defmodule Synapse.Application do
  @moduledoc """
  Starts and owns the root Synapse supervision tree.

  Runtime starts exactly three permanent infrastructure children under
  `Synapse.Supervisor`: Workspace DynamicSupervisor, Task.Supervisor, and Runtime
  DynamicSupervisor. Temporary RunServer, Agent, and real Workspace children are
  started only on demand and never restarted after side effects.

  The OTP application controller calls `start/2`; application code should not
  call it directly.
  """

  use Application

  @doc """
  Starts the named root supervisor for Synapse.

  The root uses `:one_for_one`, starts infrastructure in dependency order, and
  relies on reverse OTP shutdown order so Workspace cleanup remains available
  while Runtime and Agent children terminate.
  """
  @impl true
  @spec start(Application.start_type(), term()) :: Supervisor.on_start()
  def start(_type, _args) do
    Synapse.Supervisor.start_link()
  end
end
