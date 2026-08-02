defmodule Synapse.Tool.WriteTest do
  use ExUnit.Case, async: false

  alias Synapse.Tool.{Call, CapabilitySet, Context, Executor, Limits, Result, Write}
  alias Synapse.Workspace

  alias Synapse.Workspace.{
    Access,
    Error,
    Fake,
    Handle,
    MutationResult,
    OpenRequest,
    OperationContext,
    Platform,
    Revision,
    WriteRequest
  }

  alias Synapse.Workspace.Limits, as: WorkspaceLimits

  defmodule CrashingWriteBackend do
    def workspace_backend?, do: true
    def valid_handle?(_handle), do: true
    def close(_handle), do: :ok

    def write(handle, _request, _context) do
      send(handle.state, :crashing_write_invoked)
      raise "synthetic write backend failure"
    end
  end

  defmodule MalformedWriteBackend do
    def workspace_backend?, do: true
    def valid_handle?(_handle), do: true
    def close(_handle), do: :ok

    def write(handle, _request, _context) do
      send(handle.state, :malformed_write_invoked)
      :malformed
    end
  end

  describe "argument preparation" do
    test "maps only exact missing or canonical revisions into WriteRequest" do
      creation = write_call("file.txt", "content", "missing")

      assert {:ok, %WriteRequest{expected_revision: :missing}} =
               Write.prepare(creation, Limits.default())

      revision = revision(1)
      replacement = write_call("file.txt", "replacement", Revision.encode(revision))

      assert {:ok, request} = Write.prepare(replacement, Limits.default())
      assert request.path == "file.txt"
      assert request.content == "replacement"
      assert request.expected_revision == revision
    end

    test "rejects malformed expectations, invalid paths, fields, UTF-8, and forged broad Calls" do
      %Call{} = valid = write_call("file.txt", "content", "missing")

      invalid = [
        %{valid | arguments: Map.delete(valid.arguments, "content")},
        %{valid | arguments: Map.put(valid.arguments, "extra", true)},
        %{valid | arguments: %{valid.arguments | "path" => "../file.txt"}},
        %{valid | arguments: %{valid.arguments | "path" => "/file.txt"}},
        %{valid | arguments: %{valid.arguments | "path" => "bad\0path"}},
        %{valid | arguments: %{valid.arguments | "content" => 1}},
        %{valid | arguments: %{valid.arguments | "expected_revision" => "Missing"}},
        %{valid | arguments: %{valid.arguments | "expected_revision" => "missing "}},
        %{valid | arguments: %{valid.arguments | "expected_revision" => "wsr1.invalid"}},
        %{valid | arguments: %{valid.arguments | "expected_revision" => 1}},
        %{valid | name: "read"},
        %Call{valid | arguments: %{valid.arguments | "content" => <<255>>}}
      ]

      Enum.each(invalid, fn call ->
        assert Write.prepare(call, Limits.default()) == {:error, :invalid_arguments}
      end)

      {:ok, limits} = Limits.new(max_path_bytes: 4)

      assert Write.prepare(write_call("12345", "content", "missing"), limits) ==
               {:error, :invalid_arguments}
    end

    test "accepts the maximum canonical argument envelope and rejects one byte beyond" do
      limits = Limits.default()
      maximum = largest_content_size(limits)
      call = write_call("file.txt", String.duplicate("x", maximum), "missing")

      assert {:ok, request} = Write.prepare(call, limits)
      assert byte_size(request.content) == maximum

      forged = raw_write_call("file.txt", String.duplicate("x", maximum + 1), "missing")
      assert Write.prepare(forged, limits) == {:error, :invalid_arguments}
    end
  end

  describe "Fake Workspace adapter" do
    test "creates a missing file with one exact write-only dispatch" do
      new_revision = revision(1)
      request = write_request("file.txt", "content", :missing)
      operation_context = operation_context("write-create")

      result =
        mutation_result("write-create", "file.txt", :missing, new_revision, 7, true, "created")

      handle = fake_handle([Fake.expect_write(request, operation_context, {:ok, result})])

      context = tool_context(handle, operation_id: "write-create")
      presented = Executor.execute(write_call("file.txt", "content", "missing"), context)
      content = decode(presented)

      assert presented.status == :ok
      assert content["path"] == "file.txt"
      assert content["previous_revision"] == "missing"
      assert content["revision"] == Revision.encode(new_revision)
      assert content["changed"] == true
      assert content["bytes_written"] == 7
      assert :ok = Fake.assert_finished(handle)
    end

    test "replaces one exact revision and preserves a successful no-op" do
      previous = revision(1)
      current = revision(2)
      replacement = write_request("file.txt", "new", previous)
      replace_context = operation_context("write-replace")

      replaced =
        mutation_result("write-replace", "file.txt", previous, current, 3, true, "changed")

      noop = write_request("file.txt", "new", current)
      noop_context = operation_context("write-noop")
      unchanged = mutation_result("write-noop", "file.txt", current, current, 0, false, "")

      handle =
        fake_handle([
          Fake.expect_write(replacement, replace_context, {:ok, replaced}),
          Fake.expect_write(noop, noop_context, {:ok, unchanged})
        ])

      replace_result =
        Executor.execute(
          write_call("file.txt", "new", Revision.encode(previous)),
          tool_context(handle, operation_id: "write-replace")
        )

      assert decode(replace_result)["changed"] == true

      noop_result =
        Executor.execute(
          write_call("file.txt", "new", Revision.encode(current)),
          tool_context(handle, operation_id: "write-noop")
        )

      noop_content = decode(noop_result)
      assert noop_content["changed"] == false
      assert noop_content["bytes_written"] == 0
      assert noop_content["previous_revision"] == noop_content["revision"]
      assert :ok = Fake.assert_finished(handle)
    end

    test "empty content and the maximum argument envelope dispatch without widening" do
      limits = Limits.default()
      maximum = largest_content_size(limits)
      content = String.duplicate("x", maximum)
      request = write_request("file.txt", content, :missing)
      operation_context = operation_context("write-maximum")

      result =
        mutation_result(
          "write-maximum",
          "file.txt",
          :missing,
          revision(1),
          maximum,
          true,
          "created"
        )

      handle = fake_handle([Fake.expect_write(request, operation_context, {:ok, result})])

      presented =
        Executor.execute(
          write_call("file.txt", content, "missing"),
          tool_context(handle, operation_id: "write-maximum")
        )

      assert presented.status == :ok
      assert :ok = Fake.assert_finished(handle)

      empty_request = write_request("empty.txt", "", :missing)
      empty_context = operation_context("write-empty")

      empty_result =
        mutation_result("write-empty", "empty.txt", :missing, revision(2), 0, true, "created")

      empty_handle =
        fake_handle([Fake.expect_write(empty_request, empty_context, {:ok, empty_result})])

      empty =
        Executor.execute(
          write_call("empty.txt", "", "missing"),
          tool_context(empty_handle, operation_id: "write-empty")
        )

      assert empty.status == :ok
      assert decode(empty)["bytes_written"] == 0
      assert :ok = Fake.assert_finished(empty_handle)
    end

    test "Workspace and Tool diff truncation remain independent" do
      previous = revision(1)
      current = revision(2)
      request = write_request("file.txt", "new", previous)
      operation_context = operation_context("write-diff")

      diff = String.duplicate("+changed\n", 1_000)

      result =
        mutation_result("write-diff", "file.txt", previous, current, 3, true, diff, true)

      handle = fake_handle([Fake.expect_write(request, operation_context, {:ok, result})])
      {:ok, limits} = Limits.new(max_result_content_bytes: 512)

      presented =
        Executor.execute(
          write_call("file.txt", "new", Revision.encode(previous)),
          tool_context(handle, operation_id: "write-diff", limits: limits)
        )

      content = decode(presented)
      assert content["diff_truncated"] == true
      assert content["presentation_truncated"] == true
      assert content["previous_revision"] == Revision.encode(previous)
      assert content["revision"] == Revision.encode(current)
      assert byte_size(presented.content) <= 512
      assert :ok = Fake.assert_finished(handle)
    end

    test "malformed revisions and denied capabilities consume no Workspace entry" do
      request = write_request("file.txt", "content", :missing)
      operation_context = operation_context("write-rejected")

      result =
        mutation_result("write-rejected", "file.txt", :missing, revision(1), 7, true, "created")

      handle = fake_handle([Fake.expect_write(request, operation_context, {:ok, result})])

      invalid =
        Executor.execute(write_call("file.txt", "content", "wsr1.invalid"), tool_context(handle))

      assert_result_reason(invalid, :error, "invalid_arguments")

      denied =
        Executor.execute(
          write_call("file.txt", "content", "missing"),
          tool_context(handle, capabilities: capabilities(read: true, write: false, exec: true))
        )

      assert_result_reason(denied, :error, "capability_denied")
      assert {:ok, 1} = Fake.remaining_operations(handle)
    end

    test "an opened Workspace file ceiling rejects oversized content before backend dispatch" do
      {:ok, workspace_limits} = WorkspaceLimits.new(max_file_bytes: 4)
      handle = fake_handle([], limits: workspace_limits)

      presented =
        Executor.execute(write_call("file.txt", "12345", "missing"), tool_context(handle))

      assert_result_reason(presented, :error, "invalid_arguments")
      assert :ok = Fake.assert_finished(handle)
    end

    test "Workspace access denial is defense in depth" do
      denied_access = %Access{read: true, write: false, exec: false}
      handle = fake_handle([], access: denied_access)

      presented =
        Executor.execute(write_call("file.txt", "content", "missing"), tool_context(handle))

      assert_result_reason(presented, :error, "access_denied")
      assert :ok = Fake.assert_finished(handle)
    end

    test "known conflicts and unknown outcomes remain distinct and never replay" do
      previous = revision(1)
      request = write_request("file.txt", "new", previous)

      stale_context = operation_context("write-stale")
      stale = workspace_error(:conflict, :stale_revision, :not_applied, "write-stale")

      ambiguous_context = operation_context("write-ambiguous")
      ambiguous = workspace_error(:ambiguous, :backend_unavailable, :unknown, "write-ambiguous")

      handle =
        fake_handle([
          Fake.expect_write(request, stale_context, {:error, stale}),
          Fake.expect_write(request, ambiguous_context, {:error, ambiguous}),
          Fake.expect_write(request, ambiguous_context, {:error, ambiguous})
        ])

      stale_result =
        Executor.execute(
          write_call("file.txt", "new", Revision.encode(previous)),
          tool_context(handle, operation_id: "write-stale")
        )

      assert_result_reason(stale_result, :error, "stale_revision")
      assert decode(stale_result)["error"]["message"] =~ "reread"

      ambiguous_result =
        Executor.execute(
          write_call("file.txt", "new", Revision.encode(previous)),
          tool_context(handle, operation_id: "write-ambiguous")
        )

      assert_result_reason(ambiguous_result, :ambiguous, "backend_unavailable")
      assert decode(ambiguous_result)["error"]["outcome"] == "unknown"
      assert {:ok, 1} = Fake.remaining_operations(handle)
    end

    test "expected-existing, Workspace limit, and known I/O failures remain distinct" do
      previous = revision(1)
      missing_request = write_request("file.txt", "new", :missing)
      revision_request = write_request("file.txt", "new", previous)

      expected_context = operation_context("write-expected-existing")
      limit_context = operation_context("write-limit")
      io_context = operation_context("write-io")

      expected =
        workspace_error(:conflict, :expected_missing, :not_applied, "write-expected-existing")

      limit = workspace_error(:limit, :file_too_large, :not_applied, "write-limit")
      io = workspace_error(:io, :io, :not_applied, "write-io")

      handle =
        fake_handle([
          Fake.expect_write(missing_request, expected_context, {:error, expected}),
          Fake.expect_write(revision_request, limit_context, {:error, limit}),
          Fake.expect_write(revision_request, io_context, {:error, io})
        ])

      calls = [
        {write_call("file.txt", "new", "missing"), "write-expected-existing", "expected_missing"},
        {write_call("file.txt", "new", Revision.encode(previous)), "write-limit",
         "file_too_large"},
        {write_call("file.txt", "new", Revision.encode(previous)), "write-io", "io"}
      ]

      Enum.each(calls, fn {call, operation_id, reason} ->
        result = Executor.execute(call, tool_context(handle, operation_id: operation_id))
        assert_result_reason(result, :error, reason)
      end)

      assert :ok = Fake.assert_finished(handle)
    end

    test "crashing or malformed central Write dispatch is ambiguous and invoked once" do
      cases = [
        {CrashingWriteBackend, :crashing_write_invoked},
        {MalformedWriteBackend, :malformed_write_invoked}
      ]

      Enum.each(cases, fn {backend, message} ->
        handle = backend_handle(backend)

        result =
          Executor.execute(
            write_call("file.txt", "content", "missing"),
            tool_context(handle, operation_id: "write-backend-failure")
          )

        assert result.status == :ambiguous
        assert decode(result)["error"]["outcome"] == "unknown"
        assert decode(result)["error"]["message"] =~ "do not retry blindly"
        assert_receive ^message
        refute_receive ^message
      end)
    end

    test "presentation pressure preserves retained successful and not-applied outcomes" do
      path = String.duplicate("p", 1_000)
      previous = revision(1)
      current = revision(2)
      success_request = write_request(path, "content", :missing)
      error_request = write_request(path, "content", previous)
      success_context = operation_context("write-present-success")
      error_context = operation_context("write-present-error")

      success =
        mutation_result(
          "write-present-success",
          path,
          :missing,
          current,
          7,
          true,
          "created"
        )

      stale =
        workspace_error(
          :conflict,
          :stale_revision,
          :not_applied,
          "write-present-error",
          path
        )

      handle =
        fake_handle([
          Fake.expect_write(success_request, success_context, {:ok, success}),
          Fake.expect_write(error_request, error_context, {:error, stale})
        ])

      {:ok, limits} = Limits.new(max_result_content_bytes: 256)

      successful =
        Executor.execute(
          write_call(path, "content", "missing"),
          tool_context(handle, operation_id: "write-present-success", limits: limits)
        )

      failed =
        Executor.execute(
          write_call(path, "content", Revision.encode(previous)),
          tool_context(handle, operation_id: "write-present-error", limits: limits)
        )

      assert successful.status == :ok
      assert decode(successful)["presentation"] == "unavailable"
      assert_result_reason(failed, :error, "presentation_failed")
      assert :ok = Fake.assert_finished(handle)
    end
  end

  describe "Real Workspace integration" do
    @describetag skip: not Platform.supported?()

    test "creates, reads, replaces, and rejects a stale replacement without changing the file" do
      in_temporary_directory(fn root ->
        handle = real_handle(root)

        try do
          created =
            Executor.execute(
              write_call("file.txt", "first", "missing"),
              tool_context(handle, operation_id: "real-write-create")
            )

          created_content = decode(created)
          assert created.status == :ok
          assert created_content["previous_revision"] == "missing"
          assert File.read!(Elixir.Path.join(root, "file.txt")) == "first"

          read =
            Executor.execute(
              read_call("file.txt"),
              tool_context(handle, operation_id: "real-write-read")
            )

          first_revision = decode(read)["revision"]
          assert first_revision == created_content["revision"]

          replaced =
            Executor.execute(
              write_call("file.txt", "second", first_revision),
              tool_context(handle, operation_id: "real-write-replace")
            )

          replaced_content = decode(replaced)
          assert replaced.status == :ok
          assert replaced_content["previous_revision"] == first_revision
          assert replaced_content["revision"] != first_revision
          assert File.read!(Elixir.Path.join(root, "file.txt")) == "second"

          stale =
            Executor.execute(
              write_call("file.txt", "stale", first_revision),
              tool_context(handle, operation_id: "real-write-stale")
            )

          assert_result_reason(stale, :error, "stale_revision")
          assert File.read!(Elixir.Path.join(root, "file.txt")) == "second"

          reread =
            Executor.execute(
              read_call("file.txt"),
              tool_context(handle, operation_id: "real-write-reread")
            )

          assert decode(reread)["revision"] == replaced_content["revision"]
        after
          Workspace.close(handle)
        end
      end)
    end

    test "failed validation and missing expectation leave an existing file unchanged" do
      in_temporary_directory(fn root ->
        File.write!(Elixir.Path.join(root, "file.txt"), "original")
        handle = real_handle(root)

        try do
          malformed =
            Executor.execute(
              write_call("file.txt", "invalid", "wsr1.invalid"),
              tool_context(handle, operation_id: "real-write-invalid")
            )

          assert_result_reason(malformed, :error, "invalid_arguments")
          assert File.read!(Elixir.Path.join(root, "file.txt")) == "original"

          expected_missing =
            Executor.execute(
              write_call("file.txt", "replacement", "missing"),
              tool_context(handle, operation_id: "real-write-missing")
            )

          assert_result_reason(expected_missing, :error, "expected_missing")
          assert File.read!(Elixir.Path.join(root, "file.txt")) == "original"
        after
          Workspace.close(handle)
        end
      end)
    end

    test "creation beneath a missing parent does not create directories" do
      in_temporary_directory(fn root ->
        handle = real_handle(root)

        try do
          presented =
            Executor.execute(
              write_call("missing/file.txt", "content", "missing"),
              tool_context(handle, operation_id: "real-write-parent")
            )

          assert presented.status == :error
          refute File.exists?(Elixir.Path.join(root, "missing"))
        after
          Workspace.close(handle)
        end
      end)
    end

    test "cross-handle and wrong-path revisions fail without changing either destination" do
      in_temporary_directory(fn root ->
        File.write!(Elixir.Path.join(root, "one.txt"), "one")
        File.write!(Elixir.Path.join(root, "two.txt"), "two")
        first_handle = real_handle(root)
        second_handle = real_handle(root)

        try do
          observed =
            Executor.execute(
              read_call("one.txt"),
              tool_context(first_handle, operation_id: "real-write-observe")
            )

          revision = decode(observed)["revision"]

          cross_handle =
            Executor.execute(
              write_call("one.txt", "cross", revision),
              tool_context(second_handle, operation_id: "real-write-cross")
            )

          wrong_path =
            Executor.execute(
              write_call("two.txt", "wrong", revision),
              tool_context(first_handle, operation_id: "real-write-wrong-path")
            )

          assert_result_reason(cross_handle, :error, "stale_revision")
          assert_result_reason(wrong_path, :error, "stale_revision")
          assert File.read!(Elixir.Path.join(root, "one.txt")) == "one"
          assert File.read!(Elixir.Path.join(root, "two.txt")) == "two"
        after
          Workspace.close(first_handle)
          Workspace.close(second_handle)
        end
      end)
    end

    test "Write source has no direct host or Workspace dispatch API" do
      source = File.read!("lib/synapse/tool/write.ex")

      refute source =~ ~r/\bFile\./
      refute source =~ ~r/\bSystem\./
      refute source =~ ~r/\bPort\./
      refute source =~ ~r/:file\./
      refute source =~ "Workspace.write"
    end
  end

  defp write_call(path, content, expected_revision) do
    {:ok, call} = Call.new(Map.from_struct(raw_write_call(path, content, expected_revision)))
    call
  end

  defp raw_write_call(path, content, expected_revision) do
    %Call{
      call_id: "call-write",
      name: "write",
      arguments: %{
        "path" => path,
        "content" => content,
        "expected_revision" => expected_revision
      }
    }
  end

  defp read_call(path) do
    {:ok, call} =
      Call.new(
        call_id: "call-read",
        name: "read",
        arguments: %{"path" => path, "offset" => nil, "limit" => nil}
      )

    call
  end

  defp tool_context(handle, options \\ []) do
    attrs =
      options
      |> Keyword.put_new(:capabilities, capabilities())
      |> Keyword.put_new(:operation_id, "tool-write-operation")
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

  defp operation_context(operation_id) do
    {:ok, context} =
      OperationContext.new(
        operation_id: operation_id,
        access: %Access{read: false, write: true, exec: false}
      )

    context
  end

  defp write_request(path, content, expectation) do
    {:ok, request} =
      WriteRequest.new(path: path, content: content, expected_revision: expectation)

    request
  end

  defp mutation_result(
         operation_id,
         path,
         previous,
         revision,
         bytes_written,
         changed,
         diff,
         diff_truncated \\ false
       ) do
    {:ok, result} =
      MutationResult.new(
        operation_id: operation_id,
        path: path,
        previous_revision: previous,
        revision: revision,
        bytes_written: bytes_written,
        changed: changed,
        diff: diff,
        diff_truncated: diff_truncated
      )

    result
  end

  defp workspace_error(kind, reason, outcome, operation_id, path \\ "file.txt") do
    {:ok, error} =
      Error.new(
        kind: kind,
        reason: reason,
        operation: :write,
        message: "Workspace write failed",
        operation_id: operation_id,
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

  defp backend_handle(backend) do
    %Handle{
      backend: backend,
      state: self(),
      token: make_ref(),
      limits: WorkspaceLimits.default(),
      access: %Access{read: true, write: true, exec: true}
    }
  end

  defp real_handle(root) do
    {:ok, request} =
      OpenRequest.new(
        root: root,
        owner: self(),
        limits: WorkspaceLimits.default(),
        access: %Access{read: true, write: true, exec: true}
      )

    {:ok, handle} = Workspace.open(request)
    handle
  end

  defp revision(byte) do
    {:ok, revision} = Revision.from_mac(:binary.copy(<<byte>>, 32))
    revision
  end

  defp largest_content_size(limits),
    do: largest_content_size(0, limits.max_argument_json_bytes, limits)

  defp largest_content_size(low, high, _limits) when low == high, do: low

  defp largest_content_size(low, high, limits) do
    middle = div(low + high + 1, 2)
    call = raw_write_call("file.txt", String.duplicate("x", middle), "missing")

    case Call.new(Map.from_struct(call), limits) do
      {:ok, _call} -> largest_content_size(middle, high, limits)
      {:error, _reason} -> largest_content_size(low, middle - 1, limits)
    end
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
        "synapse-tool-write-#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}"
      )

    File.mkdir!(root)

    try do
      fun.(root)
    after
      File.rm_rf!(root)
    end
  end
end
