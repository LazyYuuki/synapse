defmodule Synapse.Runtime.SupervisionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Synapse.Runtime.Error
  alias Synapse.Runtime.RunServer
  alias Synapse.Runtime.RunServer.Message
  alias Synapse.Runtime.RunServer.State
  alias Synapse.Runtime.Supervisor, as: RuntimeSupervisor
  alias Synapse.Workspace
  alias Synapse.Workspace.{Access, Limits}

  test "isolated root restarts empty infrastructure with the same singleton policy" do
    {:ok, root} =
      Synapse.Supervisor.start_link(
        name: nil,
        workspace_supervisor: nil,
        task_supervisor: nil,
        runtime_supervisor: nil
      )

    on_exit(fn -> stop_if_alive(root) end)

    children = child_map(root)
    old_runtime_supervisor = children[Synapse.Runtime.Supervisor]
    monitor = Process.monitor(old_runtime_supervisor)
    Process.exit(old_runtime_supervisor, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^old_runtime_supervisor, :killed}

    assert eventually(fn ->
             replacement = child_map(root)[Synapse.Runtime.Supervisor]
             is_pid(replacement) and replacement != old_runtime_supervisor
           end)

    children = child_map(root)
    workspace_supervisor = children[Synapse.Workspace.Supervisor]
    runtime_supervisor = children[Synapse.Runtime.Supervisor]
    task_supervisor = children[Synapse.TaskSupervisor]
    test_pid = self()

    assert DynamicSupervisor.count_children(runtime_supervisor).active == 0

    agent = blocking_agent(self(), :replacement_agent_started)

    assert {:ok, run_server} =
             RuntimeSupervisor.start_run_server(state(), agent,
               supervisor: runtime_supervisor,
               task_supervisor: task_supervisor
             )

    assert_receive {:replacement_agent_started, task}

    assert {:error, %Error{reason: :runtime_busy, run_id: "run-1"}} =
             RuntimeSupervisor.start_run_server(
               state(),
               fn _run_server ->
                 send(test_pid, :second_replacement_agent_started)
               end,
               supervisor: runtime_supervisor,
               task_supervisor: task_supervisor
             )

    refute_received :second_replacement_agent_started

    run_monitor = Process.monitor(run_server)
    task_monitor = Process.monitor(task)
    workspace_supervisor_monitor = Process.monitor(workspace_supervisor)
    task_supervisor_monitor = Process.monitor(task_supervisor)
    runtime_supervisor_monitor = Process.monitor(runtime_supervisor)

    assert :ok = Supervisor.stop(root)
    assert_receive {:DOWN, ^run_monitor, :process, ^run_server, :shutdown}
    assert_receive {:DOWN, ^task_monitor, :process, ^task, :killed}
    assert_receive {:DOWN, ^runtime_supervisor_monitor, :process, ^runtime_supervisor, :shutdown}
    assert_receive {:DOWN, ^task_supervisor_monitor, :process, ^task_supervisor, :shutdown}

    assert_receive {:DOWN, ^workspace_supervisor_monitor, :process, ^workspace_supervisor,
                    :shutdown}
  end

  test "temporary RunServer links and monitors one brutally-shutdown Agent task" do
    {:ok, task_supervisor} = Task.Supervisor.start_link()
    {:ok, runtime_supervisor} = RuntimeSupervisor.start_link(name: nil)
    test_pid = self()

    on_exit(fn ->
      stop_if_alive(runtime_supervisor)
      stop_if_alive(task_supervisor)
    end)

    assert RunServer.child_spec({state(), fn _run_server -> :ok end, task_supervisor}).restart ==
             :temporary

    assert {:ok, run_server} =
             RuntimeSupervisor.start_run_server(
               state(),
               blocking_agent(self(), :agent_started),
               supervisor: runtime_supervisor,
               task_supervisor: task_supervisor
             )

    assert_receive {:agent_started, task}

    run_state = :sys.get_state(run_server)
    assert run_state.task.pid == task
    assert run_state.task.owner == run_server
    assert Process.info(run_server, :trap_exit) == {:trap_exit, true}

    {:links, links} = Process.info(run_server, :links)
    assert task in links

    {:monitors, monitors} = Process.info(run_server, :monitors)
    assert {:process, task} in monitors
    assert Task.Supervisor.children(task_supervisor) == [task]

    assert {:error, %Error{reason: :runtime_busy, run_id: "run-1"}} =
             RuntimeSupervisor.start_run_server(
               state(),
               fn _run_server ->
                 send(test_pid, :second_agent_started)
               end,
               supervisor: runtime_supervisor,
               task_supervisor: task_supervisor
             )

    refute_received :second_agent_started
    assert DynamicSupervisor.count_children(runtime_supervisor).active == 1
    assert Task.Supervisor.children(task_supervisor) == [task]

    run_monitor = Process.monitor(run_server)
    task_monitor = Process.monitor(task)
    Process.exit(run_server, :kill)

    assert_receive {:DOWN, ^run_monitor, :process, ^run_server, :killed}
    assert_receive {:DOWN, ^task_monitor, :process, ^task, reason}
    assert reason != :normal

    assert eventually(fn -> DynamicSupervisor.count_children(runtime_supervisor).active == 0 end)
    assert Task.Supervisor.children(task_supervisor) == []
  end

  test "isolated application shutdown removes linked Fake Provider and Workspace owners" do
    {:ok, root} =
      Synapse.Supervisor.start_link(
        name: nil,
        workspace_supervisor: nil,
        task_supervisor: nil,
        runtime_supervisor: nil
      )

    on_exit(fn -> stop_if_alive(root) end)
    children = child_map(root)
    runtime_supervisor = children[Synapse.Runtime.Supervisor]
    task_supervisor = children[Synapse.TaskSupervisor]
    test_pid = self()
    run_state = state()

    agent = fn run_server ->
      {:ok, access} = Access.new(read: true, write: true, exec: true)

      {:ok, handle} =
        Workspace.Fake.open([],
          owner: self(),
          limits: Limits.default(),
          access: access
        )

      {:ok, script_owner} =
        Synapse.Provider.Fake.start_link(
          "runtime-shutdown-provider",
          [
            {:turn, [], {:error, provider_error("runtime-shutdown-provider")}}
          ]
        )

      send(test_pid, {:shutdown_owned_processes, self(), handle.state, script_owner})
      {:ok, ready} = Message.ready(run_state.run_ref, self(), handle)
      send(run_server, ready)

      receive do
        %Message{kind: :accept, run_ref: run_ref} when run_ref == run_state.run_ref ->
          send(test_pid, :shutdown_agent_accepted)
      end

      receive do
        :never -> :ok
      end
    end

    assert {:ok, run_server} =
             RuntimeSupervisor.start_run_server(run_state, agent,
               supervisor: runtime_supervisor,
               task_supervisor: task_supervisor
             )

    assert_receive {:shutdown_owned_processes, task, workspace_owner, script_owner}
    assert_receive %Message{kind: :started, worker: ^task, payload: ^run_server}
    assert_receive :shutdown_agent_accepted

    task_monitor = Process.monitor(task)
    workspace_monitor = Process.monitor(workspace_owner)
    script_monitor = Process.monitor(script_owner)
    run_monitor = Process.monitor(run_server)

    assert :ok = Supervisor.stop(root)
    assert_receive {:DOWN, ^run_monitor, :process, ^run_server, :shutdown}
    assert_receive {:DOWN, ^task_monitor, :process, ^task, :killed}
    assert_receive {:DOWN, ^workspace_monitor, :process, ^workspace_owner, _reason}
    assert_receive {:DOWN, ^script_monitor, :process, ^script_owner, _reason}
    refute Process.alive?(workspace_owner)
    refute Process.alive?(script_owner)
  end

  test "TaskSupervisor brutal shutdown cannot be trapped and neither child restarts" do
    {:ok, task_supervisor} = Task.Supervisor.start_link()
    {:ok, runtime_supervisor} = RuntimeSupervisor.start_link(name: nil)

    on_exit(fn ->
      stop_if_alive(runtime_supervisor)
      stop_if_alive(task_supervisor)
    end)

    test_pid = self()

    trapping_agent = fn _run_server ->
      Process.flag(:trap_exit, true)
      send(test_pid, {:trapping_agent_started, self()})

      receive do
        message -> send(test_pid, {:trapping_agent_received, message})
      end
    end

    assert {:ok, run_server} =
             RuntimeSupervisor.start_run_server(state(), trapping_agent,
               supervisor: runtime_supervisor,
               task_supervisor: task_supervisor
             )

    assert_receive {:trapping_agent_started, task}
    task_monitor = Process.monitor(task)
    run_monitor = Process.monitor(run_server)

    assert :ok = Task.Supervisor.terminate_child(task_supervisor, task)
    assert_receive {:DOWN, ^task_monitor, :process, ^task, :killed}
    refute_received {:trapping_agent_received, _message}
    assert_receive {:DOWN, ^run_monitor, :process, ^run_server, :normal}

    assert DynamicSupervisor.count_children(runtime_supervisor).active == 0
    assert Task.Supervisor.children(task_supervisor) == []
  end

  test "missing infrastructure is sanitized without starting an Agent function" do
    dead_supervisor = spawn(fn -> receive do: (:stop -> :ok) end)
    test_pid = self()
    monitor = Process.monitor(dead_supervisor)
    send(dead_supervisor, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^dead_supervisor, :normal}

    assert {:error, %Error{reason: :runtime_unavailable, run_id: "run-1"} = error} =
             RuntimeSupervisor.start_run_server(
               state(),
               fn _run_server ->
                 send(test_pid, :unavailable_agent_started)
               end,
               supervisor: dead_supervisor,
               task_supervisor: dead_supervisor
             )

    refute inspect(error) =~ "noproc"
    refute_received :unavailable_agent_started
  end

  test "Agent lifecycle failures cannot enter Task crash logs" do
    failures = [
      fn -> raise "SYNTHETIC_RUNTIME_TASK_SECRET" end,
      fn -> throw("SYNTHETIC_RUNTIME_TASK_SECRET") end,
      fn -> exit("SYNTHETIC_RUNTIME_TASK_SECRET") end
    ]

    Enum.each(failures, fn failure ->
      {:ok, task_supervisor} = Task.Supervisor.start_link()
      {:ok, runtime_supervisor} = RuntimeSupervisor.start_link(name: nil)
      test_pid = self()

      agent = fn _run_server ->
        send(test_pid, {:failing_agent_ready, self()})

        receive do
          :fail -> failure.()
        end
      end

      log =
        capture_log(fn ->
          assert {:ok, run_server} =
                   RuntimeSupervisor.start_run_server(state(), agent,
                     supervisor: runtime_supervisor,
                     task_supervisor: task_supervisor
                   )

          assert_receive {:failing_agent_ready, task}
          monitor = Process.monitor(run_server)
          send(task, :fail)
          assert_receive {:DOWN, ^monitor, :process, ^run_server, :normal}
        end)

      refute log =~ "SYNTHETIC_RUNTIME_TASK_SECRET"
      stop_if_alive(runtime_supervisor)
      stop_if_alive(task_supervisor)
    end)
  end

  test "Fake Workspace remains owner-monitored outside real Workspace supervision" do
    {:ok, workspace_supervisor} = Synapse.Workspace.Supervisor.start_link(name: nil)
    on_exit(fn -> stop_if_alive(workspace_supervisor) end)

    assert {:ok, handle} = Synapse.Workspace.Fake.open([])

    try do
      assert Process.alive?(handle.state)
      assert DynamicSupervisor.count_children(workspace_supervisor).active == 0
    after
      assert :ok = Synapse.Workspace.close(handle)
    end
  end

  defp blocking_agent(test_pid, tag) do
    fn _run_server ->
      send(test_pid, {tag, self()})

      receive do
        :finish -> :ok
      end
    end
  end

  defp state do
    {:ok, state} =
      State.new(
        run_id: "run-1",
        owner: self(),
        run_ref: make_ref(),
        cancel_ref: make_ref(),
        cancellation: atomics(),
        await_state: atomics(),
        event_sink: fn _event -> :ok end
      )

    state
  end

  defp provider_error(operation_id) do
    {:ok, error} =
      Synapse.Provider.Error.new(
        kind: :unavailable,
        message: "Synthetic shutdown Provider",
        retryable: false,
        output_started: false,
        operation_id: operation_id
      )

    error
  end

  defp atomics do
    :atomics.new(1, signed: false)
  end

  defp child_map(supervisor) do
    Map.new(Supervisor.which_children(supervisor), fn {id, pid, _type, _modules} -> {id, pid} end)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp stop_if_alive(process) do
    Supervisor.stop(process)
  catch
    :exit, _reason -> :ok
  end
end
