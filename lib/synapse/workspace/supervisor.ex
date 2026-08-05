defmodule Synapse.Workspace.Supervisor do
  @moduledoc """
  Dynamically supervises temporary real Workspace MutationServers.

  The supervisor is permanent infrastructure, but every opened real Workspace is
  a `restart: :temporary` child. Explicit close, opening-owner death, an abnormal
  MutationServer exit, or infrastructure shutdown removes the child without
  replay. Fake Workspace remains independently owner-monitored and is never
  inserted into this supervisor.
  """

  use DynamicSupervisor

  alias Synapse.Workspace.{MutationServer, OpenRequest}

  @doc "Starts the named production supervisor or an unnamed isolated copy."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    start_options = if is_nil(name), do: [], else: [name: name]
    DynamicSupervisor.start_link(__MODULE__, :ok, start_options)
  end

  @doc false
  @spec start_mutation_server(OpenRequest.t(), reference(), GenServer.server()) ::
          DynamicSupervisor.on_start_child() | {:error, :workspace_supervisor_unavailable}
  def start_mutation_server(request, token, supervisor \\ __MODULE__) do
    DynamicSupervisor.start_child(supervisor, {MutationServer, {request, token}})
  catch
    :exit, _reason -> {:error, :workspace_supervisor_unavailable}
  end

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)
end
