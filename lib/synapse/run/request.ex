defmodule Synapse.Run.Request do
  @moduledoc """
  Trusted local intent and policy for one bounded Agent run.

  API RunSession or another trusted adapter creates Request. Runtime later
  validates and opens `cwd`, then passes the resulting Workspace Handle separately
  through `Synapse.Agent.Context`. Request deliberately contains no Provider
  module, callback, credential, transport option, Workspace Handle, or terminal
  state.

  Fields:

  * `id` is a bounded trusted run correlation identifier;
  * `prompt` is the exact non-empty user input projected on the first turn;
  * `cwd` is trusted canonical-workspace input for Runtime, never model authority;
  * `model` is the explicit Provider model identifier;
  * `capabilities` is trusted fixed Tool authority;
  * `budget` is the aggregate run policy.

  Ordinary inspection redacts prompt and workspace path.

  ## Example

      iex> {:ok, capabilities} = Synapse.Tool.CapabilitySet.new(
      ...>   fs_read: true, fs_write: false, process_exec: false
      ...> )
      iex> {:ok, request} = Synapse.Run.Request.new(
      ...>   id: "run-doc",
      ...>   prompt: "Inspect the project.",
      ...>   cwd: "/tmp/project",
      ...>   model: "configured-model",
      ...>   capabilities: capabilities,
      ...>   budget: Synapse.Budget.default()
      ...> )
      iex> request.id
      "run-doc"
  """

  alias Synapse.Budget
  alias Synapse.Tool.CapabilitySet

  @max_id_bytes 256
  @max_prompt_bytes 1_048_576
  @max_cwd_bytes 4_096
  @max_model_bytes 256
  @allowed_fields [:id, :prompt, :cwd, :model, :capabilities, :budget]

  @enforce_keys @allowed_fields
  defstruct @allowed_fields

  @typedoc "Trusted run identity, input, local workspace selection, and policy."
  @type t :: %__MODULE__{
          id: String.t(),
          prompt: String.t(),
          cwd: String.t(),
          model: String.t(),
          capabilities: CapabilitySet.t(),
          budget: Budget.t()
        }

  @typedoc "A field-specific invalid Run Request."
  @type validation_error ::
          {:attributes, :must_be_keyword_or_map}
          | {:unknown_fields, [term()]}
          | {:id, :must_be_bounded_non_empty_utf8_identifier}
          | {:prompt, :must_be_bounded_non_empty_utf8_string}
          | {:cwd, :must_be_bounded_utf8_path}
          | {:model, :must_be_bounded_non_empty_utf8_identifier}
          | {:capabilities, :must_be_tool_capability_set}
          | {:budget, :must_be_budget}

  @doc "Validates exact trusted Request fields without opening the workspace."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs) do
    with {:ok, attrs} <- attributes(attrs),
         true <-
           identifier?(attrs[:id], @max_id_bytes) or
             {:error, {:id, :must_be_bounded_non_empty_utf8_identifier}},
         true <-
           bounded_non_empty_utf8?(attrs[:prompt], @max_prompt_bytes) or
             {:error, {:prompt, :must_be_bounded_non_empty_utf8_string}},
         true <- valid_cwd?(attrs[:cwd]) or {:error, {:cwd, :must_be_bounded_utf8_path}},
         true <-
           identifier?(attrs[:model], @max_model_bytes) or
             {:error, {:model, :must_be_bounded_non_empty_utf8_identifier}},
         {:ok, capabilities} <- normalize_capabilities(attrs[:capabilities]),
         {:ok, budget} <- normalize_budget(attrs[:budget]) do
      {:ok,
       %__MODULE__{
         id: attrs.id,
         prompt: attrs.prompt,
         cwd: attrs.cwd,
         model: attrs.model,
         capabilities: capabilities,
         budget: budget
       }}
    end
  end

  @doc "Returns whether a Request struct passes full constructor validation."
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = request),
    do: match?({:ok, %__MODULE__{}}, new(Map.from_struct(request)))

  def valid?(_request), do: false

  defp normalize_capabilities(%CapabilitySet{} = capabilities) do
    case CapabilitySet.new(Map.from_struct(capabilities)) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, _reason} -> {:error, {:capabilities, :must_be_tool_capability_set}}
    end
  end

  defp normalize_capabilities(_capabilities),
    do: {:error, {:capabilities, :must_be_tool_capability_set}}

  defp normalize_budget(%Budget{} = budget) do
    case Budget.new(Map.from_struct(budget)) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, _reason} -> {:error, {:budget, :must_be_budget}}
    end
  end

  defp normalize_budget(_budget), do: {:error, {:budget, :must_be_budget}}

  defp attributes(attrs) when is_list(attrs) do
    if proper_list?(attrs, length(@allowed_fields) + 1) and Keyword.keyword?(attrs),
      do: attributes(Map.new(attrs)),
      else: {:error, {:attributes, :must_be_keyword_or_map}}
  end

  defp attributes(attrs) when is_map(attrs) do
    if map_size(attrs) > length(@allowed_fields) + 1 do
      {:error, {:unknown_fields, [:too_many]}}
    else
      unknown = attrs |> Map.keys() |> Kernel.--(@allowed_fields) |> Enum.map(&safe_field/1)
      if unknown == [], do: {:ok, attrs}, else: {:error, {:unknown_fields, unknown}}
    end
  end

  defp attributes(_attrs), do: {:error, {:attributes, :must_be_keyword_or_map}}

  defp identifier?(value, maximum) do
    bounded_non_empty_utf8?(value, maximum) and
      value |> :binary.bin_to_list() |> Enum.all?(&(&1 >= 32 and &1 != 127))
  end

  defp bounded_non_empty_utf8?(value, maximum),
    do:
      is_binary(value) and byte_size(value) <= maximum and String.valid?(value) and
        String.trim(value) != ""

  defp valid_cwd?(value),
    do:
      bounded_non_empty_utf8?(value, @max_cwd_bytes) and
        :binary.match(value, <<0>>) == :nomatch and Path.type(value) == :absolute

  defp proper_list?([], _maximum), do: true
  defp proper_list?(_value, 0), do: false
  defp proper_list?([_item | rest], maximum), do: proper_list?(rest, maximum - 1)
  defp proper_list?(_value, _maximum), do: false

  defp safe_field(field) when is_atom(field) do
    if field |> Atom.to_string() |> byte_size() <= 128, do: field, else: :unknown
  end

  defp safe_field(_field), do: :unknown
end

defimpl Inspect, for: Synapse.Run.Request do
  def inspect(request, _options) do
    "#Synapse.Run.Request<id=#{inspect(request.id)} model=#{inspect(request.model)} prompt=redacted cwd=redacted capabilities=#{inspect(request.capabilities)} budget=#{inspect(request.budget)}>"
  end
end
