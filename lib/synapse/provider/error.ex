defmodule Synapse.Provider.Error do
  @moduledoc """
  A sanitized terminal provider failure.

  Provider implementations create errors; the Agent Loop or Runtime consumes
  them and decides whether policy permits another attempt. `retryable` describes
  the failure class, while `output_started` independently records whether the
  user may already have observed model output. Keeping both lets higher-level
  policy explicitly account for progress duplication when replaying a request.

  Fields contain normalized classifications and sanitized diagnostics only.
  Raw response bodies, authorization headers, credentials, and Req structs do
  not belong in this contract.

  * `kind` is a stable failure classification.
  * `message` is a sanitized explanation suitable for higher layers.
  * `status` is an HTTP status when one is relevant and safe to retain.
  * `retryable` classifies whether retry policy may consider another attempt.
  * `output_started` records whether model output was already emitted.
  * `operation_id` correlates the failure without exposing provider data.
  * `details` contains bounded, string-keyed, sanitized diagnostic values.

  `new/1` limits messages and operation IDs to 512 bytes and details to 4 KiB,
  32 entries per collection, four nested collection levels, and signed 64-bit
  integers. Provider implementations additionally construct only allowlisted
  detail fields; passing validation alone does not prove that arbitrary content
  is non-secret.
  """

  alias Synapse.Provider.JSON

  @max_message_bytes 512
  @max_operation_id_bytes 512
  @max_details_bytes 4_096
  @max_collection_entries 32
  @max_detail_depth 4
  @maximum_integer 9_223_372_036_854_775_807

  @kinds [
    :configuration,
    :authentication,
    :authorization,
    :rate_limited,
    :unavailable,
    :timeout,
    :transport,
    :protocol,
    :interrupted,
    :upstream
  ]

  @enforce_keys [:kind, :message, :retryable, :output_started, :operation_id]
  defstruct [:kind, :message, :status, :retryable, :output_started, :operation_id, details: %{}]

  @typedoc """
  A stable failure category independent of an endpoint's wire format.

  Configuration, authentication, and authorization are local/access failures;
  rate limiting and unavailability describe upstream capacity; timeout and
  transport describe request lifetime; protocol means known data was malformed;
  interrupted means a stream could not complete safely; upstream is a valid
  provider-reported failed terminal.
  """
  @type kind ::
          :configuration
          | :authentication
          | :authorization
          | :rate_limited
          | :unavailable
          | :timeout
          | :transport
          | :protocol
          | :interrupted
          | :upstream

  @typedoc "The sanitized terminal failure returned by a Provider implementation."
  @type t :: %__MODULE__{
          kind: kind(),
          message: String.t(),
          status: non_neg_integer() | nil,
          retryable: boolean(),
          output_started: boolean(),
          operation_id: String.t(),
          details: Synapse.Provider.json_object()
        }

  @typedoc "A validation failure identifying an unsafe or invalid error field."
  @type validation_error ::
          {:kind, :must_be_known_kind}
          | {:message, :must_be_bounded_string}
          | {:status, :must_be_http_status_or_nil}
          | {:retryable, :must_be_boolean}
          | {:output_started, :must_be_boolean}
          | {:operation_id, :must_be_bounded_non_empty_string}
          | {:details, :must_be_bounded_string_keyed_json_object}

  @doc """
  Validates bounded, JSON-safe failure data and constructs a Provider error.

  This validates shape and size, not whether arbitrary caller-provided strings
  contain secrets. Provider implementations must use allowlisted diagnostics.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs) when is_list(attrs) or is_map(attrs) do
    attrs = Map.new(attrs)

    validations = [
      {:kind, Map.get(attrs, :kind) in @kinds, :must_be_known_kind},
      {:message, bounded_string?(Map.get(attrs, :message), @max_message_bytes),
       :must_be_bounded_string},
      {:status, valid_status?(Map.get(attrs, :status)), :must_be_http_status_or_nil},
      {:retryable, is_boolean(Map.get(attrs, :retryable)), :must_be_boolean},
      {:output_started, is_boolean(Map.get(attrs, :output_started)), :must_be_boolean},
      {:operation_id,
       non_empty_string?(Map.get(attrs, :operation_id)) and
         byte_size(Map.get(attrs, :operation_id)) <= @max_operation_id_bytes,
       :must_be_bounded_non_empty_string},
      {:details, bounded_details?(Map.get(attrs, :details, %{})),
       :must_be_bounded_string_keyed_json_object}
    ]

    case Enum.find(validations, fn {_field, valid?, _reason} -> not valid? end) do
      {field, false, reason} ->
        {:error, {field, reason}}

      nil ->
        {:ok,
         struct!(__MODULE__,
           kind: attrs.kind,
           message: attrs.message,
           status: Map.get(attrs, :status),
           retryable: attrs.retryable,
           output_started: attrs.output_started,
           operation_id: attrs.operation_id,
           details: Map.get(attrs, :details, %{})
         )}
    end
  end

  def new(_attrs), do: {:error, {:kind, :must_be_known_kind}}

  defp valid_status?(nil), do: true
  defp valid_status?(status), do: is_integer(status) and status in 100..599

  defp bounded_details?(details) do
    JSON.object?(details) and match?({:ok, _bytes}, diagnostic_size(details, 0, 0))
  end

  defp diagnostic_size(_value, _bytes, depth) when depth > @max_detail_depth,
    do: :too_large

  defp diagnostic_size(value, bytes, _depth) when is_binary(value) do
    add_bytes(bytes, byte_size(value))
  end

  defp diagnostic_size(value, bytes, _depth)
       when is_integer(value) and value >= -@maximum_integer and value <= @maximum_integer,
       do: add_bytes(bytes, 20)

  defp diagnostic_size(value, bytes, _depth) when is_float(value), do: add_bytes(bytes, 24)

  defp diagnostic_size(value, bytes, _depth) when is_boolean(value) or is_nil(value),
    do: add_bytes(bytes, 5)

  defp diagnostic_size(value, bytes, depth) when is_map(value) do
    if map_size(value) <= @max_collection_entries do
      Enum.reduce_while(value, {:ok, bytes}, fn {key, item}, {:ok, bytes} ->
        with {:ok, bytes} <- diagnostic_size(key, bytes, depth + 1),
             {:ok, bytes} <- diagnostic_size(item, bytes, depth + 1) do
          {:cont, {:ok, bytes}}
        else
          :too_large -> {:halt, :too_large}
        end
      end)
    else
      :too_large
    end
  end

  defp diagnostic_size(value, bytes, depth) when is_list(value) do
    value
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, bytes}, fn
      {_item, index}, _acc when index > @max_collection_entries ->
        {:halt, :too_large}

      {item, _index}, {:ok, bytes} ->
        case diagnostic_size(item, bytes, depth + 1) do
          {:ok, bytes} -> {:cont, {:ok, bytes}}
          :too_large -> {:halt, :too_large}
        end
    end)
  end

  defp diagnostic_size(_value, _bytes, _depth), do: :too_large

  defp add_bytes(bytes, addition) when bytes + addition <= @max_details_bytes,
    do: {:ok, bytes + addition}

  defp add_bytes(_bytes, _addition), do: :too_large

  defp bounded_string?(value, maximum),
    do: is_binary(value) and String.valid?(value) and byte_size(value) <= maximum

  defp non_empty_string?(value),
    do: is_binary(value) and String.valid?(value) and String.trim(value) != ""
end
