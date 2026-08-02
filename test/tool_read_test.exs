defmodule Synapse.Tool.ReadTest do
  use ExUnit.Case, async: false

  alias Synapse.Tool.{Call, CapabilitySet, Context, Executor, Limits, Read, Result}
  alias Synapse.Workspace

  alias Synapse.Workspace.{
    Access,
    Error,
    Fake,
    OpenRequest,
    OperationContext,
    Platform,
    ReadLine,
    ReadRequest,
    ReadResult,
    Revision
  }

  alias Synapse.Workspace.Limits, as: WorkspaceLimits

  describe "argument preparation" do
    test "normalizes null defaults and maps zero-based offset to one-based lines" do
      call = read_call("lib/example.ex", nil, nil)

      assert {:ok, request} = Read.prepare(call, Limits.default())
      assert request.path == "lib/example.ex"
      assert request.start_line == 1
      assert request.line_count == 100
      assert request.max_bytes == 32_768

      call = read_call("lib/example.ex", 7, 3)
      assert {:ok, request} = Read.prepare(call, Limits.default())
      assert request.start_line == 8
      assert request.line_count == 3
    end

    test "uses trusted lowered line and source-byte defaults" do
      {:ok, limits} =
        Limits.new(
          default_read_lines: 5,
          max_read_lines: 10,
          default_read_source_bytes: 512,
          max_read_source_bytes: 1_024
        )

      assert {:ok, request} = Read.prepare(read_call("file.txt", nil, nil), limits)
      assert request.line_count == 5
      assert request.max_bytes == 512

      assert {:ok, request} = Read.prepare(read_call("file.txt", 0, 10), limits)
      assert request.line_count == 10
    end

    test "accepts the hard line maximum and largest non-overflowing offset" do
      assert {:ok, request} = Read.prepare(read_call("file.txt", nil, 1_000), Limits.default())
      assert request.line_count == 1_000

      maximum_offset = 9_223_372_036_854_775_806

      assert {:ok, request} =
               Read.prepare(read_call("file.txt", maximum_offset, 1), Limits.default())

      assert request.start_line == 9_223_372_036_854_775_807
    end

    test "rejects missing, additional, malformed, overflowing, and over-limit arguments" do
      limits = Limits.default()
      %Call{} = valid = read_call("file.txt", nil, nil)

      invalid_calls = [
        %{valid | arguments: %{"path" => "file.txt", "offset" => nil}},
        %{valid | arguments: Map.put(valid.arguments, "extra", true)},
        %{valid | arguments: %{"path" => "/file.txt", "offset" => nil, "limit" => nil}},
        %{valid | arguments: %{"path" => "../file.txt", "offset" => nil, "limit" => nil}},
        %{valid | arguments: %{"path" => "bad\0path", "offset" => nil, "limit" => nil}},
        %{valid | arguments: %{"path" => 1, "offset" => nil, "limit" => nil}},
        %{valid | arguments: %{"path" => "file.txt", "offset" => -1, "limit" => nil}},
        %{
          valid
          | arguments: %{
              "path" => "file.txt",
              "offset" => 9_223_372_036_854_775_807,
              "limit" => nil
            }
        },
        %{valid | arguments: %{"path" => "file.txt", "offset" => 1.0, "limit" => nil}},
        %{valid | arguments: %{"path" => "file.txt", "offset" => nil, "limit" => 0}},
        %{valid | arguments: %{"path" => "file.txt", "offset" => nil, "limit" => 1_001}},
        %{valid | arguments: %{"path" => "file.txt", "offset" => nil, "limit" => 1.0}},
        %{valid | name: "write"},
        %Call{valid | arguments: %{"path" => <<255>>, "offset" => nil, "limit" => nil}}
      ]

      Enum.each(invalid_calls, fn call ->
        assert Read.prepare(call, limits) == {:error, :invalid_arguments}
      end)

      {:ok, lowered} = Limits.new(max_path_bytes: 4, default_read_lines: 1, max_read_lines: 1)
      assert Read.prepare(read_call("12345", nil, nil), lowered) == {:error, :invalid_arguments}
      assert Read.prepare(read_call("a", nil, 2), lowered) == {:error, :invalid_arguments}
    end
  end

  describe "Fake Workspace adapter" do
    test "Executor delegates the exact default request and read-only operation context" do
      request = read_request("file.txt", 1, 100, 32_768)
      result = read_result("file.txt", revision(1), [line(1, "hello", :none)], nil, 5)
      operation_context = operation_context("read-default")
      handle = fake_handle([Fake.expect_read(request, operation_context, {:ok, result})])

      tool_context = tool_context(handle, operation_id: "read-default")
      presented = Executor.execute(read_call("file.txt", nil, nil), tool_context)
      content = decode(presented)

      assert presented.status == :ok
      assert content["path"] == "file.txt"
      assert content["revision"] == Revision.encode(result.revision)

      assert content["lines"] == [
               %{
                 "number" => 1,
                 "text" => "hello",
                 "ending" => "none",
                 "truncated" => false,
                 "presentation_truncated" => false
               }
             ]

      assert content["next_offset"] == nil
      assert :ok = Fake.assert_finished(handle)
    end

    test "preserves non-zero offsets, lowered limits, mixed endings, and direct continuation" do
      {:ok, limits} =
        Limits.new(
          default_read_lines: 2,
          max_read_lines: 3,
          default_read_source_bytes: 1_024,
          max_read_source_bytes: 2_048
        )

      request = read_request("mixed.txt", 4, 3, 1_024)

      lines = [
        line(4, "a", :lf),
        line(5, "", :crlf),
        line(6, "z", :lf)
      ]

      result = read_result("mixed.txt", revision(2), lines, 7, 6)
      operation_context = operation_context("read-window")
      handle = fake_handle([Fake.expect_read(request, operation_context, {:ok, result})])

      context = tool_context(handle, operation_id: "read-window", limits: limits)
      presented = Executor.execute(read_call("mixed.txt", 3, 3), context)
      content = decode(presented)

      assert Enum.map(content["lines"], &{&1["number"], &1["ending"]}) == [
               {4, "lf"},
               {5, "crlf"},
               {6, "lf"}
             ]

      assert content["next_offset"] == 6
      assert {:ok, %Revision{}} = Revision.parse(content["revision"])
      assert :ok = Fake.assert_finished(handle)
    end

    test "empty EOF result remains directly usable" do
      request = read_request("empty.txt", 1, 1, 32_768)
      result = read_result("empty.txt", revision(1), [], nil, 0)
      operation_context = operation_context("read-empty")
      handle = fake_handle([Fake.expect_read(request, operation_context, {:ok, result})])

      context = tool_context(handle, operation_id: "read-empty")
      presented = Executor.execute(read_call("empty.txt", 0, 1), context)
      content = decode(presented)

      assert content["lines"] == []
      assert content["next_offset"] == nil
      assert content["file_bytes"] == 0
      assert :ok = Fake.assert_finished(handle)
    end

    test "hard maximum line request dispatches exactly" do
      request = read_request("maximum.txt", 1, 1_000, 32_768)
      result = read_result("maximum.txt", revision(1), [], nil, 0)
      operation_context = operation_context("read-maximum")
      handle = fake_handle([Fake.expect_read(request, operation_context, {:ok, result})])

      context = tool_context(handle, operation_id: "read-maximum")
      presented = Executor.execute(read_call("maximum.txt", 0, 1_000), context)

      assert presented.status == :ok
      assert :ok = Fake.assert_finished(handle)
    end

    test "dropped trailing lines resume the first omitted physical line through Executor" do
      lines = Enum.map(1..20, &line(&1, String.duplicate("v", 40), :lf))
      request = read_request("many.txt", 1, 20, 32_768)
      result = read_result("many.txt", revision(1), lines, 21, 820)
      operation_context = operation_context("read-many")
      handle = fake_handle([Fake.expect_read(request, operation_context, {:ok, result})])
      {:ok, limits} = Limits.new(max_result_content_bytes: 700)

      context = tool_context(handle, operation_id: "read-many", limits: limits)
      presented = Executor.execute(read_call("many.txt", 0, 20), context)
      content = decode(presented)

      assert content["presentation_truncated"] == true
      assert length(content["lines"]) < 20
      assert content["next_offset"] == List.last(content["lines"])["number"]
      assert :ok = Fake.assert_finished(handle)
    end

    test "Workspace-only and Tool-only line clipping remain independent" do
      workspace_request = read_request("workspace.txt", 1, 1, 32_768)

      workspace_result =
        read_result("workspace.txt", revision(1), [line(1, "short", :lf, true)], 2, 5)

      workspace_context = operation_context("read-workspace-clip")

      workspace_handle =
        fake_handle([
          Fake.expect_read(workspace_request, workspace_context, {:ok, workspace_result})
        ])

      workspace_presented =
        Executor.execute(
          read_call("workspace.txt", 0, 1),
          tool_context(workspace_handle, operation_id: "read-workspace-clip")
        )

      [workspace_line] = decode(workspace_presented)["lines"]
      assert workspace_line["truncated"] == true
      assert workspace_line["presentation_truncated"] == false

      text = String.duplicate("界", 1_000)
      tool_request = read_request("tool.txt", 1, 1, 32_768)

      tool_result =
        read_result("tool.txt", revision(2), [line(1, text, :lf, false)], 2, byte_size(text) + 1)

      tool_context_value = operation_context("read-tool-clip")

      tool_handle =
        fake_handle([Fake.expect_read(tool_request, tool_context_value, {:ok, tool_result})])

      {:ok, limits} = Limits.new(max_result_content_bytes: 512)

      tool_presented =
        Executor.execute(
          read_call("tool.txt", 0, 1),
          tool_context(tool_handle, operation_id: "read-tool-clip", limits: limits)
        )

      [tool_line] = decode(tool_presented)["lines"]
      assert tool_line["truncated"] == false
      assert tool_line["presentation_truncated"] == true
    end

    test "Tool presentation clipping retains Workspace source clipping and continuation" do
      text = String.duplicate("界", 1_000)
      request = read_request("large.txt", 1, 1, 32_768)

      result =
        read_result("large.txt", revision(1), [line(1, text, :lf, true)], 2, byte_size(text))

      operation_context = operation_context("read-clipped")
      handle = fake_handle([Fake.expect_read(request, operation_context, {:ok, result})])
      {:ok, limits} = Limits.new(max_result_content_bytes: 512)

      context = tool_context(handle, operation_id: "read-clipped", limits: limits)
      presented = Executor.execute(read_call("large.txt", 0, 1), context)
      content = decode(presented)
      [rendered] = content["lines"]

      assert rendered["truncated"] == true
      assert rendered["presentation_truncated"] == true
      assert content["presentation_truncated"] == true
      assert content["next_offset"] == 1
      assert byte_size(presented.content) <= 512
      assert :ok = Fake.assert_finished(handle)
    end

    test "invalid arguments and missing capability consume no Workspace entry" do
      request = read_request("file.txt", 1, 100, 32_768)
      result = read_result("file.txt", revision(1), [], nil, 0)
      operation_context = operation_context("read-rejected")
      entry = Fake.expect_read(request, operation_context, {:ok, result})
      handle = fake_handle([entry])

      invalid = Executor.execute(read_call("../file.txt", nil, nil), tool_context(handle))
      assert_result_reason(invalid, :error, "invalid_arguments")

      denied_context =
        tool_context(handle,
          capabilities: capabilities(read: false, write: true, exec: true)
        )

      denied = Executor.execute(read_call("file.txt", nil, nil), denied_context)
      assert_result_reason(denied, :error, "capability_denied")
      assert {:ok, 1} = Fake.remaining_operations(handle)
    end

    test "Workspace Handle denial remains a structured Tool error without consuming Fake" do
      denied_access = %Access{read: false, write: false, exec: false}
      handle = fake_handle([], access: denied_access)
      context = tool_context(handle)

      presented = Executor.execute(read_call("file.txt", nil, nil), context)

      assert_result_reason(presented, :error, "access_denied")
      assert decode(presented)["error"]["workspace_kind"] == "denied"
      assert :ok = Fake.assert_finished(handle)
    end

    test "Workspace failure, cancellation, and deadline remain paired and structured" do
      request = read_request("missing.txt", 1, 1, 32_768)
      operation_context = operation_context("read-missing")

      error = workspace_error(:not_found, :not_found, :not_applicable, "missing.txt")
      handle = fake_handle([Fake.expect_read(request, operation_context, {:error, error})])
      context = tool_context(handle, operation_id: "read-missing")

      missing = Executor.execute(read_call("missing.txt", 0, 1), context)
      assert_result_reason(missing, :error, "not_found")
      assert :ok = Fake.assert_finished(handle)

      cancel_ref = make_ref()

      cancelled_context =
        operation_context("read-cancelled", cancel_ref: cancel_ref)

      cancelled_entry =
        Fake.expect_read(
          request,
          cancelled_context,
          {:ok, read_result("missing.txt", revision(1), [], nil, 0)}
        )

      cancelled_handle = fake_handle([cancelled_entry])
      send(self(), {:cancel, cancel_ref})

      cancelled =
        Executor.execute(
          read_call("missing.txt", 0, 1),
          tool_context(cancelled_handle,
            operation_id: "read-cancelled",
            cancel_ref: cancel_ref
          )
        )

      assert_result_reason(cancelled, :error, "cancelled")
      assert {:ok, 1} = Fake.remaining_operations(cancelled_handle)

      deadline = System.monotonic_time(:millisecond) - 1
      deadline_context = operation_context("read-deadline", deadline: deadline)

      deadline_entry =
        Fake.expect_read(
          request,
          deadline_context,
          {:ok, read_result("missing.txt", revision(1), [], nil, 0)}
        )

      deadline_handle = fake_handle([deadline_entry])

      elapsed =
        Executor.execute(
          read_call("missing.txt", 0, 1),
          tool_context(deadline_handle,
            operation_id: "read-deadline",
            deadline: deadline
          )
        )

      assert_result_reason(elapsed, :error, "deadline_elapsed")
      assert {:ok, 1} = Fake.remaining_operations(deadline_handle)
    end
  end

  describe "Real Workspace integration" do
    @describetag skip: not Platform.supported?()

    test "reads a temporary UTF-8 file with revision, numbering, and continuation" do
      in_temporary_directory(fn root ->
        File.write!(Elixir.Path.join(root, "sample.txt"), "first\r\nsecond\nthird")
        handle = real_handle(root)

        try do
          first =
            Executor.execute(
              read_call("sample.txt", nil, 2),
              tool_context(handle, operation_id: "real-read-first")
            )

          content = decode(first)
          assert first.status == :ok

          assert Enum.map(content["lines"], &{&1["number"], &1["text"], &1["ending"]}) == [
                   {1, "first", "crlf"},
                   {2, "second", "lf"}
                 ]

          assert content["next_offset"] == 2
          assert {:ok, revision} = Revision.parse(content["revision"])
          assert Revision.encode(revision) == content["revision"]

          continued =
            Executor.execute(
              read_call("sample.txt", content["next_offset"], 2),
              tool_context(handle, operation_id: "real-read-next")
            )

          next_content = decode(continued)
          assert Enum.map(next_content["lines"], &{&1["number"], &1["text"]}) == [{3, "third"}]
          assert next_content["next_offset"] == nil
          refute first.content =~ root
          refute continued.content =~ root
        after
          Workspace.close(handle)
        end
      end)
    end

    test "traversal, symlink, non-regular, invalid UTF-8, and oversized files are structured" do
      in_temporary_directory(fn root ->
        File.write!(Elixir.Path.join(root, "target.txt"), "target")
        File.ln_s!("target.txt", Elixir.Path.join(root, "link.txt"))
        File.mkdir!(Elixir.Path.join(root, "directory"))
        File.write!(Elixir.Path.join(root, "invalid.txt"), <<255>>)
        File.write!(Elixir.Path.join(root, "large.txt"), String.duplicate("x", 17))

        {:ok, workspace_limits} = WorkspaceLimits.new(max_file_bytes: 16)
        handle = real_handle(root, workspace_limits)

        try do
          cases = [
            {"../target.txt", "invalid_arguments"},
            {"link.txt", "symlink"},
            {"directory", "not_regular_file"},
            {"invalid.txt", "invalid_utf8"},
            {"large.txt", "file_too_large"}
          ]

          Enum.with_index(cases, 1)
          |> Enum.each(fn {{path, reason}, index} ->
            presented =
              Executor.execute(
                read_call(path, nil, 1),
                tool_context(handle, operation_id: "real-read-error-#{index}")
              )

            assert_result_reason(presented, :error, reason)
            refute presented.content =~ root
          end)
        after
          Workspace.close(handle)
        end
      end)
    end

    test "Tool production source has no direct host API and only Dispatcher calls Workspace" do
      sources =
        "lib/synapse/tool/*.ex"
        |> Elixir.Path.wildcard()
        |> Map.new(&{&1, File.read!(&1)})

      Enum.each(sources, fn {_path, source} ->
        refute source =~ ~r/\bFile\./
        refute source =~ ~r/\bSystem\./
        refute source =~ ~r/\bPort\./
        refute source =~ ~r/:file\./
        refute source =~ "MuonTrap"
      end)

      workspace_callers =
        Enum.filter(sources, fn {_path, source} ->
          source =~ ~r/Workspace\.(read|write|edit|run)\(/
        end)

      assert Enum.map(workspace_callers, &elem(&1, 0)) == ["lib/synapse/tool/dispatcher.ex"]
    end
  end

  defp read_call(path, offset, limit) do
    {:ok, call} =
      Call.new(
        call_id: "call-read",
        name: "read",
        arguments: %{"path" => path, "offset" => offset, "limit" => limit}
      )

    call
  end

  defp tool_context(handle, options \\ []) do
    attrs =
      options
      |> Keyword.put_new(:capabilities, capabilities())
      |> Keyword.put_new(:operation_id, "tool-read-operation")
      |> Keyword.put_new(:limits, Limits.default())
      |> Keyword.put(:workspace, handle)

    {:ok, context} = Context.new(attrs)
    context
  end

  defp capabilities(options \\ []) do
    {:ok, capabilities} =
      CapabilitySet.new(
        fs_read: Keyword.get(options, :read, true),
        fs_write: Keyword.get(options, :write, true),
        process_exec: Keyword.get(options, :exec, true)
      )

    capabilities
  end

  defp operation_context(operation_id, options \\ []) do
    {:ok, context} =
      OperationContext.new(
        operation_id: operation_id,
        access: %Access{read: true, write: false, exec: false},
        cancel_ref: Keyword.get(options, :cancel_ref),
        deadline: Keyword.get(options, :deadline, :infinity)
      )

    context
  end

  defp read_request(path, start_line, line_count, max_bytes) do
    {:ok, request} =
      ReadRequest.new(
        path: path,
        start_line: start_line,
        line_count: line_count,
        max_bytes: max_bytes
      )

    request
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
    {:ok, line} = ReadLine.new(number: number, text: text, ending: ending, truncated: truncated)
    line
  end

  defp workspace_error(kind, reason, outcome, path) do
    {:ok, error} =
      Error.new(
        kind: kind,
        reason: reason,
        operation: :read,
        message: "Workspace read failed",
        operation_id: "read-missing",
        path: path,
        outcome: outcome
      )

    error
  end

  defp fake_handle(script, options \\ []) do
    {:ok, handle} = Fake.open(script, options)
    on_exit(fn -> Workspace.close(handle) end)
    handle
  end

  defp real_handle(root, limits \\ WorkspaceLimits.default()) do
    {:ok, request} =
      OpenRequest.new(
        root: root,
        owner: self(),
        limits: limits,
        access: %Access{read: true, write: true, exec: true}
      )

    {:ok, handle} = Workspace.open(request)
    handle
  end

  defp revision(byte) do
    {:ok, revision} = Revision.from_mac(:binary.copy(<<byte>>, 32))
    revision
  end

  defp decode(%Result{} = result) do
    {:ok, content} = Elixir.JSON.decode(result.content)
    content
  end

  defp assert_result_reason(result, status, reason) do
    assert %Result{status: ^status} = result
    assert decode(result)["error"]["reason"] == reason
  end

  defp in_temporary_directory(fun) do
    root =
      Elixir.Path.join(
        System.tmp_dir!(),
        "synapse-tool-read-#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}"
      )

    File.mkdir!(root)

    try do
      fun.(root)
    after
      File.rm_rf!(root)
    end
  end
end
