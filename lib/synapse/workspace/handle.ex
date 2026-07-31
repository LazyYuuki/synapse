defmodule Synapse.Workspace.Handle do
  @moduledoc """
  An opaque backend handle scoped to one opened Workspace.

  Real and Fake backends create handles; callers pass them back to
  `Synapse.Workspace` and must not inspect or construct backend state. The handle
  is accidental-misuse protection inside a trusted BEAM node, not a security
  boundary against arbitrary code execution.

  The opening owner controls lifecycle. Normal close waits for accepted bounded
  work; owner or backend death invalidates the handle. Handles are backend-local
  and cannot be reconstructed, persisted, or transferred between Real and Fake.
  """

  alias Synapse.Workspace.{Access, Limits}

  @enforce_keys [:backend, :state, :token, :limits, :access]
  defstruct [:backend, :state, :token, :limits, :access]

  @typedoc "Opaque identity, limits, and access ceiling for a real or Fake backend."
  @opaque t :: %__MODULE__{
            backend: module(),
            state: pid() | reference(),
            token: reference(),
            limits: Limits.t(),
            access: Access.t()
          }
end

defimpl Inspect, for: Synapse.Workspace.Handle do
  def inspect(_handle, _options), do: "#Synapse.Workspace.Handle<opaque>"
end
