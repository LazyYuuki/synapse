# Private absolute path observation retained only during one backend operation.
defmodule Synapse.Workspace.Resolved do
  @moduledoc false

  @enforce_keys [:relative, :absolute, :type, :stat]
  defstruct [:relative, :absolute, :type, :stat]

  @type t :: %__MODULE__{
          relative: String.t(),
          absolute: String.t(),
          type: :file | :directory | :missing,
          stat: File.Stat.t() | nil
        }
end
