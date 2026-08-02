defmodule Synapse.Tool.Spec do
  @moduledoc """
  One immutable Tool schema plus trusted capability and side-effect policy.

  `name`, `description`, and `parameters` become a flat Responses function
  definition. The outer `"type": "function"` and `"strict": true` values are
  fixed Tool System projection invariants rather than mutable Spec fields.
  `capability` and `effect` are trusted application atoms and never enter the
  model-visible schema.

  Spec accepts the strict schema subset live-verified through Tokamak: an exact
  object envelope, complete required/property parity, string or
  integer properties, exact nullable integer type arrays, descriptions, and
  optional integer bounds. The static Registry and canonical built-in modules own
  the exact reviewed specifications.

  ## Example

      iex> {:ok, spec} = Synapse.Tool.Spec.new(%{
      ...>   name: "read",
      ...>   description: "Read one bounded project file.",
      ...>   parameters: %{
      ...>     "type" => "object",
      ...>     "properties" => %{
      ...>       "path" => %{"type" => "string", "description" => "Relative path."}
      ...>     },
      ...>     "required" => ["path"],
      ...>     "additionalProperties" => false
      ...>   },
      ...>   capability: :fs_read,
      ...>   effect: :read_only
      ...> })
      iex> {spec.name, spec.capability, spec.effect}
      {"read", :fs_read, :read_only}
  """

  alias Synapse.Tool.{Limits, Validation}

  @capabilities [:fs_read, :fs_write, :process_exec]
  @effects [:read_only, :mutation, :unknown]
  @schema_depth 4
  @parameter_keys ~w(type properties required additionalProperties)
  @property_keys ~w(type description minimum maximum)

  @enforce_keys [:name, :description, :parameters, :capability, :effect]
  defstruct [:name, :description, :parameters, :capability, :effect]

  @typedoc "A fixed trusted Tool capability selected by application code."
  @type capability :: :fs_read | :fs_write | :process_exec

  @typedoc "A fixed side-effect class used by Executor dispatch hardening."
  @type effect :: :read_only | :mutation | :unknown

  @typedoc "A strict model schema and non-model execution policy."
  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          parameters: Synapse.Tool.json_object(),
          capability: capability(),
          effect: effect()
        }

  @typedoc "A field-specific invalid Tool specification."
  @type validation_error ::
          {:attributes, :must_be_keyword_or_map}
          | {:unknown_fields, [term()]}
          | {:limits, :must_be_tool_limits}
          | {:name, :must_be_bounded_non_empty_utf8_identifier}
          | {:description, :must_be_non_empty_utf8_string}
          | {:parameters, :must_be_complete_strict_flat_object_schema}
          | {:specification, :must_fit_schema_byte_limit}
          | {:capability, :must_be_known}
          | {:effect, :must_be_known}

  @doc "Validates one strict flat schema and its trusted execution policy."
  @spec new(keyword() | map(), Limits.t()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs, limits \\ Limits.default()) do
    allowed = [:name, :description, :parameters, :capability, :effect]

    with {:ok, limits} <- normalize_limits(limits),
         {:ok, attrs} <- Validation.attributes(attrs, allowed),
         true <-
           Validation.identifier?(attrs[:name], limits.max_tool_name_bytes) or
             {:error, {:name, :must_be_bounded_non_empty_utf8_identifier}},
         true <-
           Validation.bounded_non_empty_string?(
             attrs[:description],
             limits.max_schema_bytes_per_tool
           ) or
             {:error, {:description, :must_be_non_empty_utf8_string}},
         true <-
           valid_parameters?(attrs[:parameters], limits) or
             {:error, {:parameters, :must_be_complete_strict_flat_object_schema}},
         true <-
           attrs[:capability] in @capabilities or {:error, {:capability, :must_be_known}},
         true <- attrs[:effect] in @effects or {:error, {:effect, :must_be_known}},
         true <-
           specification_fits?(attrs, limits) or
             {:error, {:specification, :must_fit_schema_byte_limit}} do
      {:ok, struct!(__MODULE__, attrs)}
    end
  end

  @doc """
  Revalidates and projects a Spec into the canonical flat Responses function map.

  The projection always supplies `type: function` and `strict: true`. Trusted
  capability, side-effect policy, and implementation identity remain local and
  never enter model-visible Provider data. Callers should pass only Specs produced
  by `new/2` or the static Tool Registry.
  """
  @spec to_provider(t(), Limits.t()) ::
          {:ok, Synapse.Tool.json_object()} | {:error, validation_error()}
  def to_provider(spec, limits \\ Limits.default())

  def to_provider(%__MODULE__{} = spec, limits) do
    with {:ok, validated} <- new(Map.from_struct(spec), limits) do
      {:ok, project(validated)}
    end
  end

  def to_provider(_spec, limits) do
    with {:ok, _limits} <- normalize_limits(limits) do
      {:error, {:attributes, :must_be_keyword_or_map}}
    end
  end

  defp valid_parameters?(parameters, limits) when is_map(parameters) do
    not is_struct(parameters) and
      Validation.bounded_json_object?(
        parameters,
        limits.max_schema_bytes_per_tool,
        limits.max_schema_bytes_per_tool,
        @schema_depth
      ) and exact_keys?(parameters, @parameter_keys) and
      parameters["type"] == "object" and parameters["additionalProperties"] == false and
      valid_properties?(parameters["properties"], limits) and
      valid_required?(parameters["required"], parameters["properties"])
  end

  defp valid_parameters?(_parameters, _limits), do: false

  defp valid_properties?(properties, limits) when is_map(properties) do
    not is_struct(properties) and
      Enum.all?(properties, fn {name, property} ->
        Validation.identifier?(name, limits.max_tool_name_bytes) and valid_property?(property)
      end)
  end

  defp valid_properties?(_properties, _limits), do: false

  defp valid_property?(property) when is_map(property) do
    not is_struct(property) and Map.has_key?(property, "type") and
      Map.has_key?(property, "description") and
      Map.keys(property) |> Enum.all?(&(&1 in @property_keys)) and
      Validation.non_empty_string?(property["description"]) and valid_property_type?(property) and
      valid_property_bounds?(property)
  end

  defp valid_property?(_property), do: false

  defp valid_property_type?(%{"type" => "string"}), do: true
  defp valid_property_type?(%{"type" => "integer"}), do: true
  defp valid_property_type?(%{"type" => ["integer", "null"]}), do: true
  defp valid_property_type?(_property), do: false

  defp valid_property_bounds?(%{"type" => "string"} = property),
    do: not Map.has_key?(property, "minimum") and not Map.has_key?(property, "maximum")

  defp valid_property_bounds?(property) do
    minimum = Map.fetch(property, "minimum")
    maximum = Map.fetch(property, "maximum")

    valid_optional_bound?(minimum) and valid_optional_bound?(maximum) and
      bounds_ordered?(minimum, maximum)
  end

  defp valid_optional_bound?(:error), do: true
  defp valid_optional_bound?({:ok, value}), do: Validation.int64?(value)

  defp bounds_ordered?({:ok, minimum}, {:ok, maximum}), do: minimum <= maximum
  defp bounds_ordered?(_minimum, _maximum), do: true

  defp valid_required?(required, properties) when is_list(required) and is_map(properties) do
    Validation.proper_list?(required, map_size(properties)) and
      Enum.all?(required, &is_binary/1) and length(Enum.uniq(required)) == length(required) and
      MapSet.new(required) == MapSet.new(Map.keys(properties))
  end

  defp valid_required?(_required, _properties), do: false

  defp specification_fits?(attrs, limits) do
    projected = project(attrs)

    match?(
      {:ok, _bytes},
      Validation.bounded_json_bytes(
        projected,
        limits.max_schema_bytes_per_tool,
        limits.max_schema_bytes_per_tool,
        @schema_depth
      )
    )
  end

  defp project(spec) do
    %{
      "type" => "function",
      "name" => spec.name,
      "description" => spec.description,
      "parameters" => spec.parameters,
      "strict" => true
    }
  end

  defp exact_keys?(map, keys), do: MapSet.new(Map.keys(map)) == MapSet.new(keys)

  defp normalize_limits(%Limits{} = limits) do
    if Limits.valid?(limits),
      do: {:ok, limits},
      else: {:error, {:limits, :must_be_tool_limits}}
  end

  defp normalize_limits(_limits), do: {:error, {:limits, :must_be_tool_limits}}
end
