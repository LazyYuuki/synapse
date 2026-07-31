defmodule Synapse.Workspace.Error do
  @moduledoc """
  A bounded sanitized Workspace failure.

  Workspace creates errors and Tool or Runtime consumes them. Expected file,
  mutation, access, runner, cancellation, and ambiguity failures remain data.
  Errors contain relative paths and allowlisted JSON details only; absolute roots,
  file content, staged content, command output, environments, Ports, and arbitrary
  exception messages do not cross this boundary.

  Ordinary inspection exposes only kind, operation, outcome, and reason. It omits
  message, details, path, and operation ID to reduce accidental log disclosure;
  direct field access remains available to trusted callers.
  """

  alias Synapse.Workspace.{Limits, Validation}

  @kinds [
    :invalid,
    :not_found,
    :denied,
    :conflict,
    :limit,
    :cancelled,
    :unsupported,
    :io,
    :unavailable,
    :ambiguous
  ]
  @operations [:open, :close, :read, :write, :edit, :run]
  @outcomes [:not_applicable, :not_applied, :unknown]
  @reasons [
    :invalid_root,
    :not_found,
    :invalid_request,
    :invalid_handle,
    :absolute_path,
    :path_traversal,
    :invalid_utf8,
    :path_too_long,
    :symlink,
    :broken_link,
    :mount_crossing,
    :multiple_hard_links,
    :not_regular_file,
    :file_too_large,
    :file_changed,
    :stale_revision,
    :expected_missing,
    :no_match,
    :multiple_matches,
    :workspace_busy,
    :access_denied,
    :executable_not_found,
    :event_sink_failed,
    :activity_sink_failed,
    :process_start_failed,
    :runner_failed,
    :deadline_elapsed,
    :inactivity_timeout,
    :cancelled,
    :output_limit,
    :unexpected_operation,
    :script_exhausted,
    :atomic_commit_failed,
    :durability_unknown,
    :mutation_activity_failed,
    :backend_unavailable,
    :io,
    :unsupported_platform,
    :unsupported_filesystem,
    :not_implemented
  ]
  @detail_keys ~w(
    action actual attempt current_revision elapsed_ms errno exit_code expected_revision limit
    match_count retryable stage termination
  )
  @message_bytes 512

  @enforce_keys [:kind, :reason, :operation, :message, :outcome]
  defstruct [:kind, :reason, :operation, :message, :operation_id, :path, :outcome, details: %{}]

  @typedoc "A stable Workspace failure category."
  @type kind ::
          :invalid
          | :not_found
          | :denied
          | :conflict
          | :limit
          | :cancelled
          | :unsupported
          | :io
          | :unavailable
          | :ambiguous

  @typedoc "The fixed Workspace operation that failed."
  @type operation :: :open | :close | :read | :write | :edit | :run

  @typedoc "A stable machine-readable Workspace failure reason."
  @type reason ::
          :invalid_root
          | :not_found
          | :invalid_request
          | :invalid_handle
          | :absolute_path
          | :path_traversal
          | :invalid_utf8
          | :path_too_long
          | :symlink
          | :broken_link
          | :mount_crossing
          | :multiple_hard_links
          | :not_regular_file
          | :file_too_large
          | :file_changed
          | :stale_revision
          | :expected_missing
          | :no_match
          | :multiple_matches
          | :workspace_busy
          | :access_denied
          | :executable_not_found
          | :event_sink_failed
          | :activity_sink_failed
          | :process_start_failed
          | :runner_failed
          | :deadline_elapsed
          | :inactivity_timeout
          | :cancelled
          | :output_limit
          | :unexpected_operation
          | :script_exhausted
          | :atomic_commit_failed
          | :durability_unknown
          | :mutation_activity_failed
          | :backend_unavailable
          | :io
          | :unsupported_platform
          | :unsupported_filesystem
          | :not_implemented

  @typedoc "Whether a side effect was irrelevant, known absent, or uncertain."
  @type outcome :: :not_applicable | :not_applied | :unknown

  @typedoc "A bounded failure returned by the Workspace facade or backend."
  @type t :: %__MODULE__{
          kind: kind(),
          reason: reason(),
          operation: operation(),
          message: String.t(),
          operation_id: String.t() | nil,
          path: String.t() | nil,
          outcome: outcome(),
          details: map()
        }

  @typedoc "A field-specific invalid error contract."
  @type validation_error :: {atom(), atom()} | {:unknown_fields, [term()]}

  @doc """
  Validates bounded allowlisted Workspace failure data.

  Shape validation cannot prove trusted message or detail values are non-secret.
  Backend producers must use fixed messages and intentionally safe values.
  """
  @spec new(keyword() | map(), Limits.t()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs, limits \\ Limits.default()) do
    allowed = [
      :kind,
      :reason,
      :operation,
      :message,
      :operation_id,
      :path,
      :outcome,
      :details
    ]

    with {:ok, attrs} <- Validation.attributes(attrs, allowed),
         true <- attrs[:kind] in @kinds or {:error, {:kind, :must_be_known}},
         true <- attrs[:reason] in @reasons or {:error, {:reason, :must_be_known}},
         true <- attrs[:operation] in @operations or {:error, {:operation, :must_be_known}},
         true <-
           Validation.bounded_string?(attrs[:message], @message_bytes, false) or
             {:error, {:message, :must_be_bounded_non_empty_utf8}},
         true <-
           valid_operation_id?(attrs[:operation_id], limits) or
             {:error, {:operation_id, :must_be_bounded_string_or_nil}},
         true <-
           valid_path?(attrs[:path], limits) or
             {:error, {:path, :must_be_bounded_relative_path_or_nil}},
         true <- attrs[:outcome] in @outcomes or {:error, {:outcome, :must_be_known}},
         true <-
           valid_outcome?(attrs[:kind], attrs[:outcome]) or
             {:error, {:outcome, :must_match_kind}},
         details <- Map.get(attrs, :details, %{}),
         true <-
           (Validation.bounded_json_object?(
              details,
              limits.max_diagnostic_bytes,
              limits.max_diagnostic_entries,
              limits.max_diagnostic_depth
            ) and allowlisted_detail_keys?(details)) or
             {:error, {:details, :must_be_bounded_safe_json_object}} do
      {:ok,
       %__MODULE__{
         kind: attrs.kind,
         reason: attrs.reason,
         operation: attrs.operation,
         message: attrs.message,
         operation_id: Map.get(attrs, :operation_id),
         path: Map.get(attrs, :path),
         outcome: attrs.outcome,
         details: details
       }}
    end
  end

  @doc "Returns whether an Error struct satisfies the public bounded contract."
  @spec valid?(term(), Limits.t()) :: boolean()
  def valid?(error, limits \\ Limits.default())

  def valid?(%__MODULE__{} = error, limits),
    do: match?({:ok, %__MODULE__{}}, new(Map.from_struct(error), limits))

  def valid?(_error, _limits), do: false

  defp valid_operation_id?(nil, _limits), do: true

  defp valid_operation_id?(value, limits),
    do: Validation.bounded_string?(value, limits.max_operation_id_bytes, false)

  defp valid_path?(nil, _limits), do: true

  defp valid_path?(value, limits),
    do: Validation.relative_path?(value, limits.max_path_bytes, allow_dot: true)

  defp valid_outcome?(:ambiguous, :unknown), do: true
  defp valid_outcome?(:ambiguous, _outcome), do: false
  defp valid_outcome?(_kind, :unknown), do: false
  defp valid_outcome?(_kind, _outcome), do: true

  defp allowlisted_detail_keys?(value) when is_map(value) do
    Enum.all?(value, fn {key, item} ->
      key in @detail_keys and allowlisted_detail_keys?(item)
    end)
  end

  defp allowlisted_detail_keys?(value) when is_list(value),
    do: Enum.all?(value, &allowlisted_detail_keys?/1)

  defp allowlisted_detail_keys?(_value), do: true
end
