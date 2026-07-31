defmodule Synapse.Provider.ResponsesCodec do
  @moduledoc """
  Encodes normalized Provider requests as canonical Responses API maps.

  The Agent Loop owns conversation state and creates a credential-free
  `Synapse.Provider.Request`. This pure codec validates that request again and
  projects it into string-keyed data ready for outer JSON serialization. It does
  not perform HTTP, resolve credentials, select an endpoint, or parse responses.

  The MVP always sends the full projected conversation. It does not rely on
  `previous_response_id` or any state associated with a pooled account. This
  keeps durable conversation ownership inside Synapse and allows a different
  pool credential to serve each turn.

  ## Supported input items

  * `message` preserves user, developer, system, and assistant messages. The
    first three contain `input_text`; assistant replay contains `output_text`.
  * `function_call` represents a completed assistant call. Its decoded argument
    map is encoded as the JSON string required by the Responses wire format.
  * `function_call_output` represents a Tool Result and preserves the exact
    `call_id` pairing from the assistant call.

  Function tools use flat Responses fields: `type`, `name`, `description`,
  `parameters`, and optional `strict`. They are not transformed into the nested
  `%{"type" => "function", "function" => %{...}}` shape used by Tokamak's
  generic Chat Completions-compatible route.

  For the Tokamak Codex pool profile, `stream` is always `true`, `store` is
  always `false`, and `max_output_tokens` is deliberately absent because the
  proxy removes that field before forwarding. Absent instructions are omitted
  rather than encoded as `null`. Request metadata remains local correlation data
  and is not sent upstream by this MVP codec.

  ## Tool continuation

      iex> {:ok, request} = Synapse.Provider.Request.new(%{
      ...>   model: "configured-model",
      ...>   input_items: [
      ...>     %{
      ...>       "type" => "function_call",
      ...>       "call_id" => "call-1",
      ...>       "name" => "read",
      ...>       "arguments" => %{"path" => "mix.exs"}
      ...>     },
      ...>     %{
      ...>       "type" => "function_call_output",
      ...>       "call_id" => "call-1",
      ...>       "output" => "1: defmodule Synapse.MixProject do"
      ...>     }
      ...>   ]
      ...> })
      iex> {:ok, encoded} = Synapse.Provider.ResponsesCodec.encode(request)
      iex> Enum.map(encoded["input"], &{&1["type"], &1["call_id"]})
      [{"function_call", "call-1"}, {"function_call_output", "call-1"}]

  ## One function tool

      iex> {:ok, request} = Synapse.Provider.Request.new(%{
      ...>   model: "configured-model",
      ...>   tools: [%{
      ...>     "type" => "function",
      ...>     "name" => "read",
      ...>     "description" => "Read one project file",
      ...>     "parameters" => %{
      ...>       "type" => "object",
      ...>       "properties" => %{"path" => %{"type" => "string"}},
      ...>       "required" => ["path"],
      ...>       "additionalProperties" => false
      ...>     },
      ...>     "strict" => true
      ...>   }]
      ...> })
      iex> {:ok, encoded} = Synapse.Provider.ResponsesCodec.encode(request)
      iex> [tool] = encoded["tools"]
      iex> {tool["type"], tool["name"], Map.has_key?(tool, "function")}
      {"function", "read", false}

  """

  alias Synapse.Provider.Request

  @typedoc "A canonical string-keyed Responses request ready for JSON serialization."
  @type encoded_request :: Synapse.Provider.json_object()

  @typedoc "A validation failure returned before any HTTP operation is possible."
  @type encode_error :: Request.validation_error() | {:request, :must_be_provider_request}

  @doc """
  Validates and encodes one normalized request.

  Returned maps contain no credentials, endpoint options, `previous_response_id`,
  or `max_output_tokens`.
  """
  @spec encode(Request.t()) :: {:ok, encoded_request()} | {:error, encode_error()}
  def encode(%Request{} = request) do
    with {:ok, request} <- Request.new(Map.from_struct(request)) do
      encoded = %{
        "model" => request.model,
        "input" => Enum.map(request.input_items, &encode_input_item/1),
        "tools" => Enum.map(request.tools, &encode_tool/1),
        "stream" => true,
        "store" => false
      }

      {:ok, put_optional(encoded, "instructions", request.instructions)}
    end
  end

  def encode(_request), do: {:error, {:request, :must_be_provider_request}}

  defp encode_input_item(%{"type" => "message"} = message) do
    %{
      "type" => "message",
      "role" => message["role"],
      "content" =>
        Enum.map(message["content"], fn part ->
          %{"type" => part["type"], "text" => part["text"]}
        end)
    }
  end

  defp encode_input_item(%{"type" => "function_call"} = call) do
    %{
      "type" => "function_call",
      "call_id" => call["call_id"],
      "name" => call["name"],
      "arguments" => Elixir.JSON.encode!(call["arguments"])
    }
    |> put_optional("id", call["id"])
  end

  defp encode_input_item(%{"type" => "function_call_output"} = output) do
    %{
      "type" => "function_call_output",
      "call_id" => output["call_id"],
      "output" => output["output"]
    }
  end

  defp encode_tool(tool) do
    %{
      "type" => "function",
      "name" => tool["name"],
      "description" => tool["description"],
      "parameters" => tool["parameters"]
    }
    |> put_optional("strict", tool["strict"])
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
