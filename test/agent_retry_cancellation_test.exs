defmodule Synapse.Agent.RetryCancellationTest do
  use ExUnit.Case, async: true

  alias Synapse.Agent.{Context, OperationId, Projection, Runner}
  alias Synapse.Agent.Error, as: AgentError
  alias Synapse.Provider.Response
  alias Synapse.Provider.Error, as: ProviderError
  alias Synapse.Provider.Event.{TextDelta, ToolCallStarted}
  alias Synapse.Provider.OutputItem.{FunctionCall, Message}
  alias Synapse.Run.Event
  alias Synapse.Tool.{CapabilitySet, Limits}
  alias Synapse.Workspace

  alias Synapse.Workspace.{
    Access,
    OperationContext,
    ProcessEvent,
    ProcessResult,
    ProcessSpec,
    Revision,
    WriteRequest
  }

  alias Synapse.Workspace.Fake, as: WorkspaceFake

  setup do
    Process.put(:retry_cancelled, false)
    Process.put(:retry_deadline, System.monotonic_time(:millisecond) + 60_000)
    :ok
  end

  test "retryable transport failure reuses the exact Request with a distinct operation ID" do
    test_pid = self()
    run = run_request(max_provider_retries: 1)
    operation_ids = provider_ids(run, 2)
    final_response = text_response("response-retry-final", "Recovered")

    assert {{:ok, result}, [0, 0], events} =
             run_provider(
               run,
               operation_ids,
               fn context ->
                 expected = initial_request(run, context)

                 [
                   {:turn, expected, [],
                    {:error, provider_error(Enum.at(operation_ids, 0), :transport, true, false)}},
                   {:turn, expected, [], {:ok, final_response}}
                 ]
               end,
               event_sink: event_sink(test_pid),
               retry_delay: fn ordinal ->
                 send(test_pid, {:retry_delay, ordinal})
                 0
               end
             )

    assert result.turns == 1
    assert result.provider_retries == 1
    assert_receive {:retry_delay, 1}
    assert Enum.count(events, &match?(%Event.TurnStarted{}, &1)) == 1

    assert [%Event.TurnCompleted{provider_attempts: 2}] =
             Enum.filter(events, &match?(%Event.TurnCompleted{}, &1))

    assert Enum.at(operation_ids, 0) != Enum.at(operation_ids, 1)
  end

  test "two safe failures succeed at the exact retry limit" do
    test_pid = self()
    run = run_request(max_provider_retries: 2)
    operation_ids = provider_ids(run, 3)

    script = [
      {:turn, [], {:error, provider_error(Enum.at(operation_ids, 0), :unavailable, true, false)}},
      {:turn, [],
       {:error, provider_error(Enum.at(operation_ids, 1), :rate_limited, true, false)}},
      {:turn, [], {:ok, text_response("response-two-retries", "Succeeded")}}
    ]

    assert {{:ok, result}, [0, 0, 0], _events} =
             run_provider(run, operation_ids, fn _context -> script end,
               retry_delay: fn ordinal ->
                 send(test_pid, {:retry_delay, ordinal})
                 0
               end
             )

    assert result.turns == 1
    assert result.provider_retries == 2
    assert_receive {:retry_delay, 1}
    assert_receive {:retry_delay, 2}
  end

  test "retry exhaustion returns the final safe Provider classification" do
    run = run_request(max_provider_retries: 2)
    operation_ids = provider_ids(run, 3)

    script =
      Enum.with_index(operation_ids, 1)
      |> Enum.map(fn {operation_id, index} ->
        {:turn, [],
         {:error, provider_error(operation_id, :transport, true, false, "failure #{index}")}}
      end)

    assert {{:error, error}, [0, 0, 0], events} =
             run_provider(run, operation_ids, fn _context -> script end,
               retry_delay: fn _ -> 0 end
             )

    assert %AgentError{
             kind: :provider,
             reason: :provider_retry_exhausted,
             details: %{
               "provider_kind" => "transport",
               "retryable" => true,
               "output_started" => false,
               "attempts" => 3
             }
           } = error

    assert Enum.any?(events, &match?(%Event.RunFailed{}, &1))
    refute Enum.any?(events, &match?(%Event.RunInterrupted{}, &1))
  end

  test "cancellation during retry wait starts no second attempt" do
    run = run_request(max_provider_retries: 1)
    operation_ids = provider_ids(run, 2)
    cancel_ref = make_ref()

    script = [
      {:turn, [], {:error, provider_error(Enum.at(operation_ids, 0), :transport, true, false)}},
      {:turn, [], {:ok, text_response("response-must-not-run", "never")}}
    ]

    retry_delay = fn _ordinal ->
      Process.put(:retry_cancelled, true)
      send(self(), {:cancel, cancel_ref})
      10_000
    end

    assert {{:error, %AgentError{kind: :cancelled, reason: :run_cancelled}}, [1, 1], events} =
             run_provider(run, operation_ids, fn _context -> script end,
               cancel_ref: cancel_ref,
               cancelled?: fn -> Process.get(:retry_cancelled, false) end,
               retry_delay: retry_delay
             )

    assert Enum.count(events, &match?(%Event.TurnStarted{}, &1)) == 1
  end

  test "retry delay that reaches the deadline fails without waiting or retrying" do
    run = run_request(max_provider_retries: 1)
    operation_ids = provider_ids(run, 2)

    script = [
      {:turn, [], {:error, provider_error(Enum.at(operation_ids, 0), :transport, true, false)}},
      {:turn, [], {:ok, text_response("response-after-deadline", "never")}}
    ]

    assert {{:error, %AgentError{reason: :wall_time_budget_exhausted}}, [1, 1], _events} =
             run_provider(run, operation_ids, fn _context -> script end,
               deadline: System.monotonic_time(:millisecond) + 5_000,
               retry_delay: fn _ -> 10_000 end
             )
  end

  test "non-retryable and policy-forbidden Provider failures do not retry" do
    for {kind, retryable} <- [
          {:configuration, true},
          {:authentication, true},
          {:authorization, true},
          {:protocol, true},
          {:interrupted, true},
          {:transport, false}
        ] do
      run = run_request(max_provider_retries: 2)
      [operation_id] = provider_ids(run, 1)
      provider_error = provider_error(operation_id, kind, retryable, false)

      assert {{:error, %AgentError{reason: :provider_failed}}, [0], _events} =
               run_provider(run, [operation_id], fn _context ->
                 [{:turn, [], {:error, provider_error}}]
               end)
    end
  end

  test "TextDelta and ToolCall progress make retryable failures terminal and execute nothing" do
    for {_label, progress} <- [
          {"text", %TextDelta{item_id: "message-partial", content_index: 0, delta: "partial"}},
          {"tool",
           %ToolCallStarted{
             item_id: "item-partial",
             call_id: "call-partial",
             name: "write"
           }}
        ] do
      run = run_request(max_provider_retries: 2)
      [operation_id] = provider_ids(run, 1)
      provider_error = provider_error(operation_id, :transport, true, true)
      {:ok, workspace} = Workspace.Fake.open([])

      try do
        {:ok, context} =
          Context.new(
            provider: Synapse.Provider.Fake,
            workspace: workspace,
            event_sink: fn _event -> :ok end
          )

        Synapse.Provider.Fake.with_script(
          operation_id,
          [{:turn, [progress], {:error, provider_error}}],
          fn ->
            assert {:error, %AgentError{reason: :provider_interrupted_after_output}} =
                     Runner.run(run, context)

            assert {:ok, 0} = Workspace.Fake.remaining_operations(workspace)
          end
        )
      after
        Workspace.close(workspace)
      end
    end
  end

  test "cancellation before the first turn starts no Provider operation" do
    run = run_request()
    [operation_id] = provider_ids(run, 1)
    response = text_response("response-cancelled-first", "never")

    assert {{:error, %AgentError{kind: :cancelled, reason: :run_cancelled}}, [1], events} =
             run_provider(
               run,
               [operation_id],
               fn _context ->
                 [{:turn, [], {:ok, response}}]
               end,
               cancelled?: fn -> true end
             )

    refute Enum.any?(events, &match?(%Event.TurnStarted{}, &1))
    assert Enum.any?(events, &match?(%Event.RunInterrupted{}, &1))
  end

  test "persistent cancellation remains after Provider consumes its matching message" do
    run = run_request()
    [operation_id] = provider_ids(run, 1)
    cancel_ref = make_ref()
    test_pid = self()

    sink = fn
      %Event.TextDelta{} ->
        Process.put(:retry_cancelled, true)
        send(self(), {:cancel, cancel_ref})
        send(test_pid, :cancel_sent)
        :ok

      _event ->
        :ok
    end

    assert {{:error, %AgentError{kind: :cancelled, reason: :run_cancelled}}, [0], _events} =
             run_provider(
               run,
               [operation_id],
               fn _context ->
                 response = text_response("response-cancel-provider", "never")

                 [
                   {:turn, [%TextDelta{item_id: "partial", content_index: 0, delta: "x"}],
                    {:ok, response}}
                 ]
               end,
               cancel_ref: cancel_ref,
               cancelled?: fn -> Process.get(:retry_cancelled, false) end,
               event_sink: sink
             )

    assert_receive :cancel_sent
    assert Process.get(:retry_cancelled)
    refute_received {:cancel, ^cancel_ref}
  end

  test "cancellation during a known-not-applied Tool returns interrupted and starts no next Provider" do
    run = run_request()
    [provider_id] = provider_ids(run, 1)
    tool_id = tool_id(run, 1, 1)
    stale_revision = revision(1)
    call = write_call("item-write", "call-write", "stale.txt", "new", stale_revision)

    stale =
      workspace_error(
        :conflict,
        :stale_revision,
        :not_applied,
        :write,
        tool_id,
        "stale.txt"
      )

    entry =
      WorkspaceFake.expect_write(
        write_request("stale.txt", "new", stale_revision),
        operation_context(tool_id, :write),
        {:error, stale}
      )

    sink = cancel_on_tool_started()

    assert {{:error, %AgentError{kind: :cancelled, reason: :run_cancelled}}, {:ok, 0}, events} =
             run_tool_case(
               run,
               provider_id,
               response!("response-cancel-tool", [call]),
               [entry],
               sink
             )

    assert Enum.any?(events, &match?(%Event.ToolCompleted{status: :error}, &1))
    assert Enum.any?(events, &match?(%Event.RunInterrupted{}, &1))
    refute Enum.any?(events, &match?(%Event.TurnStarted{turn: 2}, &1))
  end

  test "cancellation with ambiguous Tool outcome remains interrupted with ambiguity evidence" do
    run = run_request()
    [provider_id] = provider_ids(run, 1)
    write_id = tool_id(run, 1, 1)
    bash_id = tool_id(run, 1, 2)

    calls = [
      call("item-write", "call-write", "write", %{
        "path" => "maybe.txt",
        "content" => "value",
        "expected_revision" => "missing"
      }),
      call("item-bash", "call-bash", "bash", %{"command" => "never", "timeout_ms" => nil})
    ]

    ambiguous =
      workspace_error(
        :ambiguous,
        :durability_unknown,
        :unknown,
        :write,
        write_id,
        "maybe.txt"
      )

    entries = [
      WorkspaceFake.expect_write(
        write_request("maybe.txt", "value", :missing),
        operation_context(write_id, :write),
        {:error, ambiguous}
      ),
      WorkspaceFake.expect_run(
        process_spec("never"),
        operation_context(bash_id, :exec),
        [started_event(bash_id)],
        {:ok, process_result(bash_id)}
      )
    ]

    assert {{:error, error}, {:ok, 1}, events} =
             run_tool_case(
               run,
               provider_id,
               response!("response-cancel-ambiguous", calls),
               entries,
               cancel_on_tool_started()
             )

    assert %AgentError{
             kind: :cancelled,
             reason: :run_cancelled,
             details: %{
               "call_id" => "call-write",
               "tool_name" => "write",
               "outcome" => "unknown",
               "status" => "ambiguous"
             }
           } = error

    assert Enum.any?(events, &match?(%Event.RunInterrupted{}, &1))
    refute Enum.any?(events, &match?(%Event.ToolStarted{call_id: "call-bash"}, &1))
  end

  defp run_provider(run, operation_ids, script_builder, options \\ []) do
    {:ok, workspace} = Workspace.Fake.open([])
    test_pid = self()

    try do
      attributes =
        Keyword.merge(
          [
            provider: Synapse.Provider.Fake,
            workspace: workspace,
            event_sink: event_sink(test_pid),
            retry_delay: fn _ -> 0 end
          ],
          options
        )

      {:ok, context} = Context.new(attributes)
      script = script_builder.(context)

      Synapse.Provider.Fake.with_script(operation_ids, script, fn ->
        terminal = Runner.run(run, context)
        remaining = Enum.map(operation_ids, &elem(Synapse.Provider.Fake.remaining_turns(&1), 1))
        {terminal, remaining, collect_events([])}
      end)
    after
      Workspace.close(workspace)
    end
  end

  defp run_tool_case(run, provider_id, response, entries, sink) do
    {:ok, workspace} = Workspace.Fake.open(entries)

    try do
      {:ok, context} =
        Context.new(
          provider: Synapse.Provider.Fake,
          workspace: workspace,
          deadline: Process.get(:retry_deadline),
          cancelled?: fn -> Process.get(:retry_cancelled, false) end,
          event_sink: sink
        )

      Synapse.Provider.Fake.with_script(provider_id, [{:turn, [], {:ok, response}}], fn ->
        terminal = Runner.run(run, context)
        {terminal, Workspace.Fake.remaining_operations(workspace), collect_events([])}
      end)
    after
      Workspace.close(workspace)
    end
  end

  defp cancel_on_tool_started do
    test_pid = self()

    fn
      %Event.ToolStarted{} = event ->
        Process.put(:retry_cancelled, true)
        send(test_pid, {:run_event, event})
        :ok

      event ->
        send(test_pid, {:run_event, event})
        :ok
    end
  end

  defp initial_request(run, context) do
    {:ok, state} = Projection.initial_state(run, context, 0)
    {:ok, request} = Projection.provider_request(state, context)
    request
  end

  defp collect_events(events) do
    receive do
      {:run_event, event} -> collect_events([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp event_sink(test_pid) do
    fn event ->
      send(test_pid, {:run_event, event})
      :ok
    end
  end

  defp run_request(options \\ []) do
    {:ok, capabilities} =
      CapabilitySet.new(fs_read: true, fs_write: true, process_exec: true)

    {:ok, budget} = Synapse.Budget.new(options)

    {:ok, run} =
      Synapse.Run.Request.new(
        id: "run-retry-#{System.unique_integer([:positive, :monotonic])}",
        prompt: "Retry safely",
        cwd: "/tmp/project",
        model: "test-model",
        capabilities: capabilities,
        budget: budget
      )

    run
  end

  defp provider_error(operation_id, kind, retryable, output_started, message \\ "scripted") do
    {:ok, error} =
      ProviderError.new(
        kind: kind,
        message: message,
        retryable: retryable,
        output_started: output_started,
        operation_id: operation_id
      )

    error
  end

  defp provider_ids(run, count),
    do: Enum.map(1..count, fn attempt -> elem(OperationId.provider(run.id, 1, attempt), 1) end)

  defp tool_id(run, turn, ordinal), do: elem(OperationId.tool(run.id, turn, ordinal), 1)

  defp response!(id, output_items) do
    {:ok, response} = Response.new(id: id, model: "test-model", output_items: output_items)
    response
  end

  defp text_response(id, text),
    do: response!(id, [%Message{id: "message-#{id}", role: :assistant, content: text}])

  defp call(id, call_id, name, arguments),
    do: %FunctionCall{id: id, call_id: call_id, name: name, arguments: arguments}

  defp write_call(id, call_id, path, content, revision) do
    call(id, call_id, "write", %{
      "path" => path,
      "content" => content,
      "expected_revision" => Revision.encode(revision)
    })
  end

  defp operation_context(operation_id, access) do
    access =
      case access do
        :write -> %Access{read: false, write: true, exec: false}
        :exec -> %Access{read: false, write: false, exec: true}
      end

    {:ok, context} =
      OperationContext.new(
        operation_id: operation_id,
        access: access,
        deadline: Process.get(:retry_deadline)
      )

    context
  end

  defp write_request(path, content, expected_revision) do
    {:ok, request} =
      WriteRequest.new(path: path, content: content, expected_revision: expected_revision)

    request
  end

  defp workspace_error(kind, reason, outcome, operation, operation_id, path) do
    {:ok, error} =
      Workspace.Error.new(
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

  defp started_event(operation_id) do
    {:ok, event} = ProcessEvent.Started.new(operation_id: operation_id)
    event
  end

  defp process_result(operation_id) do
    {:ok, result} =
      ProcessResult.new(
        operation_id: operation_id,
        termination: :exited,
        exit_code: 0,
        output: "",
        output_bytes: 0,
        truncated: false,
        elapsed_ms: 1
      )

    result
  end

  defp revision(byte) do
    {:ok, revision} = Revision.from_mac(:binary.copy(<<byte>>, 32))
    revision
  end
end
