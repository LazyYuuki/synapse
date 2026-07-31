defmodule Synapse.Provider.Fake do
  @moduledoc """
  A deterministic scripted implementation of `Synapse.Provider`.

  Fake belongs inside the Provider component because it implements the same
  normalized request, event, response, and error boundary as Tokamak. Agent Loop
  tests should not know how to construct Req responses, split SSE chunks, or
  supply credentials. Those are transport contract concerns already tested by
  `Synapse.Provider.Tokamak`; Fake tests how another component uses a Provider.

  Each script is owned by a small Agent registered under its operation ID. A
  caller may run the component under test in another process while both resolve
  the same script through `StreamContext.operation_id`. `with_script/3` scopes
  that process to one test and always stops it afterward.

  ## Script syntax

  A turn accepts any request:

      {:turn, [event, ...], {:ok, response}}
      {:turn, [event, ...], {:error, error}}

  A four-element turn asserts the exact normalized request:

      {:turn, expected_request, [event, ...], {:ok, response}}

  Turns are consumed once in source order. Events are synchronously emitted in
  source order before the scripted terminal result is returned.

  ## Text example

      script = [
        {:turn,
         [
           %Synapse.Provider.Event.MessageStarted{
             response_id: "response-1",
             model: "test-model"
           },
           %Synapse.Provider.Event.TextDelta{
             item_id: "message-1",
             content_index: 0,
             delta: "Hello"
           },
           %Synapse.Provider.Event.MessageCompleted{response: response}
         ], {:ok, response}}
      ]

  ## Tool-call example

      script = [
        {:turn, first_request,
         [
           %Synapse.Provider.Event.ToolCallStarted{
             item_id: "item-1",
             call_id: "call-1",
             name: "read"
           },
           %Synapse.Provider.Event.ToolCallCompleted{
             item_id: "item-1",
             call_id: "call-1",
             name: "read",
             arguments: %{"path" => "mix.exs"}
           }
         ], {:ok, tool_response}},
        {:turn, continuation_request, final_text_events, {:ok, final_response}}
      ]

  Scripts may intentionally contain incomplete or semantically inconsistent
  event sequences so upper components can prove defensive behavior. Fake only
  validates that values use Provider contract structs. It is intended to
  reproduce text and tool turns, failure before output, interruption after
  output, cancellation, exhausted scripts, and malformed event ordering without
  network access, credentials, timing sleeps, or provider wire data.

  ## Executable example

      iex> {:ok, request} = Synapse.Provider.Request.new(model: "test-model")
      iex> {:ok, response} = Synapse.Provider.Response.new(
      ...>   id: "response-fake-doc",
      ...>   model: "test-model",
      ...>   output_items: [
      ...>     %Synapse.Provider.OutputItem.Message{
      ...>       id: "message-fake-doc",
      ...>       role: :assistant,
      ...>       content: "Hello"
      ...>     }
      ...>   ]
      ...> )
      iex> {:ok, context} = Synapse.Provider.StreamContext.new(
      ...>   operation_id: "fake-provider-doc-example"
      ...> )
      iex> script = [{:turn, [%Synapse.Provider.Event.TextDelta{
      ...>   item_id: "message-fake-doc", content_index: 0, delta: "Hello"
      ...> }], {:ok, response}}]
      iex> result = Synapse.Provider.Fake.with_script(context.operation_id, script, fn ->
      ...>   Synapse.Provider.Fake.stream(request, fn _event -> :ok end, context)
      ...> end)
      iex> result == {:ok, response}
      true
  """

  @behaviour Synapse.Provider

  alias Synapse.Provider.{Error, Request, Response, StreamContext}

  alias Synapse.Provider.Event.{
    Diagnostic,
    MessageCompleted,
    MessageStarted,
    TextDelta,
    ToolCallCompleted,
    ToolCallDelta,
    ToolCallStarted
  }

  @event_modules [
    Diagnostic,
    MessageCompleted,
    MessageStarted,
    TextDelta,
    ToolCallCompleted,
    ToolCallDelta,
    ToolCallStarted
  ]

  @typedoc "A successful or failed terminal result for one scripted turn."
  @type result :: {:ok, Response.t()} | {:error, Error.t()}

  @typedoc "One request expectation, ordered event sequence, and terminal result."
  @type turn ::
          {:turn, [Synapse.Provider.Event.t()], result()}
          | {:turn, Request.t(), [Synapse.Provider.Event.t()], result()}

  @typedoc "An ordered sequence consumed one turn per `stream/3` call."
  @type script :: [turn()]

  @doc "Starts a script owner registered under a non-empty operation ID."
  @spec start_link(String.t(), script()) :: Agent.on_start()
  def start_link(operation_id, script) do
    validate_operation_id!(operation_id)
    validate_script!(script)
    Agent.start_link(fn -> script end, name: registry_name(operation_id))
  end

  @doc """
  Runs a function while a script is available under `operation_id`.

  The callback may spawn another process; that process can call `stream/3` with a
  context carrying the same operation ID.
  """
  @spec with_script(String.t(), script(), (-> result)) :: result when result: term()
  def with_script(operation_id, script, callback) when is_function(callback, 0) do
    {:ok, owner} = start_link(operation_id, script)

    try do
      callback.()
    after
      if Process.alive?(owner), do: Agent.stop(owner)
    end
  end

  @doc "Returns the number of unconsumed turns for an active script."
  @spec remaining_turns(String.t()) :: {:ok, non_neg_integer()} | {:error, :not_configured}
  def remaining_turns(operation_id) do
    case lookup(operation_id) do
      {:ok, owner} -> {:ok, Agent.get(owner, &length/1)}
      :error -> {:error, :not_configured}
    end
  end

  @doc """
  Consumes and streams the next scripted turn for the context's operation ID.

  It checks an optional exact request expectation, emits events synchronously,
  and returns the scripted result. Missing/exhausted scripts, sink rejection,
  cancellation, and deadlines return normalized Provider errors.
  """
  @spec stream(Request.t(), Synapse.Provider.event_sink(), StreamContext.t()) :: result()
  @impl true
  def stream(%Request{} = request, event_sink, %StreamContext{} = context)
      when is_function(event_sink, 1) do
    cond do
      cancelled?(context.cancel_ref) ->
        {:error, interrupted_error(context, false)}

      deadline_elapsed?(context) ->
        {:error, timeout_error(context, false)}

      true ->
        run_turn(request, event_sink, context)
    end
  end

  defp run_turn(request, event_sink, context) do
    with {:ok, turn} <- take_turn(context),
         {:ok, events, result} <- match_request(turn, request, context),
         {:ok, output_started} <- emit_events(events, event_sink, context, false) do
      cond do
        cancelled?(context.cancel_ref) -> {:error, interrupted_error(context, output_started)}
        deadline_elapsed?(context) -> {:error, timeout_error(context, output_started)}
        true -> result
      end
    else
      {:error, %Error{} = error} -> {:error, error}
      {:cancelled, output_started} -> {:error, interrupted_error(context, output_started)}
      {:deadline, output_started} -> {:error, timeout_error(context, output_started)}
    end
  end

  defp take_turn(context) do
    case lookup(context.operation_id) do
      {:ok, owner} ->
        Agent.get_and_update(owner, fn
          [turn | remaining] -> {{:ok, turn}, remaining}
          [] -> {{:error, exhausted_error(context)}, []}
        end)

      :error ->
        {:error, not_configured_error(context)}
    end
  end

  defp match_request({:turn, events, result}, _request, _context),
    do: {:ok, events, result}

  defp match_request({:turn, expected, events, result}, request, context) do
    if request == expected,
      do: {:ok, events, result},
      else: {:error, unexpected_request_error(context)}
  end

  defp emit_events([], _event_sink, _context, output_started), do: {:ok, output_started}

  defp emit_events([event | remaining], event_sink, context, output_started) do
    cond do
      cancelled?(context.cancel_ref) ->
        {:cancelled, output_started}

      deadline_elapsed?(context) ->
        {:deadline, output_started}

      true ->
        emitted_output = output_started or output_event?(event)

        if callback_ok?(event_sink, event) do
          if notify_activity(context) == :ok,
            do: emit_events(remaining, event_sink, context, emitted_output),
            else: {:error, activity_error(context, emitted_output)}
        else
          {:error, sink_error(context, emitted_output)}
        end
    end
  end

  defp notify_activity(%StreamContext{activity_sink: nil}), do: :ok

  defp notify_activity(%StreamContext{} = context) do
    if callback_ok?(context.activity_sink, context), do: :ok, else: :error
  end

  defp callback_ok?(callback, value) do
    try do
      callback.(value) == :ok
    rescue
      _exception -> false
    catch
      _kind, _reason -> false
    end
  end

  defp output_event?(%TextDelta{}), do: true
  defp output_event?(%ToolCallStarted{}), do: true
  defp output_event?(%ToolCallDelta{}), do: true
  defp output_event?(%ToolCallCompleted{}), do: true
  defp output_event?(%MessageCompleted{}), do: true
  defp output_event?(_event), do: false

  defp cancelled?(nil), do: false

  defp cancelled?(cancel_ref) do
    receive do
      {:cancel, ^cancel_ref} -> true
    after
      0 -> false
    end
  end

  defp deadline_elapsed?(%StreamContext{deadline: :infinity}), do: false

  defp deadline_elapsed?(%StreamContext{deadline: deadline}),
    do: System.monotonic_time(:millisecond) >= deadline

  defp lookup(operation_id) do
    case :global.whereis_name({__MODULE__, operation_id}) do
      :undefined -> :error
      owner when is_pid(owner) -> {:ok, owner}
    end
  end

  defp registry_name(operation_id), do: {:global, {__MODULE__, operation_id}}

  defp validate_script!(script) when is_list(script) do
    if Enum.all?(script, &valid_turn?/1),
      do: :ok,
      else: raise(ArgumentError, "Fake script contains an invalid turn")
  end

  defp validate_script!(_script), do: raise(ArgumentError, "Fake script must be a list")

  defp valid_turn?({:turn, events, result}), do: valid_events?(events) and valid_result?(result)

  defp valid_turn?({:turn, %Request{}, events, result}),
    do: valid_events?(events) and valid_result?(result)

  defp valid_turn?(_turn), do: false

  defp valid_events?(events) when is_list(events) do
    Enum.all?(events, fn event -> is_struct(event) and event.__struct__ in @event_modules end)
  end

  defp valid_events?(_events), do: false

  defp valid_result?({:ok, %Response{}}), do: true
  defp valid_result?({:error, %Error{}}), do: true
  defp valid_result?(_result), do: false

  defp validate_operation_id!(operation_id) do
    unless is_binary(operation_id) and String.valid?(operation_id) and
             String.trim(operation_id) != "" do
      raise ArgumentError, "operation_id must be a non-empty UTF-8 string"
    end
  end

  defp not_configured_error(context) do
    configuration_error(context, "Fake Provider has no script for this operation")
  end

  defp exhausted_error(context) do
    configuration_error(context, "Fake Provider script is exhausted")
  end

  defp configuration_error(context, message) do
    %Error{
      kind: :configuration,
      message: message,
      retryable: false,
      output_started: false,
      operation_id: context.operation_id
    }
  end

  defp unexpected_request_error(context) do
    %Error{
      kind: :protocol,
      message: "Fake Provider received an unexpected request",
      retryable: false,
      output_started: false,
      operation_id: context.operation_id
    }
  end

  defp sink_error(context, output_started) do
    %Error{
      kind: :protocol,
      message: "Fake Provider event sink rejected an event",
      retryable: false,
      output_started: output_started,
      operation_id: context.operation_id
    }
  end

  defp activity_error(context, output_started) do
    %Error{
      kind: :protocol,
      message: "Fake Provider activity sink rejected progress",
      retryable: false,
      output_started: output_started,
      operation_id: context.operation_id
    }
  end

  defp interrupted_error(context, output_started) do
    %Error{
      kind: :interrupted,
      message: "Fake Provider execution was cancelled",
      retryable: false,
      output_started: output_started,
      operation_id: context.operation_id
    }
  end

  defp timeout_error(context, output_started) do
    %Error{
      kind: :timeout,
      message: "Fake Provider deadline elapsed",
      retryable: false,
      output_started: output_started,
      operation_id: context.operation_id
    }
  end
end
