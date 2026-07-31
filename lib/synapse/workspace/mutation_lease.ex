# Opaque permit issued only by one handle's MutationServer.
defmodule Synapse.Workspace.MutationLease do
  @moduledoc false

  @enforce_keys [:server, :server_monitor, :reference, :holder, :operation_id, :kind]
  defstruct [:server, :server_monitor, :reference, :holder, :operation_id, :kind]

  @type kind :: :read | :write | :edit | :unknown_process
  @opaque t :: %__MODULE__{
            server: pid(),
            server_monitor: reference(),
            reference: reference(),
            holder: pid(),
            operation_id: String.t(),
            kind: kind()
          }
end

defimpl Inspect, for: Synapse.Workspace.MutationLease do
  def inspect(_lease, _options), do: "#Synapse.Workspace.MutationLease<opaque>"
end
