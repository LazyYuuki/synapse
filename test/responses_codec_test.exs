defmodule Synapse.Provider.ResponsesCodecTest do
  use ExUnit.Case, async: true

  alias Synapse.Provider.{Request, ResponsesCodec}

  doctest ResponsesCodec

  test "encodes text-only user and assistant messages" do
    expected = fixture("text_request")

    assert {:ok, request} =
             Request.new(
               model: "configured-model",
               instructions: "You are a coding agent.",
               input_items: expected["input"]
             )

    assert {:ok, ^expected} = ResponsesCodec.encode(request)
  end

  test "encodes one canonical flat function tool" do
    expected = fixture("one_tool_request")

    assert {:ok, request} =
             Request.new(
               model: "configured-model",
               input_items: expected["input"],
               tools: expected["tools"]
             )

    assert {:ok, ^expected} = ResponsesCodec.encode(request)

    [tool] = expected["tools"]
    refute Map.has_key?(tool, "function")
    assert Map.has_key?(tool, "name")
    assert Map.has_key?(tool, "parameters")
  end

  test "encodes all four future built-in function schemas in order" do
    expected = fixture("all_tools_request")

    assert {:ok, request} =
             Request.new(model: "configured-model", tools: expected["tools"])

    assert {:ok, ^expected} = ResponsesCodec.encode(request)
    assert Enum.map(expected["tools"], & &1["name"]) == ~w(read write edit bash)
  end

  test "encodes function calls and matching outputs in conversation order" do
    expected = fixture("tool_continuation_request")

    input_items = [
      Enum.at(expected["input"], 0),
      %{
        "type" => "function_call",
        "id" => "item-read",
        "call_id" => "call-read",
        "name" => "read",
        "arguments" => %{"path" => "mix.exs"}
      },
      Enum.at(expected["input"], 2),
      %{
        "type" => "function_call",
        "id" => "item-test",
        "call_id" => "call-test",
        "name" => "bash",
        "arguments" => %{"command" => "mix test"}
      },
      Enum.at(expected["input"], 4)
    ]

    assert {:ok, request} = Request.new(model: "configured-model", input_items: input_items)
    assert {:ok, ^expected} = ResponsesCodec.encode(request)

    assert Enum.map(expected["input"], & &1["type"]) == [
             "message",
             "function_call",
             "function_call_output",
             "function_call",
             "function_call_output"
           ]

    assert Enum.at(expected["input"], 1)["call_id"] ==
             Enum.at(expected["input"], 2)["call_id"]
  end

  test "omits absent optional and Tokamak-incompatible fields" do
    assert {:ok, request} =
             Request.new(
               model: "configured-model",
               metadata: %{"run_id" => "run-1"}
             )

    assert {:ok, encoded} = ResponsesCodec.encode(request)

    assert encoded["stream"]
    refute encoded["store"]
    refute Map.has_key?(encoded, "instructions")
    refute Map.has_key?(encoded, "metadata")
    refute Map.has_key?(encoded, "previous_response_id")
    refute Map.has_key?(encoded, "max_output_tokens")
    refute inspect(encoded) =~ "run-1"
  end

  test "rejects secret-shaped metadata before encoding" do
    assert {:error, {:metadata, :must_be_sanitized_string_keyed_json_object}} =
             Request.new(
               model: "configured-model",
               metadata: %{"nested" => %{"tokamak_api_key" => "secret"}}
             )

    request = %Request{
      model: "configured-model",
      metadata: %{"authorization" => "Bearer secret"}
    }

    assert {:error, {:metadata, :must_be_sanitized_string_keyed_json_object}} =
             ResponsesCodec.encode(request)
  end

  test "rejects unsupported input variants and malformed tool schemas" do
    unsupported = %Request{
      model: "configured-model",
      input_items: [%{"type" => "image", "url" => "https://example.invalid/image.png"}]
    }

    malformed_tool = %Request{
      model: "configured-model",
      tools: [
        %{
          "type" => "function",
          "name" => "read",
          "description" => "Read a file",
          "parameters" => %{"type" => "string"}
        }
      ]
    }

    assert {:error, {:input_items, :must_be_supported_items}} =
             ResponsesCodec.encode(unsupported)

    assert {:error, {:tools, :must_be_function_definitions}} =
             ResponsesCodec.encode(malformed_tool)
  end

  test "rejects values that are not Provider requests" do
    assert {:error, {:request, :must_be_provider_request}} = ResponsesCodec.encode(%{})
  end

  defp fixture(name) do
    path = Path.join([__DIR__, "fixtures", "responses", name <> ".fixture"])
    {fixture, _bindings} = Code.eval_file(path)
    fixture
  end
end
