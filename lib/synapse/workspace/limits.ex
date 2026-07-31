defmodule Synapse.Workspace.Limits do
  @moduledoc """
  Validated resource ceilings for one opened Workspace.

  Trusted application configuration may lower these defaults but cannot raise
  them above the hard Phase 0 ceilings. Individual read and process requests may
  lower limits again. Limits protect memory, model attention, Port construction,
  process lifetime, mailbox pressure, and diagnostic boundaries.
  """

  alias Synapse.Workspace.Validation

  @defaults %{
    max_path_bytes: 4_096,
    max_operation_id_bytes: 256,
    max_file_bytes: 8_388_608,
    default_read_lines: 100,
    max_read_lines: 1_000,
    default_read_bytes: 32_768,
    max_read_bytes: 65_536,
    max_diff_bytes: 32_768,
    max_process_arguments: 256,
    max_process_argument_bytes: 65_536,
    max_process_event_bytes: 16_384,
    max_process_events: 4_096,
    default_process_output_bytes: 65_536,
    max_process_output_bytes: 1_048_576,
    default_process_inactivity_ms: 180_000,
    max_process_inactivity_ms: 900_000,
    default_process_timeout_ms: 300_000,
    max_process_timeout_ms: 900_000,
    kill_grace_ms: 1_000,
    max_environment_entries: 512,
    max_environment_name_bytes: 256,
    max_environment_value_bytes: 32_768,
    max_diagnostic_bytes: 4_096,
    max_diagnostic_entries: 32,
    max_diagnostic_depth: 4,
    max_concurrent_operations: 64,
    max_fake_script_entries: 1_024
  }

  @hard_maximums @defaults
  @fields Map.keys(@defaults)

  defstruct Map.to_list(@defaults)

  @typedoc "Immutable ceilings copied into private Workspace backend state."
  @type t :: %__MODULE__{
          max_path_bytes: pos_integer(),
          max_operation_id_bytes: pos_integer(),
          max_file_bytes: pos_integer(),
          default_read_lines: pos_integer(),
          max_read_lines: pos_integer(),
          default_read_bytes: pos_integer(),
          max_read_bytes: pos_integer(),
          max_diff_bytes: pos_integer(),
          max_process_arguments: pos_integer(),
          max_process_argument_bytes: pos_integer(),
          max_process_event_bytes: pos_integer(),
          max_process_events: pos_integer(),
          default_process_output_bytes: pos_integer(),
          max_process_output_bytes: pos_integer(),
          default_process_inactivity_ms: pos_integer(),
          max_process_inactivity_ms: pos_integer(),
          default_process_timeout_ms: pos_integer(),
          max_process_timeout_ms: pos_integer(),
          kill_grace_ms: pos_integer(),
          max_environment_entries: pos_integer(),
          max_environment_name_bytes: pos_integer(),
          max_environment_value_bytes: pos_integer(),
          max_diagnostic_bytes: pos_integer(),
          max_diagnostic_entries: pos_integer(),
          max_diagnostic_depth: pos_integer(),
          max_concurrent_operations: pos_integer(),
          max_fake_script_entries: pos_integer()
        }

  @typedoc "A field-specific invalid or unreasonable trusted limit."
  @type validation_error ::
          {:attributes, :must_be_keyword_or_map}
          | {:unknown_fields, [term()]}
          | {atom(), :must_be_reasonable_positive_integer}
          | {atom(), :must_not_exceed_related_maximum}

  @doc "Returns the confirmed Phase 0 default ceilings."
  @spec default() :: t()
  def default, do: struct!(__MODULE__, @defaults)

  @doc "Validates trusted lowered ceilings and their default/maximum relationships."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs \\ %{}) do
    with {:ok, attrs} <- Validation.attributes(attrs, @fields),
         values <- Map.merge(@defaults, attrs),
         :ok <- validate_positive_maximums(values),
         :ok <- validate_relationships(values) do
      {:ok, struct!(__MODULE__, values)}
    end
  end

  @doc "Returns whether a Limits struct satisfies every hard ceiling and relationship."
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = limits),
    do: match?({:ok, %__MODULE__{}}, new(Map.from_struct(limits)))

  def valid?(_limits), do: false

  defp validate_positive_maximums(values) do
    case Enum.find(@fields, fn field ->
           value = values[field]

           not (is_integer(value) and value >= minimum(field) and value <= @hard_maximums[field])
         end) do
      nil -> :ok
      field -> {:error, {field, :must_be_reasonable_positive_integer}}
    end
  end

  defp minimum(:max_process_event_bytes), do: 16
  defp minimum(:max_environment_entries), do: 8
  defp minimum(:max_environment_name_bytes), do: 19
  defp minimum(:max_environment_value_bytes), do: 29
  defp minimum(:max_diagnostic_bytes), do: 2
  defp minimum(_field), do: 1

  defp validate_relationships(values) do
    relationships = [
      {:default_read_lines, :max_read_lines},
      {:default_read_bytes, :max_read_bytes},
      {:default_process_output_bytes, :max_process_output_bytes},
      {:default_process_inactivity_ms, :max_process_inactivity_ms},
      {:default_process_timeout_ms, :max_process_timeout_ms}
    ]

    case Enum.find(relationships, fn {default, maximum} ->
           values[default] > values[maximum]
         end) do
      nil -> :ok
      {default, _maximum} -> {:error, {default, :must_not_exceed_related_maximum}}
    end
  end
end
