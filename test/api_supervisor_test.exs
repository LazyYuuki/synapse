defmodule Synapse.API.SupervisorTest do
  use ExUnit.Case, async: false

  alias Synapse.API.{Config, RunManager, SessionSupervisor}
  alias Synapse.API.RunSession.RuntimeBoundary
  alias Synapse.Run.Event
  alias Synapse.Runtime.Run

  test "disabled root preserves three children and enabled root appends API after Runtime" do
    disabled = Config.default()
    enabled = config()

    assert Enum.map(Synapse.Supervisor.child_specs(api_config: disabled), & &1.id) == [
             Synapse.Workspace.Supervisor,
             Synapse.TaskSupervisor,
             Synapse.Runtime.Supervisor
           ]

    specs = Synapse.Supervisor.child_specs(api_config: enabled)

    assert Enum.map(specs, & &1.id) == [
             Synapse.Workspace.Supervisor,
             Synapse.TaskSupervisor,
             Synapse.Runtime.Supervisor,
             Synapse.API.Supervisor
           ]

    assert List.last(specs).restart == :permanent
    assert List.last(specs).shutdown == :infinity
    assert List.last(specs).type == :supervisor
  end

  test "API tree uses exact rest_for_one order and one temporary-session capacity" do
    names = names()
    config = config()
    options = [config: config, manager: names.manager, session_supervisor: names.sessions]

    assert {:ok, {flags, _children}} = Synapse.API.Supervisor.init(options)
    assert flags.strategy == :rest_for_one

    specs = Synapse.API.Supervisor.child_specs(options)
    assert Enum.map(specs, & &1.id) == [RunManager, SessionSupervisor, Bandit]
    assert Enum.map(specs, & &1.restart) == [:permanent, :permanent, :permanent]
    assert Enum.map(specs, & &1.shutdown) == [5_000, 5_000, 6_000]
    assert List.last(specs).type == :supervisor

    %{start: {Bandit, :start_link, [listener_options]}} = List.last(specs)
    assert listener_options[:ip] == {127, 0, 0, 1}
    assert listener_options[:port] == 0
    assert listener_options[:http_2_options] == [enabled: false]
    assert listener_options[:http_1_options][:max_request_line_length] == 8_192
    assert listener_options[:http_1_options][:max_header_count] == 32
    assert listener_options[:http_1_options][:max_header_length] == 1_024
    assert listener_options[:websocket_options][:max_frame_size] == 2_097_166
    assert listener_options[:websocket_options][:max_fragmented_message_size] == 2_097_152
    refute listener_options[:websocket_options][:compress]
    assert listener_options[:thousand_island_options][:num_acceptors] == 1
    assert listener_options[:thousand_island_options][:num_connections] == 128
    assert listener_options[:thousand_island_options][:read_timeout] == 60_000
    assert listener_options[:thousand_island_options][:shutdown_timeout] == 5_000

    {:ok, sessions} = SessionSupervisor.start_link(name: nil)
    on_exit(fn -> stop(sessions) end)
    assert {:ok, session_flags} = SessionSupervisor.init(:ok)
    assert session_flags.strategy == :one_for_one
    assert session_flags.max_children == 1
  end

  test "listener, session owner, and Manager failures restart only the rest_for_one suffix" do
    %{supervisor: supervisor} = api = start_api()
    manager = child_pid(supervisor, RunManager)
    sessions = child_pid(supervisor, SessionSupervisor)
    listener = child_pid(supervisor, Bandit)

    kill_and_await(listener)
    barrier(supervisor)
    replacement_listener = child_pid(supervisor, Bandit)
    assert replacement_listener != listener
    assert child_pid(supervisor, RunManager) == manager
    assert child_pid(supervisor, SessionSupervisor) == sessions
    assert_listener(replacement_listener)

    kill_and_await(sessions)
    barrier(supervisor)
    replacement_sessions = child_pid(supervisor, SessionSupervisor)
    second_listener = child_pid(supervisor, Bandit)
    assert replacement_sessions != sessions
    assert second_listener != replacement_listener
    assert child_pid(supervisor, RunManager) == manager
    assert_listener(second_listener)

    kill_and_await(manager)
    barrier(supervisor)
    assert child_pid(supervisor, RunManager) != manager
    assert child_pid(supervisor, SessionSupervisor) != replacement_sessions
    assert child_pid(supervisor, Bandit) != second_listener
    assert_listener(child_pid(supervisor, Bandit))
    assert Process.alive?(api.supervisor)
  end

  test "an enabled isolated root starts full dependency order on port zero" do
    config = config()
    names = names()

    {:ok, root} =
      Synapse.Supervisor.start_link(
        name: nil,
        workspace_supervisor: names.workspace,
        task_supervisor: names.tasks,
        runtime_supervisor: names.runtime,
        api_config: config,
        api_supervisor: nil,
        api_manager: names.manager,
        api_session_supervisor: names.sessions
      )

    on_exit(fn -> stop(root) end)

    assert Enum.map(Supervisor.which_children(root), &elem(&1, 0)) |> Enum.reverse() == [
             Synapse.Workspace.Supervisor,
             Synapse.TaskSupervisor,
             Synapse.Runtime.Supervisor,
             Synapse.API.Supervisor
           ]

    api = child_pid(root, Synapse.API.Supervisor)
    {:ok, listener} = Synapse.API.Supervisor.listener(api)
    assert_listener(listener)
  end

  test "fixed-port conflict fails API startup without disturbing the existing listener" do
    {:ok, reserved} =
      :gen_tcp.listen(0,
        mode: :binary,
        active: false,
        ip: {127, 0, 0, 1},
        reuseaddr: false
      )

    on_exit(fn -> :gen_tcp.close(reserved) end)
    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(reserved)
    names = names()
    {:ok, config} = Config.new(enabled: true, default_model: "model-a", port: port)

    Process.flag(:trap_exit, true)

    assert {:error, _reason} =
             Synapse.API.Supervisor.start_link(
               name: nil,
               config: config,
               manager: names.manager,
               session_supervisor: names.sessions
             )

    assert {:ok, {{127, 0, 0, 1}, ^port}} = :inet.sockname(reserved)
  end

  test "root shutdown cancels RunSession while lower infrastructure remains alive" do
    test_pid = self()
    config = config()
    names = names()

    {:ok, boundary} =
      RuntimeBoundary.new(
        start_run: fn request, _sink, _options ->
          run = runtime_run(request.id, self())
          send(test_pid, {:shutdown_runtime_started, self(), run})
          {:ok, run}
        end,
        await: fn run, timeout ->
          reference = make_ref()
          send(test_pid, {:shutdown_runtime_await, self(), reference, run, timeout})

          receive do
            {:shutdown_await_reply, ^reference, reply} -> reply
          after
            timeout -> {:error, :await_timeout}
          end
        end,
        cancel: fn run ->
          send(test_pid, {:shutdown_runtime_cancel, self(), run})
          :ok
        end
      )

    {:ok, root} =
      Synapse.Supervisor.start_link(
        name: nil,
        workspace_supervisor: names.workspace,
        task_supervisor: names.tasks,
        runtime_supervisor: names.runtime,
        api_config: config,
        api_supervisor: nil,
        api_manager: names.manager,
        api_session_supervisor: names.sessions,
        api_runtime: boundary
      )

    on_exit(fn -> stop(root) end)
    workspace = child_pid(root, Synapse.Workspace.Supervisor)
    tasks = child_pid(root, Synapse.TaskSupervisor)
    runtime = child_pid(root, Synapse.Runtime.Supervisor)
    api = child_pid(root, Synapse.API.Supervisor)
    listener = child_pid(api, Bandit)

    {:ok, command} =
      Synapse.API.Command.Start.new(
        %{prompt: "Hold", cwd: "/tmp/project", model: "model-a", budget: config.budget},
        config
      )

    assert {:ok, _run_id} = RunManager.start_run(names.manager, command)
    assert_receive {:shutdown_runtime_started, session, run}
    assert_receive {:shutdown_runtime_await, ^session, await_ref, ^run, 1_000}
    listener_monitor = Process.monitor(listener)
    root_monitor = Process.monitor(root)
    stopper = Task.async(fn -> Supervisor.stop(root) end)
    assert_receive {:DOWN, ^listener_monitor, :process, ^listener, _reason}, 7_000
    assert Process.alive?(workspace)
    assert Process.alive?(tasks)
    assert Process.alive?(runtime)
    send(session, {:shutdown_await_reply, await_ref, {:error, :await_timeout}})

    assert_receive {:shutdown_runtime_cancel, ^session, ^run}, 5_000
    assert Process.alive?(workspace)
    assert Process.alive?(tasks)
    assert Process.alive?(runtime)
    assert :ok = Task.await(stopper, 10_000)
    assert_receive {:DOWN, ^root_monitor, :process, ^root, :normal}
  end

  test "Manager failure cancels but never replays an admitted temporary RunSession" do
    test_pid = self()
    names = names()
    config = config()

    {:ok, boundary} =
      RuntimeBoundary.new(
        start_run: fn request, sink, _options ->
          run = runtime_run(request.id, self())
          send(test_pid, {:restart_runtime_started, self(), run, sink})
          {:ok, run}
        end,
        await: fn run, _timeout ->
          reference = make_ref()
          send(test_pid, {:restart_runtime_await, self(), reference, run})

          receive do
            {:restart_await_reply, ^reference, reply} -> reply
          after
            5_000 -> {:error, :test_timeout}
          end
        end,
        cancel: fn run ->
          send(test_pid, {:restart_runtime_cancel, self(), run})
          :ok
        end
      )

    {:ok, supervisor} =
      Synapse.API.Supervisor.start_link(
        name: nil,
        config: config,
        manager: names.manager,
        session_supervisor: names.sessions,
        runtime: boundary
      )

    on_exit(fn -> stop(supervisor) end)

    {:ok, command} =
      Synapse.API.Command.Start.new(
        %{prompt: "Hold", cwd: "/tmp/project", model: "model-a", budget: config.budget},
        config
      )

    assert {:ok, run_id} = RunManager.start_run(names.manager, command)
    assert_receive {:restart_runtime_started, session, run, sink}
    assert_receive {:restart_runtime_await, ^session, await_ref, ^run}
    {:ok, started} = Event.new(:run_started, run_id: run_id, model: "model-a")
    assert :ok = sink.(started)

    assert {:ok, %{messages: [frame], cursor: 1, more?: false}} =
             RunManager.pull(names.manager, run_id, 0)

    assert JSON.decode!(IO.iodata_to_binary(frame))["payload"]["seq"] == 1
    manager = child_pid(supervisor, RunManager)
    kill_and_await(manager)
    send(session, {:restart_await_reply, await_ref, {:error, :await_timeout}})
    assert_receive {:restart_runtime_cancel, ^session, ^run}, 5_000
    barrier(supervisor)

    replacement_manager = child_pid(supervisor, RunManager)
    replacement_sessions = child_pid(supervisor, SessionSupervisor)
    assert replacement_manager != manager
    assert :sys.get_state(replacement_manager).runs == %{}
    assert {:error, :run_not_found} = RunManager.subscribe(replacement_manager, run_id, 1)
    assert {:error, :run_not_found} = RunManager.cancel(replacement_manager, run_id)
    assert {:error, :run_not_found} = RunManager.pull(replacement_manager, run_id, 1)
    assert DynamicSupervisor.count_children(replacement_sessions).active == 0
    refute_received {:restart_runtime_started, _replacement_session, _run, _sink}
  end

  test "listener failure preserves an active session without cancellation or replay" do
    label = make_ref()
    names = names()
    config = config()
    boundary = runtime_boundary(self(), label)

    {:ok, supervisor} =
      Synapse.API.Supervisor.start_link(
        name: nil,
        config: config,
        manager: names.manager,
        session_supervisor: names.sessions,
        runtime: boundary
      )

    on_exit(fn -> stop(supervisor) end)
    {session, run, await_ref} = start_blocked_run(names.manager, config, label)
    manager = child_pid(supervisor, RunManager)
    sessions = child_pid(supervisor, SessionSupervisor)
    listener = child_pid(supervisor, Bandit)
    kill_and_await(listener)
    barrier(supervisor)
    assert child_pid(supervisor, RunManager) == manager
    assert child_pid(supervisor, SessionSupervisor) == sessions
    assert child_pid(supervisor, Bandit) != listener
    assert Process.alive?(session)
    refute_received {:supervision_boundary, ^label, :cancel, _caller, ^run}
    refute_received {:supervision_boundary, ^label, :started, _caller, _replacement}

    send(session, {:supervision_await_reply, label, await_ref, {:error, :not_owner}})
    assert_receive {:supervision_boundary, ^label, :cancel, ^session, ^run}
  end

  test "SessionSupervisor failure cancels an active session and never starts a replacement" do
    label = make_ref()
    names = names()
    config = config()
    boundary = runtime_boundary(self(), label)

    {:ok, supervisor} =
      Synapse.API.Supervisor.start_link(
        name: nil,
        config: config,
        manager: names.manager,
        session_supervisor: names.sessions,
        runtime: boundary
      )

    on_exit(fn -> stop(supervisor) end)
    {session, run, await_ref} = start_blocked_run(names.manager, config, label)
    manager = child_pid(supervisor, RunManager)
    sessions = child_pid(supervisor, SessionSupervisor)
    listener = child_pid(supervisor, Bandit)
    sessions_monitor = Process.monitor(sessions)
    Process.exit(sessions, :kill)
    assert_receive {:DOWN, ^sessions_monitor, :process, ^sessions, :killed}
    send(session, {:supervision_await_reply, label, await_ref, {:error, :await_timeout}})
    assert_receive {:supervision_boundary, ^label, :cancel, ^session, ^run}, 5_000
    barrier(supervisor)

    replacement_sessions = child_pid(supervisor, SessionSupervisor)
    assert child_pid(supervisor, RunManager) == manager
    assert replacement_sessions != sessions
    assert child_pid(supervisor, Bandit) != listener
    assert DynamicSupervisor.count_children(replacement_sessions).active == 0
    refute_received {:supervision_boundary, ^label, :started, _caller, _replacement}
  end

  defp start_api(options \\ []) do
    config = config()
    names = names()

    {:ok, supervisor} =
      Synapse.API.Supervisor.start_link(
        [
          name: nil,
          config: config,
          manager: names.manager,
          session_supervisor: names.sessions
        ] ++ options
      )

    on_exit(fn -> stop(supervisor) end)
    %{supervisor: supervisor, config: config, names: names}
  end

  defp config do
    {:ok, config} = Config.new(enabled: true, default_model: "model-a", port: 0)
    config
  end

  defp names do
    reference = make_ref()

    %{
      manager: {:global, {:api_supervisor_manager, reference}},
      sessions: {:global, {:api_supervisor_sessions, reference}},
      workspace: {:global, {:api_supervisor_workspace, reference}},
      tasks: {:global, {:api_supervisor_tasks, reference}},
      runtime: {:global, {:api_supervisor_runtime, reference}}
    }
  end

  defp child_pid(supervisor, id) do
    Supervisor.which_children(supervisor)
    |> Enum.find_value(fn
      {^id, pid, _type, _modules} -> pid
      _child -> nil
    end)
  end

  defp barrier(supervisor), do: :sys.get_state(supervisor)

  defp kill_and_await(pid) do
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000
  end

  defp assert_listener(listener) do
    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(listener)
    assert port in 1..65_535
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

  defp runtime_boundary(test_pid, label) do
    {:ok, boundary} =
      RuntimeBoundary.new(
        start_run: fn request, _sink, _options ->
          run = runtime_run(request.id, self())
          send(test_pid, {:supervision_boundary, label, :started, self(), run})
          {:ok, run}
        end,
        await: fn run, _timeout ->
          reference = make_ref()
          send(test_pid, {:supervision_boundary, label, :await, self(), reference, run})

          receive do
            {:supervision_await_reply, ^label, ^reference, reply} -> reply
          after
            5_000 -> {:error, :test_timeout}
          end
        end,
        cancel: fn run ->
          send(test_pid, {:supervision_boundary, label, :cancel, self(), run})
          :ok
        end
      )

    boundary
  end

  defp start_blocked_run(manager, config, label) do
    {:ok, command} =
      Synapse.API.Command.Start.new(
        %{prompt: "Hold", cwd: "/tmp/project", model: "model-a", budget: config.budget},
        config
      )

    assert {:ok, _run_id} = RunManager.start_run(manager, command)
    assert_receive {:supervision_boundary, ^label, :started, session, run}
    assert_receive {:supervision_boundary, ^label, :await, ^session, await_ref, ^run}
    {session, run, await_ref}
  end

  defp stop(supervisor) when is_pid(supervisor) do
    if Process.alive?(supervisor), do: Supervisor.stop(supervisor)
  catch
    :exit, _reason -> :ok
  end
end
