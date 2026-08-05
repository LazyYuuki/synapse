defmodule Synapse.Runtime.Supervisor do
  @moduledoc """
  Dynamically supervises the one active MVP Runtime RunServer.

  The supervisor is permanent infrastructure with `max_children: 1`; each
  RunServer is temporary. Admission calls `DynamicSupervisor.start_child/2`
  directly so capacity checking and child start are one serialized operation.
  Capacity and infrastructure failures are normalized to sanitized Runtime Error
  values and never expose child-init or supervisor exit terms.

  The internal RunServer handoff supports public Runtime startup and deterministic
  topology tests. Only `Synapse.Runtime` is a supported
  caller lifecycle boundary; this supervisor does not return a Run handle or
  invoke Agent Runner itself.

  `start_run_server/3` is intentionally `@doc false`: it is an internal ownership
  seam used by Runtime and isolated supervision tests, not a second public start
  API.
  """

  use DynamicSupervisor

  alias Synapse.Runtime.{Error, RunServer}
  alias Synapse.Runtime.RunServer.State
  alias Synapse.Tool.Validation

  @doc "Starts the named production supervisor or an unnamed isolated copy."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    start_options = if is_nil(name), do: [], else: [name: name]
    DynamicSupervisor.start_link(__MODULE__, :ok, start_options)
  end

  @doc false
  @spec start_run_server(State.t(), (pid() -> term()), keyword()) ::
          {:ok, pid()} | {:error, Error.t()}
  def start_run_server(state, agent, options \\ []) do
    supervisor = Keyword.get(options, :supervisor, __MODULE__)
    task_supervisor = Keyword.get(options, :task_supervisor, Synapse.TaskSupervisor)
    run_id = safe_run_id(state)

    try do
      case DynamicSupervisor.start_child(
             supervisor,
             {RunServer, {state, agent, task_supervisor}}
           ) do
        {:ok, pid} -> {:ok, pid}
        {:error, :max_children} -> runtime_error(:runtime_busy, run_id)
        {:error, _reason} -> runtime_error(:runtime_unavailable, run_id)
      end
    catch
      :exit, _reason -> runtime_error(:runtime_unavailable, run_id)
    end
  end

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one, max_children: 1)

  defp safe_run_id(%State{run_id: run_id}) do
    if Validation.identifier?(run_id, 256), do: run_id, else: nil
  end

  defp safe_run_id(_state), do: nil

  defp runtime_error(reason, run_id) do
    {:ok, error} = Error.new(reason: reason, run_id: run_id)
    {:error, error}
  end
end
