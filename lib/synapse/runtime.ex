defmodule Synapse.Runtime do
  @moduledoc """
  Public lifecycle boundary for one supervised Agent run.

  Runtime validates trusted start configuration and will own one temporary
  RunServer, one linked Agent task, Workspace open/close, persistent cancellation,
  terminal cleanup gating, and conservative worker-crash conversion. It does not
  own conversation, Provider retry, Tool execution, Workspace operation, terminal
  rendering, persistence, or verification semantics.

  `start_run/3` synchronously waits for Agent-task-owned Workspace readiness and
  returns after RunServer accepts startup, not after Provider or Tool completion.
  `await/2` is owner-only and returns one validated terminal only after Agent Task
  and Workspace settlement plus terminal sink delivery. `cancel/1` persistently
  marks the run before routing one matching message to the Agent task.

  Runtime's optional deadline is an absolute monotonic boundary. Agent selects it
  only when earlier than the Run Budget wall-time boundary and propagates the
  effective deadline to Provider and Workspace operations. Provider inactivity,
  command inactivity, and command timeout remain lower-component policies because
  only those components can define meaningful activity. `await/2` timeout affects
  only the caller's receive. Runtime creates no competing operation watchdog.

  Application shutdown stops Runtime coordination before Agent tasks and Workspace
  owners. Once RunServer is gone no terminal-event guarantee remains; links,
  monitors, and lower owner watchdogs provide cleanup instead.

  Runtime is an ownership and reliability boundary, not a security sandbox. BEAM
  supervision does not isolate trusted code in the same VM, Workspace capabilities
  are cooperative application policy, and worktrees do not provide OS containment.
  Runtime never transfers Provider credentials to Workspace children; real command
  environment filtering remains Workspace policy. Deliberately daemonized or
  reparented descendants may escape the portable direct-child cleanup guarantee.

  Trusted in-process callbacks are synchronous contracts. Runtime sanitizes a
  callback that returns, raises, throws, or exits, but does not create a competing
  timeout around an opener, event sink, retry-delay callback, or Workspace close.
  If such trusted code blocks forever, the owning process must be terminated by
  application shutdown or another external owner decision.

  ## Text-only Fake example

      iex> {:ok, capabilities} = Synapse.Tool.CapabilitySet.new(
      ...>   fs_read: false, fs_write: false, process_exec: false
      ...> )
      iex> {:ok, request} = Synapse.Run.Request.new(
      ...>   id: "runtime-doc", prompt: "Answer.", cwd: "/synthetic/runtime-doc",
      ...>   model: "test-model", capabilities: capabilities,
      ...>   budget: Synapse.Budget.default()
      ...> )
      iex> {:ok, operation_id} = Synapse.Agent.OperationId.provider(request.id, 1, 1)
      iex> {:ok, response} = Synapse.Provider.Response.new(
      ...>   id: "runtime-doc-response", model: request.model,
      ...>   output_items: [%Synapse.Provider.OutputItem.Message{
      ...>     id: "runtime-doc-message", role: :assistant, content: "Finished"
      ...>   }]
      ...> )
      iex> opener = fn open_request ->
      ...>   Synapse.Workspace.Fake.open([],
      ...>     owner: open_request.owner,
      ...>     limits: open_request.limits,
      ...>     access: open_request.access
      ...>   )
      ...> end
      iex> Synapse.Provider.Fake.with_script(
      ...>   operation_id,
      ...>   [{:turn, [], {:ok, response}}],
      ...>   fn ->
      ...>     {:ok, run} = Synapse.Runtime.start_run(
      ...>       request,
      ...>       fn _event -> :ok end,
      ...>       provider: Synapse.Provider.Fake,
      ...>       workspace_opener: opener
      ...>     )
      ...>     {:ok, result} = Synapse.Runtime.await(run)
      ...>     {result.text, result.turns, result.tool_calls}
      ...>   end
      ...> )
      {"Finished", 1, 0}

  See `docs/plan/PLAN-RUNTIME.md` for the confirmed ownership and implementation
  phases.
  """

  alias Synapse.Run.Request
  alias Synapse.Runtime.{AgentTask, Error, Options, Run}
  alias Synapse.Runtime.RunServer.{Message, State}
  alias Synapse.Runtime.Supervisor, as: RuntimeSupervisor

  @max_receive_timeout 4_294_967_295

  @typedoc "A trusted synchronous consumer of one validated Run Event."
  @type event_sink :: (Synapse.Run.Event.t() -> :ok)

  @typedoc "A successful or failed terminal produced by the supervised Agent task."
  @type agent_terminal ::
          {:ok, Synapse.Agent.Result.t()}
          | {:error, Synapse.Agent.Error.t()}

  @typedoc "An Agent terminal or outer Runtime coordinator-loss failure."
  @type await_terminal ::
          agent_terminal()
          | {:error, Error.t()}

  @typedoc "The complete MVP await result including non-terminal waiting errors."
  @type await_result ::
          await_terminal()
          | {:error,
             :await_timeout
             | :already_awaited
             | :not_owner
             | :invalid_run
             | :invalid_timeout}

  @typedoc "Starting one accepted run or rejecting trusted configuration."
  @type start_result :: {:ok, Run.t()} | {:error, Error.t()}

  @typedoc "Idempotent cancellation request or malformed handle rejection."
  @type cancel_result :: :ok | {:error, :invalid_run}

  @doc """
  Starts one supervised Agent run after a synchronous Workspace-ready handshake.

  Request, event sink, and trusted options are normalized before any resource is
  allocated. The Agent task derives exact Workspace Access, opens Workspace with
  itself as owner, validates Agent Context, and waits for RunServer acceptance
  before Runner can emit `RunStarted`. Workspace opening currently has no Runtime
  timeout because the lower open protocol is synchronously blocking.
  """
  @spec start_run(Request.t(), event_sink(), keyword() | map() | Options.t()) :: start_result()
  def start_run(request, event_sink, options \\ []) do
    with {:ok, request} <- normalize_request(request),
         true <- is_function(event_sink, 1) or {:error, :invalid_options},
         {:ok, options} <- normalize_options(options),
         {:ok, controls} <- allocate_controls(),
         {:ok, state} <- initial_state(request, event_sink, controls),
         {:ok, server} <-
           RuntimeSupervisor.start_run_server(
             state,
             agent_callback(request, options, controls)
           ) do
      await_startup(server, request.id, controls)
    else
      {:error, :invalid_request} -> runtime_error(:invalid_run_request, nil)
      {:error, :invalid_options} -> runtime_error(:invalid_runtime_options, safe_run_id(request))
      {:error, %Error{}} = error -> error
      {:error, _reason} -> runtime_error(:runtime_unavailable, safe_run_id(request))
    end
  end

  @doc """
  Requests cancellation asynchronously from any trusted process holding the Run.

  Runtime atomically marks persistent cancellation before sending the matching
  `{:cancel, cancel_ref}` message to the Agent task. Repeated and post-terminal
  calls are harmless and send no duplicate message. Observe the structured
  terminal through `await/2`.
  """
  @spec cancel(Run.t()) :: cancel_result()
  def cancel(run) do
    if Run.valid?(run) do
      case compare_exchange(run.cancellation, 0, 1) do
        :ok ->
          send(run.task, {:cancel, run.cancel_ref})
          :ok

        1 ->
          :ok

        _invalid ->
          {:error, :invalid_run}
      end
    else
      {:error, :invalid_run}
    end
  end

  @doc """
  Waits for one accepted run terminal as the process that started the run.

  Timeout must be `:infinity` or a non-negative integer. A malformed waiting
  policy is distinct from an await timeout and from a malformed Run handle. An
  await timeout stops only this receive, restores the one await right, and does
  not cancel or kill the run. A terminal or coordinator-loss result consumes the
  right permanently.
  """
  @spec await(Run.t(), timeout()) :: await_result()
  def await(run, timeout \\ :infinity)

  def await(run, timeout) do
    cond do
      not valid_timeout?(timeout) ->
        {:error, :invalid_timeout}

      not Run.valid?(run) ->
        {:error, :invalid_run}

      self() != run.owner ->
        {:error, :not_owner}

      true ->
        begin_await(run, timeout)
    end
  end

  defp normalize_request(%Request{} = request) do
    case Request.new(Map.from_struct(request)) do
      {:ok, request} -> {:ok, request}
      {:error, _reason} -> {:error, :invalid_request}
    end
  end

  defp normalize_request(_request), do: {:error, :invalid_request}

  defp normalize_options(%Options{} = options) do
    case Options.new(Map.from_struct(options)) do
      {:ok, options} -> {:ok, options}
      {:error, _reason} -> {:error, :invalid_options}
    end
  end

  defp normalize_options(options) do
    case Options.new(options) do
      {:ok, options} -> {:ok, options}
      {:error, _reason} -> {:error, :invalid_options}
    end
  end

  defp allocate_controls do
    try do
      controls = %{
        run_ref: make_ref(),
        cancel_ref: make_ref(),
        cancellation: :atomics.new(1, signed: false),
        await_state: :atomics.new(1, signed: false)
      }

      :atomics.put(controls.cancellation, 1, 0)
      :atomics.put(controls.await_state, 1, 0)
      {:ok, controls}
    rescue
      _exception -> {:error, :control_allocation_failed}
    catch
      _kind, _reason -> {:error, :control_allocation_failed}
    end
  end

  defp initial_state(request, event_sink, controls) do
    State.new(
      run_id: request.id,
      owner: self(),
      run_ref: controls.run_ref,
      cancel_ref: controls.cancel_ref,
      cancellation: controls.cancellation,
      await_state: controls.await_state,
      event_sink: event_sink
    )
  end

  defp agent_callback(request, options, controls) do
    fn run_server ->
      AgentTask.run(
        run_server,
        controls.run_ref,
        request,
        options,
        controls.cancel_ref,
        controls.cancellation
      )
    end
  end

  defp await_startup(server, run_id, controls) do
    monitor = Process.monitor(server)

    receive do
      %Message{
        kind: :started,
        run_ref: run_ref,
        worker: worker,
        payload: ^server
      }
      when run_ref == controls.run_ref and is_pid(worker) ->
        Process.demonitor(monitor, [:flush])
        build_run(server, worker, run_id, controls)

      %Message{
        kind: :start_failed,
        run_ref: run_ref,
        worker: worker,
        payload: {^server, reason}
      }
      when run_ref == controls.run_ref and is_pid(worker) and
             reason in [:workspace_open_failed, :runtime_unavailable] ->
        await_start_failure_down(server, monitor)
        runtime_error(reason, run_id)

      {:DOWN, ^monitor, :process, ^server, _reason} ->
        recheck_startup_after_down(server, run_id, controls)
    end
  end

  defp recheck_startup_after_down(server, run_id, controls) do
    receive do
      %Message{
        kind: :started,
        run_ref: run_ref,
        worker: worker,
        payload: ^server
      }
      when run_ref == controls.run_ref and is_pid(worker) ->
        build_run(server, worker, run_id, controls)

      %Message{
        kind: :start_failed,
        run_ref: run_ref,
        worker: worker,
        payload: {^server, reason}
      }
      when run_ref == controls.run_ref and is_pid(worker) and
             reason in [:workspace_open_failed, :runtime_unavailable] ->
        runtime_error(reason, run_id)
    after
      0 -> runtime_error(:runtime_unavailable, run_id)
    end
  end

  defp await_start_failure_down(server, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^server, _reason} -> :ok
    end
  end

  defp build_run(server, worker, run_id, controls) do
    run = %Run{
      id: run_id,
      owner: self(),
      server: server,
      task: worker,
      run_ref: controls.run_ref,
      cancel_ref: controls.cancel_ref,
      cancellation: controls.cancellation,
      await_state: controls.await_state
    }

    if Run.valid?(run) do
      {:ok, run}
    else
      Process.exit(server, :kill)
      runtime_error(:runtime_unavailable, run_id)
    end
  end

  defp begin_await(run, timeout) do
    case compare_exchange(run.await_state, 0, 1) do
      :ok ->
        monitor = Process.monitor(run.server)
        deadline = await_deadline(timeout)
        wait_for_terminal_or_down(run, monitor, deadline)

      current when current in [1, 2] ->
        {:error, :already_awaited}

      _invalid ->
        {:error, :invalid_run}
    end
  end

  defp wait_for_terminal_or_down(run, monitor, :infinity) do
    receive do
      %Message{kind: :terminal, run_ref: run_ref, worker: nil, payload: payload} = message
      when run_ref == run.run_ref ->
        case normalize_await_terminal(payload, run.id) do
          {:ok, terminal} -> await_down_after_terminal(run, monitor, :infinity, message, terminal)
          :error -> wait_for_terminal_or_down(run, monitor, :infinity)
        end

      {:DOWN, ^monitor, :process, server, _reason} when server == run.server ->
        terminal_after_down(run)
    end
  end

  defp wait_for_terminal_or_down(run, monitor, deadline) do
    timeout = receive_timeout(deadline)

    receive do
      %Message{kind: :terminal, run_ref: run_ref, worker: nil, payload: payload} = message
      when run_ref == run.run_ref ->
        case normalize_await_terminal(payload, run.id) do
          {:ok, terminal} -> await_down_after_terminal(run, monitor, deadline, message, terminal)
          :error -> wait_for_terminal_or_down(run, monitor, deadline)
        end

      {:DOWN, ^monitor, :process, server, _reason} when server == run.server ->
        terminal_after_down(run)
    after
      timeout ->
        if deadline_elapsed?(deadline),
          do: await_timeout(run, monitor),
          else: wait_for_terminal_or_down(run, monitor, deadline)
    end
  end

  defp await_down_after_terminal(run, monitor, :infinity, _message, terminal) do
    receive do
      {:DOWN, ^monitor, :process, server, _reason} when server == run.server ->
        consume_await(run, terminal)
    end
  end

  defp await_down_after_terminal(run, monitor, deadline, message, terminal) do
    timeout = receive_timeout(deadline)

    receive do
      {:DOWN, ^monitor, :process, server, _reason} when server == run.server ->
        consume_await(run, terminal)
    after
      timeout ->
        if deadline_elapsed?(deadline) do
          send(self(), message)
          await_timeout(run, monitor)
        else
          await_down_after_terminal(run, monitor, deadline, message, terminal)
        end
    end
  end

  defp terminal_after_down(run) do
    case queued_terminal(run) do
      {:ok, terminal} -> consume_await(run, terminal)
      :none -> consume_await(run, runtime_lost(run.id))
    end
  end

  defp queued_terminal(run) do
    receive do
      %Message{kind: :terminal, run_ref: run_ref, worker: nil, payload: payload}
      when run_ref == run.run_ref ->
        case normalize_await_terminal(payload, run.id) do
          {:ok, terminal} -> {:ok, terminal}
          :error -> queued_terminal(run)
        end
    after
      0 -> :none
    end
  end

  defp normalize_await_terminal({:ok, %Synapse.Agent.Result{} = result}, run_id) do
    case Synapse.Agent.Result.new(Map.from_struct(result)) do
      {:ok, result} when result.run_id == run_id -> {:ok, {:ok, result}}
      _invalid -> :error
    end
  end

  defp normalize_await_terminal({:error, %Synapse.Agent.Error{} = error}, run_id) do
    case Synapse.Agent.Error.new(Map.from_struct(error)) do
      {:ok, error} when error.run_id == run_id -> {:ok, {:error, error}}
      _invalid -> :error
    end
  end

  defp normalize_await_terminal(_terminal, _run_id), do: :error

  defp consume_await(run, terminal) do
    case compare_exchange(run.await_state, 1, 2) do
      :ok -> terminal
      _invalid -> {:error, :invalid_run}
    end
  end

  defp await_timeout(run, monitor) do
    Process.demonitor(monitor, [:flush])

    case compare_exchange(run.await_state, 1, 0) do
      :ok -> {:error, :await_timeout}
      _invalid -> {:error, :invalid_run}
    end
  end

  defp compare_exchange(cell, expected, desired) do
    :atomics.compare_exchange(cell, 1, expected, desired)
  rescue
    _exception -> :invalid
  catch
    _kind, _reason -> :invalid
  end

  defp runtime_lost(run_id) do
    {:ok, error} = Error.new(reason: :runtime_lost, run_id: run_id)
    {:error, error}
  end

  defp valid_timeout?(:infinity), do: true
  defp valid_timeout?(timeout), do: is_integer(timeout) and timeout >= 0

  defp await_deadline(:infinity), do: :infinity
  defp await_deadline(timeout), do: monotonic_milliseconds() + timeout

  defp receive_timeout(deadline),
    do: min(max(deadline - monotonic_milliseconds(), 0), @max_receive_timeout)

  defp deadline_elapsed?(deadline), do: monotonic_milliseconds() >= deadline
  defp monotonic_milliseconds, do: :erlang.monotonic_time(:millisecond)

  defp runtime_error(reason, run_id) do
    {:ok, error} = Error.new(reason: reason, run_id: run_id)
    {:error, error}
  end

  defp safe_run_id(%Request{} = request) do
    if Request.valid?(request), do: request.id, else: nil
  end

  defp safe_run_id(_request), do: nil
end
