defmodule Synapse.Tool.LiveSchemaTest do
  use ExUnit.Case, async: false

  alias Synapse.Provider.{Request, StreamContext, Tokamak}
  alias Synapse.Provider.Event.{MessageCompleted, ToolCallCompleted, ToolCallStarted}
  alias Synapse.Provider.OutputItem.FunctionCall
  alias Synapse.Tool.{Call, Registry}

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

  test "Tokamak accepts all four canonical strict Tool schemas without executing the call" do
    test_pid = self()
    message_ref = make_ref()
    specifications = Registry.specifications()

    assert Enum.map(specifications, & &1["name"]) == ["read", "write", "edit", "bash"]
    assert length(specifications) == 4
    assert Enum.all?(specifications, &(&1["type"] == "function" and &1["strict"] == true))

    assert Enum.all?(specifications, fn specification ->
             specification["parameters"]["additionalProperties"] == false
           end)

    read = Enum.find(specifications, &(&1["name"] == "read"))
    bash = Enum.find(specifications, &(&1["name"] == "bash"))
    assert read["parameters"]["properties"]["offset"]["type"] == ["integer", "null"]
    assert read["parameters"]["properties"]["limit"]["type"] == ["integer", "null"]
    assert bash["parameters"]["properties"]["timeout_ms"]["type"] == ["integer", "null"]

    {:ok, request} =
      Request.new(
        model: System.fetch_env!("SYNAPSE_MODEL"),
        instructions:
          "Call read exactly once with path mix.exs, offset null, and limit null. " <>
            "Do not answer with text and do not call another function.",
        input_items: [user_message("Perform the required Tool schema acceptance call now.")],
        tools: specifications
      )

    sink = fn event ->
      send(test_pid, {message_ref, event})
      :ok
    end

    assert {:ok, response} = Tokamak.stream(request, sink, context!())
    assert response.status == :completed
    events = drain_events(message_ref)

    assert [started] = Enum.filter(events, &is_struct(&1, ToolCallStarted))
    assert Enum.count(events, &is_struct(&1, MessageCompleted)) == 1

    assert [completed] = Enum.filter(events, &is_struct(&1, ToolCallCompleted))
    assert completed.name == "read"
    assert completed.arguments == %{"path" => "mix.exs", "offset" => nil, "limit" => nil}
    assert Enum.all?(Map.keys(completed.arguments), &is_binary/1)
    assert started.item_id == completed.item_id
    assert started.call_id == completed.call_id
    assert started.name == completed.name

    assert [call] = Enum.filter(response.output_items, &is_struct(&1, FunctionCall))
    assert call.id == completed.item_id
    assert call.call_id == completed.call_id
    assert call.name == completed.name
    assert call.arguments == completed.arguments
    assert {:ok, _module} = Registry.fetch(call.name)
    assert {:ok, tool_call} = Call.from_provider(call)
    assert tool_call.call_id == call.call_id
    assert tool_call.arguments == call.arguments
  end

  defp context! do
    {:ok, context} =
      StreamContext.new(
        operation_id: "live-tool-schema-#{System.unique_integer([:positive])}",
        inactivity_ms: 120_000,
        deadline: System.monotonic_time(:millisecond) + 120_000
      )

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
