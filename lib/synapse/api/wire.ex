defmodule Synapse.API.Wire do
  @moduledoc """
  Explicit version-1 server-message mapping for the local API.

  Every constructor validates its typed input, builds a fresh string-keyed map,
  encodes it, and measures the final JSON iodata against trusted Config. Elixir
  struct layout is never a wire-compatibility mechanism.

  Progress constructors have one clause per concrete Run Event. Terminal Run
  Events are not accepted as progress. Agent, Runtime, and API terminal errors
  retain distinct exact shapes, and successful terminals never expose Provider
  `final_response`.

  `server.error` reports a command or protocol failure and does not settle an
  accepted run. Once `run.accepted` has been sent, lifecycle failure is exposed
  exactly once as `run.terminal` instead.

  The complete protocol-v1 command, message, error, replay, and close-code
  reference is in the [local API guide](api.html).

  ## Replay example

      iex> config = Synapse.API.Config.default()
      iex> run_id = "run_" <> Base.url_encode64(<<0::128>>, padding: false)
      iex> {:ok, frame} = Synapse.API.Wire.snapshot("request-1", %{
      ...>   mode: :replay,
      ...>   reset: false,
      ...>   run_id: run_id,
      ...>   first_available_seq: 1,
      ...>   last_seq: 0,
      ...>   projection: nil,
      ...>   terminal: nil
      ...> }, config)
      iex> {:ok, %{"type" => "run.snapshot"}} = frame |> IO.iodata_to_binary() |> JSON.decode()

  ## Terminal example

      iex> config = Synapse.API.Config.default()
      iex> run_id = "run_" <> Base.url_encode64(<<0::128>>, padding: false)
      iex> {:ok, terminal} =
      ...>   Synapse.API.ConfirmedTerminal.internal_contract_failed(run_id, 1, config)
      iex> {:ok, frame} = Synapse.API.Wire.terminal(terminal, config)
      iex> {:ok, %{"type" => "run.terminal"}} = frame |> IO.iodata_to_binary() |> JSON.decode()
  """

  alias Synapse.Agent.Error, as: AgentError
  alias Synapse.API.Command.Cancel
  alias Synapse.API.{ActiveTool, Config, ConfirmedTerminal, Policy, Projection, TerminalError}
  alias Synapse.Run.Event

  alias Synapse.Run.Event.{
    RunCompleted,
    RunFailed,
    RunInterrupted,
    RunStarted,
    TextDelta,
    ToolCompleted,
    ToolStarted,
    TurnCompleted,
    TurnStarted
  }

  alias Synapse.Runtime.Error, as: RuntimeError
  alias Synapse.Tool.{Limits, Validation}

  @snapshot_fields [
    :mode,
    :reset,
    :run_id,
    :first_available_seq,
    :last_seq,
    :projection,
    :terminal
  ]

  @error_messages %{
    invalid_json: {"invalid_json", "Message is not valid JSON", false},
    invalid_envelope: {"invalid_envelope", "Command envelope is invalid", false},
    unsupported_version: {"unsupported_version", "Protocol version is not supported", false},
    unknown_type: {"unknown_type", "Command type is not supported", false},
    invalid_request_id: {"invalid_request_id", "Request ID is invalid", false},
    invalid_payload: {"invalid_payload", "Command payload is invalid", false},
    token_limit_exceeded:
      {"token_limit_exceeded", "Estimated input exceeds the 272000 token context limit", false},
    run_busy: {"run_busy", "A run is already active", true},
    run_not_found: {"run_not_found", "Run was not found", false},
    invalid_cursor: {"invalid_cursor", "Run cursor is invalid", false},
    subscription_limit: {"subscription_limit", "Connection subscription limit reached", false},
    runtime_unavailable: {"runtime_unavailable", "Runtime is unavailable", true},
    internal_error: {"internal_error", "Internal API failure", false}
  }

  @agent_kinds %{
    internal: "internal",
    provider: "provider",
    protocol: "protocol",
    tool: "tool",
    context: "context",
    budget: "budget",
    cancelled: "cancelled"
  }

  @agent_reasons %{
    invalid_run_request: "invalid_run_request",
    invalid_agent_context: "invalid_agent_context",
    event_sink_failed: "event_sink_failed",
    tool_executor_contract_failed: "tool_executor_contract_failed",
    conversation_projection_failed: "conversation_projection_failed",
    run_worker_crashed: "run_worker_crashed",
    workspace_close_failed: "workspace_close_failed",
    provider_failed: "provider_failed",
    provider_interrupted_after_output: "provider_interrupted_after_output",
    provider_retry_exhausted: "provider_retry_exhausted",
    empty_provider_response: "empty_provider_response",
    invalid_function_call_batch: "invalid_function_call_batch",
    tool_admission_failed: "tool_admission_failed",
    tool_ambiguous: "tool_ambiguous",
    token_limit_exceeded: "token_limit_exceeded",
    turn_budget_exhausted: "turn_budget_exhausted",
    tool_call_budget_exhausted: "tool_call_budget_exhausted",
    wall_time_budget_exhausted: "wall_time_budget_exhausted",
    output_budget_exhausted: "output_budget_exhausted",
    run_cancelled: "run_cancelled"
  }

  @runtime_reasons %{
    invalid_run_request: "invalid_run_request",
    invalid_runtime_options: "invalid_runtime_options",
    runtime_unavailable: "runtime_unavailable",
    runtime_busy: "runtime_busy",
    workspace_open_failed: "workspace_open_failed",
    runtime_lost: "runtime_lost"
  }

  @statuses %{
    starting: "starting",
    running: "running",
    cancel_requested: "cancel_requested",
    owner_lost: "owner_lost",
    completed: "completed",
    failed: "failed",
    interrupted: "interrupted"
  }

  @null_error_ids [:invalid_json, :invalid_request_id]
  @optional_error_ids [:invalid_envelope, :unsupported_version, :internal_error]

  @doc "Encodes the first message sent after a successful WebSocket upgrade."
  @spec hello(struct()) :: encode_result()
  def hello(config) do
    with {:ok, policy} <- hello_policy(config) do
      payload = %{
        "protocol" => 1,
        "replay" => "memory",
        "max_active_runs" => 1,
        "cwd" => policy.launch_cwd,
        "max_output_bytes" => policy.budget.max_output_bytes
      }

      encode("server.hello", nil, payload, policy)
    else
      _invalid -> {:error, :invalid_message}
    end
  end

  @doc "Encodes one fixed sanitized command or protocol error."
  @spec error(atom(), String.t() | nil, struct()) :: encode_result()
  def error(code, request_id, config) do
    with true <- Policy.valid?(config),
         {wire_code, message, retryable} <- Map.get(@error_messages, code),
         true <- is_binary(wire_code),
         true <- valid_error_request_id?(code, request_id, config) do
      encode(
        "server.error",
        request_id,
        %{"code" => wire_code, "message" => message, "retryable" => retryable},
        config
      )
    else
      _invalid -> {:error, :invalid_message}
    end
  end

  @doc "Encodes successful start admission."
  @spec run_accepted(String.t(), String.t(), struct()) :: encode_result()
  def run_accepted(request_id, run_id, config) do
    if Policy.valid?(config) and valid_request_id?(request_id, config) and
         Cancel.valid_run_id?(run_id, config) do
      encode(
        "run.accepted",
        request_id,
        %{"run_id" => run_id, "status" => "starting"},
        config
      )
    else
      {:error, :invalid_message}
    end
  end

  @doc "Encodes an idempotent cancellation acknowledgement."
  @spec cancel_requested(
          String.t(),
          String.t(),
          :cancel_requested | :already_terminal,
          struct()
        ) ::
          encode_result()
  def cancel_requested(request_id, run_id, status, config)
      when status in [:cancel_requested, :already_terminal] do
    if Policy.valid?(config) and valid_request_id?(request_id, config) and
         Cancel.valid_run_id?(run_id, config) do
      wire_status =
        if status == :cancel_requested, do: "cancel_requested", else: "already_terminal"

      encode(
        "run.cancel_requested",
        request_id,
        %{"run_id" => run_id, "status" => wire_status},
        config
      )
    else
      {:error, :invalid_message}
    end
  end

  def cancel_requested(_request_id, _run_id, _status, _config),
    do: {:error, :invalid_message}

  @doc "Encodes an authoritative snapshot or replay acknowledgement."
  @spec snapshot(String.t(), keyword() | map(), struct()) :: encode_result()
  def snapshot(request_id, attrs, config) do
    if Policy.valid?(config) and valid_request_id?(request_id, config),
      do: encode_snapshot(request_id, attrs, config),
      else: {:error, :invalid_message}
  end

  @doc "Encodes a Manager-initiated stale-cursor reset with no command correlation."
  @spec async_snapshot(keyword() | map(), struct()) :: encode_result()
  def async_snapshot(attrs, config) do
    if Policy.valid?(config),
      do: encode_snapshot(nil, attrs, config),
      else: {:error, :invalid_message}
  end

  defp encode_snapshot(request_id, attrs, config) do
    with {:ok, attrs} <- Validation.attributes(attrs, @snapshot_fields),
         true <- Map.keys(attrs) |> Enum.sort() == Enum.sort(@snapshot_fields),
         true <- valid_snapshot?(attrs, config),
         {:ok, terminal} <- optional_terminal_payload(attrs.terminal, config) do
      payload = %{
        "mode" => snapshot_mode(attrs.mode),
        "reset" => attrs.reset,
        "run_id" => attrs.run_id,
        "first_available_seq" => attrs.first_available_seq,
        "last_seq" => attrs.last_seq,
        "projection" => optional_projection_payload(attrs.projection, attrs.terminal),
        "terminal" => terminal
      }

      encode("run.snapshot", request_id, payload, config)
    else
      _invalid -> {:error, :invalid_message}
    end
  end

  @doc "Encodes one concrete non-terminal Runtime progress event."
  @spec event(String.t(), pos_integer(), Event.t(), struct()) :: encode_result()
  def event(run_id, seq, event, config) do
    with true <- Policy.valid?(config),
         true <- Cancel.valid_run_id?(run_id, config),
         true <- positive_int64?(seq),
         {:ok, event_payload} <- event_payload(run_id, event, config) do
      encode(
        "run.event",
        nil,
        %{"run_id" => run_id, "seq" => seq, "event" => event_payload},
        config
      )
    else
      _invalid -> {:error, :invalid_message}
    end
  end

  @doc "Encodes the API-generated owner-loss progress event."
  @spec owner_lost(String.t(), pos_integer(), struct()) :: encode_result()
  def owner_lost(run_id, seq, config) do
    if Policy.valid?(config) and Cancel.valid_run_id?(run_id, config) and positive_int64?(seq) do
      encode(
        "run.event",
        nil,
        %{"run_id" => run_id, "seq" => seq, "event" => %{"type" => "run.owner_lost"}},
        config
      )
    else
      {:error, :invalid_message}
    end
  end

  @doc "Encodes one confirmed terminal as an asynchronous server message."
  @spec terminal(ConfirmedTerminal.t(), struct()) :: encode_result()
  def terminal(%ConfirmedTerminal{} = terminal, config) do
    with {:ok, payload} <- terminal_payload(terminal, config) do
      encode("run.terminal", nil, payload, config)
    end
  end

  def terminal(_terminal, _config), do: {:error, :invalid_message}

  @doc "Encodes the empty response to a protocol ping."
  @spec pong(String.t(), struct()) :: encode_result()
  def pong(request_id, config) do
    if Policy.valid?(config) and valid_request_id?(request_id, config),
      do: encode("pong", request_id, %{}, config),
      else: {:error, :invalid_message}
  end

  @typedoc "A bounded JSON frame or a closed encoding failure classification."
  @type encode_result :: {:ok, iodata()} | {:error, :invalid_message | :message_too_large}

  defp event_payload(run_id, %RunStarted{} = event, config) do
    with true <- normalized_event?(:run_started, event, run_id),
         true <- event.model in config.model_allowlist do
      {:ok, %{"type" => "run.started", "model" => event.model}}
    else
      false -> {:error, :invalid_message}
    end
  end

  defp event_payload(run_id, %TurnStarted{} = event, config) do
    with true <- normalized_event?(:turn_started, event, run_id),
         true <- valid_operation_id?(event.operation_id, config) do
      {:ok,
       %{
         "type" => "turn.started",
         "turn" => event.turn,
         "operation_id" => event.operation_id
       }}
    else
      false -> {:error, :invalid_message}
    end
  end

  defp event_payload(run_id, %TextDelta{} = event, config) do
    with true <- normalized_event?(:text_delta, event, run_id),
         true <- valid_operation_id?(event.operation_id, config) do
      {:ok,
       %{
         "type" => "text.delta",
         "turn" => event.turn,
         "operation_id" => event.operation_id,
         "item_id" => event.item_id,
         "content_index" => event.content_index,
         "delta" => event.delta
       }}
    else
      false -> {:error, :invalid_message}
    end
  end

  defp event_payload(run_id, %ToolStarted{} = event, config) do
    with true <- normalized_event?(:tool_started, event, run_id),
         true <- valid_tool?(event, config),
         true <- valid_tool_arguments?(event.arguments, config) do
      {:ok, Map.put(tool_payload("tool.started", event), "arguments", event.arguments)}
    else
      false -> {:error, :invalid_message}
    end
  end

  defp event_payload(run_id, %ToolCompleted{} = event, config) do
    with true <- normalized_event?(:tool_completed, event, run_id),
         true <- valid_tool?(event, config),
         true <- valid_tool_content?(event.content, config),
         status when is_binary(status) <- tool_status(event.status) do
      payload =
        tool_payload("tool.completed", event)
        |> Map.put("status", status)
        |> Map.put("metadata", public_tool_metadata(event))
        |> Map.put("content", event.content)

      {:ok, payload}
    else
      _invalid -> {:error, :invalid_message}
    end
  end

  defp event_payload(run_id, %TurnCompleted{} = event, _config) do
    with true <- normalized_event?(:turn_completed, event, run_id),
         outcome when is_binary(outcome) <- turn_outcome(event.outcome) do
      {:ok,
       %{
         "type" => "turn.completed",
         "turn" => event.turn,
         "outcome" => outcome,
         "provider_attempts" => event.provider_attempts,
         "tool_calls" => event.tool_calls,
         "output_bytes" => event.output_bytes
       }}
    else
      _invalid -> {:error, :invalid_message}
    end
  end

  defp event_payload(_run_id, %RunCompleted{}, _config), do: {:error, :invalid_message}
  defp event_payload(_run_id, %RunFailed{}, _config), do: {:error, :invalid_message}
  defp event_payload(_run_id, %RunInterrupted{}, _config), do: {:error, :invalid_message}
  defp event_payload(_run_id, _event, _config), do: {:error, :invalid_message}

  defp normalized_event?(kind, event, run_id) do
    case Event.new(kind, Map.from_struct(event)) do
      {:ok, ^event} -> event.run_id == run_id
      {:ok, _normalized} -> false
      {:error, _reason} -> false
    end
  end

  defp valid_operation_id?(operation_id, config),
    do:
      Validation.identifier?(
        operation_id,
        Policy.max_operation_id_bytes(config)
      )

  defp valid_tool?(event, config) do
    attrs = %{
      turn: event.turn,
      operation_id: event.operation_id,
      call_id: event.call_id,
      name: event.name,
      ordinal: event.ordinal
    }

    match?({:ok, %ActiveTool{}}, ActiveTool.new(attrs, config))
  end

  defp valid_tool_arguments?(arguments, config) do
    limits = tool_limits(config)

    Validation.bounded_json_object?(
      arguments,
      limits.max_argument_json_bytes,
      limits.max_argument_entries,
      limits.max_argument_depth
    )
  end

  defp valid_tool_content?(content, config) do
    limits = tool_limits(config)

    is_binary(content) and String.valid?(content) and
      byte_size(content) <= limits.max_result_content_bytes
  end

  defp tool_limits(%Config{} = config), do: config.runtime_options.tool_limits
  defp tool_limits(%Policy{}), do: Limits.default()

  defp tool_payload(type, event) do
    %{
      "type" => type,
      "turn" => event.turn,
      "operation_id" => event.operation_id,
      "call_id" => event.call_id,
      "name" => event.name,
      "ordinal" => event.ordinal
    }
  end

  defp public_tool_metadata(event) do
    %{}
    |> maybe_put_metadata("tool", event.metadata["tool"], event.name)
    |> maybe_put_outcome(event.metadata["outcome"])
  end

  defp maybe_put_metadata(metadata, key, value, expected) when value == expected,
    do: Map.put(metadata, key, value)

  defp maybe_put_metadata(metadata, _key, _value, _expected), do: metadata

  defp maybe_put_outcome(metadata, outcome)
       when outcome in ["completed", "not_applied", "not_applicable", "unknown"],
       do: Map.put(metadata, "outcome", outcome)

  defp maybe_put_outcome(metadata, _outcome), do: metadata

  defp tool_status(:ok), do: "ok"
  defp tool_status(:error), do: "error"
  defp tool_status(:ambiguous), do: "ambiguous"
  defp tool_status(_status), do: :error

  defp turn_outcome(:continued), do: "continued"
  defp turn_outcome(:completed), do: "completed"
  defp turn_outcome(:failed), do: "failed"
  defp turn_outcome(:interrupted), do: "interrupted"
  defp turn_outcome(_outcome), do: :error

  defp valid_snapshot?(attrs, config) do
    Policy.valid?(config) and attrs.mode in [:snapshot, :replay] and is_boolean(attrs.reset) and
      Cancel.valid_run_id?(attrs.run_id, config) and positive_int64?(attrs.first_available_seq) and
      cursor?(attrs.last_seq) and valid_cursor_window?(attrs) and
      valid_snapshot_mode?(attrs, config)
  end

  defp valid_cursor_window?(attrs) do
    attrs.first_available_seq <= attrs.last_seq or
      (attrs.last_seq < 9_223_372_036_854_775_807 and
         attrs.first_available_seq == attrs.last_seq + 1)
  end

  defp valid_snapshot_mode?(%{mode: :replay} = attrs, _config),
    do: attrs.reset == false and is_nil(attrs.projection) and is_nil(attrs.terminal)

  defp valid_snapshot_mode?(%{mode: :snapshot} = attrs, config) do
    match?(%Projection{}, attrs.projection) and Projection.valid?(attrs.projection, config) and
      snapshot_terminal_matches?(attrs, config)
  end

  defp snapshot_terminal_matches?(%{terminal: nil, projection: projection}, _config),
    do: projection.status not in [:completed, :failed, :interrupted]

  defp snapshot_terminal_matches?(%{terminal: %ConfirmedTerminal{} = terminal} = attrs, config) do
    ConfirmedTerminal.valid?(terminal, config) and terminal.run_id == attrs.run_id and
      terminal.seq == attrs.last_seq and terminal.status == attrs.projection.status and
      completed_snapshot_matches?(attrs.projection, terminal)
  end

  defp snapshot_terminal_matches?(_attrs, _config), do: false

  defp snapshot_mode(:snapshot), do: "snapshot"
  defp snapshot_mode(:replay), do: "replay"

  defp completed_snapshot_matches?(projection, %ConfirmedTerminal{
         status: :completed,
         result: result
       }),
       do:
         projection.active_tool == nil and projection.turn == result.turns and
           projection.text == result.text and
           projection.provider_attempts == result.turns + result.provider_retries and
           projection.tool_calls == result.tool_calls and
           projection.output_bytes == result.output_bytes

  defp completed_snapshot_matches?(projection, %ConfirmedTerminal{}),
    do: projection.active_tool == nil

  defp optional_projection_payload(nil, _terminal), do: nil

  defp optional_projection_payload(%Projection{} = projection, %ConfirmedTerminal{
         status: :completed
       }),
       do: projection_payload(%{projection | text: ""})

  defp optional_projection_payload(%Projection{} = projection, _terminal),
    do: projection_payload(projection)

  defp projection_payload(projection) do
    %{
      "status" => Map.fetch!(@statuses, projection.status),
      "model" => projection.model,
      "turn" => projection.turn,
      "text" => projection.text,
      "active_tool" => active_tool_payload(projection.active_tool),
      "provider_attempts" => projection.provider_attempts,
      "tool_calls" => projection.tool_calls,
      "output_bytes" => projection.output_bytes
    }
  end

  defp active_tool_payload(nil), do: nil

  defp active_tool_payload(%ActiveTool{} = tool) do
    %{
      "turn" => tool.turn,
      "operation_id" => tool.operation_id,
      "call_id" => tool.call_id,
      "name" => tool.name,
      "ordinal" => tool.ordinal
    }
  end

  defp optional_terminal_payload(nil, _config), do: {:ok, nil}

  defp optional_terminal_payload(%ConfirmedTerminal{} = terminal, config),
    do: terminal_payload(terminal, config)

  defp optional_terminal_payload(_terminal, _config), do: {:error, :invalid_message}

  defp terminal_payload(%ConfirmedTerminal{} = terminal, config) do
    if ConfirmedTerminal.valid?(terminal, config) do
      with {:ok, error} <- optional_error_payload(terminal.error) do
        {:ok,
         %{
           "run_id" => terminal.run_id,
           "seq" => terminal.seq,
           "status" => Map.fetch!(@statuses, terminal.status),
           "result" => optional_result_payload(terminal.result),
           "error" => error
         }}
      end
    else
      {:error, :invalid_message}
    end
  end

  defp optional_result_payload(nil), do: nil

  defp optional_result_payload(result) do
    %{
      "text" => result.text,
      "turns" => result.turns,
      "tool_calls" => result.tool_calls,
      "provider_retries" => result.provider_retries,
      "output_bytes" => result.output_bytes
    }
  end

  defp optional_error_payload(nil), do: {:ok, nil}

  defp optional_error_payload(%AgentError{} = error) do
    with kind when is_binary(kind) <- Map.get(@agent_kinds, error.kind),
         reason when is_binary(reason) <- Map.get(@agent_reasons, error.reason) do
      {:ok,
       %{
         "source" => "agent",
         "kind" => kind,
         "reason" => reason,
         "message" => error.message,
         "turn" => error.turn,
         "operation_id" => error.operation_id,
         "details" => error.details
       }}
    else
      _invalid -> {:error, :invalid_message}
    end
  end

  defp optional_error_payload(%RuntimeError{} = error) do
    case Map.get(@runtime_reasons, error.reason) do
      reason when is_binary(reason) ->
        {:ok, %{"source" => "runtime", "reason" => reason, "message" => error.message}}

      _invalid ->
        {:error, :invalid_message}
    end
  end

  defp optional_error_payload(%TerminalError{} = error) do
    if TerminalError.valid?(error) do
      {:ok,
       %{
         "source" => "api",
         "reason" => "internal_contract_failed",
         "message" => error.message
       }}
    else
      {:error, :invalid_message}
    end
  end

  defp optional_error_payload(_error), do: {:error, :invalid_message}

  defp valid_request_id?(request_id, config),
    do: Validation.identifier?(request_id, config.max_request_id_bytes)

  defp valid_error_request_id?(code, request_id, _config) when code in @null_error_ids,
    do: is_nil(request_id)

  defp valid_error_request_id?(code, request_id, config) when code in @optional_error_ids,
    do: is_nil(request_id) or valid_request_id?(request_id, config)

  defp valid_error_request_id?(_code, request_id, config),
    do: valid_request_id?(request_id, config)

  defp cursor?(value), do: Validation.int64?(value) and value >= 0
  defp positive_int64?(value), do: Validation.int64?(value) and value > 0

  defp hello_policy(%Config{} = config), do: Policy.from_config(config)

  defp hello_policy(%Policy{} = policy) do
    if Policy.valid?(policy), do: {:ok, policy}, else: {:error, :invalid_message}
  end

  defp hello_policy(_config), do: {:error, :invalid_message}

  defp encode(type, request_id, payload, config) do
    if Policy.valid?(config) do
      encoded =
        JSON.encode_to_iodata!(%{
          "version" => 1,
          "type" => type,
          "request_id" => request_id,
          "payload" => payload
        })

      if IO.iodata_length(encoded) <= config.max_outgoing_message_bytes,
        do: {:ok, encoded},
        else: {:error, :message_too_large}
    else
      {:error, :invalid_message}
    end
  rescue
    _exception -> {:error, :invalid_message}
  catch
    _kind, _reason -> {:error, :invalid_message}
  end
end
