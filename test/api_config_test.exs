defmodule Synapse.API.ConfigTest do
  use ExUnit.Case, async: true

  alias Synapse.API
  alias Synapse.API.Config
  alias Synapse.Budget
  alias Synapse.Runtime.Options
  alias Synapse.Tool.CapabilitySet

  doctest Config

  @limit_fields [
    :max_incoming_message_bytes,
    :max_incoming_frame_payload_bytes,
    :max_outgoing_message_bytes,
    :max_prompt_bytes,
    :max_request_id_bytes,
    :max_run_id_bytes,
    :max_origin_bytes,
    :max_json_depth,
    :max_json_object_keys,
    :max_json_array_elements,
    :max_json_nodes,
    :max_http_request_line_bytes,
    :max_http_headers,
    :max_http_header_line_bytes,
    :max_http_header_bytes,
    :connection_inactivity_ms,
    :max_protocol_violations,
    :max_connections,
    :max_subscriptions_per_socket,
    :max_subscribers_per_run,
    :max_replay_events,
    :max_replay_bytes,
    :max_projection_text_bytes,
    :max_pull_events,
    :max_pull_bytes,
    :max_completed_runs,
    :max_active_state_bytes,
    :max_aggregate_state_bytes
  ]

  test "defaults centralize disabled loopback policy and every hard limit" do
    config = Config.default()

    assert Config.valid?(config)
    assert config.enabled == false
    assert config.ip == {127, 0, 0, 1}
    assert config.port == 4_848
    assert config.model_allowlist == []
    assert config.default_model == nil
    assert config.budget == Budget.default()
    assert config.capabilities == capabilities(true, true, true)
    assert Options.valid?(config.runtime_options)

    assert Map.take(Map.from_struct(config), @limit_fields) == %{
             max_incoming_message_bytes: 2_097_152,
             max_incoming_frame_payload_bytes: 2_097_152,
             max_outgoing_message_bytes: 1_048_576,
             max_prompt_bytes: 262_144,
             max_request_id_bytes: 128,
             max_run_id_bytes: 64,
             max_origin_bytes: 512,
             max_json_depth: 16,
             max_json_object_keys: 32,
             max_json_array_elements: 128,
             max_json_nodes: 4_096,
             max_http_request_line_bytes: 8_192,
             max_http_headers: 32,
             max_http_header_line_bytes: 1_024,
             max_http_header_bytes: 32_768,
             connection_inactivity_ms: 60_000,
             max_protocol_violations: 8,
             max_connections: 128,
             max_subscriptions_per_socket: 16,
             max_subscribers_per_run: 128,
             max_replay_events: 2_048,
             max_replay_bytes: 4_194_304,
             max_projection_text_bytes: 64_000,
             max_pull_events: 64,
             max_pull_bytes: 1_048_576,
             max_completed_runs: 16,
             max_active_state_bytes: 6_291_456,
             max_aggregate_state_bytes: 16_777_216
           }

    assert Config.max_incoming_frame_wire_bytes(config) == 2_097_166
  end

  test "environment overrides port and default model without widening the allowlist" do
    environment = environment(%{"SYNAPSE_API_PORT" => "5858", "SYNAPSE_MODEL" => "model-b"})

    assert {:ok, config} =
             Config.load(
               [
                 enabled: true,
                 model_allowlist: ["model-a", "model-b"],
                 default_model: "model-a"
               ],
               environment
             )

    assert config.port == 5_858
    assert config.default_model == "model-b"
    assert config.model_allowlist == ["model-a", "model-b"]

    assert {:error, {:default_model, :must_be_allowlisted}} =
             Config.load(
               [enabled: true, model_allowlist: ["model-a"]],
               environment
             )

    assert {:ok, port_zero} = Config.load([port: 0], environment(%{}))
    assert port_zero.port == 0
  end

  test "malformed environment is sanitized and environment port zero is forbidden" do
    for value <- ["", "0", "65536", "12x", " 4848", "SYNTHETIC_PORT_SECRET"] do
      assert {:error, {:environment, :invalid_port}} =
               Config.load([], environment(%{"SYNAPSE_API_PORT" => value}))
    end

    for value <- ["", "bad\nmodel", String.duplicate("m", 257)] do
      assert {:error, {:environment, :invalid_model}} =
               Config.load([], environment(%{"SYNAPSE_MODEL" => value}))
    end

    assert {:error, {:environment, :unavailable}} =
             Config.load([], fn _name -> raise "secret" end)

    assert {:error, {:environment, :unavailable}} = Config.load([], fn _name -> :invalid end)
    assert {:error, {:environment, :unavailable}} = Config.load([], :not_a_function)
  end

  test "model default and allowlist normalization remain bounded" do
    assert {:ok, config} = Config.new(enabled: true, default_model: "model-a")
    assert config.model_allowlist == ["model-a"]
    assert config.default_model == "model-a"

    assert {:ok, config} =
             Config.new(
               enabled: true,
               model_allowlist: ["model-a", "model-a", "model-b"],
               default_model: "model-a"
             )

    assert config.model_allowlist == ["model-a", "model-b"]
    assert config.default_model == "model-a"

    assert {:error, {:default_model, :required_when_enabled}} = Config.new(enabled: true)

    assert {:error, {:default_model, :required_when_enabled}} =
             Config.new(enabled: true, model_allowlist: ["model-a"])

    assert {:error, {:default_model, :must_be_allowlisted}} =
             Config.new(default_model: "model-b", model_allowlist: ["model-a"])

    assert {:error, {:model_allowlist, :must_be_bounded_identifiers}} =
             Config.new(model_allowlist: List.duplicate("model", 129))

    assert {:error, {:model_allowlist, :must_be_bounded_identifiers}} =
             Config.new(model_allowlist: ["bad\nmodel"])

    assert {:ok, independent_policy} =
             Config.new(
               max_json_array_elements: 1,
               model_allowlist: ["model-a", "model-b"],
               default_model: "model-a"
             )

    assert independent_policy.model_allowlist == ["model-a", "model-b"]
  end

  test "trusted startup policy rejects malformed fields and remote authority" do
    invalid = [
      enabled: :yes,
      ip: :loopback,
      ip: {0, 0, 0, 0},
      port: -1,
      port: 65_536,
      budget: %{},
      capabilities: %{},
      runtime_options: %{}
    ]

    Enum.each(invalid, fn {field, value} ->
      assert {:error, {^field, _reason}} = Config.new([{field, value}])
    end)

    for field <- [:api_key, :bind, :endpoint, :provider, :workspace_opener, :event_sink] do
      assert {:error, {:unknown_fields, [^field]}} = Config.new([{field, "secret"}])
    end

    assert {:error, {:attributes, :must_be_keyword_or_map}} =
             Config.new([{:enabled, true} | :bad])
  end

  test "every hard limit rejects non-positive, non-integer, and above-ceiling values" do
    defaults = Config.default()

    Enum.each(@limit_fields, fn field ->
      assert {:error, {^field, :must_be_in_recorded_range}} = Config.new([{field, 0}])

      assert {:error, {^field, :must_be_in_recorded_range}} =
               Config.new([{field, Map.fetch!(defaults, field) + 1}])

      assert {:error, {^field, :must_be_in_recorded_range}} = Config.new([{field, 1.0}])
    end)
  end

  test "incompatible limit combinations are rejected before use" do
    assert {:ok, fragmented_only} = Config.new(max_incoming_frame_payload_bytes: 1)
    assert fragmented_only.max_incoming_frame_payload_bytes == 1

    assert {:error, {:max_incoming_message_bytes, :incompatible_limit}} =
             Config.new(
               max_incoming_message_bytes: 1_000_000,
               max_incoming_frame_payload_bytes: 1_000_000
             )

    {:ok, small_budget} = Budget.new(max_output_bytes: 1_000)

    assert {:error, {:max_pull_bytes, :incompatible_limit}} =
             Config.new(
               budget: small_budget,
               max_projection_text_bytes: 1_000,
               max_outgoing_message_bytes: 200_000,
               max_pull_bytes: 300_000
             )

    assert {:error, {:max_pull_bytes, :incompatible_limit}} =
             Config.new(max_pull_bytes: Config.default().max_pull_bytes - 1)

    assert {:error, {:max_replay_bytes, :incompatible_limit}} =
             Config.new(max_replay_bytes: Config.default().max_outgoing_message_bytes)

    assert {:error, {:max_outgoing_message_bytes, :incompatible_limit}} =
             Config.new(max_outgoing_message_bytes: 800_000, max_pull_bytes: 800_000)

    assert {:error, {:max_projection_text_bytes, :incompatible_limit}} =
             Config.new(max_projection_text_bytes: 1)

    assert {:error, {:max_origin_bytes, :incompatible_limit}} =
             Config.new(max_http_header_line_bytes: 256)

    assert {:error, {:max_http_header_bytes, :incompatible_limit}} =
             Config.new(max_http_header_bytes: 16_000)

    assert {:ok, independently_lowered} =
             Config.new(
               max_connections: 1,
               max_subscribers_per_run: 128,
               max_subscriptions_per_socket: 16,
               max_completed_runs: 1,
               max_replay_events: 1,
               max_pull_events: 64,
               max_replay_bytes:
                 Config.default().max_outgoing_message_bytes +
                   Config.replay_entry_overhead_bytes(),
               max_pull_bytes: 1_048_576
             )

    assert independently_lowered.max_completed_runs == 1

    assert {:error, {:max_active_state_bytes, :incompatible_limit}} =
             Config.new(max_active_state_bytes: 4_000_000)

    encoded_only_active_state =
      Config.default().max_replay_bytes + Config.default().max_projection_text_bytes +
        Config.default().max_outgoing_message_bytes

    assert {:error, {:max_active_state_bytes, :incompatible_limit}} =
             Config.new(max_active_state_bytes: encoded_only_active_state)

    assert {:error, {:max_aggregate_state_bytes, :incompatible_limit}} =
             Config.new(max_aggregate_state_bytes: 6_000_000)
  end

  test "default outgoing limit fits a completed snapshot with worst-case escaped text twice" do
    config = Config.default()
    text = String.duplicate(<<0>>, config.budget.max_output_bytes)

    snapshot = %{
      "version" => 1,
      "type" => "run.snapshot",
      "request_id" => "request-1",
      "payload" => %{
        "mode" => "snapshot",
        "reset" => true,
        "run_id" => run_id(),
        "first_available_seq" => 1,
        "last_seq" => 1,
        "projection" => %{
          "status" => "completed",
          "model" => "model-a",
          "turn" => 1,
          "text" => text,
          "active_tool" => nil,
          "provider_attempts" => 1,
          "tool_calls" => 0,
          "output_bytes" => byte_size(text)
        },
        "terminal" => %{
          "run_id" => run_id(),
          "seq" => 1,
          "status" => "completed",
          "result" => %{
            "text" => text,
            "turns" => 1,
            "tool_calls" => 0,
            "provider_retries" => 0,
            "output_bytes" => byte_size(text)
          },
          "error" => nil
        }
      }
    }

    encoded_bytes = snapshot |> JSON.encode_to_iodata!() |> IO.iodata_length()
    assert encoded_bytes <= config.max_outgoing_message_bytes
  end

  test "client-shaped Budget data can only lower server policy" do
    {:ok, server_budget} =
      Budget.new(
        max_turns: 10,
        max_tool_calls: 20,
        max_wall_time_ms: 600_000,
        provider_inactivity_ms: 90_000,
        tool_inactivity_ms: 120_000,
        max_output_bytes: 32_000,
        max_provider_retries: 1
      )

    {:ok, %Config{} = config} = Config.new(budget: server_budget)
    assert {:ok, ^server_budget} = Config.lower_budget(config, %{})

    lower = %{
      max_turns: 5,
      max_tool_calls: 10,
      max_wall_time_ms: 300_000,
      provider_inactivity_ms: 45_000,
      tool_inactivity_ms: 60_000,
      max_output_bytes: 16_000,
      max_provider_retries: 0
    }

    assert {:ok, lowered} = Config.lower_budget(config, lower)
    assert Map.take(Map.from_struct(lowered), Map.keys(lower)) == lower

    Enum.each(Map.from_struct(server_budget), fn {field, value} ->
      assert {:error, {^field, :must_not_exceed_server_policy}} =
               Config.lower_budget(config, %{field => value + 1})

      assert {:ok, _equal} = Config.lower_budget(config, %{field => value})
    end)

    assert {:error, {:unknown_fields, [:capabilities]}} =
             Config.lower_budget(config, capabilities: %{process_exec: true})

    assert {:error, {:unknown_fields, [:unknown]}} =
             Config.lower_budget(config, %{"max_turns" => 1})

    assert {:error, {:max_turns, :must_be_in_recorded_range}} =
             Config.lower_budget(config, %{max_turns: "five"})

    malformed = %Config{config | budget: %{}}
    assert {:error, {:config, :must_be_valid}} = Config.lower_budget(malformed, %{})

    assert config.capabilities == capabilities(true, true, true)
  end

  test "inspection redacts startup policy, commands, state, content, and authority" do
    secret = "SYNTHETIC_API_PHASE1_SECRET"
    path = "/tmp/#{secret}"

    {:ok, runtime_options} =
      Options.new(
        provider: Synapse.Provider.Fake,
        instructions: secret,
        retry_delay: fn _ordinal -> 0 end,
        workspace_opener: fn _request -> {:error, secret} end
      )

    {:ok, config} =
      Config.new(
        model_allowlist: [secret],
        default_model: secret,
        runtime_options: runtime_options
      )

    start = %API.Command.Start{prompt: secret, cwd: path, model: secret, budget: config.budget}
    cancel = %API.Command.Cancel{run_id: secret}
    subscribe = %API.Command.Subscribe{run_id: secret, after_seq: 1}

    tool = %API.ActiveTool{
      turn: 1,
      operation_id: secret,
      call_id: secret,
      name: secret,
      ordinal: 1
    }

    projection = %{API.Projection.new() | text: secret, active_tool: tool}

    subscriber = %API.Subscriber{
      pid: self(),
      monitor: make_ref(),
      cursor: 0,
      notified: false
    }

    entry = %API.ReplayEntry{
      seq: 1,
      type: :event,
      encoded: secret,
      encoded_bytes: byte_size(secret),
      accounted_bytes: byte_size(secret) + Config.replay_entry_overhead_bytes()
    }

    pending_terminal = %API.PendingTerminal{
      run_id: secret,
      status: :completed,
      result: %{text: secret},
      error: nil
    }

    record = %API.RunRecord{
      id: secret,
      status: :starting,
      cancel_requested: false,
      session_pid: self(),
      session_monitor: make_ref(),
      runtime_run: {:opaque_authority, secret},
      last_seq: 0,
      projection: projection,
      run_started: false,
      open_turn: nil,
      provider_operation_id: nil,
      last_completed_turn: 0,
      last_turn_outcome: nil,
      last_tool_ordinal: 0,
      owner_lost_tool: nil,
      pending_terminal: {:pending, secret},
      terminal: %{"text" => secret},
      replay: :queue.from_list([entry]),
      replay_bytes: byte_size(secret),
      subscribers: %{self() => subscriber},
      created_ordinal: 0,
      completed_ordinal: nil,
      sink_rejected: false,
      accounted_bytes:
        config.max_outgoing_message_bytes + Config.run_record_overhead_bytes() +
          byte_size(secret)
    }

    inspected =
      [
        config,
        start,
        cancel,
        subscribe,
        tool,
        projection,
        subscriber,
        entry,
        pending_terminal,
        record
      ]
      |> Enum.map_join("\n", &inspect/1)

    refute inspected =~ secret
    refute inspected =~ path
    refute inspected =~ inspect(self())
    refute inspected =~ "Reference"
    refute inspected =~ "opaque_authority"
    refute inspected =~ "pending"

    forged = [
      %{subscribe | after_seq: secret},
      %{tool | turn: secret},
      %{projection | status: secret},
      %{subscriber | cursor: secret},
      %{entry | type: secret},
      %{pending_terminal | status: secret},
      %{record | last_seq: secret}
    ]

    Enum.each(forged, fn value ->
      inspected = inspect(value)
      refute inspected =~ secret
      assert inspected =~ "invalid redacted"
    end)
  end

  test "internal command constructors enforce protocol-independent bounds" do
    {:ok, config} =
      Config.new(
        enabled: true,
        model_allowlist: ["model-a"],
        default_model: "model-a"
      )

    run_id = run_id()

    assert {:ok, start} =
             API.Command.Start.new(
               [prompt: "Inspect.", cwd: "/tmp/project", model: "model-a", budget: config.budget],
               config
             )

    assert API.Command.Start.valid?(start, config)
    assert {:ok, {"request-1", ^start}} = API.Command.new("request-1", start, config)

    assert {:error, {:prompt, :must_be_bounded_non_empty_string}} =
             API.Command.Start.new(
               [
                 prompt: String.duplicate("p", config.max_prompt_bytes + 1),
                 cwd: "/tmp/project",
                 model: "model-a",
                 budget: config.budget
               ],
               config
             )

    assert {:error, {:cwd, :must_be_absolute_path}} =
             API.Command.Start.new(
               [prompt: "Inspect.", cwd: "relative", model: "model-a", budget: config.budget],
               config
             )

    assert {:error, {:model, :must_be_allowlisted}} =
             API.Command.Start.new(
               [prompt: "Inspect.", cwd: "/tmp/project", model: "model-b", budget: config.budget],
               config
             )

    {:ok, wider_budget} = Budget.new(max_turns: config.budget.max_turns + 1)

    assert {:error, {:budget, :must_be_lowered_budget}} =
             API.Command.Start.new(
               [prompt: "Inspect.", cwd: "/tmp/project", model: "model-a", budget: wider_budget],
               config
             )

    assert {:ok, cancel} = API.Command.Cancel.new(%{run_id: run_id}, config)
    assert API.Command.Cancel.valid?(cancel, config)

    assert {:error, {:run_id, :must_be_valid}} =
             API.Command.Cancel.new(%{run_id: "run_bad"}, config)

    assert {:ok, subscribe} =
             API.Command.Subscribe.new(%{run_id: run_id, after_seq: 0}, config)

    assert API.Command.Subscribe.valid?(subscribe, config)

    assert {:error, {:after_seq, :must_be_cursor}} =
             API.Command.Subscribe.new(
               %{run_id: run_id, after_seq: 9_223_372_036_854_775_808},
               config
             )

    assert {:ok, %API.Command.Ping{}} = API.Command.Ping.new(%{}, config)
    assert {:error, {:unknown_fields, [:echo]}} = API.Command.Ping.new(%{echo: "no"}, config)

    assert {:error, {:request_id, :must_be_bounded_identifier}} =
             API.Command.new(
               String.duplicate("r", config.max_request_id_bytes + 1),
               cancel,
               config
             )
  end

  test "internal state constructors validate identities, counters, bytes, and retained bounds" do
    {:ok, config} =
      Config.new(model_allowlist: ["model-a"], default_model: "model-a")

    assert {:ok, tool} =
             API.ActiveTool.new(
               [
                 turn: 1,
                 operation_id: "operation-1",
                 call_id: "call-1",
                 name: "read",
                 ordinal: 1
               ],
               config
             )

    projection = %{API.Projection.new() | model: "model-a", active_tool: tool}
    assert API.Projection.valid?(projection, config)
    refute API.Projection.valid?(%{projection | text: String.duplicate("x", 64_001)}, config)
    refute API.Projection.valid?(%{projection | turn: 9_223_372_036_854_775_808}, config)

    assert {:ok, subscriber} =
             API.Subscriber.new(
               pid: self(),
               monitor: make_ref(),
               cursor: 0,
               notified: false
             )

    assert API.Subscriber.valid?(subscriber)
    refute API.Subscriber.valid?(%{subscriber | cursor: -1})

    assert {:ok, entry} =
             API.ReplayEntry.new(
               [seq: 1, type: :event, encoded: ["{", "}"]],
               config
             )

    assert API.ReplayEntry.valid?(entry, config)
    assert entry.encoded_bytes == 2
    assert entry.accounted_bytes == 2 + Config.replay_entry_overhead_bytes()

    refute API.ReplayEntry.valid?(%{entry | encoded_bytes: 1}, config)
    refute API.ReplayEntry.valid?(%{entry | accounted_bytes: 1}, config)

    assert {:error, {:encoded, :must_be_iodata}} =
             API.ReplayEntry.new(
               [seq: 1, type: :event, encoded: {:not, :iodata}],
               config
             )

    assert {:ok, record} = API.RunRecord.new(run_id(), 0, config)
    assert API.RunRecord.valid?(record, config)
    refute API.RunRecord.valid?(%{record | replay: :not_a_queue}, config)
    refute API.RunRecord.valid?(%{record | replay_bytes: 1}, config)
    refute API.RunRecord.valid?(%{record | accounted_bytes: 0}, config)

    refute API.RunRecord.valid?(
             %{record | accounted_bytes: config.max_active_state_bytes + 1},
             config
           )

    replayed = %{
      record
      | last_seq: 1,
        replay: :queue.from_list([entry]),
        replay_bytes: entry.accounted_bytes,
        accounted_bytes: record.accounted_bytes + entry.accounted_bytes
    }

    assert API.RunRecord.valid?(replayed, config)

    refute API.RunRecord.valid?(
             %{replayed | replay: :queue.from_list([%{entry | type: :terminal}])},
             config
           )

    refute API.RunRecord.valid?(
             %{replayed | accounted_bytes: replayed.accounted_bytes - 1},
             config
           )

    subscribed = %{
      record
      | subscribers: %{self() => subscriber},
        accounted_bytes: record.accounted_bytes + Config.subscriber_overhead_bytes()
    }

    assert API.RunRecord.valid?(subscribed, config)

    {:ok, replay_one} = Config.new(max_replay_events: 1)
    two_entries = :queue.from_list([entry, %{entry | seq: 2}])

    refute API.RunRecord.valid?(
             %{
               record
               | last_seq: 2,
                 replay: two_entries,
                 replay_bytes: entry.accounted_bytes * 2,
                 accounted_bytes: record.accounted_bytes + entry.accounted_bytes * 2
             },
             replay_one
           )

    assert {:error, {:max_replay_bytes, :must_be_in_recorded_range}} =
             Config.new(max_replay_bytes: Config.replay_entry_overhead_bytes())

    assert {:error, {:max_replay_bytes, :incompatible_limit}} =
             Config.new(max_replay_bytes: Config.replay_entry_overhead_bytes() + 1)

    other_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        after
          10_000 -> exit(:other_subscriber_stop_timeout)
        end
      end)

    on_exit(fn -> send(other_pid, :stop) end)

    {:ok, other_subscriber} =
      API.Subscriber.new(
        pid: other_pid,
        monitor: make_ref(),
        cursor: 0,
        notified: false
      )

    {:ok, one_subscriber} = Config.new(max_subscribers_per_run: 1)

    refute API.RunRecord.valid?(
             %{
               record
               | subscribers: %{self() => subscriber, other_pid => other_subscriber},
                 accounted_bytes: record.accounted_bytes + Config.subscriber_overhead_bytes() * 2
             },
             one_subscriber
           )

    pending = pending_terminal(config)
    assert API.PendingTerminal.valid?(pending, config)
    assert API.RunRecord.valid?(%{record | pending_terminal: pending}, config)

    forged_pending = %{
      pending
      | result: %{
          pending.result
          | text: String.duplicate("x", config.budget.max_output_bytes + 1),
            output_bytes: config.budget.max_output_bytes + 1
        }
    }

    refute API.PendingTerminal.valid?(forged_pending, config)
    refute API.RunRecord.valid?(%{record | pending_terminal: forged_pending}, config)
    refute API.RunRecord.valid?(%{record | terminal: %{"status" => "completed"}}, config)

    refute API.RunRecord.valid?(
             %{
               record
               | status: :completed,
                 projection: %{record.projection | status: :completed}
             },
             config
           )
  end

  test "initial projection is bounded and Phase 6 transport supervision is loaded" do
    assert API.Projection.new() == %API.Projection{
             status: :starting,
             model: nil,
             turn: 0,
             text: "",
             active_tool: nil,
             provider_attempts: 0,
             tool_calls: 0,
             output_bytes: 0
           }

    assert Code.ensure_loaded?(Synapse.API.Router)
    assert Code.ensure_loaded?(Synapse.API.Socket)
    assert Code.ensure_loaded?(Synapse.API.RunManager)
    assert Code.ensure_loaded?(Synapse.API.RunSession)
    assert Code.ensure_loaded?(Synapse.API.SessionSupervisor)
    assert Code.ensure_loaded?(Synapse.API.Supervisor)
  end

  defp capabilities(read, write, exec) do
    {:ok, capabilities} =
      CapabilitySet.new(fs_read: read, fs_write: write, process_exec: exec)

    capabilities
  end

  defp environment(values), do: fn name -> Map.get(values, name) end

  defp run_id,
    do: "run_" <> Base.url_encode64(<<0::128>>, padding: false)

  defp pending_terminal(config) do
    {:ok, response} =
      Synapse.Provider.Response.new(
        id: "response-1",
        model: "model-a",
        output_items: [
          %Synapse.Provider.OutputItem.Message{
            id: "message-1",
            role: :assistant,
            content: "Done"
          }
        ]
      )

    {:ok, result} =
      Synapse.Agent.Result.new(
        run_id: run_id(),
        text: "Done",
        final_response: response,
        turns: 1,
        tool_calls: 0,
        provider_retries: 0,
        output_bytes: 4
      )

    {:ok, event} = Synapse.Run.Event.new(:run_completed, run_id: run_id(), result: result)
    {:ok, pending} = API.PendingTerminal.new(event, config)
    pending
  end
end
