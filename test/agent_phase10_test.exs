defmodule Synapse.Agent.Phase10Test.FaultProvider do
  @behaviour Synapse.Provider

  alias Synapse.Provider.{Error, Response}
  alias Synapse.Provider.OutputItem.Message

  @impl true
  def stream(_request, _event_sink, context) do
    Process.put(:phase10_provider_attempts, Process.get(:phase10_provider_attempts, 0) + 1)
    send(self(), :phase10_provider_called)

    case Process.get(:phase10_provider_mode) do
      :raise -> raise "synthetic Provider crash"
      :throw -> throw(:synthetic_provider_throw)
      :exit -> exit(:synthetic_provider_exit)
      :unsupported -> {:ok, unsupported_response()}
      :retryable_failure -> {:error, failure(context.operation_id, true)}
      :failure -> {:error, failure(context.operation_id, false)}
      _text -> {:ok, text_response()}
    end
  end

  defp failure(operation_id, retryable) do
    {:ok, error} =
      Error.new(
        kind: :transport,
        message: "SYNTHETIC_PROVIDER_SECRET_MUST_NOT_ESCAPE",
        retryable: retryable,
        output_started: false,
        operation_id: operation_id
      )

    error
  end

  defp unsupported_response do
    %Response{
      id: "response-unsupported",
      model: "test-model",
      output_items: [:unsupported_model_item],
      usage: %{},
      status: :completed
    }
  end

  defp text_response do
    {:ok, response} =
      Response.new(
        id: "response-phase10-text",
        model: "test-model",
        output_items: [
          %Message{
            id: "message-phase10-text",
            role: :assistant,
            content: "SYNTHETIC_FINAL_CONTENT"
          }
        ]
      )

    response
  end
end

