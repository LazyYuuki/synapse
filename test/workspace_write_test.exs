defmodule Synapse.Workspace.WriteTest do
  use ExUnit.Case, async: false

  alias Synapse.Workspace

  alias Synapse.Workspace.{
    Access,
    AtomicWriter,
    Diff,
    Error,
    Limits,
    MutationResult,
    MutationServer,
    OpenRequest,
    OperationContext,
    Platform,
    ReadRequest,
    ReadResult,
    Revision,
    Root,
    WriteRequest
  }

  @moduletag skip: not Platform.supported?()

  test "creates a complete file with a revision, bounded diff, and process umask mode" do
    in_temporary_directory(fn root ->
      baseline_path = Elixir.Path.join(root, "baseline.txt")
      target_path = Elixir.Path.join(root, "new.txt")
      File.write!(baseline_path, "baseline")
      baseline_mode = permission_mode(baseline_path)
      handle = open_workspace(root)

      assert {:ok,
              %MutationResult{
                operation_id: "create",
                path: "new.txt",
                previous_revision: :missing,
                bytes_written: 3,
                changed: true,
                diff_truncated: false,
                revision: %Revision{} = revision
              } = result} = write(handle, "new.txt", "new", :missing, "create")

      assert result.diff ==
               "--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1,1 @@\n+new\n\\ No newline at end of file\n"

      assert File.read!(target_path) == "new"
      assert permission_mode(target_path) == baseline_mode
      assert stage_names(root) == []

      assert {:ok, %ReadResult{revision: ^revision}} = read(handle, "new.txt")
      assert :ok = Workspace.close(handle)
    end)
  end

  test "replaces only the observed revision and preserves permission bits" do
    in_temporary_directory(fn root ->
      target_path = Elixir.Path.join(root, "file.txt")
      File.write!(target_path, "old")
      File.chmod!(target_path, 0o640)
      handle = open_workspace(root)
      old_revision = read_revision(handle, "file.txt")

      assert {:ok,
              %MutationResult{
                previous_revision: ^old_revision,
                revision: %Revision{} = new_revision,
                bytes_written: 3,
                changed: true
              }} = write(handle, "file.txt", "new", old_revision, "replace")

      refute new_revision == old_revision
      assert File.read!(target_path) == "new"
      assert permission_mode(target_path) == 0o640
      assert stage_names(root) == []
      assert read_revision(handle, "file.txt") == new_revision

      assert {:error, %Error{kind: :conflict, reason: :stale_revision, outcome: :not_applied}} =
               write(handle, "file.txt", "stale", old_revision, "stale")

      assert File.read!(target_path) == "new"

      assert {:error, %Error{kind: :conflict, reason: :expected_missing, outcome: :not_applied}} =
               write(handle, "file.txt", "blind", :missing, "already-exists")

      assert File.read!(target_path) == "new"
      assert :ok = Workspace.close(handle)
    end)
  end

  test "rejects revisions from another path or handle and revalidates request bounds" do
    in_temporary_directory(fn root ->
      File.write!(Elixir.Path.join(root, "a.txt"), "same")
      File.write!(Elixir.Path.join(root, "b.txt"), "same")
      first = open_workspace(root)
      second = open_workspace(root)
      a_revision = read_revision(first, "a.txt")
      other_handle_revision = read_revision(second, "a.txt")

      assert {:error, %Error{reason: :stale_revision, outcome: :not_applied}} =
               write(first, "b.txt", "changed", a_revision, "wrong-path")

      assert {:error, %Error{reason: :stale_revision, outcome: :not_applied}} =
               write(first, "a.txt", "changed", other_handle_revision, "wrong-handle")

      malformed = %WriteRequest{
        path: "a.txt",
        content: "changed",
        expected_revision: %Revision{encoded: "invalid"}
      }

      assert {:error, %Error{kind: :invalid, reason: :invalid_request}} =
               Workspace.write(first, malformed, context("malformed"))

      {:ok, small_limits} = Limits.new(max_file_bytes: 4)
      small = open_workspace(root, small_limits)
      oversized = write_request("too-large.txt", "12345", :missing)

      assert {:error, %Error{kind: :invalid, reason: :invalid_request}} =
               Workspace.write(small, oversized, context("oversized"))

      refute File.exists?(Elixir.Path.join(root, "too-large.txt"))
      assert File.read!(Elixir.Path.join(root, "a.txt")) == "same"
      assert File.read!(Elixir.Path.join(root, "b.txt")) == "same"
      Enum.each([first, second, small], &Workspace.close/1)
    end)
  end

  test "returns a no-op without replacing the file" do
    in_temporary_directory(fn root ->
      target_path = Elixir.Path.join(root, "same.txt")
      File.write!(target_path, "unchanged")
      handle = open_workspace(root)
      revision = read_revision(handle, "same.txt")
      before_stat = File.stat!(target_path)

      assert {:ok,
              %MutationResult{
                previous_revision: ^revision,
                revision: ^revision,
                bytes_written: 0,
                changed: false,
                diff: "",
                diff_truncated: false
              }} = write(handle, "same.txt", "unchanged", revision, "no-op")

      after_stat = File.stat!(target_path)
      assert after_stat.inode == before_stat.inode
      assert after_stat.mtime == before_stat.mtime
      assert stage_names(root) == []
      assert :ok = Workspace.close(handle)
    end)
  end

  test "truncates mutation diffs on a valid UTF-8 boundary" do
    in_temporary_directory(fn root ->
      File.write!(Elixir.Path.join(root, "unicode.txt"), "old")
      {:ok, limits} = Limits.new(max_diff_bytes: 47)
      handle = open_workspace(root, limits)
      revision = read_revision(handle, "unicode.txt")
      content = String.duplicate("😀", 20)

      assert {:ok, %MutationResult{diff: diff, diff_truncated: true}} =
               write(handle, "unicode.txt", content, revision, "bounded-diff")

      assert byte_size(diff) <= limits.max_diff_bytes
      assert String.valid?(diff)
      assert File.read!(Elixir.Path.join(root, "unicode.txt")) == content
      assert :ok = Workspace.close(handle)
    end)
  end

  test "builds valid multiline whole-file hunks with bounded allocation" do
    assert {diff, false} =
             Diff.build("one\ntwo\n", "one\nthree\n", "file.txt", 1_024, :existing)

    assert diff ==
             "--- a/file.txt\n+++ b/file.txt\n@@ -1,2 +1,2 @@\n-one\n-two\n+one\n+three\n"

    newline_heavy = String.duplicate("\n", 100_000)

    assert {bounded, true} =
             Diff.build(newline_heavy, newline_heavy <> "x", "file.txt", 64, :existing)

    assert byte_size(bounded) <= 64
    assert String.valid?(bounded)
  end

  test "supports empty and exact-limit content while rejecting forged owner requests" do
    in_temporary_directory(fn root ->
      {:ok, limits} = Limits.new(max_file_bytes: 4)
      handle = open_workspace(root, limits)

      assert {:ok, %MutationResult{bytes_written: 0}} =
               write(handle, "empty.txt", "", :missing, "empty")

      assert {:ok, %MutationResult{bytes_written: 4}} =
               write(handle, "maximum.txt", "1234", :missing, "maximum")

      assert {:ok, lease} =
               MutationServer.acquire(handle.state, handle.token, "forged", :write)

      oversized = %WriteRequest{
        path: "oversized.txt",
        content: "12345",
        expected_revision: :missing
      }

      invalid_utf8 = %WriteRequest{
        path: "invalid.txt",
        content: <<255>>,
        expected_revision: :missing
      }

      assert {:error, :invalid_request, :not_applied} =
               MutationServer.write(lease, oversized, "forged")

      assert {:error, :invalid_request, :not_applied} =
               MutationServer.write(lease, invalid_utf8, "forged")

      assert :ok = MutationServer.release(lease)
      refute File.exists?(Elixir.Path.join(root, "oversized.txt"))
      refute File.exists?(Elixir.Path.join(root, "invalid.txt"))
      assert stage_names(root) == []
      assert :ok = Workspace.close(handle)
    end)
  end

  test "cleans every pre-commit fault and classifies failed confirmation as ambiguous" do
    in_temporary_directory(fn root_path ->
      limits = Limits.default()
      {:ok, root} = Root.open(root_path, limits)
      key = :crypto.strong_rand_bytes(32)

      for fault <- [
            :before_stage,
            :stage_open,
            :stage_stat,
            :private_mode,
            :during_write,
            :stage_written,
            :apply_mode,
            :verify_stage,
            :validation,
            :sync,
            :stage_close,
            :before_recheck,
            :before_commit,
            :commit
          ] do
        relative = "#{fault}.txt"
        request = write_request(relative, String.duplicate("complete", 100), :missing)

        assert {:error, reason, :not_applied} =
                 AtomicWriter.write(root, key, limits, request, "fault-#{fault}", fail_at: fault)

        if fault == :commit,
          do: assert(reason == :atomic_commit_failed),
          else: assert(reason == :io)

        refute File.exists?(Elixir.Path.join(root_path, relative))
        assert stage_names(root_path) == []
      end

      request = write_request("confirmation.txt", "complete", :missing)

      assert {:error, :durability_unknown, :unknown} =
               AtomicWriter.write(root, key, limits, request, "confirmation",
                 fail_at: :confirmation
               )

      assert File.read!(Elixir.Path.join(root_path, "confirmation.txt")) == "complete"
      assert stage_names(root_path) == []

      after_commit = write_request("after-commit.txt", "complete", :missing)

      assert {:error, :durability_unknown, :unknown} =
               AtomicWriter.write(root, key, limits, after_commit, "after-commit",
                 fail_at: :after_commit
               )

      assert File.read!(Elixir.Path.join(root_path, "after-commit.txt")) == "complete"
      assert stage_names(root_path) == []

      unlink = write_request("creation-unlink.txt", "complete", :missing)

      assert {:error, :durability_unknown, :unknown} =
               AtomicWriter.write(root, key, limits, unlink, "creation-unlink",
                 fail_at: :creation_unlink
               )

      assert File.read!(Elixir.Path.join(root_path, "creation-unlink.txt")) == "complete"
      assert stage_names(root_path) == []

      cleanup = write_request("cleanup-failure.txt", "complete", :missing)

      assert {:error, :durability_unknown, :unknown} =
               AtomicWriter.write(root, key, limits, cleanup, "cleanup-failure",
                 fail_at: :before_commit,
                 fail_cleanup: true
               )

      refute File.exists?(Elixir.Path.join(root_path, "cleanup-failure.txt"))
      assert stage_names(root_path) == []

      raised = write_request("raised.txt", "complete", :missing)

      assert {:error, :io, :not_applied} =
               AtomicWriter.write(root, key, limits, raised, "raised", raise_at: :stage_written)

      refute File.exists?(Elixir.Path.join(root_path, "raised.txt"))
      assert stage_names(root_path) == []
    end)
  end

  test "keeps staged replacement content owner-only until it is complete" do
    in_temporary_directory(fn root ->
      target_path = Elixir.Path.join(root, "file.txt")
      File.write!(target_path, "old")
      File.chmod!(target_path, 0o644)
      handle = open_workspace(root)

      request =
        write_request(
          "file.txt",
          String.duplicate("new", 1_000),
          read_revision(handle, "file.txt")
        )

      owner = self()

      spawn_link(fn ->
        {:ok, lease} = MutationServer.acquire(handle.state, handle.token, "stage-mode", :write)

        result =
          MutationServer.write(lease, request, "stage-mode",
            test_control: {:stage_written, owner}
          )

        send(owner, {:stage_mode_result, result, MutationServer.release(lease)})
      end)

      assert_receive {:atomic_writer_checkpoint, :stage_written, server, checkpoint}, 5_000
      assert [stage_name] = stage_names(root)
      assert permission_mode(Elixir.Path.join(root, stage_name)) == 0o600
      assert File.read!(target_path) == "old"
      send(server, {:continue_atomic_writer, checkpoint})
      assert_receive {:stage_mode_result, {:ok, %MutationResult{}}, :ok}, 5_000
      assert permission_mode(target_path) == 0o644
      assert stage_names(root) == []
      assert :ok = Workspace.close(handle)
    end)
  end

  test "a failed staged replacement preserves the original bytes and mode" do
    in_temporary_directory(fn root ->
      target_path = Elixir.Path.join(root, "file.txt")
      File.write!(target_path, "original")
      File.chmod!(target_path, 0o600)
      handle = open_workspace(root)
      revision = read_revision(handle, "file.txt")
      request = write_request("file.txt", String.duplicate("replacement", 100), revision)

      assert {:ok, lease} =
               MutationServer.acquire(handle.state, handle.token, "failed-replacement", :write)

      assert {:error, :io, :not_applied} =
               MutationServer.write(lease, request, "failed-replacement", fail_at: :during_write)

      assert :ok = MutationServer.release(lease)
      assert File.read!(target_path) == "original"
      assert permission_mode(target_path) == 0o600
      assert stage_names(root) == []
      assert :ok = Workspace.close(handle)
    end)
  end

  test "observers see only the old or complete new file during replacement" do
    in_temporary_directory(fn root ->
      old_content = String.duplicate("old-line\n", 20_000)
      new_content = String.duplicate("new-line\n", 20_000)
      target_path = Elixir.Path.join(root, "file.txt")
      File.write!(target_path, old_content)
      handle = open_workspace(root)
      revision = read_revision(handle, "file.txt")
      request = write_request("file.txt", new_content, revision)
      owner = self()

      observer =
        spawn_link(fn -> observe_file(target_path, old_content, new_content, owner, false) end)

      writer =
        spawn_link(fn ->
          {:ok, lease} =
            MutationServer.acquire(handle.state, handle.token, "atomic-visibility", :write)

          result =
            MutationServer.write(lease, request, "atomic-visibility",
              test_control: {:before_commit, owner}
            )

          send(owner, {:writer_result, result, MutationServer.release(lease)})
        end)

      assert_receive {:atomic_writer_checkpoint, :before_commit, worker, checkpoint}, 5_000
      refute worker == handle.state
      assert Process.alive?(writer)
      assert File.read!(target_path) == old_content
      send(worker, {:continue_atomic_writer, checkpoint})

      assert_receive {:writer_result, {:ok, %MutationResult{}}, :ok}, 5_000
      assert_receive :observer_saw_complete_new, 5_000
      refute_receive {:observer_saw_partial, _bytes}
      refute_receive {:observer_saw_error, _reason}
      send(observer, {:stop, self()})
      assert_receive :observer_stopped
      assert stage_names(root) == []
      assert :ok = Workspace.close(handle)
    end)
  end

  test "the final revision recheck rejects a cooperative external race" do
    in_temporary_directory(fn root ->
      target_path = Elixir.Path.join(root, "file.txt")
      File.write!(target_path, "observed")
      handle = open_workspace(root)
      revision = read_revision(handle, "file.txt")
      request = write_request("file.txt", "requested", revision)
      owner = self()

      spawn_link(fn ->
        {:ok, lease} = MutationServer.acquire(handle.state, handle.token, "race", :write)

        result =
          MutationServer.write(lease, request, "race", test_control: {:before_recheck, owner})

        send(owner, {:race_result, result, MutationServer.release(lease)})
      end)

      assert_receive {:atomic_writer_checkpoint, :before_recheck, server, checkpoint}, 5_000
      File.write!(target_path, "external")
      send(server, {:continue_atomic_writer, checkpoint})

      assert_receive {:race_result, {:error, :stale_revision, :not_applied}, :ok}, 5_000
      assert File.read!(target_path) == "external"
      assert stage_names(root) == []
      assert :ok = Workspace.close(handle)
    end)
  end

  test "creation never overwrites a file that appears in the final commit window" do
    in_temporary_directory(fn root ->
      target_path = Elixir.Path.join(root, "new.txt")
      handle = open_workspace(root)
      request = write_request("new.txt", "requested", :missing)
      owner = self()

      spawn_link(fn ->
        {:ok, lease} = MutationServer.acquire(handle.state, handle.token, "create-race", :write)

        result =
          MutationServer.write(lease, request, "create-race",
            test_control: {:before_commit, owner}
          )

        send(owner, {:create_race_result, result, MutationServer.release(lease)})
      end)

      assert_receive {:atomic_writer_checkpoint, :before_commit, server, checkpoint}, 5_000
      File.write!(target_path, "external")
      send(server, {:continue_atomic_writer, checkpoint})

      assert_receive {:create_race_result, {:error, :expected_missing, :not_applied}, :ok}, 5_000
      assert File.read!(target_path) == "external"
      assert stage_names(root) == []
      assert :ok = Workspace.close(handle)
    end)
  end

  test "documents the cooperative replacement race after the final recheck" do
    in_temporary_directory(fn root ->
      target_path = Elixir.Path.join(root, "file.txt")
      File.write!(target_path, "observed")
      handle = open_workspace(root)
      request = write_request("file.txt", "requested", read_revision(handle, "file.txt"))
      owner = self()

      spawn_link(fn ->
        {:ok, lease} = MutationServer.acquire(handle.state, handle.token, "commit-window", :write)

        result =
          MutationServer.write(lease, request, "commit-window",
            test_control: {:before_commit, owner}
          )

        send(owner, {:commit_window_result, result, MutationServer.release(lease)})
      end)

      assert_receive {:atomic_writer_checkpoint, :before_commit, server, checkpoint}, 5_000
      File.write!(target_path, "external-after-recheck")
      send(server, {:continue_atomic_writer, checkpoint})

      assert_receive {:commit_window_result, {:ok, %MutationResult{}}, :ok}, 5_000
      assert File.read!(target_path) == "requested"
      assert stage_names(root) == []
      assert :ok = Workspace.close(handle)
    end)
  end

  test "server death after publication is ambiguous and the guard removes the linked stage" do
    in_temporary_directory(fn root ->
      target_path = Elixir.Path.join(root, "committed.txt")
      handle = open_workspace(root)
      request = write_request("committed.txt", "complete", :missing)
      owner = self()
      server_monitor = Process.monitor(handle.state)

      spawn_link(fn ->
        {:ok, lease} = MutationServer.acquire(handle.state, handle.token, "server-death", :write)

        result =
          MutationServer.write(lease, request, "server-death",
            test_control: {:after_commit, owner}
          )

        send(owner, {:server_death_result, result})
      end)

      assert_receive {:atomic_writer_checkpoint, :after_commit, _worker, _checkpoint}, 5_000
      assert length(stage_names(root)) == 1
      mutation_server = handle.state
      Process.exit(mutation_server, :kill)
      assert_receive {:DOWN, ^server_monitor, :process, ^mutation_server, :killed}, 5_000
      assert_receive {:server_death_result, {:error, :durability_unknown, :unknown}}, 5_000
      assert File.read!(target_path) == "complete"
      assert eventually(fn -> stage_names(root) == [] end)
      assert :ok = Workspace.close(handle)
    end)
  end

  test "server death before publication preserves the original and the guard removes the stage" do
    in_temporary_directory(fn root ->
      target_path = Elixir.Path.join(root, "file.txt")
      File.write!(target_path, "original")
      handle = open_workspace(root)
      request = write_request("file.txt", "replacement", read_revision(handle, "file.txt"))
      owner = self()
      server_monitor = Process.monitor(handle.state)

      spawn_link(fn ->
        {:ok, lease} =
          MutationServer.acquire(handle.state, handle.token, "precommit-death", :write)

        result =
          MutationServer.write(lease, request, "precommit-death",
            test_control: {:before_commit, owner}
          )

        send(owner, {:precommit_death_result, result})
      end)

      assert_receive {:atomic_writer_checkpoint, :before_commit, _worker, _checkpoint}, 5_000
      assert length(stage_names(root)) == 1
      mutation_server = handle.state
      Process.exit(mutation_server, :kill)
      assert_receive {:DOWN, ^server_monitor, :process, ^mutation_server, :killed}, 5_000
      assert_receive {:precommit_death_result, {:error, :durability_unknown, :unknown}}, 5_000
      assert File.read!(target_path) == "original"
      assert eventually(fn -> stage_names(root) == [] end)
      assert :ok = Workspace.close(handle)
    end)
  end

  test "cancellation after admission does not abandon the atomic write" do
    in_temporary_directory(fn root ->
      handle = open_workspace(root)
      cancel_ref = make_ref()
      operation_context = context("accepted", cancel_ref: cancel_ref)

      assert {:ok, lease} =
               MutationServer.acquire(
                 handle.state,
                 handle.token,
                 "accepted",
                 :write,
                 operation_context
               )

      send(self(), {:cancel, cancel_ref})
      request = write_request("accepted.txt", "complete", :missing)

      assert {:ok, %MutationResult{changed: true}} =
               MutationServer.write(lease, request, "accepted")

      assert :ok = MutationServer.release(lease)
      assert_receive {:cancel, ^cancel_ref}
      assert File.read!(Elixir.Path.join(root, "accepted.txt")) == "complete"

      deadline_context =
        context("deadline-accepted", deadline: System.monotonic_time(:millisecond) + 50)

      assert {:ok, deadline_lease} =
               MutationServer.acquire(
                 handle.state,
                 handle.token,
                 "deadline-accepted",
                 :write,
                 deadline_context
               )

      Process.sleep(60)
      deadline_request = write_request("deadline.txt", "complete", :missing)

      assert {:ok, %MutationResult{changed: true}} =
               MutationServer.write(deadline_lease, deadline_request, "deadline-accepted")

      assert :ok = MutationServer.release(deadline_lease)
      assert File.read!(Elixir.Path.join(root, "deadline.txt")) == "complete"
      assert :ok = Workspace.close(handle)
    end)
  end

  test "reports one activity after commit and makes activity failure ambiguous" do
    in_temporary_directory(fn root ->
      handle = open_workspace(root)
      owner = self()

      successful_sink = fn operation_context ->
        send(owner, {:mutation_activity, operation_context.operation_id})
        :ok
      end

      assert {:ok, %MutationResult{}} =
               write(handle, "first.txt", "first", :missing, "activity",
                 activity_sink: successful_sink
               )

      assert_receive {:mutation_activity, "activity"}
      refute_receive {:mutation_activity, _operation_id}

      failing_sink = fn operation_context ->
        send(owner, {:failed_activity, operation_context.operation_id})
        :invalid
      end

      assert {:error,
              %Error{
                kind: :ambiguous,
                reason: :mutation_activity_failed,
                outcome: :unknown
              }} =
               write(handle, "second.txt", "second", :missing, "activity-failed",
                 activity_sink: failing_sink
               )

      assert_receive {:failed_activity, "activity-failed"}
      assert File.read!(Elixir.Path.join(root, "second.txt")) == "second"

      stale_sink = fn _operation_context ->
        send(owner, :unexpected_stale_activity)
        :ok
      end

      assert {:error, %Error{reason: :expected_missing}} =
               write(handle, "second.txt", "other", :missing, "no-activity",
                 activity_sink: stale_sink
               )

      refute_receive :unexpected_stale_activity

      revision = read_revision(handle, "first.txt")

      assert {:error,
              %Error{
                kind: :unavailable,
                reason: :activity_sink_failed,
                outcome: :not_applied
              }} =
               write(handle, "first.txt", "first", revision, "no-op-activity-failed",
                 activity_sink: fn _operation_context -> :invalid end
               )

      assert File.read!(Elixir.Path.join(root, "first.txt")) == "first"
      assert :ok = Workspace.close(handle)
    end)
  end

  test "many writers from one revision produce one commit and stale known losers" do
    in_temporary_directory(fn root ->
      File.write!(Elixir.Path.join(root, "contended.txt"), "base")
      handle = open_workspace(root)
      revision = read_revision(handle, "contended.txt")

      tasks =
        for index <- 1..12 do
          Task.async(fn ->
            receive do
              :start_contended_write -> :ok
            end

            request = write_request("contended.txt", "winner-#{index}", revision)
            retry_busy_write(handle, request, context("contended-#{index}"), 200)
          end)
        end

      Enum.each(tasks, &send(&1.pid, :start_contended_write))
      results = Enum.map(tasks, &Task.await(&1, 5_000))

      assert Enum.count(results, &match?({:ok, %MutationResult{}}, &1)) == 1

      assert Enum.count(results, fn
               {:error, %Error{reason: :stale_revision, outcome: :not_applied}} -> true
               _result -> false
             end) == 11

      assert File.read!(Elixir.Path.join(root, "contended.txt")) =~ "winner-"
      assert stage_names(root) == []

      assert {:ok, lease} =
               MutationServer.acquire(handle.state, handle.token, "after-contention", :write)

      assert :ok = MutationServer.release(lease)
      assert :ok = Workspace.close(handle)
    end)
  end

  defp write(handle, path, content, expectation, operation_id, context_options \\ []) do
    Workspace.write(
      handle,
      write_request(path, content, expectation),
      context(operation_id, context_options)
    )
  end

  defp retry_busy_write(_handle, _request, _context, 0), do: flunk("writer stayed busy")

  defp retry_busy_write(handle, request, context, attempts) do
    case Workspace.write(handle, request, context) do
      {:error, %Error{reason: :workspace_busy}} ->
        Process.sleep(1)
        retry_busy_write(handle, request, context, attempts - 1)

      result ->
        result
    end
  end

  defp write_request(path, content, expectation) do
    {:ok, request} =
      WriteRequest.new(path: path, content: content, expected_revision: expectation)

    request
  end

  defp read(handle, path) do
    {:ok, request} = ReadRequest.new(path: path)
    Workspace.read(handle, request, context("read-#{path}"))
  end

  defp read_revision(handle, path) do
    {:ok, %ReadResult{revision: revision}} = read(handle, path)
    revision
  end

  defp context(operation_id, options \\ []) do
    {:ok, access} = Access.new(read: true, write: true, exec: true)

    options =
      options
      |> Keyword.put(:operation_id, operation_id)
      |> Keyword.put(:access, access)

    {:ok, operation_context} = OperationContext.new(options)
    operation_context
  end

  defp open_workspace(root, limits \\ Limits.default()) do
    {:ok, access} = Access.new(read: true, write: true, exec: true)
    {:ok, request} = OpenRequest.new(root: root, owner: self(), limits: limits, access: access)
    {:ok, handle} = Workspace.open(request)
    handle
  end

  defp observe_file(path, old_content, new_content, owner, saw_new?) do
    receive do
      {:stop, caller} ->
        send(caller, :observer_stopped)
    after
      0 ->
        next_saw_new? =
          case File.read(path) do
            {:ok, ^old_content} ->
              saw_new?

            {:ok, ^new_content} ->
              if not saw_new?, do: send(owner, :observer_saw_complete_new)
              true

            {:ok, other} ->
              send(owner, {:observer_saw_partial, byte_size(other)})
              saw_new?

            {:error, reason} ->
              send(owner, {:observer_saw_error, reason})
              saw_new?
          end

        Process.sleep(1)
        observe_file(path, old_content, new_content, owner, next_saw_new?)
    end
  end

  defp permission_mode(path), do: Bitwise.band(File.stat!(path).mode, 0o7777)

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp stage_names(root) do
    root
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, ".synapse-stage-"))
  end

  defp in_temporary_directory(fun) do
    root =
      Elixir.Path.join(
        System.tmp_dir!(),
        "synapse-workspace-write-#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}"
      )

    File.mkdir!(root)

    try do
      fun.(root)
    after
      File.rm_rf!(root)
    end
  end
end
