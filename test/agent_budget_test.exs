defmodule Synapse.Agent.BudgetTest do
  use ExUnit.Case, async: true

  alias Synapse.Agent.{Context, OperationId, Runner, State}
  alias Synapse.Agent.Error, as: AgentError
  alias Synapse.Provider.Response
  alias Synapse.Provider.Error, as: ProviderError
  alias Synapse.Provider.Event.TextDelta
  alias Synapse.Provider.OutputItem.{FunctionCall, Message}
  alias Synapse.Run.Event
  alias Synapse.Tool.{Call, CapabilitySet, Executor, Limits}
  alias Synapse.Tool.Context, as: ToolContext
  alias Synapse.Workspace

  alias Synapse.Workspace.{
    Access,
    Fake,
    OperationContext,
    ProcessEvent,
    ProcessResult,
    ProcessSpec
  }

  test "pure State transitions enforce exact counters and keep retries separate from turns" do
    budget = budget(max_turns: 2, max_tool_calls: 2, max_output_bytes: 5, max_provider_retries: 1)
    state = state(budget, 100, 1_000)
    assert state.deadline == 1_000

    assert {:ok, first_turn} = State.admit_turn(state, 101)
    assert {first_turn.turn, first_turn.tool_calls, first_turn.provider_retries} == {1, 0, 0}

    assert {:ok, second_turn} = State.admit_turn(first_turn, 102)
    assert second_turn.turn == 2
    assert {:error, :turn_budget_exhausted} = State.admit_turn(second_turn, 103)

    assert {:ok, first_tool} = State.admit_tool(first_turn, 102)
    assert {:ok, second_tool} = State.admit_tool(first_tool, 103)
    assert second_tool.tool_calls == 2
    assert {:error, :tool_call_budget_exhausted} = State.admit_tool(second_tool, 104)

    assert {:ok, retried} = State.admit_provider_retry(first_turn, 102)
    assert {retried.turn, retried.provider_retries} == {1, 1}

    assert {:error, :provider_retry_budget_exhausted} =
             State.admit_provider_retry(retried, 103)

    assert {:ok, exact_output} = State.add_output(first_turn, 5)
    assert exact_output.output_bytes == 5
    assert {:error, :output_budget_exhausted} = State.add_output(exact_output, 1)

    assert {:error, :counter_overflow} =
             State.add_output(first_turn, 9_223_372_036_854_775_808)
  end

  test "pure deadlines use the earlier Runtime value and expire exactly at the boundary" do
    state = state(budget(max_wall_time_ms: 100), 1_000, 1_050)
    assert state.deadline == 1_050
    assert State.deadline_open?(state, 1_049)
    refute State.deadline_open?(state, 1_050)

    assert {:ok, turn} = State.admit_turn(state, 1_049)
    assert {:error, :wall_time_budget_exhausted} = State.admit_turn(state, 1_050)
    assert {:ok, tool} = State.admit_tool(turn, 1_049)
    assert {:error, :wall_time_budget_exhausted} = State.admit_tool(tool, 1_050)

    budget_deadline = state(budget(max_wall_time_ms: 100), 1_000, :infinity)
    assert budget_deadline.deadline == 1_100
  end

  test "already elapsed effective deadline starts no Provider attempt" do
    run = run_request(budget())
    operation_id = provider_operation_id(run, 1)
    response = text_response("response-never", "never")
    test_pid = self()
    {:ok, workspace} = Workspace.Fake.open([])

    try do
      {:ok, context} =
        Context.new(
          provider: Synapse.Provider.Fake,
          workspace: workspace,
          deadline: System.monotonic_time(:millisecond) - 1,
          event_sink: event_sink(test_pid)
        )

      Synapse.Provider.Fake.with_script(operation_id, [{:turn, [], {:ok, response}}], fn ->
        assert {:error, %AgentError{kind: :budget, reason: :wall_time_budget_exhausted}} =
                 Runner.run(run, context)

        assert {:ok, 1} = Synapse.Provider.Fake.remaining_turns(operation_id)
      end)
    after
      Workspace.close(workspace)
    end

    refute_received {:run_event, %Event.TurnStarted{}}
    assert_received {:run_event, %Event.RunFailed{}}
  end

  test "provider final text succeeds at the exact output limit and fails one byte over" do
    for {label, text, expected} <- [
          {"exact", "12345", :ok},
          {"over", "123456", :output_budget_exhausted}
        ] do
      run = run_request(budget(max_output_bytes: 5))
      operation_id = provider_operation_id(run, 1)
      response = text_response("response-#{label}", text)

      {result, remaining, _events} =
        run_provider_script(run, [operation_id], [{:turn, [], {:ok, response}}])

      assert remaining == [0]

      case expected do
        :ok ->
          assert {:ok, agent_result} = result
          assert agent_result.output_bytes == 5

        :output_budget_exhausted ->
          assert {:error,
                  %AgentError{
                    kind: :budget,
                    reason: :output_budget_exhausted,
                    details: %{"observed" => 6, "maximum" => 5}
                  }} = result
      end
    end
  end

  test "Tool Result content succeeds at the exact aggregate limit and one byte over stops continuation" do
    provider_call = call("item-unknown", "call-unknown", "not_registered", %{})
    result = unknown_result(provider_call)
    provider_bytes = 2
    exact_limit = provider_bytes + byte_size(result.content)

    exact_run = run_request(budget(max_output_bytes: exact_limit))
    exact_ids = [provider_operation_id(exact_run, 1), provider_operation_id(exact_run, 2)]
    provider_error = provider_error(Enum.at(exact_ids, 1))

    {exact_terminal, exact_remaining, exact_events} =
      run_provider_script(exact_run, exact_ids, [
        {:turn, [], {:ok, response!("response-exact-result", [provider_call])}},
        {:turn, [], {:error, provider_error}}
      ])

    assert {:error, %AgentError{reason: :provider_failed}} = exact_terminal
    assert exact_remaining == [0, 0]
    assert Enum.any?(exact_events, &match?(%Event.TurnCompleted{outcome: :continued}, &1))

    over_run = run_request(budget(max_output_bytes: exact_limit - 1))
    [over_id] = [provider_operation_id(over_run, 1)]

    {over_terminal, over_remaining, over_events} =
      run_provider_script(over_run, [over_id], [
        {:turn, [], {:ok, response!("response-over-result", [provider_call])}}
      ])

    assert {:error,
            %AgentError{
              reason: :output_budget_exhausted,
              details: %{"observed" => ^exact_limit, "maximum" => maximum}
            }} = over_terminal

    assert maximum == exact_limit - 1
    assert over_remaining == [0]
    refute Enum.any?(over_events, &match?(%Event.TurnStarted{turn: 2}, &1))
  end

  test "aggregate Tool-call limit is exact across turns and the next batch executes nothing" do
    exact_run = run_request(budget(max_tool_calls: 2, max_turns: 3))
    exact_ids = Enum.map(1..3, &provider_operation_id(exact_run, &1))

    exact_script = [
      {:turn, [], {:ok, response!("response-call-1", [unknown_call("call-1")])}},
      {:turn, [], {:ok, response!("response-call-2", [unknown_call("call-2")])}},
      {:turn, [], {:ok, text_response("response-call-final", "done")}}
    ]

    {exact_terminal, [0, 0, 0], exact_events} =
      run_provider_script(exact_run, exact_ids, exact_script)

    assert {:ok, %{tool_calls: 2}} = exact_terminal
    assert Enum.count(exact_events, &match?(%Event.ToolStarted{}, &1)) == 2

    over_run = run_request(budget(max_tool_calls: 2, max_turns: 3))
    over_ids = Enum.map(1..3, &provider_operation_id(over_run, &1))

    over_script = [
      {:turn, [], {:ok, response!("response-over-call-1", [unknown_call("call-1")])}},
      {:turn, [], {:ok, response!("response-over-call-2", [unknown_call("call-2")])}},
      {:turn, [], {:ok, response!("response-over-call-3", [unknown_call("call-3")])}}
    ]

    {over_terminal, [0, 0, 0], over_events} =
      run_provider_script(over_run, over_ids, over_script)

    assert {:error,
            %AgentError{
              reason: :tool_call_budget_exhausted,
              details: %{"observed" => 3, "maximum" => 2}
            }} = over_terminal

    assert Enum.count(over_events, &match?(%Event.ToolStarted{}, &1)) == 2
  end

  test "Agent Budget lowers Provider and Bash inactivity without enlarging lower limits" do
    test_pid = self()
    budget = budget(provider_inactivity_ms: 7, tool_inactivity_ms: 11)
    run = run_request(budget)
    provider_ids = [provider_operation_id(run, 1), provider_operation_id(run, 2)]
    tool_id = tool_operation_id(run, 1, 1)
    deadline = System.monotonic_time(:millisecond) + 60_000

    bash_call =
      call("item-bash", "call-bash", "bash", %{"command" => "true", "timeout_ms" => nil})

    {:ok, started} = ProcessEvent.Started.new(operation_id: tool_id)

    {:ok, process_result} =
      ProcessResult.new(
        operation_id: tool_id,
        termination: :exited,
        exit_code: 0,
        output: "",
        output_bytes: 0,
        truncated: false,
        elapsed_ms: 1
      )

    {:ok, spec} =
      ProcessSpec.new(
        executable: "/bin/bash",
        arguments: ["-lc", "true"],
        cwd: ".",
        inactivity_ms: 11,
        timeout_ms: Limits.default().default_bash_timeout_ms,
        max_output_bytes: Limits.default().default_bash_output_bytes,
        mutation: :unknown
      )

    {:ok, workspace_context} =
      OperationContext.new(
        operation_id: tool_id,
        access: %Access{read: false, write: false, exec: true},
        deadline: deadline
      )

    entry = Fake.expect_run(spec, workspace_context, [started], {:ok, process_result})
    {:ok, workspace} = Fake.open([entry])

    provider_activity = fn stream_context ->
      send(test_pid, {:provider_context, stream_context})
      :ok
    end

    try do
      {:ok, context} =
        Context.new(
          provider: Synapse.Provider.Fake,
          workspace: workspace,
          deadline: deadline,
          provider_activity_sink: provider_activity,
          event_sink: fn _event -> :ok end
        )

      script = [
        {:turn, [%TextDelta{item_id: "progress", content_index: 0, delta: "x"}],
         {:ok, response!("response-bash-budget", [bash_call])}},
        {:turn, [], {:ok, text_response("response-bash-budget-final", "done")}}
      ]

      Synapse.Provider.Fake.with_script(provider_ids, script, fn ->
        assert {:ok, _result} = Runner.run(run, context)
        assert {:ok, 0} = Fake.remaining_operations(workspace)
      end)
    after
      Workspace.close(workspace)
    end

    assert_receive {:provider_context,
                    %Synapse.Provider.StreamContext{inactivity_ms: 7, deadline: ^deadline}}
  end

  defp run_provider_script(run, provider_ids, script) do
    {:ok, workspace} = Workspace.Fake.open([])
    test_pid = self()

    try do
      {:ok, context} =
        Context.new(
          provider: Synapse.Provider.Fake,
          workspace: workspace,
          event_sink: event_sink(test_pid)
        )

      Synapse.Provider.Fake.with_script(provider_ids, script, fn ->
        terminal = Runner.run(run, context)

        remaining =
          Enum.map(provider_ids, fn id -> elem(Synapse.Provider.Fake.remaining_turns(id), 1) end)

        events = collect_events([])
        {terminal, remaining, events}
      end)
    after
      Workspace.close(workspace)
    end
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

  defp state(budget, started_at, deadline) do
    run = run_request(budget)

    {:ok, state} =
      State.new(
        run: run,
        input_items: [user_item(run.prompt)],
        started_at: started_at,
        deadline: deadline
      )

    state
  end

  defp run_request(budget) do
    {:ok, capabilities} =
      CapabilitySet.new(fs_read: true, fs_write: true, process_exec: true)

    {:ok, run} =
      Synapse.Run.Request.new(
        id: "run-budget-#{System.unique_integer([:positive, :monotonic])}",
        prompt: "Respect limits",
        cwd: "/tmp/project",
        model: "test-model",
        capabilities: capabilities,
        budget: budget
      )

    run
  end

  defp budget(options \\ []) do
    {:ok, budget} = Synapse.Budget.new(options)
    budget
  end

  defp user_item(prompt) do
    %{
      "type" => "message",
      "role" => "user",
      "content" => [%{"type" => "input_text", "text" => prompt}]
    }
  end

  defp unknown_result(provider_call) do
    {:ok, workspace} = Workspace.Fake.open([])

    try do
      {:ok, capabilities} =
        CapabilitySet.new(fs_read: false, fs_write: false, process_exec: false)

      {:ok, context} =
        ToolContext.new(
          workspace: workspace,
          capabilities: capabilities,
          operation_id: "unknown-result-operation",
          limits: Limits.default()
        )

      {:ok, call} = Call.from_provider(provider_call)
      Executor.execute(call, context)
    after
      Workspace.close(workspace)
    end
  end

  defp provider_error(operation_id) do
    {:ok, error} =
      ProviderError.new(
        kind: :unavailable,
        message: "scripted terminal",
        retryable: false,
        output_started: false,
        operation_id: operation_id
      )

    error
  end

  defp response!(id, output_items) do
    {:ok, response} = Response.new(id: id, model: "test-model", output_items: output_items)
    response
  end

  defp text_response(id, content),
    do: response!(id, [%Message{id: "message-#{id}", role: :assistant, content: content}])

  defp unknown_call(call_id),
    do: call("item-#{call_id}", call_id, "not_registered", %{})

  defp call(id, call_id, name, arguments),
    do: %FunctionCall{id: id, call_id: call_id, name: name, arguments: arguments}

  defp provider_operation_id(run, turn),
    do: elem(OperationId.provider(run.id, turn, 1), 1)

  defp tool_operation_id(run, turn, ordinal),
    do: elem(OperationId.tool(run.id, turn, ordinal), 1)
end
