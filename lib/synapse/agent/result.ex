defmodule Synapse.Agent.Result do
  @moduledoc """
  Validated successful terminal output and aggregate accounting for one run.

  Agent creates Result only after a successful terminal Provider Response has no
  pending Tool calls and contains non-empty final assistant text. The normalized
  final Response remains available to trusted higher layers, while ordinary
  inspection redacts both it and `text`.

  Result means the model settled. It does not mean a coding task was verified,
  accepted, committed, or safe to merge.

  Fields retain run identity, joined final text, the authoritative completed
  Provider Response, logical turn count, executed Tool-call count, safe Provider
  retry count, and aggregate output bytes. Counters are validated against the
  signed accounting range, and output bytes must include final text bytes.

  ## Example

      iex> response = %Synapse.Provider.Response{
      ...>   id: "response-doc",
      ...>   model: "test-model",
      ...>   output_items: [
      ...>     %Synapse.Provider.OutputItem.Message{
      ...>       id: "message-doc", role: :assistant, content: "Finished"
      ...>     }
      ...>   ]
      ...> }
      iex> {:ok, result} = Synapse.Agent.Result.new(
      ...>   run_id: "run-doc",
      ...>   text: "Finished",
      ...>   final_response: response,
      ...>   turns: 1,
      ...>   tool_calls: 0,
      ...>   provider_retries: 0,
      ...>   output_bytes: 8
      ...> )
      iex> result.turns
      1
  """

  alias Synapse.Provider.Response
  alias Synapse.Tool.Validation

  @max_run_id_bytes 256
  @max_text_bytes 4_194_304
  @allowed_fields [
    :run_id,
    :text,
    :final_response,
    :turns,
    :tool_calls,
    :provider_retries,
    :output_bytes
  ]

  @enforce_keys @allowed_fields
  defstruct @allowed_fields

  @typedoc "Successful Agent terminal and run-level counters."
  @type t :: %__MODULE__{
          run_id: String.t(),
          text: String.t(),
          final_response: Response.t(),
          turns: pos_integer(),
          tool_calls: non_neg_integer(),
          provider_retries: non_neg_integer(),
          output_bytes: non_neg_integer()
        }

  @typedoc "A field-specific invalid successful terminal."
  @type validation_error ::
          {:attributes, :must_be_keyword_or_map}
          | {:unknown_fields, [term()]}
          | {:run_id, :must_be_bounded_non_empty_utf8_identifier}
          | {:text, :must_be_bounded_non_empty_utf8_string}
          | {:final_response, :must_be_completed_provider_response}
          | {:turns, :must_be_in_recorded_range}
          | {:tool_calls, :must_be_in_recorded_range}
          | {:provider_retries, :must_be_in_recorded_range}
          | {:output_bytes, :must_be_in_recorded_range}
          | {:output_bytes, :must_include_final_text}

  @doc "Validates final normalized output and aggregate counters."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs) do
    with {:ok, attrs} <- Validation.attributes(attrs, @allowed_fields),
         true <-
           Validation.identifier?(attrs[:run_id], @max_run_id_bytes) or
             {:error, {:run_id, :must_be_bounded_non_empty_utf8_identifier}},
         true <-
           bounded_text?(attrs[:text]) or
             {:error, {:text, :must_be_bounded_non_empty_utf8_string}},
         {:ok, response} <- normalize_response(attrs[:final_response]),
         :ok <- counter(:turns, attrs[:turns], 1),
         :ok <- counter(:tool_calls, attrs[:tool_calls], 0),
         :ok <- counter(:provider_retries, attrs[:provider_retries], 0),
         :ok <- counter(:output_bytes, attrs[:output_bytes], 0),
         true <-
           attrs[:output_bytes] >= byte_size(attrs[:text]) or
             {:error, {:output_bytes, :must_include_final_text}} do
      {:ok, struct!(__MODULE__, Map.put(attrs, :final_response, response))}
    end
  end

  defp normalize_response(%Response{} = response) do
    case Response.new(Map.from_struct(response)) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, _reason} -> {:error, {:final_response, :must_be_completed_provider_response}}
    end
  end

  defp normalize_response(_response),
    do: {:error, {:final_response, :must_be_completed_provider_response}}

  defp bounded_text?(text),
    do:
      is_binary(text) and byte_size(text) <= @max_text_bytes and String.valid?(text) and
        String.trim(text) != ""

  defp counter(_field, value, minimum)
       when is_integer(value) and value >= minimum and value <= 9_223_372_036_854_775_807,
       do: :ok

  defp counter(field, _value, _minimum),
    do: {:error, {field, :must_be_in_recorded_range}}
end

defimpl Inspect, for: Synapse.Agent.Result do
  def inspect(result, _options),
    do: "#Synapse.Agent.Result<turns=#{result.turns} tool_calls=#{result.tool_calls} redacted>"
end
