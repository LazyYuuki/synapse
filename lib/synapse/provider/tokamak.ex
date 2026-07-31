defmodule Synapse.Provider.Tokamak do
  @moduledoc """
  Streams one normalized request through Tokamak's Codex pool proxy.

  The production endpoint is fixed at
  `https://api.tokamak.sh/v1/agent-pool/codex-proxy/responses`. Trusted callers
  may inject an endpoint and Req adapter through `stream/4` for deterministic
  tests; neither option is part of model input or a Provider Request.

  ## Ownership

  The process calling `stream/3` is the operation coordinator. It starts and
  monitors one temporary worker that owns `Req.request/1` and Finch's
  `stream_while` callback. The coordinator retains the worker PID as the
  cancellation handle and kills it on `{:cancel, cancel_ref}`, inactivity, or an
  absolute deadline. Worker termination causes the owned Finch request to close.
  A linked watchdog monitors the coordinator and kills the worker if its caller
  exits, preventing an orphaned HTTP operation.

  Req's function-based `:into` callback processes one body chunk at a time. It
  does not use Req's `into: :self` firehose. Each chunk passes through
  `SSEDecoder`, `ResponsesStream`, and the synchronous event sink before Req asks
  Finch for more data, supplying backpressure through the entire pipeline.

  Req and its supervised Finch pool own reusable connection processes. The
  temporary worker owns this request attempt and its reducer state; it does not
  own the shared pool. The transport performs exactly one attempt with Req retry
  and redirects disabled. It classifies retryability for Runtime or Agent policy
  but never performs a replay itself, because partial model output cannot be
  transparently duplicated safely.

  ## Limits and timeouts

  * Connect timeout: 10 seconds.
  * Request body: 8 MiB, below Tokamak's observed 32 MiB upstream reader.
  * Error body retained internally: 4 KiB; body content never enters Provider
    errors.
  * Transport chunk: 2 MiB, SSE line: 64 KiB, and SSE frame fields: 1 MiB,
    enforced by `SSEDecoder`.
  * Model output and function arguments: 64,000 bytes each, with count limits
    for events, output items, content parts, and compatibility diagnostics,
    enforced by `ResponsesStream`.
  * Receive inactivity: `StreamContext.inactivity_ms`, also enforced by the
    coordinator between meaningful normalized event batches.
  * Absolute deadline: `StreamContext.deadline` in monotonic milliseconds.

  Redirects are returned and classified as protocol failures rather than
  followed, preventing authorization from reaching another origin. See
  `docs/PROVIDERS.md` for the researched Tokamak proxy behavior and limitations.

  The proxy currently labels streamed Responses bytes as
  `text/plain; charset=utf-8` despite sending valid SSE framing. This transport
  accepts that endpoint-specific compatibility type in addition to
  `text/event-stream`, but still requires complete SSE and a terminal Responses
  event before returning success.
  """

  @behaviour Synapse.Provider

  alias Synapse.Provider.{
    Credentials,
    Error,
    Request,
    Response,
    ResponsesCodec,
    ResponsesStream,
    SSEDecoder,
    StreamContext
  }

  @endpoint "https://api.tokamak.sh/v1/agent-pool/codex-proxy/responses"
  @connect_timeout_ms 10_000
  @max_request_bytes 8 * 1024 * 1024
  @max_error_body_bytes 4 * 1024
  @request_id_bytes 128
  @state_key_prefix :synapse_tokamak_stream

  @typedoc "Trusted transport-only options unavailable to model input."
  @type option ::
          {:adapter, (Req.Request.t() -> {Req.Request.t(), Req.Response.t() | Exception.t()})}
          | {:credential_source, Credentials.source()}
          | {:endpoint, String.t()}

  @doc """
  Runs one production Tokamak request through the fixed trusted endpoint.

  The calling process owns cancellation and blocks until one normalized terminal
  result is returned. Events are delivered synchronously with backpressure.
  """
  @spec stream(Request.t(), Synapse.Provider.event_sink(), StreamContext.t()) ::
          {:ok, Response.t()} | {:error, Error.t()}
  @impl true
  def stream(request, event_sink, context), do: stream(request, event_sink, context, [])

  @doc """
  Runs one request with trusted transport overrides.

  `:adapter` and `:endpoint` exist for local deterministic tests.
  `:credential_source` injects a trusted test source or future broker lookup and
  is resolved only inside the request worker. None may originate from model
  input. Production code should call `stream/3`, which uses the fixed HTTPS
  endpoint, environment credential adapter, and Req's Finch adapter.
  """
  @spec stream(Request.t(), Synapse.Provider.event_sink(), StreamContext.t(), [option()]) ::
          {:ok, Response.t()} | {:error, Error.t()}
  def stream(%Request{} = request, event_sink, %StreamContext{} = context, options)
      when is_function(event_sink, 1) and is_list(options) do
    with {:ok, context} <- validate_context(context),
         {:ok, transport} <- validate_options(options, context.operation_id),
         {:ok, encoded} <- encode_request(request, context.operation_id),
         {:ok, body} <- encode_body(encoded, context.operation_id),
         :ok <- enforce_request_size(body, context.operation_id),
         :ok <- enforce_deadline(context) do
      run_owned_request(request, body, event_sink, context, transport)
    end
  end

  @doc """
  Asynchronously requests cancellation from a process blocked in `stream/3` or `stream/4`.

  `operation_pid` is the operation coordinator, not its temporary HTTP worker.
  Only a reference matching the operation's `StreamContext.cancel_ref` is
  honored; the terminal interrupted result is returned by the stream call.
  """
  @spec cancel(pid(), reference()) :: :ok
  def cancel(operation_pid, cancel_ref) when is_pid(operation_pid) and is_reference(cancel_ref) do
    send(operation_pid, {:cancel, cancel_ref})
    :ok
  end

  defp validate_context(context) do
    case StreamContext.new(Map.from_struct(context)) do
      {:ok, context} ->
        {:ok, context}

      {:error, reason} ->
        {:error, local_error(context.operation_id, "Invalid stream context", reason)}
    end
  end

  defp validate_options(options, operation_id) do
    allowed = [:adapter, :credential_source, :endpoint]

    with [] <- Keyword.keys(options) -- allowed,
         endpoint <- Keyword.get(options, :endpoint, @endpoint),
         true <- trusted_endpoint?(endpoint),
         adapter <- Keyword.get(options, :adapter),
         true <- is_nil(adapter) or is_function(adapter, 1),
         source <- Keyword.get(options, :credential_source, &System.get_env/1),
         true <- is_function(source, 1) do
      {:ok, %{endpoint: endpoint, adapter: adapter, credential_source: source}}
    else
      _invalid -> {:error, local_error(operation_id, "Invalid trusted transport options")}
    end
  end

  defp trusted_endpoint?(endpoint) when is_binary(endpoint) do
    case URI.new(endpoint) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil, fragment: nil}}
      when scheme in ["http", "https"] and is_binary(host) ->
        true

      _invalid ->
        false
    end
  end

  defp trusted_endpoint?(_endpoint), do: false

  defp encode_request(request, operation_id) do
    case ResponsesCodec.encode(request) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _reason} -> {:error, protocol_error(operation_id, "Invalid Provider request")}
    end
  end

  defp encode_body(encoded, operation_id) do
    try do
      {:ok, Elixir.JSON.encode!(encoded)}
    rescue
      _exception ->
        {:error, protocol_error(operation_id, "Provider request could not be encoded")}
    end
  end

  defp enforce_request_size(body, operation_id) do
    actual = byte_size(body)

    if actual <= @max_request_bytes do
      :ok
    else
      {:error,
       protocol_error(operation_id, "Encoded Provider request exceeds the size limit", %{
         "actual_bytes" => actual,
         "max_bytes" => @max_request_bytes
       })}
    end
  end

  defp enforce_deadline(%StreamContext{deadline: :infinity}), do: :ok

  defp enforce_deadline(%StreamContext{} = context) do
    if now_ms() < context.deadline,
      do: :ok,
      else: {:error, timeout_error(context, "Provider deadline elapsed", false)}
  end

  defp run_owned_request(request, body, event_sink, context, transport) do
    coordinator = self()
    operation_ref = make_ref()

    {worker, monitor} =
      spawn_monitor(fn ->
        worker = self()
        watchdog = spawn_link(fn -> watch_coordinator(coordinator, worker) end)

        result =
          execute_request(
            request,
            body,
            event_sink,
            context,
            transport,
            coordinator,
            operation_ref
          )

        send(watchdog, {:request_finished, worker})
        send(coordinator, {operation_ref, :result, result})
      end)

    await_request(worker, monitor, operation_ref, context, false, now_ms())
  end

  defp watch_coordinator(coordinator, worker) do
    monitor = Process.monitor(coordinator)

    receive do
      {:request_finished, ^worker} ->
        Process.demonitor(monitor, [:flush])

      {:DOWN, ^monitor, :process, ^coordinator, _reason} ->
        Process.exit(worker, :kill)
    end
  end

  defp await_request(worker, monitor, operation_ref, context, output_started, last_activity) do
    timeout = next_timeout(context, last_activity)

    receive do
      {^operation_ref, :progress, started?} ->
        await_request(
          worker,
          monitor,
          operation_ref,
          context,
          output_started or started?,
          now_ms()
        )

      {^operation_ref, :result, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:cancel, cancel_ref}
      when is_reference(cancel_ref) and cancel_ref == context.cancel_ref ->
        output_started = terminate_worker(worker, monitor, operation_ref, output_started)
        {:error, interrupted_error(context, "Provider request cancelled", output_started)}

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        receive do
          {^operation_ref, :result, result} -> result
        after
          0 ->
            {:error, transport_error(context, "Provider request worker stopped", output_started)}
        end
    after
      timeout ->
        output_started = terminate_worker(worker, monitor, operation_ref, output_started)

        if deadline_elapsed?(context) do
          {:error, timeout_error(context, "Provider deadline elapsed", output_started)}
        else
          {:error, timeout_error(context, "Provider stream became inactive", output_started)}
        end
    end
  end

  defp next_timeout(context, last_activity) do
    inactivity = max(context.inactivity_ms - (now_ms() - last_activity), 0)

    case context.deadline do
      :infinity -> inactivity
      deadline -> min(inactivity, max(deadline - now_ms(), 0))
    end
  end

  defp deadline_elapsed?(%StreamContext{deadline: :infinity}), do: false
  defp deadline_elapsed?(%StreamContext{deadline: deadline}), do: now_ms() >= deadline

  defp terminate_worker(worker, monitor, operation_ref, output_started) do
    Process.exit(worker, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    after
      1_000 -> Process.demonitor(monitor, [:flush])
    end

    drain_progress(operation_ref, output_started)
  end

  defp drain_progress(operation_ref, output_started) do
    receive do
      {^operation_ref, :progress, started?} ->
        drain_progress(operation_ref, output_started or started?)
    after
      0 -> output_started
    end
  end

  defp execute_request(request, body, event_sink, context, transport, coordinator, operation_ref) do
    state_key = {@state_key_prefix, operation_ref}
    state = new_transport_state(context)
    Process.put(state_key, state)

    try do
      with {:ok, secret} <- Credentials.resolve(context.operation_id, transport.credential_source) do
        Credentials.with_value(secret, fn key ->
          req =
            build_req(
              request,
              body,
              key,
              context,
              transport,
              state_key,
              event_sink,
              coordinator,
              operation_ref
            )

          result = Req.request(req)
          finish_request(result, Process.get(state_key), context, key)
        end)
      end
    rescue
      exception ->
        {:error,
         %Error{
           kind: :transport,
           message: "Provider request worker raised an exception",
           retryable: false,
           output_started: Process.get(state_key).responses.output_started,
           operation_id: context.operation_id,
           details: %{"exception" => exception.__struct__ |> Module.split() |> Enum.join(".")}
         }}
    catch
      _kind, _reason ->
        {:error,
         %Error{
           kind: :transport,
           message: "Provider request worker terminated unexpectedly",
           retryable: false,
           output_started: Process.get(state_key).responses.output_started,
           operation_id: context.operation_id
         }}
    after
      Process.delete(state_key)
    end
  end

  defp new_transport_state(context) do
    %{
      sse: SSEDecoder.new(),
      responses: ResponsesStream.new(context.operation_id),
      terminal_error: nil,
      error_body: "",
      error_body_bytes: 0,
      error_body_truncated: false
    }
  end

  defp build_req(
         _request,
         body,
         key,
         context,
         transport,
         state_key,
         event_sink,
         coordinator,
         operation_ref
       ) do
    options = [
      method: :post,
      url: transport.endpoint,
      auth: {:bearer, key},
      headers: %{
        "accept" => "text/event-stream",
        "content-type" => "application/json",
        "user-agent" => user_agent()
      },
      body: body,
      raw: true,
      decode_body: false,
      compressed: false,
      retry: false,
      redirect: false,
      redirect_trusted: false,
      http_errors: :return,
      connect_options: [timeout: connect_timeout(context)],
      receive_timeout: context.inactivity_ms,
      into: into_callback(state_key, event_sink, context, coordinator, operation_ref)
    ]

    if transport.adapter do
      options
      |> Keyword.put(:adapter, Synapse.Provider.Tokamak.InjectedAdapter)
      |> Req.new()
      |> Req.Request.put_private(:synapse_tokamak_adapter, transport.adapter)
    else
      Req.new(options)
    end
  end

  defp into_callback(state_key, event_sink, context, coordinator, operation_ref) do
    fn {:data, chunk}, {req, response} ->
      state = Process.get(state_key)

      result =
        if response.status in 200..299 do
          consume_success_chunk(state, chunk, event_sink, context, coordinator, operation_ref)
        else
          {:cont, collect_error_body(state, chunk)}
        end

      case result do
        {:cont, state} ->
          Process.put(state_key, state)
          {:cont, {req, response}}

        {:halt, state} ->
          Process.put(state_key, state)
          {:halt, {req, response}}
      end
    end
  end

  defp consume_success_chunk(state, chunk, event_sink, context, coordinator, operation_ref) do
    case SSEDecoder.feed(state.sse, chunk) do
      {:ok, sse, frames} ->
        consume_frames(
          %{state | sse: sse},
          frames,
          event_sink,
          context,
          coordinator,
          operation_ref
        )

      {:error, %SSEDecoder.Error{}} ->
        {:halt,
         %{
           state
           | terminal_error:
               protocol_error(
                 context.operation_id,
                 "Malformed SSE stream",
                 %{},
                 state.responses.output_started
               )
         }}
    end
  end

  defp consume_frames(state, [], _event_sink, _context, _coordinator, _operation_ref),
    do: {:cont, state}

  defp consume_frames(state, [frame | remaining], event_sink, context, coordinator, operation_ref) do
    case ResponsesStream.push(state.responses, frame) do
      {:ok, responses, events} ->
        state = %{state | responses: responses}

        case emit_events(events, event_sink, context, coordinator, operation_ref, responses) do
          :ok when responses.terminal_seen ->
            {:halt, state}

          :ok ->
            consume_frames(
              state,
              remaining,
              event_sink,
              context,
              coordinator,
              operation_ref
            )

          {:sink_error, message} ->
            {:halt,
             %{
               state
               | terminal_error:
                   protocol_error(
                     context.operation_id,
                     message,
                     %{},
                     responses.output_started
                   )
             }}
        end

      {:error, error} ->
        {:halt, %{state | terminal_error: error}}
    end
  end

  defp emit_events([], _event_sink, _context, _coordinator, _operation_ref, _responses), do: :ok

  defp emit_events(events, event_sink, context, coordinator, operation_ref, responses) do
    send(coordinator, {operation_ref, :progress, responses.output_started})

    if Enum.all?(events, &callback_ok?(event_sink, &1)) do
      notify_activity(context)
    else
      {:sink_error, "Provider event sink rejected an event"}
    end
  end

  defp notify_activity(%StreamContext{activity_sink: nil}), do: :ok

  defp notify_activity(%StreamContext{} = context) do
    if callback_ok?(context.activity_sink, context),
      do: :ok,
      else: {:sink_error, "Provider activity sink rejected progress"}
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

  defp collect_error_body(state, chunk) do
    remaining = max(@max_error_body_bytes - byte_size(state.error_body), 0)

    retained =
      if remaining == 0, do: "", else: binary_part(chunk, 0, min(byte_size(chunk), remaining))

    %{
      state
      | error_body: state.error_body <> retained,
        error_body_bytes: state.error_body_bytes + byte_size(chunk),
        error_body_truncated: state.error_body_truncated or byte_size(chunk) > remaining
    }
  end

  defp finish_request({:ok, %Req.Response{} = response}, state, context, credential) do
    cond do
      state.terminal_error ->
        {:error, state.terminal_error}

      response.status in 200..299 ->
        finish_success(response, state, context, credential)

      true ->
        {:error, classify_status(response, state, context, credential)}
    end
  end

  defp finish_request({:error, exception}, state, context, _credential) do
    {:error, classify_transport_exception(exception, state, context)}
  end

  defp finish_success(response, state, context, credential) do
    if event_stream_content_type?(response) do
      finish_success_stream(response, state, context, credential)
    else
      {:error,
       protocol_error(
         context.operation_id,
         "Successful response was not an SSE stream",
         request_details(response, credential),
         state.responses.output_started
       )}
    end
  end

  defp finish_success_stream(
         _response,
         %{responses: %{terminal_seen: true}} = state,
         _context,
         _credential
       ),
       do: ResponsesStream.finish(state.responses)

  defp finish_success_stream(response, state, context, credential) do
    with {:ok, _sse, []} <- SSEDecoder.finish(state.sse),
         {:ok, completed_response} <- ResponsesStream.finish(state.responses) do
      {:ok, completed_response}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, %SSEDecoder.Error{}} ->
        {:error,
         protocol_error(
           context.operation_id,
           "SSE stream ended with incomplete framing",
           request_details(response, credential),
           state.responses.output_started
         )}
    end
  end

  defp event_stream_content_type?(response) do
    response
    |> Req.Response.get_header("content-type")
    |> Enum.any?(fn value ->
      value = String.downcase(value)
      String.starts_with?(value, "text/event-stream") or String.starts_with?(value, "text/plain")
    end)
  end

  defp classify_status(response, state, context, credential) do
    {kind, message, retryable} =
      case response.status do
        401 -> {:authentication, "Tokamak authentication failed", false}
        403 -> {:authorization, "Tokamak authorization failed", false}
        408 -> {:timeout, "Tokamak request timed out", true}
        429 -> {:rate_limited, "Tokamak rate limit exceeded", true}
        status when status in 300..399 -> {:protocol, "Tokamak redirect was rejected", false}
        status when status in 500..599 -> {:unavailable, "Tokamak service is unavailable", true}
        _status -> {:upstream, "Tokamak rejected the request", false}
      end

    details =
      request_details(response, credential)
      |> Map.merge(%{
        "error_body_bytes" => state.error_body_bytes,
        "error_body_truncated" => state.error_body_truncated
      })

    %Error{
      kind: kind,
      message: message,
      status: response.status,
      retryable: retryable,
      output_started: state.responses.output_started,
      operation_id: context.operation_id,
      details: details
    }
  end

  defp classify_transport_exception(%Req.TransportError{reason: :timeout}, state, context),
    do: timeout_error(context, "Provider transport timed out", state.responses.output_started)

  defp classify_transport_exception(exception, state, context) do
    details =
      case exception do
        %Req.TransportError{reason: reason} when is_atom(reason) ->
          %{"reason" => Atom.to_string(reason)}

        %Req.HTTPError{reason: reason} when is_atom(reason) ->
          %{"reason" => Atom.to_string(reason)}

        _exception ->
          %{}
      end

    if state.responses.output_started do
      %Error{
        kind: :interrupted,
        message: "Provider stream was interrupted after output",
        retryable: false,
        output_started: true,
        operation_id: context.operation_id,
        details: details
      }
    else
      %Error{
        kind: :transport,
        message: "Provider transport failed",
        retryable: true,
        output_started: false,
        operation_id: context.operation_id,
        details: details
      }
    end
  end

  defp request_details(response, credential) do
    ["x-request-id", "request-id", "cf-ray"]
    |> Enum.find_value(%{}, fn header ->
      case Req.Response.get_header(response, header) do
        [value | _values] ->
          case safe_request_id(value, credential) do
            nil -> nil
            request_id -> %{"request_id" => request_id}
          end

        [] ->
          nil
      end
    end)
  end

  defp safe_request_id(value, credential) do
    bearer = "Bearer " <> credential

    if is_binary(value) and value != credential and value != bearer and String.valid?(value) and
         value != "" and safe_request_id_bytes?(value) do
      bounded(value, @request_id_bytes)
    end
  end

  defp safe_request_id_bytes?(value) do
    Enum.all?(:binary.bin_to_list(value), fn byte ->
      byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or byte in ~c"-_.:"
    end)
  end

  defp connect_timeout(%StreamContext{deadline: :infinity}), do: @connect_timeout_ms

  defp connect_timeout(%StreamContext{deadline: deadline}) do
    min(@connect_timeout_ms, max(deadline - now_ms(), 1))
  end

  defp user_agent do
    version = Application.spec(:synapse, :vsn) || ~c"unknown"
    "synapse/" <> to_string(version)
  end

  defp local_error(operation_id, message, reason \\ nil) do
    details = if reason, do: %{"reason" => "invalid_configuration"}, else: %{}

    %Error{
      kind: :configuration,
      message: message,
      retryable: false,
      output_started: false,
      operation_id: valid_operation_id(operation_id),
      details: details
    }
  end

  defp protocol_error(operation_id, message, details \\ %{}, output_started \\ false) do
    %Error{
      kind: :protocol,
      message: message,
      retryable: false,
      output_started: output_started,
      operation_id: valid_operation_id(operation_id),
      details: details
    }
  end

  defp timeout_error(context, message, output_started) do
    %Error{
      kind: :timeout,
      message: message,
      retryable: true,
      output_started: output_started,
      operation_id: context.operation_id
    }
  end

  defp interrupted_error(context, message, output_started) do
    %Error{
      kind: :interrupted,
      message: message,
      retryable: false,
      output_started: output_started,
      operation_id: context.operation_id
    }
  end

  defp transport_error(context, message, output_started) do
    %Error{
      kind: if(output_started, do: :interrupted, else: :transport),
      message: message,
      retryable: not output_started,
      output_started: output_started,
      operation_id: context.operation_id
    }
  end

  defp valid_operation_id(value) when is_binary(value) do
    if String.valid?(value) and String.trim(value) != "", do: value, else: "invalid-operation"
  end

  defp valid_operation_id(_value), do: "invalid-operation"

  defp bounded(value, limit) when is_binary(value) do
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

  defp now_ms, do: System.monotonic_time(:millisecond)
end

defmodule Synapse.Provider.Tokamak.InjectedAdapter do
  # Private Req adapter shim used only to invoke trusted deterministic test callbacks.
  @moduledoc false

  @spec run(Req.Request.t()) :: {Req.Request.t(), Req.Response.t() | Exception.t()}
  def run(request) do
    request
    |> Req.Request.get_private(:synapse_tokamak_adapter)
    |> then(& &1.(request))
  end
end
