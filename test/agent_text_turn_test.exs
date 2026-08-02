defmodule Synapse.Agent.TextTurnTest.CrossProcessProvider do
  @behaviour Synapse.Provider

  alias Synapse.Provider.Event.TextDelta
  alias Synapse.Provider.OutputItem.Message
  alias Synapse.Provider.Response

  @impl true
  def stream(_request, event_sink, _context) do
    task =
      Task.async(fn ->
        event_sink.(%TextDelta{item_id: "message-cross", content_index: 0, delta: "Cross"})
      end)

    :ok = Task.await(task)

    Response.new(
      id: "response-cross",
      model: "test-model",
      output_items: [%Message{id: "message-cross", role: :assistant, content: "Cross process"}]
    )
  end
end

defmodule Synapse.Agent.TextTurnTest.MalformedProvider do
  @behaviour Synapse.Provider

  @impl true
  def stream(_request, _event_sink, _context), do: :malformed_terminal
end

defmodule Synapse.Agent.TextTurnTest.MalformedErrorProvider do
  @behaviour Synapse.Provider

  @impl true
  def stream(_request, _event_sink, _context) do
    {:error,
     %Synapse.Provider.Error{
       kind: :unavailable,
       message: "wrong correlation",
       retryable: true,
       output_started: false,
       operation_id: "different-operation"
     }}
  end
end

