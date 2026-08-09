defmodule Synapse.Budget do
  @moduledoc """
  Legacy validated policy envelope retained at internal Run boundaries.

  Aggregate values remain in the struct while internal callers migrate, but
  `Synapse.Agent.Runner` no longer treats turn, Tool-call, wall-time, output, or
  retry values as execution ceilings. Those dimensions are accounting only.

  Current execution safety is owned by the component that can enforce it:

  * every complete Provider request is checked against the 272,000-token context
    limit before transport;
  * Runtime may supply an explicit absolute deadline, but the default is
    `:infinity`;
  * Provider transport owns per-attempt inactivity handling;
  * Tool and Workspace policy own Bash timeout, inactivity, and retained-output
    truncation.

  The loopback API no longer accepts client Budget fields. `max_output_bytes`
  remains in server configuration temporarily as a transport/projection sizing
  value, not as an Agent run termination policy. Counters remain signed-64 values
  so event and wire representations stay well-defined.

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
    max_output_bytes: 524_288,
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

  @typedoc "Legacy immutable policy values carried across internal run contracts."
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

  @doc "Returns the legacy internal policy defaults."
  @spec default() :: t()
  def default, do: struct!(__MODULE__, @defaults)

  @doc "Validates and constructs the legacy internal policy envelope."
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
