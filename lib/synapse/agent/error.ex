defmodule Synapse.Agent.Error do
  @moduledoc """
  Sanitized structured failure, interruption, ambiguity, or Budget terminal.

  Error carries stable typed policy data so Runtime and the future CLI never need
  to parse prose or Tool Result JSON. Details are bounded string-keyed JSON with a
  small Agent-owned key allowlist. They may retain Provider classification,
  operation correlation, Tool ambiguity identity, or Budget counts, but never
  prompt, file content, command, process output, absolute path, Handle, callback,
  exception, credential, or arbitrary Tool metadata.

  Shape validation and allowlisted keys are defense in depth; a trusted producer
  must still avoid placing a secret in an otherwise allowed string value.

  `kind` identifies the terminal source, `reason` is the stable machine value,
  `message` is bounded sanitized prose, `run_id` and optional `operation_id`
  correlate trusted activity, `turn` records the logical boundary, and `details`
  contains only bounded allowlisted local data.

  ## Example

      iex> {:ok, error} = Synapse.Agent.Error.new(
      ...>   kind: :budget,
      ...>   reason: :turn_budget_exhausted,
      ...>   message: "Run turn budget exhausted",
      ...>   run_id: "run-doc",
      ...>   turn: 20,
      ...>   operation_id: nil,
      ...>   details: %{"observed" => 20, "maximum" => 20}
      ...> )
      iex> error.kind
      :budget
  """

  alias Synapse.Tool.Validation

  @max_run_id_bytes 256
  @max_operation_id_bytes 256
  @max_message_bytes 512
  @max_details_bytes 4_096
  @max_details_entries 32
  @max_details_depth 4
  @max_turns 100

  @reasons_by_kind %{
    internal: [
      :invalid_run_request,
      :invalid_agent_context,
      :event_sink_failed,
      :tool_executor_contract_failed,
      :conversation_projection_failed,
      :run_worker_crashed,
      :workspace_close_failed
    ],
    provider: [:provider_failed, :provider_interrupted_after_output, :provider_retry_exhausted],
    protocol: [:empty_provider_response, :invalid_function_call_batch, :tool_admission_failed],
    tool: [:tool_ambiguous],
    budget: [
      :turn_budget_exhausted,
      :tool_call_budget_exhausted,
      :wall_time_budget_exhausted,
      :output_budget_exhausted
    ],
    cancelled: [:run_cancelled]
  }

  @detail_keys MapSet.new(~w(
    attempts call_id http_status limit maximum observed operation_id outcome output_started
    provider_kind retryable status tool_name
  ))

  @allowed_fields [:kind, :reason, :message, :run_id, :turn, :operation_id, :details]

  @enforce_keys @allowed_fields
  defstruct @allowed_fields

  @typedoc "Stable terminal source category."
  @type kind :: :provider | :tool | :budget | :protocol | :cancelled | :internal

  @typedoc "Stable machine-readable terminal reason."
  @type reason ::
          :invalid_run_request
          | :invalid_agent_context
          | :event_sink_failed
          | :tool_executor_contract_failed
          | :conversation_projection_failed
          | :run_worker_crashed
          | :workspace_close_failed
          | :provider_failed
          | :provider_interrupted_after_output
          | :provider_retry_exhausted
          | :empty_provider_response
          | :invalid_function_call_batch
          | :tool_admission_failed
          | :tool_ambiguous
          | :turn_budget_exhausted
          | :tool_call_budget_exhausted
          | :wall_time_budget_exhausted
          | :output_budget_exhausted
          | :run_cancelled

  @typedoc "One sanitized Agent terminal Error."
  @type t :: %__MODULE__{
          kind: kind(),
          reason: reason(),
          message: String.t(),
          run_id: String.t(),
          turn: non_neg_integer(),
          operation_id: String.t() | nil,
          details: Synapse.Provider.json_object()
        }

  @typedoc "A field-specific invalid Agent Error."
  @type validation_error ::
          {:attributes, :must_be_keyword_or_map}
          | {:unknown_fields, [term()]}
          | {:kind, :must_be_known}
          | {:reason, :must_match_kind}
          | {:message, :must_be_bounded_non_empty_utf8_string}
          | {:run_id, :must_be_bounded_non_empty_utf8_identifier}
          | {:turn, :must_be_in_recorded_range}
          | {:operation_id, :must_be_bounded_identifier_or_nil}
          | {:details, :must_be_bounded_allowlisted_json_object}

  @doc "Validates one sanitized terminal classification and allowlisted details."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs) do
    with {:ok, attrs} <- Validation.attributes(attrs, @allowed_fields),
         true <-
           Map.has_key?(@reasons_by_kind, attrs[:kind]) or
             {:error, {:kind, :must_be_known}},
         true <-
           attrs[:reason] in @reasons_by_kind[attrs[:kind]] or
             {:error, {:reason, :must_match_kind}},
         true <-
           bounded_message?(attrs[:message]) or
             {:error, {:message, :must_be_bounded_non_empty_utf8_string}},
         true <-
           Validation.identifier?(attrs[:run_id], @max_run_id_bytes) or
             {:error, {:run_id, :must_be_bounded_non_empty_utf8_identifier}},
         true <- valid_turn?(attrs[:turn]) or {:error, {:turn, :must_be_in_recorded_range}},
         true <-
           optional_operation_id?(attrs[:operation_id]) or
             {:error, {:operation_id, :must_be_bounded_identifier_or_nil}},
         true <-
           allowed_details?(attrs[:details]) or
             {:error, {:details, :must_be_bounded_allowlisted_json_object}} do
      {:ok, struct!(__MODULE__, attrs)}
    end
  end

  defp bounded_message?(message),
    do:
      is_binary(message) and byte_size(message) <= @max_message_bytes and
        String.valid?(message) and String.trim(message) != ""

  defp valid_turn?(turn), do: is_integer(turn) and turn >= 0 and turn <= @max_turns

  defp optional_operation_id?(nil), do: true

  defp optional_operation_id?(operation_id),
    do: Validation.identifier?(operation_id, @max_operation_id_bytes)

  defp allowed_details?(details) do
    Validation.bounded_json_object?(
      details,
      @max_details_bytes,
      @max_details_entries,
      @max_details_depth
    ) and allowed_detail_keys?(details)
  end

  defp allowed_detail_keys?(value) when is_map(value) do
    Enum.all?(value, fn {key, item} ->
      MapSet.member?(@detail_keys, key) and allowed_detail_keys?(item)
    end)
  end

  defp allowed_detail_keys?(value) when is_list(value),
    do: Enum.all?(value, &allowed_detail_keys?/1)

  defp allowed_detail_keys?(_value), do: true
end

defimpl Inspect, for: Synapse.Agent.Error do
  def inspect(%{kind: kind, reason: reason}, _options)
      when kind in [:internal, :provider, :protocol, :tool, :budget, :cancelled] and
             reason in [
               :invalid_run_request,
               :invalid_agent_context,
               :event_sink_failed,
               :tool_executor_contract_failed,
               :conversation_projection_failed,
               :run_worker_crashed,
               :workspace_close_failed,
               :provider_failed,
               :provider_interrupted_after_output,
               :provider_retry_exhausted,
               :empty_provider_response,
               :invalid_function_call_batch,
               :tool_admission_failed,
               :tool_ambiguous,
               :turn_budget_exhausted,
               :tool_call_budget_exhausted,
               :wall_time_budget_exhausted,
               :output_budget_exhausted,
               :run_cancelled
             ],
      do: "#Synapse.Agent.Error<kind=#{inspect(kind)} reason=#{inspect(reason)} redacted>"

  def inspect(_error, _options), do: "#Synapse.Agent.Error<invalid redacted>"
end
