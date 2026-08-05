defmodule Synapse.Runtime.RunServer do
  @moduledoc """
  Owns bounded lifecycle tracking and conservative terminal conversion for one run.

  RunServer starts one linked and monitored Agent lifecycle function through
  `Task.Supervisor.async/3`. The task has temporary restart and brutal supervisor
  shutdown. During startup, RunServer monitors the caller, accepts one matching
  ready message, and relays only accepted non-terminal events. It buffers one
  terminal for later publication after Workspace cleanup. If the task fails without
  a valid terminal, fixed state classifies cancellation, active Tool ambiguity,
  accepted visible output, or an ordinary worker crash without retaining raw exit
  reasons or event content.

  Runtime uses two caller-supplied unsigned one-cell atomics resources:

  * cancellation values are `0` for active and `1` for cancelled;
  * await values are `0` for available, `1` for waiting, and `2` for consumed.

  Atomics are shared mutable resources, not unforgeable capabilities. Structural
  checks reject ordinary references and malformed resources but cannot prove
  provenance inside a trusted BEAM node.

  The production Agent Runner must not enable `trap_exit`. The wrapper resets it
  to `false` before invocation, so abnormal RunServer exit propagates through the
  task link and terminates Agent. Arbitrary trusted code in the same task can
  change that flag and defeat link-based ownership; the internal callback
  is not an extension or public execution API.

  Exported child startup, event relay, and initial-cell predicates are intentionally
  `@doc false`. They form the private protocol among Runtime, AgentTask, and OTP
  supervisors; supported callers use `Synapse.Runtime` instead.
  """

  use GenServer

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

  alias Synapse.Runtime.RunServer.{Message, State}

  @doc false
  @spec child_spec({State.t(), (pid() -> term()), GenServer.server()}) ::
          Supervisor.child_spec()
  def child_spec(argument) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [argument]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }
  end

  @doc false
  @spec start_link({State.t(), (pid() -> term()), GenServer.server()}) ::
          GenServer.on_start()
  def start_link(argument), do: GenServer.start_link(__MODULE__, argument)

  @doc false
  @spec emit_event(pid(), reference(), pid(), Event.t()) :: :ok | {:error, :closed}
  def emit_event(server, run_ref, worker, event) do
    GenServer.call(server, {:runtime_event, run_ref, worker, event}, :infinity)
  catch
    :exit, _reason -> {:error, :closed}
  end

  @impl true
  def init({state, agent, task_supervisor}) do
    Process.flag(:trap_exit, true)

    with {:ok, state} <- normalize_initial_state(state),
         true <- is_function(agent, 1) or {:error, :invalid_agent},
         owner_monitor <- Process.monitor(state.owner),
         {:ok, task} <- start_agent_task(task_supervisor, agent) do
      {:ok, %{state | task: task, startup_owner_monitor: owner_monitor}}
    else
      {:error, _reason} -> {:stop, :runtime_unavailable}
    end
  end

  def init(_argument), do: {:stop, :runtime_unavailable}

  @impl true
  def handle_call(
        {:runtime_event, run_ref, worker, _event},
        _from,
        %{
          phase: :running,
          run_ref: run_ref,
          task: %Task{pid: worker},
          buffered_terminal: buffered
        } = state
      )
      when not is_nil(buffered),
      do: {:reply, {:error, :closed}, %{state | event_contract_status: :failed}}

  def handle_call(
        {:runtime_event, run_ref, worker, event},
        _from,
        %{
          phase: :running,
          run_ref: run_ref,
          task: %Task{pid: worker},
          sink_status: :open
        } = state
      ) do
    case normalize_event(event, state.run_id) do
      {:ok, event, :terminal} when is_nil(state.buffered_terminal) ->
        {:reply, :ok, %{state | buffered_terminal: event}}

      {:ok, _event, :terminal} ->
        {:reply, {:error, :closed}, %{state | event_contract_status: :failed}}

      {:ok, event, :progress} ->
        handle_progress_event(state, event)

      :error ->
        {:reply, {:error, :closed}, %{state | event_contract_status: :failed}}
    end
  end

  def handle_call({:runtime_event, _run_ref, _worker, _event}, _from, state),
    do: {:reply, {:error, :closed}, state}

  @impl true
  def handle_info(
        %Message{
          kind: :ready,
          run_ref: run_ref,
          worker: worker,
          payload: {:ok, handle}
        },
        %{phase: :starting, run_ref: run_ref, task: %Task{pid: worker}} = state
      ) do
    if Process.alive?(state.owner) and is_pid(handle.state) and
         Synapse.Workspace.valid_handle?(handle) do
      {:noreply, accept_startup(state, handle)}
    else
      {:noreply, abort_startup(state, :workspace_open_failed, handle.state)}
    end
  end

  def handle_info(
        %Message{
          kind: :ready,
          run_ref: run_ref,
          worker: worker,
          payload: {:error, reason, backend}
        },
        %{phase: :starting, run_ref: run_ref, task: %Task{pid: worker}} = state
      )
      when reason in [:workspace_open_failed, :runtime_unavailable],
      do: {:noreply, abort_startup(state, reason, backend)}

  def handle_info(
        {:DOWN, monitor, :process, owner, _reason},
        %{phase: :starting, startup_owner_monitor: monitor, owner: owner} = state
      ),
      do: {:noreply, abort_startup(%{state | startup_owner_monitor: nil}, :runtime_unavailable)}

  def handle_info({reference, result}, %{task: %Task{ref: reference}} = state),
    do: {:noreply, retain_worker_result(state, result)}

  def handle_info({:EXIT, task, _reason}, %{task: %Task{pid: task}} = state),
    do: {:noreply, %{state | phase: :settling}}

  def handle_info(
        {:DOWN, reference, :process, task, _reason},
        %{task: %Task{pid: task, ref: reference}} = state
      ),
      do: finish_after_task_down(%{state | task_settled?: true})

  def handle_info(
        {:DOWN, monitor, :process, backend, _reason},
        %{workspace_monitor: monitor, workspace_backend: backend} = state
      ),
      do:
        state
        |> Map.merge(%{
          workspace_monitor: nil,
          workspace_backend: nil,
          workspace_status: :settled
        })
        |> after_workspace_down()

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{task: %Task{pid: task}}) do
    if Process.alive?(task), do: Process.exit(task, :kill)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @impl true
  def format_status(status) when is_map(status) do
    Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted, log: []})
  end

  @impl true
  def format_status(_reason, [_process_dictionary, _state]),
    do: [data: [{~c"State", :redacted}]]

  @typedoc "The fixed values stored in the cancellation atomics cell."
  @type cancellation_value :: 0 | 1

  @typedoc "The fixed values stored in the await-state atomics cell."
  @type await_value :: 0 | 1 | 2

  @doc "Returns whether a value is one unsigned atomics cell in a cancellation state."
  @spec valid_cancellation_cell?(term()) :: boolean()
  def valid_cancellation_cell?(cell), do: valid_cell?(cell, 0..1)

  @doc "Returns whether a value is one unsigned atomics cell in an await state."
  @spec valid_await_cell?(term()) :: boolean()
  def valid_await_cell?(cell), do: valid_cell?(cell, 0..2)

  @doc false
  @spec initial_cancellation_cell?(term()) :: boolean()
  def initial_cancellation_cell?(cell), do: valid_cell?(cell, 0..0)

  @doc false
  @spec initial_await_cell?(term()) :: boolean()
  def initial_await_cell?(cell), do: valid_cell?(cell, 0..0)

  defp valid_cell?(cell, allowed_values) when is_reference(cell) do
    try do
      case :atomics.info(cell) do
        %{size: 1, min: 0} -> :atomics.get(cell, 1) in allowed_values
        _invalid -> false
      end
    rescue
      ArgumentError -> false
    catch
      :error, :badarg -> false
    end
  end

  defp valid_cell?(_cell, _allowed_values), do: false

  defp normalize_initial_state(%State{} = state) do
    State.new(
      run_id: state.run_id,
      owner: state.owner,
      run_ref: state.run_ref,
      cancel_ref: state.cancel_ref,
      cancellation: state.cancellation,
      await_state: state.await_state,
      event_sink: state.event_sink
    )
  end

  defp normalize_initial_state(_state), do: {:error, :invalid_state}

  defp start_agent_task(task_supervisor, agent) do
    run_server = self()

    {:ok,
     Task.Supervisor.async(task_supervisor, fn -> invoke_agent(agent, run_server) end,
       shutdown: :brutal_kill
     )}
  rescue
    _exception -> {:error, :runtime_unavailable}
  catch
    _kind, _reason -> {:error, :runtime_unavailable}
  end

  defp invoke_agent(agent, run_server) do
    Process.flag(:trap_exit, false)
    normalize_worker_outcome(agent.(run_server))
  rescue
    _exception -> :agent_failed
  catch
    _kind, _reason -> :agent_failed
  end

  defp normalize_worker_outcome({:agent_finished, terminal, close_status} = outcome)
       when close_status in [:workspace_closed, :workspace_close_failed] do
    if valid_agent_terminal?(terminal) or terminal == :agent_failed,
      do: outcome,
      else: :agent_failed
  end

  defp normalize_worker_outcome(:startup_aborted), do: :startup_aborted
  defp normalize_worker_outcome(_outcome), do: :agent_failed

  defp valid_agent_terminal?({:ok, %Synapse.Agent.Result{} = result}),
    do: match?({:ok, _result}, Synapse.Agent.Result.new(Map.from_struct(result)))

  defp valid_agent_terminal?({:error, %Synapse.Agent.Error{} = error}),
    do: match?({:ok, _error}, Synapse.Agent.Error.new(Map.from_struct(error)))

  defp valid_agent_terminal?(_terminal), do: false

  defp accept_startup(state, handle) do
    {:ok, accept} = Message.accept(state.run_ref)
    {:ok, started} = Message.started(state.run_ref, state.task.pid, self())
    Process.demonitor(state.startup_owner_monitor, [:flush])

    {workspace_backend, workspace_monitor} = monitor_workspace(handle.state)

    send(state.task.pid, accept)
    send(state.owner, started)

    %{
      state
      | phase: :running,
        startup_owner_monitor: nil,
        workspace_backend: workspace_backend,
        workspace_monitor: workspace_monitor,
        workspace_status: :open
    }
  end

  defp abort_startup(state, reason, backend \\ nil) do
    {:ok, abort} = Message.abort(state.run_ref)
    send(state.task.pid, abort)
    {workspace_backend, workspace_monitor} = monitor_workspace(backend)

    %{
      state
      | phase: :settling,
        startup_error: reason,
        workspace_backend: workspace_backend,
        workspace_monitor: workspace_monitor,
        workspace_status: if(is_pid(backend), do: :open, else: state.workspace_status)
    }
  end

  defp retain_worker_result(state, {:agent_finished, terminal, close_status}) do
    worker_terminal = if valid_agent_terminal?(terminal), do: terminal, else: nil

    state = %{
      state
      | phase: :settling,
        worker_result_seen?: true,
        worker_terminal: worker_terminal,
        close_failed?: close_status == :workspace_close_failed,
        event_contract_status:
          if(is_nil(worker_terminal), do: :failed, else: state.event_contract_status)
    }

    if close_status == :workspace_closed do
      clear_workspace_monitor(%{state | workspace_status: :settled})
    else
      state
    end
  end

  defp retain_worker_result(state, _result),
    do: %{
      state
      | phase: :settling,
        worker_result_seen?: true,
        worker_terminal: nil,
        event_contract_status: :failed
    }

  defp finish_after_task_down(%{phase: :starting} = state),
    do: state |> Map.put(:startup_error, :runtime_unavailable) |> maybe_finish_start_failure()

  defp finish_after_task_down(%{startup_owner_monitor: monitor, startup_error: nil} = state)
       when is_reference(monitor) do
    Process.demonitor(monitor, [:flush])

    state
    |> Map.merge(%{startup_owner_monitor: nil, startup_error: :runtime_unavailable})
    |> maybe_finish_start_failure()
  end

  defp finish_after_task_down(%{startup_error: reason} = state) when not is_nil(reason),
    do: maybe_finish_start_failure(state)

  defp finish_after_task_down(state), do: maybe_finalize(state)

  defp maybe_finish_start_failure(
         %{startup_error: reason, task_settled?: true, workspace_monitor: nil} = state
       )
       when not is_nil(reason),
       do: send_start_failure_and_stop(state, reason)

  defp maybe_finish_start_failure(state), do: {:noreply, state}

  defp after_workspace_down(%{startup_error: reason} = state) when not is_nil(reason),
    do: maybe_finish_start_failure(state)

  defp after_workspace_down(state), do: maybe_finalize(state)

  defp send_start_failure_and_stop(state, reason) do
    if Process.alive?(state.owner) do
      {:ok, failed} = Message.start_failed(state.run_ref, state.task.pid, self(), reason)
      send(state.owner, failed)
    end

    {:stop, :normal, state}
  end

  defp monitor_workspace(backend) when is_pid(backend),
    do: {backend, Process.monitor(backend)}

  defp monitor_workspace(_backend), do: {nil, nil}

  defp normalize_event(event, run_id) do
    with {:ok, kind, terminal?} <- event_kind(event),
         {:ok, normalized} <- Event.new(kind, Map.from_struct(event)),
         true <- normalized.run_id == run_id do
      {:ok, normalized, if(terminal?, do: :terminal, else: :progress)}
    else
      _invalid -> :error
    end
  end

  defp event_kind(%RunStarted{}), do: {:ok, :run_started, false}
  defp event_kind(%TurnStarted{}), do: {:ok, :turn_started, false}
  defp event_kind(%TextDelta{}), do: {:ok, :text_delta, false}
  defp event_kind(%ToolStarted{}), do: {:ok, :tool_started, false}
  defp event_kind(%ToolCompleted{}), do: {:ok, :tool_completed, false}
  defp event_kind(%TurnCompleted{}), do: {:ok, :turn_completed, false}
  defp event_kind(%RunCompleted{}), do: {:ok, :run_completed, true}
  defp event_kind(%RunFailed{}), do: {:ok, :run_failed, true}
  defp event_kind(%RunInterrupted{}), do: {:ok, :run_interrupted, true}
  defp event_kind(_event), do: :error

  defp invoke_event_sink(event_sink, event) do
    try do
      if event_sink.(event) == :ok, do: :ok, else: {:error, :closed}
    rescue
      _exception -> {:error, :closed}
    catch
      _kind, _reason -> {:error, :closed}
    end
  end

  defp handle_progress_event(state, %TextDelta{} = event) do
    case invoke_event_sink(state.event_sink, event) do
      :ok -> {:reply, :ok, %{state | visible_output?: true}}
      {:error, :closed} -> sink_failed_reply(state)
    end
  end

  defp handle_progress_event(%{active_tool: nil} = state, %ToolStarted{} = event) do
    case invoke_event_sink(state.event_sink, event) do
      :ok -> {:reply, :ok, %{state | active_tool: tool_identity(event)}}
      {:error, :closed} -> sink_failed_reply(state)
    end
  end

  defp handle_progress_event(state, %ToolStarted{}),
    do: contract_failed_reply(state)

  defp handle_progress_event(%{active_tool: active_tool} = state, %ToolCompleted{} = event)
       when not is_nil(active_tool) do
    if tool_identity(event) == active_tool do
      state = %{state | active_tool: nil}

      case invoke_event_sink(state.event_sink, event) do
        :ok -> {:reply, :ok, state}
        {:error, :closed} -> sink_failed_reply(state)
      end
    else
      contract_failed_reply(state)
    end
  end

  defp handle_progress_event(state, %ToolCompleted{}),
    do: contract_failed_reply(state)

  defp handle_progress_event(state, event) do
    case invoke_event_sink(state.event_sink, event) do
      :ok -> {:reply, :ok, state}
      {:error, :closed} -> sink_failed_reply(state)
    end
  end

  defp sink_failed_reply(state),
    do: {:reply, {:error, :closed}, %{state | sink_status: :failed}}

  defp contract_failed_reply(state),
    do: {:reply, {:error, :closed}, %{state | event_contract_status: :failed}}

  defp tool_identity(event) do
    %{
      turn: event.turn,
      operation_id: event.operation_id,
      call_id: event.call_id,
      name: event.name,
      ordinal: event.ordinal
    }
  end

  defp clear_workspace_monitor(%{workspace_monitor: monitor} = state)
       when is_reference(monitor) do
    Process.demonitor(monitor, [:flush])
    %{state | workspace_monitor: nil, workspace_backend: nil}
  end

  defp clear_workspace_monitor(state), do: %{state | workspace_backend: nil}

  defp maybe_finalize(
         %{
           startup_error: nil,
           task_settled?: true,
           workspace_status: :settled
         } = state
       ),
       do: finalize(state)

  defp maybe_finalize(state), do: {:noreply, state}

  defp finalize(state) do
    {terminal_event, terminal} = select_terminal(state)

    cond do
      state.sink_status == :failed ->
        deliver_terminal(state, event_sink_failure(state.run_id))

      true ->
        case invoke_event_sink(state.event_sink, terminal_event) do
          :ok ->
            deliver_terminal(%{state | sink_status: :terminal_accepted}, terminal)

          {:error, :closed} ->
            deliver_terminal(%{state | sink_status: :failed}, event_sink_failure(state.run_id))
        end
    end
  end

  defp deliver_terminal(state, terminal) do
    {:ok, message} = Message.terminal(state.run_ref, terminal)
    send(state.owner, message)
    {:stop, :normal, %{state | phase: :publishing}}
  end

  defp select_terminal(%{close_failed?: true} = state), do: close_failure(state)

  defp select_terminal(state) do
    case matching_buffered_terminal(state) do
      {:ok, event, terminal} -> {event, terminal}
      :error -> fallback_terminal(state)
    end
  end

  defp matching_buffered_terminal(%{buffered_terminal: nil}), do: :error

  defp matching_buffered_terminal(%{event_contract_status: :failed}), do: :error

  defp matching_buffered_terminal(state) do
    terminal = event_terminal(state.buffered_terminal)

    cond do
      not terminal_outcome_agrees?(state.buffered_terminal) ->
        :error

      not state.worker_result_seen? ->
        {:ok, state.buffered_terminal, terminal}

      state.worker_terminal == terminal ->
        {:ok, state.buffered_terminal, terminal}

      true ->
        :error
    end
  end

  defp event_terminal(%RunCompleted{result: result}), do: {:ok, result}
  defp event_terminal(%RunFailed{error: error}), do: {:error, error}
  defp event_terminal(%RunInterrupted{error: error}), do: {:error, error}

  defp terminal_outcome_agrees?(%RunCompleted{}), do: true

  defp terminal_outcome_agrees?(%RunInterrupted{error: error}),
    do: interrupted_error?(error)

  defp terminal_outcome_agrees?(%RunFailed{error: error}),
    do: not interrupted_error?(error)

  defp interrupted_error?(%Synapse.Agent.Error{kind: :cancelled}), do: true

  defp interrupted_error?(%Synapse.Agent.Error{reason: :provider_interrupted_after_output}),
    do: true

  defp interrupted_error?(%Synapse.Agent.Error{
         kind: :provider,
         details: %{"provider_kind" => provider_kind}
       })
       when provider_kind in ["interrupted", "timeout"],
       do: true

  defp interrupted_error?(_error), do: false

  defp fallback_terminal(state) do
    cond do
      cancelled?(state.cancellation) -> cancellation_failure(state)
      not is_nil(state.active_tool) -> tool_ambiguity(state)
      state.visible_output? -> worker_failure(state, :interrupted)
      true -> worker_failure(state, :failed)
    end
  end

  defp close_failure(state) do
    {turn, operation_id, details} = ambiguity_evidence(state)

    error =
      agent_error(
        :internal,
        :workspace_close_failed,
        "Workspace could not be closed",
        state.run_id,
        turn,
        operation_id,
        details
      )

    {:ok, event} = Event.new(:run_failed, run_id: state.run_id, error: error)
    {event, {:error, error}}
  end

  defp cancellation_failure(state) do
    {turn, operation_id, details} = ambiguity_evidence(state)

    error =
      agent_error(
        :cancelled,
        :run_cancelled,
        "Run was cancelled",
        state.run_id,
        turn,
        operation_id,
        details
      )

    {:ok, event} = Event.new(:run_interrupted, run_id: state.run_id, error: error)
    {event, {:error, error}}
  end

  defp tool_ambiguity(state) do
    {turn, operation_id, details} = ambiguity_evidence(state)

    error =
      agent_error(
        :tool,
        :tool_ambiguous,
        "Tool result has an unknown side-effect outcome",
        state.run_id,
        turn,
        operation_id,
        details
      )

    {:ok, event} = Event.new(:run_failed, run_id: state.run_id, error: error)
    {event, {:error, error}}
  end

  defp worker_failure(state, event_kind) do
    error =
      agent_error(
        :internal,
        :run_worker_crashed,
        "Run worker failed",
        state.run_id,
        0,
        nil,
        %{}
      )

    kind = if event_kind == :interrupted, do: :run_interrupted, else: :run_failed
    {:ok, event} = Event.new(kind, run_id: state.run_id, error: error)
    {event, {:error, error}}
  end

  defp event_sink_failure(run_id) do
    error =
      agent_error(
        :internal,
        :event_sink_failed,
        "Run Event sink failed",
        run_id,
        0,
        nil,
        %{}
      )

    {:error, error}
  end

  defp agent_error(kind, reason, message, run_id, turn, operation_id, details) do
    {:ok, error} =
      Synapse.Agent.Error.new(
        kind: kind,
        reason: reason,
        message: message,
        run_id: run_id,
        turn: turn,
        operation_id: operation_id,
        details: details
      )

    error
  end

  defp ambiguity_evidence(%{active_tool: active}) when not is_nil(active),
    do: {active.turn, active.operation_id, active_tool_details(active)}

  defp ambiguity_evidence(state) do
    buffered_terminal =
      case matching_buffered_terminal(state) do
        {:ok, event, _terminal} -> event
        :error -> nil
      end

    case buffered_error(buffered_terminal) do
      %Synapse.Agent.Error{} = error ->
        details = prior_ambiguity_details(error.details)

        if details == %{},
          do: {0, nil, %{}},
          else: {error.turn, error.operation_id, details}

      nil ->
        {0, nil, %{}}
    end
  end

  defp active_tool_details(active) do
    %{
      "call_id" => active.call_id,
      "tool_name" => active.name,
      "operation_id" => active.operation_id,
      "outcome" => "unknown",
      "status" => "ambiguous"
    }
  end

  defp buffered_error(%RunFailed{error: error}), do: error
  defp buffered_error(%RunInterrupted{error: error}), do: error
  defp buffered_error(_event), do: nil

  defp prior_ambiguity_details(%{"status" => "ambiguous", "outcome" => "unknown"} = details),
    do: Map.take(details, ["call_id", "tool_name", "operation_id", "outcome", "status"])

  defp prior_ambiguity_details(_details), do: %{}

  defp cancelled?(cancellation) do
    :atomics.get(cancellation, 1) == 1
  rescue
    _exception -> true
  catch
    _kind, _reason -> true
  end
