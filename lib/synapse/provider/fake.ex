defmodule Synapse.Provider.Fake do
  @moduledoc """
  A deterministic scripted implementation of `Synapse.Provider`.

  Fake belongs inside the Provider component because it implements the same
  normalized request, event, response, and error boundary as Tokamak. Agent Loop
  tests should not know how to construct Req responses, split SSE chunks, or
  supply credentials. Those are transport contract concerns already tested by
  `Synapse.Provider.Tokamak`; Fake tests how another component uses a Provider.

  Each script is owned by a small Agent registered under one or more declared
  operation IDs. A caller may run the component under test in another process
  while both resolve the same script through `StreamContext.operation_id`.
  Declaring multiple IDs lets each Provider attempt retain a distinct production
  identity while consuming one ordered test script. `with_script/3` scopes that
  process to one test and always stops it afterward.

  ## Script syntax

  A turn accepts any request:

      {:turn, [event, ...], {:ok, response}}
      {:turn, [event, ...], {:error, error}}

  A four-element turn asserts the exact normalized request:

      {:turn, expected_request, [event, ...], {:ok, response}}

  Turns are consumed once in source order. Events are synchronously emitted in
  source order before the scripted terminal result is returned. A script may be
  declared under one ID for compatibility or under up to 128 unique IDs of at
  most 512 bytes each:

      operation_ids = ["provider-turn-1", "provider-turn-2"]

      Fake.with_script(operation_ids, script, fn ->
        Fake.stream(first_request, sink, first_context)
        Fake.stream(second_request, sink, second_context)
      end)

  The contexts carry the two distinct declared IDs. Small registered alias
  processes resolve both IDs to one script owner and terminate when that owner
  stops. Operation IDs select the script owner; call order still consumes turns
  in script source order.

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

  @max_operation_ids 128
  @max_operation_id_bytes 512
  @alias_lookup_timeout_ms 1_000

  @typedoc "A successful or failed terminal result for one scripted turn."
  @type result :: {:ok, Response.t()} | {:error, Error.t()}

  @typedoc "One request expectation, ordered event sequence, and terminal result."
  @type turn ::
          {:turn, [Synapse.Provider.Event.t()], result()}
          | {:turn, Request.t(), [Synapse.Provider.Event.t()], result()}

  @typedoc "An ordered sequence consumed one turn per `stream/3` call."
  @type script :: [turn()]

  @typedoc "One operation ID or a non-empty unique list sharing one script owner."
  @type operation_ids :: String.t() | [String.t(), ...]

  @doc "Starts a script owner registered under one or more operation IDs."
  @spec start_link(operation_ids(), script()) :: Agent.on_start()
  def start_link(operation_ids, script) do
    operation_ids = validate_operation_ids!(operation_ids)
    validate_script!(script)

    case Agent.start_link(fn -> script end) do
      {:ok, owner} -> register_owner(owner, operation_ids)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Runs a function while a script is available under one or more operation IDs.

  The callback may spawn another process; that process can call `stream/3` with a
  context carrying any declared operation ID. All declared IDs resolve to the
  same ordered script owner.
  """
  @spec with_script(operation_ids(), script(), (-> result)) :: result when result: term()
  def with_script(operation_ids, script, callback) when is_function(callback, 0) do
    {:ok, owner} = start_link(operation_ids, script)

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
    case :global.whereis_name(registry_key(operation_id)) do
      :undefined -> :error
      alias_pid when is_pid(alias_pid) -> resolve_owner(alias_pid)
    end
  end

  defp register_owner(owner, operation_ids) do
    case Enum.reduce_while(operation_ids, :ok, fn operation_id, :ok ->
           case start_alias(owner, operation_id) do
             {:ok, _alias_pid} -> {:cont, :ok}
             {:error, reason} -> {:halt, {:error, reason}}
           end
         end) do
      :ok ->
        {:ok, owner}

      {:error, reason} ->
        Agent.stop(owner)
        {:error, reason}
    end
  end

  defp start_alias(owner, operation_id) do
    caller = self()
    registration_ref = make_ref()

    alias_pid =
      spawn_link(fn ->
        monitor_ref = Process.monitor(owner)
        registered = :global.register_name(registry_key(operation_id), self())
        send(caller, {registration_ref, registered, self()})
        alias_loop(owner, monitor_ref)
      end)

    receive do
      {^registration_ref, :yes, ^alias_pid} ->
        {:ok, alias_pid}

      {^registration_ref, :no, ^alias_pid} ->
        send(alias_pid, :stop)
        {:error, already_started(operation_id)}
    end
  end

  defp alias_loop(owner, monitor_ref) do
    receive do
      {:resolve_owner, caller, lookup_ref} when is_pid(caller) ->
        send(caller, {lookup_ref, owner})
        alias_loop(owner, monitor_ref)

      {:DOWN, ^monitor_ref, :process, ^owner, _reason} ->
        :ok

      :stop ->
        :ok
    end
  end

  defp resolve_owner(alias_pid) do
    lookup_ref = make_ref()
    monitor_ref = Process.monitor(alias_pid)
    send(alias_pid, {:resolve_owner, self(), lookup_ref})

    receive do
      {^lookup_ref, owner} when is_pid(owner) ->
        Process.demonitor(monitor_ref, [:flush])
        if Process.alive?(owner), do: {:ok, owner}, else: :error

      {:DOWN, ^monitor_ref, :process, ^alias_pid, _reason} ->
        :error
    after
      @alias_lookup_timeout_ms ->
        Process.demonitor(monitor_ref, [:flush])
        :error
    end
  end

  defp already_started(operation_id) do
    case :global.whereis_name(registry_key(operation_id)) do
      existing_alias when is_pid(existing_alias) ->
        case resolve_owner(existing_alias) do
          {:ok, existing_owner} -> {:already_started, existing_owner}
          :error -> :already_registered
        end

      :undefined ->
        :already_registered
    end
  end

  defp registry_key(operation_id), do: {__MODULE__, operation_id}

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

  defp validate_operation_ids!(operation_id) when is_binary(operation_id) do
    validate_operation_id!(operation_id)
    [operation_id]
  end

  defp validate_operation_ids!(operation_ids) when is_list(operation_ids) do
    unless operation_ids != [] and length(operation_ids) <= @max_operation_ids and
             Enum.uniq(operation_ids) == operation_ids do
      raise ArgumentError,
            "operation_ids must be a non-empty unique list of at most #{@max_operation_ids} IDs"
    end

    Enum.each(operation_ids, &validate_operation_id!/1)
    operation_ids
  end

  defp validate_operation_ids!(_operation_ids) do
    raise ArgumentError, "operation_ids must be one ID or a non-empty unique list"
  end

  defp validate_operation_id!(operation_id) do
    unless is_binary(operation_id) and String.valid?(operation_id) and
             String.trim(operation_id) != "" and
             byte_size(operation_id) <= @max_operation_id_bytes do
      raise ArgumentError,
            "operation_id must be a non-empty UTF-8 string of at most #{@max_operation_id_bytes} bytes"
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
