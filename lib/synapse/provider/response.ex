defmodule Synapse.Provider.Response do
  @moduledoc """
  The completed terminal result of one provider request.

  A Provider implementation creates this only after the wire protocol reports a
  successful completion and all output items are complete. The Agent Loop may
  then use its messages and function calls. Streaming progress belongs in
  `Synapse.Provider.Event`; interrupted or failed terminals belong in
  `Synapse.Provider.Error`.

  Fields:

  * `id` is the provider response identifier.
  * `model` is the model reported for the completed response.
  * `output_items` contains normalized complete messages and function calls with
    unique item IDs and unique function call pairing IDs.
  * `usage` is string-keyed JSON token accounting. Provider producers sanitize
    and allowlist it; `new/1` validates JSON shape only.
  * `status` is always `:completed` for this success-only contract.
  """

  alias Synapse.Provider.{JSON, OutputItem}
  alias Synapse.Provider.OutputItem.{FunctionCall, Message}

  @enforce_keys [:id, :model]
  defstruct id: nil, model: nil, output_items: [], usage: %{}, status: :completed

  @typedoc "A completed, normalized provider response."
  @type t :: %__MODULE__{
          id: String.t(),
          model: String.t(),
          output_items: [OutputItem.t()],
          usage: Synapse.Provider.json_object(),
          status: :completed
        }

  @typedoc "A validation failure for a completed response."
  @type validation_error ::
          {:id, :must_be_non_empty_string}
          | {:model, :must_be_non_empty_string}
          | {:output_items, :must_be_complete_output_items}
          | {:output_items, :must_have_unique_item_and_call_ids}
          | {:status, :must_be_completed}
          | {:usage, :must_be_string_keyed_json_object}

  @doc """
  Validates complete output items and constructs a success-only terminal response.

  It performs no streaming or tool execution. Callers receive field-specific
  validation errors; Provider producers remain responsible for sanitizing usage.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs) when is_list(attrs) or is_map(attrs) do
    attrs = Map.new(attrs)
    id = Map.get(attrs, :id)
    model = Map.get(attrs, :model)
    output_items = Map.get(attrs, :output_items, [])
    usage = Map.get(attrs, :usage, %{})
    status = Map.get(attrs, :status, :completed)

    cond do
      not non_empty_string?(id) ->
        {:error, {:id, :must_be_non_empty_string}}

      not non_empty_string?(model) ->
        {:error, {:model, :must_be_non_empty_string}}

      not (is_list(output_items) and Enum.all?(output_items, &complete_output_item?/1)) ->
        {:error, {:output_items, :must_be_complete_output_items}}

      not unique_output_items?(output_items) ->
        {:error, {:output_items, :must_have_unique_item_and_call_ids}}

      status != :completed ->
        {:error, {:status, :must_be_completed}}

      not JSON.object?(usage) ->
        {:error, {:usage, :must_be_string_keyed_json_object}}

      true ->
        {:ok,
         %__MODULE__{
           id: id,
           model: model,
           output_items: output_items,
           usage: usage
         }}
    end
  end

  def new(_attrs), do: {:error, {:id, :must_be_non_empty_string}}

  defp complete_output_item?(%Message{
         id: id,
         role: :assistant,
         content: content
       }),
       do: non_empty_string?(id) and is_binary(content)

  defp complete_output_item?(%FunctionCall{
         id: id,
         call_id: call_id,
         name: name,
         arguments: arguments
       }),
       do:
         non_empty_string?(id) and non_empty_string?(call_id) and non_empty_string?(name) and
           JSON.object?(arguments)

  defp complete_output_item?(_item), do: false

  defp unique_output_items?(items) do
    item_ids = Enum.map(items, & &1.id)

    call_ids =
      Enum.flat_map(items, fn
        %FunctionCall{call_id: call_id} -> [call_id]
        %Message{} -> []
      end)

    Enum.uniq(item_ids) == item_ids and Enum.uniq(call_ids) == call_ids
  end

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""
end
