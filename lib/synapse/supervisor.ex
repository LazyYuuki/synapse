defmodule Synapse.Supervisor do
  @moduledoc """
  Owns the fixed MVP infrastructure supervision tree.

  The root is a static `Supervisor` because its three infrastructure children are
  known when the application starts and should be restarted permanently. Each
  dynamic child owner has a narrower role:

  * `Synapse.Workspace.Supervisor` dynamically owns temporary real Workspace
    MutationServers;
  * `Synapse.TaskSupervisor` is a `Task.Supervisor` for temporary linked Agent
    tasks;
  * `Synapse.Runtime.Supervisor` dynamically owns at most one temporary RunServer.

  Children start in that order and OTP stops them in reverse order. Runtime
  coordination therefore stops first, Agent tasks second, and Workspace owners
  last. All three infrastructure supervisors use permanent restart and infinite
  supervisor shutdown; every side-effecting dynamic child is temporary and is
  never replayed automatically.

  ```text
  Synapse.Supervisor                 Supervisor, :one_for_one
  |-- Synapse.Workspace.Supervisor   DynamicSupervisor
  |   `-- Workspace.MutationServer   temporary per real Handle
  |-- Synapse.TaskSupervisor         Task.Supervisor
  |   `-- Agent Runner Task          temporary, linked to RunServer
  `-- Synapse.Runtime.Supervisor     DynamicSupervisor, max_children: 1
      `-- Runtime.RunServer          temporary per accepted run
  ```

  Future daemon registries, stores, brokers, managers, and transports are omitted
  until they have real state and ownership requirements.
  """

  use Supervisor

  @typedoc "Names used by one production or isolated copy of the MVP tree."
  @type option ::
          {:name, Supervisor.name() | nil}
          | {:workspace_supervisor, GenServer.name() | nil}
          | {:task_supervisor, GenServer.name() | nil}
          | {:runtime_supervisor, GenServer.name() | nil}

  @doc "Starts the fixed root tree, optionally unnamed for isolated topology tests."
  @spec start_link([option()]) :: Supervisor.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    start_options = if is_nil(name), do: [], else: [name: name]
    Supervisor.start_link(__MODULE__, options, start_options)
  end

  @doc "Returns the exact ordered infrastructure child specifications."
  @spec child_specs([option()]) :: [Supervisor.child_spec()]
  def child_specs(options \\ []) do
    workspace_name = Keyword.get(options, :workspace_supervisor, Synapse.Workspace.Supervisor)
    task_name = Keyword.get(options, :task_supervisor, Synapse.TaskSupervisor)
    runtime_name = Keyword.get(options, :runtime_supervisor, Synapse.Runtime.Supervisor)

    [
      Supervisor.child_spec(
        {Synapse.Workspace.Supervisor, name: workspace_name},
        id: Synapse.Workspace.Supervisor,
        restart: :permanent,
        shutdown: :infinity,
        type: :supervisor
      ),
      %{
        id: Synapse.TaskSupervisor,
        start: {Task.Supervisor, :start_link, [named_options(task_name)]},
        restart: :permanent,
        shutdown: :infinity,
        type: :supervisor
      },
      Supervisor.child_spec(
        {Synapse.Runtime.Supervisor, name: runtime_name},
        id: Synapse.Runtime.Supervisor,
        restart: :permanent,
        shutdown: :infinity,
        type: :supervisor
      )
    ]
  end

  @impl true
  def init(options), do: Supervisor.init(child_specs(options), strategy: :one_for_one)

  defp named_options(nil), do: []
  defp named_options(name), do: [name: name]
end
