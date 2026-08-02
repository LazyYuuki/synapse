defmodule Synapse.Tool.Presentation do
  @moduledoc """
  Converts retained Workspace outcomes into deterministic bounded Tool Results.

  Built-in present callbacks use the function matching their statically registered
  Tool. Presentation validates the expected Workspace result type, writes JSON in
  fixed key order, structurally clips only evidence fields, repairs arbitrary
  process bytes, and maps Workspace uncertainty mechanically. It never receives a
  Workspace Handle or OperationContext.

  Workspace messages, operation IDs, arbitrary details, and backend state are not
  copied into diagnostics. File text, diffs, and process output are intentionally
  model-visible evidence and are bounded and escaped rather than claimed secret-free.
  """

  alias Synapse.Tool.{FixedResult, Limits, Result, Validation}

  alias Synapse.Workspace.{
    Error,
    MutationResult,
    ProcessResult,
    ReadLine,
    ReadResult,
    Revision
  }

  alias Synapse.Workspace.Limits, as: WorkspaceLimits

  @numeric_detail_keys ~w(actual attempt elapsed_ms errno exit_code limit match_count)

  @doc "Presents one retained Read outcome with numbered lines and continuation."
  @spec read(String.t(), Synapse.Tool.workspace_outcome(), Limits.t()) :: Result.t()
  def read(call_id, outcome, limits), do: present(:read, call_id, outcome, limits)

  @doc "Presents one retained Write outcome with revision and bounded diff evidence."
  @spec write(String.t(), Synapse.Tool.workspace_outcome(), Limits.t()) :: Result.t()
  def write(call_id, outcome, limits), do: present(:write, call_id, outcome, limits)

  @doc "Presents one retained Edit outcome with revision and bounded diff evidence."
  @spec edit(String.t(), Synapse.Tool.workspace_outcome(), Limits.t()) :: Result.t()
  def edit(call_id, outcome, limits), do: present(:edit, call_id, outcome, limits)

  @doc "Presents one retained Bash outcome with repaired bounded process evidence."
  @spec bash(String.t(), Synapse.Tool.workspace_outcome(), Limits.t()) :: Result.t()
  def bash(call_id, outcome, limits), do: present(:bash, call_id, outcome, limits)

  defp present(tool, call_id, outcome, %Limits{} = limits) do
    try do
      with {:ok, limits} <- Limits.new(Map.from_struct(limits)),
           true <- tool in [:read, :write, :edit, :bash],
           {:ok, status, content, outcome_name} <- content(tool, outcome, limits),
           {:ok, result} <- result(status, call_id, content, tool, outcome_name, limits) do
        result
      else
        {:error, :presentation_failed} ->
          FixedResult.presentation_fallback(call_id, outcome, limits)

        _invalid ->
          FixedResult.error(call_id, :internal_error, limits)
      end
    rescue
      _exception -> FixedResult.presentation_fallback(call_id, outcome, limits)
    catch
      _kind, _reason -> FixedResult.presentation_fallback(call_id, outcome, limits)
    end
  end

  defp present(_tool, call_id, outcome, _limits),
    do: FixedResult.presentation_fallback(call_id, outcome, Limits.default())

  defp content(:read, {:ok, %ReadResult{} = result}, limits) do
    with {:ok, result} <- ReadResult.new(Map.from_struct(result), WorkspaceLimits.default()),
         true <- byte_size(result.path) <= limits.max_path_bytes do
      case read_content(result, limits.max_result_content_bytes) do
        {:ok, content} -> {:ok, :ok, content, "completed"}
        {:error, :mandatory_fields_too_large} -> {:error, :presentation_failed}
      end
    else
      _invalid -> {:error, :invalid_result}
    end
  end

  defp content(tool, {:ok, %MutationResult{} = result}, limits)
       when tool in [:write, :edit] do
    with {:ok, result} <-
           MutationResult.new(Map.from_struct(result), WorkspaceLimits.default()),
         true <- byte_size(result.path) <= limits.max_path_bytes do
      case mutation_content(tool, result, limits.max_result_content_bytes) do
        {:ok, content} -> {:ok, :ok, content, "completed"}
        {:error, :mandatory_fields_too_large} -> {:error, :presentation_failed}
      end
    else
      _invalid -> {:error, :invalid_result}
    end
  end

  defp content(:bash, {:ok, %ProcessResult{} = result}, limits) do
    with {:ok, result} <- ProcessResult.new(Map.from_struct(result), WorkspaceLimits.default()),
         true <- byte_size(result.output) <= limits.max_bash_output_bytes do
      case bash_content(result, limits.max_result_content_bytes) do
        {:ok, status, content} -> {:ok, status, content, "completed"}
        {:error, :mandatory_fields_too_large} -> {:error, :presentation_failed}
      end
    else
      _invalid -> {:error, :invalid_result}
    end
  end

  defp content(tool, {:error, %Error{} = error}, limits) do
    with true <- Error.valid?(error, WorkspaceLimits.default()),
         true <- error.operation == workspace_operation(tool),
         true <- is_nil(error.path) or byte_size(error.path) <= limits.max_path_bytes do
      case workspace_error_content(tool, error, limits) do
        {:ok, status, content} ->
          {:ok, status, content, Atom.to_string(error.outcome)}

        {:error, :mandatory_fields_too_large} ->
          {:error, :presentation_failed}
      end
    else
      _invalid -> {:error, :invalid_error}
    end
  end

  defp content(_tool, _outcome, _limits), do: {:error, :invalid_outcome}

  defp read_content(result, maximum) do
    prefix =
      fields_prefix([
        {"status", string("ok")},
        {"tool", string("read")},
        {"path", string(result.path)},
        {"revision", string(Revision.encode(result.revision))}
      ]) <> ",\"lines\":["

    prefix_bytes = byte_size(prefix)

    {parts, parts_bytes, next_offset, presentation_truncated} =
      read_lines(
        result.lines,
        result.next_line,
        prefix_bytes,
        [],
        0,
        result.file_bytes,
        maximum
      )

    suffix = read_suffix(next_offset, result.file_bytes, presentation_truncated)
    content = IO.iodata_to_binary([prefix, Enum.reverse(parts), suffix])

    if prefix_bytes + parts_bytes + byte_size(suffix) <= maximum and
         byte_size(content) <= maximum,
       do: {:ok, content},
       else: {:error, :mandatory_fields_too_large}
  end

  defp read_lines([], next_line, _prefix_bytes, parts, parts_bytes, file_bytes, maximum) do
    next_offset = workspace_next_offset(next_line)
    suffix = read_suffix(next_offset, file_bytes, false)

    if parts_bytes + byte_size(suffix) <= maximum,
      do: {parts, parts_bytes, next_offset, false},
      else: {parts, parts_bytes, next_offset, false}
  end

  defp read_lines(
         [line | rest],
         workspace_next_line,
         prefix_bytes,
         parts,
         parts_bytes,
         file_bytes,
         maximum
       ) do
    separator = if parts == [], do: "", else: ","
    separator_bytes = byte_size(separator)

    {stop_offset, stop_truncated} =
      case rest do
        [next | _remaining] -> {next.number - 1, true}
        [] -> {workspace_next_offset(workspace_next_line), false}
      end

    stop_suffix = read_suffix(stop_offset, file_bytes, stop_truncated)
    full_empty = line_content(line, "", false)

    available =
      maximum - prefix_bytes - parts_bytes - separator_bytes - byte_size(stop_suffix) -
        byte_size(full_empty)

    {escaped, complete?} = escaped_prefix(line.text, max(available, 0))

    if available >= 0 and complete? do
      encoded = separator <> line_content(line, escaped, false)

      read_lines(
        rest,
        workspace_next_line,
        prefix_bytes,
        [encoded | parts],
        parts_bytes + byte_size(encoded),
        file_bytes,
        maximum
      )
    else
      clip_offset = clipped_next_offset(line, rest, workspace_next_line)
      clip_suffix = read_suffix(clip_offset, file_bytes, true)
      clipped_empty = line_content(line, "", true)

      clip_available =
        maximum - prefix_bytes - parts_bytes - separator_bytes - byte_size(clip_suffix) -
          byte_size(clipped_empty)

      if clip_available >= 0 do
        {clipped, complete?} = escaped_prefix(line.text, clip_available)

        if complete? do
          omitted_offset = line.number - 1
          {parts, parts_bytes, omitted_offset, true}
        else
          encoded = separator <> line_content(line, clipped, true)
          {[encoded | parts], parts_bytes + byte_size(encoded), clip_offset, true}
        end
      else
        omitted_offset = line.number - 1
        {parts, parts_bytes, omitted_offset, true}
      end
    end
  end

  defp line_content(%ReadLine{} = line, escaped_text, presentation_truncated) do
    object([
      {"number", integer(line.number)},
      {"text", quoted(escaped_text)},
      {"ending", string(Atom.to_string(line.ending))},
      {"truncated", boolean(line.truncated)},
      {"presentation_truncated", boolean(presentation_truncated)}
    ])
  end

  defp read_suffix(next_offset, file_bytes, presentation_truncated) do
    "]," <>
      fields([
        {"next_offset", nullable_integer(next_offset)},
        {"file_bytes", integer(file_bytes)},
        {"presentation_truncated", boolean(presentation_truncated)}
      ]) <> "}"
  end

  defp clipped_next_offset(line, rest, workspace_next_line) do
    cond do
      rest != [] -> line.number
      not is_nil(workspace_next_line) -> line.number
      line.ending == :none -> nil
      true -> nil
    end
  end

  defp workspace_next_offset(nil), do: nil
  defp workspace_next_offset(next_line), do: next_line - 1

  defp mutation_content(tool, result, maximum) do
    false_base = mutation_envelope(tool, result, "", false)
    false_available = maximum - byte_size(false_base)
    {escaped, complete?} = escaped_prefix(result.diff, max(false_available, 0))

    cond do
      false_available >= 0 and complete? ->
        {:ok, mutation_envelope(tool, result, escaped, false)}

      true ->
        true_base = mutation_envelope(tool, result, "", true)
        available = maximum - byte_size(true_base)

        if available >= 0 do
          {clipped, _complete} = escaped_prefix(result.diff, available)
          {:ok, mutation_envelope(tool, result, clipped, true)}
        else
          {:error, :mandatory_fields_too_large}
        end
    end
  end

  defp mutation_envelope(tool, result, escaped_diff, presentation_truncated) do
    previous_revision =
      if result.previous_revision == :missing,
        do: "missing",
        else: Revision.encode(result.previous_revision)

    object([
      {"status", string("ok")},
      {"tool", string(Atom.to_string(tool))},
      {"path", string(result.path)},
      {"previous_revision", string(previous_revision)},
      {"revision", string(Revision.encode(result.revision))},
      {"changed", boolean(result.changed)},
      {"bytes_written", integer(result.bytes_written)},
      {"diff", quoted(escaped_diff)},
      {"diff_truncated", boolean(result.diff_truncated)},
      {"presentation_truncated", boolean(presentation_truncated)}
    ])
  end

  defp bash_content(result, maximum) do
    status = bash_status(result)
    false_base = bash_envelope(status, result, "", false)
    false_available = maximum - byte_size(false_base)
    {escaped, complete?} = escaped_repaired_prefix(result.output, max(false_available, 0))

    cond do
      false_available >= 0 and complete? ->
        {:ok, status, bash_envelope(status, result, escaped, false)}

      true ->
        true_base = bash_envelope(status, result, "", true)
        available = maximum - byte_size(true_base)

        if available >= 0 do
          {clipped, _complete} = escaped_repaired_prefix(result.output, available)
          {:ok, status, bash_envelope(status, result, clipped, true)}
        else
          {:error, :mandatory_fields_too_large}
        end
    end
  end

  defp bash_envelope(status, result, escaped_output, presentation_truncated) do
    outcome = if status == :error, do: [{"outcome", string("completed")}], else: []

    object(
      [
        {"status", string(Atom.to_string(status))},
        {"tool", string("bash")}
      ] ++
        outcome ++
        [
          {"exit_code", nullable_integer(result.exit_code)},
          {"termination", string(Atom.to_string(result.termination))},
          {"elapsed_ms", integer(result.elapsed_ms)},
          {"output", quoted(escaped_output)},
          {"output_bytes", integer(result.output_bytes)},
          {"truncated", boolean(result.truncated)},
          {"presentation_truncated", boolean(presentation_truncated)}
        ]
    )
  end

  defp bash_status(%ProcessResult{termination: :exited, exit_code: 0}), do: :ok
  defp bash_status(%ProcessResult{}), do: :error

  defp workspace_error_content(tool, error, limits) do
    status = if error.outcome == :unknown, do: :ambiguous, else: :error
    base_fields = workspace_error_fields(error, [])
    base = error_envelope(status, tool, base_fields)

    if byte_size(base) > limits.max_result_content_bytes do
      {:error, :mandatory_fields_too_large}
    else
      details = safe_numeric_details(error.details)

      content =
        if details == [] do
          base
        else
          candidate = error_envelope(status, tool, workspace_error_fields(error, details))
          if byte_size(candidate) <= limits.max_result_content_bytes, do: candidate, else: base
        end

      {:ok, status, content}
    end
  end

  defp workspace_error_fields(error, details) do
    fields = [
      {"kind", string("workspace")},
      {"workspace_kind", string(Atom.to_string(error.kind))},
      {"reason", string(Atom.to_string(error.reason))},
      {"message", string(error_message(error))},
      {"outcome", string(Atom.to_string(error.outcome))}
    ]

    fields = if is_nil(error.path), do: fields, else: fields ++ [{"path", string(error.path)}]
    if details == [], do: fields, else: fields ++ [{"details", object(details)}]
  end

  defp error_envelope(status, tool, error_fields) do
    object([
      {"status", string(Atom.to_string(status))},
      {"tool", string(Atom.to_string(tool))},
      {"error", object(error_fields)}
    ])
  end

  defp safe_numeric_details(details) do
    Enum.flat_map(@numeric_detail_keys, fn key ->
      case Map.fetch(details, key) do
        {:ok, value} when is_integer(value) and value >= 0 ->
          if Validation.int64?(value), do: [{key, integer(value)}], else: []

        _missing_or_unsafe ->
          []
      end
    end)
  end

  defp error_message(%Error{outcome: :unknown}),
    do: "Workspace outcome is unknown; inspect current workspace state and do not retry blindly"

  defp error_message(%Error{reason: reason}), do: reason_message(reason)

  defp reason_message(:invalid_root), do: "Workspace root is invalid or unavailable"
  defp reason_message(:not_found), do: "Workspace path was not found"
  defp reason_message(:invalid_request), do: "Workspace request is invalid"
  defp reason_message(:invalid_handle), do: "Workspace handle is invalid or unavailable"
  defp reason_message(:absolute_path), do: "Workspace path must be relative"
  defp reason_message(:path_traversal), do: "Workspace path traversal is not permitted"
  defp reason_message(:invalid_utf8), do: "Workspace text is not valid UTF-8"
  defp reason_message(:path_too_long), do: "Workspace path exceeds the configured limit"
  defp reason_message(:symlink), do: "Workspace symlink paths are not permitted"
  defp reason_message(:broken_link), do: "Workspace broken links are not permitted"
  defp reason_message(:mount_crossing), do: "Workspace mount crossing is not permitted"

  defp reason_message(:multiple_hard_links),
    do: "Workspace files with multiple hard links are not permitted"

  defp reason_message(:not_regular_file), do: "Workspace path is not a permitted file type"
  defp reason_message(:file_too_large), do: "Workspace file exceeds the configured limit"
  defp reason_message(:file_changed), do: "Workspace file changed while it was read"

  defp reason_message(:stale_revision),
    do: "Workspace file changed after it was read; reread before retrying"

  defp reason_message(:expected_missing), do: "Workspace destination already exists"
  defp reason_message(:no_match), do: "Workspace edit text was not found"
  defp reason_message(:multiple_matches), do: "Workspace edit text matched more than once"
  defp reason_message(:workspace_busy), do: "Workspace is busy"
  defp reason_message(:access_denied), do: "Workspace operation is not permitted"
  defp reason_message(:executable_not_found), do: "Workspace executable was not found"
  defp reason_message(:event_sink_failed), do: "Workspace process event handling failed"
  defp reason_message(:activity_sink_failed), do: "Workspace activity reporting failed"
  defp reason_message(:process_start_failed), do: "Workspace process could not start"
  defp reason_message(:runner_failed), do: "Workspace process runner failed"
  defp reason_message(:deadline_elapsed), do: "Workspace operation deadline elapsed"
  defp reason_message(:inactivity_timeout), do: "Workspace process output became inactive"
  defp reason_message(:cancelled), do: "Workspace operation was cancelled"
  defp reason_message(:output_limit), do: "Workspace process output limit was reached"
  defp reason_message(:unexpected_operation), do: "Workspace received an unexpected operation"
  defp reason_message(:script_exhausted), do: "Workspace operation was unavailable"
  defp reason_message(:atomic_commit_failed), do: "Workspace atomic commit failed"

  defp reason_message(:durability_unknown),
    do: "Workspace could not confirm the committed file state"

  defp reason_message(:mutation_activity_failed),
    do: "Workspace mutation completed but activity reporting failed"

  defp reason_message(:backend_unavailable), do: "Workspace backend is unavailable"
  defp reason_message(:io), do: "Workspace I/O operation failed"
  defp reason_message(:unsupported_platform), do: "Workspace platform is unsupported"
  defp reason_message(:unsupported_filesystem), do: "Workspace filesystem is unsupported"
  defp reason_message(:not_implemented), do: "Workspace operation is not implemented"

  defp result(status, call_id, content, tool, outcome, limits) do
    metadata = metadata(tool, outcome, limits)
    attrs = [call_id: call_id, content: content, metadata: metadata]

    case status do
      :ok -> Result.ok(attrs, limits)
      :error -> Result.error(attrs, limits)
      :ambiguous -> Result.ambiguous(attrs, limits)
    end
  end

  defp metadata(tool, outcome, limits) do
    metadata = %{"tool" => Atom.to_string(tool), "outcome" => outcome}

    if Validation.safe_metadata_object?(
         metadata,
         limits.max_result_metadata_json_bytes,
         limits.max_result_metadata_entries,
         limits.max_result_metadata_depth
       ),
       do: metadata,
       else: %{}
  end

  defp workspace_operation(:read), do: :read
  defp workspace_operation(:write), do: :write
  defp workspace_operation(:edit), do: :edit
  defp workspace_operation(:bash), do: :run

  defp fields_prefix(fields), do: "{" <> fields(fields)

  defp object(fields), do: "{" <> fields(fields) <> "}"

  defp fields(fields) do
    fields
    |> Enum.map_join(",", fn {key, encoded_value} -> string(key) <> ":" <> encoded_value end)
  end

  defp string(value) do
    {escaped, true} = escaped_prefix(value, :infinity)
    quoted(escaped)
  end

  defp quoted(escaped), do: "\"" <> escaped <> "\""
  defp integer(value), do: Integer.to_string(value)
  defp boolean(true), do: "true"
  defp boolean(false), do: "false"
  defp nullable_integer(nil), do: "null"
  defp nullable_integer(value), do: integer(value)

  defp escaped_prefix(value, maximum) when is_binary(value) do
    if String.valid?(value),
      do: do_escaped_prefix(value, maximum, [], 0),
      else: {"", false}
  end

  defp escaped_repaired_prefix(value, maximum) when is_binary(value) do
    do_escaped_repaired_prefix(value, maximum, [], 0)
  end

  defp do_escaped_repaired_prefix(<<>>, _maximum, parts, _bytes),
    do: {parts |> Enum.reverse() |> IO.iodata_to_binary(), true}

  defp do_escaped_repaired_prefix(value, maximum, parts, bytes) do
    case :unicode.characters_to_binary(value, :utf8, :utf8) do
      valid when is_binary(valid) ->
        append_repaired_segment(valid, <<>>, maximum, parts, bytes, false)

      {:error, valid, rest} ->
        rest = IO.iodata_to_binary(rest)
        invalid_bytes = invalid_prefix_bytes(rest)
        <<_invalid::binary-size(^invalid_bytes), remaining::binary>> = rest

        append_repaired_segment(
          IO.iodata_to_binary(valid),
          remaining,
          maximum,
          parts,
          bytes,
          true
        )

      {:incomplete, valid, _rest} ->
        append_repaired_segment(
          IO.iodata_to_binary(valid),
          <<>>,
          maximum,
          parts,
          bytes,
          true
        )
    end
  end

  defp append_repaired_segment(valid, remaining, maximum, parts, bytes, replacement?) do
    available = maximum - bytes
    {escaped, complete?} = escaped_prefix(valid, max(available, 0))
    escaped_bytes = byte_size(escaped)
    parts = if escaped == "", do: parts, else: [escaped | parts]
    bytes = bytes + escaped_bytes

    cond do
      not complete? ->
        {parts |> Enum.reverse() |> IO.iodata_to_binary(), false}

      replacement? and bytes + 3 <= maximum ->
        do_escaped_repaired_prefix(remaining, maximum, ["�" | parts], bytes + 3)

      replacement? ->
        {parts |> Enum.reverse() |> IO.iodata_to_binary(), false}

      true ->
        {parts |> Enum.reverse() |> IO.iodata_to_binary(), true}
    end
  end

  defp invalid_prefix_bytes(<<lead, rest::binary>>) do
    expected = expected_continuations(lead)
    continuations = count_continuations(rest, expected, 0)

    if expected > 0 and continuations > 0 and continuations < expected,
      do: 1 + continuations,
      else: 1
  end

  defp expected_continuations(lead) when lead in 0xC2..0xDF, do: 1
  defp expected_continuations(lead) when lead in 0xE0..0xEF, do: 2
  defp expected_continuations(lead) when lead in 0xF0..0xF4, do: 3
  defp expected_continuations(_lead), do: 0

  defp count_continuations(_rest, expected, count) when count == expected, do: count

  defp count_continuations(<<byte, rest::binary>>, expected, count)
       when byte in 0x80..0xBF,
       do: count_continuations(rest, expected, count + 1)

  defp count_continuations(_rest, _expected, count), do: count

  defp do_escaped_prefix(<<>>, _maximum, parts, _bytes),
    do: {parts |> Enum.reverse() |> IO.iodata_to_binary(), true}

  defp do_escaped_prefix(value, maximum, parts, bytes) do
    <<codepoint::utf8, rest::binary>> = value
    encoded = escape_codepoint(codepoint)
    encoded_bytes = byte_size(encoded)

    if maximum == :infinity or bytes + encoded_bytes <= maximum do
      do_escaped_prefix(rest, maximum, [encoded | parts], bytes + encoded_bytes)
    else
      {parts |> Enum.reverse() |> IO.iodata_to_binary(), false}
    end
  end

  defp escape_codepoint(?\"), do: "\\\""
  defp escape_codepoint(?\\), do: "\\\\"
  defp escape_codepoint(8), do: "\\b"
  defp escape_codepoint(9), do: "\\t"
  defp escape_codepoint(10), do: "\\n"
  defp escape_codepoint(12), do: "\\f"
  defp escape_codepoint(13), do: "\\r"
  defp escape_codepoint(codepoint) when codepoint in 0..31, do: unicode_escape(codepoint)
  defp escape_codepoint(127), do: "\\u007f"
  defp escape_codepoint(codepoint), do: <<codepoint::utf8>>

  defp unicode_escape(codepoint) do
    encoded =
      codepoint |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")

    "\\u00" <> encoded
  end
end
