defmodule Synapse.Provider.ResponsesStreamTest do
  use ExUnit.Case, async: true

  alias Synapse.Provider.{Error, ResponsesStream, SSEEvent}

  alias Synapse.Provider.Event.{
    Diagnostic,
    MessageCompleted,
    MessageStarted,
    TextDelta,
    ToolCallCompleted,
    ToolCallDelta,
    ToolCallStarted
  }

  alias Synapse.Provider.OutputItem.{FunctionCall, Message}

  test "reduces a text stream with many deltas, usage, and [DONE]" do
    assert {:ok, state, events} = reduce(fixture("text_stream"))

    assert [
             %MessageStarted{},
             %TextDelta{delta: "Hello"},
             %TextDelta{delta: " from"},
             %TextDelta{delta: " Synapse"},
             %MessageCompleted{}
           ] = events

    assert state.done_seen
    assert {:ok, response} = ResponsesStream.finish(state)
    assert [%Message{content: "Hello from Synapse"}] = response.output_items
    assert response.usage["total_tokens"] == 15
    refute Map.has_key?(response.usage, "raw")
  end

  test "accepts completion without usage or [DONE]" do
    frames =
      fixture("text_stream")
      |> Enum.reject(&(&1 == "[DONE]"))
      |> update_completed_response(&Map.delete(&1, "usage"))

    assert {:ok, state, _events} = reduce(frames)
    refute state.done_seen
    assert {:ok, %{usage: %{}}} = ResponsesStream.finish(state)
  end

  test "reduces one function call split across argument deltas" do
    assert {:ok, state, events} = reduce(fixture("tool_stream"))

    assert [
             %MessageStarted{},
             %ToolCallStarted{call_id: "call-read"},
             %ToolCallDelta{},
             %ToolCallDelta{},
             %ToolCallCompleted{
               arguments: %{"path" => "mix.exs", "offset" => nil, "limit" => nil}
             },
             %MessageCompleted{}
           ] = events

    assert {:ok, response} = ResponsesStream.finish(state)

    assert [
             %FunctionCall{
               id: "item-read",
               call_id: "call-read",
               name: "read",
               arguments: %{"path" => "mix.exs", "offset" => nil, "limit" => nil}
             }
           ] = response.output_items
  end

  test "accepts an empty completed function argument object" do
    frames = fixture("mixed_stream")

    assert {:ok, state, events} = reduce(frames)

    assert %ToolCallCompleted{arguments: %{}} =
             Enum.find(events, &is_struct(&1, ToolCallCompleted))

    assert {:ok, _response} = ResponsesStream.finish(state)
  end

  test "keeps multiple interleaved calls isolated and preserves source order" do
    assert {:ok, state, events} = reduce(fixture("interleaved_tool_stream"))

    completed_calls = for %ToolCallCompleted{} = event <- events, do: event
    assert Enum.map(completed_calls, & &1.call_id) == ["call-bash", "call-read"]

    assert {:ok, response} = ResponsesStream.finish(state)
    assert Enum.map(response.output_items, & &1.call_id) == ["call-read", "call-bash"]

    assert [
             %FunctionCall{
               arguments: %{"path" => "mix.exs", "offset" => nil, "limit" => nil}
             },
             %FunctionCall{arguments: arguments}
           ] =
             response.output_items

    assert arguments == %{"command" => "mix test", "timeout_ms" => nil}
  end

  test "normalizes mixed text and tool output by output_index" do
    assert {:ok, state, _events} = reduce(fixture("mixed_stream"))
    assert {:ok, response} = ResponsesStream.finish(state)

    assert [%Message{content: "I will read it."}, %FunctionCall{arguments: %{}}] =
             response.output_items
  end

  test "rejects malformed completed function arguments" do
    frames =
      fixture("tool_stream")
      |> Enum.map(fn
        %{"type" => "response.function_call_arguments.done"} = event ->
          %{event | "arguments" => "{not-json}"}

        event ->
          event
      end)

    assert {:error, %Error{kind: :protocol, output_started: true}, events} = reduce(frames)
    refute Enum.any?(events, &is_struct(&1, ToolCallCompleted))
  end

  test "rejects response completion when arguments.done is missing" do
    frames =
      fixture("tool_stream")
      |> Enum.reject(fn
        %{"type" => "response.function_call_arguments.done"} -> true
        _event -> false
      end)

    assert {:error, %Error{kind: :protocol, output_started: true}, events} = reduce(frames)
    refute Enum.any?(events, &is_struct(&1, ToolCallCompleted))
  end

  test "emits a bounded diagnostic for an unknown event and continues" do
    unknown_type = "response.future." <> String.duplicate("x", 200)
    frames = List.insert_at(fixture("text_stream"), 2, %{"type" => unknown_type, "raw" => "omit"})

    assert {:ok, state, events} = reduce(frames)
    diagnostic = Enum.find(events, &is_struct(&1, Diagnostic))

    assert diagnostic.code == "unknown_responses_event"
    assert byte_size(diagnostic.details["type"]) == 128
    refute inspect(diagnostic) =~ "omit"
    assert {:ok, _response} = ResponsesStream.finish(state)
  end

  test "normalizes response.failed before model output" do
    assert {:error, error, [%MessageStarted{}]} = reduce(fixture("failed_stream"))
    assert %Error{kind: :upstream, output_started: false, retryable: false} = error
    assert error.details == %{"code" => "server_error"}
    refute error.message =~ "raw upstream"
  end

  test "records response.failed after text output" do
    [created, failed] = fixture("failed_stream")

    frames = [
      created,
      %{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => %{
          "id" => "message-failed",
          "type" => "message",
          "role" => "assistant",
          "content" => []
        }
      },
      %{
        "type" => "response.output_text.delta",
        "item_id" => "message-failed",
        "content_index" => 0,
        "delta" => "partial"
      },
      failed
    ]

    assert {:error, %Error{kind: :upstream, output_started: true}, events} = reduce(frames)
    assert Enum.any?(events, &is_struct(&1, TextDelta))
  end

  test "rejects malformed JSON without exposing its payload" do
    state = ResponsesStream.new("operation-test")
    frame = %SSEEvent{data: ~s({"type":)}

    assert {:error, error} = ResponsesStream.push(state, frame)
    assert %Error{kind: :protocol, output_started: false} = error
    refute inspect(error) =~ ~s({"type":)
  end

  test "rejects EOF and [DONE] without a terminal Responses event" do
    [created | _events] = fixture("text_stream")

    assert {:ok, state, _events} = reduce([created, "[DONE]"])

    assert {:error, %Error{kind: :interrupted, output_started: false}} =
             ResponsesStream.finish(state)
  end

  test "rejects data after [DONE]" do
    [created | _events] = fixture("text_stream")
    state = ResponsesStream.new("operation-test")

    assert {:ok, state, [%MessageStarted{}]} = push(state, created)
    assert {:ok, state, []} = push(state, "[DONE]")
    assert {:error, %Error{kind: :protocol}} = push(state, %{"type" => "response.in_progress"})
  end

  test "bounds accumulated text output bytes" do
    [created, message_added | _events] = fixture("text_stream")
    state = ResponsesStream.new("operation-test", max_output_bytes: 5)

    assert {:ok, state, _events} = push(state, created)
    assert {:ok, state, []} = push(state, message_added)

    assert {:ok, state, [%TextDelta{delta: "12345"}]} =
             push(state, %{
               "type" => "response.output_text.delta",
               "item_id" => "message-text",
               "content_index" => 0,
               "delta" => "12345"
             })

    assert {:error, error} =
             push(state, %{
               "type" => "response.output_text.delta",
               "item_id" => "message-text",
               "content_index" => 0,
               "delta" => "6"
             })

    assert %Error{kind: :protocol, output_started: true} = error
    assert error.message == "Response exceeds the model-output byte limit"
  end

  test "bounds accumulated function arguments before completion" do
    [created, call_added | _events] = fixture("tool_stream")

    state =
      ResponsesStream.new("operation-test",
        max_argument_bytes: 5,
        max_output_bytes: 100
      )

    assert {:ok, state, _events} = push(state, created)
    assert {:ok, state, [%ToolCallStarted{}]} = push(state, call_added)

    assert {:error, error} =
             push(state, %{
               "type" => "response.function_call_arguments.delta",
               "item_id" => "item-read",
               "delta" => "123456"
             })

    assert %Error{kind: :protocol, output_started: true} = error
    assert error.message == "Response exceeds the function-argument byte limit"
  end

  test "bounds compatibility diagnostics and total event count" do
    [created | _events] = fixture("text_stream")
    state = ResponsesStream.new("operation-test", max_diagnostics: 1)

    assert {:ok, state, _events} = push(state, created)
    assert {:ok, state, [%Diagnostic{}]} = push(state, %{"type" => "response.future.one"})

    assert {:error, error} = push(state, %{"type" => "response.future.two"})
    assert error.message == "Response exceeds the compatibility-diagnostic limit"

    state = ResponsesStream.new("operation-test", max_events: 1)
    assert {:ok, state, _events} = push(state, created)
    assert {:error, error} = push(state, %{"type" => "response.future"})
    assert error.message == "Response exceeds the event-count limit"
  end

  test "bounds output item and content part accumulators" do
    [created, message_added | _events] = fixture("text_stream")
    state = ResponsesStream.new("operation-test", max_output_items: 1, max_content_parts: 1)

    assert {:ok, state, _events} = push(state, created)
    assert {:ok, state, []} = push(state, message_added)

    second_item =
      message_added
      |> put_in(["output_index"], 1)
      |> put_in(["item", "id"], "message-second")

    assert {:error, error} = push(state, second_item)
    assert error.message == "Response exceeds the output-item limit"

    assert {:ok, state, [%TextDelta{}]} =
             push(state, %{
               "type" => "response.output_text.delta",
               "item_id" => "message-text",
               "content_index" => 0,
               "delta" => "a"
             })

    assert {:error, error} =
             push(state, %{
               "type" => "response.output_text.delta",
               "item_id" => "message-text",
               "content_index" => 1,
               "delta" => "b"
             })

    assert error.message == "Malformed response.output_text.delta event"
  end

  test "rejects unreasonable accumulator limits and oversized identifiers" do
    assert_raise ArgumentError, fn ->
      ResponsesStream.new("operation-test", max_output_bytes: 8 * 1024 * 1024 + 1)
    end

    state = ResponsesStream.new("operation-test")

    assert {:error, error} =
             push(state, %{
               "type" => "response.created",
               "response" => %{
                 "id" => String.duplicate("x", 513),
                 "model" => "test-model"
               }
             })

    assert error.message == "Malformed response.created event"
  end

  defp reduce(frames) do
    Enum.reduce_while(frames, {:ok, ResponsesStream.new("operation-test"), []}, fn
      frame, {:ok, state, events} ->
        case push(state, frame) do
          {:ok, state, new_events} -> {:cont, {:ok, state, events ++ new_events}}
          {:error, error} -> {:halt, {:error, error, events}}
        end
    end)
  end

  defp push(state, data) when is_map(data) do
    ResponsesStream.push(state, %SSEEvent{data: Elixir.JSON.encode!(data)})
  end

  defp push(state, data) when is_binary(data) do
    ResponsesStream.push(state, %SSEEvent{data: data})
  end

  defp fixture(name) do
    path = Path.join([__DIR__, "fixtures", "responses", name <> ".fixture"])
    {fixture, _bindings} = Code.eval_file(path)
    fixture
  end

  defp update_completed_response(frames, update) do
    Enum.map(frames, fn
      %{"type" => "response.completed", "response" => response} = event ->
        %{event | "response" => update.(response)}

      event ->
        event
    end)
  end
end
