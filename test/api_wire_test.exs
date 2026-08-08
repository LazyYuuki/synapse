defmodule Synapse.API.WireTest do
  use ExUnit.Case, async: true

  alias Synapse.Agent.{Error, Result}
  alias Synapse.API
  alias Synapse.API.{Config, ConfirmedTerminal, PendingTerminal, Policy, Wire}
  alias Synapse.Budget
  alias Synapse.Provider
  alias Synapse.Run.Event
  alias Synapse.Runtime.Error, as: RuntimeError

  doctest ConfirmedTerminal
  doctest Wire

  test "encodes exact fixtures for fixed server messages" do
    config = config()
    run_id = run_id()

    assert_frame(
      Wire.hello(config),
      ~S({"version":1,"type":"server.hello","request_id":null,"payload":{"protocol":1,"replay":"memory","max_active_runs":1,"cwd":"/synthetic/api-wire-launch","max_output_bytes":524288}}),
      config
    )

    assert_frame(
      Wire.error(:invalid_payload, "request-1", config),
      ~S({"version":1,"type":"server.error","request_id":"request-1","payload":{"code":"invalid_payload","message":"Command payload is invalid","retryable":false}}),
      config
    )

    assert_frame(
      Wire.run_accepted("request-1", run_id, config),
      ~s({"version":1,"type":"run.accepted","request_id":"request-1","payload":{"run_id":"#{run_id}","status":"starting"}}),
      config
    )

    assert_frame(
      Wire.cancel_requested("request-2", run_id, :cancel_requested, config),
      ~s({"version":1,"type":"run.cancel_requested","request_id":"request-2","payload":{"run_id":"#{run_id}","status":"cancel_requested"}}),
      config
    )

    assert_frame(
      Wire.cancel_requested("request-2", run_id, :already_terminal, config),
      ~s({"version":1,"type":"run.cancel_requested","request_id":"request-2","payload":{"run_id":"#{run_id}","status":"already_terminal"}}),
      config
    )

    assert_frame(
      Wire.snapshot(
        "request-3",
        %{
          mode: :replay,
          reset: false,
          run_id: run_id,
          first_available_seq: 1,
          last_seq: 0,
          projection: nil,
          terminal: nil
        },
        config
      ),
      ~s({"version":1,"type":"run.snapshot","request_id":"request-3","payload":{"mode":"replay","reset":false,"run_id":"#{run_id}","first_available_seq":1,"last_seq":0,"projection":null,"terminal":null}}),
      config
    )

    async_attrs = %{
      mode: :snapshot,
      reset: true,
      run_id: run_id,
      first_available_seq: 1,
      last_seq: 0,
      projection: API.Projection.new(),
      terminal: nil
    }

    async = Wire.async_snapshot(async_attrs, config) |> decode_frame!()
    assert async["type"] == "run.snapshot"
    assert async["request_id"] == nil
    assert async["payload"]["reset"] == true

    assert_frame(
      Wire.pong("request-4", config),
      ~S({"version":1,"type":"pong","request_id":"request-4","payload":{}}),
      config
    )
  end

  test "hello rejects Config and Policy values without a bounded launch directory" do
    assert {:error, :invalid_api_policy} = Policy.from_config(Config.default())
    assert {:error, :invalid_message} = Wire.hello(Config.default())

    config = config()
    assert {:ok, policy} = Policy.from_config(config)
    assert {:error, :invalid_message} = Wire.hello(%{policy | launch_cwd: nil})
  end

  test "every server error code has fixed prose and retry policy" do
    config = config()

    expected = %{
      invalid_json: {"Message is not valid JSON", false},
      invalid_envelope: {"Command envelope is invalid", false},
      unsupported_version: {"Protocol version is not supported", false},
      unknown_type: {"Command type is not supported", false},
      invalid_request_id: {"Request ID is invalid", false},
      invalid_payload: {"Command payload is invalid", false},
      run_busy: {"A run is already active", true},
      run_not_found: {"Run was not found", false},
      invalid_cursor: {"Run cursor is invalid", false},
      subscription_limit: {"Connection subscription limit reached", false},
      runtime_unavailable: {"Runtime is unavailable", true},
      internal_error: {"Internal API failure", false}
    }

    Enum.each(expected, fn {code, {message, retryable}} ->
      request_id = if code in [:invalid_json, :invalid_request_id], do: nil, else: "request-1"
      decoded = Wire.error(code, request_id, config) |> decode_frame!()

      assert decoded["payload"] == %{
               "code" => Atom.to_string(code),
               "message" => message,
               "retryable" => retryable
             }
    end)

    assert {:error, :invalid_message} = Wire.error(:unknown, nil, config)
    assert {:error, :invalid_message} = Wire.error(:invalid_json, "bad\nrequest", config)
    assert {:error, :invalid_message} = Wire.error(:invalid_json, "request-1", config)
    assert {:error, :invalid_message} = Wire.error(:invalid_request_id, "request-1", config)
    assert {:error, :invalid_message} = Wire.error(:run_busy, nil, config)
    assert {:error, :invalid_message} = Wire.error(:invalid_payload, nil, config)
  end

  test "encodes authoritative active and completed snapshots exactly" do
    config = config()
    run_id = run_id()

    {:ok, active_tool} =
      API.ActiveTool.new(
        [turn: 2, operation_id: "tool-op", call_id: "call-1", name: "read", ordinal: 1],
        config
      )

    projection = %{
      API.Projection.new()
      | status: :running,
        model: "model-a",
        turn: 2,
        text: "working",
        active_tool: active_tool,
        provider_attempts: 2,
        tool_calls: 1,
        output_bytes: 7
    }

    active =
      Wire.snapshot(
        "request-1",
        %{
          mode: :snapshot,
          reset: true,
          run_id: run_id,
          first_available_seq: 2,
          last_seq: 3,
          projection: projection,
          terminal: nil
        },
        config
      )
      |> decode_frame!()

    assert active == decode_json!(~s({
      "version": 1,
      "type": "run.snapshot",
      "request_id": "request-1",
      "payload": {
        "mode": "snapshot",
        "reset": true,
        "run_id": "#{run_id}",
        "first_available_seq": 2,
        "last_seq": 3,
        "projection": {
          "status": "running",
          "model": "model-a",
          "turn": 2,
          "text": "working",
          "active_tool": {"turn":2,"operation_id":"tool-op","call_id":"call-1","name":"read","ordinal":1},
          "provider_attempts": 2,
          "tool_calls": 1,
          "output_bytes": 7
        },
        "terminal": null
      }
    }))

    terminal = completed_terminal(config, 4)

    completed_projection = %{
      projection
      | status: :completed,
        turn: 1,
        active_tool: nil,
        text: "done",
        provider_attempts: 1,
        tool_calls: 0,
        output_bytes: 4
    }

    completed =
      Wire.snapshot(
        "request-2",
        %{
          mode: :snapshot,
          reset: false,
          run_id: run_id,
          first_available_seq: 1,
          last_seq: 4,
          projection: completed_projection,
          terminal: terminal
        },
        config
      )
      |> decode_frame!()

    assert completed["payload"]["terminal"] == terminal_payload_fixture(run_id, 4)
    assert completed["payload"]["projection"]["status"] == "completed"
    assert completed["payload"]["projection"]["text"] == ""
  end

  test "encodes every concrete progress event and owner loss field by field" do
    config = config()
    run_id = run_id()

    fixtures = [
      {:run_started, %{run_id: run_id, model: "model-a"},
       %{"type" => "run.started", "model" => "model-a"}},
      {:turn_started, %{run_id: run_id, turn: 2, operation_id: "provider-op"},
       %{"type" => "turn.started", "turn" => 2, "operation_id" => "provider-op"}},
      {:text_delta,
       %{
         run_id: run_id,
         turn: 2,
         operation_id: "provider-op",
         item_id: "item-1",
         content_index: 0,
         delta: "hello"
       },
       %{
         "type" => "text.delta",
         "turn" => 2,
         "operation_id" => "provider-op",
         "item_id" => "item-1",
         "content_index" => 0,
         "delta" => "hello"
       }},
      {:tool_started, tool_attrs(run_id),
       %{
         "type" => "tool.started",
         "turn" => 2,
         "operation_id" => "tool-op",
         "call_id" => "call-1",
         "name" => "read",
         "ordinal" => 1
       }},
      {:tool_completed,
       Map.merge(tool_attrs(run_id), %{
         status: :ok,
         metadata: %{
           "tool" => "read",
           "outcome" => "completed",
           "status" => "SYNTHETIC_OMITTED_METADATA"
         }
       }),
       %{
         "type" => "tool.completed",
         "turn" => 2,
         "operation_id" => "tool-op",
         "call_id" => "call-1",
         "name" => "read",
         "ordinal" => 1,
         "status" => "ok",
         "metadata" => %{"tool" => "read", "outcome" => "completed"}
       }},
      {:turn_completed,
       %{
         run_id: run_id,
         turn: 2,
         outcome: :continued,
         provider_attempts: 2,
         tool_calls: 1,
         output_bytes: 5
       },
       %{
         "type" => "turn.completed",
         "turn" => 2,
         "outcome" => "continued",
         "provider_attempts" => 2,
         "tool_calls" => 1,
         "output_bytes" => 5
       }}
    ]

    Enum.with_index(fixtures, 1)
    |> Enum.each(fn {{kind, attrs, expected_event}, seq} ->
      {:ok, event} = Event.new(kind, attrs)
      decoded = Wire.event(run_id, seq, event, config) |> decode_frame!()

      assert decoded == %{
               "version" => 1,
               "type" => "run.event",
               "request_id" => nil,
               "payload" => %{"run_id" => run_id, "seq" => seq, "event" => expected_event}
             }
    end)

    assert Wire.owner_lost(run_id, 7, config) |> decode_frame!() == %{
             "version" => 1,
             "type" => "run.event",
             "request_id" => nil,
             "payload" => %{
               "run_id" => run_id,
               "seq" => 7,
               "event" => %{"type" => "run.owner_lost"}
             }
           }
  end

  test "terminal Run Events and malformed internal events never encode as progress" do
    config = config()
    run_id = run_id()
    result = agent_result(run_id)
    {:ok, completed_event} = Event.new(:run_completed, run_id: run_id, result: result)

    {:ok, failed_error} =
      Error.new(
        kind: :provider,
        reason: :provider_failed,
        message: "Provider failed",
        run_id: run_id,
        turn: 1,
        operation_id: nil,
        details: %{}
      )

    {:ok, failed_event} = Event.new(:run_failed, run_id: run_id, error: failed_error)

    {:ok, interrupted_error} =
      Error.new(
        kind: :cancelled,
        reason: :run_cancelled,
        message: "Run cancelled",
        run_id: run_id,
        turn: 1,
        operation_id: nil,
        details: %{}
      )

    {:ok, interrupted_event} =
      Event.new(:run_interrupted, run_id: run_id, error: interrupted_error)

    assert {:error, :invalid_message} = Wire.event(run_id, 1, completed_event, config)
    assert {:error, :invalid_message} = Wire.event(run_id, 1, failed_event, config)
    assert {:error, :invalid_message} = Wire.event(run_id, 1, interrupted_event, config)

    {:ok, started} = Event.new(:run_started, run_id: run_id, model: "model-a")

    assert {:error, :invalid_message} =
             Wire.event(run_id, 1, %{started | model: "model-b"}, config)

    assert {:error, :invalid_message} = Wire.event(other_run_id(), 1, started, config)
    assert {:error, :invalid_message} = Wire.event(run_id, 0, started, config)
    assert {:error, :invalid_message} = Wire.event(run_id, 1, %{secret: "value"}, config)
  end

  test "maps every closed Tool status and turn outcome" do
    config = config()
    run_id = run_id()

    for status <- [:ok, :error, :ambiguous] do
      {:ok, event} =
        Event.new(
          :tool_completed,
          Map.merge(tool_attrs(run_id), %{status: status, metadata: %{}})
        )

      assert Wire.event(run_id, 1, event, config)
             |> decode_frame!()
             |> get_in(["payload", "event", "status"]) == Atom.to_string(status)
    end

    for outcome <- [:continued, :completed, :failed, :interrupted] do
      {:ok, event} =
        Event.new(:turn_completed,
          run_id: run_id,
          turn: 1,
          outcome: outcome,
          provider_attempts: 1,
          tool_calls: 0,
          output_bytes: 0
        )

      assert Wire.event(run_id, 1, event, config)
             |> decode_frame!()
             |> get_in(["payload", "event", "outcome"]) == Atom.to_string(outcome)
    end
  end

  test "Tool metadata copies only matching identity and four public outcomes" do
    config = config()
    run_id = run_id()

    for outcome <- ["completed", "not_applied", "not_applicable", "unknown"] do
      {:ok, event} =
        Event.new(
          :tool_completed,
          Map.merge(tool_attrs(run_id), %{
            status: :ok,
            metadata: %{"tool" => "read", "outcome" => outcome}
          })
        )

      assert Wire.event(run_id, 1, event, config)
             |> decode_frame!()
             |> get_in(["payload", "event", "metadata"]) == %{
               "tool" => "read",
               "outcome" => outcome
             }
    end

    {:ok, omitted} =
      Event.new(
        :tool_completed,
        Map.merge(tool_attrs(run_id), %{
          status: :ok,
          metadata: %{"tool" => "write", "outcome" => "private", "status" => "secret"}
        })
      )

    assert Wire.event(run_id, 1, omitted, config)
           |> decode_frame!()
           |> get_in(["payload", "event", "metadata"]) == %{}
  end

  test "encodes successful, Agent, Runtime, and API terminals as distinct exact unions" do
    config = config()
    run_id = run_id()

    completed = completed_terminal(config, 10)
    completed_frame = Wire.terminal(completed, config) |> decode_frame!()
    assert completed_frame["payload"] == terminal_payload_fixture(run_id, 10)

    {:ok, agent_error} =
      Error.new(
        kind: :provider,
        reason: :provider_failed,
        message: "Provider request failed",
        run_id: run_id,
        turn: 2,
        operation_id: "provider-op",
        details: %{"http_status" => 503, "retryable" => true}
      )

    {:ok, failed_event} = Event.new(:run_failed, run_id: run_id, error: agent_error)
    {:ok, pending} = PendingTerminal.new(failed_event, config)
    {:ok, failed} = ConfirmedTerminal.from_pending(pending, 11, config)

    assert Wire.terminal(failed, config) |> decode_frame!() |> get_in(["payload"]) == %{
             "run_id" => run_id,
             "seq" => 11,
             "status" => "failed",
             "result" => nil,
             "error" => %{
               "source" => "agent",
               "kind" => "provider",
               "reason" => "provider_failed",
               "message" => "Provider request failed",
               "turn" => 2,
               "operation_id" => "provider-op",
               "details" => %{"http_status" => 503, "retryable" => true}
             }
           }

    {:ok, cancelled_error} =
      Error.new(
        kind: :cancelled,
        reason: :run_cancelled,
        message: "Run was cancelled",
        run_id: run_id,
        turn: 2,
        operation_id: nil,
        details: %{}
      )

    {:ok, interrupted_event} =
      Event.new(:run_interrupted, run_id: run_id, error: cancelled_error)

    {:ok, interrupted_pending} = PendingTerminal.new(interrupted_event, config)
    {:ok, interrupted} = ConfirmedTerminal.from_pending(interrupted_pending, 12, config)

    assert Wire.terminal(interrupted, config)
           |> decode_frame!()
           |> get_in(["payload", "status"]) == "interrupted"

    {:ok, runtime_error} = RuntimeError.new(reason: :runtime_lost, run_id: run_id)
    {:ok, runtime_terminal} = ConfirmedTerminal.from_runtime(run_id, 13, runtime_error, config)

    assert Wire.terminal(runtime_terminal, config) |> decode_frame!() |> get_in(["payload"]) == %{
             "run_id" => run_id,
             "seq" => 13,
             "status" => "interrupted",
             "result" => nil,
             "error" => %{
               "source" => "runtime",
               "reason" => "runtime_lost",
               "message" => "Runtime coordinator was lost"
             }
           }

    {:ok, api_terminal} = ConfirmedTerminal.internal_contract_failed(run_id, 14, config)

    assert Wire.terminal(api_terminal, config) |> decode_frame!() |> get_in(["payload"]) == %{
             "run_id" => run_id,
             "seq" => 14,
             "status" => "interrupted",
             "result" => nil,
             "error" => %{
               "source" => "api",
               "reason" => "internal_contract_failed",
               "message" => "Run settlement contract failed"
             }
           }
  end

  test "maps every Runtime reason to fixed prose and authoritative status" do
    config = config()
    run_id = run_id()

    expected = %{
      invalid_run_request: {"Run Request is invalid", "failed"},
      invalid_runtime_options: {"Runtime options are invalid", "failed"},
      runtime_unavailable: {"Runtime infrastructure is unavailable", "failed"},
      runtime_busy: {"Runtime is busy", "failed"},
      workspace_open_failed: {"Workspace could not be opened", "failed"},
      runtime_lost: {"Runtime coordinator was lost", "interrupted"}
    }

    Enum.with_index(expected, 1)
    |> Enum.each(fn {{reason, {message, status}}, seq} ->
      {:ok, error} = RuntimeError.new(reason: reason, run_id: nil)
      {:ok, terminal} = ConfirmedTerminal.from_runtime(run_id, seq, error, config)
      payload = Wire.terminal(terminal, config) |> decode_frame!() |> get_in(["payload"])

      assert payload["status"] == status

      assert payload["error"] == %{
               "source" => "runtime",
               "reason" => Atom.to_string(reason),
               "message" => message
             }
    end)
  end

  test "maps every Agent kind and reason through the fixed terminal table" do
    config = config()
    run_id = run_id()

    pairs = [
      internal: [
        :invalid_run_request,
        :invalid_agent_context,
        :event_sink_failed,
        :tool_executor_contract_failed,
        :conversation_projection_failed,
        :run_worker_crashed,
        :workspace_close_failed
      ],
      provider: [
        :provider_failed,
        :provider_interrupted_after_output,
        :provider_retry_exhausted
      ],
      protocol: [:empty_provider_response, :invalid_function_call_batch, :tool_admission_failed],
      tool: [:tool_ambiguous],
      budget: [
        :turn_budget_exhausted,
        :tool_call_budget_exhausted,
        :wall_time_budget_exhausted,
        :output_budget_exhausted
      ],
      cancelled: [:run_cancelled]
    ]

    pairs
    |> Enum.flat_map(fn {kind, reasons} -> Enum.map(reasons, &{kind, &1}) end)
    |> Enum.with_index(1)
    |> Enum.each(fn {{kind, reason}, seq} ->
      {:ok, error} =
        Error.new(
          kind: kind,
          reason: reason,
          message: "Sanitized failure",
          run_id: run_id,
          turn: 1,
          operation_id: nil,
          details: %{}
        )

      event_kind = if kind == :cancelled, do: :run_interrupted, else: :run_failed
      {:ok, event} = Event.new(event_kind, run_id: run_id, error: error)
      {:ok, pending} = PendingTerminal.new(event, config)
      {:ok, terminal} = ConfirmedTerminal.from_pending(pending, seq, config)

      wire_error =
        Wire.terminal(terminal, config) |> decode_frame!() |> get_in(["payload", "error"])

      assert wire_error["kind"] == Atom.to_string(kind)
      assert wire_error["reason"] == Atom.to_string(reason)
    end)
  end

  test "confirmed terminals are bounded and RunRecord transition remains Phase 3 work" do
    config = config()
    terminal = completed_terminal(config, 1)

    assert ConfirmedTerminal.valid?(terminal, config)
    assert inspect(terminal) == "#Synapse.API.ConfirmedTerminal<status=:completed seq=1 redacted>"
    refute ConfirmedTerminal.valid?(%{terminal | seq: 0}, config)
    refute ConfirmedTerminal.valid?(%{terminal | status: :failed}, config)

    {:ok, record} = API.RunRecord.new(run_id(), 0, config)
    {:ok, encoded} = Wire.terminal(terminal, config)

    {:ok, replay_entry} =
      API.ReplayEntry.new(%{seq: 1, type: :terminal, encoded: encoded}, config)

    completed = %{
      record
      | status: :completed,
        projection: %{record.projection | status: :completed, text: "done", output_bytes: 4},
        terminal: terminal,
        replay: :queue.from_list([replay_entry]),
        replay_bytes: replay_entry.accounted_bytes,
        completed_ordinal: 1,
        accounted_bytes: record.accounted_bytes + 4 + replay_entry.accounted_bytes
    }

    refute API.RunRecord.valid?(completed, config)

    malformed_config = %Config{config | max_outgoing_message_bytes: nil}
    assert {:error, {:config, :must_be_valid}} = API.RunRecord.new(run_id(), 0, malformed_config)
    refute API.RunRecord.valid?(%{record | projection: nil}, config)
  end

  test "final encoding measures JSON escaping and rejects one oversized frame" do
    {:ok, budget} = Budget.new(max_output_bytes: 1)

    {:ok, tight} =
      Config.new(
        enabled: true,
        launch_cwd: "/synthetic/api-wire-launch",
        default_model: "model-a",
        budget: budget,
        max_projection_text_bytes: 1,
        max_outgoing_message_bytes: 140_000,
        max_pull_bytes: 140_000
      )

    run_id = run_id()

    {:ok, ordinary} =
      Event.new(:text_delta,
        run_id: run_id,
        turn: 1,
        operation_id: "provider-op",
        item_id: "item-1",
        content_index: 0,
        delta: String.duplicate("x", 64_000)
      )

    assert {:ok, frame} = Wire.event(run_id, 1, ordinary, tight)
    assert IO.iodata_length(frame) <= tight.max_outgoing_message_bytes

    {:ok, escaped} =
      Event.new(:text_delta, %{Map.from_struct(ordinary) | delta: String.duplicate(<<0>>, 64_000)})

    assert {:error, :message_too_large} = Wire.event(run_id, 1, escaped, tight)
  end

  test "production limits carry maximum escaped identifiers, metadata, delta, and terminal text" do
    config = config()
    run_id = run_id()
    escaped_delta = String.duplicate(<<0>>, 64_000)
    maximum_text = String.duplicate(<<0>>, config.budget.max_output_bytes)

    {:ok, delta} =
      Event.new(:text_delta,
        run_id: run_id,
        turn: 1,
        operation_id: String.duplicate(~S("), 256),
        item_id: String.duplicate("\\", 512),
        content_index: 0,
        delta: escaped_delta
      )

    assert {:ok, delta_frame} = Wire.event(run_id, 1, delta, config)
    decoded_delta = decode_frame!({:ok, delta_frame})
    assert decoded_delta["payload"]["event"]["delta"] == escaped_delta

    tool_attrs = %{
      run_id: run_id,
      turn: 1,
      operation_id: String.duplicate(~S("), 256),
      call_id: String.duplicate("\\", 512),
      name: String.duplicate(~S("), 64),
      ordinal: 1,
      status: :ok
    }

    base_value = String.duplicate(<<0>>, 679)
    base_metadata = %{"observed" => base_value}
    padding = 4_096 - byte_size(JSON.encode!(base_metadata))
    metadata = %{"observed" => base_value <> String.duplicate("x", padding)}
    assert byte_size(JSON.encode!(metadata)) == 4_096

    assert {:ok, completed} = Event.new(:tool_completed, Map.put(tool_attrs, :metadata, metadata))
    assert {:ok, tool_frame} = Wire.event(run_id, 2, completed, config)

    refute Map.has_key?(
             decode_frame!({:ok, tool_frame})["payload"]["event"]["metadata"],
             "observed"
           )

    assert {:error, _reason} =
             Event.new(
               :tool_completed,
               Map.put(tool_attrs, :metadata, %{
                 "observed" => metadata["observed"] <> "x"
               })
             )

    {:ok, response} =
      Provider.Response.new(
        id: "MAX_ESCAPED_PROVIDER_RESPONSE",
        model: "model-a",
        output_items: [],
        usage: %{}
      )

    {:ok, result} =
      Result.new(
        run_id: run_id,
        text: maximum_text,
        final_response: response,
        turns: 1,
        tool_calls: 0,
        provider_retries: 0,
        output_bytes: byte_size(maximum_text)
      )

    {:ok, terminal_event} = Event.new(:run_completed, run_id: run_id, result: result)
    {:ok, pending} = PendingTerminal.new(terminal_event, config)
    {:ok, terminal} = ConfirmedTerminal.from_pending(pending, 3, config)
    assert {:ok, terminal_frame} = Wire.terminal(terminal, config)
    decoded_terminal = decode_frame!({:ok, terminal_frame})
    assert decoded_terminal["payload"]["result"]["text"] == maximum_text

    projection = %{
      API.Projection.new()
      | status: :completed,
        model: "model-a",
        turn: 1,
        text: maximum_text,
        provider_attempts: 1,
        output_bytes: byte_size(maximum_text)
    }

    assert {:ok, snapshot_frame} =
             Wire.snapshot(
               "maximum-snapshot",
               %{
                 mode: :snapshot,
                 reset: false,
                 run_id: run_id,
                 first_available_seq: 1,
                 last_seq: 3,
                 projection: projection,
                 terminal: terminal
               },
               config
             )

    snapshot = decode_frame!({:ok, snapshot_frame})
    assert snapshot["payload"]["projection"]["text"] == ""
    assert snapshot["payload"]["terminal"]["result"]["text"] == maximum_text

    assert value_paths(decoded_delta, escaped_delta) == [["payload", "event", "delta"]]

    assert Enum.flat_map([decoded_terminal, snapshot], &value_paths(&1, maximum_text))
           |> Enum.sort() == [
             ["payload", "result", "text"],
             ["payload", "terminal", "result", "text"]
           ]
  end

  test "accepts an encoded frame at its exact byte limit and rejects one byte less" do
    {:ok, budget} = Budget.new(max_output_bytes: 1)

    attrs = [
      enabled: true,
      launch_cwd: "/synthetic/api-wire-launch",
      default_model: "model-a",
      budget: budget,
      max_projection_text_bytes: 1,
      max_outgoing_message_bytes: 140_000,
      max_pull_bytes: 140_000
    ]

    {:ok, roomy} = Config.new(attrs)
    run_id = run_id()

    {:ok, event} =
      Event.new(:text_delta,
        run_id: run_id,
        turn: 1,
        operation_id: "provider-op",
        item_id: "item-1",
        content_index: 0,
        delta: String.duplicate(<<0>>, 22_000)
      )

    {:ok, frame} = Wire.event(run_id, 1, event, roomy)
    encoded_bytes = IO.iodata_length(frame)
    assert encoded_bytes > 131_078

    {:ok, exact} =
      Config.new(
        Keyword.merge(attrs,
          max_outgoing_message_bytes: encoded_bytes,
          max_pull_bytes: encoded_bytes
        )
      )

    assert {:ok, exact_frame} = Wire.event(run_id, 1, event, exact)
    assert IO.iodata_length(exact_frame) == exact.max_outgoing_message_bytes

    {:ok, one_less} =
      Config.new(
        Keyword.merge(attrs,
          max_outgoing_message_bytes: encoded_bytes - 1,
          max_pull_bytes: encoded_bytes - 1
        )
      )

    assert {:error, :message_too_large} = Wire.event(run_id, 1, event, one_less)
  end

  test "encoded messages omit secrets, Provider response, authority, and struct syntax" do
    config = config()
    terminal = completed_terminal(config, 1)

    frames = [
      Wire.hello(config),
      Wire.error(:internal_error, nil, config),
      Wire.terminal(terminal, config),
      Wire.owner_lost(run_id(), 2, config)
    ]

    encoded =
      frames
      |> Enum.map(fn {:ok, frame} -> IO.iodata_to_binary(frame) end)
      |> Enum.join("\n")

    for sentinel <- [
          "SYNTHETIC_FINAL_RESPONSE_SECRET",
          "SYNTHETIC_PHASE2_PROMPT",
          "/synthetic/private/path",
          "final_response",
          "#PID<",
          "#Reference<",
          "Elixir.Synapse",
          "%Synapse."
        ] do
      refute encoded =~ sentinel
    end
  end

  test "rejects invalid snapshot combinations and outgoing inputs" do
    config = config()
    run_id = run_id()
    projection = %{API.Projection.new() | status: :running, model: "model-a"}

    base = %{
      mode: :snapshot,
      reset: false,
      run_id: run_id,
      first_available_seq: 1,
      last_seq: 1,
      projection: projection,
      terminal: nil
    }

    assert {:error, :invalid_message} = Wire.snapshot("bad\nrequest", base, config)

    assert {:error, :invalid_message} =
             Wire.snapshot("request-1", Map.delete(base, :reset), config)

    assert {:error, :invalid_message} =
             Wire.snapshot("request-1", %{base | mode: :replay}, config)

    assert {:error, :invalid_message} =
             Wire.snapshot("request-1", %{base | first_available_seq: 3}, config)

    assert {:error, :invalid_message} =
             Wire.snapshot(
               "request-1",
               %{base | first_available_seq: 0, last_seq: 0},
               config
             )

    terminal = completed_terminal(config, 2)

    assert {:error, :invalid_message} =
             Wire.snapshot("request-1", %{base | terminal: terminal}, config)

    completed_projection = %{projection | status: :completed, text: "done", output_bytes: 4}

    assert {:error, :invalid_message} =
             Wire.snapshot(
               "request-1",
               %{
                 base
                 | projection: completed_projection,
                   terminal: terminal,
                   last_seq: terminal.seq + 1
               },
               config
             )

    assert {:error, :invalid_message} = Wire.run_accepted("request-1", "run_invalid", config)
    assert {:error, :invalid_message} = Wire.pong("", config)

    malformed_config = %Config{config | max_request_id_bytes: nil}
    assert {:error, :invalid_message} = Wire.pong("request-1", malformed_config)
  end

  defp config do
    {:ok, config} =
      Config.new(
        enabled: true,
        launch_cwd: "/synthetic/api-wire-launch",
        default_model: "model-a"
      )

    config
  end

  defp completed_terminal(config, seq) do
    result = agent_result(run_id())
    {:ok, event} = Event.new(:run_completed, run_id: run_id(), result: result)
    {:ok, pending} = PendingTerminal.new(event, config)
    {:ok, terminal} = ConfirmedTerminal.from_pending(pending, seq, config)
    terminal
  end

  defp agent_result(run_id) do
    {:ok, response} =
      Provider.Response.new(
        id: "SYNTHETIC_FINAL_RESPONSE_SECRET",
        model: "model-a",
        output_items: [],
        usage: %{"private" => "SYNTHETIC_PHASE2_PROMPT /synthetic/private/path"}
      )

    {:ok, result} =
      Result.new(
        run_id: run_id,
        text: "done",
        final_response: response,
        turns: 1,
        tool_calls: 0,
        provider_retries: 0,
        output_bytes: 4
      )

    result
  end

  defp tool_attrs(run_id) do
    %{
      run_id: run_id,
      turn: 2,
      operation_id: "tool-op",
      call_id: "call-1",
      name: "read",
      ordinal: 1
    }
  end

  defp value_paths(value, expected), do: value_paths(value, expected, [])

  defp value_paths(value, expected, path) when is_map(value) do
    Enum.flat_map(value, fn {key, item} -> value_paths(item, expected, path ++ [key]) end)
  end

  defp value_paths(value, expected, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} -> value_paths(item, expected, path ++ [index]) end)
  end

  defp value_paths(value, expected, path) when value == expected, do: [path]
  defp value_paths(_value, _expected, _path), do: []

  defp terminal_payload_fixture(run_id, seq) do
    %{
      "run_id" => run_id,
      "seq" => seq,
      "status" => "completed",
      "result" => %{
        "text" => "done",
        "turns" => 1,
        "tool_calls" => 0,
        "provider_retries" => 0,
        "output_bytes" => 4
      },
      "error" => nil
    }
  end

  defp assert_frame(result, fixture, config) do
    assert {:ok, frame} = result
    assert IO.iodata_length(frame) <= config.max_outgoing_message_bytes
    assert decode_frame!({:ok, frame}) == decode_json!(fixture)
  end

  defp decode_frame!({:ok, frame}), do: frame |> IO.iodata_to_binary() |> decode_json!()

  defp decode_json!(json) do
    assert {:ok, decoded} = JSON.decode(json)
    decoded
  end

  defp run_id, do: "run_" <> Base.url_encode64(<<0::128>>, padding: false)
  defp other_run_id, do: "run_" <> Base.url_encode64(<<1::128>>, padding: false)
end
