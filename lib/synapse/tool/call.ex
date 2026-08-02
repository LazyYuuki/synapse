defmodule Synapse.Tool.Call do
  @moduledoc """
  A complete bounded model-requested Tool call.

  Agent creates a Call only from a complete Provider FunctionCall after the
  Provider has returned a successful terminal Response. A bare FunctionCall
  cannot itself prove that parent-response condition, so `from_provider/2`
  defensively validates item shape while terminal provenance remains an Agent
  precondition.

  `call_id` is the Provider function pairing ID. It is not the Provider output
  item `id` and is not the Workspace operation ID. `name` and every argument key
  remain strings; each built-in adapter validates its exact argument fields.
  Unknown names are valid Calls until the static Registry rejects them.

  ## Example

      iex> {:ok, call} = Synapse.Tool.Call.new(%{
      ...>   call_id: "call-1",
      ...>   name: "read",
      ...>   arguments: %{"path" => "mix.exs", "offset" => nil, "limit" => nil}
      ...> })
      iex> {call.call_id, call.name}
      {"call-1", "read"}
  """

  alias Synapse.Provider.OutputItem.FunctionCall
  alias Synapse.Tool.{Limits, Validation}

  @enforce_keys [:call_id, :name, :arguments]
  defstruct [:call_id, :name, :arguments]

  @typedoc "A complete generic call eligible for later registry and argument validation."
  @type t :: %__MODULE__{
          call_id: String.t(),
          name: String.t(),
          arguments: Synapse.Tool.json_object()
        }

  @typedoc "A field-specific invalid Call or Provider conversion."
  @type validation_error ::
          {:attributes, :must_be_keyword_or_map}
          | {:unknown_fields, [term()]}
          | {:limits, :must_be_tool_limits}
          | {:function_call, :must_be_complete_provider_function_call}
          | {:call_id, :must_be_bounded_non_empty_utf8_identifier}
          | {:name, :must_be_bounded_non_empty_utf8_identifier}
          | {:arguments, :must_be_bounded_string_keyed_json_object}

  @doc "Validates generic Call identity and bounded string-keyed JSON arguments."
  @spec new(keyword() | map(), Limits.t()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs, limits \\ Limits.default()) do
    allowed = [:call_id, :name, :arguments]

    with {:ok, limits} <- normalize_limits(limits),
         {:ok, attrs} <- Validation.attributes(attrs, allowed),
         true <-
           Validation.identifier?(attrs[:call_id], limits.max_call_id_bytes) or
             {:error, {:call_id, :must_be_bounded_non_empty_utf8_identifier}},
         true <-
           Validation.identifier?(attrs[:name], limits.max_tool_name_bytes) or
             {:error, {:name, :must_be_bounded_non_empty_utf8_identifier}},
         true <-
           Validation.bounded_json_object?(
             attrs[:arguments],
             limits.max_argument_json_bytes,
             limits.max_argument_entries,
             limits.max_argument_depth
           ) or {:error, {:arguments, :must_be_bounded_string_keyed_json_object}} do
      {:ok, struct!(__MODULE__, attrs)}
    end
  end

  @doc """
  Copies one complete normalized Provider FunctionCall into a Tool Call.

  The Provider output item ID is validated as part of complete item shape and then
  deliberately discarded. Successful parent Response provenance remains an Agent
  precondition because it is not represented by the item alone.
  """
  @spec from_provider(FunctionCall.t(), Limits.t()) ::
          {:ok, t()} | {:error, validation_error()}
  def from_provider(function_call, limits \\ Limits.default())

  def from_provider(%FunctionCall{} = function_call, limits) do
    with {:ok, limits} <- normalize_limits(limits),
         true <-
           Validation.identifier?(function_call.id, limits.max_call_id_bytes) or
             {:error, {:function_call, :must_be_complete_provider_function_call}} do
      new(
        %{
          call_id: function_call.call_id,
          name: function_call.name,
          arguments: function_call.arguments
        },
        limits
      )
    end
  end

  def from_provider(_function_call, limits) do
    with {:ok, _limits} <- normalize_limits(limits) do
      {:error, {:function_call, :must_be_complete_provider_function_call}}
    end
  end

  defp normalize_limits(%Limits{} = limits) do
    if Limits.valid?(limits),
      do: {:ok, limits},
      else: {:error, {:limits, :must_be_tool_limits}}
  end

  defp normalize_limits(_limits), do: {:error, {:limits, :must_be_tool_limits}}
end
