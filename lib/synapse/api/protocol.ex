defmodule Synapse.API.Protocol do
  @moduledoc """
  Pure decoder for one bounded local API command.

  `decode/2` checks encoded bytes before JSON decoding, bounds the complete
  decoded tree, validates the exact version-1 envelope, and constructs one typed
  internal command value. External strings are matched against fixed literals;
  decoding never creates atoms.

  Ordinary protocol failures return a stable code and the validated request ID
  when one exists. An oversized message returns `{:close, :message_too_big}` so
  the later WebSocket adapter can close with RFC 6455 code 1009 without emitting
  another frame. The internal `:internal_error` classification is not a client
  validation response; Socket closes 1011 when trusted policy is invalid.

  Protocol v1 accepts exactly `run.start`, `run.cancel`, `run.subscribe`, and
  `ping` at `ws://127.0.0.1:4848/v1/socket`. See the [local API guide](api.html)
  for exact envelopes, limits, replay behavior, close codes, and security scope.

  ## Example

      iex> {:ok, config} = Synapse.API.Config.new(enabled: true, default_model: "model-a")
      iex> message = ~s({"version":1,"type":"run.start","request_id":"request-1","payload":{"prompt":"Inspect","cwd":"/tmp/project"}})
      iex> {:ok, {"request-1", %Synapse.API.Command.Start{} = start}} =
      ...>   Synapse.API.Protocol.decode(message, config)
      iex> {start.model, start.prompt}
      {"model-a", "Inspect"}
  """

  alias Synapse.API.Command
  alias Synapse.API.Command.{Cancel, Ping, Start, Subscribe}
  alias Synapse.API.Policy
  alias Synapse.Tool.Validation

  @envelope_keys MapSet.new(~w(payload request_id type version))
  @start_keys MapSet.new(~w(budget cwd model prompt))
  @cancel_keys MapSet.new(~w(run_id))
  @subscribe_keys MapSet.new(~w(after_seq run_id))
  @budget_fields %{
    "max_turns" => :max_turns,
    "max_tool_calls" => :max_tool_calls,
    "max_wall_time_ms" => :max_wall_time_ms,
    "provider_inactivity_ms" => :provider_inactivity_ms,
    "tool_inactivity_ms" => :tool_inactivity_ms,
    "max_output_bytes" => :max_output_bytes,
    "max_provider_retries" => :max_provider_retries
  }

  @typedoc "Stable decode classification; ordinary protocol codes become `server.error`."
  @type error_code ::
          :invalid_json
          | :invalid_envelope
          | :unsupported_version
          | :unknown_type
          | :invalid_request_id
          | :invalid_payload
          | :internal_error

  @typedoc "A typed command, sanitized protocol error, or close-only size violation."
  @type decode_result ::
          {:ok, {String.t(), struct()}}
          | {:error, error_code(), String.t() | nil}
          | {:close, :message_too_big}

  @doc "Decodes one complete WebSocket text message without starting resources."
  @spec decode(binary(), Synapse.API.Config.t() | struct()) :: decode_result()
  def decode(message, config) when is_binary(message) do
    cond do
      not Policy.valid?(config) ->
        {:error, :internal_error, nil}

      byte_size(message) > config.max_incoming_message_bytes ->
        {:close, :message_too_big}

      true ->
        decode_json(message, config)
    end
  end

  def decode(_message, _config), do: {:error, :invalid_json, nil}

  defp decode_json(message, config) do
    case JSON.decode(message) do
      {:ok, decoded} -> decode_value(decoded, config)
      {:error, _reason} -> {:error, :invalid_json, nil}
    end
  rescue
    _exception -> {:error, :invalid_json, nil}
  catch
    _kind, _reason -> {:error, :invalid_json, nil}
  end

  defp decode_value(decoded, config) do
    request_id = correlated_request_id(decoded, config)

    with true <- bounded_tree?(decoded, config) or protocol_error(:invalid_envelope, request_id),
         true <- envelope?(decoded) or protocol_error(:invalid_envelope, request_id),
         :ok <- validate_version(decoded["version"], request_id),
         :ok <- validate_request_id(decoded["request_id"], config),
         :ok <- validate_type(decoded["type"], request_id),
         true <-
           plain_object?(decoded["payload"]) or protocol_error(:invalid_envelope, request_id),
         {:ok, command} <- command(decoded["type"], decoded["payload"], config),
         {:ok, typed} <- Command.new(decoded["request_id"], command, config) do
      {:ok, typed}
    else
      {:error, code, correlation} -> {:error, code, correlation}
      {:error, _reason} -> {:error, :invalid_payload, request_id}
      false -> {:error, :invalid_payload, request_id}
    end
  end

  defp validate_version(version, request_id) when not is_integer(version),
    do: protocol_error(:invalid_envelope, request_id)

  defp validate_version(1, _request_id), do: :ok

  defp validate_version(_version, request_id),
    do: protocol_error(:unsupported_version, request_id)

  defp validate_request_id(request_id, config) do
    if Validation.identifier?(request_id, config.max_request_id_bytes),
      do: :ok,
      else: protocol_error(:invalid_request_id, nil)
  end

  defp validate_type(type, request_id) when not is_binary(type),
    do: protocol_error(:invalid_envelope, request_id)

  defp validate_type(type, _request_id)
       when type in ["run.start", "run.cancel", "run.subscribe", "ping"],
       do: :ok

  defp validate_type(_type, request_id), do: protocol_error(:unknown_type, request_id)

  defp command("run.start", payload, config), do: start(payload, config)
  defp command("run.cancel", payload, config), do: cancel(payload, config)
  defp command("run.subscribe", payload, config), do: subscribe(payload, config)
  defp command("ping", payload, config), do: Ping.new(payload, config)

  defp start(payload, config) do
    with true <- exact_optional_keys?(payload, @start_keys, ~w(cwd prompt)),
         {:ok, model} <- selected_model(payload, config),
         {:ok, budget} <- selected_budget(payload, config) do
      Start.new(
        %{prompt: payload["prompt"], cwd: payload["cwd"], model: model, budget: budget},
        config
      )
    end
  end

  defp selected_model(payload, config) do
    if Map.has_key?(payload, "model") do
      model = payload["model"]
      if is_binary(model), do: {:ok, model}, else: {:error, :invalid_model}
    else
      if is_binary(config.default_model),
        do: {:ok, config.default_model},
        else: {:error, :invalid_model}
    end
  end

  defp selected_budget(payload, config) do
    if Map.has_key?(payload, "budget") do
      lower_budget(payload["budget"], config)
    else
      {:ok, config.budget}
    end
  end

  defp lower_budget(budget, config) when is_map(budget) and not is_struct(budget) do
    with true <-
           MapSet.subset?(MapSet.new(Map.keys(budget)), MapSet.new(Map.keys(@budget_fields))),
         true <- Enum.all?(budget, fn {_field, value} -> is_integer(value) end) do
      attrs = Map.new(budget, fn {field, value} -> {Map.fetch!(@budget_fields, field), value} end)
      Policy.lower_budget(config, attrs)
    else
      false -> {:error, :invalid_budget}
    end
  end

  defp lower_budget(_budget, _config), do: {:error, :invalid_budget}

  defp cancel(payload, config) do
    if exact_keys?(payload, @cancel_keys),
      do: Cancel.new(%{run_id: payload["run_id"]}, config),
      else: {:error, :invalid_payload}
  end

  defp subscribe(payload, config) do
    with true <- exact_optional_keys?(payload, @subscribe_keys, ["run_id"]),
         true <-
           not Map.has_key?(payload, "after_seq") or not is_nil(payload["after_seq"]) do
      Subscribe.new(
        %{run_id: payload["run_id"], after_seq: Map.get(payload, "after_seq")},
        config
      )
    else
      false -> {:error, :invalid_payload}
    end
  end

  defp correlated_request_id(value, config) when is_map(value) and not is_struct(value) do
    request_id = value["request_id"]

    if Validation.identifier?(request_id, config.max_request_id_bytes),
      do: request_id,
      else: nil
  end

  defp correlated_request_id(_value, _config), do: nil

  defp envelope?(value), do: plain_object?(value) and exact_keys?(value, @envelope_keys)

  defp exact_optional_keys?(value, allowed, required) do
    plain_object?(value) and MapSet.subset?(MapSet.new(Map.keys(value)), allowed) and
      Enum.all?(required, &Map.has_key?(value, &1))
  end

  defp exact_keys?(value, keys), do: plain_object?(value) and MapSet.new(Map.keys(value)) == keys
  defp plain_object?(value), do: is_map(value) and not is_struct(value)
  defp protocol_error(code, request_id), do: {:error, code, request_id}

  defp bounded_tree?(value, config), do: match?({:ok, _nodes}, visit(value, 1, 0, config))

  defp visit(_value, depth, _nodes, config) when depth > config.max_json_depth, do: :error
  defp visit(_value, _depth, nodes, config) when nodes >= config.max_json_nodes, do: :error

  defp visit(value, depth, nodes, config) when is_map(value) and not is_struct(value) do
    if map_size(value) <= config.max_json_object_keys do
      Enum.reduce_while(value, {:ok, nodes + 1}, fn {key, item}, {:ok, count} ->
        if bounded_json_string?(key, config) do
          case visit(item, depth + 1, count, config) do
            {:ok, next} -> {:cont, {:ok, next}}
            :error -> {:halt, :error}
          end
        else
          {:halt, :error}
        end
      end)
    else
      :error
    end
  end

  defp visit(value, depth, nodes, config) when is_list(value) do
    if Validation.proper_list?(value, config.max_json_array_elements + 1) and
         length(value) <= config.max_json_array_elements do
      Enum.reduce_while(value, {:ok, nodes + 1}, fn item, {:ok, count} ->
        case visit(item, depth + 1, count, config) do
          {:ok, next} -> {:cont, {:ok, next}}
          :error -> {:halt, :error}
        end
      end)
    else
      :error
    end
  end

  defp visit(value, _depth, nodes, config) when is_binary(value) do
    if bounded_json_string?(value, config), do: {:ok, nodes + 1}, else: :error
  end

  defp visit(value, _depth, nodes, _config) when is_integer(value) do
    if Validation.int64?(value), do: {:ok, nodes + 1}, else: :error
  end

  defp visit(value, _depth, nodes, _config)
       when is_float(value) or is_boolean(value) or is_nil(value),
       do: {:ok, nodes + 1}

  defp visit(_value, _depth, _nodes, _config), do: :error

  defp bounded_json_string?(value, config),
    do:
      is_binary(value) and byte_size(value) <= config.max_incoming_message_bytes and
        String.valid?(value)
end
