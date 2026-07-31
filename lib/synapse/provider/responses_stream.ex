defmodule Synapse.Provider.ResponsesStream do
  @moduledoc """
  Reduces framed Responses SSE payloads into normalized Provider events.

  `Synapse.Provider.SSEDecoder` owns byte and line framing. Tokamak transport owns
  the HTTP request. This module sits between them: it decodes JSON only after
  a complete `Synapse.Provider.SSEEvent` exists, validates known Responses event
  shapes, and accumulates one immutable response state.

  State retains the response identity, output items keyed by stable item ID,
  function calls keyed by both item ID and call ID, output indexes, text and
  argument fragments, usage, terminal status, and whether observable model
  output began. Each `push/2` returns a new state and ordered normalized events;
  no process or mailbox is required.

  ## Function-call lifecycle

      output_item.added(function_call)
        -> ToolCallStarted
        -> function_call_arguments.delta(item_id, call_id)
        -> ToolCallDelta
        -> function_call_arguments.done
        -> decode complete JSON object
        -> ToolCallCompleted
        -> response.completed
        -> completed FunctionCall output item is executable

  Interleaved calls remain deterministic because fragments are never associated
  by arrival position alone. The reducer resolves each delta through its item ID
  and verifies any supplied call ID against the call registered at item start.

  `ToolCallCompleted` means argument JSON is structurally complete, not that the
  call may execute. Execution must wait for successful `response.completed` and
  the terminal response returned by `finish/1`. Malformed completed arguments
  are a provider protocol failure because no validated tool invocation exists
  yet; they are not a Tool System execution failure.

  Unknown future event types produce a bounded `Diagnostic` containing only the
  event type. Malformed known events fail instead of being ignored. Raw decoded
  response maps, raw payloads, and upstream error messages never leave this
  reducer.

  ## Limits

  Defaults bound one response to 64,000 model-output bytes, 64,000 accumulated
  function-argument bytes, 128 output items, 32 content parts per message, 32
  compatibility diagnostics, and 10,000 framed Responses events. Identifier
  fields are limited to 512 bytes. `new/2` permits lower test or endpoint limits
  but rejects non-positive and unreasonable values.

  ## Adding a known Responses event

  Add its dispatch and strict shape validation here, extend the normalized Event
  union only when callers need a new contract value, update output accounting,
  and add valid, malformed, and ordering tests. Preserve unknown-event fallback
  for forward compatibility. Tokamak transport does not change because it owns
  bytes and request lifetime, not Responses event semantics.
  """

  alias Synapse.Provider.{Error, JSON, Response, SSEEvent}

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

  @diagnostic_type_bytes 128
  @default_max_output_bytes 64_000
  @default_max_argument_bytes 64_000
  @default_max_output_items 128
  @default_max_content_parts 32
  @default_max_diagnostics 32
  @default_max_events 10_000
  @max_identifier_bytes 512

  @maximum_limits %{
    max_output_bytes: 8 * 1024 * 1024,
    max_argument_bytes: 1024 * 1024,
    max_output_items: 1_024,
    max_content_parts: 256,
    max_diagnostics: 256,
    max_events: 100_000
  }

  defstruct operation_id: nil,
            response_id: nil,
            model: nil,
            status: :waiting,
            items: %{},
            output_order: %{},
            calls: %{},
            usage: %{},
            output_bytes: 0,
            argument_bytes: 0,
            diagnostic_count: 0,
            event_count: 0,
            output_started: false,
            terminal_response: nil,
            terminal_seen: false,
            done_seen: false,
            max_output_bytes: @default_max_output_bytes,
            max_argument_bytes: @default_max_argument_bytes,
            max_output_items: @default_max_output_items,
            max_content_parts: @default_max_content_parts,
            max_diagnostics: @default_max_diagnostics,
            max_events: @default_max_events

  @typedoc """
  Opaque immutable reducer state for one Responses stream.

  Callers create it with `new/2` and pass returned versions through `push/2` and
  `finish/1`; item maps, counters, flags, and limit fields are implementation
  details rather than a construction API.
  """
  @opaque t :: %__MODULE__{
            operation_id: String.t(),
            response_id: String.t() | nil,
            model: String.t() | nil,
            status: :waiting | :in_progress | :completed,
            items: %{optional(String.t()) => map()},
            output_order: %{optional(non_neg_integer()) => String.t()},
            calls: %{optional(String.t()) => String.t()},
            usage: Synapse.Provider.json_object(),
            output_bytes: non_neg_integer(),
            argument_bytes: non_neg_integer(),
            diagnostic_count: non_neg_integer(),
            event_count: non_neg_integer(),
            output_started: boolean(),
            terminal_response: Response.t() | nil,
            terminal_seen: boolean(),
            done_seen: boolean(),
            max_output_bytes: pos_integer(),
            max_argument_bytes: pos_integer(),
            max_output_items: pos_integer(),
            max_content_parts: pos_integer(),
            max_diagnostics: pos_integer(),
            max_events: pos_integer()
          }

  @typedoc "Trusted response-accumulator limits."
  @type option ::
          {:max_output_bytes, pos_integer()}
          | {:max_argument_bytes, pos_integer()}
          | {:max_output_items, pos_integer()}
          | {:max_content_parts, pos_integer()}
          | {:max_diagnostics, pos_integer()}
          | {:max_events, pos_integer()}

  @typedoc "A successful event reduction or a normalized terminal Provider error."
  @type push_result ::
          {:ok, t(), [Synapse.Provider.Event.t()]}
          | {:error, Error.t()}

  @doc """
  Creates empty reducer state with validated trusted resource limits.

  Invalid operation IDs, unknown options, non-positive values, and values above
  hard ceilings raise `ArgumentError`; no process is started.
  """
  @spec new(String.t(), [option()]) :: t()
  def new(operation_id, options \\ []) when is_binary(operation_id) do
    if String.valid?(operation_id) and String.trim(operation_id) != "" do
      options =
        Keyword.validate!(options,
          max_output_bytes: @default_max_output_bytes,
          max_argument_bytes: @default_max_argument_bytes,
          max_output_items: @default_max_output_items,
          max_content_parts: @default_max_content_parts,
          max_diagnostics: @default_max_diagnostics,
          max_events: @default_max_events
        )

      Enum.each(options, fn {name, value} -> validate_limit!(name, value) end)

      struct!(__MODULE__, Keyword.put(options, :operation_id, operation_id))
    else
      raise ArgumentError, "operation_id must be a non-empty UTF-8 string"
    end
  end

  @doc """
  Decodes and reduces one complete SSE frame.

  `[DONE]` is accepted as an optional post-terminal marker. It is never accepted
  as a substitute for `response.completed` or `response.failed`.
  """
  @spec push(t(), SSEEvent.t()) :: push_result()
  def push(%__MODULE__{} = state, %SSEEvent{data: data}) when is_binary(data) do
    cond do
      String.trim(data) == "[DONE]" ->
        {:ok, %{state | done_seen: true}, []}

      state.done_seen ->
        protocol_error(state, "Received Responses data after [DONE]")

      state.terminal_seen ->
        protocol_error(state, "Received a Responses event after terminal completion")

      true ->
        with {:ok, state} <- reserve_event(state) do
          decode_and_reduce(state, data)
        end
    end
  end

  @doc """
  Returns the authoritative completed response or rejects an incomplete stream.

  A prior `[DONE]` marker is optional. EOF without a terminal Responses event is
  an interruption, even when syntactically complete SSE frames were received.
  """
  @spec finish(t()) :: {:ok, Response.t()} | {:error, Error.t()}
  def finish(%__MODULE__{terminal_response: %Response{} = response}), do: {:ok, response}

  def finish(%__MODULE__{} = state) do
    provider_error(
      state,
      :interrupted,
      "Responses stream ended before a terminal event",
      false,
      %{}
    )
  end

  defp decode_and_reduce(state, data) do
    case Elixir.JSON.decode(data) do
      {:ok, payload} when is_map(payload) ->
        reduce_payload(state, payload)

      {:ok, _payload} ->
        protocol_error(state, "Responses event JSON must be an object")

      {:error, _reason} ->
        protocol_error(state, "Malformed Responses event JSON")
    end
  end

  defp reduce_payload(state, payload) do
    case payload["type"] do
      "response.created" -> reduce_created(state, payload)
      "response.output_item.added" -> reduce_output_item_added(state, payload)
      "response.output_text.delta" -> reduce_text_delta(state, payload)
      "response.function_call_arguments.delta" -> reduce_call_delta(state, payload)
      "response.function_call_arguments.done" -> reduce_call_done(state, payload)
      "response.completed" -> reduce_completed(state, payload)
      "response.failed" -> reduce_failed(state, payload)
      type when is_binary(type) -> reduce_unknown(state, type)
      _type -> protocol_error(state, "Responses event is missing a string type")
    end
  end

  defp reduce_created(%__MODULE__{response_id: response_id} = state, _payload)
       when not is_nil(response_id),
       do: protocol_error(state, "Received duplicate response.created")

  defp reduce_created(state, payload) do
    response = payload["response"]

    if is_map(response) and bounded_identifier?(response["id"]) and
         bounded_identifier?(response["model"]) do
      state = %{
        state
        | response_id: response["id"],
          model: response["model"],
          status: :in_progress
      }

      {:ok, state, [%MessageStarted{response_id: state.response_id, model: state.model}]}
    else
      protocol_error(state, "Malformed response.created event")
    end
  end

  defp reduce_output_item_added(%__MODULE__{response_id: nil} = state, _payload),
    do: protocol_error(state, "Received output before response.created")

  defp reduce_output_item_added(state, payload) do
    item = payload["item"]
    output_index = payload["output_index"]

    cond do
      not is_map(item) or not is_integer(output_index) or output_index < 0 ->
        protocol_error(state, "Malformed response.output_item.added event")

      Map.has_key?(state.output_order, output_index) ->
        protocol_error(state, "Received duplicate output index")

      map_size(state.items) >= state.max_output_items ->
        protocol_error(state, "Response exceeds the output-item limit")

      item["type"] == "message" ->
        add_message_item(state, item, output_index)

      item["type"] == "function_call" ->
        add_function_call_item(state, item, output_index)

      is_binary(item["type"]) ->
        diagnostic(state, "unknown_output_item", item["type"])

      true ->
        protocol_error(state, "Output item is missing a string type")
    end
  end

  defp add_message_item(state, item, output_index) do
    id = item["id"]

    cond do
      not bounded_identifier?(id) or item["role"] != "assistant" ->
        protocol_error(state, "Malformed assistant message output item")

      Map.has_key?(state.items, id) ->
        protocol_error(state, "Received duplicate output item ID")

      not valid_initial_content?(Map.get(item, "content", [])) ->
        protocol_error(state, "Malformed assistant message content")

      length(Map.get(item, "content", [])) > state.max_content_parts ->
        protocol_error(state, "Assistant message exceeds the content-part limit")

      true ->
        content = Map.get(item, "content", [])

        with {:ok, state} <- reserve_output(state, content_bytes(content)) do
          normalized_item = %{
            kind: :message,
            id: id,
            output_index: output_index,
            text: initial_content(content)
          }

          {:ok, put_item(state, normalized_item), []}
        end
    end
  end

  defp add_function_call_item(state, item, output_index) do
    id = item["id"]
    call_id = item["call_id"]
    name = item["name"]
    initial_arguments = Map.get(item, "arguments", "")

    cond do
      not bounded_identifier?(id) or not bounded_identifier?(call_id) or
        not bounded_identifier?(name) or not is_binary(initial_arguments) ->
        protocol_error(state, "Malformed function-call output item")

      Map.has_key?(state.items, id) or Map.has_key?(state.calls, call_id) ->
        protocol_error(state, "Received duplicate function-call identity")

      true ->
        with {:ok, state} <- reserve_arguments(state, byte_size(initial_arguments)),
             {:ok, state} <- reserve_output(state, byte_size(initial_arguments)) do
          normalized_item = %{
            kind: :function_call,
            id: id,
            output_index: output_index,
            call_id: call_id,
            name: name,
            argument_fragments: if(initial_arguments == "", do: [], else: [initial_arguments]),
            arguments: nil,
            complete: false
          }

          state =
            state
            |> put_item(normalized_item)
            |> then(&%{&1 | calls: Map.put(&1.calls, call_id, id), output_started: true})

          {:ok, state, [%ToolCallStarted{item_id: id, call_id: call_id, name: name}]}
        end
    end
  end

  defp reduce_text_delta(state, payload) do
    item_id = payload["item_id"]
    content_index = payload["content_index"]
    delta = payload["delta"]

    with {:ok, item} <- fetch_item(state, item_id, :message),
         true <- is_integer(content_index) and content_index >= 0 and is_binary(delta),
         true <-
           Map.has_key?(item.text, content_index) or
             map_size(item.text) < state.max_content_parts,
         {:ok, state} <- reserve_output(state, byte_size(delta)) do
      fragments = Map.get(item.text, content_index, [])
      item = %{item | text: Map.put(item.text, content_index, [delta | fragments])}
      state = %{state | items: Map.put(state.items, item_id, item), output_started: true}

      {:ok, state, [%TextDelta{item_id: item_id, content_index: content_index, delta: delta}]}
    else
      {:error, %Error{}} = error -> error
      _invalid -> protocol_error(state, "Malformed response.output_text.delta event")
    end
  end

  defp reduce_call_delta(state, payload) do
    item_id = payload["item_id"]
    delta = payload["delta"]

    with {:ok, item} <- fetch_call(state, item_id, payload["call_id"]),
         false <- item.complete,
         true <- is_binary(delta),
         {:ok, state} <- reserve_arguments(state, byte_size(delta)),
         {:ok, state} <- reserve_output(state, byte_size(delta)) do
      item = %{item | argument_fragments: [delta | item.argument_fragments]}
      state = %{state | items: Map.put(state.items, item_id, item), output_started: true}

      {:ok, state, [%ToolCallDelta{item_id: item_id, call_id: item.call_id, delta: delta}]}
    else
      {:error, %Error{}} = error -> error
      _invalid -> protocol_error(state, "Malformed function-call argument delta")
    end
  end

  defp reduce_call_done(state, payload) do
    item_id = payload["item_id"]
    completed_arguments = payload["arguments"]

    with {:ok, item} <- fetch_call(state, item_id, payload["call_id"]),
         false <- item.complete,
         true <- is_binary(completed_arguments),
         accumulated <- item.argument_fragments |> Enum.reverse() |> IO.iodata_to_binary(),
         true <- accumulated == "" or accumulated == completed_arguments,
         {:ok, state} <- reserve_unstreamed_arguments(state, accumulated, completed_arguments),
         {:ok, arguments} when is_map(arguments) <- Elixir.JSON.decode(completed_arguments),
         true <- JSON.object?(arguments) do
      item = %{item | arguments: arguments, complete: true}
      state = %{state | items: Map.put(state.items, item_id, item), output_started: true}

      {:ok, state,
       [
         %ToolCallCompleted{
           item_id: item_id,
           call_id: item.call_id,
           name: item.name,
           arguments: arguments
         }
       ]}
    else
      {:error, %Error{}} = error -> error
      _invalid -> protocol_error(state, "Malformed completed function-call arguments")
    end
  end

  defp reduce_completed(%__MODULE__{response_id: nil} = state, _payload),
    do: protocol_error(state, "Received response.completed before response.created")

  defp reduce_completed(state, payload) do
    response = payload["response"]

    cond do
      not valid_completed_response?(state, response) ->
        protocol_error(state, "Malformed response.completed event")

      incomplete_call?(state) ->
        protocol_error(state, "Response completed with an incomplete function call")

      true ->
        with {:ok, usage} <- normalize_usage(response),
             {:ok, completed_response} <-
               Response.new(
                 id: state.response_id,
                 model: state.model,
                 output_items: build_output_items(state),
                 usage: usage
               ) do
          state = %{
            state
            | status: :completed,
              usage: usage,
              terminal_response: completed_response,
              terminal_seen: true
          }

          {:ok, state, [%MessageCompleted{response: completed_response}]}
        else
          _error -> protocol_error(state, "Completed response could not be normalized")
        end
    end
  end

  defp reduce_failed(state, payload) do
    response = payload["response"]

    if is_map(response) and response["status"] == "failed" and
         non_empty_string?(state.response_id) and response["id"] == state.response_id do
      code = if is_map(response["error"]), do: response["error"]["code"]

      details =
        if non_empty_string?(code),
          do: %{"code" => bounded(code, @diagnostic_type_bytes)},
          else: %{}

      provider_error(
        state,
        :upstream,
        "Provider reported a failed response",
        false,
        details
      )
    else
      protocol_error(state, "Malformed response.failed event")
    end
  end

  defp reduce_unknown(state, type) do
    diagnostic(state, "unknown_responses_event", type)
  end

  defp diagnostic(state, code, type) do
    if state.diagnostic_count < state.max_diagnostics do
      event = %Diagnostic{
        code: code,
        message: "Ignored an unknown Responses event",
        details: %{"type" => bounded(type, @diagnostic_type_bytes)}
      }

      {:ok, %{state | diagnostic_count: state.diagnostic_count + 1}, [event]}
    else
      protocol_error(state, "Response exceeds the compatibility-diagnostic limit")
    end
  end

  defp fetch_item(state, item_id, kind) when is_binary(item_id) do
    case state.items[item_id] do
      %{kind: ^kind} = item -> {:ok, item}
      _item -> :error
    end
  end

  defp fetch_item(_state, _item_id, _kind), do: :error

  defp fetch_call(state, item_id, supplied_call_id) do
    with {:ok, item} <- fetch_item(state, item_id, :function_call),
         true <- is_nil(supplied_call_id) or supplied_call_id == item.call_id,
         true <- state.calls[item.call_id] == item_id do
      {:ok, item}
    else
      _invalid -> :error
    end
  end

  defp put_item(state, item) do
    %{
      state
      | items: Map.put(state.items, item.id, item),
        output_order: Map.put(state.output_order, item.output_index, item.id)
    }
  end

  defp build_output_items(state) do
    state.output_order
    |> Enum.sort_by(fn {output_index, _item_id} -> output_index end)
    |> Enum.map(fn {_output_index, item_id} -> normalize_output_item(state.items[item_id]) end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_output_item(%{kind: :message} = item) do
    content =
      item.text
      |> Enum.sort_by(fn {content_index, _fragments} -> content_index end)
      |> Enum.map_join(fn {_content_index, fragments} ->
        fragments |> Enum.reverse() |> IO.iodata_to_binary()
      end)

    %Message{id: item.id, role: :assistant, content: content}
  end

  defp normalize_output_item(%{kind: :function_call, complete: true} = item) do
    %FunctionCall{
      id: item.id,
      call_id: item.call_id,
      name: item.name,
      arguments: item.arguments
    }
  end

  defp normalize_output_item(_item), do: nil

  defp valid_completed_response?(state, response) do
    is_map(response) and response["status"] == "completed" and
      response["id"] == state.response_id and response["model"] == state.model and
      valid_optional_output?(response)
  end

  defp valid_optional_output?(response) do
    not Map.has_key?(response, "output") or is_list(response["output"])
  end

  defp normalize_usage(response) do
    usage = Map.get(response, "usage", %{})

    if JSON.object?(usage) do
      {:ok, normalized_usage(usage)}
    else
      :error
    end
  end

  defp normalized_usage(usage) do
    %{}
    |> put_non_negative_integer("input_tokens", usage["input_tokens"])
    |> put_non_negative_integer("output_tokens", usage["output_tokens"])
    |> put_non_negative_integer("total_tokens", usage["total_tokens"])
    |> put_usage_detail("input_tokens_details", "cached_tokens", usage)
    |> put_usage_detail("output_tokens_details", "reasoning_tokens", usage)
  end

  defp put_non_negative_integer(map, _key, nil), do: map

  defp put_non_negative_integer(map, key, value)
       when is_integer(value) and value >= 0 and value <= 9_223_372_036_854_775_807,
       do: Map.put(map, key, value)

  defp put_non_negative_integer(map, _key, _value), do: map

  defp put_usage_detail(map, detail_key, value_key, usage) do
    case usage[detail_key] do
      %{^value_key => value}
      when is_integer(value) and value >= 0 and value <= 9_223_372_036_854_775_807 ->
        Map.put(map, detail_key, %{value_key => value})

      _details ->
        map
    end
  end

  defp incomplete_call?(state) do
    Enum.any?(state.items, fn
      {_id, %{kind: :function_call, complete: false}} -> true
      _item -> false
    end)
  end

  defp valid_initial_content?(content) when is_list(content) do
    Enum.all?(content, fn
      %{"type" => "output_text", "text" => text} -> is_binary(text)
      _part -> false
    end)
  end

  defp valid_initial_content?(_content), do: false

  defp initial_content(content) do
    content
    |> Enum.with_index()
    |> Map.new(fn {%{"text" => text}, index} -> {index, [text]} end)
  end

  defp content_bytes(content),
    do: Enum.reduce(content, 0, fn %{"text" => text}, total -> total + byte_size(text) end)

  defp reserve_event(state) do
    if state.event_count < state.max_events,
      do: {:ok, %{state | event_count: state.event_count + 1}},
      else: protocol_error(state, "Response exceeds the event-count limit")
  end

  defp reserve_output(state, bytes) do
    total = state.output_bytes + bytes

    if total <= state.max_output_bytes,
      do: {:ok, %{state | output_bytes: total}},
      else: protocol_error(state, "Response exceeds the model-output byte limit")
  end

  defp reserve_arguments(state, bytes) do
    total = state.argument_bytes + bytes

    if total <= state.max_argument_bytes,
      do: {:ok, %{state | argument_bytes: total}},
      else: protocol_error(state, "Response exceeds the function-argument byte limit")
  end

  defp reserve_unstreamed_arguments(state, "", completed_arguments) do
    with {:ok, state} <- reserve_arguments(state, byte_size(completed_arguments)),
         {:ok, state} <- reserve_output(state, byte_size(completed_arguments)) do
      {:ok, state}
    end
  end

  defp reserve_unstreamed_arguments(state, _accumulated, _completed_arguments), do: {:ok, state}

  defp protocol_error(state, message) do
    provider_error(state, :protocol, message, false, %{})
  end

  defp provider_error(state, kind, message, retryable, details) do
    {:error,
     %Error{
       kind: kind,
       message: message,
       retryable: retryable,
       output_started: state.output_started,
       operation_id: state.operation_id,
       details: details
     }}
  end

  defp bounded(value, limit) do
    cond do
      byte_size(value) <= limit ->
        value

      limit == 0 ->
        ""

      true ->
        prefix = binary_part(value, 0, limit)
        if String.valid?(prefix), do: prefix, else: bounded(value, limit - 1)
    end
  end

  defp non_empty_string?(value) do
    is_binary(value) and String.valid?(value) and String.trim(value) != ""
  end

  defp bounded_identifier?(value),
    do: non_empty_string?(value) and byte_size(value) <= @max_identifier_bytes

  defp validate_limit!(name, value) do
    maximum = Map.fetch!(@maximum_limits, name)

    unless is_integer(value) and value > 0 and value <= maximum do
      raise ArgumentError,
            "#{name} must be a positive integer no greater than #{maximum}"
    end
  end
end