end

defmodule Synapse.Runtime.RunServer.State do
  @moduledoc """
  Bounded initial state for one temporary Runtime RunServer.

  RunServer owns this state for one temporary run. The initial contract retains only
  run identity, control references, the trusted event sink, and fixed lifecycle
  slots. It deliberately excludes Run Request, Runtime Options, prompt, cwd,
  instructions, Workspace Handle, raw Workspace errors, task exit reasons, text
  deltas, Tool arguments, Tool Result content, and event history.
  """

  alias Synapse.Runtime.RunServer
  alias Synapse.Tool.Validation

  @allowed_fields [
    :run_id,
    :owner,
    :run_ref,
    :cancel_ref,
    :cancellation,
    :await_state,
    :event_sink
  ]
  @max_run_id_bytes 256

  @enforce_keys [
    :run_id,
    :owner,
    :run_ref,
    :cancel_ref,
    :cancellation,
    :await_state,
    :event_sink,
    :startup_owner_monitor,
    :startup_error,
    :task_settled?,
    :worker_result_seen?,
    :close_failed?,
    :event_contract_status,
    :phase,
    :task,
    :workspace_backend,
    :workspace_monitor,
    :workspace_status,
    :visible_output?,
    :active_tool,
    :buffered_terminal,
    :worker_terminal,
    :sink_status
  ]
  defstruct run_id: nil,
            owner: nil,
            run_ref: nil,
            cancel_ref: nil,
            cancellation: nil,
            await_state: nil,
            event_sink: nil,
            startup_owner_monitor: nil,
            startup_error: nil,
            task_settled?: false,
            worker_result_seen?: false,
            close_failed?: false,
            event_contract_status: :ok,
            phase: :starting,
            task: nil,
            workspace_backend: nil,
            workspace_monitor: nil,
            workspace_status: :not_open,
            visible_output?: false,
            active_tool: nil,
            buffered_terminal: nil,
            worker_terminal: nil,
            sink_status: :open

  @typedoc "A RunServer lifecycle phase."
  @type phase :: :starting | :running | :settling | :publishing

  @typedoc "Observed Workspace backend state."
  @type workspace_status :: :not_open | :open | :settled | :close_failed

  @typedoc "Downstream event-sink state."
  @type sink_status :: :open | :failed | :terminal_accepted

  @typedoc "Bounded mutable lifecycle state owned by one future RunServer."
  @type t :: %__MODULE__{
          run_id: String.t(),
          owner: pid(),
          run_ref: reference(),
          cancel_ref: reference(),
          cancellation: reference(),
          await_state: reference(),
          event_sink: Synapse.Runtime.event_sink(),
          startup_owner_monitor: reference() | nil,
          startup_error: :workspace_open_failed | :runtime_unavailable | nil,
          task_settled?: boolean(),
          worker_result_seen?: boolean(),
          close_failed?: boolean(),
          event_contract_status: :ok | :failed,
          phase: phase(),
          task: Task.t() | nil,
          workspace_backend: pid() | nil,
          workspace_monitor: reference() | nil,
          workspace_status: workspace_status(),
          visible_output?: boolean(),
          active_tool:
            %{
              turn: pos_integer(),
              operation_id: String.t(),
              call_id: String.t(),
              name: String.t(),
              ordinal: pos_integer()
            }
            | nil,
          buffered_terminal:
            Synapse.Run.Event.RunCompleted.t()
            | Synapse.Run.Event.RunFailed.t()
            | Synapse.Run.Event.RunInterrupted.t()
            | nil,
          worker_terminal: Synapse.Agent.result() | nil,
          sink_status: sink_status()
        }

  @typedoc "A field-specific invalid initial RunServer state."
  @type validation_error ::
          {:attributes, :must_be_keyword_or_map}
          | {:unknown_fields, [term()]}
          | {:run_id, :must_be_bounded_non_empty_utf8_identifier}
          | {:owner, :must_be_pid}
          | {:run_ref, :must_be_reference}
          | {:cancel_ref, :must_be_reference}
          | {:cancellation, :must_be_one_cell_cancellation_atomics}
          | {:await_state, :must_be_one_cell_await_atomics}
          | {:await_state, :must_differ_from_cancellation}
          | {:authority, :must_be_pairwise_distinct}
          | {:event_sink, :must_be_arity_one_function}

  @doc "Validates initial authority fields and fills every lifecycle slot deterministically."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs) do
    with {:ok, attrs} <- Validation.attributes(attrs, @allowed_fields),
         true <-
           Validation.identifier?(attrs[:run_id], @max_run_id_bytes) or
             {:error, {:run_id, :must_be_bounded_non_empty_utf8_identifier}},
         true <- is_pid(attrs[:owner]) or {:error, {:owner, :must_be_pid}},
         true <- is_reference(attrs[:run_ref]) or {:error, {:run_ref, :must_be_reference}},
         true <-
           is_reference(attrs[:cancel_ref]) or {:error, {:cancel_ref, :must_be_reference}},
         true <-
           RunServer.initial_cancellation_cell?(attrs[:cancellation]) or
             {:error, {:cancellation, :must_be_one_cell_cancellation_atomics}},
         true <-
           RunServer.initial_await_cell?(attrs[:await_state]) or
             {:error, {:await_state, :must_be_one_cell_await_atomics}},
         true <-
           attrs.cancellation != attrs.await_state or
             {:error, {:await_state, :must_differ_from_cancellation}},
         true <-
           pairwise_distinct?([
             attrs.run_ref,
             attrs.cancel_ref,
             attrs.cancellation,
             attrs.await_state
           ]) or {:error, {:authority, :must_be_pairwise_distinct}},
         true <-
           is_function(attrs[:event_sink], 1) or
             {:error, {:event_sink, :must_be_arity_one_function}} do
      {:ok,
       %__MODULE__{
         run_id: attrs.run_id,
         owner: attrs.owner,
         run_ref: attrs.run_ref,
         cancel_ref: attrs.cancel_ref,
         cancellation: attrs.cancellation,
         await_state: attrs.await_state,
         event_sink: attrs.event_sink,
         startup_owner_monitor: nil,
         startup_error: nil,
         task_settled?: false,
         worker_result_seen?: false,
         close_failed?: false,
         event_contract_status: :ok,
         phase: :starting,
         task: nil,
         workspace_backend: nil,
         workspace_monitor: nil,
         workspace_status: :not_open,
         visible_output?: false,
         active_tool: nil,
         buffered_terminal: nil,
         worker_terminal: nil,
         sink_status: :open
       }}
    end
  end

  defp pairwise_distinct?(values), do: length(Enum.uniq(values)) == length(values)
