defmodule Synapse.API.RunManager.State do
  @moduledoc false

  @enforce_keys [
    :config,
    :runs,
    :active_run_id,
    :aggregate_bytes,
    :next_created_ordinal,
    :next_completed_ordinal,
    :session_starter,
    :id_generator,
    :cancel_run
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          config: Synapse.API.Config.t(),
          runs: %{optional(String.t()) => Synapse.API.RunRecord.t()},
          active_run_id: String.t() | nil,
          aggregate_bytes: non_neg_integer(),
          next_created_ordinal: non_neg_integer(),
          next_completed_ordinal: non_neg_integer(),
          session_starter: (pid(), String.t(), struct() -> term()),
          id_generator: (-> term()),
          cancel_run: (Synapse.Runtime.Run.t() -> term())
        }
end

defmodule Synapse.API.RunManager do
  @moduledoc """
  Ephemeral bounded projection, replay, and subscription owner for the local API.

  RunManager serializes one active API reservation, ordered Runtime progress,
  cleanup-gated terminal confirmation, retained replay, subscriber cursors, and
  completed-run eviction. It does not own Runtime await authority and never invokes
  WebSock or pushes a frame directly; it sends at most one coalesced wakeup to each
  subscriber, which then pulls bounded encoded frames. Runtime event recording uses
  an unbounded OTP call timeout because a local timeout could otherwise report sink
  failure after the same event was committed.

  A trusted session-admission callback keeps supervision outside this state owner.
  Production supplies the RunSession starter through the named SessionSupervisor;
  isolated tests may inject a starter. Losing Manager intentionally loses every
  run ID, projection, sequence, replay entry, terminal, and subscription. The API
  supervisor then replaces Manager, SessionSupervisor, and Bandit; no temporary
  run work is replayed.

  Sequence state stores the last exposed value, initially zero. Ordinary progress
  leaves the highest two signed-64-bit values for owner loss and terminal
  settlement. Replay is a sliding prefix-evicted queue including the terminal;
  completed snapshots also retain the exact confirmed terminal separately.

  Subscription without a cursor returns an authoritative snapshot. A retained
  cursor returns replay, a future cursor is rejected, and a cursor that becomes
  stale before pull receives an asynchronous authoritative reset. Pull advances
  only the caller's acknowledged cursor and clears its one outstanding wakeup
  flag atomically when caught up. Completed records are evicted oldest-first for
  both count and aggregate-byte pressure. All subscription operations derive
  ownership from the `GenServer.call/3` caller, so subscribe, pull, and unsubscribe
  must come from the same Socket process.

  See the [local API guide](api.html) for event, cancellation, replay, failure, and
  authority traces.
  """

  use GenServer

  alias Synapse.Agent.{Error, Result}
  alias Synapse.API.Command.Start

  alias Synapse.API.{
    ActiveTool,
    Config,
    ConfirmedTerminal,
    PendingTerminal,
    ReplayEntry,
    RunRecord,
    Subscriber,
    Wire
  }

  alias Synapse.API.RunManager.State
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

  alias Synapse.Runtime
  alias Synapse.Runtime.Error, as: RuntimeError
  alias Synapse.Runtime.Run
  alias Synapse.Tool.Validation

  @max_int 9_223_372_036_854_775_807
  @last_ordinary_seq @max_int - 2
  @max_id_attempts 8

  @typedoc "A named or isolated RunManager server reference."
  @type server :: GenServer.server()

  @typedoc "An immediate subscription acknowledgement or authoritative projection."
  @type snapshot :: %{
          mode: :snapshot | :replay,
          reset: boolean(),
          run_id: String.t(),
          first_available_seq: pos_integer(),
          last_seq: non_neg_integer(),
          projection: map() | nil,
          terminal: ConfirmedTerminal.t() | nil
        }
  @typedoc "One bounded contiguous replay batch and its acknowledged cursor."
  @type pull :: %{messages: [iodata()], cursor: non_neg_integer(), more?: boolean()}

  @doc "Starts one named or isolated Manager with trusted Config and dependencies."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    start_options = if is_nil(name), do: [], else: [name: name]
    GenServer.start_link(__MODULE__, options, start_options)
  end

  @doc "Atomically reserves one run, subscribes the calling Socket, and admits its session."
  @spec start_run(server(), struct()) ::
          {:ok, String.t()}
          | {:error, :run_busy | :subscription_limit | :runtime_unavailable | :internal_error}
  def start_run(server, %Start{} = command),
    do: safe_call(server, {:start_run, command}, {:error, :internal_error})

  def start_run(_server, _command), do: {:error, :internal_error}

  @doc "Records idempotent cancellation intent and delegates through a registered handle."
  @spec cancel(server(), String.t()) ::
          {:ok, :cancel_requested | :already_terminal}
          | {:error, :run_not_found | :internal_error}
  def cancel(server, run_id),
    do: safe_call(server, {:cancel, run_id}, {:error, :internal_error})

  @doc "Subscribes the calling Socket and returns a snapshot or replay acknowledgement."
  @spec subscribe(server(), String.t(), non_neg_integer() | nil) ::
          {:ok, snapshot()}
          | {:error, :run_not_found | :invalid_cursor | :subscription_limit | :internal_error}
  def subscribe(server, run_id, after_seq),
    do: safe_call(server, {:subscribe, run_id, after_seq}, {:error, :internal_error})

  @doc "Pulls for that same Socket, or returns an authoritative stale-cursor reset."
  @spec pull(server(), String.t(), non_neg_integer()) ::
          {:ok, pull()}
          | {:reset, snapshot()}
          | {:error, :run_not_found | :invalid_cursor | :internal_error}
  def pull(server, run_id, cursor),
    do: safe_call(server, {:pull, run_id, cursor}, {:error, :internal_error})

  @doc "Removes the caller's subscription to one retained run."
  @spec unsubscribe(server(), String.t()) :: :ok
  def unsubscribe(server, run_id), do: safe_call(server, {:unsubscribe, run_id}, :ok)

  @doc "Removes every subscription owned by the caller."
  @spec unsubscribe_all(server()) :: :ok
  def unsubscribe_all(server), do: safe_call(server, :unsubscribe_all, :ok)

  @doc false
  @spec unsubscribe_all_async(server()) :: :ok
  def unsubscribe_all_async(server) do
    GenServer.cast(server, {:unsubscribe_all, self()})
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  @doc "Registers cancellation authority only when called by the admitted RunSession."
  @spec register_runtime_run(server(), String.t(), Run.t()) :: :ok | {:error, :closed}
  def register_runtime_run(server, run_id, %Run{} = run),
    do: safe_call(server, {:register_runtime_run, run_id, run}, {:error, :closed})

  def register_runtime_run(_server, _run_id, _run), do: {:error, :closed}

  @doc "Synchronously records one Runtime Run Event without ambiguous timeout recovery."
  @spec record_event(server(), Event.t()) :: :ok | {:error, :closed}
  def record_event(server, event),
    do: safe_call(server, {:record_event, event}, {:error, :closed})

  @doc "Confirms cleanup-gated settlement only from the admitted RunSession caller."
  @spec settle(server(), String.t(), {:ok, Result.t()} | {:error, Error.t() | RuntimeError.t()}) ::
          :ok | {:error, :closed}
  def settle(server, run_id, settlement),
    do: safe_call(server, {:settle, run_id, settlement}, {:error, :closed})

  @impl true
  def init(options) do
    config = Keyword.get(options, :config, Config.default())
    session_starter = Keyword.get(options, :session_starter, &unavailable_session/3)
    id_generator = Keyword.get(options, :id_generator, &generate_run_id/0)
    cancel_run = Keyword.get(options, :cancel_run, &Runtime.cancel/1)

    if Config.valid?(config) and is_function(session_starter, 3) and is_function(id_generator, 0) and
         is_function(cancel_run, 1) do
      {:ok,
       %State{
         config: config,
         runs: %{},
         active_run_id: nil,
         aggregate_bytes: 0,
         next_created_ordinal: 0,
         next_completed_ordinal: 0,
         session_starter: session_starter,
         id_generator: id_generator,
         cancel_run: cancel_run
       }}
    else
      {:stop, :invalid_api_config}
    end
  end

  @impl true
  def handle_call({:start_run, command}, {socket, _tag}, state) do
    reply_start(socket, command, state)
  end

  def handle_call({:cancel, run_id}, _from, state) do
    case Map.fetch(state.runs, run_id) do
      :error ->
        {:reply, {:error, :run_not_found}, state}

      {:ok, %RunRecord{terminal: %ConfirmedTerminal{}}} ->
        {:reply, {:ok, :already_terminal}, state}

      {:ok, record} ->
        record = mark_cancel_requested(record)
        cancel_runtime(record, state.cancel_run)
        {:reply, {:ok, :cancel_requested}, put_record(state, record)}
    end
  end

  def handle_call({:subscribe, run_id, after_seq}, {socket, _tag}, state) do
    case subscribe_socket(state, run_id, after_seq, socket) do
      {:ok, snapshot, state} -> {:reply, {:ok, snapshot}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:pull, run_id, cursor}, {socket, _tag}, state) do
    case pull_messages(state, run_id, cursor, socket) do
      {:ok, pull, state} -> {:reply, {:ok, pull}, state}
      {:reset, snapshot, state} -> {:reply, {:reset, snapshot}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:unsubscribe, run_id}, {socket, _tag}, state),
    do: {:reply, :ok, unsubscribe_socket(state, run_id, socket)}

  def handle_call(:unsubscribe_all, {socket, _tag}, state),
    do: {:reply, :ok, unsubscribe_all_socket(state, socket)}

  def handle_call({:register_runtime_run, run_id, run}, {session, _tag}, state) do
    case Map.fetch(state.runs, run_id) do
      {:ok, %RunRecord{session_pid: ^session, terminal: nil} = record} ->
        if valid_registered_run?(run, run_id, session, record.runtime_run) do
          record = %{record | runtime_run: run}
          if record.cancel_requested, do: cancel_runtime(record, state.cancel_run)
          {:reply, :ok, put_record(state, record)}
        else
          {:reply, {:error, :closed}, state}
        end

      _invalid ->
        {:reply, {:error, :closed}, state}
    end
  end

  def handle_call({:record_event, event}, _from, state) do
    case safe_record_event_call(state, event) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, state} -> {:reply, {:error, :closed}, state}
    end
  end

  def handle_call({:settle, run_id, settlement}, {session, _tag}, state) do
    case Map.fetch(state.runs, run_id) do
      {:ok, %RunRecord{session_pid: ^session, terminal: nil} = record} ->
        case terminal_from_settlement(record, settlement, state.config) do
          {:ok, terminal_kind} ->
            case expose_terminal(state, record, terminal_kind) do
              {:ok, state} -> {:reply, :ok, state}
              {:error, state} -> {:reply, {:error, :closed}, state}
            end

          :mismatch ->
            cancel_runtime(record, state.cancel_run)

            case expose_terminal(state, record, :internal_contract_failed) do
              {:ok, state} -> {:reply, :ok, state}
              {:error, state} -> {:reply, {:error, :closed}, state}
            end
        end

      _invalid ->
        {:reply, {:error, :closed}, state}
    end
  end

  def handle_call(_message, _from, state), do: {:reply, {:error, :internal_error}, state}

  @impl true
  def handle_cast({:unsubscribe_all, socket}, state) when is_pid(socket),
    do: {:noreply, unsubscribe_all_socket(state, socket)}

  def handle_cast(_message, state), do: {:noreply, state}

  defp safe_record_event_call(state, event) do
    record_event_call(state, event)
  rescue
    _exception -> reject_malformed_event(state, event)
  catch
    _kind, _reason -> reject_malformed_event(state, event)
  end

  defp reject_malformed_event(state, %{run_id: run_id}) do
    case Map.fetch(state.runs, run_id) do
      {:ok, record} -> reject_sink(state, record)
      :error -> {:error, state}
    end
  end

  defp reject_malformed_event(state, _event), do: {:error, state}

  @impl true
  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    case find_session(state.runs, monitor, pid) do
      {:ok, record} -> {:noreply, session_down(state, record)}
      :error -> {:noreply, subscriber_down(state, monitor, pid)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def format_status(status) when is_map(status) do
    Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted, log: []})
  end

  @impl true
  def format_status(_reason, [_process_dictionary, _state]),
    do: [data: [{~c"State", :redacted}]]

  defp reply_start(socket, %Start{} = command, state) do
    cond do
      not Start.valid?(command, state.config) ->
        {:reply, {:error, :internal_error}, state}

      subscription_count(state.runs, socket) >= state.config.max_subscriptions_per_socket ->
        {:reply, {:error, :subscription_limit}, state}

      not is_nil(state.active_run_id) ->
        {:reply, {:error, :run_busy}, state}

      true ->
        admit_run(socket, command, state)
    end
  end

  defp admit_run(socket, command, state) do
    with {:ok, state} <- ensure_created_ordinal(state),
         {:ok, run_id} <- unique_run_id(state),
         {:ok, record} <- RunRecord.new(run_id, state.next_created_ordinal, state.config),
         {:ok, candidate, evicted, subscriber_monitor} <- reserve_run(state, record, socket) do
      case start_session(state.session_starter, self(), run_id, command) do
        {:ok, session} ->
          session_monitor = Process.monitor(session)

          record = %{
            Map.fetch!(candidate.runs, run_id)
            | session_pid: session,
              session_monitor: session_monitor
          }

          candidate = %{
            candidate
            | runs: Map.put(candidate.runs, run_id, record),
              next_created_ordinal: state.next_created_ordinal + 1
          }

          cleanup_evicted(evicted)
          {:reply, {:ok, run_id}, candidate}

        {:error, :runtime_unavailable} ->
          Process.demonitor(subscriber_monitor, [:flush])
          {:reply, {:error, :runtime_unavailable}, state}
      end
    else
      _invalid ->
        {:reply, {:error, :internal_error}, state}
    end
  end

  defp reserve_run(state, record, socket) do
    monitor = Process.monitor(socket)

    result =
      with {:ok, subscriber} <-
             Subscriber.new(pid: socket, monitor: monitor, cursor: 0, notified: false),
           record <- add_subscriber(record, subscriber),
           true <- RunRecord.valid?(record, state.config),
           candidate <-
             %{state | runs: Map.put(state.runs, record.id, record), active_run_id: record.id}
             |> update_aggregate(),
           {:ok, candidate, evicted} <- retention_plan(candidate, MapSet.new([record.id])) do
        {:ok, candidate, evicted, monitor}
      else
        _invalid -> {:error, :reservation_failed}
      end

    if match?({:error, _reason}, result), do: Process.demonitor(monitor, [:flush])
    result
  end

  defp start_session(starter, manager, run_id, command) do
    case starter.(manager, run_id, command) do
      {:ok, pid} when is_pid(pid) -> {:ok, pid}
      {:ok, pid, _info} when is_pid(pid) -> {:ok, pid}
      _invalid -> {:error, :runtime_unavailable}
    end
  rescue
    _exception -> {:error, :runtime_unavailable}
  catch
    _kind, _reason -> {:error, :runtime_unavailable}
  end

  defp unique_run_id(state), do: unique_run_id(state, @max_id_attempts)
  defp unique_run_id(_state, 0), do: {:error, :id_generation_failed}

  defp unique_run_id(state, attempts) do
    run_id = state.id_generator.()

    if Synapse.API.Command.Cancel.valid_run_id?(run_id, state.config) and
         not Map.has_key?(state.runs, run_id),
       do: {:ok, run_id},
       else: unique_run_id(state, attempts - 1)
  rescue
    _exception -> {:error, :id_generation_failed}
  catch
    _kind, _reason -> {:error, :id_generation_failed}
  end

  defp ensure_created_ordinal(%State{next_created_ordinal: value} = state) when value < @max_int,
    do: {:ok, state}

  defp ensure_created_ordinal(state), do: {:ok, rebase_ordinals(state, :created_ordinal)}

  defp ensure_completed_ordinal(%State{next_completed_ordinal: value} = state)
       when value < @max_int,
       do: {:ok, state}

  defp ensure_completed_ordinal(state), do: {:ok, rebase_ordinals(state, :completed_ordinal)}

  defp rebase_ordinals(state, field) do
    records =
      state.runs
      |> Map.values()
      |> Enum.filter(&(not is_nil(Map.fetch!(&1, field))))
      |> Enum.sort_by(&Map.fetch!(&1, field))

    runs =
      records
      |> Enum.with_index()
      |> Enum.reduce(state.runs, fn {record, ordinal}, runs ->
        Map.put(runs, record.id, Map.put(record, field, ordinal))
      end)

    next_field =
      if field == :created_ordinal, do: :next_created_ordinal, else: :next_completed_ordinal

    %{state | runs: runs} |> Map.put(next_field, length(records))
  end

  defp record_event_call(state, %module{run_id: run_id} = event)
       when module in [RunCompleted, RunFailed, RunInterrupted] do
    case Map.fetch(state.runs, run_id) do
      {:ok, %RunRecord{terminal: nil, pending_terminal: nil} = record} ->
        case PendingTerminal.new(event, state.config) do
          {:ok, pending} when record.status == :owner_lost and is_nil(record.session_pid) ->
            expose_terminal(state, %{record | pending_terminal: pending}, {:pending, pending})

          {:ok, pending} ->
            {:ok, put_record(state, %{record | pending_terminal: pending})}

          {:error, _reason} ->
            reject_sink(state, record)
        end

      {:ok, record} ->
        reject_sink(state, record)

      :error ->
        {:error, state}
    end
  end

  defp record_event_call(state, %{run_id: run_id} = event) do
    case Map.fetch(state.runs, run_id) do
      {:ok, %RunRecord{terminal: nil, pending_terminal: nil, sink_rejected: false} = record}
      when record.status in [:starting, :running, :cancel_requested, :owner_lost] ->
        with {:ok, projection, changes} <- project_event(record, event, state.config),
             true <- record.last_seq < @last_ordinary_seq,
             seq <- record.last_seq + 1,
             {:ok, encoded} <- Wire.event(run_id, seq, event, state.config),
             true <- IO.iodata_length(encoded) <= state.config.max_pull_bytes,
             {:ok, entry} <-
               ReplayEntry.new(%{seq: seq, type: :event, encoded: encoded}, state.config),
             {:ok, replay, replay_bytes} <- append_replay(record, entry, state.config),
             candidate <-
               record
               |> Map.merge(changes)
               |> Map.merge(%{
                 projection: projection,
                 status: projection.status,
                 last_seq: seq,
                 replay: replay,
                 replay_bytes: replay_bytes
               })
               |> account_record(state.config),
             true <- RunRecord.valid?(candidate, state.config),
             candidate_state <- put_record(state, candidate),
             {:ok, candidate_state, evicted} <-
               retention_plan(candidate_state, MapSet.new([run_id])) do
          candidate_state = notify_subscribers(candidate_state, run_id)
          cleanup_evicted(evicted)
          {:ok, candidate_state}
        else
          _invalid -> reject_sink(state, record)
        end

      {:ok, record} ->
        reject_sink(state, record)

      :error ->
        {:error, state}
    end
  end

  defp record_event_call(state, _event), do: {:error, state}

  defp project_event(record, %RunStarted{} = event, config) do
    if not record.run_started and is_nil(record.open_turn) and event.run_id == record.id and
         event.model in config.model_allowlist do
      status =
        cond do
          record.status == :owner_lost -> :owner_lost
          record.cancel_requested -> :cancel_requested
          true -> :running
        end

      projection = %{record.projection | status: status, model: event.model}
      {:ok, projection, %{run_started: true}}
    else
      :error
    end
  end

  defp project_event(record, %TurnStarted{} = event, _config) do
    if record.run_started and is_nil(record.open_turn) and
         record.last_turn_outcome in [nil, :continued] and
         event.turn == record.last_completed_turn + 1 do
      projection = %{record.projection | turn: event.turn}

      {:ok, projection,
       %{open_turn: event.turn, provider_operation_id: event.operation_id, last_tool_ordinal: 0}}
    else
      :error
    end
  end

  defp project_event(record, %TextDelta{} = event, config) do
    text = record.projection.text <> event.delta

    if event.turn == record.open_turn and event.operation_id == record.provider_operation_id and
         is_nil(record.projection.active_tool) and is_nil(record.owner_lost_tool) and
         byte_size(text) <= config.max_projection_text_bytes and String.valid?(text) do
      {:ok, %{record.projection | text: text}, %{}}
    else
      :error
    end
  end

  defp project_event(record, %ToolStarted{} = event, config) do
    attrs = %{
      turn: event.turn,
      operation_id: event.operation_id,
      call_id: event.call_id,
      name: event.name,
      ordinal: event.ordinal
    }

    if event.turn == record.open_turn and is_nil(record.projection.active_tool) and
         is_nil(record.owner_lost_tool) and
         event.ordinal == record.last_tool_ordinal + 1 do
      case ActiveTool.new(attrs, config) do
        {:ok, tool} ->
          {:ok, %{record.projection | active_tool: tool}, %{last_tool_ordinal: event.ordinal}}

        {:error, _reason} ->
          :error
      end
    else
      :error
    end
  end

  defp project_event(record, %ToolCompleted{} = event, _config) do
    tool = record.projection.active_tool

    cond do
      match?(%ActiveTool{}, tool) and tool.turn == event.turn and
        tool.operation_id == event.operation_id and tool.call_id == event.call_id and
        tool.name == event.name and tool.ordinal == event.ordinal ->
        {:ok, %{record.projection | active_tool: nil}, %{}}

      record.status == :owner_lost and is_nil(tool) and
        match?(%ActiveTool{}, record.owner_lost_tool) and
        record.owner_lost_tool.turn == event.turn and
        record.owner_lost_tool.operation_id == event.operation_id and
        record.owner_lost_tool.call_id == event.call_id and
        record.owner_lost_tool.name == event.name and
          record.owner_lost_tool.ordinal == event.ordinal ->
        {:ok, record.projection, %{owner_lost_tool: nil}}

      true ->
        :error
    end
  end

  defp project_event(record, %TurnCompleted{} = event, _config) do
    projection = record.projection

    with true <- event.turn == record.open_turn,
         true <- is_nil(projection.active_tool) and is_nil(record.owner_lost_tool),
         {:ok, provider_attempts} <-
           checked_add(projection.provider_attempts, event.provider_attempts),
         {:ok, tool_calls} <- checked_add(projection.tool_calls, event.tool_calls),
         {:ok, output_bytes} <- checked_add(projection.output_bytes, event.output_bytes) do
      projection = %{
        projection
        | provider_attempts: provider_attempts,
          tool_calls: tool_calls,
          output_bytes: output_bytes
      }

      {:ok, projection,
       %{
         open_turn: nil,
         provider_operation_id: nil,
         last_completed_turn: event.turn,
         last_turn_outcome: event.outcome
       }}
    else
      _invalid -> :error
    end
  end

  defp project_event(_record, _event, _config), do: :error

  defp checked_add(left, right) when is_integer(left) and is_integer(right) do
    value = left + right
    if value <= @max_int, do: {:ok, value}, else: :error
  end

  defp append_replay(record, entry, config) do
    entries = :queue.to_list(record.replay)
    trim_replay(entries, record.replay_bytes, entry, config)
  end

  defp trim_replay(entries, bytes, entry, config) do
    if length(entries) + 1 <= config.max_replay_events and
         bytes + entry.accounted_bytes <= config.max_replay_bytes do
      {:ok, :queue.from_list(entries ++ [entry]), bytes + entry.accounted_bytes}
    else
      case entries do
        [oldest | rest] -> trim_replay(rest, bytes - oldest.accounted_bytes, entry, config)
        [] -> {:error, :entry_does_not_fit}
      end
    end
  end

  defp reject_sink(state, %RunRecord{terminal: nil} = record) do
    record = record |> mark_cancel_requested() |> Map.put(:sink_rejected, true)
    cancel_runtime(record, state.cancel_run)
    {:error, put_record(state, record)}
  end

  defp reject_sink(state, _record), do: {:error, state}

  defp mark_cancel_requested(%RunRecord{status: :owner_lost} = record),
    do: %{record | cancel_requested: true}

  defp mark_cancel_requested(record),
    do: %{
      record
      | cancel_requested: true,
        status: :cancel_requested,
        projection: %{record.projection | status: :cancel_requested}
    }

  defp terminal_from_settlement(record, settlement, config) do
    cond do
      matching_pending?(record.pending_terminal, settlement, config) ->
        {:ok, {:pending, record.pending_terminal}}

      is_nil(record.pending_terminal) and match?({:error, %RuntimeError{}}, settlement) ->
        {:error, error} = settlement

        if RuntimeError.valid?(error) and (is_nil(error.run_id) or error.run_id == record.id),
          do: {:ok, {:runtime, error}},
          else: :mismatch

      is_nil(record.pending_terminal) and record.sink_rejected and
          match?({:error, %Error{reason: :event_sink_failed}}, settlement) ->
        {:error, error} = settlement
        pending = %PendingTerminal{run_id: record.id, status: :failed, result: nil, error: error}

        if PendingTerminal.valid?(pending, config),
          do: {:ok, {:pending, pending}},
          else: :mismatch

      true ->
        :mismatch
    end
  end

  defp matching_pending?(nil, _settlement, _config), do: false

  defp matching_pending?(
         %PendingTerminal{status: :completed} = pending,
         {:ok, %Result{} = result},
         config
       ) do
    case Event.new(:run_completed, run_id: pending.run_id, result: result) do
      {:ok, event} -> match?({:ok, ^pending}, PendingTerminal.new(event, config))
      {:error, _reason} -> false
    end
  end

  defp matching_pending?(
         %PendingTerminal{status: status} = pending,
         {:error, %Error{} = error},
         config
       )
       when status in [:failed, :interrupted] do
    kind = if status == :failed, do: :run_failed, else: :run_interrupted

    case Event.new(kind, run_id: pending.run_id, error: error) do
      {:ok, event} -> match?({:ok, ^pending}, PendingTerminal.new(event, config))
      {:error, _reason} -> false
    end
  end

  defp matching_pending?(_pending, _settlement, _config), do: false

  defp expose_terminal(state, record, terminal_kind) do
    with true <- record.last_seq < @max_int,
         {:ok, state} <- ensure_completed_ordinal(state),
         seq <- record.last_seq + 1,
         {:ok, terminal} <- confirmed_terminal(terminal_kind, record.id, seq, state.config),
         {:ok, encoded} <- Wire.terminal(terminal, state.config),
         true <- IO.iodata_length(encoded) <= state.config.max_pull_bytes,
         {:ok, entry} <-
           ReplayEntry.new(%{seq: seq, type: :terminal, encoded: encoded}, state.config),
         {:ok, replay, replay_bytes} <- append_replay(record, entry, state.config),
         projection <- terminal_projection(record.projection, terminal),
         record <- clear_session_monitor(record),
         record <-
           %{
             record
             | status: terminal.status,
               projection: projection,
               open_turn: nil,
               provider_operation_id: nil,
               owner_lost_tool: nil,
               last_completed_turn: projection.turn,
               last_turn_outcome: terminal_outcome(terminal),
               pending_terminal: nil,
               terminal: terminal,
               replay: replay,
               replay_bytes: replay_bytes,
               last_seq: seq,
               session_pid: nil,
               session_monitor: nil,
               runtime_run: nil,
               completed_ordinal: state.next_completed_ordinal
           }
           |> account_record(state.config),
         true <- RunRecord.valid?(record, state.config),
         candidate <-
           %{
             state
             | runs: Map.put(state.runs, record.id, record),
               active_run_id: nil,
               next_completed_ordinal: state.next_completed_ordinal + 1
           }
           |> update_aggregate(),
         {:ok, candidate, evicted} <- retention_plan(candidate, MapSet.new([record.id])) do
      cleanup_evicted(evicted)
      {:ok, notify_subscribers(candidate, record.id)}
    else
      _invalid -> reject_sink(state, record)
    end
  end

  defp confirmed_terminal({:pending, pending}, _run_id, seq, config),
    do: ConfirmedTerminal.from_pending(pending, seq, config)

  defp confirmed_terminal({:runtime, error}, run_id, seq, config),
    do: ConfirmedTerminal.from_runtime(run_id, seq, error, config)

  defp confirmed_terminal(:internal_contract_failed, run_id, seq, config),
    do: ConfirmedTerminal.internal_contract_failed(run_id, seq, config)

  defp terminal_projection(projection, %ConfirmedTerminal{status: :completed, result: result}) do
    %{
      projection
      | status: :completed,
        turn: result.turns,
        text: result.text,
        active_tool: nil,
        provider_attempts: result.turns + result.provider_retries,
        tool_calls: result.tool_calls,
        output_bytes: result.output_bytes
    }
  end

  defp terminal_projection(projection, %ConfirmedTerminal{status: status}),
    do: %{projection | status: status, active_tool: nil}

  defp terminal_outcome(%ConfirmedTerminal{status: :completed}), do: :completed
  defp terminal_outcome(%ConfirmedTerminal{status: :failed}), do: :failed
  defp terminal_outcome(%ConfirmedTerminal{status: :interrupted}), do: :interrupted

  defp clear_session_monitor(%RunRecord{session_monitor: nil} = record), do: record

  defp clear_session_monitor(%RunRecord{session_monitor: monitor} = record) do
    Process.demonitor(monitor, [:flush])
    record
  end

  defp session_down(state, record) do
    record = %{record | session_pid: nil, session_monitor: nil}
    cancel_runtime(record, state.cancel_run)
    state = put_record(state, record)

    if record.pending_terminal do
      case expose_terminal(state, record, {:pending, record.pending_terminal}) do
        {:ok, state} -> state
        {:error, state} -> state
      end
    else
      owner_lost(state, record)
    end
  end

  defp owner_lost(state, record) do
    if record.last_seq < @max_int - 1 do
      seq = record.last_seq + 1

      with {:ok, encoded} <- Wire.owner_lost(record.id, seq, state.config),
           {:ok, entry} <-
             ReplayEntry.new(%{seq: seq, type: :event, encoded: encoded}, state.config),
           {:ok, replay, replay_bytes} <- append_replay(record, entry, state.config) do
        projection = %{record.projection | status: :owner_lost, active_tool: nil}

        record =
          record
          |> Map.merge(%{
            status: :owner_lost,
            projection: projection,
            owner_lost_tool: record.projection.active_tool,
            last_seq: seq,
            replay: replay,
            replay_bytes: replay_bytes
          })
          |> account_record(state.config)

        candidate = put_record(state, record)

        with true <- RunRecord.valid?(record, state.config),
             {:ok, candidate, evicted} <- retention_plan(candidate, MapSet.new([record.id])) do
          cleanup_evicted(evicted)
          notify_subscribers(candidate, record.id)
        else
          _invalid -> put_record(state, %{mark_cancel_requested(record) | sink_rejected: true})
        end
      else
        _invalid -> put_record(state, %{mark_cancel_requested(record) | sink_rejected: true})
      end
    else
      put_record(state, %{mark_cancel_requested(record) | sink_rejected: true})
    end
  end

  defp find_session(runs, monitor, pid) do
    Enum.find_value(runs, :error, fn {_id, record} ->
      if record.session_monitor == monitor and record.session_pid == pid, do: {:ok, record}
    end)
  end

  defp subscriber_down(state, monitor, pid) do
    Enum.reduce(state.runs, state, fn {run_id, record}, current ->
      case record.subscribers[pid] do
        %Subscriber{monitor: ^monitor} -> unsubscribe_socket(current, run_id, pid, false)
        _subscriber -> current
      end
    end)
  end

  defp subscribe_socket(state, run_id, after_seq, socket) do
    with {:ok, record} <- fetch_run(state, run_id),
         true <- valid_cursor_input?(after_seq) or {:error, :invalid_cursor},
         true <- is_nil(after_seq) or after_seq <= record.last_seq or {:error, :invalid_cursor},
         existing <- Map.get(record.subscribers, socket),
         true <-
           not is_nil(existing) or
             subscription_count(state.runs, socket) < state.config.max_subscriptions_per_socket or
             {:error, :subscription_limit},
         true <-
           not is_nil(existing) or
             map_size(record.subscribers) < state.config.max_subscribers_per_run or
             {:error, :subscription_limit},
         {snapshot, cursor} <- subscription_snapshot(record, after_seq),
         {:ok, subscriber, new?} <- subscription_record(existing, socket, cursor, record.last_seq),
         record <- add_or_replace_subscriber(record, subscriber, new?),
         true <- RunRecord.valid?(record, state.config),
         candidate <- put_record(state, record),
         {:ok, candidate, evicted} <- retention_plan(candidate, MapSet.new([run_id])),
         candidate <- finalize_subscriber_monitor(candidate, run_id, socket, new?) do
      cleanup_evicted(evicted)
      {:ok, snapshot, candidate}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :internal_error}
      _invalid -> {:error, :internal_error}
    end
  end

  defp fetch_run(state, run_id) do
    case Map.fetch(state.runs, run_id) do
      {:ok, record} -> {:ok, record}
      :error -> {:error, :run_not_found}
    end
  end

  defp valid_cursor_input?(nil), do: true
  defp valid_cursor_input?(cursor), do: Validation.int64?(cursor) and cursor >= 0

  defp subscription_snapshot(record, nil),
    do: {snapshot(record, :snapshot, false), record.last_seq}

  defp subscription_snapshot(record, after_seq) do
    if stale_cursor?(record, after_seq),
      do: {snapshot(record, :snapshot, true), record.last_seq},
      else: {snapshot(record, :replay, false), after_seq}
  end

  defp subscription_record(nil, socket, cursor, last_seq) do
    monitor = make_ref()

    case Subscriber.new(
           pid: socket,
           monitor: monitor,
           cursor: cursor,
           notified: cursor < last_seq
         ) do
      {:ok, subscriber} ->
        {:ok, subscriber, true}

      {:error, _reason} ->
        {:error, :internal_error}
    end
  end

  defp subscription_record(%Subscriber{} = existing, _socket, cursor, last_seq),
    do:
      {:ok, %{existing | cursor: cursor, notified: existing.notified or cursor < last_seq}, false}

  defp add_subscriber(record, subscriber) do
    record
    |> Map.put(:subscribers, Map.put(record.subscribers, subscriber.pid, subscriber))
    |> Map.update!(:accounted_bytes, &(&1 + Config.subscriber_overhead_bytes()))
  end

  defp add_or_replace_subscriber(record, subscriber, true), do: add_subscriber(record, subscriber)

  defp add_or_replace_subscriber(record, subscriber, false),
    do: %{record | subscribers: Map.put(record.subscribers, subscriber.pid, subscriber)}

  defp finalize_subscriber_monitor(state, _run_id, _socket, false), do: state

  defp finalize_subscriber_monitor(state, run_id, socket, true) do
    monitor = Process.monitor(socket)
    record = Map.fetch!(state.runs, run_id)
    subscriber = %{Map.fetch!(record.subscribers, socket) | monitor: monitor}
    record = %{record | subscribers: Map.put(record.subscribers, socket, subscriber)}
    %{state | runs: Map.put(state.runs, run_id, record)}
  end

  defp pull_messages(state, run_id, cursor, socket) do
    with {:ok, record} <- fetch_run(state, run_id),
         %Subscriber{} = subscriber <- Map.get(record.subscribers, socket),
         true <- Validation.int64?(cursor) and cursor >= 0 and cursor == subscriber.cursor,
         true <- cursor <= record.last_seq do
      if stale_cursor?(record, cursor) do
        subscriber = %{subscriber | cursor: record.last_seq, notified: false}
        record = %{record | subscribers: Map.put(record.subscribers, socket, subscriber)}
        {:reset, snapshot(record, :snapshot, true), put_record(state, record)}
      else
        entries = record.replay |> :queue.to_list() |> Enum.filter(&(&1.seq > cursor))
        {selected, more?} = bounded_pull(entries, state.config)

        next_cursor =
          case List.last(selected) do
            nil -> cursor
            entry -> entry.seq
          end

        subscriber = %{subscriber | cursor: next_cursor, notified: more?}
        record = %{record | subscribers: Map.put(record.subscribers, socket, subscriber)}

        {:ok, %{messages: Enum.map(selected, & &1.encoded), cursor: next_cursor, more?: more?},
         put_record(state, record)}
      end
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_cursor}
    end
  end

  defp bounded_pull(entries, config) do
    {selected, _bytes, rest} =
      Enum.reduce_while(entries, {[], 0, entries}, fn entry, {selected, bytes, remaining} ->
        if length(selected) < config.max_pull_events and
             bytes + entry.encoded_bytes <= config.max_pull_bytes do
          {:cont, {selected ++ [entry], bytes + entry.encoded_bytes, tl(remaining)}}
        else
          {:halt, {selected, bytes, remaining}}
        end
      end)

    {selected, rest != []}
  end

  defp first_available_seq(record) do
    case :queue.peek(record.replay) do
      {:value, entry} -> entry.seq
      :empty -> record.last_seq + 1
    end
  end

  defp stale_cursor?(record, cursor), do: cursor < first_available_seq(record) - 1

  defp snapshot(record, :snapshot, reset) do
    %{
      mode: :snapshot,
      reset: reset,
      run_id: record.id,
      first_available_seq: first_available_seq(record),
      last_seq: record.last_seq,
      projection: record.projection,
      terminal: record.terminal
    }
  end

  defp snapshot(record, :replay, false) do
    %{
      mode: :replay,
      reset: false,
      run_id: record.id,
      first_available_seq: first_available_seq(record),
      last_seq: record.last_seq,
      projection: nil,
      terminal: nil
    }
  end

  defp unsubscribe_socket(state, run_id, socket),
    do: unsubscribe_socket(state, run_id, socket, true)

  defp unsubscribe_socket(state, run_id, socket, demonitor?) do
    case Map.fetch(state.runs, run_id) do
      {:ok, record} ->
        case Map.pop(record.subscribers, socket) do
          {nil, _subscribers} ->
            state

          {%Subscriber{monitor: monitor}, subscribers} ->
            if demonitor?, do: Process.demonitor(monitor, [:flush])

            record =
              %{record | subscribers: subscribers}
              |> Map.update!(:accounted_bytes, &(&1 - Config.subscriber_overhead_bytes()))

            put_record(state, record)
        end

      :error ->
        state
    end
  end

  defp unsubscribe_all_socket(state, socket) do
    Enum.reduce(Map.keys(state.runs), state, &unsubscribe_socket(&2, &1, socket))
  end

  defp subscription_count(runs, socket),
    do: Enum.count(runs, fn {_run_id, record} -> Map.has_key?(record.subscribers, socket) end)

  defp notify_subscribers(state, run_id) do
    record = Map.fetch!(state.runs, run_id)

    subscribers =
      Map.new(record.subscribers, fn {pid, subscriber} ->
        if subscriber.notified do
          {pid, subscriber}
        else
          send(pid, {:synapse_run_changed, run_id})
          {pid, %{subscriber | notified: true}}
        end
      end)

    put_record(state, %{record | subscribers: subscribers})
  end

  defp valid_registered_run?(run, run_id, session, nil),
    do: Run.valid?(run) and run.id == run_id and run.owner == session

  defp valid_registered_run?(run, _run_id, _session, existing), do: run == existing

  defp cancel_runtime(%RunRecord{runtime_run: %Run{} = run}, cancel_run) do
    try do
      cancel_run.(run)
    rescue
      _exception -> :ok
    catch
      _kind, _reason -> :ok
    end

    :ok
  end

  defp cancel_runtime(_record, _cancel_run), do: :ok

  defp account_record(record, config) do
    projection = record.projection

    projection_bytes =
      byte_size(projection.text) + optional_bytes(projection.model) +
        active_tool_bytes(projection.active_tool)

    accounted =
      Config.run_record_overhead_bytes() + config.max_outgoing_message_bytes +
        byte_size(record.id) + projection_bytes + active_tool_bytes(record.owner_lost_tool) +
        record.replay_bytes +
        map_size(record.subscribers) * Config.subscriber_overhead_bytes()

    %{record | accounted_bytes: accounted}
  end

  defp optional_bytes(nil), do: 0
  defp optional_bytes(value), do: byte_size(value)
  defp active_tool_bytes(nil), do: 0

  defp active_tool_bytes(tool),
    do: byte_size(tool.operation_id) + byte_size(tool.call_id) + byte_size(tool.name)

  defp put_record(state, record) do
    state
    |> Map.put(:runs, Map.put(state.runs, record.id, record))
    |> update_aggregate()
  end

  defp update_aggregate(state),
    do: %{
      state
      | aggregate_bytes: state.runs |> Map.values() |> Enum.reduce(0, &(&1.accounted_bytes + &2))
    }

  defp retention_plan(state, protected) do
    completed = Enum.count(state.runs, fn {_id, record} -> not is_nil(record.terminal) end)

    if state.aggregate_bytes <= state.config.max_aggregate_state_bytes and
         completed <= state.config.max_completed_runs do
      {:ok, state, []}
    else
      candidate =
        state.runs
        |> Map.values()
        |> Enum.filter(&(not is_nil(&1.terminal) and not MapSet.member?(protected, &1.id)))
        |> Enum.min_by(& &1.completed_ordinal, fn -> nil end)

      if candidate do
        state = %{state | runs: Map.delete(state.runs, candidate.id)} |> update_aggregate()

        case retention_plan(state, protected) do
          {:ok, state, evicted} -> {:ok, state, [candidate | evicted]}
          error -> error
        end
      else
        {:error, :aggregate_limit}
      end
    end
  end

  defp cleanup_evicted(records) do
    Enum.each(records, fn record ->
      Enum.each(record.subscribers, fn {_pid, subscriber} ->
        Process.demonitor(subscriber.monitor, [:flush])
      end)
    end)
  end

  defp safe_call(server, message, fallback) do
    GenServer.call(server, message, :infinity)
  catch
    :exit, _reason -> fallback
  end

  defp unavailable_session(_manager, _run_id, _command), do: {:error, :runtime_unavailable}

  defp generate_run_id,
    do: "run_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
end

defimpl Inspect, for: Synapse.API.RunManager.State do
  def inspect(%{active_run_id: active_run_id, runs: runs}, _options)
      when (is_nil(active_run_id) or is_binary(active_run_id)) and is_map(runs),
      do: "#Synapse.API.RunManager.State<runs=#{map_size(runs)} redacted>"

  def inspect(_state, _options), do: "#Synapse.API.RunManager.State<invalid redacted>"
end