defmodule Synapse.Agent.TextTurnTest do
  use ExUnit.Case, async: true

  alias Synapse.Agent.{Context, Error, OperationId, Result, Runner}
  alias Synapse.Provider.{Fake, Request, Response}
  alias Synapse.Provider.Error, as: ProviderError
  alias Synapse.Provider.Event.{MessageCompleted, ToolCallCompleted}
  alias Synapse.Provider.Event.TextDelta, as: ProviderTextDelta
  alias Synapse.Provider.OutputItem.Message
  alias Synapse.Run.Event

  alias Synapse.Run.Event.{
    RunCompleted,
    RunFailed,
    RunInterrupted,
    RunStarted,
    TurnCompleted,
    TurnStarted
  }

  alias Synapse.Tool.CapabilitySet
  alias Synapse.Workspace.Fake, as: WorkspaceFake

  doctest OperationId
  doctest Synapse.Agent
  doctest Runner

  test "operation IDs are deterministic, bounded, and ordinal-specific" do
    digest = Base.encode16(:crypto.hash(:sha256, "run-1"), case: :lower)

    assert {:ok, provider_id} = OperationId.provider("run-1", 1, 1)
    assert provider_id == "provider-#{digest}-t0001-a0001"

    assert {:ok, tool_id} = OperationId.tool("run-1", 2, 3)
    assert tool_id == "tool-#{digest}-t0002-c0003"
    assert OperationId.provider("run-1", 1, 1) == OperationId.provider("run-1", 1, 1)
    refute OperationId.provider("run-1", 1, 1) == OperationId.provider("run-1", 1, 2)
    refute provider_id =~ "run-1"
    assert {:ok, longest_id} = OperationId.provider(String.duplicate("x", 256), 9_999, 9_999)
    assert byte_size(longest_id) <= 256
  end

  test "operation IDs reject invalid trusted inputs" do
    for invalid <- ["", "bad\nrun", String.duplicate("x", 257), :not_a_run_id] do
      assert {:error, {:run_id, :must_be_bounded_non_empty_utf8_identifier}} =
               OperationId.provider(invalid, 1, 1)
    end

    for {turn, attempt} <- [{0, 1}, {10_000, 1}, {1, 0}, {1, 10_000}] do
      assert {:error, _reason} = OperationId.provider("run-1", turn, attempt)
    end

    for {turn, ordinal} <- [{0, 1}, {10_000, 1}, {1, 0}, {1, 10_000}] do
      assert {:error, _reason} = OperationId.tool("run-1", turn, ordinal)
    end
  end

  test "runs one exact text-only Provider turn and emits ordered lifecycle events" do
    test_pid = self()
    run = run_request("Answer exactly")
    {:ok, operation_id} = OperationId.provider(run.id, 1, 1)
    response = text_response("response-text", ["Hello", "world"])

    provider_events = [
      %ProviderTextDelta{item_id: "message-a", content_index: 0, delta: "Hel"},
      %ProviderTextDelta{item_id: "message-a", content_index: 0, delta: "lo"},
      %MessageCompleted{response: response}
    ]

    with_context(test_pid, Fake, fn context, workspace ->
      Fake.with_script(
        operation_id,
        [{:turn, expected_request(run, context), provider_events, {:ok, response}}],
        fn ->
          assert {:ok, %Result{} = result} = Runner.run(run, context)
          assert result.text == "Hello\nworld"
          assert result.final_response == response
          assert result.turns == 1
          assert result.tool_calls == 0
          assert result.provider_retries == 0
          assert result.output_bytes == byte_size(result.text)
          assert {:ok, 0} = Fake.remaining_turns(operation_id)
          assert {:ok, 0} = WorkspaceFake.remaining_operations(workspace)
        end
      )
    end)

    assert_receive {:run_event, %RunStarted{run_id: "run-text", model: "test-model"}}

    assert_receive {:run_event,
                    %TurnStarted{
                      run_id: "run-text",
                      turn: 1,
                      operation_id: ^operation_id
                    }}

    assert_receive {:run_event,
                    %Event.TextDelta{
                      run_id: "run-text",
                      turn: 1,
                      operation_id: ^operation_id,
                      item_id: "message-a",
                      content_index: 0,
                      delta: "Hel"
                    }}

    assert_receive {:run_event,
                    %Event.TextDelta{
                      run_id: "run-text",
                      turn: 1,
                      operation_id: ^operation_id,
                      item_id: "message-a",
                      content_index: 0,
                      delta: "lo"
                    }}

    assert_receive {:run_event,
                    %TurnCompleted{
                      run_id: "run-text",
                      turn: 1,
                      outcome: :completed,
                      provider_attempts: 1,
                      tool_calls: 0,
                      output_bytes: 11
                    }}

    assert_receive {:run_event,
                    %RunCompleted{
                      run_id: "run-text",
                      result: %Result{
                        text: "Hello\nworld",
                        turns: 1,
                        tool_calls: 0,
                        provider_retries: 0,
                        output_bytes: 11
                      }
                    }}

    refute_receive {:run_event, _event}
  end

  test "Provider progress callbacks work from another process" do
    test_pid = self()

    with_context(test_pid, __MODULE__.CrossProcessProvider, fn context, workspace ->
      assert {:ok, %Result{text: "Cross process"}} = Runner.run(run_request(), context)
      assert {:ok, 0} = WorkspaceFake.remaining_operations(workspace)
    end)

    assert_receive {:run_event, %Event.TextDelta{delta: "Cross"}}
    assert_receive {:run_event, %RunCompleted{}}
  end

  test "passes exact lifetime controls to the Provider StreamContext" do
    test_pid = self()
    run = run_request()
    {:ok, operation_id} = OperationId.provider(run.id, 1, 1)
    cancel_ref = make_ref()
    deadline = System.monotonic_time(:millisecond) + 60_000
    response = text_response("response-context", ["Finished"])

    activity_sink = fn stream_context ->
      send(test_pid, {:provider_activity, stream_context})
      :ok
    end

    {:ok, workspace} = WorkspaceFake.open([])

    try do
      {:ok, context} =
        context(Fake, workspace, fn _event -> :ok end,
          cancel_ref: cancel_ref,
          deadline: deadline,
          provider_activity_sink: activity_sink
        )

      events = [%ProviderTextDelta{item_id: "message-1", content_index: 0, delta: "F"}]

      Fake.with_script(operation_id, [{:turn, events, {:ok, response}}], fn ->
        assert {:ok, %Result{text: "Finished"}} = Runner.run(run, context)
      end)
    after
      Synapse.Workspace.close(workspace)
    end

    assert_receive {:provider_activity,
                    %Synapse.Provider.StreamContext{
                      operation_id: ^operation_id,
                      cancel_ref: ^cancel_ref,
                      inactivity_ms: 120_000,
                      deadline: ^deadline,
                      activity_sink: ^activity_sink
                    }}
  end

  test "synchronous Run Event handling backpressures Provider streaming" do
    test_pid = self()
    run = run_request()
    {:ok, operation_id} = OperationId.provider(run.id, 1, 1)
    response = text_response("response-backpressure", ["Finished"])

    provider_events = [
      %ProviderTextDelta{item_id: "message-1", content_index: 0, delta: "F"}
    ]

    {:ok, workspace} = WorkspaceFake.open([])

    try do
      sink = fn
        %Event.TextDelta{} ->
          send(test_pid, {:sink_entered, self()})

          receive do
            :release_sink -> :ok
          end

        _event ->
          :ok
      end

      {:ok, context} = context(Fake, workspace, sink)

      Fake.with_script(operation_id, [{:turn, provider_events, {:ok, response}}], fn ->
        task = Task.async(fn -> Runner.run(run, context) end)
        assert_receive {:sink_entered, callback_pid}
        assert callback_pid == task.pid
        assert Task.yield(task, 0) == nil
        send(callback_pid, :release_sink)
        assert {:ok, %Result{text: "Finished"}} = Task.await(task)
      end)
    after
      Synapse.Workspace.close(workspace)
    end
  end

  test "ignores progress-only Tool calls and trusts the terminal text response" do
    test_pid = self()
    run = run_request()
    {:ok, operation_id} = OperationId.provider(run.id, 1, 1)
    response = text_response("response-progress-tool", ["Finished"])

    progress = [
      %ToolCallCompleted{
        item_id: "item-progress",
        call_id: "call-progress",
        name: "read",
        arguments: %{"path" => "mix.exs"}
      }
    ]

    with_context(test_pid, Fake, fn context, workspace ->
      Fake.with_script(operation_id, [{:turn, progress, {:ok, response}}], fn ->
        assert {:ok, %Result{text: "Finished"}} = Runner.run(run, context)
        assert {:ok, 0} = WorkspaceFake.remaining_operations(workspace)
      end)
    end)

    refute_receive {:run_event, %Event.ToolStarted{}}
    refute_receive {:run_event, %Event.ToolCompleted{}}
  end

  test "rejects empty terminal responses without looping" do
    for {label, response, reason} <- [
          {"empty", response!("response-empty", []), :empty_provider_response},
          {"blank", text_response("response-blank", [" \n"]), :empty_provider_response}
        ] do
      test_pid = self()
      run = run_request("case #{label}", "run-#{label}")
      {:ok, operation_id} = OperationId.provider(run.id, 1, 1)

      with_context(test_pid, Fake, fn context, workspace ->
        Fake.with_script(operation_id, [{:turn, [], {:ok, response}}], fn ->
          assert {:error, %Error{kind: :protocol, reason: ^reason}} = Runner.run(run, context)
          assert {:ok, 0} = WorkspaceFake.remaining_operations(workspace)
        end)
      end)

      assert_receive {:run_event, %TurnCompleted{outcome: :failed}}
      assert_receive {:run_event, %RunFailed{error: %Error{reason: ^reason}}}
    end
  end

  test "normalizes Provider failures before and after output without retrying" do
    for {label, provider_error, expected_reason, terminal_module, delta} <- [
          {"before", provider_error("run-before", :unavailable, false), :provider_failed,
           RunFailed, nil},
          {"timeout", provider_error("run-timeout", :timeout, false), :provider_failed,
           RunInterrupted, nil},
          {"after", provider_error("run-after", :interrupted, true),
           :provider_interrupted_after_output, RunInterrupted, "partial"}
        ] do
      test_pid = self()
      run = run_request("case #{label}", "run-#{label}")
      {:ok, operation_id} = OperationId.provider(run.id, 1, 1)
      provider_error = %{provider_error | operation_id: operation_id}

      events =
        if delta,
          do: [%ProviderTextDelta{item_id: "partial", content_index: 0, delta: delta}],
          else: []

      with_context(test_pid, Fake, fn context, workspace ->
        Fake.with_script(operation_id, [{:turn, events, {:error, provider_error}}], fn ->
          assert {:error, %Error{reason: ^expected_reason, operation_id: ^operation_id}} =
                   Runner.run(run, context)

          assert {:ok, 0} = Fake.remaining_turns(operation_id)
          assert {:ok, 0} = WorkspaceFake.remaining_operations(workspace)
        end)
      end)

      assert_receive {:run_event, %TurnCompleted{provider_attempts: 1}}
      assert_receive {:run_event, %{__struct__: ^terminal_module}}
    end
  end

  test "normalizes a malformed Provider terminal as a protocol failure" do
    test_pid = self()

    with_context(test_pid, __MODULE__.MalformedProvider, fn context, _workspace ->
      assert {:error, %Error{kind: :protocol, reason: :empty_provider_response}} =
               Runner.run(run_request(), context)
    end)

    assert_receive {:run_event, %RunFailed{error: %Error{kind: :protocol}}}
  end

  test "rejects a malformed or mismatched Provider Error without crashing" do
    test_pid = self()

    with_context(test_pid, __MODULE__.MalformedErrorProvider, fn context, _workspace ->
      assert {:error, %Error{kind: :protocol, reason: :empty_provider_response}} =
               Runner.run(run_request(), context)
    end)

    assert_receive {:run_event, %RunFailed{error: %Error{kind: :protocol}}}
  end

  test "event sink rejection stops before Provider or becomes an interrupted stream" do
    run = run_request()
    {:ok, operation_id} = OperationId.provider(run.id, 1, 1)
    response = text_response("response-sink", ["unused"])
    {:ok, workspace} = WorkspaceFake.open([])

    try do
      {:ok, context} = context(Fake, workspace, fn _event -> {:error, :closed} end)

      Fake.with_script(operation_id, [{:turn, [], {:ok, response}}], fn ->
        assert {:error, %Error{reason: :event_sink_failed}} = Runner.run(run, context)
        assert {:ok, 1} = Fake.remaining_turns(operation_id)
      end)
    after
      Synapse.Workspace.close(workspace)
    end

    test_pid = self()
    {:ok, workspace} = WorkspaceFake.open([])

    try do
      sink = fn
        %Event.TextDelta{} ->
          {:error, :closed}

        event ->
          send(test_pid, {:accepted_event, event})
          :ok
      end

      {:ok, context} = context(Fake, workspace, sink)

      provider_events = [
        %ProviderTextDelta{item_id: "message-sink", content_index: 0, delta: "partial"}
      ]

      Fake.with_script(operation_id, [{:turn, provider_events, {:ok, response}}], fn ->
        assert {:error, %Error{reason: :provider_interrupted_after_output}} =
                 Runner.run(run, context)
      end)
    after
      Synapse.Workspace.close(workspace)
    end

    assert_receive {:accepted_event, %RunInterrupted{}}
  end

  defp with_context(test_pid, provider, callback) do
    {:ok, workspace} = WorkspaceFake.open([])

    try do
      {:ok, context} =
        context(provider, workspace, fn event ->
          send(test_pid, {:run_event, event})
          :ok
        end)

      callback.(context, workspace)
    after
      Synapse.Workspace.close(workspace)
    end
  end

  defp context(provider, workspace, event_sink, options \\ []) do
    attributes =
      Keyword.merge(
        [
          provider: provider,
          workspace: workspace,
          instructions: "Fixed test instructions",
          event_sink: event_sink
        ],
        options
      )

    Context.new(attributes)
  end

  defp run_request(prompt \\ "Answer", id \\ "run-text") do
    {:ok, capabilities} =
      CapabilitySet.new(fs_read: false, fs_write: false, process_exec: false)

    {:ok, request} =
      Synapse.Run.Request.new(
        id: id,
        prompt: prompt,
        cwd: "/tmp/project",
        model: "test-model",
        capabilities: capabilities,
        budget: Synapse.Budget.default()
      )

    request
  end

  defp expected_request(run, context) do
    {:ok, request} =
      Request.new(
        model: run.model,
        instructions: context.instructions,
        input_items: [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => run.prompt}]
          }
        ],
        tools: Synapse.Tool.Registry.specifications(),
        metadata: %{"run_id" => run.id, "turn" => 1}
      )

    request
  end

  defp text_response(id, contents) do
    items =
      contents
      |> Enum.with_index(1)
      |> Enum.map(fn {content, index} ->
        %Message{id: "message-#{index}", role: :assistant, content: content}
      end)

    response!(id, items)
  end

  defp response!(id, output_items) do
    {:ok, response} = Response.new(id: id, model: "test-model", output_items: output_items)
    response
  end

  defp provider_error(run_id, kind, output_started) do
    {:ok, error} =
      ProviderError.new(
        kind: kind,
        message: "scripted #{kind}",
        retryable: false,
        output_started: output_started,
        operation_id: elem(OperationId.provider(run_id, 1, 1), 1)
      )

    error
  end
end
