defmodule Synapse.Workspace.FakeTest do
  use ExUnit.Case, async: true

  alias Synapse.Workspace

  alias Synapse.Workspace.{
    Access,
    EditRequest,
    Error,
    Fake,
    Handle,
    MutationResult,
    OperationContext,
    ProcessEvent,
    ProcessResult,
    ProcessSpec,
    ReadLine,
    ReadRequest,
    ReadResult,
    Revision,
    WriteRequest
  }

  test "runs a complete exact read-edit-run script through the Workspace facade" do
    test_pid = self()
    old_revision = revision(1)
    new_revision = revision(2)
    read_context = context("fake-read")
    edit_context = context("fake-edit")
    run_context = context("fake-run")
    read_request = read_request("lib/example.ex")
    read_result = read_result(read_request.path, old_revision, "old")

    {:ok, edit_request} =
      EditRequest.new(
        path: read_request.path,
        old_text: "old",
        new_text: "new",
        expected_revision: old_revision
      )

    edit_result =
      mutation_result(
        edit_context.operation_id,
        read_request.path,
        old_revision,
        new_revision,
        3
      )

    spec = process_spec()
    started = %ProcessEvent.Started{operation_id: run_context.operation_id}
    output = %ProcessEvent.Output{operation_id: run_context.operation_id, sequence: 1, data: "ok"}
    process_result = process_result(run_context.operation_id, "ok")

    script = [
      Fake.expect_read(read_request, read_context, {:ok, read_result}),
      Fake.expect_edit(edit_request, edit_context, {:ok, edit_result}),
      Fake.expect_run(spec, run_context, [started, output], {:ok, process_result})
    ]

    assert {:ok, %Handle{} = handle} = Fake.open(script)
    assert inspect(handle) == "#Synapse.Workspace.Handle<opaque>"
    assert {:error, {:remaining_operations, 3}} = Fake.assert_finished(handle)

    task =
      Task.async(fn ->
        assert {:ok, ^read_result} = Workspace.read(handle, read_request, read_context)
        assert {:ok, ^edit_result} = Workspace.edit(handle, edit_request, edit_context)

        sink = fn event ->
          send(test_pid, {:fake_process_event, event})
          :ok
        end

        Workspace.run(handle, spec, sink, run_context)
      end)

    assert {:ok, ^process_result} = Task.await(task)
    assert_receive {:fake_process_event, ^started}
    assert_receive {:fake_process_event, ^output}
    refute_receive {:fake_process_event, _event}
    assert {:ok, 0} = Fake.remaining_operations(handle)
    assert :ok = Fake.assert_finished(handle)
    assert :ok = Workspace.close(handle)
  end

  test "consumes unexpected operations and exact request or context mismatches once" do
    revision = revision(3)
    expected_context = context("expected-context")
    expected_request = read_request("expected.txt")
    expected_result = read_result(expected_request.path, revision, "expected")

    entry = Fake.expect_read(expected_request, expected_context, {:ok, expected_result})
    assert {:ok, handle} = Fake.open([entry])

    assert {:error, %Error{reason: :unexpected_operation, operation: :read}} =
             Workspace.read(handle, read_request("different.txt"), expected_context)

    assert {:ok, 0} = Fake.remaining_operations(handle)

    assert {:error, %Error{reason: :script_exhausted, operation: :read}} =
             Workspace.read(handle, expected_request, expected_context)

    assert :ok = Workspace.close(handle)

    assert {:ok, context_handle} = Fake.open([entry])

    assert {:error, %Error{reason: :unexpected_operation}} =
             Workspace.read(context_handle, expected_request, context("different-context"))

    assert :ok = Fake.assert_finished(context_handle)
    assert :ok = Workspace.close(context_handle)
  end

  test "preserves deterministic source order across operation kinds" do
    read_context = context("ordered-read")
    write_context = context("ordered-write")
    read_request = read_request("ordered.txt")
    revision = revision(4)
    read_result = read_result(read_request.path, revision, "value")

    {:ok, write_request} =
      WriteRequest.new(path: "created.txt", content: "created", expected_revision: :missing)

    write_result =
      mutation_result(
        write_context.operation_id,
        write_request.path,
        :missing,
        revision(5),
        byte_size(write_request.content)
      )

    script = [
      Fake.expect_read(read_request, read_context, {:ok, read_result}),
      Fake.expect_write(write_request, write_context, {:ok, write_result})
    ]

    assert {:ok, handle} = Fake.open(script)

    assert {:error, %Error{reason: :unexpected_operation, operation: :write}} =
             Workspace.write(handle, write_request, write_context)

    assert {:error, %Error{reason: :unexpected_operation, operation: :read}} =
             Workspace.read(handle, read_request, read_context)

    assert :ok = Fake.assert_finished(handle)
    assert :ok = Workspace.close(handle)
  end

  test "returns scripted stale, denied, timeout, and ambiguous outcomes" do
    old_revision = revision(6)
    read_context = context("scripted-denied")
    write_context = context("scripted-stale")
    timeout_context = context("scripted-timeout")
    ambiguous_context = context("scripted-ambiguous")
    read_request = read_request("denied.txt")

    denied = error(:denied, :access_denied, :read, read_context, :not_applied)

    {:ok, write_request} =
      WriteRequest.new(path: "stale.txt", content: "new", expected_revision: old_revision)

    stale = error(:conflict, :stale_revision, :write, write_context, :not_applied, "stale.txt")
    timeout_spec = process_spec()
    timeout_result = process_result(timeout_context.operation_id, "", :timed_out)
    timeout_started = %ProcessEvent.Started{operation_id: timeout_context.operation_id}
    unknown_spec = process_spec(mutation: :unknown)

    ambiguous =
      error(:ambiguous, :runner_failed, :run, ambiguous_context, :unknown)

    script = [
      Fake.expect_read(read_request, read_context, {:error, denied}),
      Fake.expect_write(write_request, write_context, {:error, stale}),
      Fake.expect_run(timeout_spec, timeout_context, [timeout_started], {:ok, timeout_result}),
      Fake.expect_run(unknown_spec, ambiguous_context, [], {:error, ambiguous})
    ]

    assert {:ok, handle} = Fake.open(script)
    assert {:error, ^denied} = Workspace.read(handle, read_request, read_context)
    assert {:error, ^stale} = Workspace.write(handle, write_request, write_context)

    assert {:ok, ^timeout_result} =
             Workspace.run(handle, timeout_spec, fn _event -> :ok end, timeout_context)

    assert {:error, ^ambiguous} =
             Workspace.run(handle, unknown_spec, fn _event -> :ok end, ambiguous_context)

    assert :ok = Fake.assert_finished(handle)
    assert :ok = Workspace.close(handle)
  end

  test "cancels during synchronous event emission without sleeping" do
    cancel_ref = make_ref()
    context = context("fake-cancel", cancel_ref: cancel_ref)
    spec = process_spec()
    started = %ProcessEvent.Started{operation_id: context.operation_id}
    first = %ProcessEvent.Output{operation_id: context.operation_id, sequence: 1, data: "A"}
    second = %ProcessEvent.Output{operation_id: context.operation_id, sequence: 2, data: "B"}
    scripted_result = process_result(context.operation_id, "AB")

    entry =
      Fake.expect_run(spec, context, [started, first, second], {:ok, scripted_result})

    assert {:ok, handle} = Fake.open([entry])

    sink = fn event ->
      send(self(), {:fake_cancel_event, event})
      if event == first, do: send(self(), {:cancel, cancel_ref})
      :ok
    end

    assert {:ok, %ProcessResult{termination: :cancelled, output: "A"}} =
             Workspace.run(handle, spec, sink, context)

    assert_received {:fake_cancel_event, ^started}
    assert_received {:fake_cancel_event, ^first}
    refute_received {:fake_cancel_event, ^second}
    assert :ok = Fake.assert_finished(handle)
    assert :ok = Workspace.close(handle)
  end

  test "normalizes event-sink rejection and leaves no later event" do
    context = context("fake-sink-rejection")
    spec = process_spec()
    started = %ProcessEvent.Started{operation_id: context.operation_id}
    output = %ProcessEvent.Output{operation_id: context.operation_id, sequence: 1, data: "data"}
    result = process_result(context.operation_id, "data")
    entry = Fake.expect_run(spec, context, [started, output], {:ok, result})
    assert {:ok, handle} = Fake.open([entry])

    sink = fn
      %ProcessEvent.Started{} -> :ok
      %ProcessEvent.Output{} -> :reject
    end

    assert {:error, %Error{reason: :event_sink_failed, outcome: :not_applicable}} =
             Workspace.run(handle, spec, sink, context)

    assert :ok = Fake.assert_finished(handle)
    assert :ok = Workspace.close(handle)
  end

  test "close waits for a blocked active operation before stopping the handle" do
    test_pid = self()
    context = context("fake-close-active")
    spec = process_spec()
    started = %ProcessEvent.Started{operation_id: context.operation_id}
    output = %ProcessEvent.Output{operation_id: context.operation_id, sequence: 1, data: "late"}
    result = process_result(context.operation_id, "late")
    entry = Fake.expect_run(spec, context, [started, output], {:ok, result})
    assert {:ok, handle} = Fake.open([entry])

    task =
      Task.async(fn ->
        sink = fn event ->
          send(test_pid, {:blocked_fake_event, event, self()})

          case event do
            %ProcessEvent.Started{} ->
              receive do
                :release_blocked_fake_event -> :ok
              end

            %ProcessEvent.Output{} ->
              :ok
          end
        end

        Workspace.run(handle, spec, sink, context)
      end)

    assert_receive {:blocked_fake_event, ^started, sink_process}
    close_task = Task.async(fn -> Workspace.close(handle) end)
    assert nil == Task.yield(close_task, 10)
    send(sink_process, :release_blocked_fake_event)

    assert {:ok, ^result} = Task.await(task)
    assert_receive {:blocked_fake_event, ^output, _sink_process}
    assert :ok = Task.await(close_task)
    refute Fake.valid_handle?(handle)
  end

  test "pre-operation cancellation and deadline do not consume a script entry" do
    request = read_request("lifetime.txt")
    revision = revision(7)
    result = read_result(request.path, revision, "value")
    cancel_ref = make_ref()
    cancelled_context = context("fake-pre-cancel", cancel_ref: cancel_ref)
    cancelled_entry = Fake.expect_read(request, cancelled_context, {:ok, result})
    assert {:ok, cancelled_handle} = Fake.open([cancelled_entry])
    send(self(), {:cancel, cancel_ref})

    assert {:error, %Error{reason: :cancelled}} =
             Workspace.read(cancelled_handle, request, cancelled_context)

    assert {:ok, 1} = Fake.remaining_operations(cancelled_handle)
    assert :ok = Workspace.close(cancelled_handle)

    deadline_context =
      context("fake-pre-deadline", deadline: System.monotonic_time(:millisecond))

    deadline_entry = Fake.expect_read(request, deadline_context, {:ok, result})
    assert {:ok, deadline_handle} = Fake.open([deadline_entry])

    assert {:error, %Error{reason: :deadline_elapsed}} =
             Workspace.read(deadline_handle, request, deadline_context)

    assert {:ok, 1} = Fake.remaining_operations(deadline_handle)
    assert :ok = Workspace.close(deadline_handle)
  end

  test "rejects malformed scripts and stops the handle when its owner dies" do
    assert {:error, :invalid_script} = Fake.open([:not_an_entry])
    assert {:error, :invalid_options} = Fake.open([], unknown: true)

    context = context("invalid-correlation")
    request = read_request("expected.txt")
    wrong_result = read_result("different.txt", revision(8), "wrong")

    assert {:error, :invalid_script} =
             Fake.open([Fake.expect_read(request, context, {:ok, wrong_result})])

    spec = process_spec()
    started = %ProcessEvent.Started{operation_id: context.operation_id}
    bad_output = %ProcessEvent.Output{operation_id: context.operation_id, sequence: 2, data: "x"}

    assert {:error, :invalid_script} =
             Fake.open([
               Fake.expect_run(
                 spec,
                 context,
                 [started, bad_output],
                 {:ok, process_result(context.operation_id, "x")}
               )
             ])

    wrong_error = error(:conflict, :stale_revision, :write, context, :not_applied, "expected.txt")

    assert {:error, :invalid_script} =
             Fake.open([Fake.expect_read(request, context, {:error, wrong_error})])

    {:ok, write_request} =
      WriteRequest.new(path: "wrong-operation.txt", content: "value", expected_revision: :missing)

    wrong_mutation =
      mutation_result("wrong-operation-id", write_request.path, :missing, revision(11), 5)

    assert {:error, :invalid_script} =
             Fake.open([Fake.expect_write(write_request, context, {:ok, wrong_mutation})])

    valid_output = %ProcessEvent.Output{
      operation_id: context.operation_id,
      sequence: 1,
      data: "x"
    }

    assert {:error, :invalid_script} =
             Fake.open([
               Fake.expect_run(
                 spec,
                 context,
                 [started, valid_output],
                 {:ok, process_result(context.operation_id, "different")}
               )
             ])

    {:ok, denied_access} = Access.new(read: false, write: true, exec: true)

    assert {:error, :invalid_script} =
             Fake.open(
               [
                 Fake.expect_read(
                   request,
                   context,
                   {:ok, read_result(request.path, revision(12), "ok")}
                 )
               ],
               access: denied_access
             )

    {:ok, lowered_limits} =
      Synapse.Workspace.Limits.new(default_read_bytes: 4, max_read_bytes: 4)

    assert {:error, :invalid_script} =
             Fake.open(
               [
                 Fake.expect_read(
                   request,
                   context,
                   {:ok, read_result(request.path, revision(13), "ok")}
                 )
               ],
               limits: lowered_limits
             )

    owner = spawn(fn -> Process.sleep(:infinity) end)
    assert {:ok, handle} = Fake.open([], owner: owner)
    assert Fake.valid_handle?(handle)
    monitor = Process.monitor(handle.state)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, _server, :normal}
    refute Fake.valid_handle?(handle)
    assert {:error, :invalid_handle} = Fake.remaining_operations(handle)
  end

  test "returns a successful scripted write result" do
    context = context("fake-write-success")

    {:ok, request} =
      WriteRequest.new(path: "created.txt", content: "created", expected_revision: :missing)

    result =
      mutation_result(
        context.operation_id,
        request.path,
        :missing,
        revision(9),
        byte_size(request.content)
      )

    assert {:ok, handle} = Fake.open([Fake.expect_write(request, context, {:ok, result})])
    assert {:ok, ^result} = Workspace.write(handle, request, context)
    assert :ok = Fake.assert_finished(handle)
    assert :ok = Workspace.close(handle)
  end

  test "owner death during changed-mutation activity preserves ambiguity" do
    test_pid = self()
    owner = spawn(fn -> Process.sleep(:infinity) end)

    activity_sink = fn _context ->
      send(test_pid, {:fake_mutation_activity, self()})

      receive do
        :release_fake_mutation_activity -> :reject
      end
    end

    context = context("fake-owner-death-write", activity_sink: activity_sink)

    {:ok, request} =
      WriteRequest.new(path: "changed.txt", content: "changed", expected_revision: :missing)

    result =
      mutation_result(
        context.operation_id,
        request.path,
        :missing,
        revision(10),
        byte_size(request.content)
      )

    assert {:ok, handle} =
             Fake.open([Fake.expect_write(request, context, {:ok, result})], owner: owner)

    task = Task.async(fn -> Workspace.write(handle, request, context) end)
    assert_receive {:fake_mutation_activity, activity_process}
    server_monitor = Process.monitor(handle.state)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^server_monitor, :process, _server, :normal}
    send(activity_process, :release_fake_mutation_activity)

    assert {:error,
            %Error{kind: :ambiguous, reason: :mutation_activity_failed, outcome: :unknown}} =
             Task.await(task)
  end

  test "implementation has no host file, command, Port, or environment access" do
    source = File.read!("lib/synapse/workspace/fake.ex")

    refute source =~ ~r/\bFile\./
    refute source =~ ~r/\bSystem\./
    refute source =~ ~r/\bPort\./
    refute source =~ ~r/\bSystem\.(get_env|put_env|delete_env)/
  end

  defp read_request(path) do
    {:ok, request} = ReadRequest.new(path: path, start_line: 1, line_count: 10, max_bytes: 1_024)
    request
  end

  defp read_result(path, revision, text) do
    {:ok, line} = ReadLine.new(number: 1, text: text, ending: :none, truncated: false)

    {:ok, result} =
      ReadResult.new(
        path: path,
        revision: revision,
        lines: [line],
        next_line: nil,
        file_bytes: byte_size(text)
      )

    result
  end

  defp mutation_result(operation_id, path, previous_revision, revision, bytes_written) do
    {:ok, result} =
      MutationResult.new(
        operation_id: operation_id,
        path: path,
        previous_revision: previous_revision,
        revision: revision,
        bytes_written: bytes_written,
        changed: true,
        diff: "changed",
        diff_truncated: false
      )

    result
  end

  defp process_spec(options \\ []) do
    {:ok, spec} =
      ProcessSpec.new(
        [
          executable: "/usr/bin/true",
          arguments: [],
          cwd: ".",
          mutation: :read_only,
          timeout_ms: 1_000,
          inactivity_ms: 500,
          max_output_bytes: 1_024
        ] ++ options
      )

    spec
  end

  defp process_result(operation_id, output, termination \\ :exited) do
    {:ok, result} =
      ProcessResult.new(
        operation_id: operation_id,
        termination: termination,
        exit_code: if(termination == :exited, do: 0),
        output: output,
        output_bytes: byte_size(output),
        truncated: false,
        elapsed_ms: 0
      )

    result
  end

  defp context(operation_id, options \\ []) do
    {:ok, access} = Access.new(read: true, write: true, exec: true)

    {:ok, context} =
      options
      |> Keyword.put(:operation_id, operation_id)
      |> Keyword.put(:access, access)
      |> OperationContext.new()

    context
  end

  defp revision(byte) do
    {:ok, revision} = Revision.from_mac(:binary.copy(<<byte>>, 32))
    revision
  end

  defp error(kind, reason, operation, context, outcome, path \\ nil) do
    {:ok, error} =
      Error.new(
        kind: kind,
        reason: reason,
        operation: operation,
        message: "scripted #{reason}",
        operation_id: context.operation_id,
        path: path,
        outcome: outcome
      )

    error
  end
end
