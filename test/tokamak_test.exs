defmodule Synapse.Provider.TokamakTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Synapse.Provider.{Error, Request, StreamContext, Tokamak}
  alias Synapse.Provider.Event.{MessageCompleted, MessageStarted, TextDelta}
  alias Synapse.Provider.OutputItem.{FunctionCall, Message}

  @test_key "tokamak-transport-test-key"
  @event_stream_headers [{"content-type", "text/event-stream"}]

  test "streams a successful text response through an injected Req adapter" do
    test_pid = self()
    body = fixture_sse("text_stream")

    adapter =
      stream_adapter(200, chunks(body, 17), @event_stream_headers, fn request ->
        send(test_pid, {:request, request})
      end)

    context =
      context!(
        activity_sink: fn context ->
          send(test_pid, {:activity, context.operation_id})
          :ok
        end
      )

    sink = fn event ->
      send(test_pid, {:event, event})
      :ok
    end

    assert {:ok, response} = Tokamak.stream(request!(), sink, context, transport(adapter))
    assert [%Message{content: "Hello from Synapse"}] = response.output_items

    assert_receive {:request, request}
    assert request.method == :post

    assert URI.to_string(request.url) ==
             "https://api.tokamak.sh/v1/agent-pool/codex-proxy/responses"

    assert_receive {:event, %MessageStarted{}}
    assert_receive {:event, %TextDelta{}}
    assert_receive {:event, %MessageCompleted{}}
    assert_receive {:activity, "operation-test"}
  end

  test "streams a completed function call" do
    adapter = stream_adapter(200, chunks(fixture_sse("tool_stream"), 11), @event_stream_headers)

    assert {:ok, response} =
             Tokamak.stream(request!(), fn _event -> :ok end, context!(), transport(adapter))

    assert [
             %FunctionCall{
               call_id: "call-read",
               name: "read",
               arguments: %{"path" => "mix.exs", "offset" => nil, "limit" => nil}
             }
           ] = response.output_items
  end

  test "accepts Tokamak's text/plain label only when the body is valid Responses SSE" do
    adapter =
      stream_adapter(200, [fixture_sse("text_stream")], [
        {"content-type", "text/plain; charset=utf-8"}
      ])

    assert {:ok, response} =
             Tokamak.stream(request!(), fn _event -> :ok end, context!(), transport(adapter))

    assert [%Message{}] = response.output_items
  end

  test "accepts a compatibility content type only after complete terminal SSE" do
    adapter =
      stream_adapter(200, [fixture_sse("text_stream")], [
        {"content-type", "application/json"}
      ])

    assert {:ok, response} =
             Tokamak.stream(request!(), fn _event -> :ok end, context!(), transport(adapter))

    assert [%Message{}] = response.output_items
  end

  test "builds the fixed POST request with canonical headers, body, and one-attempt policy" do
    test_pid = self()

    adapter =
      stream_adapter(200, [fixture_sse("text_stream")], @event_stream_headers, fn request ->
        send(test_pid, {:captured_request, request})
      end)

    assert {:ok, _response} =
             Tokamak.stream(request!(), fn _event -> :ok end, context!(), transport(adapter))

    assert_receive {:captured_request, request}
    assert request.method == :post
    assert request.headers["authorization"] == ["Bearer " <> @test_key]
    assert request.headers["accept"] == ["text/event-stream"]
    assert request.headers["content-type"] == ["application/json"]
    assert [user_agent] = request.headers["user-agent"]
    assert String.starts_with?(user_agent, "synapse/")
    refute user_agent =~ System.get_env("HOSTNAME", "host-not-present")
    assert request.options[:retry] == false
    assert request.options[:redirect] == false
    assert request.options[:redirect_trusted] == false

    decoded = Elixir.JSON.decode!(request.body)
    assert decoded["model"] == "configured-model"
    assert decoded["stream"]
    refute decoded["store"]
    refute Map.has_key?(decoded, "max_output_tokens")
  end

  test "rejects an oversized encoded request before credential lookup or HTTP" do
    test_pid = self()
    oversized = String.duplicate("x", 8 * 1024 * 1024)

    request =
      request!(
        input_items: [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => oversized}]
          }
        ]
      )

    source = fn _name ->
      send(test_pid, :credential_lookup)
      @test_key
    end

    adapter = fn _request ->
      send(test_pid, :adapter_called)
      flunk("adapter must not run")
    end

    assert {:error, error} =
             Tokamak.stream(request, fn _event -> :ok end, context!(),
               adapter: adapter,
               credential_source: source
             )

    assert %Error{kind: :protocol, output_started: false} = error
    assert error.details["actual_bytes"] > error.details["max_bytes"]
    refute_received :credential_lookup
    refute_received :adapter_called
  end

  test "rejects redirects instead of forwarding authorization" do
    test_pid = self()

    adapter =
      stream_adapter(
        302,
        ["redirect body"],
        [{"location", "https://evil.invalid/steal"}],
        fn request ->
          send(test_pid, {:redirect_request, request})
        end
      )

    assert {:error, error} =
             Tokamak.stream(request!(), fn _event -> :ok end, context!(), transport(adapter))

    assert %Error{kind: :protocol, status: 302, retryable: false} = error
    assert error.message == "Tokamak redirect was rejected"
    assert_receive {:redirect_request, request}
    assert request.options[:redirect] == false
    refute error.details |> inspect() =~ "evil.invalid"
  end

  test "classifies HTTP failures and preserves only a bounded request identifier" do
    mappings = [
      {401, :authentication, false},
      {403, :authorization, false},
      {408, :timeout, true},
      {429, :rate_limited, true},
      {500, :unavailable, true},
      {503, :unavailable, true}
    ]

    for {status, kind, retryable} <- mappings do
      adapter =
        stream_adapter(
          status,
          [String.duplicate("upstream failure ", 500)],
          [{"x-request-id", "request-#{status}"}]
        )

      assert {:error, error} =
               Tokamak.stream(request!(), fn _event -> :ok end, context!(), transport(adapter))

      assert %Error{kind: ^kind, status: ^status, retryable: ^retryable} = error
      assert error.details["request_id"] == "request-#{status}"
      assert error.details["error_body_bytes"] > 4_096
      assert error.details["error_body_truncated"]
      refute inspect(error) =~ "upstream failure"
    end
  end

  test "classifies a transport disconnect before output" do
    adapter = fn request -> {request, %Req.TransportError{reason: :closed}} end

    assert {:error, error} =
             Tokamak.stream(request!(), fn _event -> :ok end, context!(), transport(adapter))

    assert %Error{kind: :transport, retryable: true, output_started: false} = error
    assert error.details == %{"reason" => "closed"}
  end

  test "classifies a transport disconnect after partial output" do
    test_pid = self()
    partial = partial_text_sse()

    adapter = fn request ->
      response = Req.Response.new(status: 200, headers: @event_stream_headers)
      {:cont, {request, _response}} = request.into.({:data, partial}, {request, response})
      send(test_pid, :partial_chunk_processed)
      {request, %Req.TransportError{reason: :closed}}
    end

    sink = fn event ->
      send(test_pid, {:partial_event, event})
      :ok
    end

    assert {:error, error} = Tokamak.stream(request!(), sink, context!(), transport(adapter))
    assert %Error{kind: :interrupted, retryable: false, output_started: true} = error
    assert_receive :partial_chunk_processed
    assert_receive {:partial_event, %TextDelta{delta: "partial"}}
  end

  test "enforces inactivity while the adapter waits without producing bytes" do
    test_pid = self()

    adapter = fn request ->
      send(test_pid, {:sleeping_worker, self()})
      Process.sleep(:infinity)
      {request, Req.Response.new(status: 200)}
    end

    context = context!(inactivity_ms: 500)

    task =
      Task.async(fn ->
        Tokamak.stream(request!(), fn _event -> :ok end, context, transport(adapter))
      end)

    assert_receive {:sleeping_worker, worker}, 1_000

    assert {:error, error} = Task.await(task, 2_000)

    assert %Error{kind: :timeout, output_started: false} = error
    assert error.message == "Provider stream became inactive"
    refute Process.alive?(worker)
  end

  test "enforces an absolute monotonic deadline" do
    adapter = fn request ->
      Process.sleep(:infinity)
      {request, Req.Response.new(status: 200)}
    end

    context = context!(inactivity_ms: 1_000, deadline: now_ms() + 20)

    assert {:error, error} =
             Tokamak.stream(request!(), fn _event -> :ok end, context, transport(adapter))

    assert %Error{kind: :timeout} = error
    assert error.message == "Provider deadline elapsed"
  end

  test "explicit cancellation kills the owned request worker" do
    test_pid = self()
    cancel_ref = make_ref()

    adapter = fn request ->
      send(test_pid, {:cancellable_worker, self()})
      Process.sleep(:infinity)
      {request, Req.Response.new(status: 200)}
    end

    task =
      Task.async(fn ->
        context = context!(cancel_ref: cancel_ref, inactivity_ms: 5_000)
        Tokamak.stream(request!(), fn _event -> :ok end, context, transport(adapter))
      end)

    assert_receive {:cancellable_worker, worker}, 1_000
    monitor = Process.monitor(worker)
    assert :ok = Tokamak.cancel(task.pid, cancel_ref)

    assert {:error, %Error{kind: :interrupted, retryable: false}} = Task.await(task)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}
  end

  test "a slow synchronous event sink applies backpressure" do
    body = fixture_sse("text_stream")
    adapter = stream_adapter(200, [body], @event_stream_headers)

    sink = fn _event ->
      Process.sleep(15)
      :ok
    end

    started_at = now_ms()

    assert {:ok, _response} =
             Tokamak.stream(request!(), sink, context!(inactivity_ms: 1_000), transport(adapter))

    assert now_ms() - started_at >= 75
  end

  test "halts after exactly one terminal response" do
    test_pid = self()
    completed = fixture_sse("text_stream")
    invalid_after_terminal = "data: {not-json}\n\n"

    adapter =
      stream_adapter(
        200,
        [completed, invalid_after_terminal],
        @event_stream_headers,
        fn _request ->
          send(test_pid, :adapter_started)
        end
      )

    sink = fn event ->
      if is_struct(event, MessageCompleted), do: send(test_pid, :terminal_event)
      :ok
    end

    assert {:ok, _response} =
             Tokamak.stream(request!(), sink, context!(), transport(adapter))

    assert_receive :adapter_started
    assert_receive :terminal_event
    refute_received :terminal_event
  end

  test "maps a malformed successful body to protocol failure" do
    adapter = stream_adapter(200, ["data: {not-json}\n\n"], @event_stream_headers)

    assert {:error, error} =
             Tokamak.stream(request!(), fn _event -> :ok end, context!(), transport(adapter))

    assert %Error{kind: :protocol, output_started: false} = error
  end

  test "event sink failure stops interpretation within the current HTTP chunk" do
    test_pid = self()
    body = fixture_sse("text_stream")

    adapter = fn request ->
      response = Req.Response.new(status: 200, headers: @event_stream_headers)
      {tag, request_response} = request.into.({:data, body}, {request, response})
      send(test_pid, {:into_result, tag})
      request_response
    end

    sink = fn
      %MessageStarted{} -> raise "synthetic sink failure"
      event -> send(test_pid, {:unexpected_event, event})
    end

    assert {:error, error} =
             Tokamak.stream(request!(), sink, context!(), transport(adapter))

    assert %Error{kind: :protocol, output_started: false} = error
    assert error.message == "Provider event sink rejected an event"
    assert_receive {:into_result, :halt}
    refute_received {:unexpected_event, _event}
  end

  test "decoder failure halts the owned HTTP operation" do
    test_pid = self()

    adapter = fn request ->
      response = Req.Response.new(status: 200, headers: @event_stream_headers)

      {tag, request_response} =
        request.into.({:data, String.duplicate("x", 65_537)}, {request, response})

      send(test_pid, {:decoder_into_result, tag})
      request_response
    end

    assert {:error, %Error{kind: :protocol, output_started: false}} =
             Tokamak.stream(request!(), fn _event -> :ok end, context!(), transport(adapter))

    assert_receive {:decoder_into_result, :halt}
  end

  test "caller termination kills its owned request worker" do
    test_pid = self()

    adapter = fn request ->
      send(test_pid, {:orphan_test_worker, self()})

      receive do
        :adapter_release ->
          {request, Req.Response.new(status: 500, headers: [])}
      end
    end

    {coordinator, coordinator_monitor} =
      spawn_monitor(fn ->
        Tokamak.stream(request!(), fn _event -> :ok end, context!(), transport(adapter))
      end)

    assert_receive {:orphan_test_worker, worker}, 1_000
    worker_monitor = Process.monitor(worker)
    Process.exit(coordinator, :kill)

    assert_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, :killed}
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}
  end

  test "adapter exceptions expose only their class, not a synthetic secret" do
    adapter = fn _request -> raise "upstream reflected #{@test_key}" end

    log =
      capture_log(fn ->
        assert {:error, error} =
                 Tokamak.stream(request!(), fn _event -> :ok end, context!(), transport(adapter))

        assert %Error{kind: :transport, details: %{"exception" => "RuntimeError"}} = error
        refute inspect(error) =~ @test_key
      end)

    refute log =~ @test_key
  end

  test "does not expose credentials or reflected error bodies in errors or logs" do
    adapter =
      stream_adapter(500, ["reflected #{@test_key}"], [
        {"content-type", "text/plain"},
        {"x-request-id", @test_key}
      ])

    log =
      capture_log(fn ->
        assert {:error, error} =
                 Tokamak.stream(request!(), fn _event -> :ok end, context!(), transport(adapter))

        refute inspect(error) =~ @test_key
        refute Map.has_key?(error.details, "request_id")
      end)

    refute log =~ @test_key
  end

  test "controlled invalid-key fixture returns sanitized authentication failure" do
    adapter =
      stream_adapter(401, ["invalid credential #{@test_key}"], [
        {"content-type", "text/plain"},
        {"x-request-id", @test_key}
      ])

    log =
      capture_log(fn ->
        assert {:error, error} =
                 Tokamak.stream(request!(), fn _event -> :ok end, context!(), transport(adapter))

        assert %Error{kind: :authentication, status: 401, output_started: false} = error
        refute inspect(error) =~ @test_key
      end)

    refute log =~ @test_key
  end

  defp stream_adapter(status, chunks, headers, on_request \\ fn _request -> :ok end) do
    fn request ->
      on_request.(request)
      response = Req.Response.new(status: status, headers: headers)

      {request, response} =
        Enum.reduce_while(chunks, {request, response}, fn chunk, acc ->
          case request.into.({:data, chunk}, acc) do
            {:cont, acc} -> {:cont, acc}
            {:halt, acc} -> {:halt, acc}
          end
        end)

      {request, response}
    end
  end

  defp request!(attributes \\ []) do
    attributes = Keyword.put_new(attributes, :model, "configured-model")
    {:ok, request} = Request.new(attributes)
    request
  end

  defp context!(attributes \\ []) do
    attributes =
      attributes
      |> Keyword.put_new(:operation_id, "operation-test")
      |> Keyword.put_new(:inactivity_ms, 2_000)

    {:ok, context} = StreamContext.new(attributes)
    context
  end

  defp transport(adapter) do
    [adapter: adapter, credential_source: fn "TOKAMAK_API_KEY" -> @test_key end]
  end

  defp fixture_sse(name) do
    name
    |> fixture()
    |> Enum.map_join(fn
      "[DONE]" -> "data: [DONE]\n\n"
      payload -> "data: " <> Elixir.JSON.encode!(payload) <> "\n\n"
    end)
  end

  defp partial_text_sse do
    [created, item_added, delta | _events] = fixture("text_stream")

    Enum.map_join([created, item_added, %{delta | "delta" => "partial"}], fn payload ->
      "data: " <> Elixir.JSON.encode!(payload) <> "\n\n"
    end)
  end

  defp fixture(name) do
    path = Path.join([__DIR__, "fixtures", "responses", name <> ".fixture"])
    {fixture, _bindings} = Code.eval_file(path)
    fixture
  end

  defp chunks(binary, size) do
    binary
    |> :binary.bin_to_list()
    |> Enum.chunk_every(size)
    |> Enum.map(&:erlang.list_to_binary/1)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
