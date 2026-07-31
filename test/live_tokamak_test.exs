defmodule Synapse.Provider.LiveTokamakTest do
  use ExUnit.Case, async: false

  alias Synapse.Provider.{Error, Request, StreamContext, Tokamak}

  alias Synapse.Provider.Event.{
    MessageCompleted,
    MessageStarted,
    TextDelta,
    ToolCallCompleted,
    ToolCallDelta,
    ToolCallStarted
  }

  alias Synapse.Provider.OutputItem.FunctionCall

  @moduletag :live_tokamak
  @moduletag timeout: 150_000

  @missing_environment Enum.reject(["TOKAMAK_API_KEY", "SYNAPSE_MODEL"], fn name ->
                         case System.get_env(name) do
                           value when is_binary(value) ->
                             String.valid?(value) and String.trim(value) != ""

                           _missing ->
                             false
                         end
                       end)

  @live_skip if(@missing_environment == [],
               do: false,
               else:
                 "requires non-empty runtime environment: #{Enum.join(@missing_environment, ", ")}"
             )
  @moduletag skip: @live_skip

  test "streams a live text response through normalized Provider events" do
    test_pid = self()
    message_ref = make_ref()

    request =
      request!(
        instructions: "Return only the exact text SYNAPSE_LIVE_TEXT_OK.",
        input_items: [user_message("Return the requested acceptance marker now.")]
      )

    sink = fn event ->
      send(test_pid, {message_ref, event})
      :ok
    end

    assert {:ok, response} = Tokamak.stream(request, sink, context!("text"))
    events = drain_events(message_ref)

    assert Enum.any?(events, &is_struct(&1, MessageStarted))
    assert Enum.any?(events, &match?(%TextDelta{delta: delta} when delta != "", &1))
    assert Enum.count(events, &is_struct(&1, MessageCompleted)) == 1
    assert is_binary(response.id) and response.id != "" and byte_size(response.id) <= 512
    assert response.model == System.fetch_env!("SYNAPSE_MODEL")
    assert response.status == :completed
  end

  test "normalizes exactly one live function call without executing it" do
    test_pid = self()
    message_ref = make_ref()

    request =
      request!(
        instructions:
          "Call synapse_acceptance_probe exactly once with value SYNAPSE_TOOL_OK. " <>
            "Do not answer with text and do not call any other function.",
        input_items: [user_message("Perform the required function-call acceptance check.")],
        tools: [
          %{
            "type" => "function",
            "name" => "synapse_acceptance_probe",
            "description" =>
              "Returns a synthetic acceptance marker. The Provider must not execute it.",
            "parameters" => %{
              "type" => "object",
              "properties" => %{
                "value" => %{
                  "type" => "string",
                  "description" => "The exact value SYNAPSE_TOOL_OK"
                }
              },
              "required" => ["value"],
              "additionalProperties" => false
            },
            "strict" => true
          }
        ]
      )

    sink = fn event ->
      send(test_pid, {message_ref, event})
      :ok
    end

    assert {:ok, response} = Tokamak.stream(request, sink, context!("tool"))
    events = drain_events(message_ref)

    assert Enum.count(events, &is_struct(&1, ToolCallStarted)) == 1
    assert Enum.any?(events, &match?(%ToolCallDelta{delta: delta} when delta != "", &1))

    assert [completed] = Enum.filter(events, &is_struct(&1, ToolCallCompleted))
    assert completed.name == "synapse_acceptance_probe"
    assert completed.arguments == %{"value" => "SYNAPSE_TOOL_OK"}
    assert Enum.all?(Map.keys(completed.arguments), &is_binary/1)

    assert [call] = Enum.filter(response.output_items, &is_struct(&1, FunctionCall))
    assert call.call_id == completed.call_id
    assert call.arguments == completed.arguments
  end

  test "cancels a live response after output without replaying it" do
    test_pid = self()
    message_ref = make_ref()
    cancel_ref = make_ref()

    request =
      request!(
        instructions: "Write a detailed response of at least 500 words.",
        input_items: [user_message("Explain why deterministic stream cancellation matters.")]
      )

    task =
      Task.async(fn ->
        coordinator = self()

        sink = fn event ->
          send(test_pid, {message_ref, event})

          if match?(%TextDelta{delta: delta} when delta != "", event) do
            Tokamak.cancel(coordinator, cancel_ref)

            receive do
              :release_live_sink -> :ok
            after
              10_000 -> :ok
            end
          end

          :ok
        end

        Tokamak.stream(request, sink, context!("cancel", cancel_ref: cancel_ref))
      end)

    assert_receive {^message_ref, %TextDelta{delta: delta}} when delta != "", 120_000

    assert {:error, %Error{kind: :interrupted, output_started: true, retryable: false}} =
             Task.await(task, 15_000)

    events = drain_events(message_ref)
    assert Enum.count(events, &is_struct(&1, MessageStarted)) == 1
    refute Enum.any?(events, &is_struct(&1, MessageCompleted))
  end

  defp request!(attributes) do
    attributes = Keyword.put(attributes, :model, System.fetch_env!("SYNAPSE_MODEL"))
    {:ok, request} = Request.new(attributes)
    request
  end

  defp context!(suffix, attributes \\ []) do
    operation_id = "live-tokamak-#{suffix}-#{System.unique_integer([:positive])}"

    attributes =
      attributes
      |> Keyword.put(:operation_id, operation_id)
      |> Keyword.put_new(:inactivity_ms, 120_000)
      |> Keyword.put_new(:deadline, System.monotonic_time(:millisecond) + 120_000)

    {:ok, context} = StreamContext.new(attributes)
    context
  end

  defp user_message(text) do
    %{
      "type" => "message",
      "role" => "user",
      "content" => [%{"type" => "input_text", "text" => text}]
    }
  end

  defp drain_events(message_ref, events \\ []) do
    receive do
      {^message_ref, event} -> drain_events(message_ref, [event | events])
    after
      0 -> Enum.reverse(events)
    end
  end
end
