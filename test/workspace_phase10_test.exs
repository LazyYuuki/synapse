defmodule Synapse.Workspace.Phase10Test do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  require Logger

  alias Synapse.Workspace

  alias Synapse.Workspace.{
    Access,
    EditRequest,
    Error,
    Fake,
    Limits,
    OperationContext,
    ProcessEvent,
    ProcessResult,
    ProcessSpec,
    ReadLine,
    ReadRequest,
    ReadResult,
    Revision,
    Validation,
    WriteRequest
  }

  test "every configured ceiling rejects zero, non-integers, and values above its hard maximum" do
    defaults = Limits.default() |> Map.from_struct()

    Enum.each(defaults, fn {field, hard_maximum} ->
      assert {:error, {^field, :must_be_reasonable_positive_integer}} =
               Limits.new(%{field => 0})

      assert {:error, {^field, :must_be_reasonable_positive_integer}} =
               Limits.new(%{field => :unbounded})

      assert {:error, {^field, :must_be_reasonable_positive_integer}} =
               Limits.new(%{field => hard_maximum + 1})
    end)

    assert {:error, {:max_environment_entries, :must_be_reasonable_positive_integer}} =
             Limits.new(max_environment_entries: 7)

    assert {:error, {:max_environment_name_bytes, :must_be_reasonable_positive_integer}} =
             Limits.new(max_environment_name_bytes: 18)

    assert {:error, {:max_environment_value_bytes, :must_be_reasonable_positive_integer}} =
             Limits.new(max_environment_value_bytes: 28)

    assert {:error, {:max_diagnostic_bytes, :must_be_reasonable_positive_integer}} =
             Limits.new(max_diagnostic_bytes: 1)
  end

  test "diagnostic accounting includes JSON escaping overhead" do
    assert Validation.bounded_json_object?(%{"stage" => "\""}, 15, 4, 2)
    refute Validation.bounded_json_object?(%{"stage" => "\""}, 14, 4, 2)

    assert Validation.bounded_json_object?(%{"stage" => "\n"}, 19, 4, 2)
    refute Validation.bounded_json_object?(%{"stage" => "\n"}, 18, 4, 2)
  end

  test "content-bearing contracts and Fake owner state redact recognizable synthetic secrets" do
    secret = "sk-proj-FAKE_WORKSPACE_SECRET_123456789"
    {:ok, access} = Access.new(read: true, write: true, exec: true)
    {:ok, revision} = Revision.from_mac(:binary.copy(<<42>>, 32))
    {:ok, context} = OperationContext.new(operation_id: "redaction", access: access)
    {:ok, read_request} = ReadRequest.new(path: "secret.txt")
    {:ok, line} = ReadLine.new(number: 1, text: secret, ending: :none, truncated: false)

    {:ok, read_result} =
      ReadResult.new(
        path: read_request.path,
        revision: revision,
        lines: [line],
        next_line: nil,
        file_bytes: byte_size(secret)
      )

    {:ok, write_request} =
      WriteRequest.new(path: "secret.txt", content: secret, expected_revision: revision)

    {:ok, edit_request} =
      EditRequest.new(
        path: "secret.txt",
        old_text: secret,
        new_text: "replacement",
        expected_revision: revision
      )

    {:ok, spec} =
      ProcessSpec.new(executable: "/usr/bin/printf", arguments: [secret], mutation: :read_only)

    output_event = %ProcessEvent.Output{
      operation_id: context.operation_id,
      sequence: 1,
      data: secret
    }

    {:ok, process_result} =
      ProcessResult.new(
        operation_id: context.operation_id,
        termination: :exited,
        exit_code: 0,
        output: secret,
        output_bytes: byte_size(secret),
        truncated: false,
        elapsed_ms: 0
      )

    {:ok, error} =
      Error.new(
        kind: :io,
        reason: :io,
        operation: :read,
        message: secret,
        outcome: :not_applicable,
        details: %{"stage" => secret}
      )

    values = [
      line,
      read_result,
      write_request,
      edit_request,
      spec,
      output_event,
      process_result,
      error
    ]

    Enum.each(values, fn value -> refute inspect(value) =~ secret end)

    entry = Fake.expect_read(read_request, context, {:ok, read_result})
    refute inspect(entry) =~ secret
    assert {:ok, handle} = Fake.open([entry])
    assert inspect(:sys.get_state(handle.state)) == "#Synapse.Workspace.Fake.Server<redacted>"

    log = capture_log(fn -> Logger.warning("workspace value: #{inspect(entry)}") end)
    refute log =~ secret
    assert :ok = Workspace.close(handle)
  end

  test "Fake bounds retained script entries" do
    {:ok, limits} = Limits.new(max_fake_script_entries: 1)
    {:ok, access} = Access.new(read: true, write: true, exec: true)
    {:ok, context} = OperationContext.new(operation_id: "script-bound", access: access)
    {:ok, request} = ReadRequest.new(path: "bounded.txt")
    {:ok, revision} = Revision.from_mac(:binary.copy(<<7>>, 32))
    {:ok, line} = ReadLine.new(number: 1, text: "value", ending: :none, truncated: false)

    {:ok, result} =
      ReadResult.new(
        path: request.path,
        revision: revision,
        lines: [line],
        next_line: nil,
        file_bytes: 5
      )

    entry = Fake.expect_read(request, context, {:ok, result})
    assert {:error, :invalid_script} = Fake.open([entry, entry], limits: limits)
    assert {:error, :invalid_options} = Fake.open([], [{:limits, limits} | :improper])
  end

  test "Fake bounds nested process-event scripts before traversal" do
    {:ok, limits} = Limits.new(max_process_events: 1)
    {:ok, access} = Access.new(read: true, write: true, exec: true)
    {:ok, context} = OperationContext.new(operation_id: "event-bound", access: access)
    {:ok, spec} = ProcessSpec.new(executable: "/usr/bin/true", mutation: :read_only)
    started = %ProcessEvent.Started{operation_id: context.operation_id}
    output = %ProcessEvent.Output{operation_id: context.operation_id, sequence: 1, data: "x"}

    {:ok, result} =
      ProcessResult.new(
        operation_id: context.operation_id,
        termination: :exited,
        exit_code: 0,
        output: "x",
        output_bytes: 1,
        truncated: false,
        elapsed_ms: 0
      )

    entry = Fake.expect_run(spec, context, [started, output], {:ok, result})
    assert {:error, :invalid_script} = Fake.open([entry], limits: limits)
  end

  test "Fake bounds active operations without consuming the next entry" do
    test_pid = self()
    {:ok, limits} = Limits.new(max_concurrent_operations: 1)
    {:ok, access} = Access.new(read: true, write: true, exec: true)
    {:ok, run_context} = OperationContext.new(operation_id: "active-run", access: access)
    {:ok, read_context} = OperationContext.new(operation_id: "after-active", access: access)

    {:ok, spec} =
      ProcessSpec.new(executable: "/usr/bin/true", mutation: :read_only)

    started = %ProcessEvent.Started{operation_id: run_context.operation_id}

    {:ok, run_result} =
      ProcessResult.new(
        operation_id: run_context.operation_id,
        termination: :exited,
        exit_code: 0,
        output: "",
        output_bytes: 0,
        truncated: false,
        elapsed_ms: 0
      )

    {:ok, read_request} = ReadRequest.new(path: "after.txt")
    {:ok, revision} = Revision.from_mac(:binary.copy(<<8>>, 32))
    {:ok, line} = ReadLine.new(number: 1, text: "after", ending: :none, truncated: false)

    {:ok, read_result} =
      ReadResult.new(
        path: read_request.path,
        revision: revision,
        lines: [line],
        next_line: nil,
        file_bytes: 5
      )

    script = [
      Fake.expect_run(spec, run_context, [started], {:ok, run_result}),
      Fake.expect_read(read_request, read_context, {:ok, read_result})
    ]

    assert {:ok, handle} = Fake.open(script, limits: limits)

    task =
      Task.async(fn ->
        Workspace.run(
          handle,
          spec,
          fn event ->
            send(test_pid, {:active_fake_event, event, self()})

            receive do
              :release_active_fake -> :ok
            end
          end,
          run_context
        )
      end)

    assert_receive {:active_fake_event, ^started, sink_process}

    assert {:error, %Error{reason: :workspace_busy}} =
             Workspace.read(handle, read_request, read_context)

    assert {:ok, 1} = Fake.remaining_operations(handle)
    send(sink_process, :release_active_fake)
    assert {:ok, ^run_result} = Task.await(task)
    assert {:ok, ^read_result} = Workspace.read(handle, read_request, read_context)
    assert :ok = Workspace.close(handle)
  end
end
