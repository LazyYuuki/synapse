defmodule Synapse.API.AcceptanceTest.ControlledFake do
  @behaviour Synapse.Workspace.Backend

  alias Synapse.Workspace.{Fake, Handle}

  @impl true
  def workspace_backend?, do: true

  @impl true
  def valid_handle?(%Handle{} = handle), do: Fake.valid_handle?(fake_handle(handle))

  @impl true
  def close(%Handle{} = handle) do
    fake = fake_handle(handle)
    test_pid = :persistent_term.get({__MODULE__, handle.state})
    send(test_pid, {:acceptance_fake_closing, handle.state, Fake.remaining_operations(fake)})
    result = Fake.close(fake)
    :persistent_term.erase({__MODULE__, handle.state})
    result
  end

  @impl true
  def read(handle, request, context) do
    await_release(handle, :read, request, context)
    Fake.read(fake_handle(handle), request, context)
  end

  @impl true
  def write(handle, request, context) do
    await_release(handle, :write, request, context)
    Fake.write(fake_handle(handle), request, context)
  end

  @impl true
  def edit(handle, request, context) do
    await_release(handle, :edit, request, context)
    Fake.edit(fake_handle(handle), request, context)
  end

  @impl true
  def run(handle, spec, event_sink, context) do
    await_release(handle, :run, spec, context)
    Fake.run(fake_handle(handle), spec, event_sink, context)
  end

  defp await_release(handle, operation, request, context) do
    test_pid = :persistent_term.get({__MODULE__, handle.state})

    send(
      test_pid,
      {:acceptance_fake_operation, operation, self(), handle.state, request, context}
    )

    receive do
      {:release_acceptance_fake, ^operation} -> :ok
    after
      10_000 -> exit({:acceptance_fake_release_timeout, operation})
    end
  end

  defp fake_handle(handle), do: %{handle | backend: Fake}
end

defmodule Synapse.API.AcceptanceTest.ObservingReal do
  @behaviour Synapse.Workspace.Backend

  alias Synapse.Workspace.{Handle, Real}

  @impl true
  def workspace_backend?, do: true

  @impl true
  def valid_handle?(%Handle{} = handle), do: Real.valid_handle?(real_handle(handle))

  @impl true
  def close(%Handle{} = handle) do
    test_pid = :persistent_term.get({__MODULE__, handle.state})
    send(test_pid, {:acceptance_real_closing, handle.state})
    result = Real.close(real_handle(handle))
    :persistent_term.erase({__MODULE__, handle.state})
    result
  end

  @impl true
  def read(handle, request, context), do: Real.read(real_handle(handle), request, context)

  @impl true
  def write(handle, request, context), do: Real.write(real_handle(handle), request, context)

  @impl true
  def edit(handle, request, context), do: Real.edit(real_handle(handle), request, context)

  @impl true
  def run(handle, spec, event_sink, context) do
    test_pid = :persistent_term.get({__MODULE__, handle.state})

    observed_sink = fn event ->
      send(test_pid, {:acceptance_real_process_event, handle.state, event})
      event_sink.(event)
    end

    Real.run(real_handle(handle), spec, observed_sink, context)
  end

  defp real_handle(handle), do: %{handle | backend: Real}
end

