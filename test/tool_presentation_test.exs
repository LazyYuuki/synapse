defmodule Synapse.Tool.PresentationTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Synapse.Tool.{FixedResult, Limits, Presentation, Result}

  alias Synapse.Workspace.{
    Error,
    MutationResult,
    ProcessResult,
    ReadLine,
    ReadResult,
    Revision
  }

  @workspace_kinds [
    :invalid,
    :not_found,
    :denied,
    :conflict,
    :limit,
    :cancelled,
    :unsupported,
    :io,
    :unavailable
  ]

  @workspace_reasons [
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

  describe "deterministic success envelopes" do
    test "Read output has fixed key order and direct continuation fields" do
      revision = revision(1)
      result = read_result("file.txt", revision, [line(1, "hello", :none)], nil, 5)

      presented = Presentation.read("call-read", {:ok, result}, Limits.default())

      expected =
        ~s({"status":"ok","tool":"read","path":"file.txt","revision":"#{Revision.encode(revision)}","lines":[{"number":1,"text":"hello","ending":"none","truncated":false,"presentation_truncated":false}],"next_offset":null,"file_bytes":5,"presentation_truncated":false})

      assert %Result{status: :ok, content: ^expected} = presented
      assert presented.metadata == %{"outcome" => "completed", "tool" => "read"}
    end

    test "Write and Edit use the same fixed mutation evidence shape" do
      previous = revision(1)
      current = revision(2)

      write = mutation_result(:missing, current, "created", 7)
      edit = mutation_result(previous, current, "changed", 7)

      write_result = Presentation.write("call-write", {:ok, write}, Limits.default())
      edit_result = Presentation.edit("call-edit", {:ok, edit}, Limits.default())

      assert write_result.content ==
               ~s({"status":"ok","tool":"write","path":"file.txt","previous_revision":"missing","revision":"#{Revision.encode(current)}","changed":true,"bytes_written":7,"diff":"created","diff_truncated":false,"presentation_truncated":false})

      assert edit_result.content ==
               ~s({"status":"ok","tool":"edit","path":"file.txt","previous_revision":"#{Revision.encode(previous)}","revision":"#{Revision.encode(current)}","changed":true,"bytes_written":7,"diff":"changed","diff_truncated":false,"presentation_truncated":false})
    end

    test "mutation no-op retains equal revisions and empty evidence" do
      revision = revision(1)
      result = mutation_noop(revision)

      presented = Presentation.edit("call-edit", {:ok, result}, Limits.default())
      content = decode(presented)

      assert presented.status == :ok
      assert content["changed"] == false
      assert content["bytes_written"] == 0
      assert content["diff"] == ""
      assert content["previous_revision"] == content["revision"]
    end

    test "Bash distinguishes zero and natural non-zero exits without losing evidence" do
      zero = process_result(0, "ok\n")
      nonzero = process_result(7, "failed\n")

      zero_result = Presentation.bash("call-zero", {:ok, zero}, Limits.default())
      nonzero_result = Presentation.bash("call-nonzero", {:ok, nonzero}, Limits.default())

      assert zero_result.content ==
               ~S({"status":"ok","tool":"bash","exit_code":0,"termination":"exited","elapsed_ms":12,"output":"ok\n","output_bytes":3,"truncated":false,"presentation_truncated":false})

      assert nonzero_result.content ==
               ~S({"status":"error","tool":"bash","outcome":"completed","exit_code":7,"termination":"exited","elapsed_ms":12,"output":"failed\n","output_bytes":7,"truncated":false,"presentation_truncated":false})

      assert nonzero_result.status == :error
      assert nonzero_result.metadata["outcome"] == "completed"
    end
  end

  describe "structural truncation and exact byte budgets" do
    test "every representative budget produces a bounded valid object on every envelope path" do
      read =
        read_result(
          "file.txt",
          revision(1),
          Enum.map(1..10, &line(&1, String.duplicate("\"界", 20), :lf)),
          11,
          1_000
        )

      mutation =
        mutation_result(
          revision(1),
          revision(2),
          String.duplicate("\\diff\n", 500),
          10,
          true
        )

      process = process_result(3, :binary.copy(<<255, 10, 127>>, 1_000))
      known = workspace_error(:conflict, :stale_revision, :not_applied, path: "file.txt")

      unknown =
        workspace_error(:ambiguous, :output_limit, :unknown,
          operation: :run,
          path: "."
        )

      for maximum <- [256, 257, 300, 511, 512, 1_024, 4_096] do
        {:ok, limits} = Limits.new(max_result_content_bytes: maximum)

        results = [
          Presentation.read("call-read", {:ok, read}, limits),
          Presentation.write("call-write", {:ok, mutation}, limits),
          Presentation.bash("call-bash", {:ok, process}, limits),
          Presentation.write("call-known", {:error, known}, limits),
          Presentation.bash("call-unknown", {:error, unknown}, limits)
        ]

        Enum.each(results, fn result ->
          assert byte_size(result.content) <= maximum
          assert_valid_result_json(result)
        end)
      end
    end

    test "Read fits at the exact full boundary and clips one byte below it" do
      result =
        read_result(
          "file.txt",
          revision(1),
          [line(1, String.duplicate("x", 300), :none)],
          nil,
          300
        )

      full = Presentation.read("call-read", {:ok, result}, Limits.default())
      full_bytes = byte_size(full.content)

      assert {:ok, exact_limits} = Limits.new(max_result_content_bytes: full_bytes)
      assert {:ok, short_limits} = Limits.new(max_result_content_bytes: full_bytes - 1)

      exact = Presentation.read("call-read", {:ok, result}, exact_limits)
      short = Presentation.read("call-read", {:ok, result}, short_limits)

      assert exact.content == full.content
      assert decode(exact)["presentation_truncated"] == false
      assert byte_size(short.content) <= full_bytes - 1
      assert decode(short)["presentation_truncated"] == true
      assert_valid_result_json(short)
    end

    test "an empty line that cannot fit its false flag is omitted rather than falsely clipped" do
      result = read_result("empty-line.txt", revision(1), [line(1, "", :lf)], 2, 1)
      full = Presentation.read("call-empty-line", {:ok, result}, Limits.default())
      {:ok, limits} = Limits.new(max_result_content_bytes: byte_size(full.content) - 1)

      content = decode(Presentation.read("call-empty-line", {:ok, result}, limits))

      assert content["lines"] == []
      assert content["next_offset"] == 0
      assert content["presentation_truncated"] == true
    end

    test "mutation fits at its exact boundary and clips evidence one byte below it" do
      result =
        mutation_result(
          revision(1),
          revision(2),
          String.duplicate("changed\n", 100),
          8
        )

      full = Presentation.write("call-write", {:ok, result}, Limits.default())
      full_bytes = byte_size(full.content)
      {:ok, exact_limits} = Limits.new(max_result_content_bytes: full_bytes)
      {:ok, short_limits} = Limits.new(max_result_content_bytes: full_bytes - 1)

      exact = Presentation.write("call-write", {:ok, result}, exact_limits)
      short = Presentation.write("call-write", {:ok, result}, short_limits)

      assert exact.content == full.content
      assert decode(exact)["presentation_truncated"] == false
      assert decode(short)["presentation_truncated"] == true
      assert byte_size(short.content) <= full_bytes - 1
    end

    test "Read omits trailing lines and resumes at the first omitted physical line" do
      lines = Enum.map(1..20, &line(&1, String.duplicate("v", 40), :lf))
      result = read_result("many.txt", revision(1), lines, 21, 820)
      {:ok, limits} = Limits.new(max_result_content_bytes: 700)

      presented = Presentation.read("call-many", {:ok, result}, limits)
      content = decode(presented)
      returned = content["lines"]

      assert content["presentation_truncated"]
      assert length(returned) < length(lines)
      assert content["next_offset"] == List.last(returned)["number"]
      assert_valid_result_json(presented)
    end

    test "one huge line is UTF-8 clipped and keeps source truncation separate" do
      text = String.duplicate("界", 1_000)
      source_line = line(4, text, :lf, true)
      result = read_result("huge.txt", revision(1), [source_line], 5, byte_size(text) + 1)
      {:ok, limits} = Limits.new(max_result_content_bytes: 512)

      presented = Presentation.read("call-huge", {:ok, result}, limits)
      content = decode(presented)
      [rendered] = content["lines"]

      assert rendered["truncated"] == true
      assert rendered["presentation_truncated"] == true
      assert String.valid?(rendered["text"])
      assert content["next_offset"] == 4
      assert content["presentation_truncated"] == true
    end

    test "an omitted first line resumes that line and a clipped final line at EOF returns null" do
      first = line(1, String.duplicate("x", 500), :lf)
      result = read_result("file.txt", revision(1), [first], 2, 501)

      full_size =
        byte_size(Presentation.read("call-read", {:ok, result}, Limits.default()).content)

      {_maximum, omitted} =
        Enum.find_value(256..full_size, fn maximum ->
          {:ok, limits} = Limits.new(max_result_content_bytes: maximum)
          content = limits |> then(&Presentation.read("call-read", {:ok, result}, &1)) |> decode()

          if Map.has_key?(content, "lines") and content["lines"] == [],
            do: {maximum, content}
        end)

      assert omitted["next_offset"] == 0
      assert omitted["presentation_truncated"] == true

      final = line(9, String.duplicate("界", 500), :none)
      final_result = read_result("final.txt", revision(1), [final], nil, byte_size(final.text))
      {:ok, limits} = Limits.new(max_result_content_bytes: 512)
      final_content = decode(Presentation.read("call-final", {:ok, final_result}, limits))

      assert final_content["presentation_truncated"] == true
      assert final_content["next_offset"] == nil
    end

    test "large diff distinguishes Workspace and Tool truncation" do
      result =
        mutation_result(
          revision(1),
          revision(2),
          String.duplicate("+changed\n", 1_000),
          8,
          true
        )

      {:ok, limits} = Limits.new(max_result_content_bytes: 512)
      presented = Presentation.write("call-write", {:ok, result}, limits)
      content = decode(presented)

      assert content["diff_truncated"] == true
      assert content["presentation_truncated"] == true
      assert content["previous_revision"] == Revision.encode(revision(1))
      assert content["revision"] == Revision.encode(revision(2))
      assert String.valid?(content["diff"])
      assert_valid_result_json(presented)
    end

    test "large natural process output is clipped without changing exit outcome" do
      output = String.duplicate("result\n", 2_000)
      result = process_result(9, output)
      {:ok, limits} = Limits.new(max_result_content_bytes: 512)

      presented = Presentation.bash("call-bash", {:ok, result}, limits)
      content = decode(presented)

      assert presented.status == :error
      assert content["outcome"] == "completed"
      assert content["exit_code"] == 9
      assert content["output_bytes"] == byte_size(output)
      assert content["truncated"] == false
      assert content["presentation_truncated"] == true
      assert byte_size(presented.content) <= 512
    end

    test "impossible mandatory identity pressure uses an outcome-preserving fallback" do
      path = String.duplicate("q", 1_000)
      result = read_result(path, revision(1), [], nil, 0)
      {:ok, limits} = Limits.new(max_result_content_bytes: 256)

      presented = Presentation.read("call-read", {:ok, result}, limits)

      assert presented.status == :ok
      assert decode(presented) == %{"presentation" => "unavailable", "status" => "ok"}
      refute presented.content =~ path
    end
  end

  describe "process UTF-8 replacement and terminal-safe JSON" do
    test "invalid UTF-8 is replaced deterministically at every insertion boundary" do
      valid = "a界z"

      for offset <- 0..byte_size(valid) do
        <<prefix::binary-size(^offset), suffix::binary>> = valid
        raw = prefix <> <<255, 226, 130>> <> suffix
        result = process_result(0, raw)
        presented = Presentation.bash("call-#{offset}", {:ok, result}, Limits.default())

        assert decode(presented)["output"] == String.replace_invalid(raw, "�")
        assert_valid_result_json(presented)
      end
    end

    test "replacement matches the standard library across invalid UTF-8 classes" do
      invalid_values = [
        <<255, 255>>,
        <<226, 40, 161>>,
        <<240, 40, 140, 188>>,
        <<192, 175>>,
        <<237, 160, 128>>,
        <<226, 130>>,
        <<244, 144, 128, 128>>,
        <<97, 226, 130, 98>>
      ]

      Enum.each(invalid_values, fn raw ->
        presented =
          Presentation.bash("call-invalid", {:ok, process_result(0, raw)}, Limits.default())

        assert decode(presented)["output"] == String.replace_invalid(raw, "�")
      end)
    end

    test "quotes, slashes, controls, DEL, and multibyte text remain non-terminal data" do
      raw = <<0, 8, 9, 10, 12, 13, 31, 34, 47, 92, 127>> <> "界"
      result = process_result(0, raw)
      presented = Presentation.bash("call-controls", {:ok, result}, Limits.default())

      assert decode(presented)["output"] == raw
      assert presented.content =~ "\\u0000"
      assert presented.content =~ "\\u001f"
      assert presented.content =~ "\\u007f"
      refute :binary.match(presented.content, <<127>>) != :nomatch
      assert_valid_result_json(presented)
    end

    test "raw output count remains separate from replacement and escaped bytes" do
      raw = <<255, 10, 255>>
      result = process_result(0, raw)
      presented = Presentation.bash("call-bytes", {:ok, result}, Limits.default())
      content = decode(presented)

      assert content["output"] == "�\n�"
      assert content["output_bytes"] == 3
      assert byte_size(content["output"]) > content["output_bytes"]
    end

    test "invalid replacement expansion is clipped directly under the final budget" do
      raw = :binary.copy(<<255>>, 5_000)
      result = process_result(0, raw)
      {:ok, limits} = Limits.new(max_result_content_bytes: 512)

      presented = Presentation.bash("call-invalid", {:ok, result}, limits)
      content = decode(presented)

      assert content["presentation_truncated"] == true
      assert content["output_bytes"] == 5_000
      assert String.valid?(content["output"])
      assert String.starts_with?(String.replace_invalid(raw, "�"), content["output"])
      assert byte_size(presented.content) <= 512
    end
  end

  describe "Workspace failure mapping" do
    test "maps every Workspace kind and both known outcomes to ordinary errors" do
      for kind <- @workspace_kinds, outcome <- [:not_applicable, :not_applied] do
        error = workspace_error(kind, :invalid_request, outcome)
        presented = Presentation.write("call-error", {:error, error}, Limits.default())
        content = decode(presented)

        assert presented.status == :error
        assert content["error"]["kind"] == "workspace"
        assert content["error"]["workspace_kind"] == Atom.to_string(kind)
        assert content["error"]["outcome"] == Atom.to_string(outcome)
      end
    end

    test "maps every Workspace reason to a fixed non-secret diagnostic" do
      {:ok, limits} = Limits.new(max_error_message_bytes: 128)

      for reason <- @workspace_reasons do
        error =
          workspace_error(:invalid, reason, :not_applied, message: "synthetic-message-secret")

        presented = Presentation.write("call-reason", {:error, error}, limits)
        content = decode(presented)

        assert presented.status == :error
        assert content["error"]["reason"] == Atom.to_string(reason)
        assert byte_size(content["error"]["message"]) <= limits.max_error_message_bytes
        refute content["error"]["message"] =~ "synthetic"
        refute presented.content =~ "synthetic-message-secret"
      end
    end

    test "unknown outcome maps mechanically to ambiguity with inspect-before-retry guidance" do
      error = workspace_error(:ambiguous, :output_limit, :unknown, operation: :run)
      presented = Presentation.bash("call-unknown", {:error, error}, Limits.default())
      content = decode(presented)

      assert presented.status == :ambiguous
      assert content["status"] == "ambiguous"
      assert content["error"]["workspace_kind"] == "ambiguous"
      assert content["error"]["reason"] == "output_limit"
      assert content["error"]["outcome"] == "unknown"
      assert content["error"]["message"] =~ "do not retry blindly"
    end

    test "copies only allowlisted numeric details and never operation identity or messages" do
      details = %{
        "actual" => 12,
        "attempt" => 2,
        "current_revision" => "synthetic-revision-secret",
        "action" => "synthetic-action-secret",
        "retryable" => true
      }

      error =
        workspace_error(:conflict, :stale_revision, :not_applied,
          message: "synthetic-message-secret",
          operation_id: "synthetic-operation-secret",
          path: "lib/file.txt",
          details: details
        )

      log =
        capture_log(fn ->
          presented = Presentation.write("call-details", {:error, error}, Limits.default())
          content = decode(presented)

          assert content["error"]["details"] == %{"actual" => 12, "attempt" => 2}
          assert content["error"]["path"] == "lib/file.txt"
          refute presented.content =~ "synthetic"
        end)

      refute log =~ "synthetic"
    end

    test "preserves the required stale, match, denial, cancellation, deadline, and output distinctions" do
      classifications = [
        {:conflict, :stale_revision},
        {:conflict, :expected_missing},
        {:conflict, :no_match},
        {:conflict, :multiple_matches},
        {:denied, :access_denied},
        {:cancelled, :cancelled},
        {:cancelled, :deadline_elapsed},
        {:limit, :output_limit}
      ]

      observed =
        Map.new(classifications, fn {kind, reason} ->
          error = workspace_error(kind, reason, :not_applied)
          result = Presentation.write("call-#{reason}", {:error, error}, Limits.default())
          content = decode(result)["error"]
          {reason, {content["workspace_kind"], content["reason"]}}
        end)

      assert observed ==
               Map.new(classifications, fn {kind, reason} ->
                 {reason, {Atom.to_string(kind), Atom.to_string(reason)}}
               end)
    end

    test "presentation failure fallback retains known and unknown outcomes without raw data" do
      long_path = String.duplicate("p", 1_000)
      {:ok, limits} = Limits.new(max_result_content_bytes: 256)

      known =
        workspace_error(:conflict, :stale_revision, :not_applied,
          path: long_path,
          message: "synthetic-known-secret"
        )

      unknown =
        workspace_error(:ambiguous, :backend_unavailable, :unknown,
          path: long_path,
          message: "synthetic-unknown-secret"
        )

      known_result = Presentation.write("call-known", {:error, known}, limits)
      unknown_result = Presentation.write("call-unknown", {:error, unknown}, limits)

      assert known_result.status == :error
      assert decode(known_result)["error"]["reason"] == "presentation_failed"
      assert unknown_result.status == :ambiguous
      assert decode(unknown_result)["error"]["reason"] == "presentation_failed"
      refute known_result.content =~ "synthetic"
      refute unknown_result.content =~ "synthetic"
    end

    test "known non-exited process fallback remains an error and wrong result types fail closed" do
      timed_out = process_termination(:timed_out)

      fallback =
        FixedResult.presentation_fallback("call-timeout", {:ok, timed_out}, Limits.default())

      assert fallback.status == :error
      assert decode(fallback)["error"]["outcome"] == "completed"

      read = read_result("file.txt", revision(1), [], nil, 0)
      mismatched = Presentation.write("call-write", {:ok, read}, Limits.default())

      assert mismatched.status == :error
      assert decode(mismatched)["error"]["reason"] == "internal_error"
    end
  end

  describe "intentional model-visible evidence" do
    test "does not claim to remove secrets intentionally returned as read or process evidence" do
      secret = "synthetic-returned-credential"

      read =
        read_result("file.txt", revision(1), [line(1, secret, :none)], nil, byte_size(secret))

      process = process_result(0, secret)

      assert Presentation.read("call-read", {:ok, read}, Limits.default()).content =~ secret
      assert Presentation.bash("call-bash", {:ok, process}, Limits.default()).content =~ secret
    end
  end

  defp read_result(path, revision, lines, next_line, file_bytes) do
    {:ok, result} =
      ReadResult.new(
        path: path,
        revision: revision,
        lines: lines,
        next_line: next_line,
        file_bytes: file_bytes
      )

    result
  end

  defp line(number, text, ending, truncated \\ false) do
    {:ok, line} =
      ReadLine.new(number: number, text: text, ending: ending, truncated: truncated)

    line
  end

  defp mutation_result(previous, revision, diff, bytes_written, diff_truncated \\ false) do
    {:ok, result} =
      MutationResult.new(
        operation_id: "tool-operation",
        path: "file.txt",
        previous_revision: previous,
        revision: revision,
        bytes_written: bytes_written,
        changed: true,
        diff: diff,
        diff_truncated: diff_truncated
      )

    result
  end

  defp mutation_noop(revision) do
    {:ok, result} =
      MutationResult.new(
        operation_id: "tool-operation",
        path: "file.txt",
        previous_revision: revision,
        revision: revision,
        bytes_written: 0,
        changed: false,
        diff: "",
        diff_truncated: false
      )

    result
  end

  defp process_result(exit_code, output) do
    {:ok, result} =
      ProcessResult.new(
        operation_id: "tool-operation",
        termination: :exited,
        exit_code: exit_code,
        output: output,
        output_bytes: byte_size(output),
        truncated: false,
        elapsed_ms: 12
      )

    result
  end

  defp process_termination(termination) do
    {:ok, result} =
      ProcessResult.new(
        operation_id: "tool-operation",
        termination: termination,
        exit_code: nil,
        output: "",
        output_bytes: 0,
        truncated: false,
        elapsed_ms: 12
      )

    result
  end

  defp workspace_error(kind, reason, outcome, options \\ []) do
    {:ok, error} =
      Error.new(
        kind: kind,
        reason: reason,
        operation: Keyword.get(options, :operation, :write),
        message: Keyword.get(options, :message, "Workspace operation failed"),
        operation_id: Keyword.get(options, :operation_id),
        path: Keyword.get(options, :path),
        outcome: outcome,
        details: Keyword.get(options, :details, %{})
      )

    error
  end

  defp revision(byte) do
    {:ok, revision} = Revision.from_mac(:binary.copy(<<byte>>, 32))
    revision
  end

  defp decode(%Result{} = result) do
    {:ok, content} = Elixir.JSON.decode(result.content)
    content
  end

  defp assert_valid_result_json(%Result{} = result) do
    assert String.valid?(result.content)
    assert {:ok, content} = Elixir.JSON.decode(result.content)
    assert is_map(content)
    refute :binary.match(result.content, <<127>>) != :nomatch
  end
end