end

defimpl Inspect, for: Synapse.Runtime.RunServer.State do
  def inspect(_state, _options), do: "#Synapse.Runtime.RunServer.State<redacted>"
end

defmodule Synapse.Runtime.RunServer.Message do
  @moduledoc """
  Redacted internal startup-control and terminal message data.

  Every message carries the unguessable run reference. Ready messages also carry
  the expected Agent task PID because ordinary BEAM messages have no authenticated
  sender field. Startup failures are fixed and accept no raw failure term.
  These values are an internal Runtime protocol, not a caller extension API.
  """

  alias Synapse.Agent.{Error, Result}
  alias Synapse.Workspace.{Access, Handle, Limits}

  @enforce_keys [:kind, :run_ref, :worker, :payload]
  defstruct [:kind, :run_ref, :worker, :payload]

  @typedoc "An internal Runtime handshake or owner-terminal message kind."
  @type kind :: :ready | :accept | :abort | :started | :start_failed | :terminal

  @typedoc "One bounded redacted internal Runtime message."
  @type t ::
          %__MODULE__{
            kind: :ready,
            run_ref: reference(),
            worker: pid(),
            payload:
              {:ok, Handle.t()}
              | {:error, :workspace_open_failed | :runtime_unavailable, pid() | nil}
          }
          | %__MODULE__{
              kind: :accept | :abort,
              run_ref: reference(),
              worker: nil,
              payload: nil
            }
          | %__MODULE__{
              kind: :started,
              run_ref: reference(),
              worker: pid(),
              payload: pid()
            }
          | %__MODULE__{
              kind: :start_failed,
              run_ref: reference(),
              worker: pid(),
              payload: {pid(), :workspace_open_failed | :runtime_unavailable}
            }
          | %__MODULE__{
              kind: :terminal,
              run_ref: reference(),
              worker: nil,
              payload: Synapse.Runtime.agent_terminal()
            }

  @typedoc "A malformed internal message input."
  @type validation_error :: :invalid_message

  @doc "Builds an Agent-to-RunServer ready message carrying one opaque Handle."
  @spec ready(reference(), pid(), Handle.t()) :: {:ok, t()} | {:error, validation_error()}
  def ready(run_ref, worker, %Handle{} = handle) do
    if is_reference(run_ref) and is_pid(worker) and valid_handle?(handle),
      do: {:ok, message(:ready, run_ref, worker, {:ok, handle})},
      else: {:error, :invalid_message}
  end

  def ready(_run_ref, _worker, _handle), do: {:error, :invalid_message}

  @doc "Builds a sanitized Agent-to-RunServer startup failure message."
  @spec ready_failed(
          reference(),
          pid(),
          :workspace_open_failed | :runtime_unavailable,
          pid() | nil
        ) ::
          {:ok, t()} | {:error, validation_error()}
  def ready_failed(run_ref, worker, reason, backend \\ nil)

  def ready_failed(run_ref, worker, reason, backend)
      when reason in [:workspace_open_failed, :runtime_unavailable] do
    if is_reference(run_ref) and is_pid(worker) and (is_pid(backend) or is_nil(backend)),
      do: {:ok, message(:ready, run_ref, worker, {:error, reason, backend})},
      else: {:error, :invalid_message}
  end

  def ready_failed(_run_ref, _worker, _reason, _backend), do: {:error, :invalid_message}

  @doc "Builds a RunServer-to-start-caller accepted startup message."
  @spec started(reference(), pid(), pid()) :: {:ok, t()} | {:error, validation_error()}
  def started(run_ref, worker, server) do
    if is_reference(run_ref) and is_pid(worker) and is_pid(server),
      do: {:ok, message(:started, run_ref, worker, server)},
      else: {:error, :invalid_message}
  end

  @doc "Builds a sanitized RunServer-to-start-caller startup failure message."
  @spec start_failed(
          reference(),
          pid(),
          pid(),
          :workspace_open_failed | :runtime_unavailable
        ) :: {:ok, t()} | {:error, validation_error()}
  def start_failed(run_ref, worker, server, reason)
      when reason in [:workspace_open_failed, :runtime_unavailable] do
    if is_reference(run_ref) and is_pid(worker) and is_pid(server),
      do: {:ok, message(:start_failed, run_ref, worker, {server, reason})},
      else: {:error, :invalid_message}
  end

  def start_failed(_run_ref, _worker, _server, _reason), do: {:error, :invalid_message}

  @doc "Builds a RunServer-to-Agent startup acceptance message."
  @spec accept(reference()) :: {:ok, t()} | {:error, validation_error()}
  def accept(run_ref), do: control(:accept, run_ref)

  @doc "Builds a RunServer-to-Agent startup abort message."
  @spec abort(reference()) :: {:ok, t()} | {:error, validation_error()}
  def abort(run_ref), do: control(:abort, run_ref)

  @doc "Builds a RunServer-to-handle-owner validated terminal message."
  @spec terminal(reference(), Synapse.Runtime.agent_terminal()) ::
          {:ok, t()} | {:error, validation_error()}
  def terminal(run_ref, terminal) when is_reference(run_ref) do
    case normalize_terminal(terminal) do
      {:ok, terminal} -> {:ok, message(:terminal, run_ref, nil, terminal)}
      :error -> {:error, :invalid_message}
    end
  end

  def terminal(_run_ref, _terminal), do: {:error, :invalid_message}

  defp control(kind, run_ref) when is_reference(run_ref),
    do: {:ok, message(kind, run_ref, nil, nil)}

  defp control(_kind, _run_ref), do: {:error, :invalid_message}

  defp message(kind, run_ref, worker, payload),
    do: %__MODULE__{kind: kind, run_ref: run_ref, worker: worker, payload: payload}

  defp normalize_terminal({:ok, %Result{} = result}) do
    case Result.new(Map.from_struct(result)) do
      {:ok, result} -> {:ok, {:ok, result}}
      {:error, _reason} -> :error
    end
  end

  defp normalize_terminal({:error, %Error{} = error}) do
    case Error.new(Map.from_struct(error)) do
      {:ok, error} -> {:ok, {:error, error}}
      {:error, _reason} -> :error
    end
  end

  defp normalize_terminal(_terminal), do: :error

  defp valid_handle?(%Handle{
         backend: backend,
         state: state,
         token: token,
         limits: limits,
         access: access
       }) do
    is_atom(backend) and (is_pid(state) or is_reference(state)) and is_reference(token) and
      Limits.valid?(limits) and Access.valid?(access)
  end
end

defimpl Inspect, for: Synapse.Runtime.RunServer.Message do
  def inspect(_message, _options), do: "#Synapse.Runtime.RunServer.Message<redacted>"
end
