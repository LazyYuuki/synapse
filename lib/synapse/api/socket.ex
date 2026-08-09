defmodule Synapse.API.Socket.Arguments do
  @moduledoc false

  @enforce_keys [:manager, :policy]
  defstruct @enforce_keys
end

defmodule Synapse.API.Socket.State do
  @moduledoc false

  alias Synapse.API.Policy
  alias Synapse.Tool.Validation

  @enforce_keys [
    :manager,
    :policy,
    :cursors,
    :pending_pulls,
    :continuation_scheduled,
    :violations
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          manager: GenServer.server() | nil,
          policy: struct() | nil,
          cursors: %{optional(String.t()) => non_neg_integer()},
          pending_pulls: [String.t()],
          continuation_scheduled: boolean(),
          violations: non_neg_integer()
        }

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = state) do
    valid_manager?(state.manager) and match?(%Policy{}, state.policy) and
      Policy.valid?(state.policy) and
      is_map(state.cursors) and
      map_size(state.cursors) <= state.policy.max_subscriptions_per_socket and
      Enum.all?(state.cursors, fn {run_id, cursor} ->
        Synapse.API.Command.Cancel.valid_run_id?(run_id, state.policy) and
          Validation.int64?(cursor) and cursor >= 0
      end) and valid_pending?(state) and is_boolean(state.continuation_scheduled) and
      is_integer(state.violations) and state.violations >= 0 and
      state.violations <= state.policy.max_protocol_violations + 1
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  def valid?(_state), do: false

  @spec invalid() :: t()
  def invalid do
    %__MODULE__{
      manager: nil,
      policy: nil,
      cursors: %{},
      pending_pulls: [],
      continuation_scheduled: false,
      violations: 0
    }
  end

  defp valid_manager?(manager),
    do:
      is_pid(manager) or is_atom(manager) or match?({:global, _term}, manager) or
        match?({:via, _module, _term}, manager)

  defp valid_pending?(state) do
    Validation.proper_list?(state.pending_pulls, state.policy.max_subscriptions_per_socket) and
      length(state.pending_pulls) == length(Enum.uniq(state.pending_pulls)) and
      Enum.all?(state.pending_pulls, &Map.has_key?(state.cursors, &1))
  end
end

