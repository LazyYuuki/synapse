defmodule Synapse.Agent.AdmissionTest.MalformedBatchProvider do
  @behaviour Synapse.Provider

  alias Synapse.Provider.OutputItem.FunctionCall

  @impl true
  def stream(_request, _event_sink, _context) do
    valid = %FunctionCall{
      id: "item-valid",
      call_id: "call-valid",
      name: "read",
      arguments: %{"path" => "mix.exs"}
    }

    malformed = %FunctionCall{
      id: "item-malformed",
      call_id: "call-malformed",
      name: "write",
      arguments: %{atom_key: "invalid"}
    }

    {:ok,
     %Synapse.Provider.Response{
       id: "response-malformed-batch",
       model: "test-model",
       output_items: [valid, malformed]
     }}
  end
end

defmodule Synapse.Agent.AdmissionTest do
  use ExUnit.Case, async: true

  alias Synapse.Agent.{Admission, Context, Error, OperationId, Runner}
  alias Synapse.Provider.{Fake, Response}
  alias Synapse.Provider.Event.{TextDelta, ToolCallCompleted}
  alias Synapse.Provider.OutputItem.{FunctionCall, Message}
  alias Synapse.Run.Event
  alias Synapse.Tool.{CapabilitySet, Limits}
  alias Synapse.Workspace.Fake, as: WorkspaceFake

  doctest Admission

  test "admits all built-in shapes and an unknown name in terminal source order" do
    unknown_name = "extension_" <> String.duplicate("x", 8)

    output_items = [
      message("message-before", "Before"),
      call("item-read", "call-read", "read", %{
        "path" => "mix.exs",
        "offset" => nil,
        "limit" => nil
      }),
      call("item-write", "call-write", "write", %{
        "path" => "notes.txt",
        "content" => "hello",
        "expected_revision" => "missing"
      }),
      message("message-middle", "Middle"),
      call("item-edit", "call-edit", "edit", %{
        "path" => "notes.txt",
        "old_text" => "hello",
        "new_text" => "goodbye",
        "expected_revision" => "revision-1"
      }),
      call("item-bash", "call-bash", "bash", %{
        "command" => "mix test",
        "timeout_ms" => 1_000
      }),
      call("item-unknown", "call-unknown", unknown_name, %{"custom" => [1, true, nil]}),
      message("message-after", "After")
    ]

    response = response!("response-source-order", output_items)

    assert {:ok, admission} = Admission.preflight(response, Limits.default(), 10, 64_000)
    assert admission.response == response

    assert Enum.map(admission.calls, & &1.call_id) ==
             ~w(call-read call-write call-edit call-bash call-unknown)

    assert Enum.map(admission.calls, & &1.name) == ~w(read write edit bash) ++ [unknown_name]
    assert Enum.at(admission.calls, 1).arguments == Enum.at(output_items, 2).arguments
    assert Enum.at(admission.calls, 4).arguments == %{"custom" => [1, true, nil]}
    assert Enum.all?(admission.calls, &(not Map.has_key?(Map.from_struct(&1), :id)))

    expected_output_bytes =
      Enum.reduce(output_items, 0, fn
        %Message{content: content}, total -> total + byte_size(content)
        %FunctionCall{arguments: arguments}, total -> total + byte_size(JSON.encode!(arguments))
      end)

    assert admission.output_bytes == expected_output_bytes
    refute inspect(admission) =~ "notes.txt"
    refute inspect(admission) =~ "mix test"
  end

  test "structural admission leaves built-in validation and capabilities to Executor" do
    response =
      response!("response-structural-only", [
        call("item-read", "call-read", "read", %{"not_a_read_field" => "retained"})
      ])

    assert {:ok, %Admission{calls: [admitted]}} =
             Admission.preflight(response, Limits.default(), 1, 64_000)

    assert admitted.name == "read"
    assert admitted.arguments == %{"not_a_read_field" => "retained"}
  end

  test "terminal Response order overrides reverse ToolCall progress order" do
    test_pid = self()
    run = run_request()
    {:ok, operation_id} = OperationId.provider(run.id, 1, 1)

    first = call("item-first", "call-first", "read", %{"path" => "first.txt"})
    second = call("item-second", "call-second", "read", %{"path" => "second.txt"})

    response =
      response!("response-progress-order", [message("message-1", "Checking"), first, second])

    {:ok, admission} = Admission.preflight(response, Limits.default(), 2, 64_000)

    progress = [
      completed_progress(second),
      completed_progress(first),
      %TextDelta{item_id: "message-1", content_index: 0, delta: "draft"}
    ]

    with_context(test_pid, Fake, fn context, workspace ->
      Fake.with_script(operation_id, [{:turn, progress, {:ok, response}}], fn ->
        assert {:error, %Error{kind: :provider, reason: :provider_failed}} =
                 Runner.run(run, context)

        assert {:ok, 0} = Fake.remaining_turns(operation_id)
        assert {:ok, 0} = WorkspaceFake.remaining_operations(workspace)
      end)
    end)

    assert Enum.map(admission.calls, & &1.call_id) == ~w(call-first call-second)
    assert_received {:run_event, %Event.ToolStarted{call_id: "call-first", ordinal: 1}}

    assert_received {:run_event,
                     %Event.ToolCompleted{call_id: "call-first", ordinal: 1, status: :error}}

    assert_received {:run_event, %Event.ToolStarted{call_id: "call-second", ordinal: 2}}

    assert_received {:run_event,
                     %Event.ToolCompleted{call_id: "call-second", ordinal: 2, status: :error}}

    refute_received {:run_event, %Event.RunCompleted{}}

    assert_received {:run_event,
                     %Event.TurnCompleted{
                       outcome: :continued,
                       tool_calls: 2,
                       output_bytes: output_bytes
                     }}

    assert output_bytes > admission.output_bytes
  end

  test "rejects every bounded Call dimension as one invalid batch" do
    base = call("item-base", "call-base", "read", %{"path" => "mix.exs"})

    oversized_arguments = %{"value" => String.duplicate("x", 64_000)}
    too_many_entries = Map.new(1..17, &{"key-#{&1}", &1})
    too_deep = Enum.reduce(1..6, %{}, fn index, nested -> %{"level-#{index}" => nested} end)

    invalid_calls = [
      %FunctionCall{base | id: String.duplicate("i", 513)},
      %FunctionCall{base | call_id: String.duplicate("c", 513)},
      %FunctionCall{base | name: String.duplicate("n", 65)},
      %FunctionCall{base | arguments: oversized_arguments},
      %FunctionCall{base | arguments: too_many_entries},
      %FunctionCall{base | arguments: too_deep}
    ]

    Enum.with_index(invalid_calls, 1)
    |> Enum.each(fn {invalid_call, index} ->
      response = response!("response-invalid-#{index}", [invalid_call])

      assert {:error, :invalid_function_call_batch} =
               Admission.preflight(response, Limits.default(), 1, 64_000)
    end)
  end

  test "a valid first call and malformed later call execute neither" do
    test_pid = self()
    run = run_request()

    with_context(test_pid, __MODULE__.MalformedBatchProvider, fn context, workspace ->
      assert {:error, %Error{kind: :protocol, reason: :invalid_function_call_batch}} =
               Runner.run(run, context)

      assert {:ok, 0} = WorkspaceFake.remaining_operations(workspace)
    end)

    refute_received {:run_event, %Event.ToolStarted{}}
    refute_received {:run_event, %Event.ToolCompleted{}}
  end

  test "rejects the whole batch when remaining Tool-call budget is insufficient" do
    response =
      response!("response-call-budget", [
        call("item-1", "call-1", "read", %{"path" => "one"}),
        call("item-2", "call-2", "read", %{"path" => "two"})
      ])

    assert {:error, {:tool_call_budget_exhausted, 2, 1}} =
             Admission.preflight(response, Limits.default(), 1, 64_000)

    test_pid = self()
    run = run_request(max_tool_calls: 1)
    {:ok, operation_id} = OperationId.provider(run.id, 1, 1)

    with_context(test_pid, Fake, fn context, workspace ->
      Fake.with_script(operation_id, [{:turn, [], {:ok, response}}], fn ->
        assert {:error,
                %Error{
                  kind: :budget,
                  reason: :tool_call_budget_exhausted,
                  details: %{"observed" => 2, "maximum" => 1}
                }} = Runner.run(run, context)

        assert {:ok, 0} = WorkspaceFake.remaining_operations(workspace)
      end)
    end)

    refute_received {:run_event, %Event.ToolStarted{}}
  end

  test "accounts mixed terminal output and rejects it before execution when over budget" do
    response =
      response!("response-output-budget", [
        message("message-output", "1234567"),
        call("item-output", "call-output", "unknown", %{})
      ])

    assert {:error, {:output_budget_exhausted, 9, 8}} =
             Admission.preflight(response, Limits.default(), 1, 8)

    test_pid = self()
    run = run_request(max_output_bytes: 8)
    {:ok, operation_id} = OperationId.provider(run.id, 1, 1)

    with_context(test_pid, Fake, fn context, workspace ->
      Fake.with_script(operation_id, [{:turn, [], {:ok, response}}], fn ->
        assert {:error,
                %Error{
                  kind: :budget,
                  reason: :output_budget_exhausted,
                  details: %{"observed" => 9, "maximum" => 8}
                }} = Runner.run(run, context)

        assert {:ok, 0} = WorkspaceFake.remaining_operations(workspace)
      end)
    end)

    refute_received {:run_event, %Event.ToolStarted{}}
  end

  test "rejects duplicate IDs, bare calls, progress events, and no-call Responses" do
    first = call("item-1", "duplicate", "read", %{"path" => "one"})
    second = call("item-2", "duplicate", "write", %{"path" => "two"})

    forged_duplicate = %Response{
      id: "response-duplicate",
      model: "test-model",
      output_items: [first, second]
    }

    progress = completed_progress(first)
    no_calls = response!("response-no-calls", [message("message-only", "Finished")])

    for input <- [forged_duplicate, first, progress, no_calls] do
      assert {:error, :invalid_function_call_batch} =
               Admission.preflight(input, Limits.default(), 2, 64_000)
    end
  end

  test "admission source imports no Executor or Workspace operation API" do
    source = File.read!(Path.expand("../lib/synapse/agent/admission.ex", __DIR__))

    for forbidden <- [
          "Synapse.Tool.Executor",
          "Executor.execute",
          "Synapse.Workspace",
          "Workspace."
        ] do
      refute source =~ forbidden
    end
  end

  defp with_context(test_pid, provider, callback) do
    {:ok, workspace} = WorkspaceFake.open([])

    try do
      {:ok, context} =
        Context.new(
          provider: provider,
          workspace: workspace,
          event_sink: fn event ->
            send(test_pid, {:run_event, event})
            :ok
          end
        )

      callback.(context, workspace)
    after
      Synapse.Workspace.close(workspace)
    end
  end

  defp run_request(budget_options \\ []) do
    {:ok, capabilities} =
      CapabilitySet.new(fs_read: true, fs_write: true, process_exec: true)

    {:ok, budget} = Synapse.Budget.new(budget_options)

    {:ok, run} =
      Synapse.Run.Request.new(
        id: "run-admission-#{System.unique_integer([:positive, :monotonic])}",
        prompt: "Inspect calls",
        cwd: "/tmp/project",
        model: "test-model",
        capabilities: capabilities,
        budget: budget
      )

    run
  end

  defp response!(id, output_items) do
    {:ok, response} = Response.new(id: id, model: "test-model", output_items: output_items)
    response
  end

  defp message(id, content), do: %Message{id: id, role: :assistant, content: content}

  defp call(id, call_id, name, arguments) do
    %FunctionCall{id: id, call_id: call_id, name: name, arguments: arguments}
  end

  defp completed_progress(call) do
    %ToolCallCompleted{
      item_id: call.id,
      call_id: call.call_id,
      name: call.name,
      arguments: call.arguments
    }
  end
end
