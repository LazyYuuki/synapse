defmodule Synapse.Supervisor do
  @moduledoc """
  Owns the fixed core and optional local API supervision tree.

  The root is a static `Supervisor` because its infrastructure children are known
  when the application starts and should be restarted permanently. Each
  dynamic child owner has a narrower role:

  * `Synapse.Workspace.Supervisor` dynamically owns temporary real Workspace
    MutationServers;
  * `Synapse.TaskSupervisor` is a `Task.Supervisor` for temporary linked Agent
    tasks;
  * `Synapse.Runtime.Supervisor` dynamically owns at most one temporary RunServer.

  The optional API Supervisor starts after Runtime. OTP therefore stops API
  listener/session ownership first, Runtime coordination next, Agent tasks second,
  and Workspace owners last. Infrastructure supervisors use permanent restart and
  infinite supervisor shutdown; every side-effecting dynamic child is temporary
  and is never replayed automatically.

  ```text
  Synapse.Supervisor                 Supervisor, :one_for_one
  |-- Synapse.Workspace.Supervisor   DynamicSupervisor
  |   `-- Workspace.MutationServer   temporary per real Handle
  |-- Synapse.TaskSupervisor         Task.Supervisor
  |   `-- Agent Runner Task          temporary, linked to RunServer
  |-- Synapse.Runtime.Supervisor      DynamicSupervisor, max_children: 1
  |   `-- Runtime.RunServer           temporary per accepted run
  `-- Synapse.API.Supervisor          optional, :rest_for_one
      |-- API.RunManager
      |-- API.SessionSupervisor       DynamicSupervisor, max_children: 1
      `-- Bandit                      loopback listener
  ```

  The disabled configuration preserves the exact original three-child tree.
  """

  use Supervisor

  @typedoc "Names used by one production or isolated copy of the MVP tree."
  @type option ::
          {:name, Supervisor.name() | nil}
          | {:workspace_supervisor, GenServer.name() | nil}
          | {:task_supervisor, GenServer.name() | nil}
          | {:runtime_supervisor, GenServer.name() | nil}
          | {:api_config, Synapse.API.Config.t()}
          | {:api_supervisor, Supervisor.name() | nil}
          | {:api_manager, GenServer.name()}
          | {:api_session_supervisor, GenServer.name()}
          | {:api_runtime, struct()}

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
    api_config = Keyword.get(options, :api_config, Synapse.API.Config.default())

    core = [
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

    cond do
      not Synapse.API.Config.valid?(api_config) ->
        raise ArgumentError, "invalid Synapse supervisor options"

      not api_config.enabled ->
        core

      true ->
        api_name = Keyword.get(options, :api_supervisor, Synapse.API.Supervisor)
        manager = Keyword.get(options, :api_manager, Synapse.API.RunManager)
        sessions = Keyword.get(options, :api_session_supervisor, Synapse.API.SessionSupervisor)

        runtime =
          Keyword.get(options, :api_runtime, Synapse.API.RunSession.RuntimeBoundary.default())

        core ++
          [
            Supervisor.child_spec(
              {Synapse.API.Supervisor,
               name: api_name,
               config: api_config,
               manager: manager,
               session_supervisor: sessions,
               runtime: runtime},
              id: Synapse.API.Supervisor,
              restart: :permanent,
              shutdown: :infinity,
              type: :supervisor
            )
          ]
    end
  end

  @impl true
  def init(options), do: Supervisor.init(child_specs(options), strategy: :one_for_one)

  defp named_options(nil), do: []
  defp named_options(name), do: [name: name]
end
