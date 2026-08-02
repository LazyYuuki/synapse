defmodule Synapse.Budget do
  @moduledoc """
  Validated aggregate resource policy for one Agent run.

  Budget is trusted local configuration created before `Synapse.Agent.Runner`
  starts. It bounds logical turns, admitted Tool calls, wall time, Provider and
  Tool inactivity, model-visible output added to conversation, and safe
  pre-output Provider retries. Lower components retain their own hard limits;
  Budget may lower effective policy but cannot enlarge those limits.

  `max_provider_retries` is the only field that accepts zero, allowing retry to
  be disabled. All arithmetic consumers must remain within signed 64-bit
  monotonic-time and counter ranges.

  Fields:

  * `max_turns` bounds logical model turns, excluding retries of one snapshot;
  * `max_tool_calls` bounds admitted executions across the run;
  * `max_wall_time_ms` bounds total monotonic run lifetime;
  * `provider_inactivity_ms` lowers silence allowed in each Provider attempt;
  * `tool_inactivity_ms` lowers silence allowed in applicable Tool processes;
  * `max_output_bytes` bounds aggregate model-visible data added to conversation;
  * `max_provider_retries` bounds additional safe attempts before any output.

  | Field | Unit | Default | Protected aggregate resource |
  | --- | ---: | ---: | --- |
  | `max_turns` | logical turns | 20 | immutable Provider request snapshots |
  | `max_tool_calls` | executions | 50 | admitted Tool side effects |
  | `max_wall_time_ms` | milliseconds | 900,000 | monotonic run lifetime |
  | `provider_inactivity_ms` | milliseconds | 120,000 | silence within one Provider attempt |
  | `tool_inactivity_ms` | milliseconds | 180,000 | silence within applicable Tool processes |
  | `max_output_bytes` | UTF-8/canonical JSON bytes | 64,000 | newly projected model-visible output |
  | `max_provider_retries` | additional attempts | 2 | safe pre-output Provider retries |

  Provider and Tool contracts retain independent hard ceilings. Budget can lower
  those limits for one run but cannot enlarge them. A Provider retry reuses one
  immutable logical-turn request, so it increments `max_provider_retries` rather
  than `max_turns`. Tool-call budget admission is whole-batch and atomic: a batch
  that does not fit starts no Tool operation.

  ## Example

      iex> {:ok, budget} = Synapse.Budget.new(max_turns: 8, max_provider_retries: 0)
      iex> {budget.max_turns, budget.max_provider_retries}
      {8, 0}
  """

  @defaults %{
    max_turns: 20,
    max_tool_calls: 50,
    max_wall_time_ms: 900_000,
    provider_inactivity_ms: 120_000,
    tool_inactivity_ms: 180_000,
    max_output_bytes: 64_000,
    max_provider_retries: 2
  }

  @maximums %{
    max_turns: 100,
    max_tool_calls: 500,
    max_wall_time_ms: 3_600_000,
    provider_inactivity_ms: 900_000,
    tool_inactivity_ms: 900_000,
    max_output_bytes: 4_194_304,
    max_provider_retries: 5
  }

  @fields Map.keys(@defaults)

  defstruct Map.to_list(@defaults)

  @typedoc "Trusted immutable aggregate ceilings for one run."
  @type t :: %__MODULE__{
          max_turns: pos_integer(),
          max_tool_calls: pos_integer(),
          max_wall_time_ms: pos_integer(),
          provider_inactivity_ms: pos_integer(),
          tool_inactivity_ms: pos_integer(),
          max_output_bytes: pos_integer(),
          max_provider_retries: non_neg_integer()
        }

  @typedoc "A malformed attribute collection or field outside its recorded range."
  @type validation_error ::
          {:attributes, :must_be_keyword_or_map}
          | {:unknown_fields, [term()]}
          | {atom(), :must_be_in_recorded_range}

  @doc "Returns the confirmed Agent Loop aggregate defaults."
  @spec default() :: t()
  def default, do: struct!(__MODULE__, @defaults)

  @doc "Validates trusted lowering and constructs one Budget."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs \\ %{}) do
    with {:ok, attrs} <- attributes(attrs),
         values <- Map.merge(@defaults, attrs),
         :ok <- validate_ranges(values) do
      {:ok, struct!(__MODULE__, values)}
    end
  end

  @doc "Returns whether a Budget struct satisfies every recorded range."
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = budget),
    do: match?({:ok, %__MODULE__{}}, new(Map.from_struct(budget)))

  def valid?(_budget), do: false

  defp attributes(attrs) when is_list(attrs) do
    if proper_list?(attrs, length(@fields) + 1) and Keyword.keyword?(attrs),
      do: attributes(Map.new(attrs)),
      else: {:error, {:attributes, :must_be_keyword_or_map}}
  end

  defp attributes(attrs) when is_map(attrs) do
    if map_size(attrs) > length(@fields) + 1 do
      {:error, {:unknown_fields, [:too_many]}}
    else
      unknown = attrs |> Map.keys() |> Kernel.--(@fields) |> Enum.map(&safe_unknown_field/1)
      if unknown == [], do: {:ok, attrs}, else: {:error, {:unknown_fields, unknown}}
    end
  end

  defp attributes(_attrs), do: {:error, {:attributes, :must_be_keyword_or_map}}

  defp validate_ranges(values) do
    case Enum.find(@fields, fn field ->
           value = values[field]
           not (is_integer(value) and value >= minimum(field) and value <= @maximums[field])
         end) do
      nil -> :ok
      field -> {:error, {field, :must_be_in_recorded_range}}
    end
  end

  defp minimum(:max_provider_retries), do: 0
  defp minimum(_field), do: 1

  defp proper_list?([], _maximum), do: true
  defp proper_list?(_value, 0), do: false
  defp proper_list?([_item | rest], maximum), do: proper_list?(rest, maximum - 1)
  defp proper_list?(_value, _maximum), do: false

  defp safe_unknown_field(field) when is_atom(field) do
    if field |> Atom.to_string() |> byte_size() <= 128, do: field, else: :unknown
  end

  defp safe_unknown_field(_field), do: :unknown
end
