defmodule Synapse.API.Config do
  @moduledoc """
  Validated trusted startup policy for the local WebSocket API.

  Config centralizes the fixed loopback listener, launch directory, model
  allowlist, default model, server Budget, Tool capabilities, Runtime options, and
  every API-owned hard limit. It is trusted application configuration, not a wire
  contract. Protocol clients may select an allowlisted model and lower Budget
  values, but they cannot replace capabilities, Runtime options, callbacks,
  providers, or limits.

  `load/2` reads only `SYNAPSE_API_PORT`, `SYNAPSE_MODEL`, and
  `SYNAPSE_MAX_OUTPUT_BYTES` through an injected environment reader. Environment
  port `0` is rejected; trusted application configuration may use it for isolated
  tests. Disabled configuration does not require a model, which keeps ordinary
  application startup independent of server environment.

  The incoming prompt ceiling is lower than `Synapse.Run.Request`'s core ceiling.
  The complete encoded `run.start`, including optional conversation history, must
  still fit one incoming message. Config also derives a fixed model-input estimate
  from trusted instructions and static Tool schemas; only numeric fixed and
  maximum token counts cross into the authority-free API Policy. Output,
  projection, pull, replay, and retained-state limits are similarly checked as one
  compatible policy rather than accepted independently.

  See the [local API guide](api.html) for the complete limit table, trust boundary,
  startup behavior, and protocol consequences.

  ## Example

      iex> {:ok, config} = Synapse.API.Config.new()
      iex> {config.enabled, config.ip, config.port}
      {false, {127, 0, 0, 1}, 4848}
  """

  alias Synapse.Agent.ContextWindow
  alias Synapse.Budget
  alias Synapse.Runtime.Options
  alias Synapse.Tool.{CapabilitySet, Registry, Validation}

  @loopback {127, 0, 0, 1}
  @default_port 4_848
  @max_model_bytes 256
  @max_models 128
  @max_launch_cwd_bytes 4_096
  @websocket_header_bytes 14
  @start_envelope_reserve_bytes 32_768
  @snapshot_envelope_reserve_bytes 131_072
  @run_record_overhead_bytes 1_024
  @replay_entry_overhead_bytes 64
  @subscriber_overhead_bytes 64

  @limit_defaults %{
    max_incoming_message_bytes: 2_097_152,
    max_incoming_frame_payload_bytes: 2_097_152,
    max_outgoing_message_bytes: 3_276_800,
    max_input_tokens: 272_000,
    max_prompt_bytes: 262_144,
    max_request_id_bytes: 128,
    max_run_id_bytes: 64,
    max_origin_bytes: 512,
    max_json_depth: 16,
    max_json_object_keys: 32,
    max_json_array_elements: 128,
    max_json_nodes: 4_096,
    max_http_request_line_bytes: 8_192,
    max_http_headers: 32,
    max_http_header_line_bytes: 1_024,
    max_http_header_bytes: 32_768,
    connection_inactivity_ms: 60_000,
    max_protocol_violations: 8,
    max_connections: 128,
    max_subscriptions_per_socket: 16,
    max_subscribers_per_run: 128,
    max_replay_events: 2_048,
    max_replay_bytes: 4_194_304,
    max_projection_text_bytes: 524_288,
    max_pull_events: 64,
    max_pull_bytes: 3_276_800,
    max_completed_runs: 16,
    max_active_state_bytes: 8_388_608,
    max_aggregate_state_bytes: 16_777_216
  }

  @limit_minimums %{
    max_run_id_bytes: 26,
    max_replay_bytes: @replay_entry_overhead_bytes + 1,
    max_json_object_keys: 7,
    max_json_nodes: 16,
    max_http_headers: 8,
    max_http_header_line_bytes: 128
  }

  @policy_fields [
    :enabled,
    :ip,
    :port,
    :launch_cwd,
    :model_allowlist,
    :default_model,
    :budget,
    :capabilities,
    :runtime_options
  ]
  @limit_fields Map.keys(@limit_defaults)
  @allowed_fields @policy_fields ++ @limit_fields
  @derived_fields [:fixed_input_tokens]
  @struct_fields @allowed_fields ++ @derived_fields

  @enforce_keys @struct_fields
  defstruct @struct_fields

  @typedoc "Fixed IPv4 loopback address accepted by the MVP."
  @type loopback_ip :: {127, 0, 0, 1}

  @typedoc "Validated local listener, run policy, and bounded API resources."
  @type t :: %__MODULE__{
          enabled: boolean(),
          ip: loopback_ip(),
          port: :inet.port_number(),
          launch_cwd: String.t() | nil,
          model_allowlist: [String.t()],
          default_model: String.t() | nil,
          budget: Budget.t(),
          capabilities: CapabilitySet.t(),
          runtime_options: Options.t(),
          max_incoming_message_bytes: pos_integer(),
          max_incoming_frame_payload_bytes: pos_integer(),
          max_outgoing_message_bytes: pos_integer(),
          max_input_tokens: pos_integer(),
          fixed_input_tokens: pos_integer(),
          max_prompt_bytes: pos_integer(),
          max_request_id_bytes: pos_integer(),
          max_run_id_bytes: pos_integer(),
          max_origin_bytes: pos_integer(),
          max_json_depth: pos_integer(),
          max_json_object_keys: pos_integer(),
          max_json_array_elements: pos_integer(),
          max_json_nodes: pos_integer(),
          max_http_request_line_bytes: pos_integer(),
          max_http_headers: pos_integer(),
          max_http_header_line_bytes: pos_integer(),
          max_http_header_bytes: pos_integer(),
          connection_inactivity_ms: pos_integer(),
          max_protocol_violations: pos_integer(),
          max_connections: pos_integer(),
          max_subscriptions_per_socket: pos_integer(),
          max_subscribers_per_run: pos_integer(),
          max_replay_events: pos_integer(),
          max_replay_bytes: pos_integer(),
          max_projection_text_bytes: pos_integer(),
          max_pull_events: pos_integer(),
          max_pull_bytes: pos_integer(),
          max_completed_runs: pos_integer(),
          max_active_state_bytes: pos_integer(),
          max_aggregate_state_bytes: pos_integer()
        }

  @typedoc "A sanitized startup-policy validation failure."
  @type validation_error ::
          {:attributes, :must_be_keyword_or_map}
          | {:unknown_fields, [term()]}
          | {:environment,
             :unavailable | :invalid_port | :invalid_model | :invalid_max_output_bytes}
          | {atom(), atom()}

  @doc "Returns validated API-disabled production defaults."
  @spec default() :: t()
  def default do
    {:ok, config} = new()
    config
  end

  @doc "Builds trusted configuration without reading environment or starting resources."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs \\ %{}) do
    with {:ok, attrs} <- Validation.attributes(attrs, @allowed_fields),
         values <- Map.merge(default_values(), attrs),
         :ok <- validate_listener(values),
         {:ok, budget} <- normalize_budget(values.budget),
         {:ok, capabilities} <- normalize_capabilities(values.capabilities),
         {:ok, runtime_options} <- normalize_runtime_options(values.runtime_options),
         {:ok, fixed_input_tokens} <-
           ContextWindow.fixed_input_tokens(
             runtime_options.instructions,
             Registry.specifications()
           ),
         :ok <- validate_api_budget(budget),
         :ok <- validate_limits(values),
         {:ok, model_allowlist, default_model} <- normalize_models(values),
         :ok <- validate_launch_cwd(values),
         values <-
           Map.merge(values, %{
             budget: budget,
             capabilities: capabilities,
             runtime_options: runtime_options,
             fixed_input_tokens: fixed_input_tokens,
             model_allowlist: model_allowlist,
             default_model: default_model
           }),
         :ok <- validate_relationships(values) do
      {:ok, struct!(__MODULE__, values)}
    end
  end

  @doc "Loads trusted application configuration plus the three supported environment overrides."
  @spec load(keyword() | map(), (String.t() -> String.t() | nil)) ::
          {:ok, t()} | {:error, validation_error()}
  def load(
        application_config \\ Application.get_env(:synapse, :api, []),
        environment \\ &System.get_env/1
      ) do
    with true <- is_function(environment, 1) or {:error, {:environment, :unavailable}},
         {:ok, attrs} <- Validation.attributes(application_config, @allowed_fields),
         {:ok, port} <- environment_port(environment),
         {:ok, model} <- environment_model(environment),
         {:ok, max_output_bytes} <- environment_max_output_bytes(environment),
         {:ok, attrs} <- put_environment_output_budget(attrs, max_output_bytes) do
      attrs |> maybe_put(:port, port) |> maybe_put(:default_model, model) |> new()
    end
  end

  @doc "Returns whether a Config struct passes complete normalization."
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = config) do
    attrs = config |> Map.from_struct() |> Map.drop(@derived_fields)
    match?({:ok, ^config}, new(attrs))
  end

  def valid?(_config), do: false

  @doc "Validates optional client Budget fields as lowering-only server policy."
  @spec lower_budget(t(), keyword() | map()) ::
          {:ok, Budget.t()} | {:error, Budget.validation_error() | validation_error()}
  def lower_budget(%__MODULE__{} = config, attrs) do
    with true <- valid?(config) or {:error, {:config, :must_be_valid}},
         fields <- Map.keys(Map.from_struct(config.budget)),
         {:ok, attrs} <- Validation.attributes(attrs, fields),
         :ok <- values_do_not_widen(attrs, config.budget),
         values <- Map.merge(Map.from_struct(config.budget), attrs),
         {:ok, budget} <- Budget.new(values) do
      {:ok, budget}
    end
  end

  def lower_budget(_config, _attrs), do: {:error, {:config, :must_be_valid}}

  @doc "Returns Bandit's wire-frame ceiling including the largest masked header."
  @spec max_incoming_frame_wire_bytes(t()) :: pos_integer()
  def max_incoming_frame_wire_bytes(%__MODULE__{} = config),
    do: config.max_incoming_frame_payload_bytes + @websocket_header_bytes

  @doc false
  @spec run_record_overhead_bytes() :: pos_integer()
  def run_record_overhead_bytes, do: @run_record_overhead_bytes

  @doc false
  @spec replay_entry_overhead_bytes() :: pos_integer()
  def replay_entry_overhead_bytes, do: @replay_entry_overhead_bytes

  @doc false
  @spec subscriber_overhead_bytes() :: pos_integer()
  def subscriber_overhead_bytes, do: @subscriber_overhead_bytes

  defp default_values do
    {:ok, capabilities} =
      CapabilitySet.new(fs_read: true, fs_write: true, process_exec: true)

    Map.merge(@limit_defaults, %{
      enabled: false,
      ip: @loopback,
      port: @default_port,
      launch_cwd: nil,
      model_allowlist: [],
      default_model: nil,
      budget: Budget.default(),
      capabilities: capabilities,
      runtime_options: runtime_options_default()
    })
  end

  defp runtime_options_default do
    {:ok, options} = Options.new()
    options
  end

  defp validate_listener(values) do
    cond do
      not is_boolean(values.enabled) ->
        {:error, {:enabled, :must_be_boolean}}

      values.ip != @loopback ->
        {:error, {:ip, :must_be_ipv4_loopback}}

      not (is_integer(values.port) and values.port in 0..65_535) ->
        {:error, {:port, :must_be_valid_port}}

      true ->
        :ok
    end
  end

  defp normalize_budget(%Budget{} = budget) do
    case Budget.new(Map.from_struct(budget)) do
      {:ok, budget} -> {:ok, budget}
      {:error, _reason} -> {:error, {:budget, :must_be_budget}}
    end
  end

  defp normalize_budget(_budget), do: {:error, {:budget, :must_be_budget}}

  defp normalize_capabilities(%CapabilitySet{} = capabilities) do
    case CapabilitySet.new(Map.from_struct(capabilities)) do
      {:ok, capabilities} -> {:ok, capabilities}
      {:error, _reason} -> {:error, {:capabilities, :must_be_capability_set}}
    end
  end

  defp normalize_capabilities(_capabilities),
    do: {:error, {:capabilities, :must_be_capability_set}}

  defp normalize_runtime_options(%Options{} = options) do
    case Options.new(Map.from_struct(options)) do
      {:ok, options} -> {:ok, options}
      {:error, _reason} -> {:error, {:runtime_options, :must_be_runtime_options}}
    end
  end

  defp normalize_runtime_options(_options),
    do: {:error, {:runtime_options, :must_be_runtime_options}}

  defp validate_api_budget(%Budget{max_output_bytes: value})
       when value <= @limit_defaults.max_projection_text_bytes,
       do: :ok

  defp validate_api_budget(%Budget{}),
    do: {:error, {:budget, :max_output_bytes_exceeds_api_limit}}

  defp validate_limits(values) do
    case Enum.find(@limit_fields, fn field ->
           value = values[field]
           minimum = Map.get(@limit_minimums, field, 1)
           not (is_integer(value) and value >= minimum and value <= @limit_defaults[field])
         end) do
      nil -> :ok
      field -> {:error, {field, :must_be_in_recorded_range}}
    end
  end

  defp normalize_models(values) do
    models = values.model_allowlist

    with true <-
           (Validation.proper_list?(models, @max_models) and
              Enum.all?(models, &Validation.identifier?(&1, @max_model_bytes))) or
             {:error, {:model_allowlist, :must_be_bounded_identifiers}},
         models <- Enum.uniq(models),
         {:ok, default_model} <- normalize_default_model(values.default_model, models),
         models <-
           if(is_nil(default_model), do: models, else: add_default_model(models, default_model)),
         true <-
           not values.enabled or not is_nil(default_model) or
             {:error, {:default_model, :required_when_enabled}} do
      {:ok, models, default_model}
    end
  end

  defp normalize_default_model(nil, _models), do: {:ok, nil}

  defp normalize_default_model(model, models) do
    cond do
      not Validation.identifier?(model, @max_model_bytes) ->
        {:error, {:default_model, :must_be_bounded_identifier}}

      models != [] and model not in models ->
        {:error, {:default_model, :must_be_allowlisted}}

      true ->
        {:ok, model}
    end
  end

  defp add_default_model([], default_model), do: [default_model]
  defp add_default_model(models, _default_model), do: models

  defp validate_launch_cwd(%{enabled: false, launch_cwd: nil}), do: :ok

  defp validate_launch_cwd(%{enabled: true, launch_cwd: nil}),
    do: {:error, {:launch_cwd, :required_when_enabled}}

  defp validate_launch_cwd(%{launch_cwd: launch_cwd}) do
    if bounded_absolute_path?(launch_cwd),
      do: :ok,
      else: {:error, {:launch_cwd, :must_be_bounded_absolute_path}}
  end

  defp bounded_absolute_path?(value),
    do:
      is_binary(value) and byte_size(value) <= @max_launch_cwd_bytes and
        String.valid?(value) and String.trim(value) != "" and
        :binary.match(value, <<0>>) == :nomatch and Path.type(value) == :absolute

  defp validate_relationships(values) do
    relationships = [
      {:max_incoming_message_bytes,
       escaped_size_fits?(
         values.max_prompt_bytes,
         @start_envelope_reserve_bytes,
         values.max_incoming_message_bytes
       )},
      {:max_outgoing_message_bytes,
       escaped_size_fits?(
         max(values.budget.max_output_bytes, values.max_projection_text_bytes),
         @snapshot_envelope_reserve_bytes,
         values.max_outgoing_message_bytes
       )},
      {:max_projection_text_bytes,
       values.max_projection_text_bytes >= values.budget.max_output_bytes},
      {:max_input_tokens, values.fixed_input_tokens < values.max_input_tokens},
      {:max_pull_bytes, values.max_pull_bytes == values.max_outgoing_message_bytes},
      {:max_replay_bytes,
       values.max_replay_bytes >=
         values.max_outgoing_message_bytes + @replay_entry_overhead_bytes},
      {:max_origin_bytes, values.max_origin_bytes <= values.max_http_header_line_bytes},
      {:max_http_header_bytes,
       values.max_http_header_line_bytes * values.max_http_headers <=
         values.max_http_header_bytes},
      {:max_active_state_bytes,
       values.max_replay_bytes + values.max_projection_text_bytes +
         values.max_outgoing_message_bytes + maximum_fixed_active_state_bytes(values) <=
         values.max_active_state_bytes},
      {:max_aggregate_state_bytes,
       values.max_active_state_bytes <= values.max_aggregate_state_bytes}
    ]

    case Enum.find(relationships, fn {_field, valid?} -> not valid? end) do
      nil -> :ok
      {field, false} -> {:error, {field, :incompatible_limit}}
    end
  end

  defp escaped_size_fits?(source_bytes, reserve_bytes, maximum),
    do: source_bytes * 6 + reserve_bytes <= maximum

  defp maximum_fixed_active_state_bytes(values) do
    tool_limits = values.runtime_options.tool_limits

    @run_record_overhead_bytes + values.max_run_id_bytes + @max_model_bytes +
      tool_limits.max_operation_id_bytes + tool_limits.max_call_id_bytes +
      tool_limits.max_tool_name_bytes +
      values.max_subscribers_per_run * @subscriber_overhead_bytes
  end

  defp values_do_not_widen(attrs, budget) do
    case Enum.find(attrs, fn {field, value} ->
           is_integer(value) and value > Map.fetch!(budget, field)
         end) do
      nil -> :ok
      {field, _value} -> {:error, {field, :must_not_exceed_server_policy}}
    end
  end

  defp environment_port(environment) do
    with {:ok, value} <- read_environment(environment, "SYNAPSE_API_PORT") do
      case value do
        nil -> {:ok, nil}
        value -> parse_environment_port(value)
      end
    end
  end

  defp parse_environment_port(value) do
    case Integer.parse(value) do
      {port, ""} when port in 1..65_535 -> {:ok, port}
      _invalid -> {:error, {:environment, :invalid_port}}
    end
  end

  defp environment_model(environment) do
    with {:ok, value} <- read_environment(environment, "SYNAPSE_MODEL") do
      cond do
        is_nil(value) -> {:ok, nil}
        Validation.identifier?(value, @max_model_bytes) -> {:ok, value}
        true -> {:error, {:environment, :invalid_model}}
      end
    end
  end

  defp environment_max_output_bytes(environment) do
    with {:ok, value} <- read_environment(environment, "SYNAPSE_MAX_OUTPUT_BYTES") do
      case value do
        nil -> {:ok, nil}
        value -> parse_environment_max_output_bytes(value)
      end
    end
  end

  defp parse_environment_max_output_bytes(value) do
    with true <- Regex.match?(~r/^[1-9][0-9]*$/, value),
         {bytes, ""} when bytes <= 524_288 <- Integer.parse(value) do
      {:ok, bytes}
    else
      _invalid -> {:error, {:environment, :invalid_max_output_bytes}}
    end
  end

  defp put_environment_output_budget(attrs, nil), do: {:ok, attrs}

  defp put_environment_output_budget(attrs, max_output_bytes) do
    case normalize_budget(Map.get(attrs, :budget, Budget.default())) do
      {:ok, budget} ->
        effective = min(max_output_bytes, budget.max_output_bytes)
        {:ok, Map.put(attrs, :budget, %{budget | max_output_bytes: effective})}

      {:error, _reason} = error ->
        error
    end
  end

  defp read_environment(environment, name) do
    case environment.(name) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _invalid -> {:error, {:environment, :unavailable}}
    end
  rescue
    _exception -> {:error, {:environment, :unavailable}}
  catch
    _kind, _reason -> {:error, {:environment, :unavailable}}
  end

  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, key, value), do: Map.put(attrs, key, value)
end

defimpl Inspect, for: Synapse.API.Config do
  def inspect(config, _options) do
    if Synapse.API.Config.valid?(config) do
      "#Synapse.API.Config<enabled=#{inspect(config.enabled)} ip=127.0.0.1 port=#{config.port} models=#{length(config.model_allowlist)} redacted>"
    else
      "#Synapse.API.Config<invalid redacted>"
    end
  end
end
