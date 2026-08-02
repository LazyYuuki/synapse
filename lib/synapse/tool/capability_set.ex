defmodule Synapse.Tool.CapabilitySet do
  @moduledoc """
  Trusted fixed Tool authority for one Context workspace.

  Agent or Runtime creates this value from trusted local policy. Model text,
  decoded arguments, schemas, and extension output must never grant these fields.
  The value is an MVP operational policy seam, not an unforgeable token or a
  security boundary against arbitrary code already executing in the BEAM.
  """

  alias Synapse.Tool.Validation

  @enforce_keys [:fs_read, :fs_write, :process_exec]
  defstruct [:fs_read, :fs_write, :process_exec]

  @typedoc "Fixed read, write, and same-user process authority for one workspace."
  @type t :: %__MODULE__{
          fs_read: boolean(),
          fs_write: boolean(),
          process_exec: boolean()
        }

  @typedoc "A field-specific invalid trusted capability set."
  @type validation_error ::
          {:attributes, :must_be_keyword_or_map}
          | {:unknown_fields, [term()]}
          | {:fs_read, :must_be_boolean}
          | {:fs_write, :must_be_boolean}
          | {:process_exec, :must_be_boolean}

  @doc "Validates all three explicit boolean capability fields."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs) do
    with {:ok, attrs} <- Validation.attributes(attrs, [:fs_read, :fs_write, :process_exec]),
         true <- is_boolean(attrs[:fs_read]) or {:error, {:fs_read, :must_be_boolean}},
         true <- is_boolean(attrs[:fs_write]) or {:error, {:fs_write, :must_be_boolean}},
         true <-
           is_boolean(attrs[:process_exec]) or {:error, {:process_exec, :must_be_boolean}} do
      {:ok, struct!(__MODULE__, attrs)}
    end
  end

  @doc "Returns whether all fixed capability fields contain booleans."
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{fs_read: read, fs_write: write, process_exec: exec}),
    do: is_boolean(read) and is_boolean(write) and is_boolean(exec)

  def valid?(_capabilities), do: false

  @doc "Returns whether this trusted set grants one fixed Tool capability."
  @spec allows?(t(), Synapse.Tool.Spec.capability()) :: boolean()
  def allows?(%__MODULE__{} = capabilities, :fs_read),
    do: valid?(capabilities) and capabilities.fs_read

  def allows?(%__MODULE__{} = capabilities, :fs_write),
    do: valid?(capabilities) and capabilities.fs_write

  def allows?(%__MODULE__{} = capabilities, :process_exec),
    do: valid?(capabilities) and capabilities.process_exec

  def allows?(_capabilities, _capability), do: false
end
