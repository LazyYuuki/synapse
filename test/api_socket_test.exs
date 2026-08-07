defmodule Synapse.API.SocketTest do
  use ExUnit.Case, async: false

  defmodule ReplyManager do
    use GenServer

    def start_link(owner, reply), do: GenServer.start_link(__MODULE__, {owner, reply})

    @impl true
    def init({owner, reply}), do: {:ok, %{owner: owner, reply: reply}}

    @impl true
    def handle_call(message, _from, state) do
      send(state.owner, {:manager_call, message})
      {:reply, state.reply.(message), state}
    end

    @impl true
    def handle_cast(message, state) do
      send(state.owner, {:manager_cast, message})
      {:noreply, state}
    end
  end

  defmodule RuntimeProvider do
    @behaviour Synapse.Provider

    @impl true
    def stream(request, _event_sink, _context) do
      test = Process.whereis(:synapse_phase5_socket_runtime_test)
      send(test, {:real_provider_waiting, self(), request})

      receive do
        {:release_provider, response} -> {:ok, response}
      after
        10_000 -> exit(:provider_release_timeout)
      end
    end
  end

  import ExUnit.CaptureLog

  alias Synapse.Agent.Result
  alias Synapse.API.{Config, Policy, RunManager, Socket}
  alias Synapse.API.RunSession
  alias Synapse.API.RunSession.RuntimeBoundary
  alias Synapse.API.Socket.{Arguments, State}
  alias Synapse.Provider
  alias Synapse.Provider.OutputItem.Message, as: ProviderMessage
  alias Synapse.Run.Event
  alias Synapse.Runtime.Run

  @continue_pull :synapse_socket_continue_pull

  test "init pushes the exact hello first and retains only authority-free policy" do
    secret = "SOCKET_AUTHORITY_SECRET"

    {:ok, runtime_options} =
      Synapse.Runtime.Options.new(
        provider: Synapse.Provider.Fake,
        instructions: secret,
        retry_delay: fn _ordinal -> byte_size(secret) end,
        workspace_opener: fn _request -> {:error, secret} end
      )

    config = config(runtime_options: runtime_options)
    harness = start_manager(config)
    {:ok, arguments} = Socket.arguments(harness.manager, config)
    {:push, {:text, hello}, state} = Socket.init(arguments)

    assert decode(hello) == %{
             "version" => 1,
             "type" => "server.hello",
             "request_id" => nil,
             "payload" => %{
               "protocol" => 1,
               "replay" => "memory",
               "max_active_runs" => 1
             }
           }

    assert %Policy{} = state.policy
    refute Map.has_key?(Map.from_struct(state.policy), :capabilities)
    refute Map.has_key?(Map.from_struct(state.policy), :runtime_options)
    refute inspect(arguments) =~ secret
    refute inspect(state) =~ secret
    refute inspect(state) =~ inspect(harness.manager)
    assert state.cursors == %{}
    assert state.pending_pulls == []
    assert state.violations == 0
    assert {:stop, :normal, 1011, _state} = Socket.init(:invalid)

    assert {:stop, :normal, 1011, _state} =
             Socket.init(%Arguments{manager: harness.manager, policy: config})

    forged = %{state.policy | max_subscriptions_per_socket: 17}

    assert {:stop, :normal, 1011, _state} =
             Socket.init(%Arguments{manager: harness.manager, policy: forged})
  end

  test "ping supports request-ID reuse and control callbacks do not duplicate pong" do
    config = config()
    harness = start_manager(config)
    state = socket_state(harness.manager, config)
    ping = command("ping", "reuse", %{})

    assert {:push, {:text, first}, state} = Socket.handle_in({ping, opcode: :text}, state)
    assert {:push, {:text, second}, state} = Socket.handle_in({ping, opcode: :text}, state)
    assert decode(first) == decode(second)
    assert decode(first)["type"] == "pong"
    assert decode(first)["request_id"] == "reuse"
    assert decode(first)["payload"] == %{}
    assert {:ok, ^state} = Socket.handle_control({"network", opcode: :ping}, state)
    assert {:ok, ^state} = Socket.handle_control({"network", opcode: :pong}, state)
    assert {:ok, ^state} = Socket.handle_info(:unknown_message, state)
  end

  test "binary, oversized, malformed, unsupported, and repeated violations use exact policy closes" do
    config = config()
    harness = start_manager(config)
    state = socket_state(harness.manager, config)

    assert {:stop, :normal, 1003, ^state} =
             Socket.handle_in({<<0, 1, 2>>, opcode: :binary}, state)

    oversized = String.duplicate(" ", config.max_incoming_message_bytes + 1)
    assert {:stop, :normal, 1009, ^state} = Socket.handle_in({oversized, opcode: :text}, state)

    invalid = [
      "{",
      command("ping", "unsupported", %{}, version: 2),
      command("ping", "wrong-shape", %{"echo" => "x"})
    ]

    {state, codes} =
      Enum.reduce(invalid, {state, []}, fn message, {state, codes} ->
        assert {:push, {:text, encoded}, next} =
                 Socket.handle_in({message, opcode: :text}, state)

        {next, codes ++ [decode(encoded)["payload"]["code"]]}
      end)

    assert codes == ["invalid_json", "unsupported_version", "invalid_payload"]
    assert state.violations == 3

    assert {:push, {:text, _pong}, state} =
             Socket.handle_in({command("ping", "still-valid", %{}), opcode: :text}, state)

    state =
      Enum.reduce(4..8, state, fn _ordinal, state ->
        assert {:push, {:text, encoded}, next} = Socket.handle_in({"{", opcode: :text}, state)
        assert decode(encoded)["payload"]["code"] == "invalid_json"
        next
      end)

    assert state.violations == 8
    assert {:stop, :normal, 1008, closed} = Socket.handle_in({"{", opcode: :text}, state)
    assert closed.violations == 9
  end

  test "start and cancel route typed commands with exact request correlation" do
    config = config()
    harness = start_manager(config)
    state = socket_state(harness.manager, config)

    assert {:push, {:text, accepted}, state} =
             Socket.handle_in({start_command("start-1"), opcode: :text}, state)

    assert_receive {:session_started, session, run_id}

    assert decode(accepted) == %{
             "version" => 1,
             "type" => "run.accepted",
             "request_id" => "start-1",
             "payload" => %{"run_id" => run_id, "status" => "starting"}
           }

    assert state.cursors == %{run_id => 0}

    assert {:push, {:text, cancelled}, ^state} =
             Socket.handle_in(
               {command("run.cancel", "cancel-1", %{"run_id" => run_id}), opcode: :text},
               state
             )

    assert decode(cancelled)["request_id"] == "cancel-1"
    assert decode(cancelled)["type"] == "run.cancel_requested"

    assert decode(cancelled)["payload"] == %{
             "run_id" => run_id,
             "status" => "cancel_requested"
           }

    assert Process.alive?(session)
  end

  test "accepted response is observed before the first asynchronous run event" do
    config = config()
    harness = start_manager(config)
    state = socket_state(harness.manager, config)

    assert {:push, {:text, accepted}, state} =
             Socket.handle_in({start_command("ordered-start"), opcode: :text}, state)

    assert_receive {:session_started, _session, run_id}
    assert decode(accepted)["type"] == "run.accepted"
    assert :ok = RunManager.record_event(harness.manager, event(:run_started, run_id: run_id))
    assert_receive {:synapse_run_changed, ^run_id}

    assert {:push, [{:text, encoded_event}], state} =
             Socket.handle_info({:synapse_run_changed, run_id}, state)

    event_frame = decode(encoded_event)
    assert event_frame["request_id"] == nil
    assert event_frame["payload"]["seq"] == 1
    assert event_frame["payload"]["event"]["type"] == "run.started"
    assert state.cursors[run_id] == 1
  end

  test "subscribe pushes its direct snapshot before its queued acknowledgement pull" do
    config = config()
    harness = start_manager(config)
    state = socket_state(harness.manager, config)

    {:push, {:text, _accepted}, state} =
      Socket.handle_in({start_command("start-subscribe"), opcode: :text}, state)

    assert_receive {:session_started, _session, run_id}
    subscribe = command("run.subscribe", "subscribe-1", %{"run_id" => run_id, "after_seq" => 0})

    assert {:push, {:text, snapshot}, state} =
             Socket.handle_in({subscribe, opcode: :text}, state)

    assert decode(snapshot)["type"] == "run.snapshot"
    assert decode(snapshot)["request_id"] == "subscribe-1"
    assert decode(snapshot)["payload"]["mode"] == "replay"
    assert state.pending_pulls == [run_id]
    assert state.continuation_scheduled
    assert_receive @continue_pull
    assert {:ok, state} = Socket.handle_info(@continue_pull, state)
    assert state.pending_pulls == []
    refute state.continuation_scheduled
  end

  test "slow delivery advances one bounded batch and retains only one continuation" do
    config = config(max_pull_events: 1)
    harness = start_manager(config)
    state = socket_state(harness.manager, config)

    {:push, {:text, _accepted}, state} =
      Socket.handle_in({start_command("slow-start"), opcode: :text}, state)

    assert_receive {:session_started, _session, run_id}
    assert :ok = RunManager.record_event(harness.manager, event(:run_started, run_id: run_id))

    assert :ok =
             RunManager.record_event(
               harness.manager,
               event(:turn_started, run_id: run_id, turn: 1, operation_id: "provider-op")
             )

    assert :ok =
             RunManager.record_event(
               harness.manager,
               event(:text_delta,
                 run_id: run_id,
                 turn: 1,
                 operation_id: "provider-op",
                 item_id: "item-1",
                 content_index: 0,
                 delta: "one"
               )
             )

    assert_receive {:synapse_run_changed, ^run_id}

    assert {:push, [{:text, first}], state} =
             Socket.handle_info({:synapse_run_changed, run_id}, state)

    assert decode(first)["payload"]["seq"] == 1
    assert state.cursors[run_id] == 1
    assert state.pending_pulls == [run_id]
    assert_receive @continue_pull
    refute_received @continue_pull

    assert {:push, [{:text, second}], state} = Socket.handle_info(@continue_pull, state)
    assert decode(second)["payload"]["seq"] == 2
    assert_receive @continue_pull
    refute_received @continue_pull

    assert {:push, [{:text, third}], state} = Socket.handle_info(@continue_pull, state)
    assert decode(third)["payload"]["seq"] == 3
    assert state.cursors[run_id] == 3
    assert state.pending_pulls == []
    refute state.continuation_scheduled
    refute_received @continue_pull
  end

  test "a parked Socket process retains one Manager notification and one continuation" do
    config = config(max_pull_events: 1)
    harness = start_manager(config)
    test_pid = self()

    socket =
      spawn(fn ->
        state = socket_state(harness.manager, config)

        {:push, {:text, accepted}, state} =
          Socket.handle_in({start_command("mailbox-bound"), opcode: :text}, state)

        send(test_pid, {:mailbox_socket_ready, self(), accepted})

        receive do
          {:process_notification, run_id} ->
            receive do
              {:synapse_run_changed, ^run_id} = notification ->
                result = Socket.handle_info(notification, state)
                send(test_pid, {:mailbox_notification_processed, self(), result})
            after
              5_000 -> exit(:notification_timeout)
            end
        after
          5_000 -> exit(:control_timeout)
        end

        receive do
          :stop -> :ok
        after
          5_000 -> exit(:stop_timeout)
        end
      end)

    assert_receive {:mailbox_socket_ready, ^socket, accepted}, 5_000
    run_id = decode(accepted)["payload"]["run_id"]
    assert_receive {:session_started, _session, ^run_id}

    assert :ok = RunManager.record_event(harness.manager, event(:run_started, run_id: run_id))

    assert :ok =
             RunManager.record_event(
               harness.manager,
               event(:turn_started, run_id: run_id, turn: 1, operation_id: "provider-op")
             )

    assert :ok =
             RunManager.record_event(
               harness.manager,
               event(:text_delta,
                 run_id: run_id,
                 turn: 1,
                 operation_id: "provider-op",
                 item_id: "item-1",
                 content_index: 0,
                 delta: "x"
               )
             )

    assert Process.info(socket, :message_queue_len) == {:message_queue_len, 1}
    send(socket, {:process_notification, run_id})

    assert_receive {:mailbox_notification_processed, ^socket, {:push, [{:text, first}], state}},
                   5_000

    assert decode(first)["payload"]["seq"] == 1
    assert state.continuation_scheduled
    assert state.pending_pulls == [run_id]
    assert Process.info(socket, :messages) == {:messages, [@continue_pull]}
    send(socket, :stop)
  end

  test "a stale live cursor receives one authoritative asynchronous reset" do
    config = config(max_replay_events: 1)
    harness = start_manager(config)
    state = socket_state(harness.manager, config)

    {:push, {:text, _accepted}, state} =
      Socket.handle_in({start_command("stale-start"), opcode: :text}, state)

    assert_receive {:session_started, _session, run_id}
    assert :ok = RunManager.record_event(harness.manager, event(:run_started, run_id: run_id))

    assert :ok =
             RunManager.record_event(
               harness.manager,
               event(:turn_started, run_id: run_id, turn: 1, operation_id: "provider-op")
             )

    assert_receive {:synapse_run_changed, ^run_id}

    assert {:push, {:text, reset}, state} =
             Socket.handle_info({:synapse_run_changed, run_id}, state)

    decoded = decode(reset)
    assert decoded["type"] == "run.snapshot"
    assert decoded["request_id"] == nil
    assert decoded["payload"]["mode"] == "snapshot"
    assert decoded["payload"]["reset"]
    assert decoded["payload"]["last_seq"] == 2
    assert state.cursors[run_id] == 2
    refute state.continuation_scheduled
  end

  test "a completed authoritative snapshot carries terminal once and pulls no duplicate" do
    config = config()
    harness = start_manager(config)
    run_id = complete_run(harness, config, "complete snapshot")
    drain_changes()
    state = socket_state(harness.manager, config)

    subscribe = command("run.subscribe", "completed", %{"run_id" => run_id})

    assert {:push, {:text, snapshot}, state} =
             Socket.handle_in({subscribe, opcode: :text}, state)

    decoded = decode(snapshot)
    assert decoded["payload"]["mode"] == "snapshot"
    assert decoded["payload"]["terminal"]["status"] == "completed"
    assert state.cursors[run_id] == 2
    assert_receive @continue_pull
    assert {:ok, state} = Socket.handle_info(@continue_pull, state)
    refute state.continuation_scheduled
    refute_received @continue_pull
  end

  test "local subscription capacity rejects a seventeenth run before Manager admission" do
    config = config()
    harness = start_manager(config)
    state = socket_state(harness.manager, config)

    cursors = Map.new(1..16, fn ordinal -> {run_id(ordinal + 100), 0} end)
    state = %{state | cursors: cursors}
    assert State.valid?(state)

    assert {:push, {:text, encoded}, same} =
             Socket.handle_in({start_command("full"), opcode: :text}, state)

    assert same.cursors == cursors
    assert decode(encoded)["payload"]["code"] == "subscription_limit"
    assert :sys.get_state(harness.manager).active_run_id == nil
    refute_received {:session_started, _session, _run_id}
  end

  test "two retained runs keep isolated cursors under one fair continuation" do
    config = config(max_pull_events: 1)
    harness = start_manager(config)
    first = complete_run(harness, config, "first")
    second = complete_run(harness, config, "second")
    drain_changes()
    state = socket_state(harness.manager, config)

    assert {:push, {:text, first_snapshot}, state} =
             Socket.handle_in(
               {command("run.subscribe", "sub-a", %{"run_id" => first, "after_seq" => 0}),
                opcode: :text},
               state
             )

    assert {:push, {:text, second_snapshot}, state} =
             Socket.handle_in(
               {command("run.subscribe", "sub-b", %{"run_id" => second, "after_seq" => 1}),
                opcode: :text},
               state
             )

    assert decode(first_snapshot)["request_id"] == "sub-a"
    assert decode(second_snapshot)["request_id"] == "sub-b"
    assert state.cursors == %{first => 0, second => 1}
    assert state.pending_pulls == [first, second]
    assert_receive @continue_pull
    refute_received @continue_pull

    assert {:push, [{:text, first_event}], state} = Socket.handle_info(@continue_pull, state)
    assert decode(first_event)["payload"]["run_id"] == first
    assert decode(first_event)["payload"]["seq"] == 1
    assert state.cursors == %{first => 1, second => 1}
    assert state.pending_pulls == [second, first]
    assert_receive @continue_pull

    assert {:push, [{:text, second_terminal}], state} = Socket.handle_info(@continue_pull, state)
    assert decode(second_terminal)["payload"]["run_id"] == second
    assert decode(second_terminal)["payload"]["seq"] == 2
    assert state.cursors == %{first => 1, second => 2}
    assert state.pending_pulls == [first]
    assert state.continuation_scheduled
    assert_receive @continue_pull
    assert {:ok, ^state} = Socket.handle_info({:synapse_run_changed, run_id(999)}, state)
  end

  test "terminate and abrupt socket death unsubscribe without cancelling the active run" do
    config = config()
    test_pid = self()

    harness =
      start_manager(config,
        cancel_run: fn run ->
          send(test_pid, {:cancelled, run})
          :ok
        end
      )

    parent = self()

    socket =
      spawn(fn ->
        state = socket_state(harness.manager, config)

        {:push, {:text, _accepted}, state} =
          Socket.handle_in({start_command("disconnect"), opcode: :text}, state)

        send(parent, {:socket_ready, self(), state})

        receive do
          :stop -> Socket.terminate(:normal, state)
        after
          10_000 -> exit(:socket_stop_timeout)
        end
      end)

    assert_receive {:session_started, session, run_id}
    assert_receive {:socket_ready, ^socket, state}
    runtime_run = runtime_run(run_id, session)
    send(session, {:register, runtime_run, self()})
    assert_receive {:registered, :ok}
    assert Map.has_key?(run(harness.manager, run_id).subscribers, socket)

    observer =
      spawn(fn ->
        observer_state = socket_state(harness.manager, config)

        {:push, {:text, _snapshot}, observer_state} =
          Socket.handle_in(
            {command("run.subscribe", "observer", %{"run_id" => run_id, "after_seq" => 0}),
             opcode: :text},
            observer_state
          )

        send(parent, {:observer_ready, self()})

        receive do
          {:terminate, reason} ->
            send(parent, {:observer_terminated, Socket.terminate(reason, observer_state)})
        after
          10_000 -> exit(:observer_terminate_timeout)
        end
      end)

    assert_receive {:observer_ready, ^observer}
    assert Map.has_key?(run(harness.manager, run_id).subscribers, observer)
    observer_monitor = Process.monitor(observer)
    send(observer, {:terminate, :remote})
    assert_receive {:observer_terminated, :ok}
    assert_receive {:DOWN, ^observer_monitor, :process, ^observer, :normal}
    refute Map.has_key?(run(harness.manager, run_id).subscribers, observer)
    refute_received {:cancelled, ^runtime_run}

    :erlang.trace(harness.manager, true, [:receive])
    monitor = Process.monitor(socket)
    Process.exit(socket, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^socket, :killed}
    assert_receive {:trace, manager, :receive, {:DOWN, _ref, :process, ^socket, :killed}}
    assert manager == harness.manager
    refute Map.has_key?(run(harness.manager, run_id).subscribers, socket)
    assert :sys.get_state(harness.manager).active_run_id == run_id
    assert Process.alive?(session)
    refute_received {:cancelled, ^runtime_run}

    assert :ok = Socket.terminate(:remote, state)
    assert :ok = Socket.terminate(:shutdown, state)
    assert :ok = Socket.terminate(:timeout, state)
    assert :ok = Socket.terminate({:error, :synthetic}, state)
    refute_received {:cancelled, ^runtime_run}
  end

  test "real Runtime continues to settlement after its initiating socket dies" do
    Process.register(self(), :synapse_phase5_socket_runtime_test)
    test_pid = self()

    opener = fn open_request ->
      Synapse.Workspace.Fake.open([],
        owner: open_request.owner,
        limits: open_request.limits,
        access: open_request.access
      )
    end

    {:ok, runtime_options} =
      Synapse.Runtime.Options.new(provider: RuntimeProvider, workspace_opener: opener)

    config = config(runtime_options: runtime_options)
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one, max_children: 1)
    starter = RunSession.session_starter(supervisor, config, RuntimeBoundary.default())

    {:ok, manager} =
      RunManager.start_link(
        name: nil,
        config: config,
        session_starter: starter,
        cancel_run: fn runtime_run ->
          send(test_pid, {:unexpected_socket_cancel, runtime_run})
          Synapse.Runtime.cancel(runtime_run)
        end,
        id_generator: fn -> run_id(700) end
      )

    on_exit(fn ->
      try do
        DynamicSupervisor.which_children(supervisor)
        |> Enum.each(fn {_id, child, _type, _modules} -> Process.exit(child, :kill) end)

        Supervisor.stop(supervisor)
      catch
        :exit, _reason -> :ok
      end

      try do
        GenServer.stop(manager)
      catch
        :exit, _reason -> :ok
      end
    end)

    socket =
      spawn(fn ->
        state = socket_state(manager, config)
        result = Socket.handle_in({start_command("real-runtime"), opcode: :text}, state)
        send(test_pid, {:real_socket_accepted, self(), result})

        receive do
          :hold -> :ok
        after
          10_000 -> exit(:real_socket_hold_timeout)
        end
      end)

    assert_receive {:real_socket_accepted, ^socket, {:push, {:text, accepted}, _state}}, 5_000
    run_id = decode(accepted)["payload"]["run_id"]
    assert_receive {:real_provider_waiting, provider_task, request}, 5_000
    on_exit(fn -> Process.exit(provider_task, :kill) end)
    session = run(manager, run_id).session_pid
    _status = :sys.get_status(session, 5_000)
    assert %Run{} = run(manager, run_id).runtime_run

    :erlang.trace(manager, true, [:receive])
    socket_monitor = Process.monitor(socket)
    Process.exit(socket, :kill)
    assert_receive {:DOWN, ^socket_monitor, :process, ^socket, :killed}
    assert_receive {:trace, ^manager, :receive, {:DOWN, _ref, :process, ^socket, :killed}}
    refute_received {:unexpected_socket_cancel, _runtime_run}
    assert Process.alive?(session)

    {:ok, response} =
      Provider.Response.new(
        id: "phase5-response",
        model: request.model,
        output_items: [
          %ProviderMessage{id: "phase5-message", role: :assistant, content: "Still running"}
        ]
      )

    session_monitor = Process.monitor(session)
    send(provider_task, {:release_provider, response})
    assert_receive {:DOWN, ^session_monitor, :process, ^session, :normal}, 10_000
    assert run(manager, run_id).status == :completed
    assert run(manager, run_id).terminal.result.text == "Still running"
    refute_received {:unexpected_socket_cancel, _runtime_run}
  end

  test "malformed Manager replies close 1011 without forwarding or corrupting cursors" do
    config = config()
    {:ok, policy} = Policy.from_config(config)
    run_id = run_id(501)
    other_run_id = run_id(502)

    malformed = fn
      {:start_run, _command} ->
        {:unexpected, "MANAGER_START_SECRET"}

      {:cancel, _run_id} ->
        {:unexpected, "MANAGER_CANCEL_SECRET"}

      {:subscribe, _run_id, _cursor} ->
        {:ok,
         %{
           mode: :replay,
           reset: false,
           run_id: other_run_id,
           first_available_seq: 1,
           last_seq: 0,
           projection: nil,
           terminal: nil
         }}

      {:pull, _run_id, _cursor} ->
        {:ok, %{messages: [], cursor: 0, more?: true}}
    end

    {:ok, manager} = ReplyManager.start_link(self(), malformed)
    {:ok, arguments} = Socket.arguments(manager, config)
    {:push, {:text, _hello}, initial} = Socket.init(arguments)

    log =
      capture_log(fn ->
        assert {:stop, :normal, 1011, ^initial} =
                 Socket.handle_in({start_command("malformed-start"), opcode: :text}, initial)

        tracked = %{initial | cursors: %{run_id => 0}}

        assert {:stop, :normal, 1011, ^tracked} =
                 Socket.handle_in(
                   {command("run.cancel", "malformed-cancel", %{"run_id" => run_id}),
                    opcode: :text},
                   tracked
                 )

        assert {:stop, :normal, 1011, ^tracked} =
                 Socket.handle_in(
                   {command("run.subscribe", "cross-run", %{"run_id" => run_id}), opcode: :text},
                   tracked
                 )

        assert {:stop, :normal, 1011, ^tracked} =
                 Socket.handle_info({:synapse_run_changed, run_id}, tracked)
      end)

    refute log =~ "MANAGER_START_SECRET"
    refute log =~ "MANAGER_CANCEL_SECRET"
    assert %Policy{} = policy

    {:ok, invalid_window_manager} =
      ReplyManager.start_link(self(), fn
        {:subscribe, ^run_id, 0} ->
          {:ok,
           %{
             mode: :replay,
             reset: false,
             run_id: run_id,
             first_available_seq: "invalid",
             last_seq: 0,
             projection: nil,
             terminal: nil
           }}

        _message ->
          {:error, :internal_error}
      end)

    invalid_window_state = socket_state(invalid_window_manager, config)
    invalid_window_state = %{invalid_window_state | cursors: %{run_id => 0}}

    assert {:stop, :normal, 1011, ^invalid_window_state} =
             Socket.handle_in(
               {command("run.subscribe", "invalid-window", %{"run_id" => run_id, "after_seq" => 0}),
                opcode: :text},
               invalid_window_state
             )

    {:ok, struct_manager} =
      ReplyManager.start_link(self(), fn
        {:subscribe, ^run_id, 0} -> {:ok, policy}
        _message -> {:error, :internal_error}
      end)

    struct_state = socket_state(struct_manager, config)
    struct_state = %{struct_state | cursors: %{run_id => 0}}

    assert {:stop, :normal, 1011, ^struct_state} =
             Socket.handle_in(
               {command("run.subscribe", "struct-snapshot", %{
                  "run_id" => run_id,
                  "after_seq" => 0
                }), opcode: :text},
               struct_state
             )
  end

  test "pull validation rejects cursor jumps, wrong sequences, invalid text, and no-progress loops" do
    config = config()
    run_id = run_id(601)

    replies = [
      %{messages: [], cursor: 0, more?: true},
      %{messages: [], cursor: 1, more?: false},
      %{messages: ["not-json"], cursor: 1, more?: false},
      %{
        messages: [
          JSON.encode!(%{
            "version" => 1,
            "type" => "run.event",
            "request_id" => nil,
            "payload" => %{"run_id" => run_id, "seq" => 2, "event" => %{"type" => "x"}}
          })
        ],
        cursor: 1,
        more?: false
      },
      %{
        messages: [
          JSON.encode!(%{
            "version" => 1,
            "type" => "run.event",
            "request_id" => nil,
            "payload" => %{
              "run_id" => run_id,
              "seq" => 1,
              "event" => %{"type" => "run.started", "model" => "model-a", "secret" => "x"}
            }
          })
        ],
        cursor: 1,
        more?: false
      },
      %{
        messages: [
          JSON.encode!(%{
            "version" => 1,
            "type" => "run.terminal",
            "request_id" => nil,
            "payload" => %{
              "run_id" => run_id,
              "seq" => 1,
              "status" => "failed",
              "result" => nil,
              "error" => %{
                "source" => "runtime",
                "reason" => "runtime_lost",
                "message" => "forged prose"
              }
            }
          })
        ],
        cursor: 1,
        more?: false
      },
      %{messages: [<<255>>], cursor: 1, more?: false}
    ]

    Enum.each(replies, fn reply ->
      {:ok, manager} =
        ReplyManager.start_link(self(), fn
          {:pull, ^run_id, 0} -> {:ok, reply}
          _message -> {:error, :internal_error}
        end)

      {:ok, arguments} = Socket.arguments(manager, config)
      {:push, {:text, _hello}, state} = Socket.init(arguments)
      state = %{state | cursors: %{run_id => 0}}

      assert {:stop, :normal, 1011, ^state} =
               Socket.handle_info({:synapse_run_changed, run_id}, state)
    end)
  end

  test "malformed asynchronous reset mode closes without advancing the cursor" do
    config = config()
    run_id = run_id(602)

    snapshots = [
      %{
        mode: :replay,
        reset: false,
        run_id: run_id,
        first_available_seq: 1,
        last_seq: 0,
        projection: nil,
        terminal: nil
      },
      %{
        mode: :snapshot,
        reset: true,
        run_id: run_id,
        first_available_seq: 1,
        last_seq: 0,
        projection: Synapse.API.Projection.new(),
        terminal: nil
      }
    ]

    Enum.each(snapshots, fn snapshot ->
      {:ok, manager} =
        ReplyManager.start_link(self(), fn
          {:pull, ^run_id, 0} -> {:reset, snapshot}
          _message -> {:error, :internal_error}
        end)

      state = socket_state(manager, config)
      state = %{state | cursors: %{run_id => 0}}

      assert {:stop, :normal, 1011, ^state} =
               Socket.handle_info({:synapse_run_changed, run_id}, state)
    end)
  end

  test "termination uses bounded asynchronous unsubscribe" do
    config = config()
    {:ok, manager} = ReplyManager.start_link(self(), fn _message -> :unexpected_call end)
    state = socket_state(manager, config)
    assert :ok = Socket.terminate(:timeout, state)
    assert_receive {:manager_cast, {:unsubscribe_all, caller}}
    assert caller == self()
    refute_received {:manager_call, :unsubscribe_all}
  end

  test "inspection and callback failure paths do not disclose command or manager sentinels" do
    config = config()
    harness = start_manager(config)
    state = socket_state(harness.manager, config)
    secret = "SOCKET_PROMPT_AND_PATH_SECRET"
    message = start_command("secret", prompt: secret, cwd: "/tmp/#{secret}")

    log =
      capture_log(fn ->
        assert {:push, {:text, accepted}, next} =
                 Socket.handle_in({message, opcode: :text}, state)

        refute inspect(next) =~ secret
        refute inspect(next) =~ inspect(harness.manager)
        refute IO.iodata_to_binary(accepted) =~ secret
        assert {:stop, :normal, 1011, _state} = Socket.handle_in(:invalid, next)
      end)

    refute log =~ secret
    refute log =~ inspect(harness.manager)
  end

  defp start_manager(config, options \\ []) do
    test_pid = self()
    counter = :atomics.new(1, signed: false)

    starter = fn manager, run_id, _command ->
      session = spawn(fn -> session_loop(manager, run_id) end)
      send(test_pid, {:session_started, session, run_id})
      {:ok, session}
    end

    cancel_run = Keyword.get(options, :cancel_run, fn _run -> :ok end)

    {:ok, manager} =
      RunManager.start_link(
        name: nil,
        config: config,
        session_starter: starter,
        cancel_run: cancel_run,
        id_generator: fn -> run_id(:atomics.add_get(counter, 1, 1)) end
      )

    on_exit(fn -> stop_manager(manager) end)
    %{manager: manager}
  end

  defp stop_manager(manager) do
    if Process.alive?(manager) do
      :sys.get_state(manager).runs
      |> Map.values()
      |> Enum.each(fn record ->
        if is_pid(record.session_pid), do: Process.exit(record.session_pid, :kill)
      end)

      GenServer.stop(manager)
    end
  catch
    :exit, _reason -> :ok
  end

  defp session_loop(manager, run_id) do
    receive do
      {:register, runtime_run, caller} ->
        send(caller, {:registered, RunManager.register_runtime_run(manager, run_id, runtime_run)})
        session_loop(manager, run_id)

      {:settle, settlement, caller} ->
        send(caller, {:settled, RunManager.settle(manager, run_id, settlement)})

      :stop ->
        :ok
    after
      10_000 -> exit(:session_loop_timeout)
    end
  end

  defp complete_run(harness, _config, text) do
    {:ok, command} =
      Synapse.API.Command.Start.new(
        %{prompt: "Complete", cwd: "/tmp/project", model: "model-a", budget: config().budget},
        config()
      )

    assert {:ok, run_id} = RunManager.start_run(harness.manager, command)
    assert_receive {:session_started, session, ^run_id}
    result = agent_result(run_id, text)
    assert :ok = RunManager.record_event(harness.manager, event(:run_started, run_id: run_id))

    assert :ok =
             RunManager.record_event(
               harness.manager,
               event(:run_completed, run_id: run_id, result: result)
             )

    send(session, {:settle, {:ok, result}, self()})
    assert_receive {:settled, :ok}
    run_id
  end

  defp socket_state(manager, config) do
    {:ok, arguments} = Socket.arguments(manager, config)
    {:push, {:text, _hello}, state} = Socket.init(arguments)
    state
  end

  defp config(overrides \\ []) do
    attrs = Keyword.merge([enabled: true, default_model: "model-a"], overrides)
    {:ok, config} = Config.new(attrs)
    config
  end

  defp command(type, request_id, payload, options \\ []) do
    JSON.encode!(%{
      "version" => Keyword.get(options, :version, 1),
      "type" => type,
      "request_id" => request_id,
      "payload" => payload
    })
  end

  defp start_command(request_id, options \\ []) do
    command("run.start", request_id, %{
      "prompt" => Keyword.get(options, :prompt, "Inspect"),
      "cwd" => Keyword.get(options, :cwd, "/tmp/project")
    })
  end

  defp event(:run_started, attrs) do
    Event.new(:run_started, Keyword.put(attrs, :model, "model-a")) |> elem(1)
  end

  defp event(kind, attrs) do
    {:ok, event} = Event.new(kind, attrs)
    event
  end

  defp agent_result(run_id, text) do
    {:ok, response} =
      Provider.Response.new(id: "response", model: "model-a", output_items: [], usage: %{})

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

  defp runtime_run(run_id, owner) do
    %Run{
      id: run_id,
      owner: owner,
      server: owner,
      task: owner,
      run_ref: make_ref(),
      cancel_ref: make_ref(),
      cancellation: :atomics.new(1, signed: false),
      await_state: :atomics.new(1, signed: false)
    }
  end

  defp drain_changes do
    receive do
      {:synapse_run_changed, _run_id} -> drain_changes()
    after
      0 -> :ok
    end
  end

  defp decode(encoded), do: encoded |> IO.iodata_to_binary() |> JSON.decode!()
  defp run(manager, run_id), do: :sys.get_state(manager).runs[run_id]
  defp run_id(value), do: "run_" <> Base.url_encode64(<<value::128>>, padding: false)
end
