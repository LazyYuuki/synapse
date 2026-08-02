defmodule Synapse.Tool.Result do
  @moduledoc """
  One bounded terminal Tool result paired to a submitted Call.

  `status` is the authoritative terminal class: ordinary success, known error, or
  uncertain side effect. `content` is the valid UTF-8 JSON object that Agent will
  send as the matching Provider `function_call_output`; `metadata` is bounded
  local policy/event data and is not automatically sent to the model.

  The constructor validates that the content's top-level string status agrees
  with the struct status. If an outcome is present at top level, under the error
  object, or in metadata, it must also agree. Ambiguous results require
  `"unknown"`; ordinary errors may use `"completed"`, `"not_applicable"`, or
  `"not_applied"`; successful outcomes may only be `"completed"`.

  Generic metadata validation rejects content-, command-, host-, exception-, and
  credential-shaped keys as defense in depth. It cannot prove arbitrary values
  contain no secrets, so later producers must still assemble metadata from a
  small allowlist.

  ## Example

      iex> content = ~s({"status":"ok","tool":"read"})
      iex> {:ok, result} = Synapse.Tool.Result.ok(call_id: "call-1", content: content)
      iex> result.status
      :ok
  """

  alias Synapse.Tool.{Limits, Validation}

  @statuses [:ok, :error, :ambiguous]
  @enforce_keys [:call_id, :status, :content, :metadata]
  defstruct [:call_id, :status, :content, :metadata]

  @typedoc "A known success/error or uncertain side-effect terminal class."
  @type status :: :ok | :error | :ambiguous

  @typedoc "A paired model-visible result and bounded local metadata."
  @type t :: %__MODULE__{
          call_id: String.t(),
          status: status(),
          content: String.t(),
          metadata: Synapse.Tool.json_object()
        }

  @typedoc "A field-specific invalid Result."
  @type validation_error ::
          {:attributes, :must_be_keyword_or_map}
          | {:unknown_fields, [term()]}
          | {:limits, :must_be_tool_limits}
          | {:call_id, :must_be_bounded_non_empty_utf8_identifier}
          | {:status, :must_be_known}
          | {:content, :must_be_bounded_utf8_json_object}
          | {:content, :status_must_match_result}
          | {:content, :outcome_must_match_status}
          | {:metadata, :must_be_bounded_safe_json_object}

  @doc "Validates a fully assembled paired Tool Result."
  @spec new(keyword() | map(), Limits.t()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs, limits \\ Limits.default()) do
    allowed = [:call_id, :status, :content, :metadata]

    with {:ok, limits} <- normalize_limits(limits),
         {:ok, attrs} <- Validation.attributes(attrs, allowed),
         metadata <- Map.get(attrs, :metadata, %{}),
         true <-
           Validation.identifier?(attrs[:call_id], limits.max_call_id_bytes) or
             {:error, {:call_id, :must_be_bounded_non_empty_utf8_identifier}},
         true <- attrs[:status] in @statuses or {:error, {:status, :must_be_known}},
         {:ok, content_object} <- validate_content(attrs[:content], limits),
         true <-
           content_object["status"] == Atom.to_string(attrs.status) or
             {:error, {:content, :status_must_match_result}},
         true <-
           Validation.safe_metadata_object?(
             metadata,
             limits.max_result_metadata_json_bytes,
             limits.max_result_metadata_entries,
             limits.max_result_metadata_depth
           ) or {:error, {:metadata, :must_be_bounded_safe_json_object}},
         true <-
           outcome_matches?(attrs.status, content_object, metadata) or
             {:error, {:content, :outcome_must_match_status}} do
      {:ok,
       %__MODULE__{
         call_id: attrs.call_id,
         status: attrs.status,
         content: attrs.content,
         metadata: metadata
       }}
    end
  end

  @doc "Constructs a successful Result while rejecting a caller-supplied status field."
  @spec ok(keyword() | map(), Limits.t()) :: {:ok, t()} | {:error, validation_error()}
  def ok(attrs, limits \\ Limits.default()), do: with_status(attrs, :ok, limits)

  @doc "Constructs an ordinary error Result while rejecting a caller-supplied status field."
  @spec error(keyword() | map(), Limits.t()) :: {:ok, t()} | {:error, validation_error()}
  def error(attrs, limits \\ Limits.default()), do: with_status(attrs, :error, limits)

  @doc "Constructs an ambiguous Result while rejecting a caller-supplied status field."
  @spec ambiguous(keyword() | map(), Limits.t()) :: {:ok, t()} | {:error, validation_error()}
  def ambiguous(attrs, limits \\ Limits.default()), do: with_status(attrs, :ambiguous, limits)

  defp with_status(attrs, status, limits) do
    with {:ok, attrs} <- Validation.attributes(attrs, [:call_id, :content, :metadata]) do
      attrs |> Map.put(:status, status) |> new(limits)
    end
  end

  defp validate_content(content, limits) do
    if is_binary(content) and byte_size(content) <= limits.max_result_content_bytes and
         String.valid?(content) and
         :binary.match(content, <<127>>) == :nomatch do
      case Validation.decode_unique_object(content) do
        {:ok, value} -> {:ok, value}
        :error -> {:error, {:content, :must_be_bounded_utf8_json_object}}
      end
    else
      {:error, {:content, :must_be_bounded_utf8_json_object}}
    end
  end

  defp outcome_matches?(status, content, metadata) do
    outcomes =
      [
        Map.fetch(content, "outcome"),
        nested_error_outcome(content),
        Map.fetch(metadata, "outcome")
      ]
      |> Enum.flat_map(fn
        {:ok, outcome} -> [outcome]
        :error -> []
      end)
      |> Enum.uniq()

    case {status, outcomes} do
      {:ok, []} -> true
      {:ok, ["completed"]} -> true
      {:error, []} -> true
      {:error, [outcome]} when outcome in ["completed", "not_applicable", "not_applied"] -> true
      {:ambiguous, ["unknown"]} -> true
      _other -> false
    end
  end

  defp nested_error_outcome(%{"error" => error}) when is_map(error),
    do: Map.fetch(error, "outcome")

  defp nested_error_outcome(_content), do: :error

  defp normalize_limits(%Limits{} = limits) do
    if Limits.valid?(limits),
      do: {:ok, limits},
      else: {:error, {:limits, :must_be_tool_limits}}
  end

  defp normalize_limits(_limits), do: {:error, {:limits, :must_be_tool_limits}}
end
