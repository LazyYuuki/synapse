defmodule Synapse.Runtime.Run do
  @moduledoc """
  Opaque control handle for one accepted Runtime run.

  Runtime creates this value only after the Agent task has opened Workspace,
  validated Agent Context, and completed the ready/accept handshake. Callers pass
  it only to `Synapse.Runtime.cancel/1` and `Synapse.Runtime.await/2`. The starting
  owner may deliberately share it with one trusted lifecycle adapter for
  non-owner cancellation, but it must not be constructed, persisted, serialized,
  exposed beyond that trusted boundary, or inspected for internal authority.

  Await remains restricted to the process that called `start_run/3`; sharing the
  handle does not transfer the await right.

  Opaqueness and redacted inspection reduce accidental misuse. They are not an
  unforgeable security boundary against arbitrary code already executing in the
  same BEAM VM. Runtime revalidates structure and atomics resources before use.
  """

  alias Synapse.Runtime.RunServer
  alias Synapse.Tool.Validation

  @max_run_id_bytes 256

  @enforce_keys [
    :id,
    :owner,
    :server,
    :task,
    :run_ref,
    :cancel_ref,
    :cancellation,
    :await_state
  ]
  defstruct @enforce_keys

  @typedoc "Opaque Runtime identity, process, cancellation, and await authority."
  @opaque t :: %__MODULE__{
            id: String.t(),
            owner: pid(),
            server: pid(),
            task: pid(),
            run_ref: reference(),
            cancel_ref: reference(),
            cancellation: reference(),
            await_state: reference()
          }

  @doc "Returns whether a Run handle has complete bounded structural authority."
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = run) do
    Validation.identifier?(run.id, @max_run_id_bytes) and is_pid(run.owner) and
      is_pid(run.server) and is_pid(run.task) and is_reference(run.run_ref) and
      is_reference(run.cancel_ref) and
      pairwise_distinct?([run.run_ref, run.cancel_ref, run.cancellation, run.await_state]) and
      RunServer.valid_cancellation_cell?(run.cancellation) and
      RunServer.valid_await_cell?(run.await_state)
  end

  def valid?(_run), do: false

  defp pairwise_distinct?(values), do: length(Enum.uniq(values)) == length(values)
end

defimpl Inspect, for: Synapse.Runtime.Run do
  def inspect(_run, _options), do: "#Synapse.Runtime.Run<opaque>"
end