defmodule Synapse.API.Socket do
  @moduledoc """
  Bounded WebSock adapter for the version-1 local API protocol.

  Socket retains only an authority-free policy, at most sixteen run cursors, one
  bounded pending-pull queue, one continuation flag, and a protocol-violation
  counter. It routes typed run lifecycle commands through RunManager and forwards
  Manager's original encoded replay bytes after decoding them only to validate the
  exact envelope, run ID, and contiguous sequence.

  Direct command responses return from `handle_in/2` before any continuation
  scheduled by that command can run. Asynchronous events use Manager cursors and
  carry no command request ID. Disconnect removes subscriptions but never requests
  run cancellation; RunSession and Runtime ownership are independent of transport.

  This callback executes in a Bandit-owned connection process; it is not a separate
  supervised API worker. See the [local API guide](api.html) for client cursor rules,
  transport limits, and close codes.
  """

  @behaviour WebSock

  alias Synapse.Agent.Error, as: AgentError
  alias Synapse.API.Command.{Cancel, Ping, Start, Subscribe}
  alias Synapse.API.{Config, Policy, Protocol, RunManager, Wire}
  alias Synapse.API.Socket.{Arguments, State}
  alias Synapse.Tool.{Limits, Validation}

  @continue_pull :synapse_socket_continue_pull
  @agent_kinds %{
    "internal" => :internal,
    "provider" => :provider,
    "protocol" => :protocol,
    "tool" => :tool,
    "context" => :context,
    "budget" => :budget,
    "cancelled" => :cancelled
  }
  @agent_reasons %{
    "invalid_run_request" => :invalid_run_request,
    "invalid_agent_context" => :invalid_agent_context,
    "event_sink_failed" => :event_sink_failed,
    "tool_executor_contract_failed" => :tool_executor_contract_failed,
    "conversation_projection_failed" => :conversation_projection_failed,
    "run_worker_crashed" => :run_worker_crashed,
    "workspace_close_failed" => :workspace_close_failed,
    "provider_failed" => :provider_failed,
    "provider_interrupted_after_output" => :provider_interrupted_after_output,
    "provider_retry_exhausted" => :provider_retry_exhausted,
    "empty_provider_response" => :empty_provider_response,
    "invalid_function_call_batch" => :invalid_function_call_batch,
    "tool_admission_failed" => :tool_admission_failed,
    "tool_ambiguous" => :tool_ambiguous,
    "token_limit_exceeded" => :token_limit_exceeded,
    "turn_budget_exhausted" => :turn_budget_exhausted,
    "tool_call_budget_exhausted" => :tool_call_budget_exhausted,
    "wall_time_budget_exhausted" => :wall_time_budget_exhausted,
    "output_budget_exhausted" => :output_budget_exhausted,
    "run_cancelled" => :run_cancelled
  }
  @runtime_errors %{
    "invalid_run_request" => {"Run Request is invalid", "failed"},
    "invalid_runtime_options" => {"Runtime options are invalid", "failed"},
    "runtime_unavailable" => {"Runtime infrastructure is unavailable", "failed"},
    "runtime_busy" => {"Runtime is busy", "failed"},
    "workspace_open_failed" => {"Workspace could not be opened", "failed"},
    "runtime_lost" => {"Runtime coordinator was lost", "interrupted"}
  }

  @doc false
  @spec arguments(GenServer.server(), Config.t()) ::
          {:ok, struct()} | {:error, :invalid_socket_arguments}
  def arguments(manager, %Config{} = config) do
    with true <- valid_manager?(manager),
         {:ok, policy} <- Policy.from_config(config) do
      {:ok, %Arguments{manager: manager, policy: policy}}
    else
      _invalid -> {:error, :invalid_socket_arguments}
    end
  end

  def arguments(_manager, _config), do: {:error, :invalid_socket_arguments}

  @impl true
  def init(%Arguments{manager: manager, policy: %Policy{} = policy}) do
    state = initial_state(manager, policy)

    if State.valid?(state) do
      case Wire.hello(policy) do
        {:ok, encoded} -> {:push, {:text, encoded}, state}
        {:error, _reason} -> close(1011, state)
      end
    else
      close(1011, State.invalid())
    end
  end

  def init(_arguments), do: close(1011, State.invalid())

  @impl true
  def handle_in({_message, opcode: :binary}, %State{} = state) do
    if State.valid?(state), do: close(1003, state), else: close(1011, state)
  end

  def handle_in({message, opcode: :text}, %State{} = state) do
    if State.valid?(state) do
      case Protocol.decode(message, state.policy) do
        {:ok, {request_id, command}} -> route_command(request_id, command, state)
        {:error, :internal_error, _request_id} -> close(1011, state)
        {:error, code, request_id} -> protocol_violation(code, request_id, state)
        {:close, :message_too_big} -> close(1009, state)
      end
    else
      close(1011, state)
    end
  end

  def handle_in(_message, %State{} = state), do: close(1011, state)
  def handle_in(_message, _state), do: close(1011, State.invalid())

  @impl true
  def handle_control({_message, opcode: opcode}, %State{} = state)
      when opcode in [:ping, :pong] do
    if State.valid?(state), do: {:ok, state}, else: close(1011, state)
  end

  def handle_control(_message, %State{} = state), do: close(1011, state)
  def handle_control(_message, _state), do: close(1011, State.invalid())

  @impl true
  def handle_info({:synapse_run_changed, run_id}, %State{} = state) do
    cond do
      not State.valid?(state) -> close(1011, state)
      not Map.has_key?(state.cursors, run_id) -> {:ok, state}
      run_id in state.pending_pulls -> {:ok, state}
      true -> pull_run(run_id, state)
    end
  end

  def handle_info(@continue_pull, %State{} = state) do
    if State.valid?(state) and state.continuation_scheduled do
      case state.pending_pulls do
        [run_id | rest] ->
          run_id
          |> pull_run(%{state | pending_pulls: rest, continuation_scheduled: false})
          |> continue_pending()

        [] ->
          {:ok, %{state | continuation_scheduled: false}}
      end
    else
      close(1011, state)
    end
  end

  def handle_info(_message, %State{} = state) do
    if State.valid?(state), do: {:ok, state}, else: close(1011, state)
  end

  def handle_info(_message, _state), do: close(1011, State.invalid())

  @impl true
  def terminate(_reason, %State{manager: manager}) do
    if valid_manager?(manager), do: RunManager.unsubscribe_all_async(manager)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp route_command(request_id, %Start{} = command, state) do
    if map_size(state.cursors) >= state.policy.max_subscriptions_per_socket do
      command_error(:subscription_limit, request_id, state)
    else
      case RunManager.start_run(state.manager, command) do
        {:ok, run_id} ->
          with {:ok, encoded} <- Wire.run_accepted(request_id, run_id, state.policy) do
            push(encoded, %{state | cursors: Map.put(state.cursors, run_id, 0)})
          else
            {:error, _reason} -> close(1011, state)
          end

        {:error, reason}
        when reason in [:run_busy, :subscription_limit, :runtime_unavailable] ->
          command_error(reason, request_id, state)

        {:error, :internal_error} ->
          close(1011, state)

        _invalid ->
          close(1011, state)
      end
    end
  end

  defp route_command(request_id, %Cancel{run_id: run_id}, state) do
    case RunManager.cancel(state.manager, run_id) do
      {:ok, status} when status in [:cancel_requested, :already_terminal] ->
        case Wire.cancel_requested(request_id, run_id, status, state.policy) do
          {:ok, encoded} -> push(encoded, state)
          {:error, _reason} -> close(1011, state)
        end

      {:error, :run_not_found} ->
        command_error(:run_not_found, request_id, state)

      {:error, :internal_error} ->
        close(1011, state)

      _invalid ->
        close(1011, state)
    end
  end

  defp route_command(request_id, %Subscribe{} = command, state) do
    existing? = Map.has_key?(state.cursors, command.run_id)

    if not existing? and map_size(state.cursors) >= state.policy.max_subscriptions_per_socket do
      command_error(:subscription_limit, request_id, state)
    else
      subscribe(request_id, command, state)
    end
  end

  defp route_command(request_id, %Ping{}, state) do
    case Wire.pong(request_id, state.policy) do
      {:ok, encoded} -> push(encoded, state)
      {:error, _reason} -> close(1011, state)
    end
  end

  defp route_command(_request_id, _command, state), do: close(1011, state)

  defp subscribe(request_id, command, state) do
    case RunManager.subscribe(state.manager, command.run_id, command.after_seq) do
      {:ok, snapshot} ->
        with true <-
               is_map(snapshot) and not is_struct(snapshot) and
                 snapshot[:run_id] == command.run_id,
             true <- valid_subscribe_snapshot?(snapshot, command.after_seq),
             {:ok, encoded} <- Wire.snapshot(request_id, snapshot, state.policy),
             {:ok, cursor} <- subscription_cursor(snapshot, command.after_seq) do
          next = %{state | cursors: Map.put(state.cursors, command.run_id, cursor)}
          push(encoded, enqueue_pull(next, command.run_id))
        else
          _invalid -> close(1011, state)
        end

      {:error, :run_not_found} ->
        state = drop_run(state, command.run_id)
        command_error(:run_not_found, request_id, state)

      {:error, reason} when reason in [:invalid_cursor, :subscription_limit] ->
        command_error(reason, request_id, state)

      {:error, :internal_error} ->
        close(1011, state)

      _invalid ->
        close(1011, state)
    end
  end

  defp subscription_cursor(%{mode: :snapshot, last_seq: last_seq}, _requested),
    do: valid_cursor(last_seq)

  defp subscription_cursor(%{mode: :replay}, requested), do: valid_cursor(requested)
  defp subscription_cursor(_snapshot, _requested), do: :error

  defp valid_subscribe_snapshot?(%{mode: :snapshot, reset: false}, nil), do: true

  defp valid_subscribe_snapshot?(
         %{mode: :replay, reset: false, first_available_seq: first, last_seq: last},
         requested
       )
       when is_integer(requested) and is_integer(first) and is_integer(last),
       do: requested >= first - 1 and requested <= last

  defp valid_subscribe_snapshot?(
         %{mode: :snapshot, reset: true, first_available_seq: first},
         requested
       )
       when is_integer(requested) and is_integer(first),
       do: requested < first - 1

  defp valid_subscribe_snapshot?(_snapshot, _requested), do: false

  defp protocol_violation(code, request_id, state) do
    violations = state.violations + 1
    state = %{state | violations: violations}

    if violations > state.policy.max_protocol_violations do
      close(1008, state)
    else
      command_error(code, request_id, state)
    end
  end

  defp command_error(code, request_id, state) do
    case Wire.error(code, request_id, state.policy) do
      {:ok, encoded} -> push(encoded, state)
      {:error, _reason} -> close(1011, state)
    end
  end

  defp pull_run(run_id, state) do
    cursor = Map.fetch!(state.cursors, run_id)

    case RunManager.pull(state.manager, run_id, cursor) do
      {:ok, pull} -> handle_pull(run_id, cursor, pull, state)
      {:reset, snapshot} -> handle_reset(run_id, cursor, snapshot, state)
      {:error, :run_not_found} -> {:ok, drop_run(state, run_id)}
      {:error, reason} when reason in [:invalid_cursor, :internal_error] -> close(1011, state)
      _invalid -> close(1011, state)
    end
  end

  defp handle_pull(run_id, previous_cursor, pull, state) do
    if valid_pull?(pull, run_id, previous_cursor, state.policy) do
      next = %{state | cursors: Map.put(state.cursors, run_id, pull.cursor)}
      next = if pull.more?, do: enqueue_pull(next, run_id), else: next

      case pull.messages do
        [] -> {:ok, next}
        messages -> {:push, Enum.map(messages, &{:text, &1}), next}
      end
    else
      close(1011, state)
    end
  end

  defp handle_reset(run_id, previous_cursor, snapshot, state) do
    with true <-
           is_map(snapshot) and not is_struct(snapshot) and snapshot[:run_id] == run_id and
             snapshot[:mode] == :snapshot and snapshot[:reset] == true and
             is_integer(snapshot[:first_available_seq]) and
             previous_cursor < snapshot[:first_available_seq] - 1,
         {:ok, cursor} <- valid_cursor(snapshot[:last_seq]),
         {:ok, encoded} <- Wire.async_snapshot(snapshot, state.policy) do
      push(encoded, %{state | cursors: Map.put(state.cursors, run_id, cursor)})
    else
      _invalid -> close(1011, state)
    end
  end

  defp valid_pull?(pull, run_id, previous_cursor, policy)
       when is_map(pull) and not is_struct(pull) do
    with true <- Map.keys(pull) |> Enum.sort() == [:cursor, :messages, :more?],
         %{messages: messages, cursor: cursor, more?: more?} <- pull,
         true <- Validation.proper_list?(messages, policy.max_pull_events),
         true <- length(messages) <= policy.max_pull_events,
         true <- is_boolean(more?),
         true <- messages != [] or not more?,
         true <- valid_encoded_batch?(messages, run_id, previous_cursor, policy),
         expected_cursor <- previous_cursor + length(messages),
         true <- expected_cursor <= 9_223_372_036_854_775_807,
         true <- cursor == expected_cursor do
      true
    else
      _invalid -> false
    end
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  defp valid_pull?(_pull, _run_id, _previous_cursor, _policy), do: false

  defp valid_encoded_batch?(messages, run_id, previous_cursor, policy) do
    messages
    |> Enum.with_index(1)
    |> Enum.reduce_while(0, fn {encoded, offset}, bytes ->
      binary = IO.iodata_to_binary(encoded)
      size = byte_size(binary)

      if String.valid?(binary) and
           valid_async_envelope?(binary, run_id, previous_cursor + offset, policy) and
           size <= policy.max_outgoing_message_bytes and bytes + size <= policy.max_pull_bytes,
         do: {:cont, bytes + size},
         else: {:halt, :error}
    end) != :error
  end

  defp valid_async_envelope?(encoded, run_id, seq, policy) do
    case JSON.decode(encoded) do
      {:ok,
       %{
         "version" => 1,
         "type" => "run.event",
         "request_id" => nil,
         "payload" => %{"run_id" => ^run_id, "seq" => ^seq, "event" => event} = payload
       } = envelope} ->
        map_size(envelope) == 4 and map_size(payload) == 3 and
          valid_event_payload?(event, policy)

      {:ok,
       %{
         "version" => 1,
         "type" => "run.terminal",
         "request_id" => nil,
         "payload" =>
           %{
             "run_id" => ^run_id,
             "seq" => ^seq,
             "status" => status,
             "result" => result,
             "error" => error
           } = payload
       } = envelope} ->
        map_size(envelope) == 4 and map_size(payload) == 5 and
          valid_terminal_payload?(status, result, error, run_id, policy)

      _invalid ->
        false
    end
  end

  defp valid_event_payload?(%{"type" => "run.started", "model" => model} = event, policy),
    do: map_size(event) == 2 and model in policy.model_allowlist

  defp valid_event_payload?(
         %{
           "type" => "turn.started",
           "turn" => turn,
           "operation_id" => operation_id
         } = event,
         policy
       ),
       do:
         map_size(event) == 3 and positive_counter?(turn) and
           Validation.identifier?(operation_id, policy.max_operation_id_bytes)

  defp valid_event_payload?(
         %{
           "type" => "text.delta",
           "turn" => turn,
           "operation_id" => operation_id,
           "item_id" => item_id,
           "content_index" => content_index,
           "delta" => delta
         } = event,
         policy
       ),
       do:
         map_size(event) == 6 and positive_counter?(turn) and
           Validation.identifier?(operation_id, policy.max_operation_id_bytes) and
           Validation.identifier?(item_id, 512) and counter?(content_index) and
           bounded_string?(delta, true, policy.max_outgoing_message_bytes)

  defp valid_event_payload?(
         %{
           "type" => type,
           "turn" => turn,
           "operation_id" => operation_id,
           "call_id" => call_id,
           "name" => name,
           "ordinal" => ordinal,
           "arguments" => arguments
         } = event,
         policy
       )
       when type == "tool.started",
       do:
         map_size(event) == 7 and
           valid_tool_identity?(turn, operation_id, call_id, name, ordinal, policy) and
           valid_tool_arguments?(arguments)

  defp valid_event_payload?(
         %{
           "type" => "tool.completed",
           "turn" => turn,
           "operation_id" => operation_id,
           "call_id" => call_id,
           "name" => name,
           "ordinal" => ordinal,
           "status" => status,
           "metadata" => metadata,
           "content" => content
         } = event,
         policy
       ),
       do:
         map_size(event) == 9 and
           valid_tool_identity?(turn, operation_id, call_id, name, ordinal, policy) and
           status in ["ok", "error", "ambiguous"] and valid_tool_metadata?(metadata, name) and
           valid_tool_content?(content)

  defp valid_event_payload?(
         %{
           "type" => "turn.completed",
           "turn" => turn,
           "outcome" => outcome,
           "provider_attempts" => provider_attempts,
           "tool_calls" => tool_calls,
           "output_bytes" => output_bytes
         } = event,
         _policy
       ),
       do:
         map_size(event) == 6 and positive_counter?(turn) and
           outcome in ["continued", "completed", "failed", "interrupted"] and
           positive_counter?(provider_attempts) and counter?(tool_calls) and
           counter?(output_bytes)

  defp valid_event_payload?(%{"type" => "run.owner_lost"} = event, _policy),
    do: map_size(event) == 1

  defp valid_event_payload?(_event, _policy), do: false

  defp valid_terminal_payload?("completed", result, nil, _run_id, policy),
    do: valid_result_payload?(result, policy)

  defp valid_terminal_payload?(status, nil, error, run_id, _policy)
       when status in ["failed", "interrupted"],
       do: valid_error_payload?(error, run_id, status)

  defp valid_terminal_payload?(_status, _result, _error, _run_id, _policy), do: false

  defp valid_result_payload?(
         %{
           "text" => text,
           "turns" => turns,
           "tool_calls" => tool_calls,
           "provider_retries" => provider_retries,
           "output_bytes" => output_bytes
         } = result,
         policy
       ),
       do:
         map_size(result) == 5 and
           bounded_string?(text, false, policy.max_projection_text_bytes) and
           positive_counter?(turns) and counter?(tool_calls) and counter?(provider_retries) and
           counter?(output_bytes) and output_bytes >= byte_size(text)

  defp valid_result_payload?(_result, _policy), do: false

  defp valid_error_payload?(
         %{
           "source" => "agent",
           "kind" => kind,
           "reason" => reason,
           "message" => message,
           "turn" => turn,
           "operation_id" => operation_id,
           "details" => details
         } = error,
         run_id,
         _status
       ) do
    with true <- map_size(error) == 7,
         kind when is_atom(kind) <- Map.get(@agent_kinds, kind),
         reason when is_atom(reason) <- Map.get(@agent_reasons, reason),
         {:ok, _error} <-
           AgentError.new(
             kind: kind,
             reason: reason,
             message: message,
             run_id: run_id,
             turn: turn,
             operation_id: operation_id,
             details: details
           ) do
      true
    else
      _invalid -> false
    end
  end

  defp valid_error_payload?(
         %{
           "source" => "runtime",
           "reason" => reason,
           "message" => message
         } = error,
         run_id,
         status
       ) do
    with true <- map_size(error) == 3,
         {expected_message, expected_status} <- Map.get(@runtime_errors, reason) do
      message == expected_message and status == expected_status and is_binary(run_id)
    else
      _invalid -> false
    end
  end

  defp valid_error_payload?(
         %{
           "source" => "api",
           "reason" => "internal_contract_failed",
           "message" => message
         } = error,
         _run_id,
         status
       ),
       do:
         map_size(error) == 3 and status == "interrupted" and
           message == "Run settlement contract failed"

  defp valid_error_payload?(_error, _run_id, _status), do: false

  defp valid_tool_identity?(turn, operation_id, call_id, name, ordinal, policy),
    do:
      positive_counter?(turn) and
        Validation.identifier?(operation_id, policy.max_operation_id_bytes) and
        Validation.identifier?(call_id, policy.max_call_id_bytes) and
        Validation.identifier?(name, policy.max_tool_name_bytes) and positive_counter?(ordinal)

  defp valid_tool_metadata?(metadata, name) when is_map(metadata) and not is_struct(metadata) do
    Map.keys(metadata) |> Enum.sort() ==
      Map.keys(Map.take(metadata, ["tool", "outcome"])) |> Enum.sort() and
      (not Map.has_key?(metadata, "tool") or metadata["tool"] == name) and
      (not Map.has_key?(metadata, "outcome") or
         metadata["outcome"] in ["completed", "not_applied", "not_applicable", "unknown"])
  end

  defp valid_tool_metadata?(_metadata, _name), do: false

  defp valid_tool_arguments?(arguments) do
    limits = Limits.default()

    Validation.bounded_json_object?(
      arguments,
      limits.max_argument_json_bytes,
      limits.max_argument_entries,
      limits.max_argument_depth
    )
  end

  defp valid_tool_content?(content) do
    limits = Limits.default()
    bounded_string?(content, true, limits.max_result_content_bytes)
  end

  defp bounded_string?(value, empty?, maximum),
    do:
      is_binary(value) and String.valid?(value) and byte_size(value) <= maximum and
        (empty? or value != "")

  defp positive_counter?(value), do: Validation.int64?(value) and value > 0
  defp counter?(value), do: Validation.int64?(value) and value >= 0

  defp valid_cursor(cursor) do
    if Validation.int64?(cursor) and cursor >= 0, do: {:ok, cursor}, else: :error
  end

  defp enqueue_pull(state, run_id) do
    state =
      if run_id in state.pending_pulls,
        do: state,
        else: %{state | pending_pulls: state.pending_pulls ++ [run_id]}

    if state.continuation_scheduled do
      state
    else
      send(self(), @continue_pull)
      %{state | continuation_scheduled: true}
    end
  end

  defp continue_pending({:ok, state}), do: {:ok, schedule_pending(state)}

  defp continue_pending({:push, messages, state}),
    do: {:push, messages, schedule_pending(state)}

  defp continue_pending(result), do: result

  defp schedule_pending(%State{pending_pulls: [_run_id | _rest]} = state) do
    if state.continuation_scheduled do
      state
    else
      send(self(), @continue_pull)
      %{state | continuation_scheduled: true}
    end
  end

  defp schedule_pending(state), do: state

  defp drop_run(state, run_id) do
    %{
      state
      | cursors: Map.delete(state.cursors, run_id),
        pending_pulls: List.delete(state.pending_pulls, run_id)
    }
  end

  defp initial_state(manager, policy) do
    %State{
      manager: manager,
      policy: policy,
      cursors: %{},
      pending_pulls: [],
      continuation_scheduled: false,
      violations: 0
    }
  end

  defp push(encoded, state), do: {:push, {:text, encoded}, state}
  defp close(code, state), do: {:stop, :normal, code, state}

  defp valid_manager?(manager),
    do:
      is_pid(manager) or is_atom(manager) or match?({:global, _term}, manager) or
        match?({:via, _module, _term}, manager)
end

defimpl Inspect, for: Synapse.API.Socket.Arguments do
  def inspect(_arguments, _options), do: "#Synapse.API.Socket.Arguments<redacted>"
end

defimpl Inspect, for: Synapse.API.Socket.State do
  def inspect(state, _options) do
    if Synapse.API.Socket.State.valid?(state) do
      "#Synapse.API.Socket.State<subscriptions=#{map_size(state.cursors)} pending_pulls=#{length(state.pending_pulls)} violations=#{state.violations} redacted>"
    else
      "#Synapse.API.Socket.State<invalid redacted>"
    end
  end
end
