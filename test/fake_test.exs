defmodule Synapse.Provider.FakeTest do
  use ExUnit.Case, async: true

  alias Synapse.Provider.{Error, Fake, Request, Response, StreamContext}

  alias Synapse.Provider.Event.{
    MessageCompleted,
    MessageStarted,
    TextDelta,
    ToolCallCompleted,
    ToolCallStarted
  }

  alias Synapse.Provider.OutputItem.{FunctionCall, Message}

  test "implements the Provider stream callback and emits text events in source order" do
    operation_id = operation_id("event-order")
    response = text_response("response-1", "Hello")

    events = [
      %MessageStarted{response_id: response.id, model: response.model},
      %TextDelta{item_id: "message-1", content_index: 0, delta: "Hel"},
      %TextDelta{item_id: "message-1", content_index: 0, delta: "lo"},
      %MessageCompleted{response: response}
    ]

    assert {:stream, 3} in Synapse.Provider.behaviour_info(:callbacks)

    Fake.with_script(operation_id, [{:turn, events, {:ok, response}}], fn ->
      sink = fn event ->
        send(self(), {:fake_event, event})
        :ok
      end

      assert {:ok, ^response} = Fake.stream(request!("hello"), sink, context!(operation_id))
      assert_received {:fake_event, %MessageStarted{}}
      assert_received {:fake_event, %TextDelta{delta: "Hel"}}
      assert_received {:fake_event, %TextDelta{delta: "lo"}}
      assert_received {:fake_event, %MessageCompleted{}}
      refute_received {:fake_event, _event}
    end)
  end

  test "asserts the exact normalized request expected by a turn" do
    operation_id = operation_id("expected-request")
    expected = request!("expected")
    response = text_response("response-expected", "ok")

    Fake.with_script(operation_id, [{:turn, expected, [], {:ok, response}}], fn ->
      assert {:ok, ^response} =
               Fake.stream(expected, fn _event -> :ok end, context!(operation_id))
    end)

    operation_id = operation_id("unexpected-request")

    Fake.with_script(operation_id, [{:turn, expected, [], {:ok, response}}], fn ->
      assert {:error, error} =
               Fake.stream(request!("different"), fn _event -> :ok end, context!(operation_id))

      assert %Error{kind: :protocol, output_started: false} = error
      assert error.message == "Fake Provider received an unexpected request"
      refute inspect(error) =~ "different"
    end)
  end

  test "consumes one multi-turn script through distinct operation IDs from another process" do
    first_operation_id = operation_id("multi-turn-first")
    second_operation_id = operation_id("multi-turn-second")
    test_pid = self()
    first_request = request!("read mix.exs")
    second_request = request!("continue with tool output")

    tool_response = tool_response("response-tool")
    final_response = text_response("response-final", "Finished")

    script = [
      {:turn, first_request,
       [
         %ToolCallStarted{
           item_id: "item-read",
           call_id: "call-read",
           name: "read"
         },
         %ToolCallCompleted{
           item_id: "item-read",
           call_id: "call-read",
           name: "read",
           arguments: %{"path" => "mix.exs"}
         },
         %MessageCompleted{response: tool_response}
       ], {:ok, tool_response}},
      {:turn, second_request,
       [
         %TextDelta{item_id: "message-final", content_index: 0, delta: "Finished"},
         %MessageCompleted{response: final_response}
       ], {:ok, final_response}}
    ]

    Fake.with_script([first_operation_id, second_operation_id], script, fn ->
      task =
        Task.async(fn ->
          sink = fn event ->
            send(test_pid, {:agent_event, event})
            :ok
          end

          first = Fake.stream(first_request, sink, context!(first_operation_id))

          remaining =
            {Fake.remaining_turns(first_operation_id), Fake.remaining_turns(second_operation_id)}

          second = Fake.stream(second_request, sink, context!(second_operation_id))
          {first, remaining, second}
        end)

      assert {{:ok, ^tool_response}, {{:ok, 1}, {:ok, 1}}, {:ok, ^final_response}} =
               Task.await(task)

      assert {:ok, 0} = Fake.remaining_turns(first_operation_id)
      assert {:ok, 0} = Fake.remaining_turns(second_operation_id)
      assert_receive {:agent_event, %ToolCallCompleted{call_id: "call-read"}}
      assert_receive {:agent_event, %TextDelta{delta: "Finished"}}
    end)

    assert {:error, :not_configured} = Fake.remaining_turns(first_operation_id)
    assert {:error, :not_configured} = Fake.remaining_turns(second_operation_id)
  end

  test "emits multiple function calls exactly as scripted" do
    operation_id = operation_id("multiple-calls")

    {:ok, response} =
      Response.new(
        id: "response-multiple",
        model: "test-model",
        output_items: [
          %FunctionCall{
            id: "item-read",
            call_id: "call-read",
            name: "read",
            arguments: %{"path" => "mix.exs"}
          },
          %FunctionCall{
            id: "item-bash",
            call_id: "call-bash",
            name: "bash",
            arguments: %{"command" => "mix test"}
          }
        ]
      )

    events = [
      %ToolCallStarted{item_id: "item-read", call_id: "call-read", name: "read"},
      %ToolCallCompleted{
        item_id: "item-read",
        call_id: "call-read",
        name: "read",
        arguments: %{"path" => "mix.exs"}
      },
      %ToolCallStarted{item_id: "item-bash", call_id: "call-bash", name: "bash"},
      %ToolCallCompleted{
        item_id: "item-bash",
        call_id: "call-bash",
        name: "bash",
        arguments: %{"command" => "mix test"}
      }
    ]

    Fake.with_script(operation_id, [{:turn, events, {:ok, response}}], fn ->
      sink = fn event ->
        send(self(), {:multiple_call_event, event})
        :ok
      end

      assert {:ok, ^response} =
               Fake.stream(request!("two calls"), sink, context!(operation_id))

      assert_received {:multiple_call_event, %ToolCallCompleted{call_id: "call-read"}}
      assert_received {:multiple_call_event, %ToolCallCompleted{call_id: "call-bash"}}
    end)
  end

  test "returns a structured error after the script is exhausted" do
    operation_id = operation_id("exhausted")
    response = text_response("response-once", "once")

    Fake.with_script(operation_id, [{:turn, [], {:ok, response}}], fn ->
      assert {:ok, ^response} =
               Fake.stream(request!("first"), fn _event -> :ok end, context!(operation_id))

      assert {:error, error} =
               Fake.stream(request!("second"), fn _event -> :ok end, context!(operation_id))

      assert %Error{kind: :configuration, output_started: false} = error
      assert error.message == "Fake Provider script is exhausted"
    end)
  end

  test "supports cancellation during event emission without sleeping" do
    operation_id = operation_id("cancel")
    cancel_ref = make_ref()
    response = text_response("response-cancel", "AB")

    events = [
      %MessageStarted{response_id: response.id, model: response.model},
      %TextDelta{item_id: "message-cancel", content_index: 0, delta: "A"},
      %TextDelta{item_id: "message-cancel", content_index: 0, delta: "B"},
      %MessageCompleted{response: response}
    ]

    Fake.with_script(operation_id, [{:turn, events, {:ok, response}}], fn ->
      sink = fn event ->
        send(self(), {:emitted, event})
        if match?(%TextDelta{delta: "A"}, event), do: send(self(), {:cancel, cancel_ref})
        :ok
      end

      context = context!(operation_id, cancel_ref: cancel_ref)
      assert {:error, error} = Fake.stream(request!("cancel"), sink, context)
      assert %Error{kind: :interrupted, output_started: true} = error
      assert_received {:emitted, %MessageStarted{}}
      assert_received {:emitted, %TextDelta{delta: "A"}}
      refute_received {:emitted, %TextDelta{delta: "B"}}
      refute_received {:emitted, %MessageCompleted{}}
    end)
  end

  test "normalizes an event sink exception and stops scripted output" do
    operation_id = operation_id("sink-exception")
    response = text_response("response-sink-exception", "AB")

    events = [
      %TextDelta{item_id: "message-sink", content_index: 0, delta: "A"},
      %TextDelta{item_id: "message-sink", content_index: 0, delta: "B"}
    ]

    Fake.with_script(operation_id, [{:turn, events, {:ok, response}}], fn ->
      sink = fn
        %TextDelta{delta: "A"} -> raise "synthetic sink failure"
        event -> send(self(), {:unexpected_fake_event, event})
      end

      assert {:error, error} =
               Fake.stream(request!("sink failure"), sink, context!(operation_id))

      assert %Error{kind: :protocol, output_started: true} = error
      refute_received {:unexpected_fake_event, _event}
    end)
  end

  test "reproduces failure before output and interruption after output" do
    operation_id = operation_id("failures")

    before_output = %Error{
      kind: :unavailable,
      message: "scripted unavailable",
      retryable: true,
      output_started: false,
      operation_id: operation_id
    }

    after_output = %Error{
      kind: :interrupted,
      message: "scripted interruption",
      retryable: false,
      output_started: true,
      operation_id: operation_id
    }

    script = [
      {:turn, [], {:error, before_output}},
      {:turn, [%TextDelta{item_id: "partial", content_index: 0, delta: "partial"}],
       {:error, after_output}}
    ]

    Fake.with_script(operation_id, script, fn ->
      assert {:error, ^before_output} =
               Fake.stream(request!("first"), fn _event -> :ok end, context!(operation_id))

      assert {:error, ^after_output} =
               Fake.stream(request!("second"), fn _event -> :ok end, context!(operation_id))
    end)
  end

  test "allows intentionally incomplete event sequences for defensive component tests" do
    operation_id = operation_id("incomplete")
    response = text_response("response-incomplete", "fallback")

    incomplete_events = [
      %ToolCallStarted{
        item_id: "item-incomplete",
        call_id: "call-incomplete",
        name: "read"
      }
    ]

    Fake.with_script(
      operation_id,
      [{:turn, incomplete_events, {:ok, response}}],
      fn ->
        assert {:ok, ^response} =
                 Fake.stream(request!("defensive"), fn _event -> :ok end, context!(operation_id))
      end
    )
  end

  test "returns a configuration error when no script is active" do
    operation_id = operation_id("missing")

    assert {:error, error} =
             Fake.stream(request!("missing"), fn _event -> :ok end, context!(operation_id))

    assert %Error{kind: :configuration} = error
    assert error.message == "Fake Provider has no script for this operation"
  end

  test "rejects structurally invalid scripts at configuration time" do
    operation_id = operation_id("invalid")

    assert_raise ArgumentError, fn ->
      Fake.start_link(operation_id, [{:turn, [:raw_wire_event], :not_a_provider_result}])
    end
  end

  test "rejects empty, duplicate, and malformed operation ID declarations" do
    response = text_response("response-invalid-ids", "unused")
    script = [{:turn, [], {:ok, response}}]
    duplicate = operation_id("duplicate")

    assert_raise ArgumentError, fn -> Fake.start_link([], script) end
    assert_raise ArgumentError, fn -> Fake.start_link([duplicate, duplicate], script) end
    assert_raise ArgumentError, fn -> Fake.start_link([operation_id("valid"), ""], script) end
    assert_raise ArgumentError, fn -> Fake.start_link(:not_an_operation_id, script) end

    assert_raise ArgumentError, fn ->
      Fake.start_link(Enum.map(1..129, &operation_id("too-many-#{&1}")), script)
    end

    assert_raise ArgumentError, fn ->
      Fake.start_link(String.duplicate("x", 513), script)
    end
  end

  test "rejects an active operation ID without replacing its script owner" do
    operation_id = operation_id("already-active")
    partial_operation_id = operation_id("partial-registration")
    response = text_response("response-already-active", "original")
    script = [{:turn, [], {:ok, response}}]
    {:ok, owner} = Fake.start_link(operation_id, script)

    try do
      assert {:error, {:already_started, existing_owner}} =
               Fake.start_link([partial_operation_id, operation_id], script)

      assert existing_owner == owner
      assert {:ok, 1} = Fake.remaining_turns(operation_id)
      assert {:error, :not_configured} = Fake.remaining_turns(partial_operation_id)
    after
      if Process.alive?(owner), do: Agent.stop(owner)
    end
  end

  defp request!(prompt) do
    {:ok, request} =
      Request.new(
        model: "test-model",
        input_items: [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => prompt}]
          }
        ]
      )

    request
  end

  defp text_response(response_id, content) do
    {:ok, response} =
      Response.new(
        id: response_id,
        model: "test-model",
        output_items: [
          %Message{id: "message-#{response_id}", role: :assistant, content: content}
        ]
      )

    response
  end

  defp tool_response(response_id) do
    {:ok, response} =
      Response.new(
        id: response_id,
        model: "test-model",
        output_items: [
          %FunctionCall{
            id: "item-read",
            call_id: "call-read",
            name: "read",
            arguments: %{"path" => "mix.exs"}
          }
        ]
      )

    response
  end

  defp context!(operation_id, attributes \\ []) do
    attributes = Keyword.put(attributes, :operation_id, operation_id)
    {:ok, context} = StreamContext.new(attributes)
    context
  end

  defp operation_id(label),
    do: "fake-#{label}-#{System.unique_integer([:positive, :monotonic])}"
end
