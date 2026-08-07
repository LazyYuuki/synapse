defmodule Synapse.Workspace.MutationServerTest do
  use ExUnit.Case, async: false

  alias Synapse.Workspace

  alias Synapse.Workspace.{
    Access,
    EditRequest,
    Error,
    Limits,
    MutationLease,
    MutationServer,
    OpenRequest,
    OperationContext,
    Platform,
    ProcessSpec,
    ReadRequest,
    WriteRequest
  }

  @moduletag skip: not Platform.supported?()

  test "starts one redacted temporary MutationServer per handle" do
    in_temporary_directory(fn root ->
      baseline = DynamicSupervisor.count_children(Synapse.Workspace.Supervisor).active
      first = open_workspace(root)
      second = open_workspace(root)

      assert first.state != second.state
      assert Process.alive?(first.state)
      assert Process.alive?(second.state)
      assert MutationServer.child_spec(:ignored).restart == :temporary
      assert DynamicSupervisor.count_children(Synapse.Workspace.Supervisor).active == baseline + 2

      supervised =
        Synapse.Workspace.Supervisor
        |> DynamicSupervisor.which_children()
        |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)

      assert first.state in supervised
      assert second.state in supervised

      assert inspect(:sys.get_state(first.state)) ==
               "#Synapse.Workspace.MutationServer<redacted>"

      assert :ok = Workspace.close(first)
      assert :ok = Workspace.close(second)

      assert eventually(fn ->
               DynamicSupervisor.count_children(Synapse.Workspace.Supervisor).active == baseline
             end)
    end)
  end

  test "missing Workspace supervisor returns one structured unavailable open error" do
    in_temporary_directory(fn root ->
      dead_supervisor = spawn(fn -> :ok end)
      monitor = Process.monitor(dead_supervisor)
      assert_receive {:DOWN, ^monitor, :process, ^dead_supervisor, reason}
      assert reason in [:normal, :noproc]

      assert {:error,
              %Error{
                kind: :unavailable,
                reason: :backend_unavailable,
                operation: :open,
                outcome: :not_applicable
              }} = Synapse.Workspace.Real.open(open_request(root), dead_supervisor)
    end)
  end

  test "concurrent mutation callers produce one winner without assuming sender order" do
    in_temporary_directory(fn root ->
      handle = open_workspace(root)
      owner = self()

      workers =
        for label <- [:write, :edit] do
          spawn(fn ->
            receive do
              :go -> :ok
            end

            result =
              MutationServer.acquire(handle.state, handle.token, "#{label}-operation", label)

            send(owner, {:admission, label, result})

            case result do
              {:ok, lease} ->
                receive do
                  :release -> send(owner, {:released, label, MutationServer.release(lease)})
                end

              {:error, :workspace_busy} ->
                :ok
            end
          end)
        end

      Enum.each(workers, &send(&1, :go))

      admissions = [receive_admission(), receive_admission()]

      assert Enum.count(admissions, fn {_label, result} ->
               match?({:ok, %MutationLease{}}, result)
             end) == 1

      assert Enum.count(admissions, fn {_label, result} -> result == {:error, :workspace_busy} end) ==
               1

      {winner, {:ok, lease}} =
        Enum.find(admissions, fn {_label, result} -> match?({:ok, _}, result) end)

      assert inspect(lease) == "#Synapse.Workspace.MutationLease<opaque>"
      winner_pid = Enum.at(workers, if(winner == :write, do: 0, else: 1))
      send(winner_pid, :release)
      assert_receive {:released, ^winner, :ok}

      assert {:ok, final_lease} =
               MutationServer.acquire(handle.state, handle.token, "after-release", :write)

      assert :ok = MutationServer.release(final_lease)
      Workspace.close(handle)
    end)
  end

  test "active operation IDs are unique and busy calls do not queue" do
    in_temporary_directory(fn root ->
      handle = open_workspace(root)

      assert {:ok, lease} =
               MutationServer.acquire(handle.state, handle.token, "duplicate", :write)

      started = System.monotonic_time(:millisecond)

      assert {:error, :workspace_busy} =
               MutationServer.acquire(handle.state, handle.token, "duplicate", :read)

      assert System.monotonic_time(:millisecond) - started < 250
      assert :ok = MutationServer.release(lease)
      Workspace.close(handle)
    end)
  end

  test "unknown process leases exclude reads while file leases permit them" do
    in_temporary_directory(fn root ->
      File.write!(Elixir.Path.join(root, "file.txt"), "content")
      handle = open_workspace(root)

      assert {:ok, unknown} =
               MutationServer.acquire(handle.state, handle.token, "unknown", :unknown_process)

      assert {:error, %Error{kind: :conflict, reason: :workspace_busy}} =
               Workspace.read(handle, read_request("file.txt"), context("blocked-read"))

      assert :ok = MutationServer.release(unknown)

      assert {:ok, writer} =
               MutationServer.acquire(handle.state, handle.token, "writer", :write)

      assert {:ok, _result} =
               Workspace.read(handle, read_request("file.txt"), context("allowed-read"))

      assert :ok = MutationServer.release(writer)

      assert {:ok, reader} =
               MutationServer.acquire(handle.state, handle.token, "reader", :read)

      assert {:error, :workspace_busy} =
               MutationServer.acquire(
                 handle.state,
                 handle.token,
                 "unknown-while-read",
                 :unknown_process
               )

      assert :ok = MutationServer.release(reader)
      Workspace.close(handle)
    end)
  end

  test "shared operation admissions honor the configured retained-state ceiling" do
    in_temporary_directory(fn root ->
      {:ok, limits} = Limits.new(max_concurrent_operations: 1)
      handle = open_workspace(root, limits)

      assert {:ok, first} =
               MutationServer.acquire(handle.state, handle.token, "bounded-first", :read)

      assert {:error, :workspace_busy} =
               MutationServer.acquire(handle.state, handle.token, "bounded-second", :read)

      assert :ok = MutationServer.release(first)

      assert {:ok, second} =
               MutationServer.acquire(handle.state, handle.token, "bounded-second", :read)

      assert :ok = MutationServer.release(second)
      assert :ok = Workspace.close(handle)
    end)
  end

  test "holder death before acquisition and while holding releases ownership" do
    in_temporary_directory(fn root ->
      handle = open_workspace(root)
      :ok = :sys.suspend(handle.state)
      owner = self()

      before_acquisition =
        spawn(fn ->
          send(owner, :before_acquisition_started)
          MutationServer.acquire(handle.state, handle.token, "dead-before", :write)
        end)

      assert_receive :before_acquisition_started

      assert eventually(fn ->
               server_has_message?(handle.state, fn
                 {:lease_request, ^before_acquisition, _, _, "dead-before", :write} -> true
                 _message -> false
               end)
             end)

      before_monitor = Process.monitor(before_acquisition)
      Process.exit(before_acquisition, :kill)
      assert_receive {:DOWN, ^before_monitor, :process, ^before_acquisition, :killed}
      :ok = :sys.resume(handle.state)

      assert eventually(fn ->
               case MutationServer.acquire(
                      handle.state,
                      handle.token,
                      "after-dead-before",
                      :write
                    ) do
                 {:ok, lease} -> MutationServer.release(lease) == :ok
                 {:error, :workspace_busy} -> false
               end
             end)

      holder =
        spawn(fn ->
          {:ok, lease} =
            MutationServer.acquire(handle.state, handle.token, "held", :unknown_process)

          send(owner, {:held_lease, lease})
          Process.sleep(:infinity)
        end)

      assert_receive {:held_lease, %MutationLease{}}
      holder_monitor = Process.monitor(holder)
      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^holder_monitor, :process, ^holder, :killed}

      assert eventually(fn ->
               case MutationServer.acquire(
                      handle.state,
                      handle.token,
                      "after-holder-death",
                      :edit
                    ) do
                 {:ok, lease} -> MutationServer.release(lease) == :ok
                 {:error, :workspace_busy} -> false
               end
             end)

      Workspace.close(handle)
    end)
  end

  test "queued cancellation and deadline withdrawal cannot leave an orphaned lease" do
    in_temporary_directory(fn root ->
      handle = open_workspace(root)
      owner = self()

      :ok = :sys.suspend(handle.state)
      cancel_ref = make_ref()

      cancelled_caller =
        spawn(fn ->
          send(owner, :cancelled_admission_started)

          result =
            MutationServer.acquire(
              handle.state,
              handle.token,
              "queued-cancel",
              :write,
              context("queued-cancel", cancel_ref: cancel_ref)
            )

          send(owner, {:cancelled_admission_result, result})
        end)

      assert_receive :cancelled_admission_started

      assert eventually(fn ->
               server_has_message?(handle.state, fn
                 {:lease_request, ^cancelled_caller, _, _, "queued-cancel", :write} -> true
                 _message -> false
               end)
             end)

      send(cancelled_caller, {:cancel, cancel_ref})

      assert eventually(fn ->
               server_has_message?(handle.state, fn
                 {:cancel_lease_request, ^cancelled_caller, _request_reference} -> true
                 _message -> false
               end)
             end)

      :ok = :sys.resume(handle.state)
      assert_receive {:cancelled_admission_result, {:error, :cancelled}}, 1_000

      assert {:ok, after_cancel} =
               MutationServer.acquire(handle.state, handle.token, "after-cancel", :write)

      assert :ok = MutationServer.release(after_cancel)

      :ok = :sys.suspend(handle.state)

      deadline_caller =
        spawn(fn ->
          send(owner, :deadline_admission_started)

          result =
            MutationServer.acquire(
              handle.state,
              handle.token,
              "queued-deadline",
              :edit,
              context(
                "queued-deadline",
                deadline: System.monotonic_time(:millisecond) + 30
              )
            )

          send(owner, {:deadline_admission_result, result})
        end)

      assert_receive :deadline_admission_started

      assert eventually(fn ->
               server_has_message?(handle.state, fn
                 {:lease_request, ^deadline_caller, _, _, "queued-deadline", :edit} -> true
                 _message -> false
               end)
             end)

      assert eventually(fn ->
               server_has_message?(handle.state, fn
                 {:cancel_lease_request, ^deadline_caller, _request_reference} -> true
                 _message -> false
               end)
             end)

      :ok = :sys.resume(handle.state)
      assert_receive {:deadline_admission_result, {:error, :deadline_elapsed}}, 1_000
      refute Process.alive?(deadline_caller)

      assert {:ok, after_deadline} =
               MutationServer.acquire(handle.state, handle.token, "after-deadline", :edit)

      assert :ok = MutationServer.release(after_deadline)
      Workspace.close(handle)
    end)
  end

  test "a queued grant already in the caller mailbox cannot beat an expired deadline" do
    in_temporary_directory(fn root ->
      handle = open_workspace(root)
      owner = self()
      :ok = :sys.suspend(handle.state)

      caller =
        spawn(fn ->
          result =
            MutationServer.acquire(
              handle.state,
              handle.token,
              "late-reply",
              :write,
              context(
                "late-reply",
                deadline: System.monotonic_time(:millisecond) + 200
              )
            )

          send(owner, {:late_reply_result, result})
        end)

      assert eventually(fn ->
               server_has_message?(handle.state, fn
                 {:lease_request, ^caller, _, _, "late-reply", :write} -> true
                 _message -> false
               end)
             end)

      true = :erlang.suspend_process(caller)
      :ok = :sys.resume(handle.state)

      assert eventually(fn ->
               process_has_message?(caller, fn
                 {:lease_reply, _, _, {:ok, _lease_reference}} -> true
                 _message -> false
               end)
             end)

      Process.sleep(220)
      true = :erlang.resume_process(caller)
      assert_receive {:late_reply_result, {:error, :deadline_elapsed}}, 1_000

      assert {:ok, lease} =
               MutationServer.acquire(handle.state, handle.token, "after-late-reply", :write)

      assert :ok = MutationServer.release(lease)
      Workspace.close(handle)
    end)
  end

  test "matching cancellation after admission does not revoke an accepted file lease" do
    in_temporary_directory(fn root ->
      handle = open_workspace(root)
      cancel_ref = make_ref()

      assert {:ok, lease} =
               MutationServer.acquire(
                 handle.state,
                 handle.token,
                 "accepted",
                 :write,
                 context("accepted", cancel_ref: cancel_ref)
               )

      send(self(), {:cancel, cancel_ref})

      assert {:error, :workspace_busy} =
               MutationServer.acquire(handle.state, handle.token, "blocked", :edit)

      assert_receive {:cancel, ^cancel_ref}
      assert :ok = MutationServer.release(lease)
      Workspace.close(handle)
    end)
  end

  test "only the holder can release and tokens are handle-scoped" do
    in_temporary_directory(fn root ->
      first = open_workspace(root)
      second = open_workspace(root)
      assert {:ok, lease} = MutationServer.acquire(first.state, first.token, "first", :write)

      assert {:error, :invalid_handle} =
               MutationServer.acquire(first.state, second.token, "cross-token", :edit)

      assert {:error, :invalid_handle} =
               MutationServer.acquire(second.state, first.token, "cross-server", :edit)

      owner = self()

      releaser =
        spawn(fn ->
          send(owner, {:foreign_release, MutationServer.release(lease)})
        end)

      releaser_monitor = Process.monitor(releaser)
      assert_receive {:foreign_release, {:error, :invalid_handle}}
      assert_receive {:DOWN, ^releaser_monitor, :process, ^releaser, :normal}

      assert {:error, :workspace_busy} =
               MutationServer.acquire(first.state, first.token, "still-held", :edit)

      assert :ok = MutationServer.release(lease)
      Workspace.close(first)
      Workspace.close(second)
    end)
  end

  test "server crash and close release all ownership without restart or replay" do
    in_temporary_directory(fn root ->
      baseline = DynamicSupervisor.count_children(Synapse.Workspace.Supervisor).active
      handle = open_workspace(root)
      server = handle.state
      monitor = Process.monitor(server)
      owner = self()
      :ok = :sys.suspend(server)

      holder =
        spawn(fn ->
          result = MutationServer.acquire(server, handle.token, "queued", :write)
          send(owner, {:queued_result, result})
        end)

      assert eventually(fn ->
               server_has_message?(server, fn
                 {:lease_request, ^holder, _, _, "queued", :write} -> true
                 _message -> false
               end)
             end)

      Process.exit(server, :kill)

      assert_receive {:DOWN, ^monitor, :process, ^server, :killed}
      assert_receive {:queued_result, {:error, :invalid_handle}}
      refute Process.alive?(server)
      refute Process.alive?(holder)

      assert eventually(fn ->
               DynamicSupervisor.count_children(Synapse.Workspace.Supervisor).active == baseline
             end)

      assert {:error, %Error{reason: :invalid_handle}} =
               Workspace.read(handle, read_request("missing"), context("after-crash"))

      assert :ok = Workspace.close(handle)
    end)

    in_temporary_directory(fn root ->
      handle = open_workspace(root)
      assert {:ok, lease} = MutationServer.acquire(handle.state, handle.token, "active", :write)
      server_monitor = Process.monitor(handle.state)
      assert :ok = Workspace.close(handle)
      assert_receive {:DOWN, ^server_monitor, :process, _, :normal}
      assert_receive {:workspace_lease_revoked, _, reference, :normal}
      assert reference == lease.reference
      assert {:error, :invalid_handle} = MutationServer.release(lease)
    end)
  end

  test "queued close returns only after the server has actually stopped" do
    in_temporary_directory(fn root ->
      handle = open_workspace(root)
      owner = self()
      monitor = Process.monitor(handle.state)
      :ok = :sys.suspend(handle.state)

      closer =
        spawn(fn ->
          send(owner, :close_started)
          send(owner, {:close_result, Workspace.close(handle)})
        end)

      assert_receive :close_started

      assert eventually(fn ->
               server_has_message?(handle.state, fn
                 {:"$gen_call", _from, {:close, token, limits, access}}
                 when token == handle.token and limits == handle.limits and
                        access == handle.access ->
                   true

                 _message ->
                   false
               end)
             end)

      assert Process.alive?(closer)
      :ok = :sys.resume(handle.state)

      assert_receive {:close_result, :ok}, 1_000
      assert_receive {:DOWN, ^monitor, :process, _, :normal}, 1_000
      refute Process.alive?(handle.state)
    end)
  end

  test "an active holder observes abnormal server DOWN without terminate revocation" do
    in_temporary_directory(fn root ->
      handle = open_workspace(root)

      assert {:ok, lease} =
               MutationServer.acquire(
                 handle.state,
                 handle.token,
                 "crash-active",
                 :unknown_process
               )

      Process.exit(handle.state, :kill)

      assert_receive {:DOWN, monitor, :process, server, :killed}, 1_000
      assert monitor == lease.server_monitor
      assert server == handle.state
      refute_receive {:workspace_lease_revoked, _, _, _reason}
      assert {:error, :invalid_handle} = MutationServer.release(lease)
      assert :ok = Workspace.close(handle)
    end)
  end

  test "invalid admission data is distinct from genuine contention" do
    in_temporary_directory(fn root ->
      handle = open_workspace(root)

      assert {:error, :invalid_request} =
               MutationServer.acquire(handle.state, handle.token, "", :write)

      assert {:error, :invalid_request} =
               MutationServer.acquire(handle.state, handle.token, "invalid-kind", :shell)

      assert {:ok, lease} = MutationServer.acquire(handle.state, handle.token, "valid", :write)

      assert {:error, :workspace_busy} =
               MutationServer.acquire(handle.state, handle.token, "contended", :edit)

      assert :ok = MutationServer.release(lease)
      Workspace.close(handle)
    end)
  end

  test "active status and lease metadata remain redacted" do
    in_temporary_directory(fn root ->
      handle = open_workspace(root)

      assert {:ok, lease} =
               MutationServer.acquire(
                 handle.state,
                 handle.token,
                 "sensitive-operation-id",
                 :unknown_process
               )

      status = inspect(:sys.get_status(handle.state))
      assert status =~ "redacted"
      refute status =~ "sensitive-operation-id"
      refute status =~ inspect(handle.token)
      assert :ok = MutationServer.release(lease)
      Workspace.close(handle)
    end)
  end

  test "write, edit, and unknown run admission are serialized and pre-admission cancellation wins" do
    in_temporary_directory(fn root ->
      path = Elixir.Path.join(root, "file.txt")
      File.write!(path, "content")
      handle = open_workspace(root)
      revision = read_revision(handle, "file.txt")

      {:ok, write} =
        WriteRequest.new(path: "new.txt", content: "new", expected_revision: :missing)

      cancel_ref = make_ref()
      send(self(), {:cancel, cancel_ref})

      assert {:error, %Error{kind: :cancelled, reason: :cancelled, outcome: :not_applied}} =
               Workspace.write(handle, write, context("cancelled-write", cancel_ref: cancel_ref))

      refute File.exists?(Elixir.Path.join(root, "new.txt"))

      {:ok, edit} =
        EditRequest.new(
          path: "file.txt",
          old_text: "content",
          new_text: "updated",
          expected_revision: revision
        )

      assert {:error, %Error{reason: :deadline_elapsed, outcome: :not_applied}} =
               Workspace.edit(
                 handle,
                 edit,
                 context("expired-edit", deadline: System.monotonic_time(:millisecond) - 1)
               )

      assert {:ok, active} = MutationServer.acquire(handle.state, handle.token, "active", :write)

      {:ok, unknown} =
        ProcessSpec.new(executable: "/bin/sh", cwd: ".", mutation: :unknown)

      assert {:error, %Error{reason: :workspace_busy}} =
               Workspace.run(handle, unknown, fn _event -> :ok end, context("unknown-run"))

      {:ok, read_only} =
        ProcessSpec.new(executable: "/bin/sh", cwd: ".", mutation: :read_only)

      assert {:ok, %Synapse.Workspace.ProcessResult{termination: :exited, exit_code: 0}} =
               Workspace.run(handle, read_only, fn _event -> :ok end, context("read-only-run"))

      send(self(), {:cancel, make_ref()})

      assert {:error, :workspace_busy} =
               MutationServer.acquire(handle.state, handle.token, "still-active", :edit)

      assert :ok = MutationServer.release(active)

      assert {:ok, %Synapse.Workspace.MutationResult{path: "new.txt"}} =
               Workspace.write(handle, write, context("accepted-write"))

      assert {:ok, available} =
               MutationServer.acquire(handle.state, handle.token, "available", :edit)

      assert :ok = MutationServer.release(available)
      Workspace.close(handle)
    end)
  end

  defp receive_admission do
    receive do
      {:admission, label, result} -> {label, result}
    after
      1_000 -> flunk("mutation admission did not complete")
    end
  end

  defp read_revision(handle, path) do
    {:ok, request} = ReadRequest.new(path: path)
    {:ok, result} = Workspace.read(handle, request, context("revision-read"))
    result.revision
  end

  defp read_request(path) do
    {:ok, request} = ReadRequest.new(path: path)
    request
  end

  defp context(operation_id, options \\ []) do
    {:ok, access} = Access.new(read: true, write: true, exec: true)

    options =
      options
      |> Keyword.put(:operation_id, operation_id)
      |> Keyword.put(:access, access)

    {:ok, context} = OperationContext.new(options)
    context
  end

  defp open_workspace(root, limits \\ Limits.default()) do
    {:ok, handle} = Workspace.open(open_request(root, limits))
    handle
  end

  defp open_request(root, limits \\ Limits.default()) do
    {:ok, access} = Access.new(read: true, write: true, exec: true)

    {:ok, request} =
      OpenRequest.new(
        root: root,
        owner: self(),
        limits: limits,
        access: access
      )

    request
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

  defp server_has_message?(server, predicate), do: process_has_message?(server, predicate)

  defp process_has_message?(process, predicate) do
    case Process.info(process, :messages) do
      {:messages, messages} -> Enum.any?(messages, predicate)
      nil -> false
    end
  end

  defp in_temporary_directory(fun) do
    root = temporary_directory()

    try do
      fun.(root)
    after
      File.rm_rf!(root)
    end
  end

  defp temporary_directory do
    root =
      Elixir.Path.join(
        System.tmp_dir!(),
        "synapse-mutation-server-#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}"
      )

    File.mkdir!(root)
    root
  end
end