defmodule Synapse.API.AcceptanceTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Synapse.Agent.OperationId
  alias Synapse.API.{Config, RunManager, SessionSupervisor}
  alias Synapse.API.AcceptanceTest.{ControlledFake, ObservingReal}
  alias Synapse.API.RunSession.RuntimeBoundary
  alias Synapse.API.TestClient
  alias Synapse.Provider.{Fake, Request, Response}
  alias Synapse.Provider.Event.{MessageCompleted, TextDelta}
  alias Synapse.Provider.OutputItem.{FunctionCall, Message}
  alias Synapse.Tool.Limits
  alias Synapse.Workspace
  alias Synapse.Workspace.Fake, as: WorkspaceFake

  alias Synapse.Workspace.{
    Access,
    MutationResult,
    OperationContext,
    ProcessEvent,
    ProcessResult,
    ProcessSpec,
    ReadLine,
    ReadRequest,
    ReadResult,
    Revision,
    WriteRequest
  }

  @model "test-model"
  @prompt "PHASE8_PROMPT_SENTINEL: inspect README.md, create created.txt, and verify it."
  @final_text "PHASE8_MODEL_OUTPUT_SENTINEL"
  @credential "PHASE8_CREDENTIAL_SENTINEL"
  @callback_sentinel "PHASE8_CALLBACK_SENTINEL"
  @provider_response "PHASE8_PROVIDER_RESPONSE_SENTINEL"

  test "real WebSockets preserve a Fake coding run across replay and stale reset" do
    root = temporary_root("PHASE8_PATH_SENTINEL")
    File.mkdir!(root)
    File.write!(Path.join(root, "README.md"), "SYNAPSE_API_FIXTURE\n")
    on_exit(fn -> File.rm_rf!(root) end)

    deadline = System.monotonic_time(:millisecond) + 60_000
    api = start_api(controlled_fake_opener(self()), deadline, max_replay_events: 3)
    client_a = open_ws(api.port)
    assert_hello(client_a.hello)
    send_command(client_a, "run.start", "start-success", start_payload(root))
    accepted = recv_ws(client_a)
    run_id = accepted_run_id(accepted, "start-success")

    assert_receive {:acceptance_fake_open, task, open_request}, 5_000
    assert open_request.owner == task
    assert open_request.root == root
    runtime_state = sole_runtime_state()
    provider_ids = provider_ids(run_id, 2)
    tool_ids = Map.new(1..3, &{&1, tool_id(run_id, 1, &1)})
    entries = fake_entries(tool_ids, runtime_state.cancel_ref, deadline)

    provider_owner =
      start_provider(provider_ids, success_script(initial_provider_request(run_id), run_id))

    send(task, {:open_acceptance_fake, entries})

    assert_receive {:acceptance_fake_opened, ^task, backend}, 5_000
    register_control_cleanup(ControlledFake, backend)
    backend_monitor = Process.monitor(backend)
    assert_receive {:acceptance_runtime_started, session, runtime_run}, 5_000
    session_monitor = Process.monitor(session)
    assert runtime_run.id == run_id
    assert :sys.get_state(session).runtime_run == runtime_run

    assert_receive {:acceptance_fake_operation, :read, operation_task, ^backend, _, _}, 5_000
    first = receive_sequences(client_a, 3)
    assert event_types(first) == ["run.started", "turn.started", "tool.started"]
    assert List.last(first)["payload"]["event"]["name"] == "read"

    socket_a = only_subscriber(api.manager, run_id)
    socket_a_monitor = Process.monitor(socket_a)
    gun_a_monitor = Process.monitor(client_a.connection)
    Process.exit(socket_a, :kill)
    assert_receive {:DOWN, ^socket_a_monitor, :process, ^socket_a, _reason}, 5_000

    assert_receive {:gun_down, connection_a, :ws, _reason, _streams}
                   when connection_a == client_a.connection,
                   5_000

    :gun.close(client_a.connection)

    assert_receive {:DOWN, ^gun_a_monitor, :process, connection_a, _reason}
                   when connection_a == client_a.connection,
                   5_000

    manager_state = :sys.get_state(api.manager)
    assert manager_state.active_run_id == run_id
    assert manager_state.runs[run_id].subscribers == %{}
    assert Process.alive?(session)
    refute_received {:acceptance_runtime_cancelled, _caller, ^runtime_run}

    send(operation_task, {:release_acceptance_fake, :read})
    assert_receive {:acceptance_fake_operation, :write, ^operation_task, ^backend, _, _}, 5_000

    client_b = open_ws(api.port)
    assert_hello(client_b.hello)

    send_command(client_b, "run.subscribe", "subscribe-replay", %{
      "run_id" => run_id,
      "after_seq" => 3
    })

    replay_snapshot = recv_ws(client_b)
    assert replay_snapshot["type"] == "run.snapshot"
    assert replay_snapshot["request_id"] == "subscribe-replay"
    assert replay_snapshot["payload"]["mode"] == "replay"
    refute replay_snapshot["payload"]["reset"]
    assert replay_snapshot["payload"]["first_available_seq"] == 3
    assert replay_snapshot["payload"]["last_seq"] == 5
    replay = receive_sequences(client_b, 4..5)
    assert event_types(replay) == ["tool.completed", "tool.started"]
    assert List.last(replay)["payload"]["event"]["name"] == "write"
    socket_b = only_subscriber(api.manager, run_id)

    client_c = open_ws(api.port)
    assert_hello(client_c.hello)

    send_command(client_c, "run.subscribe", "subscribe-stale", %{
      "run_id" => run_id,
      "after_seq" => 0
    })

    stale = recv_ws(client_c)
    assert stale["type"] == "run.snapshot"
    assert stale["request_id"] == "subscribe-stale"
    assert stale["payload"]["mode"] == "snapshot"
    assert stale["payload"]["reset"]
    assert stale["payload"]["first_available_seq"] == 3
    assert stale["payload"]["last_seq"] == 5
    assert stale["payload"]["projection"]["status"] == "running"
    assert stale["payload"]["projection"]["active_tool"]["name"] == "write"
    assert stale["payload"]["projection"]["active_tool"]["ordinal"] == 2
    socket_c = subscriber_except(api.manager, run_id, [socket_b])
    close_ws_with_server(client_c, socket_c)

    listener_monitor = Process.monitor(api.listener)
    socket_b_monitor = Process.monitor(socket_b)
    gun_b_monitor = Process.monitor(client_b.connection)

    listener_log =
      capture_log(fn ->
        Process.exit(api.listener, :kill)
        assert_receive {:DOWN, ^listener_monitor, :process, _listener, :killed}, 5_000
        assert_receive {:DOWN, ^socket_b_monitor, :process, ^socket_b, _reason}, 5_000

        assert_receive {:gun_down, connection_b, :ws, _reason, _streams}
                       when connection_b == client_b.connection,
                       5_000

        :gun.close(client_b.connection)

        assert_receive {:DOWN, ^gun_b_monitor, :process, connection_b, _reason}
                       when connection_b == client_b.connection,
                       5_000

        :sys.get_state(api.supervisor)
        replacement_listener = child_pid(api.supervisor, Bandit)
        assert replacement_listener != api.listener

        {:ok, {{127, 0, 0, 1}, replacement_port}} =
          ThousandIsland.listener_info(replacement_listener)

        send(self(), {:listener_replaced, replacement_listener, replacement_port})
      end)

    assert_receive {:listener_replaced, replacement_listener, replacement_port}, 5_000
    api = %{api | listener: replacement_listener, port: replacement_port}
    assert child_pid(api.supervisor, RunManager) == api.manager
    assert child_pid(api.supervisor, SessionSupervisor) == api.sessions
    assert Process.alive?(session)
    refute_received {:acceptance_runtime_cancelled, _caller, ^runtime_run}

    client_b = open_ws(api.port)
    assert_hello(client_b.hello)

    send_command(client_b, "run.subscribe", "subscribe-after-listener-loss", %{
      "run_id" => run_id,
      "after_seq" => 5
    })

    listener_replay = recv_ws(client_b)
    assert listener_replay["type"] == "run.snapshot"
    assert listener_replay["payload"]["mode"] == "replay"
    assert listener_replay["payload"]["last_seq"] == 5
    socket_b = only_subscriber(api.manager, run_id)

    send(operation_task, {:release_acceptance_fake, :write})
    assert_receive {:acceptance_fake_operation, :run, ^operation_task, ^backend, _, _}, 5_000
    live = receive_sequences(client_b, 6..7)
    assert event_types(live) == ["tool.completed", "tool.started"]
    assert List.last(live)["payload"]["event"]["name"] == "bash"

    log =
      capture_log(fn ->
        send(operation_task, {:release_acceptance_fake, :run})
        send(self(), {:captured_success_frames, receive_sequences(client_b, 8..13)})
      end)

    assert_receive {:captured_success_frames, remaining}, 5_000

    assert event_types(Enum.take(remaining, 5)) == [
             "tool.completed",
             "turn.completed",
             "turn.started",
             "text.delta",
             "turn.completed"
           ]

    terminal = List.last(remaining)
    assert terminal["type"] == "run.terminal"
    assert terminal["request_id"] == nil
    assert terminal["payload"]["run_id"] == run_id
    assert terminal["payload"]["seq"] == 13
    assert terminal["payload"]["status"] == "completed"
    assert terminal["payload"]["error"] == nil
    assert terminal["payload"]["result"]["text"] == @final_text
    assert terminal["payload"]["result"]["turns"] == 2
    assert terminal["payload"]["result"]["tool_calls"] == 3
    assert terminal["payload"]["result"]["provider_retries"] == 0

    assert Map.keys(terminal["payload"]["result"]) |> Enum.sort() ==
             ~w(output_bytes provider_retries text tool_calls turns)

    encoded_terminal = JSON.encode!(terminal)
    refute encoded_terminal =~ "final_response"
    refute encoded_terminal =~ @provider_response

    frames =
      [accepted] ++
        first ++ replay ++ [replay_snapshot, stale, listener_replay] ++ live ++ remaining

    forbidden = [
      @credential,
      @prompt,
      root,
      "SYNAPSE_API_FIXTURE",
      "phase-7",
      "VERIFIED",
      @provider_response,
      @callback_sentinel,
      inspect(runtime_run.run_ref),
      inspect(runtime_run.cancel_ref)
    ]

    Enum.each(forbidden, fn sentinel ->
      refute Enum.any?(frames, &(JSON.encode!(&1) =~ sentinel))
      refute log =~ sentinel
      refute listener_log =~ sentinel
    end)

    refute log =~ @final_text
    refute listener_log =~ @final_text

    assert Enum.flat_map(frames, &sentinel_paths(&1, @final_text)) |> Enum.sort() == [
             ["payload", "event", "delta"],
             ["payload", "result", "text"]
           ]

    assert_single_terminal(api.manager, client_b, run_id)
    assert_receive {:acceptance_fake_closing, ^backend, {:ok, 0}}, 5_000
    assert_receive {:DOWN, ^backend_monitor, :process, ^backend, _reason}, 5_000
    assert_receive {:DOWN, ^session_monitor, :process, ^session, :normal}, 5_000
    assert Enum.all?(provider_ids, &(Fake.remaining_turns(&1) == {:ok, 0}))
    assert File.read!(Path.join(root, "README.md")) == "SYNAPSE_API_FIXTURE\n"
    refute File.exists?(Path.join(root, "created.txt"))

    close_ws_with_server(client_b, socket_b)
    stop_provider(provider_owner, provider_ids)
    assert_api_idle(api)
    stop_api(api)
  end

  @tag skip: not Synapse.Workspace.Platform.supported?()
  test "another WebSocket cancels a Real command and every owned process settles" do
    previous_credential = System.get_env("TOKAMAK_API_KEY")
    System.put_env("TOKAMAK_API_KEY", @credential)

    on_exit(fn ->
      if previous_credential,
        do: System.put_env("TOKAMAK_API_KEY", previous_credential),
        else: System.delete_env("TOKAMAK_API_KEY")
    end)

    root = temporary_root("real-cancel")
    File.mkdir!(root)
    File.write!(Path.join(root, "README.md"), "SYNAPSE_API_REAL_FIXTURE\n")
    on_exit(fn -> File.rm_rf!(root) end)

    deadline = System.monotonic_time(:millisecond) + 60_000
    api = start_api(controlled_real_opener(self()), deadline)
    client_a = open_ws(api.port)
    send_command(client_a, "run.start", "start-cancel", start_payload(root))
    run_id = client_a |> recv_ws() |> accepted_run_id("start-cancel")
    socket_a = only_subscriber(api.manager, run_id)
    provider_ids = provider_ids(run_id, 2)

    provider_owner =
      start_provider(provider_ids, cancellation_script(initial_provider_request(run_id)))

    assert_receive {:acceptance_real_open, task, open_request}, 5_000
    assert open_request.root == root
    send(task, :open_acceptance_real)

    assert_receive {:acceptance_real_opened, ^task, backend, environment}, 5_000
    register_control_cleanup(ObservingReal, backend)
    backend_monitor = Process.monitor(backend)
    guard_monitor = Process.monitor(environment.guard)
    assert_receive {:acceptance_runtime_started, session, runtime_run}, 5_000
    session_monitor = Process.monitor(session)
    assert :sys.get_state(session).runtime_run == runtime_run
    await_real_output(backend, "ready", "")
    command_pid = root |> Path.join("long.pid") |> File.read!() |> String.trim()

    client_b = open_ws(api.port)
    assert_hello(client_b.hello)
    send_command(client_b, "run.cancel", "cancel-real", %{"run_id" => run_id})
    acknowledgement = recv_ws(client_b)

    assert acknowledgement == %{
             "version" => 1,
             "type" => "run.cancel_requested",
             "request_id" => "cancel-real",
             "payload" => %{"run_id" => run_id, "status" => "cancel_requested"}
           }

    assert_receive {:acceptance_runtime_cancelled, caller, ^runtime_run}, 5_000
    assert caller == api.manager
    terminal = receive_until_terminal(client_a)
    assert terminal["payload"]["run_id"] == run_id
    assert terminal["payload"]["status"] == "interrupted"
    assert terminal["payload"]["result"] == nil
    assert terminal["payload"]["error"]["source"] == "agent"
    assert terminal["payload"]["error"]["kind"] == "cancelled"
    assert terminal["payload"]["error"]["reason"] == "run_cancelled"
    assert terminal["payload"]["error"]["details"]["status"] == "ambiguous"
    assert terminal["payload"]["error"]["details"]["outcome"] == "unknown"
    refute JSON.encode!(terminal) =~ @credential
    assert_single_terminal(api.manager, client_a, run_id)
    assert_receive {:acceptance_real_closing, ^backend}, 5_000
    assert_receive {:DOWN, ^backend_monitor, :process, ^backend, _reason}, 5_000
    assert_receive {:DOWN, ^guard_monitor, :process, _guard, _reason}, 5_000
    assert_receive {:DOWN, ^session_monitor, :process, ^session, :normal}, 5_000
    refute os_process_alive?(command_pid)
    refute File.exists?(environment.root)
    assert Enum.all?(provider_ids, &(Fake.remaining_turns(&1) == {:ok, 1}))

    close_ws_with_server(client_a, socket_a)
    close_ws(client_b)
    stop_provider(provider_owner, provider_ids)
    assert_api_idle(api)
    stop_api(api)
  end

  test "Workspace-open failure is accepted then exposed as one sanitized terminal" do
    secret = "PHASE7_WORKSPACE_OPEN_SECRET"
    root = "/tmp/#{secret}"
    opener = controlled_failure_opener(self(), secret)
    api = start_api(opener, System.monotonic_time(:millisecond) + 60_000)
    client = open_ws(api.port)

    log =
      capture_log(fn ->
        send_command(client, "run.start", "start-open-failure", start_payload(root))
        accepted = recv_ws(client)
        run_id = accepted_run_id(accepted, "start-open-failure")
        assert_receive {:acceptance_failure_open, task}, 5_000
        session = :sys.get_state(api.manager).runs[run_id].session_pid
        session_monitor = Process.monitor(session)
        send(task, :release_acceptance_failure)
        terminal = recv_ws(client)

        assert terminal == %{
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
                     "reason" => "workspace_open_failed",
                     "message" => "Workspace could not be opened"
                   }
                 }
               }

        refute JSON.encode!(accepted) =~ secret
        refute JSON.encode!(terminal) =~ secret
        assert_single_terminal(api.manager, client, run_id)
        assert_receive {:DOWN, ^session_monitor, :process, ^session, :normal}, 5_000
      end)

    refute log =~ secret
    [run_id] = Map.keys(:sys.get_state(api.manager).runs)
    close_ws_with_server(client, only_subscriber(api.manager, run_id))
    assert_api_idle(api)
    stop_api(api)
  end

  test "loss of a registered Runtime coordinator produces one sanitized runtime_lost terminal" do
    root = temporary_root("runtime-loss")
    deadline = System.monotonic_time(:millisecond) + 60_000
    api = start_api(controlled_fake_opener(self()), deadline)
    client = open_ws(api.port)
    send_command(client, "run.start", "start-runtime-loss", start_payload(root))
    run_id = client |> recv_ws() |> accepted_run_id("start-runtime-loss")

    assert_receive {:acceptance_fake_open, task, _open_request}, 5_000
    runtime_state = sole_runtime_state()
    provider_ids = provider_ids(run_id, 2)
    read_id = tool_id(run_id, 1, 1)
    entries = [fake_read_entry(read_id, runtime_state.cancel_ref, deadline)]

    provider_owner =
      start_provider(provider_ids, runtime_loss_script(initial_provider_request(run_id)))

    send(task, {:open_acceptance_fake, entries})

    assert_receive {:acceptance_fake_opened, ^task, backend}, 5_000
    register_control_cleanup(ControlledFake, backend)
    backend_monitor = Process.monitor(backend)
    assert_receive {:acceptance_runtime_started, session, runtime_run}, 5_000
    session_monitor = Process.monitor(session)
    assert :sys.get_state(session).runtime_run == runtime_run
    assert_receive {:acceptance_fake_operation, :read, _operation_task, ^backend, _, _}, 5_000
    runtime_monitor = Process.monitor(runtime_run.server)
    Process.exit(runtime_run.server, :kill)
    assert_receive {:DOWN, ^runtime_monitor, :process, _server, :killed}, 5_000

    frames = receive_sequences(client, 1..4)
    assert event_types(Enum.take(frames, 3)) == ["run.started", "turn.started", "tool.started"]
    terminal = List.last(frames)

    assert terminal == %{
             "version" => 1,
             "type" => "run.terminal",
             "request_id" => nil,
             "payload" => %{
               "run_id" => run_id,
               "seq" => 4,
               "status" => "interrupted",
               "result" => nil,
               "error" => %{
                 "source" => "runtime",
                 "reason" => "runtime_lost",
                 "message" => "Runtime coordinator was lost"
               }
             }
           }

    assert_single_terminal(api.manager, client, run_id)
    assert_receive {:DOWN, ^backend_monitor, :process, ^backend, _reason}, 5_000
    assert_receive {:DOWN, ^session_monitor, :process, ^session, :normal}, 5_000
    :persistent_term.erase({ControlledFake, backend})
    assert :persistent_term.get({ControlledFake, backend}, :missing) == :missing
    assert Enum.all?(provider_ids, &(Fake.remaining_turns(&1) == {:ok, 1}))
    close_ws_with_server(client, only_subscriber(api.manager, run_id))
    stop_provider(provider_owner, provider_ids)
    assert_api_idle(api)
    stop_api(api)
  end

  defp start_api(workspace_opener, deadline, config_options \\ []) do
    assert_core_idle()
    test_pid = self()

    {:ok, runtime_options} =
      Synapse.Runtime.Options.new(
        provider: Fake,
        deadline: deadline,
        workspace_opener: workspace_opener
      )

    {:ok, boundary} =
      RuntimeBoundary.new(
        start_run: fn request, sink, options ->
          _captured_callback_sentinel = @callback_sentinel
          result = Synapse.Runtime.start_run(request, sink, options)
          send(test_pid, {:acceptance_runtime_started, self(), result_value(result)})
          result
        end,
        await: &Synapse.Runtime.await/2,
        cancel: fn run ->
          send(test_pid, {:acceptance_runtime_cancelled, self(), run})
          Synapse.Runtime.cancel(run)
        end
      )

    reference = make_ref()
    manager_name = {:global, {:api_acceptance_manager, reference}}
    sessions_name = {:global, {:api_acceptance_sessions, reference}}

    attrs =
      [enabled: true, default_model: @model, port: 0, runtime_options: runtime_options] ++
        config_options

    {:ok, config} = Config.new(attrs)

    {:ok, supervisor} =
      Synapse.API.Supervisor.start_link(
        name: nil,
        config: config,
        manager: manager_name,
        session_supervisor: sessions_name,
        runtime: boundary
      )

    on_exit(fn ->
      stop_if_alive(supervisor)
      force_core_cleanup()
    end)

    manager = child_pid(supervisor, RunManager)
    sessions = child_pid(supervisor, SessionSupervisor)
    listener = child_pid(supervisor, Bandit)
    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(listener)

    %{
      supervisor: supervisor,
      manager: manager,
      manager_name: manager_name,
      sessions: sessions,
      sessions_name: sessions_name,
      listener: listener,
      port: port
    }
  end

  defp result_value({:ok, run}), do: run
  defp result_value(error), do: error

  defp controlled_fake_opener(test_pid) do
    fn open_request ->
      send(test_pid, {:acceptance_fake_open, self(), open_request})

      receive do
        {:open_acceptance_fake, entries} ->
          {:ok, handle} =
            WorkspaceFake.open(entries,
              owner: open_request.owner,
              limits: open_request.limits,
              access: open_request.access
            )

          :persistent_term.put({ControlledFake, handle.state}, test_pid)
          send(test_pid, {:acceptance_fake_opened, self(), handle.state})
          {:ok, %{handle | backend: ControlledFake}}
      after
        10_000 -> exit(:acceptance_fake_open_timeout)
      end
    end
  end

  defp controlled_real_opener(test_pid) do
    fn open_request ->
      send(test_pid, {:acceptance_real_open, self(), open_request})

      receive do
        :open_acceptance_real ->
          case Workspace.open(open_request) do
            {:ok, handle} ->
              environment = :sys.get_state(handle.state).process_environment
              :persistent_term.put({ObservingReal, handle.state}, test_pid)
              send(test_pid, {:acceptance_real_opened, self(), handle.state, environment})
              {:ok, %{handle | backend: ObservingReal}}

            {:error, _error} = error ->
              error
          end
      after
        10_000 -> exit(:acceptance_real_open_timeout)
      end
    end
  end

  defp controlled_failure_opener(test_pid, secret) do
    fn _open_request ->
      send(test_pid, {:acceptance_failure_open, self()})

      receive do
        :release_acceptance_failure -> {:error, secret}
      after
        10_000 -> exit(:acceptance_failure_release_timeout)
      end
    end
  end

  defp start_provider(operation_ids, script) do
    {:ok, owner} = Fake.start_link(operation_ids, script)
    on_exit(fn -> stop_if_alive(owner) end)
    owner
  end

  defp stop_provider(owner, operation_ids) do
    aliases =
      Enum.map(operation_ids, &:global.whereis_name({Fake, &1}))
      |> Enum.filter(&is_pid/1)

    monitors = Enum.map([owner | aliases], &{&1, Process.monitor(&1)})
    Agent.stop(owner)

    Enum.each(monitors, fn {pid, monitor} ->
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 5_000
    end)

    assert Enum.all?(operation_ids, &(Fake.remaining_turns(&1) == {:error, :not_configured}))
  end

  defp register_control_cleanup(module, backend) do
    on_exit(fn -> :persistent_term.erase({module, backend}) end)
  end

  defp success_script(initial_request, run_id) do
    calls = [
      call("item-read", "call-read", "read", %{
        "path" => "README.md",
        "offset" => nil,
        "limit" => nil
      }),
      call("item-write", "call-write", "write", %{
        "path" => "created.txt",
        "content" => "phase-7\n",
        "expected_revision" => "missing"
      }),
      call("item-bash", "call-bash", "bash", %{
        "command" => "test \"$(cat created.txt)\" = phase-7 && printf VERIFIED",
        "timeout_ms" => nil
      })
    ]

    first = response!("#{@provider_response}-tools", calls)
    final = text_response("#{@provider_response}-final", @final_text)
    read_outcome = read_result("README.md", revision(1), "SYNAPSE_API_FIXTURE")

    write_outcome =
      mutation_result(tool_id(run_id, 1, 2), "created.txt", revision(2), "phase-7\n")

    bash_outcome = process_result(tool_id(run_id, 1, 3), "VERIFIED")

    results = [
      present(Enum.at(calls, 0), {:ok, read_outcome}),
      present(Enum.at(calls, 1), {:ok, write_outcome}),
      present(Enum.at(calls, 2), {:ok, bash_outcome})
    ]

    {:ok, projected} = Synapse.Agent.Projection.response_input(first, results, Limits.default())

    {:ok, continuation} =
      Request.new(
        model: initial_request.model,
        instructions: initial_request.instructions,
        input_items: initial_request.input_items ++ projected,
        tools: Synapse.Tool.Registry.specifications(),
        metadata: %{"run_id" => run_id, "turn" => 2}
      )

    [
      {:turn, initial_request, [], {:ok, first}},
      {:turn, continuation,
       [
         %TextDelta{
           item_id: "message-model-output",
           content_index: 0,
           delta: @final_text
         },
         %MessageCompleted{response: final}
       ], {:ok, final}}
    ]
  end

  defp cancellation_script(initial_request) do
    command =
      "test -z \"${TOKAMAK_API_KEY+x}\" || exit 97; " <>
        "printf '%s' $$ > long.pid; printf ready; " <>
        "trap '' TERM; while :; do :; done"

    calls = [
      call("item-cancel-bash", "call-cancel-bash", "bash", %{
        "command" => command,
        "timeout_ms" => 60_000
      })
    ]

    [
      {:turn, initial_request, [], {:ok, response!("response-cancel-tools", calls)}},
      {:turn, [], {:ok, text_response("response-cancel-never", "must not run")}}
    ]
  end

  defp runtime_loss_script(initial_request) do
    calls = [
      call("item-loss-read", "call-loss-read", "read", %{
        "path" => "README.md",
        "offset" => nil,
        "limit" => nil
      })
    ]

    [
      {:turn, initial_request, [], {:ok, response!("response-loss-tools", calls)}},
      {:turn, [], {:ok, text_response("response-loss-never", "must not run")}}
    ]
  end

  defp fake_entries(tool_ids, cancel_ref, deadline) do
    read_revision = revision(1)
    write_revision = revision(2)
    content = "phase-7\n"
    command = "test \"$(cat created.txt)\" = phase-7 && printf VERIFIED"

    [
      WorkspaceFake.expect_read(
        read_request("README.md"),
        operation_context(tool_ids[1], :read, cancel_ref, deadline),
        {:ok, read_result("README.md", read_revision, "SYNAPSE_API_FIXTURE")}
      ),
      WorkspaceFake.expect_write(
        write_request("created.txt", content, :missing),
        operation_context(tool_ids[2], :write, cancel_ref, deadline),
        {:ok, mutation_result(tool_ids[2], "created.txt", write_revision, content)}
      ),
      WorkspaceFake.expect_run(
        process_spec(command),
        operation_context(tool_ids[3], :exec, cancel_ref, deadline),
        process_events(tool_ids[3], "VERIFIED"),
        {:ok, process_result(tool_ids[3], "VERIFIED")}
      )
    ]
  end

  defp fake_read_entry(operation_id, cancel_ref, deadline) do
    WorkspaceFake.expect_read(
      read_request("README.md"),
      operation_context(operation_id, :read, cancel_ref, deadline),
      {:ok, read_result("README.md", revision(3), "runtime loss")}
    )
  end

  defp open_ws(port) do
    assert {:ok, client} = TestClient.open(port)
    client
  end

  defp close_ws(client) do
    assert :ok = TestClient.close(client)
  end

  defp close_ws_with_server(client, socket) do
    monitor = Process.monitor(socket)
    close_ws(client)
    assert_receive {:DOWN, ^monitor, :process, ^socket, _reason}, 5_000
  end

  defp send_command(client, type, request_id, payload) do
    assert {:ok, _command, _encoded} =
             TestClient.send_command(client, type, request_id, payload)

    :ok
  end

  defp recv_ws(client) do
    assert {:ok, frame} = TestClient.receive_json(client, 10_000)
    frame
  end

  defp receive_sequences(client, count) when is_integer(count),
    do: receive_sequences(client, 1..count)

  defp receive_sequences(client, range) do
    Enum.map(range, fn expected_seq ->
      frame = recv_ws(client)
      assert frame["payload"]["seq"] == expected_seq
      frame
    end)
  end

  defp receive_until_terminal(client) do
    frame = recv_ws(client)
    if frame["type"] == "run.terminal", do: frame, else: receive_until_terminal(client)
  end

  defp assert_single_terminal(manager, client, run_id) do
    state = :sys.get_state(manager)
    record = state.runs[run_id]
    [subscriber] = Map.values(record.subscribers)
    assert subscriber.cursor == record.terminal.seq
    assert record.last_seq == record.terminal.seq
    refute subscriber.notified

    request_id = "terminal-barrier-#{String.slice(run_id, -4, 4)}"
    send_command(client, "ping", request_id, %{})
    pong = recv_ws(client)

    assert pong == %{
             "version" => 1,
             "type" => "pong",
             "request_id" => request_id,
             "payload" => %{}
           }
  end

  defp event_types(frames),
    do: Enum.map(frames, &get_in(&1, ["payload", "event", "type"]))

  defp sentinel_paths(value, sentinel), do: sentinel_paths(value, sentinel, [])

  defp sentinel_paths(value, sentinel, path) when is_map(value) do
    Enum.flat_map(value, fn {key, item} -> sentinel_paths(item, sentinel, path ++ [key]) end)
  end

  defp sentinel_paths(value, sentinel, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} -> sentinel_paths(item, sentinel, path ++ [index]) end)
  end

  defp sentinel_paths(value, sentinel, path) when is_binary(value) do
    if value == sentinel, do: [path], else: []
  end

  defp sentinel_paths(_value, _sentinel, _path), do: []

  defp assert_hello(hello) do
    assert hello == %{
             "version" => 1,
             "type" => "server.hello",
             "request_id" => nil,
             "payload" => %{
               "protocol" => 1,
               "replay" => "memory",
               "max_active_runs" => 1
             }
           }
  end

  defp accepted_run_id(frame, request_id) do
    assert frame["type"] == "run.accepted"
    assert frame["request_id"] == request_id
    assert frame["payload"]["status"] == "starting"
    run_id = frame["payload"]["run_id"]
    assert Regex.match?(~r/^run_[A-Za-z0-9_-]{22}$/, run_id)
    run_id
  end

  defp start_payload(root) do
    %{
      "prompt" => @prompt,
      "cwd" => root,
      "model" => @model
    }
  end

  defp initial_provider_request(run_id) do
    {:ok, request} =
      Request.new(
        model: @model,
        instructions: "You are the Synapse coding agent.",
        input_items: [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => @prompt}]
          }
        ],
        tools: Synapse.Tool.Registry.specifications(),
        metadata: %{"run_id" => run_id, "turn" => 1}
      )

    request
  end

  defp provider_ids(run_id, turns),
    do: Enum.map(1..turns, fn turn -> elem(OperationId.provider(run_id, turn, 1), 1) end)

  defp tool_id(run_id, turn, ordinal),
    do: elem(OperationId.tool(run_id, turn, ordinal), 1)

  defp response!(id, output_items) do
    {:ok, response} = Response.new(id: id, model: @model, output_items: output_items)
    response
  end

  defp text_response(id, text),
    do: response!(id, [%Message{id: "message-#{id}", role: :assistant, content: text}])

  defp call(id, call_id, name, arguments),
    do: %FunctionCall{id: id, call_id: call_id, name: name, arguments: arguments}

  defp present(provider_call, outcome) do
    {:ok, call} = Synapse.Tool.Call.from_provider(provider_call)

    module =
      case call.name do
        "read" -> Synapse.Tool.Read
        "write" -> Synapse.Tool.Write
        "bash" -> Synapse.Tool.Bash
      end

    module.present(call, outcome, Limits.default())
  end

  defp operation_context(operation_id, access_kind, cancel_ref, deadline) do
    access =
      case access_kind do
        :read -> %Access{read: true, write: false, exec: false}
        :write -> %Access{read: false, write: true, exec: false}
        :exec -> %Access{read: false, write: false, exec: true}
      end

    {:ok, context} =
      OperationContext.new(
        operation_id: operation_id,
        access: access,
        cancel_ref: cancel_ref,
        deadline: deadline
      )

    context
  end

  defp read_request(path) do
    limits = Limits.default()

    {:ok, request} =
      ReadRequest.new(
        path: path,
        start_line: 1,
        line_count: limits.default_read_lines,
        max_bytes: limits.default_read_source_bytes
      )

    request
  end

  defp write_request(path, content, expected_revision) do
    {:ok, request} =
      WriteRequest.new(path: path, content: content, expected_revision: expected_revision)

    request
  end

  defp process_spec(command) do
    limits = Limits.default()

    {:ok, spec} =
      ProcessSpec.new(
        executable: "/bin/bash",
        arguments: ["-lc", command],
        cwd: ".",
        inactivity_ms: limits.default_bash_inactivity_ms,
        timeout_ms: limits.default_bash_timeout_ms,
        max_output_bytes: limits.default_bash_output_bytes,
        mutation: :unknown
      )

    spec
  end

  defp read_result(path, revision, text) do
    {:ok, line} = ReadLine.new(number: 1, text: text, ending: :none, truncated: false)

    {:ok, result} =
      ReadResult.new(
        path: path,
        revision: revision,
        lines: [line],
        next_line: nil,
        file_bytes: byte_size(text)
      )

    result
  end

  defp mutation_result(operation_id, path, revision, content) do
    {:ok, result} =
      MutationResult.new(
        operation_id: operation_id,
        path: path,
        previous_revision: :missing,
        revision: revision,
        bytes_written: byte_size(content),
        changed: true,
        diff: "changed",
        diff_truncated: false
      )

    result
  end

  defp process_result(operation_id, output) do
    {:ok, result} =
      ProcessResult.new(
        operation_id: operation_id,
        termination: :exited,
        exit_code: 0,
        output: output,
        output_bytes: byte_size(output),
        truncated: false,
        elapsed_ms: 1
      )

    result
  end

  defp process_events(operation_id, output) do
    {:ok, started} = ProcessEvent.Started.new(operation_id: operation_id)
    {:ok, chunk} = ProcessEvent.Output.new(operation_id: operation_id, sequence: 1, data: output)
    [started, chunk]
  end

  defp revision(byte) do
    {:ok, revision} = Revision.from_mac(:binary.copy(<<byte>>, 32))
    revision
  end

  defp sole_runtime_state do
    [{_id, server, :worker, _modules}] =
      DynamicSupervisor.which_children(Synapse.Runtime.Supervisor)

    :sys.get_state(server)
  end

  defp only_subscriber(manager, run_id) do
    state = :sys.get_state(manager)
    [socket] = state.runs[run_id].subscribers |> Map.keys()
    socket
  end

  defp subscriber_except(manager, run_id, existing) do
    state = :sys.get_state(manager)
    [socket] = Map.keys(state.runs[run_id].subscribers) -- existing
    socket
  end

  defp await_real_output(backend, expected, output) do
    assert_receive {:acceptance_real_process_event, ^backend, event}, 5_000

    next =
      case event do
        %ProcessEvent.Output{data: data} -> output <> data
        %ProcessEvent.Started{} -> output
      end

    if next =~ expected, do: next, else: await_real_output(backend, expected, next)
  end

  defp assert_api_idle(api) do
    assert_core_idle()
    assert DynamicSupervisor.count_children(api.sessions).active == 0
    state = :sys.get_state(api.manager)
    assert state.active_run_id == nil

    assert Enum.all?(state.runs, fn {_run_id, record} ->
             is_nil(record.session_pid) and is_nil(record.runtime_run)
           end)
  end

  defp assert_core_idle do
    assert DynamicSupervisor.count_children(Synapse.Runtime.Supervisor).active == 0
    assert Task.Supervisor.children(Synapse.TaskSupervisor) == []
    assert DynamicSupervisor.count_children(Synapse.Workspace.Supervisor).active == 0
  end

  defp stop_api(api) do
    pids = [api.listener, api.sessions, api.manager, api.supervisor]
    monitors = Enum.map(pids, &{&1, Process.monitor(&1)})
    Supervisor.stop(api.supervisor)

    Enum.each(monitors, fn {pid, monitor} ->
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 7_000
    end)

    assert :global.whereis_name(elem(api.manager_name, 1)) == :undefined
    assert :global.whereis_name(elem(api.sessions_name, 1)) == :undefined
  end

  defp child_pid(supervisor, id) do
    Supervisor.which_children(supervisor)
    |> Enum.find_value(fn
      {^id, pid, _type, _modules} -> pid
      _child -> nil
    end)
  end

  defp stop_if_alive(pid) when is_pid(pid) do
    if Process.alive?(pid), do: Supervisor.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  defp force_core_cleanup do
    runtime =
      DynamicSupervisor.which_children(Synapse.Runtime.Supervisor)
      |> Enum.map(&elem(&1, 1))

    tasks = Task.Supervisor.children(Synapse.TaskSupervisor)

    workspace =
      DynamicSupervisor.which_children(Synapse.Workspace.Supervisor)
      |> Enum.map(&elem(&1, 1))

    Enum.each(runtime ++ tasks ++ workspace, fn pid ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)
  end

  defp temporary_root(label) do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    Path.join(System.tmp_dir!(), "synapse-api-#{label}-#{suffix}")
  end

  defp os_process_alive?(pid) do
    case System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end
end
