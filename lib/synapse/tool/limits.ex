defmodule Synapse.Tool.Limits do
  @moduledoc """
  Validated resource ceilings for Tool contracts and model-visible data.

  Trusted Agent or Runtime configuration may lower these defaults but cannot
  raise them above the Phase 0 hard ceilings. Tool limits independently protect
  decoded calls, canonical schemas, result content, metadata, model attention,
  and the Workspace limits selected by built-in adapters.

  Result content has a protocol floor of 256 bytes, metadata has a two-byte empty
  object floor, and fixed diagnostic messages have a 128-byte floor so trusted
  retry and ambiguity guidance cannot be configured away.

  Static registry ceilings live here for one coherent Tool policy contract, but
  a per-operation Context will not dynamically mutate registry contents.

  Field groups and ownership:

  * identity/path fields bound Call IDs, names, operation IDs, and relative paths;
  * argument/schema fields bound decoded JSON, collection shape, and static tools;
  * result/metadata/error fields bound model-visible and local diagnostic data;
  * Read fields bound line windows and retained source bytes;
  * Bash fields bound raw output, total timeout, and accepted-output inactivity.

  Agent or Runtime owns trusted lowering. Calls may select only schema-exposed
  lower values; adapters and Dispatcher enforce the resulting policy.
  """

  alias Synapse.Tool.Validation
  alias Synapse.Workspace.Limits, as: WorkspaceLimits

  @defaults %{
    max_call_id_bytes: 512,
    max_tool_name_bytes: 64,
    max_argument_json_bytes: 64_000,
    max_argument_entries: 16,
    max_argument_depth: 4,
    max_schema_bytes_per_tool: 16_384,
    max_registered_tools: 32,
    max_result_content_bytes: 64_000,
    max_result_metadata_json_bytes: 4_096,
    max_result_metadata_entries: 32,
    max_result_metadata_depth: 4,
    max_error_message_bytes: 512,
    max_operation_id_bytes: 256,
    max_path_bytes: 4_096,
    default_read_lines: 100,
    max_read_lines: 1_000,
    default_read_source_bytes: 32_768,
    max_read_source_bytes: 65_536,
    default_bash_output_bytes: 65_536,
    max_bash_output_bytes: 1_048_576,
    default_bash_timeout_ms: 300_000,
    max_bash_timeout_ms: 900_000,
    default_bash_inactivity_ms: 180_000,
    max_bash_inactivity_ms: 900_000
  }

  @hard_maximums @defaults
  @fields Map.keys(@defaults)

  defstruct Map.to_list(@defaults)

  @typedoc "Immutable hard or lowered ceilings used by Tool contracts."
  @type t :: %__MODULE__{
          max_call_id_bytes: pos_integer(),
          max_tool_name_bytes: pos_integer(),
          max_argument_json_bytes: pos_integer(),
          max_argument_entries: pos_integer(),
          max_argument_depth: pos_integer(),
          max_schema_bytes_per_tool: pos_integer(),
          max_registered_tools: pos_integer(),
          max_result_content_bytes: pos_integer(),
          max_result_metadata_json_bytes: pos_integer(),
          max_result_metadata_entries: pos_integer(),
          max_result_metadata_depth: pos_integer(),
          max_error_message_bytes: pos_integer(),
          max_operation_id_bytes: pos_integer(),
          max_path_bytes: pos_integer(),
          default_read_lines: pos_integer(),
          max_read_lines: pos_integer(),
          default_read_source_bytes: pos_integer(),
          max_read_source_bytes: pos_integer(),
          default_bash_output_bytes: pos_integer(),
          max_bash_output_bytes: pos_integer(),
          default_bash_timeout_ms: pos_integer(),
          max_bash_timeout_ms: pos_integer(),
          default_bash_inactivity_ms: pos_integer(),
          max_bash_inactivity_ms: pos_integer()
        }

  @typedoc "A field-specific invalid or unreasonable trusted Tool limit."
  @type validation_error ::
          {:attributes, :must_be_keyword_or_map}
          | {:unknown_fields, [term()]}
          | {atom(), :must_be_reasonable_positive_integer}
          | {atom(), :must_not_exceed_related_maximum}

  @doc "Returns the confirmed Phase 0 Tool ceilings."
  @spec default() :: t()
  def default, do: struct!(__MODULE__, @defaults)

  @doc "Validates trusted lowered limits and every default/maximum relationship."
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

  @doc """
  Returns whether Tool limits fit one validated Workspace ceiling.

  Runtime uses this before opening a Workspace, and Tool Context repeats the
  check against the authenticated Handle. The comparison covers every built-in
  path, read, Bash output, timeout, inactivity, and operation-ID value delegated
  into Workspace. Neither argument is trusted merely because it has the expected
  struct tag.
  """
  @spec fits_workspace?(t(), WorkspaceLimits.t()) :: boolean()
  def fits_workspace?(%__MODULE__{} = tool, %WorkspaceLimits{} = workspace) do
    valid?(tool) and WorkspaceLimits.valid?(workspace) and
      tool.max_operation_id_bytes <= workspace.max_operation_id_bytes and
      tool.max_path_bytes <= workspace.max_path_bytes and
      tool.default_read_lines <= workspace.default_read_lines and
      tool.max_read_lines <= workspace.max_read_lines and
      tool.default_read_source_bytes <= workspace.default_read_bytes and
      tool.max_read_source_bytes <= workspace.max_read_bytes and
      tool.default_bash_output_bytes <= workspace.default_process_output_bytes and
      tool.max_bash_output_bytes <= workspace.max_process_output_bytes and
      tool.default_bash_timeout_ms <= workspace.default_process_timeout_ms and
      tool.max_bash_timeout_ms <= workspace.max_process_timeout_ms and
      tool.default_bash_inactivity_ms <= workspace.default_process_inactivity_ms and
      tool.max_bash_inactivity_ms <= workspace.max_process_inactivity_ms
  end

  def fits_workspace?(_tool, _workspace), do: false

  defp validate_positive_maximums(values) do
    case Enum.find(@fields, fn field ->
           value = values[field]

           not (is_integer(value) and value >= minimum(field) and
                  value <= @hard_maximums[field])
         end) do
      nil -> :ok
      field -> {:error, {field, :must_be_reasonable_positive_integer}}
    end
  end

  defp minimum(:max_result_content_bytes), do: 256
  defp minimum(:max_result_metadata_json_bytes), do: 2
  defp minimum(:max_error_message_bytes), do: 128
  defp minimum(_field), do: 1

  defp validate_relationships(values) do
    relationships = [
      {:default_read_lines, :max_read_lines},
      {:default_read_source_bytes, :max_read_source_bytes},
      {:default_bash_output_bytes, :max_bash_output_bytes},
      {:default_bash_timeout_ms, :max_bash_timeout_ms},
      {:default_bash_inactivity_ms, :max_bash_inactivity_ms}
    ]

    case Enum.find(relationships, fn {default, maximum} -> values[default] > values[maximum] end) do
      nil -> :ok
      {default, _maximum} -> {:error, {default, :must_not_exceed_related_maximum}}
    end
  end
end
