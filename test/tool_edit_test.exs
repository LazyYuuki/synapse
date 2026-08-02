defmodule Synapse.Tool.EditTest do
  use ExUnit.Case, async: false

  alias Synapse.Tool.{Call, CapabilitySet, Context, Edit, Executor, Limits, Result}
  alias Synapse.Workspace

  alias Synapse.Workspace.{
    Access,
    EditRequest,
    Error,
    Fake,
    Handle,
    MutationResult,
    OpenRequest,
    OperationContext,
    Platform,
    Revision
  }

  alias Synapse.Workspace.Limits, as: WorkspaceLimits

  defmodule CrashingEditBackend do
    def workspace_backend?, do: true
    def valid_handle?(_handle), do: true
    def close(_handle), do: :ok

    def edit(handle, _request, _context) do
      send(handle.state, :crashing_edit_invoked)
      raise "synthetic edit backend failure"
    end
  end

  defmodule MalformedEditBackend do
    def workspace_backend?, do: true
    def valid_handle?(_handle), do: true
    def close(_handle), do: :ok

    def edit(handle, _request, _context) do
      send(handle.state, :malformed_edit_invoked)
      :malformed
    end
  end

  describe "argument preparation" do
    test "prepares exact literal text with mandatory canonical revision" do
      revision = revision(1)
      call = edit_call("file.txt", "old", "new", Revision.encode(revision))

      assert {:ok, request} = Edit.prepare(call, Limits.default())
      assert request.path == "file.txt"
      assert request.old_text == "old"
      assert request.new_text == "new"
      assert request.expected_revision == revision

      assert {:ok, deletion} =
               Edit.prepare(
                 edit_call("file.txt", "remove", "", Revision.encode(revision)),
                 Limits.default()
               )

      assert deletion.new_text == ""
    end

    test "permits equal old/new text but rejects empty old text and missing expectation" do
      revision = Revision.encode(revision(1))

      assert {:ok, request} =
               Edit.prepare(edit_call("file.txt", "same", "same", revision), Limits.default())

      assert request.old_text == request.new_text

      assert Edit.prepare(edit_call("file.txt", "", "new", revision), Limits.default()) ==
               {:error, :invalid_arguments}

      assert Edit.prepare(edit_call("file.txt", "old", "new", "missing"), Limits.default()) ==
               {:error, :invalid_arguments}
    end

    test "rejects fields, paths, malformed revisions, invalid UTF-8, and aggregate overflow" do
      %Call{} = valid = edit_call("file.txt", "old", "new", Revision.encode(revision(1)))

      invalid = [
        %{valid | arguments: Map.delete(valid.arguments, "new_text")},
        %{valid | arguments: Map.put(valid.arguments, "extra", true)},
        %{valid | arguments: %{valid.arguments | "path" => "../file.txt"}},
        %{valid | arguments: %{valid.arguments | "path" => "/file.txt"}},
        %{valid | arguments: %{valid.arguments | "path" => "bad\0path"}},
        %{valid | arguments: %{valid.arguments | "old_text" => 1}},
        %{valid | arguments: %{valid.arguments | "new_text" => 1}},
        %{valid | arguments: %{valid.arguments | "expected_revision" => "wsr1.invalid"}},
        %{valid | arguments: %{valid.arguments | "expected_revision" => 1}},
        %{valid | name: "write"},
        %Call{valid | arguments: %{valid.arguments | "old_text" => <<255>>}},
        %Call{valid | arguments: %{valid.arguments | "new_text" => <<255>>}}
      ]

      Enum.each(invalid, fn call ->
        assert Edit.prepare(call, Limits.default()) == {:error, :invalid_arguments}
      end)

      {:ok, limits} = Limits.new(max_path_bytes: 4)

      assert Edit.prepare(edit_call("12345", "old", "new", Revision.encode(revision(1))), limits) ==
               {:error, :invalid_arguments}
    end

    test "accepts the maximum canonical argument envelope and rejects one byte beyond" do
      limits = Limits.default()
      revision = Revision.encode(revision(1))
      maximum = largest_new_text_size(limits, revision)
      call = edit_call("file.txt", "a", String.duplicate("x", maximum), revision)

      assert {:ok, request} = Edit.prepare(call, limits)
      assert byte_size(request.new_text) == maximum

      forged = raw_edit_call("file.txt", "a", String.duplicate("x", maximum + 1), revision)
      assert Edit.prepare(forged, limits) == {:error, :invalid_arguments}
    end
  end

  describe "Fake Workspace adapter" do
    test "applies exactly one literal replacement through write-only dispatch" do
      previous = revision(1)
      current = revision(2)
      request = edit_request("file.txt", "old", "new", previous)
      operation_context = operation_context("edit-one")
      result = mutation_result("edit-one", "file.txt", previous, current, 3, true, "changed")
      handle = fake_handle([Fake.expect_edit(request, operation_context, {:ok, result})])

      presented =
        Executor.execute(
          edit_call("file.txt", "old", "new", Revision.encode(previous)),
          tool_context(handle, operation_id: "edit-one")
        )

      content = decode(presented)
      assert presented.status == :ok
      assert content["previous_revision"] == Revision.encode(previous)
      assert content["revision"] == Revision.encode(current)
      assert content["changed"] == true
      assert :ok = Fake.assert_finished(handle)
    end

    test "zero, multiple, overlapping, and stale classifications remain distinct" do
      previous = revision(1)
      request = edit_request("file.txt", "aa", "x", previous)

      cases = [
        {"edit-zero", :conflict, :no_match},
        {"edit-multiple", :conflict, :multiple_matches},
        {"edit-overlap", :conflict, :multiple_matches},
        {"edit-stale", :conflict, :stale_revision}
      ]

      entries =
        Enum.map(cases, fn {operation_id, kind, reason} ->
          context = operation_context(operation_id)
          error = workspace_error(kind, reason, :not_applied, operation_id)
          Fake.expect_edit(request, context, {:error, error})
        end)

      handle = fake_handle(entries)

      Enum.each(cases, fn {operation_id, _kind, reason} ->
        result =
          Executor.execute(
            edit_call("file.txt", "aa", "x", Revision.encode(previous)),
            tool_context(handle, operation_id: operation_id)
          )

        assert_result_reason(result, :error, Atom.to_string(reason))
        assert decode(result)["error"]["workspace_kind"] == "conflict"
      end)

      assert :ok = Fake.assert_finished(handle)
    end

    test "equal old/new exact-one replacement is a successful no-op" do
      revision = revision(1)
      request = edit_request("file.txt", "same", "same", revision)
      operation_context = operation_context("edit-noop")
      result = mutation_result("edit-noop", "file.txt", revision, revision, 0, false, "")
      handle = fake_handle([Fake.expect_edit(request, operation_context, {:ok, result})])

      presented =
        Executor.execute(
          edit_call("file.txt", "same", "same", Revision.encode(revision)),
          tool_context(handle, operation_id: "edit-noop")
        )

      content = decode(presented)
      assert content["changed"] == false
      assert content["bytes_written"] == 0
      assert content["previous_revision"] == content["revision"]
      assert :ok = Fake.assert_finished(handle)
    end

    test "empty replacement, generated limit, bounded diff, and both truncation layers survive" do
      previous = revision(1)
      current = revision(2)
      delete_request = edit_request("file.txt", "remove", "", previous)
      delete_context = operation_context("edit-delete")

      diff = String.duplicate("-remove\n", 1_000)

      deleted =
        mutation_result("edit-delete", "file.txt", previous, current, 0, true, diff, true)

      limit_request = edit_request("file.txt", "a", "1234567", current)
      limit_context = operation_context("edit-limit")
      limit_error = workspace_error(:limit, :file_too_large, :not_applied, "edit-limit")

      handle =
        fake_handle([
          Fake.expect_edit(delete_request, delete_context, {:ok, deleted}),
          Fake.expect_edit(limit_request, limit_context, {:error, limit_error})
        ])

      {:ok, limits} = Limits.new(max_result_content_bytes: 512)

      deletion =
        Executor.execute(
          edit_call("file.txt", "remove", "", Revision.encode(previous)),
          tool_context(handle, operation_id: "edit-delete", limits: limits)
        )

      content = decode(deletion)
      assert content["diff_truncated"] == true
      assert content["presentation_truncated"] == true

      limited =
        Executor.execute(
          edit_call("file.txt", "a", "1234567", Revision.encode(current)),
          tool_context(handle, operation_id: "edit-limit")
        )

      assert_result_reason(limited, :error, "file_too_large")
      assert :ok = Fake.assert_finished(handle)
    end

    test "invalid arguments and denied capabilities consume no Workspace entry" do
      revision = revision(1)
      request = edit_request("file.txt", "old", "new", revision)
      operation_context = operation_context("edit-rejected")

      result =
        mutation_result("edit-rejected", "file.txt", revision, revision(2), 3, true, "changed")

      handle = fake_handle([Fake.expect_edit(request, operation_context, {:ok, result})])

      invalid =
        Executor.execute(
          edit_call("file.txt", "", "new", Revision.encode(revision)),
          tool_context(handle)
        )

      assert_result_reason(invalid, :error, "invalid_arguments")

      denied =
        Executor.execute(
          edit_call("file.txt", "old", "new", Revision.encode(revision)),
          tool_context(handle, capabilities: capabilities(read: true, write: false, exec: true))
        )

      assert_result_reason(denied, :error, "capability_denied")
      assert {:ok, 1} = Fake.remaining_operations(handle)
    end

    test "Workspace access denial remains defense in depth" do
      handle = fake_handle([], access: %Access{read: true, write: false, exec: false})

      result =
        Executor.execute(
          edit_call("file.txt", "old", "new", Revision.encode(revision(1))),
          tool_context(handle)
        )

      assert_result_reason(result, :error, "access_denied")
      assert :ok = Fake.assert_finished(handle)
    end

    test "unknown outcome remains ambiguous and is not replayed" do
      revision = revision(1)
      request = edit_request("file.txt", "old", "new", revision)
      context = operation_context("edit-ambiguous")
      error = workspace_error(:ambiguous, :backend_unavailable, :unknown, "edit-ambiguous")

      handle =
        fake_handle([
          Fake.expect_edit(request, context, {:error, error}),
          Fake.expect_edit(request, context, {:error, error})
        ])

      result =
        Executor.execute(
          edit_call("file.txt", "old", "new", Revision.encode(revision)),
          tool_context(handle, operation_id: "edit-ambiguous")
        )

      assert_result_reason(result, :ambiguous, "backend_unavailable")
      assert decode(result)["error"]["message"] =~ "do not retry blindly"
      assert {:ok, 1} = Fake.remaining_operations(handle)
    end

    test "crashing or malformed central Edit dispatch is ambiguous and invoked once" do
      cases = [
        {CrashingEditBackend, :crashing_edit_invoked},
        {MalformedEditBackend, :malformed_edit_invoked}
      ]

      Enum.each(cases, fn {backend, message} ->
        result =
          Executor.execute(
            edit_call("file.txt", "old", "new", Revision.encode(revision(1))),
            tool_context(backend_handle(backend), operation_id: "edit-backend-failure")
          )

        assert result.status == :ambiguous
        assert decode(result)["error"]["outcome"] == "unknown"
        assert_receive ^message
        refute_receive ^message
      end)
    end

    test "presentation pressure preserves successful, not-applied, and unknown outcomes" do
      path = String.duplicate("p", 1_000)
      previous = revision(1)
      current = revision(2)
      request = edit_request(path, "old", "new", previous)

      success =
        mutation_result("edit-present-success", path, previous, current, 3, true, "changed")

      stale =
        workspace_error(
          :conflict,
          :stale_revision,
          :not_applied,
          "edit-present-error",
          path
        )

      unknown =
        workspace_error(
          :ambiguous,
          :backend_unavailable,
          :unknown,
          "edit-present-ambiguous",
          path
        )

      handle =
        fake_handle([
          Fake.expect_edit(
            request,
            operation_context("edit-present-success"),
            {:ok, success}
          ),
          Fake.expect_edit(
            request,
            operation_context("edit-present-error"),
            {:error, stale}
          ),
          Fake.expect_edit(
            request,
            operation_context("edit-present-ambiguous"),
            {:error, unknown}
          )
        ])

      {:ok, limits} = Limits.new(max_result_content_bytes: 256)

      execute = fn operation_id ->
        Executor.execute(
          edit_call(path, "old", "new", Revision.encode(previous)),
          tool_context(handle, operation_id: operation_id, limits: limits)
        )
      end

      successful = execute.("edit-present-success")
      failed = execute.("edit-present-error")
      ambiguous = execute.("edit-present-ambiguous")

      assert successful.status == :ok
      assert decode(successful)["presentation"] == "unavailable"
      assert_result_reason(failed, :error, "presentation_failed")
      assert_result_reason(ambiguous, :ambiguous, "presentation_failed")
      assert :ok = Fake.assert_finished(handle)
    end
  end

  describe "Real Workspace integration" do
    @describetag skip: not Platform.supported?()

    test "read-edit-read round trip returns a revision usable by a later edit" do
      in_temporary_directory(fn root ->
        File.write!(Elixir.Path.join(root, "file.txt"), "hello world")
        handle = real_handle(root)

        try do
          first =
            Executor.execute(
              read_call("file.txt"),
              tool_context(handle, operation_id: "edit-read-1")
            )

          first_revision = decode(first)["revision"]

          edited =
            Executor.execute(
              edit_call("file.txt", "world", "beam", first_revision),
              tool_context(handle, operation_id: "edit-real-1")
            )

          edited_content = decode(edited)
          assert edited.status == :ok
          assert edited_content["changed"] == true
          assert File.read!(Elixir.Path.join(root, "file.txt")) == "hello beam"

          second =
            Executor.execute(
              read_call("file.txt"),
              tool_context(handle, operation_id: "edit-read-2")
            )

          assert decode(second)["revision"] == edited_content["revision"]

          edited_again =
            Executor.execute(
              edit_call("file.txt", "hello", "hi", edited_content["revision"]),
              tool_context(handle, operation_id: "edit-real-2")
            )

          assert edited_again.status == :ok
          assert File.read!(Elixir.Path.join(root, "file.txt")) == "hi beam"
        after
          Workspace.close(handle)
        end
      end)
    end

    test "zero, multiple, and overlapping matches leave content unchanged" do
      in_temporary_directory(fn root ->
        files = %{"zero.txt" => "abc", "many.txt" => "a a", "overlap.txt" => "aaa"}

        Enum.each(files, fn {path, content} ->
          File.write!(Elixir.Path.join(root, path), content)
        end)

        handle = real_handle(root)

        try do
          cases = [
            {"zero.txt", "missing", "x", "no_match"},
            {"many.txt", "a", "x", "multiple_matches"},
            {"overlap.txt", "aa", "x", "multiple_matches"}
          ]

          Enum.with_index(cases, 1)
          |> Enum.each(fn {{path, old_text, new_text, reason}, index} ->
            read =
              Executor.execute(
                read_call(path),
                tool_context(handle, operation_id: "edit-match-read-#{index}")
              )

            revision = decode(read)["revision"]

            result =
              Executor.execute(
                edit_call(path, old_text, new_text, revision),
                tool_context(handle, operation_id: "edit-match-#{index}")
              )

            assert_result_reason(result, :error, reason)
            assert File.read!(Elixir.Path.join(root, path)) == files[path]
          end)
        after
          Workspace.close(handle)
        end
      end)
    end

    test "stale edit leaves newer content unchanged and equal old/new is a no-op" do
      in_temporary_directory(fn root ->
        path = Elixir.Path.join(root, "file.txt")
        File.write!(path, "one value")
        handle = real_handle(root)

        try do
          observed =
            Executor.execute(
              read_call("file.txt"),
              tool_context(handle, operation_id: "edit-stale-read")
            )

          revision = decode(observed)["revision"]

          File.write!(path, "newer value")

          stale =
            Executor.execute(
              edit_call("file.txt", "one", "changed", revision),
              tool_context(handle, operation_id: "edit-stale-real")
            )

          assert_result_reason(stale, :error, "stale_revision")
          assert File.read!(path) == "newer value"

          reread =
            Executor.execute(
              read_call("file.txt"),
              tool_context(handle, operation_id: "edit-noop-read")
            )

          current = decode(reread)["revision"]

          noop =
            Executor.execute(
              edit_call("file.txt", "newer", "newer", current),
              tool_context(handle, operation_id: "edit-noop-real")
            )

          assert noop.status == :ok
          assert decode(noop)["changed"] == false
          assert File.read!(path) == "newer value"
        after
          Workspace.close(handle)
        end
      end)
    end

    test "generated content above the Workspace ceiling is rejected without mutation" do
      in_temporary_directory(fn root ->
        path = Elixir.Path.join(root, "file.txt")
        File.write!(path, "abcde")
        {:ok, workspace_limits} = WorkspaceLimits.new(max_file_bytes: 10)
        handle = real_handle(root, workspace_limits)

        try do
          read =
            Executor.execute(
              read_call("file.txt"),
              tool_context(handle, operation_id: "edit-limit-read")
            )

          revision = decode(read)["revision"]

          result =
            Executor.execute(
              edit_call("file.txt", "a", "1234567", revision),
              tool_context(handle, operation_id: "edit-generated-limit")
            )

          assert_result_reason(result, :error, "file_too_large")
          assert File.read!(path) == "abcde"
        after
          Workspace.close(handle)
        end
      end)
    end

    test "Edit source has no direct host or Workspace dispatch API" do
      source = File.read!("lib/synapse/tool/edit.ex")

      refute source =~ ~r/\bFile\./
      refute source =~ ~r/\bSystem\./
      refute source =~ ~r/\bPort\./
      refute source =~ ~r/:file\./
      refute source =~ "Workspace.edit"
    end
  end

  defp edit_call(path, old_text, new_text, expected_revision) do
    {:ok, call} =
      Call.new(Map.from_struct(raw_edit_call(path, old_text, new_text, expected_revision)))

    call
  end

  defp raw_edit_call(path, old_text, new_text, expected_revision) do
    %Call{
      call_id: "call-edit",
      name: "edit",
      arguments: %{
        "path" => path,
        "old_text" => old_text,
        "new_text" => new_text,
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
      |> Keyword.put_new(:operation_id, "tool-edit-operation")
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

  defp edit_request(path, old_text, new_text, revision) do
    {:ok, request} =
      EditRequest.new(
        path: path,
        old_text: old_text,
        new_text: new_text,
        expected_revision: revision
      )

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
        operation: :edit,
        message: "Workspace edit failed",
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

  defp largest_new_text_size(limits, revision),
    do: largest_new_text_size(0, limits.max_argument_json_bytes, limits, revision)

  defp largest_new_text_size(low, high, _limits, _revision) when low == high, do: low

  defp largest_new_text_size(low, high, limits, revision) do
    middle = div(low + high + 1, 2)
    call = raw_edit_call("file.txt", "a", String.duplicate("x", middle), revision)

    case Call.new(Map.from_struct(call), limits) do
      {:ok, _call} -> largest_new_text_size(middle, high, limits, revision)
      {:error, _reason} -> largest_new_text_size(low, middle - 1, limits, revision)
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
        "synapse-tool-edit-#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}"
      )

    File.mkdir!(root)

    try do
      fun.(root)
    after
      File.rm_rf!(root)
    end
  end
end
