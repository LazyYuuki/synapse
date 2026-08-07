defmodule Synapse.API.RunSession.RuntimeBoundary do
  @moduledoc false

  @enforce_keys [:start_run, :await, :cancel]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          start_run: (struct(), function(), struct() -> term()),
          await: (struct(), timeout() -> term()),
          cancel: (struct() -> term())
        }

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, :invalid_runtime_boundary}
  def new(attrs) when is_list(attrs) or is_map(attrs) do
    attrs = Map.new(attrs)

    if Map.keys(attrs) |> Enum.sort() == [:await, :cancel, :start_run] and
         is_function(attrs.start_run, 3) and is_function(attrs.await, 2) and
         is_function(attrs.cancel, 1) do
      {:ok, struct!(__MODULE__, attrs)}
    else
      {:error, :invalid_runtime_boundary}
    end
  rescue
    _exception -> {:error, :invalid_runtime_boundary}
  end

  def new(_attrs), do: {:error, :invalid_runtime_boundary}

  @spec default() :: t()
  def default do
    %__MODULE__{
      start_run: &Synapse.Runtime.start_run/3,
      await: &Synapse.Runtime.await/2,
      cancel: &Synapse.Runtime.cancel/1
    }
  end

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = boundary),
    do: match?({:ok, ^boundary}, new(Map.from_struct(boundary)))

  def valid?(_boundary), do: false
end

defmodule Synapse.API.RunSession.StartArguments do
  @moduledoc false

  @enforce_keys [:manager, :run_id, :command, :config, :runtime]
  defstruct @enforce_keys
end

defmodule Synapse.API.RunSession.State do
  @moduledoc false

  @enforce_keys [
    :phase,
    :manager,
    :manager_monitor,
    :run_id,
    :command,
    :config,
    :runtime_run,
    :runtime
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          phase: :starting | :awaiting | :settling,
          manager: pid(),
          manager_monitor: reference(),
          run_id: String.t(),
          command: struct() | nil,
          config: struct() | nil,
          runtime_run: struct() | nil,
          runtime: Synapse.API.RunSession.RuntimeBoundary.t()
        }
end

