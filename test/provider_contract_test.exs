defmodule Synapse.ProviderContractTest do
  use ExUnit.Case, async: true

  alias Synapse.Provider
  alias Synapse.Provider.{Error, OutputItem, Request, Response, StreamContext}

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

  doctest Request
  doctest Synapse.Provider.Event.ToolCallCompleted
  doctest Synapse.Provider.Fake

  defmodule ExampleProvider do
    @behaviour Provider

    @impl true
    def stream(_request, _event_sink, _context) do
      {:error,
       %Error{
         kind: :configuration,
         message: "not configured",
         retryable: false,
         output_started: false,
         operation_id: "operation-test"
       }}
    end
  end

  describe "request validation" do
    test "constructs a normalized text request with a function tool" do
      attrs = %{
        model: "configured-model",
        instructions: "You are a coding agent.",
        input_items: [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "Inspect the project"}]
          }
        ],
        tools: [
          %{
            "type" => "function",
            "name" => "read",
            "description" => "Read a file",
            "parameters" => %{
              "type" => "object",
              "properties" => %{"path" => %{"type" => "string"}},
              "required" => ["path"]
            }
          }
        ],
        metadata: %{"run_id" => "run-test"}
      }

      assert {:ok, %Request{} = request} = Request.new(attrs)
      assert request.model == "configured-model"
      assert [%{"type" => "message"}] = request.input_items
      assert [%{"name" => "read"}] = request.tools
    end

    test "rejects a missing or blank model" do
      assert {:error, {:model, :must_be_non_empty_string}} = Request.new(%{})
      assert {:error, {:model, :must_be_non_empty_string}} = Request.new(model: "  ")
      assert {:error, {:model, :must_be_non_empty_string}} = Request.new(model: 123)
    end

    test "rejects malformed input items and tool definitions" do
      assert {:error, {:input_items, :must_be_supported_items}} =
               Request.new(model: "model", input_items: [%{"role" => "user"}])

      assert {:error, {:input_items, :must_be_supported_items}} =
               Request.new(
                 model: "model",
                 input_items: [%{type: "message", role: "user", content: []}]
               )

      assert {:error, {:tools, :must_be_function_definitions}} =
               Request.new(
                 model: "model",
                 tools: [%{"type" => "function", "name" => "read"}]
               )
    end

    test "rejects credentials and transport options as unknown fields" do
      assert {:error, {:unknown_fields, fields}} =
               Request.new(model: "model", api_key: "secret", req_options: [])

      assert Enum.sort(fields) == [:api_key, :req_options]

      inspected = inspect(%Request{model: "model"})
      refute inspected =~ "api_key"
      refute inspected =~ "authorization"
    end
  end

  test "constructs every normalized output item and event type" do
    message = %Message{id: "message-1", role: :assistant, content: "Hello"}

    function_call = %FunctionCall{
      id: "item-1",
      call_id: "call-1",
      name: "read",
      arguments: %{"path" => "mix.exs"}
    }

    assert %OutputItem.Message{} = message
    assert %OutputItem.FunctionCall{} = function_call

    assert {:ok, response} =
             Response.new(
               id: "response-1",
               model: "configured-model",
               output_items: [message, function_call],
               usage: %{"input_tokens" => 10, "output_tokens" => 5}
             )

    events = [
      %MessageStarted{response_id: "response-1", model: "configured-model"},
      %TextDelta{item_id: "message-1", content_index: 0, delta: "Hel"},
      %ToolCallStarted{item_id: "item-1", call_id: "call-1", name: "read"},
      %ToolCallDelta{item_id: "item-1", call_id: "call-1", delta: ~s({"path")},
      %ToolCallCompleted{
        item_id: "item-1",
        call_id: "call-1",
        name: "read",
        arguments: %{"path" => "mix.exs"}
      },
      %MessageCompleted{response: response},
      %Diagnostic{code: "unknown_event", message: "Ignored an unknown event"}
    ]

    assert Enum.all?(events, &is_struct/1)
    assert %Response{status: :completed} = response
  end

  test "a response rejects partial or malformed output items" do
    partial_call = %FunctionCall{
      id: "item-1",
      call_id: "call-1",
      name: "read",
      arguments: %{path: "mix.exs"}
    }

    assert {:error, {:output_items, :must_be_complete_output_items}} =
             Response.new(
               id: "response-1",
               model: "configured-model",
               output_items: [partial_call]
             )
  end

  test "constructs a sanitized error without a raw response body" do
    assert {:ok, error} =
             Error.new(
               kind: :unavailable,
               message: "provider unavailable",
               status: 503,
               retryable: true,
               output_started: false,
               operation_id: "operation-1",
               details: %{"request_id" => "request-1"}
             )

    assert error.retryable
    refute error.output_started
    refute Map.has_key?(error.details, "body")
    refute Map.has_key?(error, :raw_response)
    refute Map.has_key?(error, :authorization)

    assert {:error, {:message, :must_be_bounded_string}} =
             Error.new(
               kind: :protocol,
               message: String.duplicate("x", 513),
               retryable: false,
               output_started: false,
               operation_id: "operation-1"
             )

    assert {:error, {:details, :must_be_bounded_string_keyed_json_object}} =
             Error.new(
               kind: :protocol,
               message: "bounded",
               retryable: false,
               output_started: false,
               operation_id: "operation-1",
               details: %{"value" => String.duplicate("x", 4_097)}
             )
  end

  test "validates the Runtime-owned stream context" do
    cancel_ref = make_ref()
    activity_sink = fn %StreamContext{} -> :ok end

    assert {:ok, context} =
             StreamContext.new(
               operation_id: "operation-1",
               cancel_ref: cancel_ref,
               inactivity_ms: 5_000,
               deadline: System.monotonic_time(:millisecond) + 10_000,
               activity_sink: activity_sink
             )

    assert context.cancel_ref == cancel_ref

    assert {:error, {:inactivity_ms, :must_be_reasonable_positive_integer}} =
             StreamContext.new(operation_id: "operation-1", inactivity_ms: 0)

    assert {:error, {:inactivity_ms, :must_be_reasonable_positive_integer}} =
             StreamContext.new(operation_id: "operation-1", inactivity_ms: 900_001)
  end

  test "the behaviour accepts a normalized request and context" do
    assert {:ok, request} = Request.new(model: "configured-model")
    assert {:ok, context} = StreamContext.new(operation_id: "operation-test")

    assert {:error, %Error{kind: :configuration}} =
             ExampleProvider.stream(request, fn _event -> :ok end, context)
  end
end
