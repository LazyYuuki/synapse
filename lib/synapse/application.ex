defmodule Synapse.Application do
  @moduledoc """
  Starts and owns the root Synapse supervision tree.

  The application supervisor is intentionally empty during project bootstrap.
  Children will be added only when a component has a real process lifecycle or
  mutable state to own. This keeps pure transformations out of GenServers and
  makes every future supervised child an explicit architectural decision.

  The OTP application controller calls `start/2`; application code should not
  call it directly.
  """

  use Application

  @doc """
  Starts the named root supervisor for Synapse.

  The supervisor uses `:one_for_one` so a future child can be restarted without
  restarting unrelated components. Side-effecting one-shot operations will be
  temporary supervised tasks rather than permanent children.
  """
  @impl true
  @spec start(Application.start_type(), term()) :: Supervisor.on_start()
  def start(_type, _args) do
    children = []

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Synapse.Supervisor
    )
  end
end
