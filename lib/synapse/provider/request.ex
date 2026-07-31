defmodule Synapse.Provider.Request do
  @moduledoc """
  A credential-free model request assembled by the Agent Loop.

  The Provider consumes this struct and converts it to an endpoint-specific wire
  request. It deliberately contains no API key, URL, Req option, retry policy,
  workspace handle, or terminal-rendering state.

  Fields:

  * `model` is the explicit provider model identifier.
  * `instructions` is optional top-level model guidance.
  * `input_items` is ordered normalized conversation input.
  * `tools` contains function definitions available for this turn.
  * `metadata` contains sanitized correlation data. Secret-shaped keys are
    rejected recursively and the MVP Responses codec keeps metadata local.

  Input and tool maps use string keys so decoded external keys are never turned
  into atoms. Supported input types are `message`, `function_call`, and
  `function_call_output`. The request codec remains responsible for producing
  the final Tokamak or Responses JSON shape.

  ## Example

      iex> {:ok, request} = Synapse.Provider.Request.new(%{
      ...>   model: "configured-model",
      ...>   instructions: "Help with this project.",
      ...>   input_items: [
      ...>     %{
      ...>       "type" => "message",
      ...>       "role" => "user",
      ...>       "content" => [%{"type" => "input_text", "text" => "Inspect mix.exs"}]
      ...>     }
      ...>   ]
      ...> })
      iex> request.model
      "configured-model"

  """

  alias Synapse.Provider.JSON

  @enforce_keys [:model]
  defstruct model: nil,
            instructions: nil,
            input_items: [],
            tools: [],
            metadata: %{}

  @typedoc "A string-keyed JSON object accepted as normalized provider input."
  @type json_object :: Synapse.Provider.json_object()

  @typedoc "A validation failure identifying the invalid request field."
  @type validation_error ::
          {:unknown_fields, [term()]}
          | {:attributes, :must_be_keyword_or_map}
          | {:model, :must_be_non_empty_string}
          | {:instructions, :must_be_string_or_nil}
          | {:input_items, :must_be_supported_items}
          | {:tools, :must_be_function_definitions}
          | {:metadata, :must_be_sanitized_string_keyed_json_object}

  @typedoc "The validated, credential-free request passed from Agent to Provider."
  @type t :: %__MODULE__{
          model: String.t(),
          instructions: String.t() | nil,
          input_items: [json_object()],
          tools: [json_object()],
          metadata: json_object()
        }

  @allowed_fields MapSet.new([:model, :instructions, :input_items, :tools, :metadata])
  @message_roles ~w(user assistant developer system)

  @doc """
  Validates externally assembled request data and constructs a request.

  Unknown fields are rejected so credentials and transport options cannot be
  accidentally attached to this shared contract.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) do
      new(Map.new(attrs))
    else
      {:error, {:attributes, :must_be_keyword_or_map}}
    end
  end

  def new(attrs) when is_map(attrs) do
    attrs = Map.new(attrs)
    unknown_fields = attrs |> Map.keys() |> Enum.reject(&MapSet.member?(@allowed_fields, &1))

    case unknown_fields do
      [] -> build(attrs)
      fields -> {:error, {:unknown_fields, fields}}
    end
  end

  def new(_attrs), do: {:error, {:attributes, :must_be_keyword_or_map}}

  defp build(attrs) do
    case validation_error(attrs) do
      nil ->
        {:ok,
         %__MODULE__{
           model: attrs.model,
           instructions: Map.get(attrs, :instructions),
           input_items: Map.get(attrs, :input_items, []),
           tools: Map.get(attrs, :tools, []),
           metadata: Map.get(attrs, :metadata, %{})
         }}

      error ->
        {:error, error}
    end
  end

  defp validation_error(attrs) do
    cond do
      not non_empty_string?(attrs[:model]) ->
        {:model, :must_be_non_empty_string}

      not (is_nil(attrs[:instructions]) or valid_string?(attrs[:instructions])) ->
        {:instructions, :must_be_string_or_nil}

      not valid_input_items?(Map.get(attrs, :input_items, [])) ->
        {:input_items, :must_be_supported_items}

      not valid_tools?(Map.get(attrs, :tools, [])) ->
        {:tools, :must_be_function_definitions}

      not valid_metadata?(Map.get(attrs, :metadata, %{})) ->
        {:metadata, :must_be_sanitized_string_keyed_json_object}

      true ->
        nil
    end
  end

  defp valid_input_items?(items) when is_list(items), do: Enum.all?(items, &valid_input_item?/1)
  defp valid_input_items?(_items), do: false

  defp valid_input_item?(%{"type" => "message"} = item) do
    role = item["role"]
    JSON.object?(item) and role in @message_roles and valid_content?(role, item["content"])
  end

  defp valid_input_item?(%{"type" => "function_call"} = item) do
    JSON.object?(item) and non_empty_string?(item["call_id"]) and
      non_empty_string?(item["name"]) and JSON.object?(item["arguments"]) and
      optional_non_empty_string?(item, "id")
  end

  defp valid_input_item?(%{"type" => "function_call_output"} = item) do
    JSON.object?(item) and non_empty_string?(item["call_id"]) and is_binary(item["output"])
  end

  defp valid_input_item?(_item), do: false

  defp valid_content?(role, content) when is_list(content) and content != [] do
    Enum.all?(content, fn
      %{"type" => type, "text" => text} = part
      when type in ["input_text", "output_text"] and is_binary(text) ->
        JSON.object?(part) and valid_content_type?(role, type)

      _part ->
        false
    end)
  end

  defp valid_content?(_role, _content), do: false

  defp valid_content_type?("assistant", "output_text"), do: true
  defp valid_content_type?(role, "input_text") when role != "assistant", do: true
  defp valid_content_type?(_role, _type), do: false

  defp valid_tools?(tools) when is_list(tools), do: Enum.all?(tools, &valid_tool?/1)
  defp valid_tools?(_tools), do: false

  defp valid_tool?(%{"type" => "function"} = tool) do
    JSON.object?(tool) and non_empty_string?(tool["name"]) and
      is_binary(tool["description"]) and valid_parameters?(tool["parameters"]) and
      optional_boolean?(tool, "strict")
  end

  defp valid_tool?(_tool), do: false

  defp valid_parameters?(%{"type" => "object", "properties" => properties} = parameters) do
    JSON.object?(parameters) and JSON.object?(properties) and
      optional_string_list?(parameters, "required") and
      optional_boolean?(parameters, "additionalProperties")
  end

  defp valid_parameters?(_parameters), do: false

  defp optional_non_empty_string?(map, key) do
    not Map.has_key?(map, key) or non_empty_string?(map[key])
  end

  defp optional_boolean?(map, key) do
    not Map.has_key?(map, key) or is_boolean(map[key])
  end

  defp optional_string_list?(map, key) do
    not Map.has_key?(map, key) or
      (is_list(map[key]) and Enum.all?(map[key], &is_binary/1))
  end

  defp valid_metadata?(metadata) do
    JSON.object?(metadata) and not contains_sensitive_key?(metadata)
  end

  defp contains_sensitive_key?(value) when is_map(value) do
    Enum.any?(value, fn {key, item} ->
      sensitive_key?(key) or contains_sensitive_key?(item)
    end)
  end

  defp contains_sensitive_key?(value) when is_list(value),
    do: Enum.any?(value, &contains_sensitive_key?/1)

  defp contains_sensitive_key?(_value), do: false

  defp sensitive_key?(key) do
    key = key |> String.downcase() |> String.replace("-", "_")

    Enum.any?(~w(api_key authorization token secret password credential cookie), fn sensitive ->
      String.contains?(key, sensitive)
    end)
  end

  defp valid_string?(value), do: is_binary(value) and String.valid?(value)
  defp non_empty_string?(value), do: valid_string?(value) and String.trim(value) != ""
end
