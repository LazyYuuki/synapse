defmodule Synapse.Agent.ToolExecutionTest do
  use ExUnit.Case, async: true

  alias Synapse.Agent.{Context, OperationId, Runner}
  alias Synapse.Agent.Error, as: AgentError
  alias Synapse.Provider.Fake, as: ProviderFake
  alias Synapse.Provider.{Response}
  alias Synapse.Provider.OutputItem.FunctionCall
  alias Synapse.Run.Event
  alias Synapse.Tool.{CapabilitySet, Limits}
  alias Synapse.Workspace

  alias Synapse.Workspace.{
    Access,
    EditRequest,
    Fake,
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

  alias Synapse.Workspace.Error, as: WorkspaceError

  setup do
    Process.put(:agent_tool_deadline, System.monotonic_time(:millisecond) + 60_000)
    :ok
  end

  test "executes one Read under the exact trusted Tool Context" do
    test_pid = self()
    run = run_request()
    {:ok, operation_id} = OperationId.tool(run.id, 1, 1)
    cancel_ref = make_ref()
    deadline = System.monotonic_time(:millisecond) + 60_000

    activity_sink = fn operation_context ->
      send(test_pid, {:tool_activity, operation_context})
      :ok
    end

    expected_context =
      operation_context(operation_id, :read,
        cancel_ref: cancel_ref,
        deadline: deadline,
        activity_sink: activity_sink
      )

    response =
      response!("response-read", [
        call("item-read", "call-read", "read", %{
          "path" => "read.txt",
          "offset" => nil,
          "limit" => nil
        })
      ])

    entries = [
      Fake.expect_read(
        read_request("read.txt"),
        expected_context,
        {:ok, read_result("read.txt", revision(1), "hello")}
      )
    ]

    sink = event_sink(test_pid)

    assert {{:error, %AgentError{reason: :provider_failed}}, {:ok, 0}, _provider_id} =
             run_with(run, response, entries, sink,
               cancel_ref: cancel_ref,
               deadline: deadline,
               tool_activity_sink: activity_sink
             )

    assert_receive {:run_event,
                    %Event.ToolStarted{
                      run_id: run_id,
                      turn: 1,
                      operation_id: ^operation_id,
                      call_id: "call-read",
                      name: "read",
                      ordinal: 1
                    }}

    assert run_id == run.id

    assert_receive {:run_event,
                    %Event.ToolCompleted{
                      operation_id: ^operation_id,
                      call_id: "call-read",
                      name: "read",
                      ordinal: 1,
                      status: :ok,
                      metadata: %{"tool" => "read", "outcome" => "completed"}
                    }}

    assert_receive {:tool_activity, %OperationContext{operation_id: ^operation_id}}
  end

  test "executes Read, Write, Edit, and Bash sequentially in Response source order" do
    test_pid = self()
    run = run_request()
    old_revision = revision(1)
    new_revision = revision(2)
    edit_revision = revision(3)
    edited_revision = revision(4)

    operation_ids = Map.new(1..4, fn ordinal -> {ordinal, tool_operation_id(run, ordinal)} end)

    calls = [
      call("item-read", "call-read", "read", %{
        "path" => "read.txt",
        "offset" => nil,
        "limit" => nil
      }),
      call("item-write", "call-write", "write", %{
        "path" => "created.txt",
        "content" => "new",
        "expected_revision" => "missing"
      }),
      call("item-edit", "call-edit", "edit", %{
        "path" => "edit.txt",
        "old_text" => "old",
        "new_text" => "new",
        "expected_revision" => Revision.encode(edit_revision)
      }),
      call("item-bash", "call-bash", "bash", %{
        "command" => "printf ok",
        "timeout_ms" => nil
      })
    ]

    entries = [
      Fake.expect_read(
        read_request("read.txt"),
        operation_context(operation_ids[1], :read),
        {:ok, read_result("read.txt", old_revision, "old")}
      ),
      Fake.expect_write(
        write_request("created.txt", "new", :missing),
        operation_context(operation_ids[2], :write),
        {:ok, mutation_result(operation_ids[2], "created.txt", :missing, new_revision, 3)}
      ),
      Fake.expect_edit(
        edit_request("edit.txt", "old", "new", edit_revision),
        operation_context(operation_ids[3], :write),
        {:ok, mutation_result(operation_ids[3], "edit.txt", edit_revision, edited_revision, 3)}
      ),
      Fake.expect_run(
        process_spec("printf ok"),
        operation_context(operation_ids[4], :exec),
        process_events(operation_ids[4], "ok"),
        {:ok, process_result(operation_ids[4], 0, "ok")}
      )
    ]

    assert {{:error, %AgentError{reason: :provider_failed}}, {:ok, 0}, _provider_id} =
             run_with(run, response!("response-all-tools", calls), entries, event_sink(test_pid))

    expected = [
      {"call-read", "read", 1},
      {"call-write", "write", 2},
      {"call-edit", "edit", 3},
      {"call-bash", "bash", 4}
    ]

    Enum.each(expected, fn {call_id, name, ordinal} ->
      operation_id = operation_ids[ordinal]

      assert_receive {:run_event,
                      %Event.ToolStarted{
                        operation_id: ^operation_id,
                        call_id: ^call_id,
                        name: ^name,
                        ordinal: ^ordinal
                      }}

      assert_receive {:run_event,
                      %Event.ToolCompleted{
                        operation_id: ^operation_id,
                        call_id: ^call_id,
                        name: ^name,
                        ordinal: ^ordinal,
                        status: :ok,
                        metadata: %{"tool" => ^name, "outcome" => "completed"}
                      }}
    end)

    assert Enum.uniq(Map.values(operation_ids)) |> length() == 4
    refute Enum.any?(Map.values(operation_ids), &(&1 in Enum.map(calls, fn call -> call.id end)))

    refute Enum.any?(
             Map.values(operation_ids),
             &(&1 in Enum.map(calls, fn call -> call.call_id end))
           )
  end

  test "unknown, invalid, and denied calls remain paired and do not stop later calls" do
    test_pid = self()
    capabilities = capabilities(fs_read: true, fs_write: false, process_exec: false)
    run = run_request(capabilities: capabilities)
    read_operation_id = tool_operation_id(run, 4)

    calls = [
      call("item-unknown", "call-unknown", "not_registered", %{}),
      call("item-invalid", "call-invalid", "read", %{"path" => "missing-fields.txt"}),
      call("item-denied", "call-denied", "bash", %{"command" => "true", "timeout_ms" => nil}),
      call("item-read", "call-read", "read", %{
        "path" => "after.txt",
        "offset" => nil,
        "limit" => nil
      })
    ]

    entries = [
      Fake.expect_read(
        read_request("after.txt"),
        operation_context(read_operation_id, :read),
        {:ok, read_result("after.txt", revision(1), "after")}
      )
    ]

    assert {{:error, %AgentError{reason: :provider_failed}}, {:ok, 0}, _provider_id} =
             run_with(
               run,
               response!("response-paired-errors", calls),
               entries,
               event_sink(test_pid)
             )

    assert_tool_completions([
      {"call-unknown", 1, :error},
      {"call-invalid", 2, :error},
      {"call-denied", 3, :error},
      {"call-read", 4, :ok}
    ])
  end

  test "stale Write and natural Bash failure remain paired before a later Read" do
    test_pid = self()
    run = run_request()
    stale_revision = revision(1)
    write_operation_id = tool_operation_id(run, 1)
    bash_operation_id = tool_operation_id(run, 2)
    read_operation_id = tool_operation_id(run, 3)

    calls = [
      call("item-write", "call-write", "write", %{
        "path" => "stale.txt",
        "content" => "new",
        "expected_revision" => Revision.encode(stale_revision)
      }),
      call("item-bash", "call-bash", "bash", %{"command" => "exit 7", "timeout_ms" => nil}),
      call("item-read", "call-read", "read", %{
        "path" => "after.txt",
        "offset" => nil,
        "limit" => nil
      })
    ]

    stale =
      workspace_error(
        :conflict,
        :stale_revision,
        :not_applied,
        :write,
        write_operation_id,
        "stale.txt"
      )

    entries = [
      Fake.expect_write(
        write_request("stale.txt", "new", stale_revision),
        operation_context(write_operation_id, :write),
        {:error, stale}
      ),
      Fake.expect_run(
        process_spec("exit 7"),
        operation_context(bash_operation_id, :exec),
        process_events(bash_operation_id, "failed"),
        {:ok, process_result(bash_operation_id, 7, "failed")}
      ),
      Fake.expect_read(
        read_request("after.txt"),
        operation_context(read_operation_id, :read),
        {:ok, read_result("after.txt", revision(2), "after")}
      )
    ]

    assert {{:error, %AgentError{reason: :provider_failed}}, {:ok, 0}, _provider_id} =
             run_with(
               run,
               response!("response-ordinary-failures", calls),
               entries,
               event_sink(test_pid)
             )

    assert_tool_completions([
      {"call-write", 1, :error},
      {"call-bash", 2, :error},
      {"call-read", 3, :ok}
    ])
  end

  test "ambiguous Write is retained while later Tool calls continue" do
    test_pid = self()
    run = run_request()
    write_operation_id = tool_operation_id(run, 1)
    bash_operation_id = tool_operation_id(run, 2)

    calls = [
      call("item-write", "call-write", "write", %{
        "path" => "maybe.txt",
        "content" => "recognizable-secret-content",
        "expected_revision" => "missing"
      }),
      call("item-bash", "call-bash", "bash", %{
        "command" => "printf must-not-run",
        "timeout_ms" => nil
      })
    ]

    ambiguous =
      workspace_error(
        :ambiguous,
        :durability_unknown,
        :unknown,
        :write,
        write_operation_id,
        "maybe.txt"
      )

    entries = [
      Fake.expect_write(
        write_request("maybe.txt", "recognizable-secret-content", :missing),
        operation_context(write_operation_id, :write),
        {:error, ambiguous}
      ),
      Fake.expect_run(
        process_spec("printf must-not-run"),
        operation_context(bash_operation_id, :exec),
        process_events(bash_operation_id, "must-not-run"),
        {:ok, process_result(bash_operation_id, 0, "must-not-run")}
      )
    ]

    assert {{:error, %AgentError{kind: :provider, reason: :provider_failed}}, {:ok, 0},
            _provider_id} =
             run_with(
               run,
               response!("response-write-ambiguity", calls),
               entries,
               event_sink(test_pid)
             )

    assert_receive {:run_event,
                    %Event.ToolCompleted{
                      call_id: "call-write",
                      status: :ambiguous,
                      metadata: %{"tool" => "write", "outcome" => "unknown"}
                    }}

    assert_receive {:run_event, %Event.ToolStarted{call_id: "call-bash"}}
    assert_receive {:run_event, %Event.ToolCompleted{call_id: "call-bash", status: :ok}}
  end

  test "ambiguous Bash is retained while later Tool calls continue" do
    test_pid = self()
    run = run_request()
    bash_operation_id = tool_operation_id(run, 1)
    read_operation_id = tool_operation_id(run, 2)

    calls = [
      call("item-bash", "call-bash", "bash", %{"command" => "mutate", "timeout_ms" => nil}),
      call("item-read", "call-read", "read", %{
        "path" => "must-not-read.txt",
        "offset" => nil,
        "limit" => nil
      })
    ]

    ambiguous =
      workspace_error(
        :ambiguous,
        :output_limit,
        :unknown,
        :run,
        bash_operation_id,
        nil
      )

    entries = [
      Fake.expect_run(
        process_spec("mutate"),
        operation_context(bash_operation_id, :exec),
        [],
        {:error, ambiguous}
      ),
      Fake.expect_read(
        read_request("must-not-read.txt"),
        operation_context(read_operation_id, :read),
        {:ok, read_result("must-not-read.txt", revision(1), "never")}
      )
    ]

    assert {{:error, %AgentError{kind: :provider, reason: :provider_failed}}, {:ok, 0},
            _provider_id} =
             run_with(
               run,
               response!("response-bash-ambiguity", calls),
               entries,
               event_sink(test_pid)
             )

    assert_receive {:run_event, %Event.ToolStarted{call_id: "call-read"}}
    assert_receive {:run_event, %Event.ToolCompleted{call_id: "call-read", status: :ok}}
  end

  test "event sink failure before ToolStarted executes nothing" do
    test_pid = self()
    run = run_request()
    operation_id = tool_operation_id(run, 1)
    response = read_response("response-start-rejection", "call-read", "never.txt")

    entries = [
      Fake.expect_read(
        read_request("never.txt"),
        operation_context(operation_id, :read),
        {:ok, read_result("never.txt", revision(1), "never")}
      )
    ]

    sink = fn
      %Event.ToolStarted{} = event ->
        send(test_pid, {:rejected_event, event})
        {:error, :closed}

      event ->
        send(test_pid, {:run_event, event})
        :ok
    end

    assert {{:error, %AgentError{reason: :event_sink_failed}}, {:ok, 1}, _provider_id} =
             run_with(run, response, entries, sink)

    refute_received {:run_event, %Event.ToolCompleted{}}
  end

  test "event sink failure after a known Result starts no later Tool" do
    test_pid = self()
    run = run_request()
    first_operation_id = tool_operation_id(run, 1)
    second_operation_id = tool_operation_id(run, 2)

    response =
      response!("response-completion-rejection", [
        read_call("item-first", "call-first", "first.txt"),
        read_call("item-second", "call-second", "second.txt")
      ])

    entries = [
      Fake.expect_read(
        read_request("first.txt"),
        operation_context(first_operation_id, :read),
        {:ok, read_result("first.txt", revision(1), "first")}
      ),
      Fake.expect_read(
        read_request("second.txt"),
        operation_context(second_operation_id, :read),
        {:ok, read_result("second.txt", revision(2), "second")}
      )
    ]

    sink = fn
      %Event.ToolCompleted{} = event ->
        send(test_pid, {:rejected_event, event})
        {:error, :closed}

      event ->
        send(test_pid, {:run_event, event})
        :ok
    end

    assert {{:error, %AgentError{reason: :event_sink_failed}}, {:ok, 1}, _provider_id} =
             run_with(run, response, entries, sink)

    assert_received {:rejected_event, %Event.ToolCompleted{call_id: "call-first"}}
    refute_received {:run_event, %Event.ToolStarted{call_id: "call-second"}}
  end

  test "invalid trusted Agent Context is rejected before Provider or Workspace activity" do
    run = run_request()
    response = read_response("response-invalid-context", "call-read", "never.txt")
    provider_operation_id = provider_operation_id(run)
    tool_operation_id = tool_operation_id(run, 1)

    entries = [
      Fake.expect_read(
        read_request("never.txt"),
        operation_context(tool_operation_id, :read),
        {:ok, read_result("never.txt", revision(1), "never")}
      )
    ]

    {:ok, workspace} = Fake.open(entries)

    try do
      {:ok, context} =
        Context.new(
          provider: ProviderFake,
          workspace: workspace,
          event_sink: fn _event -> :ok end
        )

      forged = %{context | tool_limits: %{Limits.default() | max_operation_id_bytes: 1}}

      ProviderFake.with_script(provider_operation_id, [{:turn, [], {:ok, response}}], fn ->
        assert {:error, %AgentError{reason: :invalid_agent_context}} = Runner.run(run, forged)
        assert {:ok, 1} = ProviderFake.remaining_turns(provider_operation_id)
        assert {:ok, 1} = Fake.remaining_operations(workspace)
      end)
    after
      Workspace.close(workspace)
    end
  end

  test "Runner handles the Executor admission-mismatch branch as an internal contract failure" do
    source = File.read!(Path.expand("../lib/synapse/agent/runner.ex", __DIR__))
    assert source =~ "{:error, :invalid_call}"
    assert source =~ ":tool_executor_contract_failed"
  end

  test "Runner uses Executor but calls no Workspace facade directly" do
    source = File.read!(Path.expand("../lib/synapse/agent/runner.ex", __DIR__))
    assert source =~ "Executor.execute"

    for forbidden <- ["Workspace.read", "Workspace.write", "Workspace.edit", "Workspace.run"] do
      refute source =~ forbidden
    end
  end

  defp run_with(run, response, entries, sink, context_options \\ []) do
    {:ok, workspace} = Fake.open(entries)
    provider_operation_id = provider_operation_id(run)

    try do
      attributes =
        Keyword.merge(
          [
            provider: ProviderFake,
            workspace: workspace,
            event_sink: sink,
            deadline: Process.get(:agent_tool_deadline)
          ],
          context_options
        )

      {:ok, context} = Context.new(attributes)

      ProviderFake.with_script(provider_operation_id, [{:turn, [], {:ok, response}}], fn ->
        result = Runner.run(run, context)
        {result, Fake.remaining_operations(workspace), provider_operation_id}
      end)
    after
      Workspace.close(workspace)
    end
  end

  defp event_sink(test_pid) do
    fn event ->
      send(test_pid, {:run_event, event})
      :ok
    end
  end

  defp assert_tool_completions(expected) do
    Enum.each(expected, fn {call_id, ordinal, status} ->
      assert_receive {:run_event,
                      %Event.ToolCompleted{
                        call_id: ^call_id,
                        ordinal: ^ordinal,
                        status: ^status
                      }}
    end)
  end

  defp run_request(options \\ []) do
    capabilities = Keyword.get(options, :capabilities, capabilities())
    budget = Keyword.get(options, :budget, Synapse.Budget.default())

    {:ok, run} =
      Synapse.Run.Request.new(
        id: "run-execution-#{System.unique_integer([:positive, :monotonic])}",
        prompt: "Execute calls",
        cwd: "/tmp/project",
        model: "test-model",
        capabilities: capabilities,
        budget: budget
      )

    run
  end

  defp capabilities(options \\ []) do
    {:ok, capabilities} =
      CapabilitySet.new(
        fs_read: Keyword.get(options, :fs_read, true),
        fs_write: Keyword.get(options, :fs_write, true),
        process_exec: Keyword.get(options, :process_exec, true)
      )

    capabilities
  end

  defp response!(id, calls) do
    {:ok, response} = Response.new(id: id, model: "test-model", output_items: calls)
    response
  end

  defp read_response(id, call_id, path),
    do: response!(id, [read_call("item-#{call_id}", call_id, path)])

  defp read_call(id, call_id, path) do
    call(id, call_id, "read", %{"path" => path, "offset" => nil, "limit" => nil})
  end

  defp call(id, call_id, name, arguments),
    do: %FunctionCall{id: id, call_id: call_id, name: name, arguments: arguments}

  defp provider_operation_id(run) do
    {:ok, operation_id} = OperationId.provider(run.id, 1, 1)
    operation_id
  end

  defp tool_operation_id(run, ordinal) do
    {:ok, operation_id} = OperationId.tool(run.id, 1, ordinal)
    operation_id
  end

  defp operation_context(operation_id, access, options \\ []) do
    access =
      case access do
        :read -> %Access{read: true, write: false, exec: false}
        :write -> %Access{read: false, write: true, exec: false}
        :exec -> %Access{read: false, write: false, exec: true}
      end

    attributes =
      Keyword.merge(
        [
          operation_id: operation_id,
          access: access,
          deadline: Process.get(:agent_tool_deadline)
        ],
        options
      )

    {:ok, context} = OperationContext.new(attributes)
    context
  end

  defp read_request(path) do
    limits = Limits.default()

    {:ok, request} =
      ReadRequest.new(
        path: path,
        start_line: 1,
        line_count: limits.default_read_lines,
        max_bytes: limits.default_read_source_bytes
      )

    request
  end

  defp write_request(path, content, expected_revision) do
    {:ok, request} =
      WriteRequest.new(
        path: path,
        content: content,
        expected_revision: expected_revision
      )

    request
  end

  defp edit_request(path, old_text, new_text, expected_revision) do
    {:ok, request} =
      EditRequest.new(
        path: path,
        old_text: old_text,
        new_text: new_text,
        expected_revision: expected_revision
      )

    request
  end

  defp process_spec(command) do
    limits = Limits.default()

    {:ok, spec} =
      ProcessSpec.new(
        executable: "/bin/bash",
        arguments: ["-lc", command],
        cwd: ".",
        inactivity_ms: limits.default_bash_inactivity_ms,
        timeout_ms: limits.default_bash_timeout_ms,
        max_output_bytes: limits.default_bash_output_bytes,
        mutation: :unknown
      )

    spec
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

  defp mutation_result(operation_id, path, previous, revision, bytes_written) do
    {:ok, result} =
      MutationResult.new(
        operation_id: operation_id,
        path: path,
        previous_revision: previous,
        revision: revision,
        bytes_written: bytes_written,
        changed: true,
        diff: "changed",
        diff_truncated: false
      )

    result
  end

  defp process_result(operation_id, exit_code, output) do
    {:ok, result} =
      ProcessResult.new(
        operation_id: operation_id,
        termination: :exited,
        exit_code: exit_code,
        output: output,
        output_bytes: byte_size(output),
        truncated: false,
        elapsed_ms: 1
      )

    result
  end

  defp process_events(operation_id, output) do
    {:ok, started} = ProcessEvent.Started.new(operation_id: operation_id)

    {:ok, event} =
      ProcessEvent.Output.new(operation_id: operation_id, sequence: 1, data: output)

    [started, event]
  end

  defp workspace_error(kind, reason, outcome, operation, operation_id, path) do
    {:ok, error} =
      WorkspaceError.new(
        kind: kind,
        reason: reason,
        operation: operation,
        message: "Workspace operation failed",
        operation_id: operation_id,
        path: path,
        outcome: outcome
      )

    error
  end

  defp revision(byte) do
    {:ok, revision} = Revision.from_mac(:binary.copy(<<byte>>, 32))
    revision
  end
end
