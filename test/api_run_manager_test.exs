defmodule Synapse.API.RunManagerTest do
  use ExUnit.Case, async: true

  alias Synapse.Agent.{Error, Result}
  alias Synapse.API
  alias Synapse.API.{Config, RunManager}
  alias Synapse.Budget
  alias Synapse.Provider
  alias Synapse.Run.Event
  alias Synapse.Runtime.Error, as: RuntimeError
  alias Synapse.Runtime.Run

  test "racing starts admit exactly one session and failed admission rolls back" do
    test_pid = self()

    starter = fn manager, run_id, _command ->
      session = spawn(fn -> session_loop() end)
      send(test_pid, {:session_admitted, manager, run_id, session})
      {:ok, session}
    end

    {:ok, manager} = start_manager(session_starter: starter)
    command = start_command(config(manager))

    callers =
      for _ordinal <- 1..32 do
        spawn_monitor(fn ->
          receive do
            :go -> send(test_pid, {:start_result, RunManager.start_run(manager, command)})
          after
            5_000 -> exit(:start_barrier_timeout)
          end
        end)
      end

    Enum.each(callers, fn {pid, _monitor} -> send(pid, :go) end)

    results =
      for _ordinal <- 1..32 do
        assert_receive {:start_result, result}, 5_000
        result
      end

    assert Enum.count(results, &match?({:ok, _run_id}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :run_busy})) == 31
    assert_receive {:session_admitted, ^manager, run_id, session}
    refute_receive {:session_admitted, ^manager, _other_id, _other_session}
    assert :sys.get_state(manager).active_run_id == run_id

    Enum.each(callers, fn {_pid, monitor} ->
      assert_receive {:DOWN, ^monitor, :process, _pid, :normal}
    end)

    send(session, :stop)

    failing = fn _manager, _run_id, _command -> {:error, :synthetic_failure} end
    {:ok, failed_manager} = start_manager(session_starter: failing)

    assert {:error, :runtime_unavailable} =
             RunManager.start_run(failed_manager, start_command(config(failed_manager)))

    failed_state = :sys.get_state(failed_manager)
    assert failed_state.runs == %{}
    assert failed_state.active_run_id == nil
    assert failed_state.aggregate_bytes == 0
  end

  test "named startup validates trusted Config" do
    name = {:global, {__MODULE__, make_ref()}}
    {:ok, manager} = RunManager.start_link(config: default_config(), name: name)
    assert :global.whereis_name(elem(name, 1)) == manager
    GenServer.stop(manager)

    %Config{} = config = default_config()
    malformed = %Config{config | max_pull_bytes: 1}
    previous_trap = Process.flag(:trap_exit, true)
    assert {:error, :invalid_api_config} = RunManager.start_link(config: malformed, name: nil)

    receive do
      {:EXIT, _pid, :invalid_api_config} -> :ok
    after
      0 -> :ok
    end

    Process.flag(:trap_exit, previous_trap)
  end

  test "progress transitions are ordered, bounded, and invalid order is sink rejection" do
    {:ok, manager} = start_manager()
    {run_id, _session} = start_one(manager)

    assert :ok =
             RunManager.record_event(
               manager,
               event(:run_started, run_id: run_id, model: "model-a")
             )

    assert_receive {:synapse_run_changed, ^run_id}

    assert :ok =
             RunManager.record_event(
               manager,
               event(:turn_started, run_id: run_id, turn: 1, operation_id: "provider-op")
             )

    assert :ok =
             RunManager.record_event(
               manager,
               event(:text_delta,
                 run_id: run_id,
                 turn: 1,
                 operation_id: "provider-op",
                 item_id: "item-1",
                 content_index: 0,
                 delta: "hello"
               )
             )

    assert :ok = RunManager.record_event(manager, event(:tool_started, tool_attrs(run_id, 1)))

    assert :ok =
             RunManager.record_event(
               manager,
               event(
                 :tool_completed,
                 Map.merge(tool_attrs(run_id, 1), %{status: :ok, metadata: %{}})
               )
             )

    assert :ok =
             RunManager.record_event(
               manager,
               event(:turn_completed,
                 run_id: run_id,
                 turn: 1,
                 outcome: :continued,
                 provider_attempts: 2,
                 tool_calls: 1,
                 output_bytes: 5
               )
             )

    record = run(manager, run_id)
    assert record.last_seq == 6
    assert record.projection.text == "hello"
    assert record.projection.provider_attempts == 2
    assert record.projection.tool_calls == 1
    assert record.projection.output_bytes == 5
    assert record.last_completed_turn == 1
    assert record.open_turn == nil
    assert API.RunRecord.valid?(record, config(manager))

    assert {:error, :closed} =
             RunManager.record_event(
               manager,
               event(:turn_completed,
                 run_id: run_id,
                 turn: 1,
                 outcome: :continued,
                 provider_attempts: 2,
                 tool_calls: 1,
                 output_bytes: 5
               )
             )

    rejected = run(manager, run_id)
    assert rejected.last_seq == 6
    assert rejected.sink_rejected
    assert rejected.cancel_requested
    assert rejected.status == :cancel_requested
  end

  test "synchronous events from distinct callers retain Manager serialization order" do
    {:ok, manager} = start_manager()
    {run_id, _session} = start_one(manager)
    test_pid = self()

    events = [
      event(:run_started, run_id: run_id, model: "model-a"),
      event(:turn_started, run_id: run_id, turn: 1, operation_id: "provider-op"),
      event(:text_delta,
        run_id: run_id,
        turn: 1,
        operation_id: "provider-op",
        item_id: "item-1",
        content_index: 0,
        delta: "x"
      )
    ]

    callers =
      Enum.map(events, fn event ->
        spawn(fn ->
          receive do
            :go ->
              send(test_pid, {:event_result, self(), RunManager.record_event(manager, event)})
          after
            5_000 -> exit(:event_barrier_timeout)
          end
        end)
      end)

    Enum.each(callers, fn caller ->
      send(caller, :go)
      assert_receive {:event_result, ^caller, :ok}, 1_000
    end)

    assert run(manager, run_id).replay |> :queue.to_list() |> Enum.map(& &1.seq) == [1, 2, 3]
  end

  test "cancellation before and after handle registration is idempotent and terminal-aware" do
    test_pid = self()

    cancel_run = fn run ->
      send(test_pid, {:runtime_cancelled, run})
      :ok
    end

    {:ok, manager} = start_manager(cancel_run: cancel_run)
    {run_id, session} = start_one(manager)

    assert {:ok, :cancel_requested} = RunManager.cancel(manager, run_id)
    refute_receive {:runtime_cancelled, _run}

    assert :ok =
             RunManager.record_event(
               manager,
               event(:run_started, run_id: run_id, model: "model-a")
             )

    assert run(manager, run_id).status == :cancel_requested

    handle = runtime_run(run_id, session)
    assert {:error, :closed} = RunManager.register_runtime_run(manager, run_id, handle)

    assert {:error, :closed} =
             RunManager.settle(manager, run_id, {:ok, agent_result(run_id, "x")})

    assert :ok =
             session_call(session, fn ->
               RunManager.register_runtime_run(manager, run_id, handle)
             end)

    assert_receive {:runtime_cancelled, ^handle}

    assert {:ok, :cancel_requested} = RunManager.cancel(manager, run_id)
    assert_receive {:runtime_cancelled, ^handle}

    result = agent_result(run_id, "done")
    prepare_success(manager, run_id)
    completed = event(:run_completed, run_id: run_id, result: result)
    assert :ok = RunManager.record_event(manager, completed)

    assert :ok =
             session_call(session, fn -> RunManager.settle(manager, run_id, {:ok, result}) end)

    assert {:ok, :already_terminal} = RunManager.cancel(manager, run_id)
    assert {:error, :run_not_found} = RunManager.cancel(manager, other_run_id())
  end

  test "pending terminals stay invisible until matching settlement and mismatch is API-owned" do
    test_pid = self()

    {:ok, manager} =
      start_manager(
        id_generator: id_generator([run_id(1), run_id(2)]),
        cancel_run: fn run ->
          send(test_pid, {:mismatch_cancelled, run})
          :ok
        end
      )

    {first_id, first_session} = start_one(manager)
    clear_change(manager, first_id)

    result = agent_result(first_id, "final text")
    prepare_success(manager, first_id)
    clear_change(manager, first_id)

    assert :ok =
             RunManager.record_event(
               manager,
               event(:run_completed, run_id: first_id, result: result)
             )

    assert {:error, :closed} =
             RunManager.record_event(
               manager,
               event(:run_completed, run_id: first_id, result: result)
             )

    pending = run(manager, first_id)
    assert pending.pending_terminal.status == :completed
    assert pending.last_seq == 3
    assert pending.terminal == nil
    refute_receive {:synapse_run_changed, ^first_id}
    assert {:error, :run_busy} = RunManager.start_run(manager, start_command(config(manager)))

    assert :ok =
             session_call(first_session, fn ->
               RunManager.settle(manager, first_id, {:ok, result})
             end)

    assert_receive {:synapse_run_changed, ^first_id}

    terminal = run(manager, first_id)
    assert terminal.status == :completed
    assert terminal.terminal.status == :completed
    assert terminal.last_seq == 4
    assert terminal.projection.text == "final text"
    assert terminal.projection.provider_attempts == 1
    assert API.RunRecord.valid?(terminal, config(manager))

    assert {:error, :closed} =
             RunManager.record_event(
               manager,
               event(:run_completed, run_id: first_id, result: result)
             )

    assert run(manager, first_id).last_seq == 4

    replay_subscriber = spawn(fn -> subscriber_loop(self()) end)

    assert {:ok, %{mode: :replay}} =
             subscriber_call(replay_subscriber, fn ->
               RunManager.subscribe(manager, first_id, 3)
             end)

    assert {:ok, %{messages: [terminal_frame], cursor: 4, more?: false}} =
             subscriber_call(replay_subscriber, fn -> RunManager.pull(manager, first_id, 3) end)

    assert decode(terminal_frame)["type"] == "run.terminal"

    assert {:ok, %{mode: :replay}} =
             subscriber_call(replay_subscriber, fn ->
               RunManager.subscribe(manager, first_id, 4)
             end)

    assert {:ok, %{messages: [], cursor: 4, more?: false}} =
             subscriber_call(replay_subscriber, fn -> RunManager.pull(manager, first_id, 4) end)

    send(replay_subscriber, :stop)

    {second_id, second_session} = start_one(manager)
    handle = runtime_run(second_id, second_session)

    assert :ok =
             session_call(second_session, fn ->
               RunManager.register_runtime_run(manager, second_id, handle)
             end)

    result = agent_result(second_id, "expected")
    prepare_success(manager, second_id)

    assert :ok =
             RunManager.record_event(
               manager,
               event(:run_completed, run_id: second_id, result: result)
             )

    mismatch = agent_result(second_id, "different")

    assert :ok =
             session_call(second_session, fn ->
               RunManager.settle(manager, second_id, {:ok, mismatch})
             end)

    assert_receive {:mismatch_cancelled, ^handle}
    second = run(manager, second_id)
    assert second.status == :interrupted
    assert second.terminal.error.reason == :internal_contract_failed
    assert :queue.len(second.replay) == 4

    assert {:error, :closed} =
             session_call(second_session, fn ->
               RunManager.settle(manager, second_id, {:ok, mismatch})
             end)

    assert run(manager, second_id).last_seq == second.last_seq
  end

  test "cross-run Runtime errors become one API contract terminal instead of stranding reservation" do
    {:ok, manager} = start_manager()
    {run_id, session} = start_one(manager)
    {:ok, wrong_error} = RuntimeError.new(reason: :runtime_lost, run_id: other_run_id())

    assert :ok =
             session_call(session, fn ->
               RunManager.settle(manager, run_id, {:error, wrong_error})
             end)

    record = run(manager, run_id)
    assert record.status == :interrupted
    assert record.terminal.error.reason == :internal_contract_failed
    assert :sys.get_state(manager).active_run_id == nil
  end

  test "cleanup-gated failure may override a completed turn outcome" do
    {:ok, manager} = start_manager()
    {run_id, session} = start_one(manager)
    prepare_success(manager, run_id)
    error = agent_error(run_id, :internal, :workspace_close_failed)

    assert :ok =
             RunManager.record_event(manager, event(:run_failed, run_id: run_id, error: error))

    assert :ok =
             session_call(session, fn -> RunManager.settle(manager, run_id, {:error, error}) end)

    assert run(manager, run_id).status == :failed
    assert run(manager, run_id).terminal.error.reason == :workspace_close_failed
  end

  test "closed-turn and active-Tool ordering contradictions are rejected" do
    {:ok, manager} = start_manager()
    {run_id, _session} = start_one(manager)
    prepare_success(manager, run_id)

    assert {:error, :closed} =
             RunManager.record_event(
               manager,
               event(:turn_started, run_id: run_id, turn: 2, operation_id: "provider-op-2")
             )

    assert Process.alive?(manager)

    {:ok, other_manager} = start_manager()
    {other_id, _other_session} = start_one(other_manager)

    assert :ok =
             RunManager.record_event(
               other_manager,
               event(:run_started, run_id: other_id, model: "model-a")
             )

    assert :ok =
             RunManager.record_event(
               other_manager,
               event(:turn_started,
                 run_id: other_id,
                 turn: 1,
                 operation_id: "provider-op"
               )
             )

    assert :ok =
             RunManager.record_event(
               other_manager,
               event(:tool_started, tool_attrs(other_id, 1))
             )

    assert {:error, :closed} =
             RunManager.record_event(
               other_manager,
               event(:text_delta,
                 run_id: other_id,
                 turn: 1,
                 operation_id: "provider-op",
                 item_id: "item-1",
                 content_index: 0,
                 delta: "invalid while tool active"
               )
             )
  end

  test "malformed struct-shaped events are sink rejection, not Manager crashes" do
    {:ok, manager} = start_manager()
    {run_id, _session} = start_one(manager)
    started = event(:run_started, run_id: run_id, model: "model-a")
    malformed = Map.delete(started, :model)

    assert {:error, :closed} = RunManager.record_event(manager, malformed)
    assert Process.alive?(manager)
    assert run(manager, run_id).sink_rejected
  end

  test "valid projected events rejected by Wire policy cancel and settle event_sink_failed" do
    test_pid = self()
    {:ok, tool_limits} = Synapse.Tool.Limits.new(max_operation_id_bytes: 85)
    {:ok, runtime_options} = Synapse.Runtime.Options.new(tool_limits: tool_limits)

    {:ok, config} =
      Config.new(
        enabled: true,
        launch_cwd: "/synthetic/api-run-manager-launch",
        default_model: "model-a",
        runtime_options: runtime_options
      )

    {:ok, manager} =
      start_manager(
        config: config,
        cancel_run: fn run ->
          send(test_pid, {:encoder_cancelled, run})
          :ok
        end
      )

    {run_id, session} = start_one(manager)
    handle = runtime_run(run_id, session)

    assert :ok =
             session_call(session, fn ->
               RunManager.register_runtime_run(manager, run_id, handle)
             end)

    assert :ok =
             RunManager.record_event(
               manager,
               event(:run_started, run_id: run_id, model: "model-a")
             )

    before = run(manager, run_id)
    operation_id = String.duplicate("o", 86)

    assert {:error, :closed} =
             RunManager.record_event(
               manager,
               event(:turn_started, run_id: run_id, turn: 1, operation_id: operation_id)
             )

    assert_receive {:encoder_cancelled, ^handle}
    rejected = run(manager, run_id)
    assert rejected.last_seq == before.last_seq
    assert rejected.replay == before.replay
    assert %{rejected.projection | status: before.projection.status} == before.projection
    assert rejected.sink_rejected
    assert rejected.cancel_requested
    error = agent_error(run_id, :internal, :event_sink_failed)

    assert :ok =
             session_call(session, fn -> RunManager.settle(manager, run_id, {:error, error}) end)

    assert run(manager, run_id).terminal.error.reason == :event_sink_failed
  end

  test "Runtime failures settle directly and session DOWN preserves owner-loss honesty" do
    {:ok, manager} = start_manager(id_generator: id_generator([run_id(1), run_id(2)]))
    {first_id, first_session} = start_one(manager)
    {:ok, runtime_error} = RuntimeError.new(reason: :workspace_open_failed, run_id: first_id)

    assert :ok =
             session_call(first_session, fn ->
               RunManager.settle(manager, first_id, {:error, runtime_error})
             end)

    assert run(manager, first_id).status == :failed

    {second_id, second_session} = start_one(manager)
    clear_change(manager, second_id)
    Process.exit(second_session, :kill)
    assert_receive {:synapse_run_changed, ^second_id}

    owner_lost = run(manager, second_id)
    assert owner_lost.status == :owner_lost
    assert owner_lost.terminal == nil
    assert :sys.get_state(manager).active_run_id == second_id
    assert {:error, :run_busy} = RunManager.start_run(manager, start_command(config(manager)))

    error = agent_error(second_id, :internal, :run_worker_crashed)

    assert :ok =
             RunManager.record_event(
               manager,
               event(:run_failed, run_id: second_id, error: error)
             )

    completed = run(manager, second_id)
    assert completed.status == :failed
    assert completed.last_seq == owner_lost.last_seq + 1
    assert :sys.get_state(manager).active_run_id == nil
  end

  test "session DOWN exposes a cleanup-gated pending terminal without owner-loss progress" do
    {:ok, manager} = start_manager()
    {run_id, session} = start_one(manager)
    clear_change(manager, run_id)
    error = agent_error(run_id, :internal, :run_worker_crashed)

    assert :ok =
             RunManager.record_event(manager, event(:run_failed, run_id: run_id, error: error))

    assert run(manager, run_id).last_seq == 0
    refute_receive {:synapse_run_changed, ^run_id}

    Process.exit(session, :kill)
    assert_receive {:synapse_run_changed, ^run_id}, 5_000

    record = run(manager, run_id)
    assert record.status == :failed
    assert record.last_seq == 1
    assert record.terminal.error == error
    assert record.replay |> :queue.to_list() |> Enum.map(& &1.type) == [:terminal]
  end

  test "sink rejection permits cleanup-gated event_sink_failed settlement" do
    {:ok, manager} = start_manager()
    {run_id, session} = start_one(manager)

    invalid_delta =
      event(:text_delta,
        run_id: run_id,
        turn: 1,
        operation_id: "provider-op",
        item_id: "item-1",
        content_index: 0,
        delta: "out of order"
      )

    assert {:error, :closed} = RunManager.record_event(manager, invalid_delta)
    assert run(manager, run_id).sink_rejected
    error = agent_error(run_id, :internal, :event_sink_failed)

    assert :ok =
             session_call(session, fn -> RunManager.settle(manager, run_id, {:error, error}) end)

    record = run(manager, run_id)
    assert record.status == :failed
    assert record.terminal.error.reason == :event_sink_failed
  end

  test "subscribe, stale reset, bounded pull, and notifications share one cursor" do
    {:ok, config} =
      Config.new(
        enabled: true,
        launch_cwd: "/synthetic/api-run-manager-launch",
        default_model: "model-a",
        max_replay_events: 2
      )

    {:ok, manager} = start_manager(config: config)
    memory_before = manager_memory(manager)
    {run_id, _session} = start_one(manager)

    assert :ok =
             RunManager.record_event(
               manager,
               event(:run_started, run_id: run_id, model: "model-a")
             )

    assert :ok =
             RunManager.record_event(
               manager,
               event(:turn_started, run_id: run_id, turn: 1, operation_id: "provider-op")
             )

    assert :ok =
             RunManager.record_event(
               manager,
               event(:text_delta,
                 run_id: run_id,
                 turn: 1,
                 operation_id: "provider-op",
                 item_id: "item-1",
                 content_index: 0,
                 delta: "x"
               )
             )

    assert_receive {:synapse_run_changed, ^run_id}
    refute_receive {:synapse_run_changed, ^run_id}

    assert {:reset, reset} = RunManager.pull(manager, run_id, 0)
    assert reset.mode == :snapshot
    assert reset.reset
    assert reset.first_available_seq == 2
    assert reset.last_seq == 3

    assert {:ok, %{messages: [], cursor: 3, more?: false}} = RunManager.pull(manager, run_id, 3)

    assert :ok =
             RunManager.record_event(
               manager,
               event(:text_delta,
                 run_id: run_id,
                 turn: 1,
                 operation_id: "provider-op",
                 item_id: "item-1",
                 content_index: 0,
                 delta: "y"
               )
             )

    assert_receive {:synapse_run_changed, ^run_id}

    assert {:ok, %{messages: [message], cursor: 4, more?: false}} =
             RunManager.pull(manager, run_id, 3)

    assert decode(message)["payload"]["seq"] == 4

    subscriber = spawn(fn -> subscriber_loop(self()) end)

    assert {:ok, replay} =
             subscriber_call(subscriber, fn -> RunManager.subscribe(manager, run_id, 3) end)

    assert replay.mode == :replay
    assert replay.reset == false

    assert {:error, :invalid_cursor} =
             subscriber_call(subscriber, fn -> RunManager.subscribe(manager, run_id, 5) end)

    send(subscriber, :stop)
    assert_memory_bounded(memory_before, manager_memory(manager), config)
  end

  test "pull count boundary advances one contiguous batch at a time" do
    {:ok, config} =
      Config.new(
        enabled: true,
        launch_cwd: "/synthetic/api-run-manager-launch",
        default_model: "model-a",
        max_pull_events: 1
      )

    {:ok, manager} = start_manager(config: config)
    {run_id, _session} = start_one(manager)

    assert :ok =
             RunManager.record_event(
               manager,
               event(:run_started, run_id: run_id, model: "model-a")
             )

    assert :ok =
             RunManager.record_event(
               manager,
               event(:turn_started, run_id: run_id, turn: 1, operation_id: "provider-op")
             )

    assert {:ok, %{messages: [first], cursor: 1, more?: true}} =
             RunManager.pull(manager, run_id, 0)

    assert decode(first)["payload"]["seq"] == 1

    assert {:ok, %{messages: [second], cursor: 2, more?: false}} =
             RunManager.pull(manager, run_id, 1)

    assert decode(second)["payload"]["seq"] == 2
  end

  test "projection text stops growing at its retention ceiling without stopping the run" do
    {:ok, manager} = start_manager()
    {run_id, _session} = start_one(manager)
    config = config(manager)

    assert :ok =
             RunManager.record_event(
               manager,
               event(:run_started, run_id: run_id, model: "model-a")
             )

    assert :ok =
             RunManager.record_event(
               manager,
               event(:turn_started, run_id: run_id, turn: 1, operation_id: "provider-op")
             )

    chunks =
      List.duplicate(String.duplicate("x", 64_000), 8) ++
        [String.duplicate("x", config.max_projection_text_bytes - 8 * 64_000)]

    chunks
    |> Enum.with_index()
    |> Enum.each(fn {delta, index} ->
      assert :ok =
               RunManager.record_event(
                 manager,
                 event(:text_delta,
                   run_id: run_id,
                   turn: 1,
                   operation_id: "provider-op",
                   item_id: "item-#{index}",
                   content_index: index,
                   delta: delta
                 )
               )
    end)

    before = run(manager, run_id)
    assert byte_size(before.projection.text) == config.max_projection_text_bytes

    assert :ok =
             RunManager.record_event(
               manager,
               event(:text_delta,
                 run_id: run_id,
                 turn: 1,
                 operation_id: "provider-op",
                 item_id: "item-2",
                 content_index: 1,
                 delta: "y"
               )
             )

    after_limit = run(manager, run_id)
    assert after_limit.projection.text == before.projection.text
    assert after_limit.last_seq == before.last_seq + 1
    refute after_limit.sink_rejected
  end

  test "maximum successful Result remains accounted and crosses a snapshot wire once" do
    {:ok, manager} = start_manager()
    {run_id, session} = start_one(manager)
    config = config(manager)
    text = String.duplicate("x", config.budget.max_output_bytes)

    complete_run(manager, run_id, session, text)

    record = run(manager, run_id)
    assert record.projection.text == text
    assert record.terminal.result.text == text
    assert record.accounted_bytes <= config.max_active_state_bytes
    assert :sys.get_state(manager).aggregate_bytes == record.accounted_bytes

    assert {:ok, snapshot} = RunManager.subscribe(manager, run_id, nil)
    assert {:ok, encoded} = API.Wire.snapshot("request-maximum", snapshot, config)
    decoded = decode(encoded)
    assert decoded["payload"]["projection"]["text"] == ""
    assert decoded["payload"]["terminal"]["result"]["text"] == text
    assert IO.iodata_length(encoded) <= config.max_outgoing_message_bytes
  end

  test "completed count eviction is oldest-first and run-ID collisions retry" do
    ids = [run_id(1), run_id(1), run_id(2)]

    {:ok, config} =
      Config.new(
        enabled: true,
        launch_cwd: "/synthetic/api-run-manager-launch",
        default_model: "model-a",
        max_completed_runs: 1
      )

    {:ok, manager} = start_manager(config: config, id_generator: id_generator(ids))
    memory_before = manager_memory(manager)
    {first_id, first_session} = start_one(manager)
    complete_run(manager, first_id, first_session, "first")

    {second_id, second_session} = start_one(manager)
    assert second_id == run_id(2)
    complete_run(manager, second_id, second_session, "second")

    state = :sys.get_state(manager)
    refute Map.has_key?(state.runs, first_id)
    assert Map.has_key?(state.runs, second_id)
    assert {:error, :run_not_found} = RunManager.subscribe(manager, first_id, nil)
    assert_memory_bounded(memory_before, manager_memory(manager), config)
  end

  test "one socket cannot retain more than sixteen run subscriptions" do
    ids = Enum.map(1..17, &run_id/1)
    {:ok, budget} = Budget.new(max_output_bytes: 1)

    {:ok, config} =
      Config.new(
        enabled: true,
        launch_cwd: "/synthetic/api-run-manager-launch",
        default_model: "model-a",
        budget: budget,
        max_projection_text_bytes: 1,
        max_outgoing_message_bytes: 140_000,
        max_pull_bytes: 140_000,
        max_replay_bytes: 140_064,
        max_active_state_bytes: 300_000
      )

    {:ok, manager} = start_manager(config: config, id_generator: id_generator(ids))

    Enum.each(1..16, fn _ordinal ->
      {run_id, session} = start_one(manager)
      complete_run(manager, run_id, session, "x")
    end)

    assert subscription_count_for(:sys.get_state(manager), self()) == 16

    assert {:error, :subscription_limit} =
             RunManager.start_run(manager, start_command(config(manager)))

    assert :sys.get_state(manager).active_run_id == nil
  end

  test "aggregate accounting evicts completed state before reserving a new active run" do
    {:ok, budget} = Budget.new(max_output_bytes: 1)

    {:ok, config} =
      Config.new(
        enabled: true,
        launch_cwd: "/synthetic/api-run-manager-launch",
        default_model: "model-a",
        budget: budget,
        max_projection_text_bytes: 1,
        max_outgoing_message_bytes: 140_000,
        max_pull_bytes: 140_000,
        max_replay_bytes: 140_064,
        max_active_state_bytes: 300_000,
        max_aggregate_state_bytes: 300_000
      )

    {:ok, manager} =
      start_manager(config: config, id_generator: id_generator([run_id(1), run_id(2)]))

    memory_before = manager_memory(manager)

    {first_id, first_session} = start_one(manager)

    replay_sized_events(first_id, config, 100)
    |> Enum.each(fn event -> assert :ok = RunManager.record_event(manager, event) end)

    assert run(manager, first_id).replay_bytes > 120_000
    complete_run(manager, first_id, first_session, "f")
    assert Map.has_key?(:sys.get_state(manager).runs, first_id)

    {second_id, _second_session} = start_one(manager)
    state = :sys.get_state(manager)
    refute Map.has_key?(state.runs, first_id)
    assert state.active_run_id == second_id
    assert state.aggregate_bytes <= config.max_aggregate_state_bytes
    assert_memory_bounded(memory_before, manager_memory(manager), config)
  end

  test "replay byte equality is retained and one additional event evicts the minimum prefix" do
    {:ok, budget} = Budget.new(max_output_bytes: 1)

    attrs = [
      enabled: true,
      launch_cwd: "/synthetic/api-run-manager-launch",
      default_model: "model-a",
      budget: budget,
      max_projection_text_bytes: 1,
      max_outgoing_message_bytes: 140_000,
      max_pull_bytes: 140_000
    ]

    {:ok, roomy} = Config.new(attrs)
    run_id = run_id(0)
    events = replay_sized_events(run_id, roomy, 200)
    accounted = replay_accounted_sizes(events, run_id, roomy)
    minimum = roomy.max_outgoing_message_bytes + Config.replay_entry_overhead_bytes()

    {prefix_count, exact_bytes} =
      accounted
      |> Enum.with_index(1)
      |> Enum.reduce_while(0, fn {bytes, index}, total ->
        total = total + bytes
        if total >= minimum, do: {:halt, {index, total}}, else: {:cont, total}
      end)

    assert exact_bytes <= roomy.max_replay_bytes

    {:ok, exact_config} = Config.new(Keyword.put(attrs, :max_replay_bytes, exact_bytes))
    {:ok, manager} = start_manager(config: exact_config)
    memory_before = manager_memory(manager)
    {^run_id, _session} = start_one(manager)

    events
    |> Enum.take(prefix_count)
    |> Enum.each(fn event -> assert :ok = RunManager.record_event(manager, event) end)

    exact_record = run(manager, run_id)
    assert exact_record.replay_bytes == exact_config.max_replay_bytes
    assert :queue.peek(exact_record.replay) |> elem(1) |> Map.fetch!(:seq) == 1

    assert :ok = RunManager.record_event(manager, Enum.at(events, prefix_count))
    evicted = run(manager, run_id)
    assert evicted.replay_bytes <= exact_config.max_replay_bytes
    assert :queue.peek(evicted.replay) |> elem(1) |> Map.fetch!(:seq) > 1
    assert evicted.last_seq == prefix_count + 1

    assert Enum.map(:queue.to_list(evicted.replay), & &1.seq) ==
             Enum.to_list((evicted.last_seq - :queue.len(evicted.replay) + 1)..evicted.last_seq)

    assert evicted.replay_bytes ==
             Enum.sum(Enum.map(:queue.to_list(evicted.replay), & &1.accounted_bytes))

    assert_memory_bounded(memory_before, manager_memory(manager), exact_config)
  end

  test "subscriber DOWN removes only observer state and never cancels the run" do
    test_pid = self()

    cancel_run = fn _run ->
      send(test_pid, :unexpected_cancel)
      :ok
    end

    {:ok, manager} = start_manager(cancel_run: cancel_run)
    {run_id, _session} = start_one(manager)

    subscriber =
      spawn(fn ->
        send(test_pid, {:subscribed, RunManager.subscribe(manager, run_id, 0)})

        receive do
          :stop -> :ok
        after
          10_000 -> exit(:subscriber_stop_timeout)
        end
      end)

    assert_receive {:subscribed, {:ok, _snapshot}}
    assert map_size(run(manager, run_id).subscribers) == 2
    :erlang.trace(manager, true, [:receive])
    send(subscriber, :stop)
    assert_receive {:trace, ^manager, :receive, {:DOWN, _monitor, :process, ^subscriber, :normal}}
    :erlang.trace(manager, false, [:receive])
    assert map_size(run(manager, run_id).subscribers) == 1
    assert :sys.get_state(manager).active_run_id == run_id
    refute_receive :unexpected_cancel
  end

  test "session DOWN after handle registration delegates cancellation" do
    test_pid = self()

    cancel_run = fn run ->
      send(test_pid, {:session_down_cancel, run})
      :ok
    end

    {:ok, manager} = start_manager(cancel_run: cancel_run)
    {run_id, session} = start_one(manager)
    handle = runtime_run(run_id, session)

    assert :ok =
             session_call(session, fn ->
               RunManager.register_runtime_run(manager, run_id, handle)
             end)

    clear_change(manager, run_id)
    Process.exit(session, :kill)
    assert_receive {:session_down_cancel, ^handle}
    assert_receive {:synapse_run_changed, ^run_id}
    assert run(manager, run_id).status == :owner_lost
  end

  test "ordered cleanup progress remains acceptable after owner loss" do
    {:ok, manager} = start_manager()
    {run_id, session} = start_one(manager)

    assert :ok =
             RunManager.record_event(
               manager,
               event(:run_started, run_id: run_id, model: "model-a")
             )

    assert :ok =
             RunManager.record_event(
               manager,
               event(:turn_started, run_id: run_id, turn: 1, operation_id: "provider-op")
             )

    assert :ok = RunManager.record_event(manager, event(:tool_started, tool_attrs(run_id, 1)))
    clear_change(manager, run_id)
    Process.exit(session, :kill)
    assert_receive {:synapse_run_changed, ^run_id}
    assert run(manager, run_id).status == :owner_lost
    assert run(manager, run_id).owner_lost_tool.call_id == "call-1"

    assert :ok =
             RunManager.record_event(
               manager,
               event(
                 :tool_completed,
                 Map.merge(tool_attrs(run_id, 1), %{status: :error, metadata: %{}})
               )
             )

    assert run(manager, run_id).owner_lost_tool == nil

    assert :ok =
             RunManager.record_event(
               manager,
               event(:turn_completed,
                 run_id: run_id,
                 turn: 1,
                 outcome: :failed,
                 provider_attempts: 1,
                 tool_calls: 1,
                 output_bytes: 0
               )
             )

    assert run(manager, run_id).status == :owner_lost
    error = agent_error(run_id, :tool, :tool_ambiguous)

    assert :ok =
             RunManager.record_event(manager, event(:run_failed, run_id: run_id, error: error))

    assert run(manager, run_id).status == :failed
  end

  test "128 slow subscribers receive one outstanding notification each" do
    {:ok, manager} = start_manager()
    {run_id, _session} = start_one(manager)
    test_pid = self()

    subscribers =
      for _ordinal <- 1..127 do
        spawn(fn ->
          result = RunManager.subscribe(manager, run_id, 0)
          send(test_pid, {:subscribed, self(), result})
          subscriber_loop(test_pid)
        end)
      end

    Enum.each(subscribers, fn pid ->
      assert_receive {:subscribed, ^pid, {:ok, %{mode: :replay}}}, 5_000
    end)

    assert map_size(run(manager, run_id).subscribers) == 128

    overflow =
      spawn(fn ->
        send(test_pid, {:overflow, RunManager.subscribe(manager, run_id, 0)})
        subscriber_loop(test_pid)
      end)

    assert_receive {:overflow, {:error, :subscription_limit}}

    assert :ok =
             RunManager.record_event(
               manager,
               event(:run_started, run_id: run_id, model: "model-a")
             )

    assert_receive {:synapse_run_changed, ^run_id}

    for ordinal <- 1..20 do
      event =
        if ordinal == 1 do
          event(:turn_started, run_id: run_id, turn: 1, operation_id: "provider-op")
        else
          event(:text_delta,
            run_id: run_id,
            turn: 1,
            operation_id: "provider-op",
            item_id: "item-#{ordinal}",
            content_index: ordinal,
            delta: "x"
          )
        end

      assert :ok = RunManager.record_event(manager, event)
    end

    Enum.each(subscribers, fn pid ->
      assert {:messages, [{:synapse_run_changed, ^run_id}]} = Process.info(pid, :messages)
      send(pid, :stop)
    end)

    send(overflow, :stop)
  end

  test "sequence reserve leaves owner-loss and terminal slots without wrapping" do
    test_pid = self()

    {:ok, manager} =
      start_manager(
        cancel_run: fn run ->
          send(test_pid, {:sequence_cancelled, run})
          :ok
        end
      )

    {run_id, session} = start_one(manager)
    handle = runtime_run(run_id, session)

    assert :ok =
             session_call(session, fn ->
               RunManager.register_runtime_run(manager, run_id, handle)
             end)

    assert :ok =
             RunManager.record_event(
               manager,
               event(:run_started, run_id: run_id, model: "model-a")
             )

    assert :ok =
             RunManager.record_event(
               manager,
               event(:turn_started, run_id: run_id, turn: 1, operation_id: "provider-op")
             )

    clear_change(manager, run_id)
    socket = self()

    :sys.replace_state(manager, fn state ->
      record = Map.fetch!(state.runs, run_id)
      subscriber = Map.fetch!(record.subscribers, socket)

      record = %{
        record
        | last_seq: 9_223_372_036_854_775_805,
          replay: :queue.new(),
          replay_bytes: 0,
          subscribers: %{socket => %{subscriber | cursor: 9_223_372_036_854_775_805}}
      }

      %{state | runs: Map.put(state.runs, run_id, record)}
    end)

    delta =
      event(:text_delta,
        run_id: run_id,
        turn: 1,
        operation_id: "provider-op",
        item_id: "item-1",
        content_index: 0,
        delta: "x"
      )

    assert {:error, :closed} = RunManager.record_event(manager, delta)
    assert_receive {:sequence_cancelled, ^handle}
    assert run(manager, run_id).last_seq == 9_223_372_036_854_775_805
    clear_change(manager, run_id)
    Process.exit(session, :kill)
    assert_receive {:synapse_run_changed, ^run_id}
    assert run(manager, run_id).last_seq == 9_223_372_036_854_775_806

    error = agent_error(run_id, :internal, :run_worker_crashed)

    assert :ok =
             RunManager.record_event(manager, event(:run_failed, run_id: run_id, error: error))

    terminal = run(manager, run_id)
    assert terminal.last_seq == 9_223_372_036_854_775_807
    assert terminal.terminal.seq == 9_223_372_036_854_775_807
    assert {:error, :closed} = RunManager.record_event(manager, delta)
    assert run(manager, run_id).last_seq == 9_223_372_036_854_775_807
  end

  test "Manager inspection and status redact callbacks, terminal content, and authority" do
    secret = "SYNTHETIC_MANAGER_PHASE3_SECRET"
    test_pid = self()

    starter = fn manager, run_id, _command ->
      _captured_secret = secret
      session = spawn(fn -> session_loop() end)
      send(test_pid, {:secret_session, manager, run_id, session})
      {:ok, session}
    end

    {:ok, manager} = start_manager(session_starter: starter)
    assert {:ok, run_id} = RunManager.start_run(manager, start_command(config(manager)))
    assert_receive {:secret_session, ^manager, ^run_id, session}
    handle = runtime_run(run_id, session)

    assert :ok =
             session_call(session, fn ->
               RunManager.register_runtime_run(manager, run_id, handle)
             end)

    result = agent_result(run_id, secret)
    prepare_success(manager, run_id)

    assert :ok =
             RunManager.record_event(
               manager,
               event(:run_completed, run_id: run_id, result: result)
             )

    state = :sys.get_state(manager)

    refute inspect(state) =~ secret
    refute inspect(state) =~ inspect(state.session_starter)

    status = :sys.get_status(manager)
    refute inspect(status) =~ secret
    refute inspect(status) =~ "#Function<"
    refute inspect(status) =~ "Runtime.Run"
  end

  defp start_manager(options \\ []) do
    config = Keyword.get(options, :config, default_config())
    test_pid = self()

    default_starter = fn manager, run_id, _command ->
      session = spawn(fn -> session_loop() end)
      send(test_pid, {:session_started, manager, run_id, session})
      {:ok, session}
    end

    options =
      options
      |> Keyword.put_new(:config, config)
      |> Keyword.put_new(:name, nil)
      |> Keyword.put_new(:session_starter, default_starter)
      |> Keyword.put_new(:id_generator, id_generator([run_id(0)]))

    case RunManager.start_link(options) do
      {:ok, manager} = ok ->
        on_exit(fn -> stop_manager(manager) end)
        ok

      error ->
        error
    end
  end

  defp stop_manager(manager) do
    if Process.alive?(manager) do
      state = :sys.get_state(manager)

      state.runs
      |> Map.values()
      |> Enum.map(& &1.session_pid)
      |> Enum.reject(&is_nil/1)
      |> Enum.each(&send(&1, :stop))

      GenServer.stop(manager)
    end
  catch
    :exit, _reason -> :ok
  end

  defp start_one(manager) do
    assert {:ok, run_id} = RunManager.start_run(manager, start_command(config(manager)))
    assert_receive {:session_started, ^manager, ^run_id, session}
    {run_id, session}
  end

  defp config(manager), do: :sys.get_state(manager).config
  defp run(manager, run_id), do: :sys.get_state(manager).runs[run_id]

  defp subscription_count_for(state, pid),
    do: Enum.count(state.runs, fn {_run_id, record} -> Map.has_key?(record.subscribers, pid) end)

  defp default_config do
    {:ok, config} =
      Config.new(
        enabled: true,
        launch_cwd: "/synthetic/api-run-manager-launch",
        default_model: "model-a"
      )

    config
  end

  defp start_command(config) do
    {:ok, command} =
      API.Command.Start.new(
        %{prompt: "Inspect", cwd: "/tmp/project", model: "model-a", budget: config.budget},
        config
      )

    command
  end

  defp event(:tool_started, attrs) do
    {:ok, event} = Event.new(:tool_started, Map.put_new(Map.new(attrs), :arguments, %{}))
    event
  end

  defp event(:tool_completed, attrs) do
    {:ok, event} =
      Event.new(:tool_completed, Map.put_new(Map.new(attrs), :content, ~s({"status":"ok"})))

    event
  end

  defp event(kind, attrs) do
    {:ok, event} = Event.new(kind, attrs)
    event
  end

  defp tool_attrs(run_id, ordinal) do
    %{
      run_id: run_id,
      turn: 1,
      operation_id: "tool-op-#{ordinal}",
      call_id: "call-#{ordinal}",
      name: "read",
      ordinal: ordinal
    }
  end

  defp replay_sized_events(run_id, config, cycles) do
    limits = config.runtime_options.tool_limits
    operation_id = String.duplicate("o", limits.max_operation_id_bytes)
    call_id = String.duplicate("c", limits.max_call_id_bytes)
    name = String.duplicate("n", min(limits.max_tool_name_bytes, 64))

    progress = [
      event(:run_started, run_id: run_id, model: "model-a"),
      event(:turn_started, run_id: run_id, turn: 1, operation_id: "provider-op")
    ]

    tools =
      Enum.flat_map(1..cycles, fn ordinal ->
        attrs = %{
          run_id: run_id,
          turn: 1,
          operation_id: operation_id,
          call_id: call_id,
          name: name,
          ordinal: ordinal
        }

        [
          event(:tool_started, attrs),
          event(:tool_completed, Map.merge(attrs, %{status: :ok, metadata: %{}}))
        ]
      end)

    progress ++ tools
  end

  defp replay_accounted_sizes(events, run_id, config) do
    events
    |> Enum.with_index(1)
    |> Enum.map(fn {event, seq} ->
      {:ok, encoded} = API.Wire.event(run_id, seq, event, config)
      {:ok, entry} = API.ReplayEntry.new(%{seq: seq, type: :event, encoded: encoded}, config)
      entry.accounted_bytes
    end)
  end

  defp agent_result(run_id, text) do
    {:ok, response} =
      Provider.Response.new(id: "response-1", model: "model-a", output_items: [], usage: %{})

    {:ok, result} =
      Result.new(
        run_id: run_id,
        text: text,
        final_response: response,
        turns: 1,
        tool_calls: 0,
        provider_retries: 0,
        output_bytes: byte_size(text)
      )

    result
  end

  defp agent_error(run_id, kind, reason) do
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

    error
  end

  defp complete_run(manager, run_id, session, text) do
    result = agent_result(run_id, text)
    prepare_success(manager, run_id)

    assert :ok =
             RunManager.record_event(
               manager,
               event(:run_completed, run_id: run_id, result: result)
             )

    assert :ok =
             session_call(session, fn -> RunManager.settle(manager, run_id, {:ok, result}) end)

    :ok
  end

  defp prepare_success(manager, run_id) do
    record = run(manager, run_id)

    unless record.run_started do
      assert :ok =
               RunManager.record_event(
                 manager,
                 event(:run_started, run_id: run_id, model: "model-a")
               )
    end

    record = run(manager, run_id)

    if is_nil(record.open_turn) do
      turn = record.last_completed_turn + 1

      assert :ok =
               RunManager.record_event(
                 manager,
                 event(:turn_started,
                   run_id: run_id,
                   turn: turn,
                   operation_id: "provider-op-#{turn}"
                 )
               )
    end

    record = run(manager, run_id)

    assert :ok =
             RunManager.record_event(
               manager,
               event(:turn_completed,
                 run_id: run_id,
                 turn: record.open_turn,
                 outcome: :completed,
                 provider_attempts: 1,
                 tool_calls: 0,
                 output_bytes: 0
               )
             )

    :ok
  end

  defp runtime_run(run_id, owner) do
    cancellation = :atomics.new(1, signed: false)
    await_state = :atomics.new(1, signed: false)

    %Run{
      id: run_id,
      owner: owner,
      server: owner,
      task: owner,
      run_ref: make_ref(),
      cancel_ref: make_ref(),
      cancellation: cancellation,
      await_state: await_state
    }
  end

  defp session_call(session, function) do
    reference = make_ref()
    send(session, {:call, self(), reference, function})
    assert_receive {:session_reply, ^reference, result}, 5_000
    result
  end

  defp session_loop do
    receive do
      {:call, caller, reference, function} ->
        send(caller, {:session_reply, reference, function.()})
        session_loop()

      :stop ->
        :ok
    after
      10_000 -> exit(:session_loop_timeout)
    end
  end

  defp subscriber_call(subscriber, function) do
    reference = make_ref()
    send(subscriber, {:call, self(), reference, function})
    assert_receive {:subscriber_reply, ^reference, result}, 5_000
    result
  end

  defp subscriber_loop(_parent) do
    receive do
      {:call, caller, reference, function} ->
        send(caller, {:subscriber_reply, reference, function.()})
        subscriber_loop(caller)

      :stop ->
        :ok
    after
      10_000 -> exit(:subscriber_loop_timeout)
    end
  end

  defp clear_change(manager, run_id) do
    record = run(manager, run_id)
    cursor = record.subscribers[self()].cursor

    case RunManager.pull(manager, run_id, cursor) do
      {:ok, _pull} -> :ok
      {:reset, _snapshot} -> :ok
    end

    receive do
      {:synapse_run_changed, ^run_id} -> :ok
    after
      0 -> :ok
    end
  end

  defp manager_memory(manager) do
    true = :erlang.garbage_collect(manager)
    {:memory, memory} = Process.info(manager, :memory)
    {:binary, binaries} = Process.info(manager, :binary)
    {:message_queue_len, queue} = Process.info(manager, :message_queue_len)

    %{
      memory: memory,
      binary_bytes: Enum.sum(Enum.map(binaries, &elem(&1, 1))),
      message_queue_len: queue
    }
  end

  defp assert_memory_bounded(before, after_measurement, config) do
    allowance = config.max_aggregate_state_bytes * 2
    assert before.message_queue_len == 0
    assert after_measurement.message_queue_len == 0
    assert after_measurement.memory <= before.memory + allowance
    assert after_measurement.binary_bytes <= before.binary_bytes + allowance
  end

  defp decode(iodata) do
    {:ok, decoded} = iodata |> IO.iodata_to_binary() |> JSON.decode()
    decoded
  end

  defp id_generator(ids) do
    counter = :atomics.new(1, signed: false)
    values = List.to_tuple(ids)

    fn ->
      index = :atomics.add_get(counter, 1, 1)
      elem(values, min(index, tuple_size(values)) - 1)
    end
  end

  defp run_id(value), do: "run_" <> Base.url_encode64(<<value::128>>, padding: false)
  defp other_run_id, do: run_id(9_999)
end
