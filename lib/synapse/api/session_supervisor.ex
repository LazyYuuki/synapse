defmodule Synapse.API.SessionSupervisor do
  @moduledoc """
  Dynamic owner for at most one temporary API RunSession.

  RunSession children are temporary and are never restarted after side effects.
  The one-child ceiling mirrors RunManager's one-active-run reservation.

  If this supervisor fails, its active RunSession is lost, RunManager observes the
  child monitor and records owner loss, and `Synapse.API.Supervisor` restarts this
  process plus Bandit. No replacement RunSession is started.
  """

  use DynamicSupervisor

  @doc "Starts the named production or isolated session owner."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    start_options = if is_nil(name), do: [], else: [name: name]
    DynamicSupervisor.start_link(__MODULE__, :ok, start_options)
  end

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one, max_children: 1)
end