defmodule Synapse.Agent.Phase10Test do
  use ExUnit.Case, async: false

  alias Synapse.Agent.{Context, OperationId, Projection, Runner, State}
  alias Synapse.Agent.Error, as: AgentError
  alias Synapse.Agent.Phase10Test.FaultProvider
  alias Synapse.Provider.{Fake, Response}
  alias Synapse.Provider.OutputItem.{FunctionCall, Message}
  alias Synapse.Run.Event
  alias Synapse.Tool.CapabilitySet
  alias Synapse.Workspace

  setup do
    Process.delete(:phase10_provider_mode)
    Process.delete(:phase10_provider_attempts)
    flush_mailbox()
    :ok
  end

  test "unexpected Provider exception, throw, and exit remain Runner process failures" do
    with_context(fn run, context, workspace ->
      Process.put(:phase10_provider_mode, :raise)
      assert_raise RuntimeError, "synthetic Provider crash", fn -> Runner.run(run, context) end

      Process.put(:phase10_provider_mode, :throw)
      assert catch_throw(Runner.run(run, context)) == :synthetic_provider_throw

      Process.put(:phase10_provider_mode, :exit)
      assert catch_exit(Runner.run(run, context)) == :synthetic_provider_exit

      assert {:ok, 0} = Synapse.Workspace.Fake.remaining_operations(workspace)
    end)
  end

  test "unsupported successful Provider output terminates without Tool execution" do
    Process.put(:phase10_provider_mode, :unsupported)
    test_pid = self()

    with_context(
      fn run, context, workspace ->
        assert {:error, %AgentError{kind: :protocol}} = Runner.run(run, context)
        assert {:ok, 0} = Synapse.Workspace.Fake.remaining_operations(workspace)
        refute_received {:tool_event, _event}
      end,
      event_sink: fn
        %Event.ToolStarted{} = event -> send(test_pid, {:tool_event, event})
        %Event.ToolCompleted{} = event -> send(test_pid, {:tool_event, event})
        _event -> :ok
      end
    )
  end

  test "cancellation probe exception, throw, and exit fail closed before Provider" do
    probes = [
      fn -> raise "probe failed" end,
      fn -> throw(:probe_failed) end,
      fn -> exit(:probe_failed) end
    ]

    Enum.each(probes, fn probe ->
      with_context(
        fn run, context, workspace ->
          assert {:error, %AgentError{kind: :cancelled, reason: :run_cancelled}} =
                   Runner.run(run, context)

          assert {:ok, 0} = Synapse.Workspace.Fake.remaining_operations(workspace)
          refute_received :phase10_provider_called
        end,
        cancelled?: probe
      )
    end)
  end

  test "malformed and crashing retry-delay policies start no second attempt" do
    Process.put(:phase10_provider_mode, :retryable_failure)

    policies = [
      fn _ordinal -> 10_001 end,
      fn _ordinal -> raise "delay failed" end,
      fn _ordinal -> throw(:delay_failed) end,
      fn _ordinal -> exit(:delay_failed) end
    ]

    Enum.each(policies, fn policy ->
      Process.put(:phase10_provider_attempts, 0)

      with_context(
        fn run, context, _workspace ->
          assert {:error, %AgentError{kind: :internal, reason: :invalid_agent_context}} =
                   Runner.run(run, context)

          assert Process.get(:phase10_provider_attempts) == 1
          flush_mailbox()
        end,
        retry_delay: policy
      )
    end)
  end

  test "Provider prose is replaced by Agent-owned sanitized failure text" do
    Process.put(:phase10_provider_mode, :failure)
    test_pid = self()

    with_context(
      fn run, context, _workspace ->
        assert {:error, error} = Runner.run(run, context)
        assert error.message == "Provider request failed"
        refute error.message =~ "SYNTHETIC_PROVIDER_SECRET"
        refute inspect(error) =~ "SYNTHETIC_PROVIDER_SECRET"

        assert_receive {:terminal_event, %Event.RunFailed{} = event}
        refute inspect(event) =~ "SYNTHETIC_PROVIDER_SECRET"
        refute event.error.message =~ "SYNTHETIC_PROVIDER_SECRET"
      end,
      event_sink: fn
        %Event.RunFailed{} = event ->
          send(test_pid, {:terminal_event, event})
          :ok

        _event ->
          :ok
      end
    )
  end

  test "event-sink rejection at every non-Tool boundary returns one structured Error" do
    scenarios = [
      {Event.RunStarted, :text, false},
      {Event.TurnStarted, :text, false},
      {Event.TurnCompleted, :text, false},
      {Event.RunCompleted, :text, false},
      {Event.RunFailed, :failure, false},
      {Event.RunInterrupted, :text, true}
    ]

    Enum.each(scenarios, fn {rejected_module, provider_mode, cancelled} ->
      Process.put(:phase10_provider_mode, provider_mode)
      test_pid = self()

      sink = fn event ->
        if is_struct(event, rejected_module) do
          send(test_pid, {:rejected, rejected_module})
          {:error, :closed}
        else
          :ok
        end
      end

      with_context(
        fn run, context, _workspace ->
          assert {:error, %AgentError{kind: :internal, reason: :event_sink_failed}} =
                   Runner.run(run, context)

          assert_receive {:rejected, ^rejected_module}
        end,
        event_sink: sink,
        cancelled?: fn -> cancelled end
      )
    end)
  end

  test "event sink exception, throw, and exit are normalized without escaping" do
    sinks = [
      fn _event -> raise "sink failed" end,
      fn _event -> throw(:sink_failed) end,
      fn _event -> exit(:sink_failed) end
    ]

    Enum.each(sinks, fn sink ->
      with_context(
        fn run, context, _workspace ->
          assert {:error, %AgentError{reason: :event_sink_failed}} = Runner.run(run, context)
        end,
        event_sink: sink
      )
    end)
  end

  test "every terminal State status rejects all continuation transitions" do
    with_context(fn run, context, _workspace ->
      {:ok, state} = Projection.initial_state(run, context, 0)
      {:ok, response} = text_response("terminal")

      for status <- [:completed, :failed, :interrupted] do
        terminal = %{state | status: status}

        assert {:error, :invalid_state} = State.admit_turn(terminal, 1)
        assert {:error, :invalid_state} = State.admit_tool(terminal, 1)
        assert {:error, :invalid_state} = State.admit_provider_retry(terminal, 1)
        assert {:error, :invalid_state} = State.add_output(terminal, 1)
        refute State.deadline_open?(terminal, 1)
        assert {:error, :invalid_state} = Projection.provider_request(terminal, context)

        assert {:error, :invalid_state} =
                 Projection.append_response(terminal, context, response, [])
      end
    end)
  end

  test "RunCompleted carries content but ordinary inspection redacts it" do
    test_pid = self()

    with_context(
      fn run, context, _workspace ->
        assert {:ok, result} = Runner.run(run, context)
        assert result.text == "SYNTHETIC_FINAL_CONTENT"
        assert_receive {:completed, %Event.RunCompleted{} = event}
        assert event.result.text == "SYNTHETIC_FINAL_CONTENT"
        assert inspect(event) == "#Synapse.Run.Event.RunCompleted<redacted>"
        refute inspect(event) =~ "SYNTHETIC_FINAL_CONTENT"
      end,
      event_sink: fn
        %Event.RunCompleted{} = event ->
          send(test_pid, {:completed, event})
          :ok

        _event ->
          :ok
      end
    )
  end

  test "hard maximum turns and Tool calls remain bounded without atom or resource retention" do
    assert {:ok, _warmup} = run_stress(2, 1, "warmup")
    atom_count = :erlang.system_info(:atom_count)

    assert {:ok, result} = run_stress(100, 500, "maximum")
    assert result.turns == 100
    assert result.tool_calls == 500
    assert result.provider_retries == 0
    assert :erlang.system_info(:atom_count) == atom_count
    refute_received _message
  end

  test "Agent source owns no process registry, persistence, host, transport, or logging API" do
    source =
      Path.wildcard(Path.join([__DIR__, "..", "lib", "synapse", "agent", "*.ex"]))
      |> Enum.map_join("\n", &File.read!/1)

    forbidden = [
      "Req.",
      "Finch.",
      "File.",
      "System.",
      "Port.",
      "MuonTrap",
      "Runtime.",
      "CLI.",
      "Logger.",
      "IO.inspect",
      "IO.puts",
      ":ets.",
      ":global.",
      "Task.async",
      "Task.start",
      "spawn("
    ]

    Enum.each(forbidden, &refute(source =~ &1))
  end

  defp with_context(callback, options \\ []) do
    {:ok, workspace} = Synapse.Workspace.Fake.open([])

    try do
      attributes =
        Keyword.merge(
          [
            provider: FaultProvider,
            workspace: workspace,
            event_sink: fn _event -> :ok end,
            retry_delay: fn _ordinal -> 0 end
          ],
          options
        )

      {:ok, context} = Context.new(attributes)
      callback.(run_request(), context, workspace)
    after
      Workspace.close(workspace)
    end
  end

  defp run_stress(turns, tool_calls, label) do
    {:ok, budget} =
      Synapse.Budget.new(
        max_turns: 100,
        max_tool_calls: 500,
        max_output_bytes: 4_194_304
      )

    run = run_request(budget: budget, id: "run-phase10-stress-#{label}")
    provider_ids = Enum.map(1..turns, &elem(OperationId.provider(run.id, &1, 1), 1))
    tool_turns = turns - 1
    base = div(tool_calls, tool_turns)
    remainder = rem(tool_calls, tool_turns)

    {responses, call_count} =
      Enum.map_reduce(1..tool_turns, 0, fn turn, first_call ->
        count = base + if(turn <= remainder, do: 1, else: 0)

        calls =
          Enum.map(1..count, fn offset ->
            number = first_call + offset

            %FunctionCall{
              id: "item-#{label}-#{number}",
              call_id: "call-#{label}-#{number}",
              name: "unknown_tool_#{label}_#{number}",
              arguments: %{}
            }
          end)

        {:ok, response} =
          Response.new(
            id: "response-#{label}-#{turn}",
            model: "test-model",
            output_items: calls
          )

        {{:turn, [], {:ok, response}}, first_call + count}
      end)

    assert call_count == tool_calls
    {:ok, final_response} = text_response("stress complete")
    script = responses ++ [{:turn, [], {:ok, final_response}}]
    {:ok, workspace} = Synapse.Workspace.Fake.open([])

    try do
      {:ok, context} =
        Context.new(
          provider: Fake,
          workspace: workspace,
          event_sink: fn _event -> :ok end,
          retry_delay: fn _ordinal -> 0 end
        )

      result =
        Fake.with_script(provider_ids, script, fn ->
          terminal = Runner.run(run, context)
          assert {:ok, 0} = Synapse.Workspace.Fake.remaining_operations(workspace)
          assert Enum.all?(provider_ids, &(Fake.remaining_turns(&1) == {:ok, 0}))
          terminal
        end)

      assert Enum.all?(provider_ids, &(Fake.remaining_turns(&1) == {:error, :not_configured}))
      result
    after
      Workspace.close(workspace)
    end
  end

  defp run_request(options \\ []) do
    {:ok, capabilities} =
      CapabilitySet.new(fs_read: true, fs_write: true, process_exec: true)

    {:ok, run} =
      Synapse.Run.Request.new(
        id: Keyword.get(options, :id, "run-phase10"),
        prompt: "SYNTHETIC_PROMPT_CONTENT",
        cwd: "/synthetic/phase10/root",
        model: "test-model",
        capabilities: capabilities,
        budget: Keyword.get(options, :budget, Synapse.Budget.default())
      )

    run
  end

  defp text_response(content) do
    Response.new(
      id: "response-phase10-#{System.unique_integer([:positive, :monotonic])}",
      model: "test-model",
      output_items: [
        %Message{
          id: "message-phase10-#{System.unique_integer([:positive, :monotonic])}",
          role: :assistant,
          content: content
        }
      ]
    )
  end

  defp flush_mailbox do
    receive do
      _message -> flush_mailbox()
    after
      0 -> :ok
    end
  end
end