defmodule Synapse.API.RunSession do
  @moduledoc """
  Temporary owner process for one API-started Runtime run.

  The process that calls `Runtime.start_run/3` is the only process allowed to call
  `Runtime.await/2`. RunSession preserves that identity across one-second await
  polls while returning to its GenServer mailbox between polls. A socket never
  owns, awaits, or cancels Runtime work merely because it disconnects.

  `init/1` performs only bounded contract validation. Runtime startup begins from
  `handle_continue/2`, so synchronous Workspace opening cannot hold RunManager's
  child-admission call. Client cancellation during that interval remains pending
  in Manager and is applied immediately when this process registers the handle.
  Cancellation cannot interrupt synchronous Workspace opening before that Runtime
  handle exists.

  RunSession monitors Manager and requests Runtime cancellation if API projection
  ownership disappears. Catchable process shutdown also requests idempotent
  cancellation from `terminate/2`; neither path waits indefinitely for settlement.

  Runtime invokes the event sink from its RunServer/Agent path, not necessarily from
  this process. Manager therefore validates events by the exact active run identity
  and closed Event contract rather than by event-sink caller PID. Only this admitted
  RunSession may register the Runtime handle or confirm settlement.

  See the [local API guide](api.html) for the complete start, cancellation, terminal,
  and failure traces.
  """

  use GenServer

  alias Synapse.Agent.{Error, Result}
  alias Synapse.API.Command.{Cancel, Start}
  alias Synapse.API.{Config, RunManager}
  alias Synapse.API.RunSession.{RuntimeBoundary, StartArguments, State}
  alias Synapse.Run.Request
  alias Synapse.Runtime.Error, as: RuntimeError
  alias Synapse.Runtime.Options
  alias Synapse.Runtime.Run
  alias Synapse.Runtime.RunServer.Message
  alias Synapse.Tool.CapabilitySet

  @await_timeout 1_000

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(arguments) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [arguments]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }
  end

  @doc false
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(arguments), do: GenServer.start_link(__MODULE__, arguments)

  @doc false
  @spec session_starter(DynamicSupervisor.supervisor(), Config.t(), RuntimeBoundary.t()) ::
          (pid(), String.t(), struct() -> DynamicSupervisor.on_start_child())
  def session_starter(supervisor, %Config{} = config, %RuntimeBoundary{} = runtime) do
    fn manager, run_id, command ->
      arguments = %StartArguments{
        manager: manager,
        run_id: run_id,
        command: command,
        config: config,
        runtime: runtime
      }

      DynamicSupervisor.start_child(supervisor, {__MODULE__, arguments})
    end
  end

  @impl true
  def init(%StartArguments{} = arguments) do
    with true <- is_pid(arguments.manager),
         true <- Config.valid?(arguments.config),
         true <- Cancel.valid_run_id?(arguments.run_id, arguments.config),
         true <- Start.valid?(arguments.command, arguments.config),
         true <- RuntimeBoundary.valid?(arguments.runtime) do
      Process.flag(:trap_exit, true)
      manager_monitor = Process.monitor(arguments.manager)

      {:ok,
       %State{
         phase: :starting,
         manager: arguments.manager,
         manager_monitor: manager_monitor,
         run_id: arguments.run_id,
         command: arguments.command,
         config: arguments.config,
         runtime_run: nil,
         runtime: arguments.runtime
       }, {:continue, :start_runtime}}
    else
      _invalid -> {:stop, :invalid_run_session}
    end
  end

  def init(_arguments), do: {:stop, :invalid_run_session}

  @impl true
  def handle_continue(:start_runtime, %State{phase: :starting} = state) do
    case build_runtime_input(state) do
      {:ok, request, options} ->
        state
        |> start_runtime(request, options)
        |> handle_runtime_start(state)

      {:error, reason} when reason in [:invalid_run_request, :invalid_runtime_options] ->
        settle_prehandle(state, runtime_error(reason, state.run_id))
    end
  end

  @impl true
  def handle_info(:timeout, %State{phase: :awaiting, runtime_run: %Run{} = run} = state) do
    poll_await(state, run)
  end

  def handle_info(
        %Message{kind: :terminal, run_ref: run_ref, worker: nil} = message,
        %State{phase: :awaiting, runtime_run: %Run{run_ref: run_ref} = run} = state
      ) do
    send(self(), message)
    poll_await(state, run)
  end

  def handle_info(
        {:DOWN, monitor, :process, manager, _reason},
        %State{manager_monitor: monitor, manager: manager} = state
      ),
      do: cancel_and_stop(state)

  def handle_info(_message, %State{phase: :awaiting} = state), do: {:noreply, state, 0}
  def handle_info(_message, state), do: {:noreply, state}

  defp poll_await(state, run) do
    case safe_await(state.runtime, run) do
      {:error, :await_timeout} ->
        {:noreply, state, 0}

      settlement when is_tuple(settlement) ->
        if valid_settlement?(settlement, state.run_id) do
          settle_and_stop(state, settlement)
        else
          cancel_and_stop(state)
        end

      _invalid ->
        cancel_and_stop(state)
    end
  end

  @impl true
  def terminate(_reason, %State{runtime_run: %Run{} = run, runtime: runtime}) do
    safe_cancel(runtime, run)
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

  defp build_runtime_input(%State{command: command, config: config, run_id: run_id}) do
    with {:ok, capabilities} <- CapabilitySet.new(Map.from_struct(config.capabilities)),
         {:ok, budget} <- Config.lower_budget(config, Map.from_struct(command.budget)),
         {:ok, request} <-
           Request.new(
             id: run_id,
             prompt: command.prompt,
             cwd: command.cwd,
             model: command.model,
             capabilities: capabilities,
             budget: budget
           ),
         {:ok, options} <- Options.new(Map.from_struct(config.runtime_options)) do
      {:ok, request, options}
    else
      {:error, {:runtime_options, _reason}} -> {:error, :invalid_runtime_options}
      {:error, _reason} -> {:error, :invalid_run_request}
    end
  rescue
    _exception -> {:error, :invalid_run_request}
  catch
    _kind, _reason -> {:error, :invalid_run_request}
  end

  defp event_sink(state), do: fn event -> RunManager.record_event(state.manager, event) end

  defp start_runtime(state, request, options),
    do: safe_start(state.runtime, request, event_sink(state), options)

  defp handle_runtime_start({:ok, %Run{} = run}, state) do
    if Run.valid?(run) and run.id == state.run_id and run.owner == self() do
      case RunManager.register_runtime_run(state.manager, state.run_id, run) do
        :ok ->
          {:noreply,
           %{
             state
             | phase: :awaiting,
               command: nil,
               config: nil,
               runtime_run: run
           }, 0}

        {:error, :closed} ->
          safe_cancel(state.runtime, run)
          {:stop, :normal, %{state | phase: :settling, command: nil, config: nil}}
      end
    else
      safe_cancel(state.runtime, run)
      settle_prehandle(state, runtime_error(:runtime_unavailable, state.run_id))
    end
  end

  defp handle_runtime_start({:error, %RuntimeError{} = error}, state),
    do: settle_prehandle(state, normalize_runtime_error(error, state.run_id))

  defp handle_runtime_start(_invalid, state),
    do: settle_prehandle(state, runtime_error(:runtime_unavailable, state.run_id))

  defp safe_start(runtime, request, sink, options) do
    runtime.start_run.(request, sink, options)
  rescue
    _exception -> {:error, :runtime_boundary_failed}
  catch
    _kind, _reason -> {:error, :runtime_boundary_failed}
  end

  defp safe_await(runtime, run) do
    runtime.await.(run, @await_timeout)
  rescue
    _exception -> {:error, :runtime_await_contract_failed}
  catch
    _kind, _reason -> {:error, :runtime_await_contract_failed}
  end

  defp safe_cancel(runtime, run) do
    try do
      runtime.cancel.(run)
    rescue
      _exception -> :ok
    catch
      _kind, _reason -> :ok
    end

    :ok
  end

  defp settle_prehandle(state, %RuntimeError{} = error) do
    _result = RunManager.settle(state.manager, state.run_id, {:error, error})
    {:stop, :normal, %{state | phase: :settling, command: nil, config: nil}}
  end

  defp settle_and_stop(state, settlement) do
    case RunManager.settle(state.manager, state.run_id, settlement) do
      :ok ->
        {:stop, :normal, %{state | phase: :settling, runtime_run: nil}}

      {:error, :closed} ->
        cancel_and_stop(state)
    end
  end

  defp cancel_and_stop(state) do
    if match?(%Run{}, state.runtime_run), do: safe_cancel(state.runtime, state.runtime_run)
    {:stop, :normal, %{state | phase: :settling, runtime_run: nil}}
  end

  defp valid_settlement?({:ok, %Result{} = result}, run_id) do
    case Result.new(Map.from_struct(result)) do
      {:ok, ^result} -> result.run_id == run_id
      {:error, _reason} -> false
    end
  end

  defp valid_settlement?({:error, %Error{} = error}, run_id) do
    case Error.new(Map.from_struct(error)) do
      {:ok, ^error} -> error.run_id == run_id
      {:error, _reason} -> false
    end
  end

  defp valid_settlement?({:error, %RuntimeError{} = error}, run_id),
    do: RuntimeError.valid?(error) and (is_nil(error.run_id) or error.run_id == run_id)

  defp valid_settlement?(_settlement, _run_id), do: false

  defp normalize_runtime_error(%RuntimeError{} = error, run_id) do
    if RuntimeError.valid?(error) and (is_nil(error.run_id) or error.run_id == run_id),
      do: error,
      else: runtime_error(:runtime_unavailable, run_id)
  end

  defp runtime_error(reason, run_id) do
    {:ok, error} = RuntimeError.new(reason: reason, run_id: run_id)
    error
  end
end

defimpl Inspect, for: Synapse.API.RunSession.RuntimeBoundary do
  def inspect(_runtime, _options), do: "#Synapse.API.RunSession.RuntimeBoundary<redacted>"
end

defimpl Inspect, for: Synapse.API.RunSession.StartArguments do
  def inspect(_arguments, _options), do: "#Synapse.API.RunSession.StartArguments<redacted>"
end

defimpl Inspect, for: Synapse.API.RunSession.State do
  def inspect(%{phase: phase}, _options) when phase in [:starting, :awaiting, :settling],
    do: "#Synapse.API.RunSession.State<phase=#{inspect(phase)} redacted>"

  def inspect(_state, _options), do: "#Synapse.API.RunSession.State<invalid redacted>"
end
