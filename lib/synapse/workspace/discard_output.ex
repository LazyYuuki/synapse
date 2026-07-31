# Bounded sink for fixed platform-probe output; retains no child bytes.
defmodule Synapse.Workspace.DiscardOutput do
  @moduledoc false
  defstruct []
end

defimpl Collectable, for: Synapse.Workspace.DiscardOutput do
  def into(original) do
    {original,
     fn
       accumulator, {:cont, data} when is_binary(data) -> accumulator
       accumulator, :done -> accumulator
       _accumulator, :halt -> :ok
     end}
  end
end
