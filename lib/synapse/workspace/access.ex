defmodule Synapse.Workspace.Access do
  @moduledoc """
  A trusted operational access ceiling for one Workspace handle or operation.

  `read` and `write` govern Workspace file APIs. `exec` permits a same-user child
  process and is not an operating-system write sandbox. Runtime or Tool creates
  this value from trusted policy; model text must never grant access.
  """

  alias Synapse.Workspace.Validation

  @enforce_keys [:read, :write, :exec]
  defstruct [:read, :write, :exec]

  @typedoc "Fixed Workspace operation classes; no model input becomes an atom."
  @type operation :: :read | :write | :exec

  @typedoc "The maximum or reduced operation classes permitted to a caller."
  @type t :: %__MODULE__{read: boolean(), write: boolean(), exec: boolean()}

  @typedoc "A validation failure for trusted access data."
  @type validation_error ::
          {:attributes, :must_be_keyword_or_map}
          | {:unknown_fields, [term()]}
          | {:read, :must_be_boolean}
          | {:write, :must_be_boolean}
          | {:exec, :must_be_boolean}

  @doc "Validates explicit read, write, and process-execution authority."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs) do
    with {:ok, attrs} <- Validation.attributes(attrs, [:read, :write, :exec]),
         true <- is_boolean(attrs[:read]) or {:error, {:read, :must_be_boolean}},
         true <- is_boolean(attrs[:write]) or {:error, {:write, :must_be_boolean}},
         true <- is_boolean(attrs[:exec]) or {:error, {:exec, :must_be_boolean}} do
      {:ok, struct!(__MODULE__, attrs)}
    end
  end

  @doc "Returns whether this value permits one fixed Workspace operation class."
  @spec allows?(t(), operation()) :: boolean()
  def allows?(%__MODULE__{} = access, operation), do: Map.fetch!(access, operation)

  @doc "Returns whether all access fields contain validated booleans."
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{read: read, write: write, exec: exec}),
    do: is_boolean(read) and is_boolean(write) and is_boolean(exec)

  def valid?(_access), do: false

  @doc "Returns whether `reduced` grants no authority absent from `ceiling`."
  @spec within?(t(), t()) :: boolean()
  def within?(%__MODULE__{} = reduced, %__MODULE__{} = ceiling) do
    valid?(reduced) and valid?(ceiling) and
      Enum.all?([:read, :write, :exec], fn operation ->
        not allows?(reduced, operation) or allows?(ceiling, operation)
      end)
  end
end
