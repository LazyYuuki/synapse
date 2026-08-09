defmodule Synapse.Agent.ProjectionTest do
  use ExUnit.Case, async: true

  alias Synapse.Agent.{Context, Projection, State}
  alias Synapse.Budget
  alias Synapse.Provider.{Response, ResponsesCodec}
  alias Synapse.Provider.OutputItem.{FunctionCall, Message}
  alias Synapse.Run.Request
  alias Synapse.Tool.{CapabilitySet, Result}
  alias Synapse.Workspace.Fake

  doctest Projection

  setup do
    {:ok, handle} = Fake.open([])

    {:ok, context} =
      Context.new(
        provider: Synapse.Provider.Fake,
        workspace: handle,
        instructions: "Fixed test instructions",
        event_sink: fn _event -> :ok end
      )

    %{context: context, handle: handle}
  end

  test "creates exact initial input and immutable first Provider Request", %{context: context} do
    prompt = "  Inspect\nthe project exactly.  "
    run = run_request(prompt)

    assert {:ok, state} = Projection.initial_state(run, context, 1_000)

    expected_input = [
      %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => prompt}]
      }
    ]

    assert state.input_items == expected_input
    assert state.deadline == :infinity

    assert {:ok, request} = Projection.provider_request(state, context)
    assert request.model == "test-model"
    assert request.instructions == "Fixed test instructions"
    assert request.input_items == expected_input
    assert Enum.map(request.tools, & &1["name"]) == ~w(read write edit bash)
    assert request.metadata == %{"run_id" => "run-1", "turn" => 1}

    assert {:ok, encoded} = ResponsesCodec.encode(request)
    assert encoded["model"] == "test-model"
    assert encoded["instructions"] == "Fixed test instructions"
    assert encoded["input"] == expected_input
    assert Enum.map(encoded["tools"], & &1["name"]) == ~w(read write edit bash)
    refute Map.has_key?(encoded, "metadata")
    refute Map.has_key?(encoded, "previous_response_id")
  end

  test "adds a transient self-assessment after every 20 completed turns", %{context: context} do
    {:ok, %State{} = initial} = Projection.initial_state(run_request("Keep working"), context, 0)

    for turn <- [0, 19, 21, 39] do
      assert {:ok, request} = Projection.provider_request(%State{initial | turn: turn}, context)
      assert request.instructions == context.instructions
      assert request.input_items == initial.input_items
    end

    for completed_turns <- [20, 40] do
      assert {:ok, request} =
               Projection.provider_request(%State{initial | turn: completed_turns}, context)

      assert request.instructions =~ "assess whether you are making concrete progress"
      assert request.instructions =~ "stop using tools"
      assert request.metadata["turn"] == completed_turns + 1
      assert request.input_items == initial.input_items
    end
  end

  test "projects validated conversation before the current user prompt", %{context: context} do
    conversation = [
      %{"role" => "user", "content" => "Earlier question"},
      %{"role" => "assistant", "content" => "Earlier answer"}
    ]

    run = run_request("Current question", conversation)

    assert {:ok, state} = Projection.initial_state(run, context, 1_000)

    assert state.input_items == [
             %{
               "type" => "message",
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => "Earlier question"}]
             },
             %{
               "type" => "message",
               "role" => "assistant",
               "content" => [%{"type" => "output_text", "text" => "Earlier answer"}]
             },
             %{
               "type" => "message",
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => "Current question"}]
             }
           ]

    assert {:ok, request} = Projection.provider_request(state, context)
    assert request.input_items == state.input_items
  end

  test "rebuilding one turn snapshot is equal and mutates neither State nor prior Request", %{
    context: context
  } do
    {:ok, state} = Projection.initial_state(run_request("Stable prompt"), context, 0)
    original_state = state

    assert {:ok, first} = Projection.provider_request(state, context)
    assert {:ok, second} = Projection.provider_request(state, context)

    assert first == second
    assert state == original_state

    call =
      provider_call("item-read", "call-read", "read", %{
        "path" => "mix.exs",
        "offset" => nil,
        "limit" => nil
      })

    response = response("response-call", [call])
    result = tool_result("call-read", :ok, ~s({"status":"ok","tool":"read"}))

    assert {:ok, next_state} = Projection.append_response(state, context, response, [result])
    assert state == original_state
    assert first.input_items == original_state.input_items
    refute next_state == state
  end

  test "projects assistant Messages including empty continuation text", %{context: context} do
    response =
      response("response-messages", [
        %Message{id: "message-a", role: :assistant, content: "Working"},
        %Message{id: "message-empty", role: :assistant, content: ""}
      ])

    assert {:ok, projected} = Projection.response_input(response, [])

    assert projected == [
             %{
               "type" => "message",
               "role" => "assistant",
               "content" => [%{"type" => "output_text", "text" => "Working"}]
             },
             %{
               "type" => "message",
               "role" => "assistant",
               "content" => [%{"type" => "output_text", "text" => ""}]
             }
           ]

    {:ok, state} = Projection.initial_state(run_request("Prompt"), context, 0)
    assert {:ok, next_state} = Projection.append_response(state, context, response, [])
    assert Enum.take(next_state.input_items, -2) == projected
  end

  test "projects one FunctionCall and only paired Result content" do
    call =
      provider_call("item-read", "call-read", "read", %{
        "path" => "mix.exs",
        "offset" => nil,
        "limit" => nil
      })

    response = response("response-read", [call])

    result =
      tool_result(
        "call-read",
        :ok,
        ~s({"status":"ok","tool":"read"}),
        %{"tool" => "metadata-must-not-project", "outcome" => "completed"}
      )

    assert {:ok, projected} = Projection.response_input(response, [result])

    assert projected == [
             %{
               "type" => "function_call",
               "id" => "item-read",
               "call_id" => "call-read",
               "name" => "read",
               "arguments" => %{"path" => "mix.exs", "offset" => nil, "limit" => nil}
             },
             %{
               "type" => "function_call_output",
               "call_id" => "call-read",
               "output" => ~s({"status":"ok","tool":"read"})
             }
           ]

    refute inspect(projected) =~ "metadata-must-not-project"
    refute Enum.any?(projected, &Map.has_key?(&1, "status"))
    refute Enum.any?(projected, &Map.has_key?(&1, "metadata"))
  end

  test "preserves mixed source order and inserts each output immediately after its call" do
    read_call =
      provider_call("item-read", "call-read", "read", %{
        "path" => "mix.exs",
        "offset" => nil,
        "limit" => nil
      })

    bash_call =
      provider_call("item-bash", "call-bash", "bash", %{
        "command" => "mix test",
        "timeout_ms" => nil
      })

    response =
      response("response-mixed", [
        %Message{id: "message-before", role: :assistant, content: "Checking"},
        read_call,
        %Message{id: "message-between", role: :assistant, content: "Then testing"},
        bash_call,
        %Message{id: "message-after", role: :assistant, content: "Waiting"}
      ])

    results = [
      tool_result("call-bash", :error, ~s({"status":"error","outcome":"completed"})),
      tool_result("call-read", :ok, ~s({"status":"ok","tool":"read"}))
    ]

    assert {:ok, projected} = Projection.response_input(response, results)

    assert Enum.map(projected, & &1["type"]) == [
             "message",
             "function_call",
             "function_call_output",
             "message",
             "function_call",
             "function_call_output",
             "message"
           ]

    assert Enum.at(projected, 1)["id"] == "item-read"
    assert Enum.at(projected, 2)["call_id"] == "call-read"
    assert Enum.at(projected, 4)["id"] == "item-bash"
    assert Enum.at(projected, 5)["call_id"] == "call-bash"

    {:ok, request} =
      Synapse.Provider.Request.new(model: "test-model", input_items: projected)

    assert {:ok, encoded} = ResponsesCodec.encode(request)
    assert Enum.map(encoded["input"], & &1["type"]) == Enum.map(projected, & &1["type"])
  end

  test "rejects missing, extra, duplicate, and malformed Results before append", %{
    context: context
  } do
    call = provider_call("item-read", "call-read", "read", %{})
    response = response("response-pairing", [call])
    valid = tool_result("call-read", :ok, ~s({"status":"ok"}))
    extra = tool_result("call-extra", :ok, ~s({"status":"ok"}))

    assert {:error, :missing_result} = Projection.response_input(response, [])
    assert {:error, :unexpected_result} = Projection.response_input(response, [valid, extra])
    assert {:error, :duplicate_result} = Projection.response_input(response, [valid, valid])
    assert {:error, :invalid_results} = Projection.response_input(response, [%{}])
    assert {:error, :invalid_results} = Projection.response_input(response, [valid | :bad])

    forged = %Result{valid | content: "not-json"}
    assert {:error, :invalid_results} = Projection.response_input(response, [forged])

    {:ok, state} = Projection.initial_state(run_request("Pair safely"), context, 0)
    original = state

    assert {:error, :missing_result} = Projection.append_response(state, context, response, [])
    assert state == original
  end

  test "rejects malformed Response, State, Context, and unsupported output before mutation", %{
    context: context
  } do
    {:ok, %State{} = state} = Projection.initial_state(run_request("Defensive"), context, 0)

    final =
      response("response-final", [%Message{id: "message", role: :assistant, content: "done"}])

    assert {:error, :invalid_response} = Projection.response_input(%{}, [])

    assert {:error, :invalid_response} =
             Projection.response_input(%Response{final | status: :failed}, [])

    assert {:error, :invalid_state} = Projection.provider_request(%{}, context)
    assert {:error, :invalid_context} = Projection.provider_request(state, %{})
    assert {:error, :invalid_run_request} = Projection.initial_state(%{}, context, 0)
    assert {:error, :invalid_context} = Projection.initial_state(run_request("x"), %{}, 0)

    terminal_state = %State{state | status: :completed}
    assert {:error, :invalid_state} = Projection.provider_request(terminal_state, context)

    malformed_state = %State{state | input_items: [%{"type" => "unsupported"}]}
    assert {:error, :invalid_state} = Projection.provider_request(malformed_state, context)
  end

  test "Provider Request inspection cannot expose Context authority", %{context: context} do
    {:ok, state} = Projection.initial_state(run_request("recognizable-prompt"), context, 0)
    {:ok, request} = Projection.provider_request(state, context)
    inspected = inspect(request)

    refute inspected =~ "recognizable-prompt"
    refute inspected =~ "Fixed test instructions"
    refute inspected =~ "Workspace.Handle"
    refute inspected =~ "Function"
    refute Map.has_key?(Map.from_struct(request), :workspace)
    refute Map.has_key?(Map.from_struct(request), :provider)
    refute Map.has_key?(Map.from_struct(request), :retry_delay)
  end

  test "Projection source contains no Provider transport, Tool execution, or host access" do
    source =
      File.read!(Path.join([__DIR__, "..", "lib", "synapse", "agent", "projection.ex"]))

    forbidden = [
      "Req.",
      "Finch.",
      "File.",
      "System.",
      "Port.",
      "MuonTrap",
      "Provider.stream",
      "Executor.execute",
      "Workspace.open"
    ]

    Enum.each(forbidden, &refute(source =~ &1))
  end

  defp run_request(prompt, conversation \\ []) do
    {:ok, capabilities} =
      CapabilitySet.new(fs_read: true, fs_write: true, process_exec: true)

    {:ok, run} =
      Request.new(
        id: "run-1",
        prompt: prompt,
        conversation: conversation,
        cwd: "/synthetic/project",
        model: "test-model",
        capabilities: capabilities,
        budget: Budget.default()
      )

    run
  end

  defp response(id, output_items) do
    {:ok, response} = Response.new(id: id, model: "test-model", output_items: output_items)
    response
  end

  defp provider_call(id, call_id, name, arguments),
    do: %FunctionCall{id: id, call_id: call_id, name: name, arguments: arguments}

  defp tool_result(call_id, status, content, metadata \\ %{}) do
    {:ok, result} =
      Result.new(call_id: call_id, status: status, content: content, metadata: metadata)

    result
  end
end
