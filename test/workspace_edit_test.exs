defmodule Synapse.Workspace.EditTest do
  use ExUnit.Case, async: false

  alias Synapse.Workspace

  alias Synapse.Workspace.{
    Access,
    EditRequest,
    Error,
    Limits,
    MutationResult,
    MutationServer,
    OpenRequest,
    OperationContext,
    Platform,
    ReadRequest,
    ReadResult,
    Revision
  }

  @moduletag skip: not Platform.supported?()

  test "replaces exactly one byte sequence and returns revisions and a bounded diff" do
    in_temporary_directory(fn root ->
      path = Elixir.Path.join(root, "file.txt")
      File.write!(path, "before needle after\n")
      File.chmod!(path, 0o640)
      handle = open_workspace(root)
      previous = read_revision(handle, "file.txt")
      expected = "before replacement after\n"

      assert {:ok,
              %MutationResult{
                operation_id: "unique",
                path: "file.txt",
                previous_revision: ^previous,
                revision: %Revision{} = revision,
                bytes_written: bytes_written,
                changed: true,
                diff_truncated: false
              } = result} = edit(handle, "file.txt", "needle", "replacement", previous, "unique")

      assert bytes_written == byte_size(expected)
      refute revision == previous
      assert result.diff =~ "-before needle after"
      assert result.diff =~ "+before replacement after"
      assert File.read!(path) == expected
      assert permission_mode(path) == 0o640
      assert read_revision(handle, "file.txt") == revision
      assert stage_names(root) == []
      assert :ok = Workspace.close(handle)
    end)
  end

  test "rejects zero, repeated, and overlapping matches without staging" do
    in_temporary_directory(fn root ->
      fixtures = [
        {"zero.txt", "alpha beta", "missing", :no_match},
        {"repeated.txt", "target and target", "target", :multiple_matches},
        {"overlap.txt", "aaa", "aa", :multiple_matches}
      ]

      Enum.each(fixtures, fn {name, content, _old_text, _reason} ->
        File.write!(Elixir.Path.join(root, name), content)
      end)

      handle = open_workspace(root)

      for {name, content, old_text, reason} <- fixtures do
        revision = read_revision(handle, name)

        assert {:error, %Error{kind: :conflict, reason: ^reason, outcome: :not_applied}} =
                 edit(handle, name, old_text, "new", revision, "reject-#{name}")

        assert File.read!(Elixir.Path.join(root, name)) == content
        assert stage_names(root) == []
      end

      assert :ok = Workspace.close(handle)
    end)
  end

  test "proves exactly one match before returning a no-op" do
    in_temporary_directory(fn root ->
      unique_path = Elixir.Path.join(root, "unique.txt")
      repeated_path = Elixir.Path.join(root, "repeated.txt")
      File.write!(unique_path, "one target")
      File.write!(repeated_path, "target target")
      handle = open_workspace(root)
      unique_revision = read_revision(handle, "unique.txt")
      before_stat = File.stat!(unique_path)

      assert {:ok,
              %MutationResult{
                previous_revision: ^unique_revision,
                revision: ^unique_revision,
                bytes_written: 0,
                changed: false,
                diff: "",
                diff_truncated: false
              }} = edit(handle, "unique.txt", "target", "target", unique_revision, "no-op")

      after_stat = File.stat!(unique_path)
      assert after_stat.inode == before_stat.inode
      assert after_stat.mtime == before_stat.mtime

      repeated_revision = read_revision(handle, "repeated.txt")

      assert {:error, %Error{reason: :multiple_matches}} =
               edit(
                 handle,
                 "repeated.txt",
                 "target",
                 "target",
                 repeated_revision,
                 "ambiguous-no-op"
               )

      assert File.read!(repeated_path) == "target target"
      assert stage_names(root) == []
      assert :ok = Workspace.close(handle)
    end)
  end

  test "supports Unicode exact matching and deletion with empty replacement text" do
    in_temporary_directory(fn root ->
      path = Elixir.Path.join(root, "unicode.txt")
      File.write!(path, "héllo 世界")
      handle = open_workspace(root)
      revision = read_revision(handle, "unicode.txt")

      assert {:ok, %MutationResult{changed: true}} =
               edit(handle, "unicode.txt", "éllo ", "", revision, "unicode-delete")

      assert File.read!(path) == "h世界"
      assert :ok = Workspace.close(handle)
    end)
  end

  test "stale and scoped revision checks happen before match classification" do
    in_temporary_directory(fn root ->
      a_path = Elixir.Path.join(root, "a.txt")
      b_path = Elixir.Path.join(root, "b.txt")
      File.write!(a_path, "one target")
      File.write!(b_path, "same")
      first = open_workspace(root)
      second = open_workspace(root)
      stale = read_revision(first, "a.txt")
      wrong_path = read_revision(first, "b.txt")
      wrong_handle = read_revision(second, "a.txt")
      File.write!(a_path, "target target")

      for {revision, operation_id} <- [
            {stale, "stale"},
            {wrong_path, "wrong-path"},
            {wrong_handle, "wrong-handle"}
          ] do
        assert {:error, %Error{reason: :stale_revision, outcome: :not_applied}} =
                 edit(first, "a.txt", "missing", "new", revision, operation_id)
      end

      assert File.read!(a_path) == "target target"
      assert stage_names(root) == []
      assert :ok = Workspace.close(first)
      assert :ok = Workspace.close(second)
    end)
  end

  test "accepts an exact generated-size limit and rejects one byte over it" do
    in_temporary_directory(fn root ->
      path = Elixir.Path.join(root, "file.txt")
      File.write!(path, "1234")
      {:ok, limits} = Limits.new(max_file_bytes: 8)
      handle = open_workspace(root, limits)
      revision = read_revision(handle, "file.txt")

      assert {:ok, %MutationResult{bytes_written: 8}} =
               edit(handle, "file.txt", "2", "23456", revision, "exact-limit")

      assert File.read!(path) == "12345634"
      current = read_revision(handle, "file.txt")

      assert {:error, %Error{kind: :limit, reason: :file_too_large, outcome: :not_applied}} =
               edit(handle, "file.txt", "1", "12", current, "over-limit")

      assert File.read!(path) == "12345634"
      assert stage_names(root) == []
      assert :ok = Workspace.close(handle)
    end)
  end

  test "MutationServer revalidates forged edit requests before observing or staging" do
    in_temporary_directory(fn root ->
      path = Elixir.Path.join(root, "file.txt")
      File.write!(path, "target")
      {:ok, limits} = Limits.new(max_file_bytes: 8)
      handle = open_workspace(root, limits)
      revision = read_revision(handle, "file.txt")

      assert {:ok, lease} = MutationServer.acquire(handle.state, handle.token, "forged", :edit)

      forged = [
        %EditRequest{
          path: "file.txt",
          old_text: "",
          new_text: "new",
          expected_revision: revision
        },
        %EditRequest{
          path: "file.txt",
          old_text: "target",
          new_text: <<255>>,
          expected_revision: revision
        },
        %EditRequest{
          path: "file.txt",
          old_text: "target",
          new_text: "123456789",
          expected_revision: revision
        }
      ]

      Enum.each(forged, fn request ->
        assert {:error, :invalid_request, :not_applied} =
                 MutationServer.edit(lease, request, "forged")
      end)

      assert :ok = MutationServer.release(lease)
      assert File.read!(path) == "target"
      assert stage_names(root) == []
      assert :ok = Workspace.close(handle)
    end)
  end

  test "MutationServer enforces the handle write ceiling for direct edit admission" do
    in_temporary_directory(fn root ->
      File.write!(Elixir.Path.join(root, "file.txt"), "target")
      {:ok, access} = Access.new(read: true, write: false, exec: false)

      {:ok, open_request} =
        OpenRequest.new(root: root, owner: self(), access: access, limits: Limits.default())

      {:ok, handle} = Workspace.open(open_request)

      assert {:error, :invalid_request} =
               MutationServer.acquire(handle.state, handle.token, "forbidden-edit", :edit)

      assert :ok = Workspace.close(handle)
    end)
  end

  test "truncates edit diffs on a UTF-8 boundary" do
    in_temporary_directory(fn root ->
      path = Elixir.Path.join(root, "file.txt")
      File.write!(path, "START" <> String.duplicate("x", 100))
      {:ok, limits} = Limits.new(max_diff_bytes: 51)
      handle = open_workspace(root, limits)
      revision = read_revision(handle, "file.txt")

      assert {:ok, %MutationResult{diff: diff, diff_truncated: true}} =
               edit(
                 handle,
                 "file.txt",
                 "START",
                 String.duplicate("😀", 10),
                 revision,
                 "bounded-diff"
               )

      assert byte_size(diff) <= limits.max_diff_bytes
      assert String.valid?(diff)
      assert :ok = Workspace.close(handle)
    end)
  end

  test "injected staging failure and final recheck race preserve the authoritative file" do
    in_temporary_directory(fn root ->
      path = Elixir.Path.join(root, "file.txt")
      File.write!(path, "before target after")
      handle = open_workspace(root)
      revision = read_revision(handle, "file.txt")
      request = edit_request("file.txt", "target", "replacement", revision)

      assert {:ok, failed_lease} =
               MutationServer.acquire(handle.state, handle.token, "edit-fault", :edit)

      assert {:error, :io, :not_applied} =
               MutationServer.edit(failed_lease, request, "edit-fault", fail_at: :during_write)

      assert :ok = MutationServer.release(failed_lease)
      assert File.read!(path) == "before target after"
      assert stage_names(root) == []

      owner = self()

      spawn_link(fn ->
        {:ok, lease} = MutationServer.acquire(handle.state, handle.token, "edit-race", :edit)

        result =
          MutationServer.edit(lease, request, "edit-race", test_control: {:before_recheck, owner})

        send(owner, {:edit_race_result, result, MutationServer.release(lease)})
      end)

      assert_receive {:atomic_writer_checkpoint, :before_recheck, server, checkpoint}, 5_000
      File.write!(path, "external")
      send(server, {:continue_atomic_writer, checkpoint})
      assert_receive {:edit_race_result, {:error, :stale_revision, :not_applied}, :ok}, 5_000
      assert File.read!(path) == "external"
      assert stage_names(root) == []
      assert :ok = Workspace.close(handle)
    end)
  end

  test "MutationServer remains responsive to reads and contention while an edit is staging" do
    in_temporary_directory(fn root ->
      path = Elixir.Path.join(root, "file.txt")
      File.write!(path, "before target after")
      handle = open_workspace(root)
      revision = read_revision(handle, "file.txt")
      request = edit_request("file.txt", "target", "replacement", revision)
      owner = self()

      spawn_link(fn ->
        {:ok, lease} = MutationServer.acquire(handle.state, handle.token, "active-edit", :edit)

        result =
          MutationServer.edit(lease, request, "active-edit",
            test_control: {:before_commit, owner}
          )

        send(owner, {:active_edit_result, result, MutationServer.release(lease)})
      end)

      assert_receive {:atomic_writer_checkpoint, :before_commit, worker, checkpoint}, 5_000

      {:ok, read_request} = ReadRequest.new(path: "file.txt")

      assert {:ok, %ReadResult{lines: [line]}} =
               Workspace.read(handle, read_request, context("overlapping-read"))

      assert line.text == "before target after"

      assert {:error, %Error{reason: :workspace_busy, outcome: :not_applied}} =
               edit(handle, "file.txt", "target", "other", revision, "contended-edit")

      send(worker, {:continue_atomic_writer, checkpoint})
      assert_receive {:active_edit_result, {:ok, %MutationResult{}}, :ok}, 5_000
      assert File.read!(path) == "before replacement after"
      assert :ok = Workspace.close(handle)
    end)
  end

  test "close waits for an accepted edit to reach its terminal filesystem result" do
    in_temporary_directory(fn root ->
      path = Elixir.Path.join(root, "file.txt")
      File.write!(path, "before target after")
      handle = open_workspace(root)

      request =
        edit_request("file.txt", "target", "replacement", read_revision(handle, "file.txt"))

      owner = self()
      server_monitor = Process.monitor(handle.state)

      spawn_link(fn ->
        {:ok, lease} = MutationServer.acquire(handle.state, handle.token, "closing-edit", :edit)

        result =
          MutationServer.edit(lease, request, "closing-edit",
            test_control: {:before_commit, owner}
          )

        send(owner, {:closing_edit_result, result, MutationServer.release(lease)})
      end)

      assert_receive {:atomic_writer_checkpoint, :before_commit, worker, checkpoint}, 5_000

      spawn_link(fn -> send(owner, {:close_during_edit, Workspace.close(handle)}) end)
      refute_receive {:close_during_edit, _result}, 100
      send(worker, {:continue_atomic_writer, checkpoint})

      assert_receive {:closing_edit_result, {:ok, %MutationResult{}}, :ok},
                     5_000

      assert_receive {:close_during_edit, :ok}, 5_000
      assert_receive {:DOWN, ^server_monitor, :process, _, :normal}, 5_000
      assert File.read!(path) == "before replacement after"
    end)
  end

  test "mutation worker death is ambiguous, cleans its stage, and leaves the handle usable" do
    in_temporary_directory(fn root ->
      path = Elixir.Path.join(root, "file.txt")
      File.write!(path, "before target after")
      handle = open_workspace(root)

      request =
        edit_request("file.txt", "target", "replacement", read_revision(handle, "file.txt"))

      owner = self()

      spawn_link(fn ->
        {:ok, lease} = MutationServer.acquire(handle.state, handle.token, "worker-death", :edit)

        result =
          MutationServer.edit(lease, request, "worker-death",
            test_control: {:before_commit, owner}
          )

        send(owner, {:worker_death_result, result, MutationServer.release(lease)})
      end)

      assert_receive {:atomic_writer_checkpoint, :before_commit, worker, _checkpoint}, 5_000
      assert length(stage_names(root)) == 1
      Process.exit(worker, :kill)

      assert_receive {:worker_death_result, {:error, :durability_unknown, :unknown}, :ok}, 5_000
      assert Process.alive?(handle.state)
      assert File.read!(path) == "before target after"
      assert eventually(fn -> stage_names(root) == [] end)
      assert :ok = Workspace.close(handle)
    end)
  end

  test "holder death does not abandon an accepted edit or release its lease early" do
    in_temporary_directory(fn root ->
      path = Elixir.Path.join(root, "file.txt")
      File.write!(path, "before target after")
      handle = open_workspace(root)

      request =
        edit_request("file.txt", "target", "replacement", read_revision(handle, "file.txt"))

      owner = self()

      holder =
        spawn(fn ->
          {:ok, lease} = MutationServer.acquire(handle.state, handle.token, "dead-holder", :edit)

          MutationServer.edit(lease, request, "dead-holder",
            test_control: {:before_commit, owner}
          )
        end)

      holder_monitor = Process.monitor(holder)
      assert_receive {:atomic_writer_checkpoint, :before_commit, worker, checkpoint}, 5_000
      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^holder_monitor, :process, ^holder, :killed}, 5_000

      assert {:error, :workspace_busy} =
               MutationServer.acquire(handle.state, handle.token, "too-early", :write)

      send(worker, {:continue_atomic_writer, checkpoint})
      assert eventually(fn -> File.read!(path) == "before replacement after" end)

      assert eventually(fn ->
               case MutationServer.acquire(
                      handle.state,
                      handle.token,
                      "after-dead-holder",
                      :write
                    ) do
                 {:ok, lease} -> MutationServer.release(lease) == :ok
                 {:error, :workspace_busy} -> false
               end
             end)

      assert stage_names(root) == []
      assert :ok = Workspace.close(handle)
    end)
  end

  test "server death during an accepted edit is ambiguous and cleans the stage" do
    in_temporary_directory(fn root ->
      path = Elixir.Path.join(root, "file.txt")
      File.write!(path, "before target after")
      handle = open_workspace(root)

      request =
        edit_request("file.txt", "target", "replacement", read_revision(handle, "file.txt"))

      owner = self()
      server_monitor = Process.monitor(handle.state)

      spawn_link(fn ->
        {:ok, lease} = MutationServer.acquire(handle.state, handle.token, "edit-death", :edit)

        result =
          MutationServer.edit(lease, request, "edit-death", test_control: {:before_commit, owner})

        send(owner, {:edit_death_result, result})
      end)

      assert_receive {:atomic_writer_checkpoint, :before_commit, _worker, _checkpoint}, 5_000
      assert length(stage_names(root)) == 1
      mutation_server = handle.state
      Process.exit(mutation_server, :kill)
      assert_receive {:DOWN, ^server_monitor, :process, ^mutation_server, :killed}, 5_000
      assert_receive {:edit_death_result, {:error, :durability_unknown, :unknown}}, 5_000
      assert File.read!(path) == "before target after"
      assert eventually(fn -> stage_names(root) == [] end)
      assert :ok = Workspace.close(handle)
    end)
  end

  test "accepted cancellation is ignored and activity follows edit outcomes" do
    in_temporary_directory(fn root ->
      path = Elixir.Path.join(root, "file.txt")
      File.write!(path, "one target")
      handle = open_workspace(root)
      revision = read_revision(handle, "file.txt")
      cancel_ref = make_ref()
      operation_context = context("accepted-edit", cancel_ref: cancel_ref)

      assert {:ok, lease} =
               MutationServer.acquire(
                 handle.state,
                 handle.token,
                 "accepted-edit",
                 :edit,
                 operation_context
               )

      send(self(), {:cancel, cancel_ref})
      request = edit_request("file.txt", "target", "replacement", revision)

      assert {:ok, %MutationResult{changed: true}} =
               MutationServer.edit(lease, request, "accepted-edit")

      assert :ok = MutationServer.release(lease)
      assert_receive {:cancel, ^cancel_ref}
      assert File.read!(path) == "one replacement"

      owner = self()
      current = read_revision(handle, "file.txt")

      sink = fn operation_context ->
        send(owner, {:edit_activity, operation_context.operation_id})
        :ok
      end

      assert {:ok, %MutationResult{changed: true}} =
               edit(handle, "file.txt", "replacement", "target", current, "activity",
                 activity_sink: sink
               )

      assert_receive {:edit_activity, "activity"}
      refute_receive {:edit_activity, _operation_id}

      no_match_revision = read_revision(handle, "file.txt")

      assert {:error, %Error{reason: :no_match}} =
               edit(handle, "file.txt", "missing", "new", no_match_revision, "no-activity",
                 activity_sink: sink
               )

      refute_receive {:edit_activity, "no-activity"}

      assert {:error,
              %Error{
                kind: :ambiguous,
                reason: :mutation_activity_failed,
                outcome: :unknown
              }} =
               edit(
                 handle,
                 "file.txt",
                 "target",
                 "committed",
                 no_match_revision,
                 "failed-activity",
                 activity_sink: fn _operation_context -> :invalid end
               )

      assert File.read!(path) == "one committed"
      assert :ok = Workspace.close(handle)
    end)
  end

  defp edit(handle, path, old_text, new_text, revision, operation_id, context_options \\ []) do
    Workspace.edit(
      handle,
      edit_request(path, old_text, new_text, revision),
      context(operation_id, context_options)
    )
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

  defp read_revision(handle, path) do
    {:ok, request} = ReadRequest.new(path: path)

    {:ok, %ReadResult{revision: revision}} =
      Workspace.read(handle, request, context("read-#{path}"))

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

  defp permission_mode(path), do: Bitwise.band(File.stat!(path).mode, 0o7777)

  defp stage_names(root) do
    root
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, ".synapse-stage-"))
  end

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

  defp in_temporary_directory(fun) do
    root =
      Elixir.Path.join(
        System.tmp_dir!(),
        "synapse-workspace-edit-#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}"
      )

    File.mkdir!(root)

    try do
      fun.(root)
    after
      File.rm_rf!(root)
    end
  end
end
