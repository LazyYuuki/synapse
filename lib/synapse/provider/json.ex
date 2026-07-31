defmodule Synapse.Provider.JSON do
  # Internal recursive validator shared by contracts; not a stable public API.
  @moduledoc false

  @spec object?(term()) :: boolean()
  def object?(value) when is_map(value) do
    Enum.all?(value, fn {key, item} ->
      is_binary(key) and String.valid?(key) and value?(item)
    end)
  end

  def object?(_value), do: false

  @spec value?(term()) :: boolean()
  def value?(value) when is_binary(value), do: String.valid?(value)
  def value?(value) when is_number(value) or is_boolean(value) or is_nil(value), do: true

  def value?(value) when is_list(value), do: Enum.all?(value, &value?/1)
  def value?(value) when is_map(value), do: object?(value)
  def value?(_value), do: false
end
