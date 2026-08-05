defmodule Synapse.Runtime.Phase9Test.Provider do
  @behaviour Synapse.Provider

  alias Synapse.Provider.Event.TextDelta

  @impl true
  def stream(_request, event_sink, context) do
    config = :persistent_term.get({__MODULE__, context.operation_id})
    send(config.test_pid, {:phase9_provider_called, config.label, self()})

    if config.delta_count > 0 do
      Enum.each(1..config.delta_count, fn ordinal ->
        :ok =
          event_sink.(%TextDelta{
            item_id: "phase9-message",
            content_index: 0,
            delta: Integer.to_string(ordinal)
          })
      end)

      send(config.test_pid, {:phase9_deltas_emitted, config.label, self()})
    end

    receive do
      {:release_phase9_provider, label} when label == config.label -> {:ok, config.response}
    end
  end
end

defmodule Synapse.Runtime.Phase9Test.CloseBackend do
  alias Synapse.Workspace.Handle

  def workspace_backend?, do: true

  def open(owner, limits, access, test_pid, mode) do
    backend = spawn(fn -> backend_loop(Process.monitor(owner), owner, test_pid, mode) end)

    %Handle{
      backend: __MODULE__,
      state: backend,
      token: make_ref(),
      limits: limits,
      access: access
    }
  end

  def valid_handle?(%Handle{backend: __MODULE__, state: backend}), do: Process.alive?(backend)

  def close(%Handle{state: backend}) do
    reference = make_ref()
    send(backend, {:phase9_close_mode, self(), reference})

    receive do
      {:phase9_close_mode, ^reference, :malformed} ->
        :malformed

      {:phase9_close_mode, ^reference, :raise} ->
        raise "SYNTHETIC_PHASE9_CLOSE_SECRET"

      {:phase9_close_mode, ^reference, :throw} ->
        throw("SYNTHETIC_PHASE9_CLOSE_SECRET")

      {:phase9_close_mode, ^reference, :exit} ->
        exit("SYNTHETIC_PHASE9_CLOSE_SECRET")

      {:phase9_close_mode, ^reference, :hang} ->
        receive do
          :never -> :ok
        end
    end
  end

  defp backend_loop(monitor, owner, test_pid, mode) do
    receive do
      {:phase9_close_mode, caller, reference} ->
        send(test_pid, {:phase9_close_called, mode, self()})
        send(caller, {:phase9_close_mode, reference, mode})
        backend_loop(monitor, owner, test_pid, mode)

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        :ok
    end
  end
end

defmodule Synapse.Runtime.Phase9Test do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Synapse.Agent.{Error, OperationId, Result}
  alias Synapse.Provider
  alias Synapse.Provider.OutputItem.Message
  alias Synapse.Run.Event.{RunCompleted, RunFailed, RunInterrupted}
  alias Synapse.Run.Request
  alias Synapse.Runtime
  alias Synapse.Runtime.Error, as: RuntimeError
  alias Synapse.Runtime.Phase9Test.CloseBackend
  alias Synapse.Runtime.Phase9Test.Provider, as: TestProvider
  alias Synapse.Runtime.RunServer.State
  alias Synapse.Runtime.RunServer.Message, as: RuntimeMessage
  alias Synapse.Runtime.Supervisor, as: RuntimeSupervisor
  alias Synapse.Tool.CapabilitySet
  alias Synapse.Workspace
  alias Synapse.Workspace.{Access, Limits, OpenRequest, OperationContext, ProcessSpec}

  @race_iterations 12

  test "cancel versus completion and await timeout versus terminal remain linearizable" do
    Enum.each(1..@race_iterations, fn iteration ->
      test_pid = self()
      label = {:cancel_completion, iteration}
      request = request("phase9-cancel-completion-#{iteration}")
      configure_provider(request, label)
      sink = terminal_sink(self(), label)
      assert {:ok, run} = start_run(request, sink)
      register_cleanup(run)
      assert_receive {:phase9_provider_called, ^label, task}
      assert task == run.task

      cancel_caller =
        spawn(fn ->
          receive do
            :race -> send(test_pid, {:phase9_cancel_result, label, Runtime.cancel(run)})
          end
        end)

      send(cancel_caller, :race)
      send(task, {:release_phase9_provider, label})

      assert_receive {:phase9_cancel_result, ^label, :ok}

      assert terminal = Runtime.await(run, :infinity)

      assert match?({:ok, %Result{}}, terminal) or
               match?({:error, %Error{reason: :run_cancelled}}, terminal)

      assert_receive {:phase9_terminal, ^label, event}
      assert event.__struct__ in [RunCompleted, RunInterrupted]
      refute_received {:phase9_terminal, ^label, _duplicate}
      assert_settled(run)
    end)

    Enum.each(1..@race_iterations, fn iteration ->
      label = {:await_terminal, iteration}
      request = request("phase9-await-terminal-#{iteration}")
      configure_provider(request, label)
      assert {:ok, run} = start_run(request, terminal_sink(self(), label))
      register_cleanup(run)
      assert_receive {:phase9_provider_called, ^label, task}
      send(task, {:release_phase9_provider, label})

      terminal =
        case Runtime.await(run, 0) do
          {:error, :await_timeout} -> Runtime.await(run, :infinity)
          terminal -> terminal
        end

      assert {:ok, %Result{}} = terminal
      assert_receive {:phase9_terminal, ^label, %RunCompleted{}}
      refute_received {:phase9_terminal, ^label, _duplicate}
      assert_settled(run)
    end)
  end

  test "task kill versus Workspace owner cleanup settles repeatedly without restart" do
    Enum.each(1..@race_iterations, fn iteration ->
      label = {:crash_cleanup, iteration}
      request = request("phase9-crash-cleanup-#{iteration}")
      configure_provider(request, label)
      test_pid = self()

      opener = fn open_request ->
        {:ok, handle} =
          Workspace.Fake.open([],
            owner: open_request.owner,
            limits: open_request.limits,
            access: open_request.access
          )

        send(test_pid, {:phase9_workspace_opened, label, handle.state})
        {:ok, handle}
      end

      assert {:ok, run} =
               Runtime.start_run(request, terminal_sink(test_pid, label),
                 provider: TestProvider,
                 workspace_opener: opener
               )

      register_cleanup(run)
      assert_receive {:phase9_workspace_opened, ^label, backend}
      assert_receive {:phase9_provider_called, ^label, task}
      backend_monitor = Process.monitor(backend)
      Process.exit(task, :kill)

      assert {:error, %Error{reason: :run_worker_crashed}} = Runtime.await(run, :infinity)
      assert_receive {:DOWN, ^backend_monitor, :process, ^backend, _reason}
      assert_receive {:phase9_terminal, ^label, %RunFailed{}}
      refute_received {:phase9_provider_called, ^label, _replacement}
      assert_settled(run)
    end)
  end

  test "stale handles and stale handshake messages cannot control a later run" do
    first_label = :stale_first
    first_request = request("phase9-stale-first")
    configure_provider(first_request, first_label)
    assert {:ok, first} = start_run(first_request, terminal_sink(self(), first_label))
    register_cleanup(first)
    assert_receive {:phase9_provider_called, ^first_label, first_task}
    send(first_task, {:release_phase9_provider, first_label})
    assert {:ok, %Result{}} = Runtime.await(first, :infinity)
    assert_receive {:phase9_terminal, ^first_label, %RunCompleted{}}

    {:ok, stale_started} = RuntimeMessage.started(first.run_ref, first.task, first.server)
    send(self(), stale_started)

    second_label = :stale_second
    second_request = request("phase9-stale-second")
    configure_provider(second_request, second_label)
    assert {:ok, second} = start_run(second_request, terminal_sink(self(), second_label))
    register_cleanup(second)
    assert_receive {:phase9_provider_called, ^second_label, second_task}
    assert second_task == second.task
    assert :atomics.get(second.cancellation, 1) == 0
    assert :ok = Runtime.cancel(first)
    assert :atomics.get(second.cancellation, 1) == 0
    assert_received ^stale_started

    send(second_task, {:release_phase9_provider, second_label})
    assert {:ok, %Result{}} = Runtime.await(second, :infinity)
    assert_receive {:phase9_terminal, ^second_label, %RunCompleted{}}
    assert_settled(second)
  end

  test "RunServer tracking stays fixed while accepting many text deltas" do
    label = :bounded_deltas
    request = request("phase9-bounded-deltas")
    counter = :atomics.new(1, signed: false)
    configure_provider(request, label, delta_count: 1_000)

    sink = fn event ->
      if match?(%Synapse.Run.Event.TextDelta{}, event), do: :atomics.add(counter, 1, 1)
      :ok
    end

    assert {:ok, run} = start_run(request, sink)
    register_cleanup(run)
    assert_receive {:phase9_provider_called, ^label, task}
    assert_receive {:phase9_deltas_emitted, ^label, ^task}
    state = :sys.get_state(run.server)
    assert state.visible_output?
    refute Map.has_key?(Map.from_struct(state), :events)
    refute Map.has_key?(Map.from_struct(state), :text_deltas)
    assert :atomics.get(counter, 1) == 1_000
    send(task, {:release_phase9_provider, label})
    assert {:ok, %Result{}} = Runtime.await(run, :infinity)
    assert_settled(run)
  end

  test "control cells have no retained owner after the handle process exits" do
    label = :collectible_controls
    request = request("phase9-collectible-controls")
    configure_provider(request, label)
    test_pid = self()

    owner =
      spawn(fn ->
        {:ok, run} = start_run(request, terminal_sink(test_pid, label))
        terminal = Runtime.await(run, :infinity)
        send(test_pid, {:phase9_owner_terminal, terminal})
      end)

    owner_monitor = Process.monitor(owner)
    assert_receive {:phase9_provider_called, ^label, task}
    send(task, {:release_phase9_provider, label})
    assert_receive {:phase9_owner_terminal, {:ok, %Result{}}}
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}
    assert_receive {:phase9_terminal, ^label, %RunCompleted{}}
    assert Task.Supervisor.children(Synapse.TaskSupervisor) == []
    assert DynamicSupervisor.count_children(Synapse.Runtime.Supervisor).active == 0
  end

  test "malformed and crashing Workspace close callbacks become sanitized close failure" do
    Enum.each([:malformed, :raise, :throw, :exit], fn mode ->
      label = {:close_failure, mode}
      request = request("phase9-close-#{mode}")
      configure_provider(request, label)
      test_pid = self()

      opener = fn open_request ->
        handle =
          CloseBackend.open(
            open_request.owner,
            open_request.limits,
            open_request.access,
            test_pid,
            mode
          )

        send(test_pid, {:phase9_close_backend, mode, handle.state})
        {:ok, handle}
      end

      log =
        capture_log(fn ->
          assert {:ok, run} =
                   Runtime.start_run(request, terminal_sink(test_pid, label),
                     provider: TestProvider,
                     workspace_opener: opener
                   )

          register_cleanup(run)
          assert_receive {:phase9_close_backend, ^mode, backend}
          backend_monitor = Process.monitor(backend)
          assert_receive {:phase9_provider_called, ^label, task}
          send(task, {:release_phase9_provider, label})
          assert_receive {:phase9_close_called, ^mode, ^backend}

          assert {:error, %Error{kind: :internal, reason: :workspace_close_failed} = error} =
                   Runtime.await(run, :infinity)

          assert error.details == %{}
          refute inspect(error) =~ "SYNTHETIC_PHASE9_CLOSE_SECRET"
          assert_receive {:DOWN, ^backend_monitor, :process, ^backend, _reason}
          assert_receive {:phase9_terminal, ^label, %RunFailed{}}
          assert_settled(run)
        end)

      refute log =~ "SYNTHETIC_PHASE9_CLOSE_SECRET"
    end)
  end

  test "a hung trusted close is recoverable through forced Agent death without replay" do
    label = :hung_close
    request = request("phase9-hung-close")
    configure_provider(request, label)
    test_pid = self()

    opener = fn open_request ->
      handle =
        CloseBackend.open(
          open_request.owner,
          open_request.limits,
          open_request.access,
          test_pid,
          :hang
        )

      send(test_pid, {:phase9_close_backend, :hang, handle.state})
      {:ok, handle}
    end

    assert {:ok, run} =
             Runtime.start_run(request, terminal_sink(test_pid, label),
               provider: TestProvider,
               workspace_opener: opener
             )

    register_cleanup(run)
    assert_receive {:phase9_close_backend, :hang, backend}
    backend_monitor = Process.monitor(backend)
    assert_receive {:phase9_provider_called, ^label, task}
    send(task, {:release_phase9_provider, label})
    assert_receive {:phase9_close_called, :hang, ^backend}
    Process.exit(task, :kill)

    assert {:ok, %Result{}} = Runtime.await(run, :infinity)
    assert_receive {:DOWN, ^backend_monitor, :process, ^backend, _reason}
    assert_receive {:phase9_terminal, ^label, %RunCompleted{}}
    refute_received {:phase9_provider_called, ^label, _replacement}
    assert_settled(run)
  end

  test "unavailable TaskSupervisor and Workspace Supervisor are sanitized" do
    {:ok, runtime_supervisor} = RuntimeSupervisor.start_link(name: nil)
    on_exit(fn -> stop_supervisor(runtime_supervisor) end)
    dead_supervisor = dead_process()
    test_pid = self()

    assert {:error, %RuntimeError{reason: :runtime_unavailable}} =
             RuntimeSupervisor.start_run_server(
               run_server_state(),
               fn _server -> send(test_pid, :phase9_unavailable_agent_started) end,
               supervisor: runtime_supervisor,
               task_supervisor: dead_supervisor
             )

    refute_received :phase9_unavailable_agent_started

    if Synapse.Workspace.Platform.supported?() do
      root = temporary_root()
      File.mkdir!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      request = request("phase9-workspace-supervisor", root)
      configure_provider(request, :workspace_supervisor)

      opener = fn open_request ->
        Synapse.Workspace.Real.open(open_request, dead_supervisor)
      end

      assert {:error, %RuntimeError{reason: :workspace_open_failed}} =
               Runtime.start_run(request, fn _event -> :ok end,
                 provider: TestProvider,
                 workspace_opener: opener
               )

      refute_received {:phase9_provider_called, :workspace_supervisor, _task}
      assert Task.Supervisor.children(Synapse.TaskSupervisor) == []
      assert DynamicSupervisor.count_children(Synapse.Runtime.Supervisor).active == 0
    end
  end

  @tag skip: not Synapse.Workspace.Platform.supported?()
  test "application stop during a Real command removes every directly owned process" do
    root = temporary_root()
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, application_root} =
      Synapse.Supervisor.start_link(
        name: nil,
        workspace_supervisor: nil,
        task_supervisor: nil,
        runtime_supervisor: nil
      )

    on_exit(fn -> stop_supervisor(application_root) end)
    children = supervisor_children(application_root)
    workspace_supervisor = children[Synapse.Workspace.Supervisor]
    task_supervisor = children[Synapse.TaskSupervisor]
    runtime_supervisor = children[Synapse.Runtime.Supervisor]
    state = run_server_state()
    test_pid = self()

    agent = fn run_server ->
      {:ok, open_request} =
        OpenRequest.new(
          root: root,
          owner: self(),
          limits: Limits.default(),
          access: %Access{read: true, write: true, exec: true}
        )

      {:ok, handle} = Synapse.Workspace.Real.open(open_request, workspace_supervisor)
      environment = :sys.get_state(handle.state).process_environment
      send(test_pid, {:phase9_real_shutdown_open, self(), handle.state, environment})
      {:ok, ready} = RuntimeMessage.ready(state.run_ref, self(), handle)
      send(run_server, ready)

      receive do
        %RuntimeMessage{kind: :accept, run_ref: run_ref} when run_ref == state.run_ref -> :ok
      end

      operation_id = "phase9-application-stop-command"

      {:ok, context} =
        OperationContext.new(
          operation_id: operation_id,
          access: %Access{read: false, write: false, exec: true},
          deadline: System.monotonic_time(:millisecond) + 60_000
        )

      command =
        "printf '%s' $$ > shutdown.pid; printf ready; " <>
          "trap '' TERM; while :; do :; done"

      {:ok, spec} =
        ProcessSpec.new(
          executable: "/bin/bash",
          arguments: ["-lc", command],
          cwd: ".",
          inactivity_ms: 60_000,
          timeout_ms: 60_000,
          max_output_bytes: Limits.default().default_process_output_bytes,
          mutation: :unknown
        )

      result =
        Workspace.run(
          handle,
          spec,
          fn event ->
            send(test_pid, {:phase9_real_shutdown_event, event})
            :ok
          end,
          context
        )

      send(test_pid, {:phase9_real_shutdown_result, result})
      result
    end

    assert {:ok, run_server} =
             RuntimeSupervisor.start_run_server(state, agent,
               supervisor: runtime_supervisor,
               task_supervisor: task_supervisor
             )

    assert_receive {:phase9_real_shutdown_open, task, backend, environment}
    assert_receive %RuntimeMessage{kind: :started, worker: ^task, payload: ^run_server}

    receive do
      {:phase9_real_shutdown_event, %Synapse.Workspace.ProcessEvent.Started{}} ->
        :ok

      {:phase9_real_shutdown_result, result} ->
        flunk("Real shutdown command ended early: #{inspect(result)}")
    after
      5_000 -> flunk("Real shutdown command did not start")
    end

    command_pid = await_pid_file(Path.join(root, "shutdown.pid"))

    run_monitor = Process.monitor(run_server)
    task_monitor = Process.monitor(task)
    backend_monitor = Process.monitor(backend)
    guard_monitor = Process.monitor(environment.guard)
    assert :ok = Supervisor.stop(application_root)
    assert_receive {:DOWN, ^run_monitor, :process, ^run_server, :shutdown}
    assert_receive {:DOWN, ^task_monitor, :process, ^task, :killed}
    assert_receive {:DOWN, ^backend_monitor, :process, ^backend, _reason}
    assert_receive {:DOWN, ^guard_monitor, :process, _guard, _reason}
    refute os_process_alive?(command_pid)
    refute File.exists?(environment.root)
  end

  test "Runtime structs and source retain only bounded intentional authority" do
    {:ok, options} = Synapse.Runtime.Options.new(provider: TestProvider)
    option_fields = options |> Map.from_struct() |> Map.keys()
    run_fields = run_field_names()
    state_fields = State.__struct__() |> Map.from_struct() |> Map.keys()
    message_fields = RuntimeMessage.__struct__() |> Map.from_struct() |> Map.keys()
    {:ok, runtime_error} = Synapse.Runtime.Error.new(reason: :runtime_lost, run_id: "phase9")

    forbidden = ~w(prompt cwd root credential credentials api_key header headers command output
                   workspace handle request exception exit_reason stacktrace)a

    Enum.each(
      [
        option_fields,
        run_fields,
        state_fields,
        message_fields,
        Map.keys(Map.from_struct(runtime_error))
      ],
      fn fields -> refute Enum.any?(forbidden, &(&1 in fields)) end
    )

    assert Enum.sort(run_fields) ==
             Enum.sort(~w(id owner server task run_ref cancel_ref cancellation await_state)a)

    source = runtime_source()
    refute source =~ "Logger."
    refute source =~ "Exception.message"
    refute source =~ "Exception.format"
    refute source =~ "System.get_env"
    refute source =~ ":persistent_term"
    refute source =~ ":ets."
    refute source =~ "Registry."

    request_fields = request("phase9-security-request") |> Map.from_struct() |> Map.keys()

    refute Enum.any?(
             ~w(provider workspace_opener retry_delay event_sink supervisor task_supervisor
                cancel_ref cancellation)a,
             &(&1 in request_fields)
           )

    assert options.workspace_limits == Synapse.Workspace.Limits.default()
    assert options.tool_limits == Synapse.Tool.Limits.default()
  end

  defp configure_provider(request, label, options \\ []) do
    {:ok, operation_id} = OperationId.provider(request.id, 1, 1)

    :persistent_term.put(
      {TestProvider, operation_id},
      %{
        test_pid: self(),
        label: label,
        delta_count: Keyword.get(options, :delta_count, 0),
        response: response(request)
      }
    )

    on_exit(fn -> :persistent_term.erase({TestProvider, operation_id}) end)
  end

  defp start_run(request, sink) do
    Runtime.start_run(request, sink,
      provider: TestProvider,
      workspace_opener: fake_opener()
    )
  end

  defp fake_opener do
    fn open_request ->
      Workspace.Fake.open([],
        owner: open_request.owner,
        limits: open_request.limits,
        access: open_request.access
      )
    end
  end

  defp terminal_sink(test_pid, label) do
    fn event ->
      if match?(%RunCompleted{}, event) or match?(%RunFailed{}, event) or
           match?(%RunInterrupted{}, event),
         do: send(test_pid, {:phase9_terminal, label, event})

      :ok
    end
  end

  defp request(id, root \\ "/synthetic/phase9/SECRET_ROOT") do
    {:ok, capabilities} =
      CapabilitySet.new(fs_read: true, fs_write: true, process_exec: true)

    {:ok, request} =
      Request.new(
        id: id,
        prompt: "SYNTHETIC_PHASE9_PROMPT_SECRET",
        cwd: root,
        model: "phase9-model",
        capabilities: capabilities,
        budget: Synapse.Budget.default()
      )

    request
  end

  defp response(request) do
    {:ok, response} =
      Provider.Response.new(
        id: "response-#{request.id}",
        model: request.model,
        output_items: [
          %Message{id: "message-#{request.id}", role: :assistant, content: "finished"}
        ]
      )

    response
  end

  defp assert_settled(run) do
    run_ref = run.run_ref
    refute Process.alive?(run.server)
    refute Process.alive?(run.task)
    assert Task.Supervisor.children(Synapse.TaskSupervisor) == []
    assert DynamicSupervisor.count_children(Synapse.Runtime.Supervisor).active == 0
    {:monitors, monitors} = Process.info(self(), :monitors)
    refute {:process, run.server} in monitors
    refute {:process, run.task} in monitors
    refute_received %RuntimeMessage{run_ref: ^run_ref}
  end

  defp register_cleanup(run) do
    on_exit(fn ->
      if Process.alive?(run.server), do: Process.exit(run.server, :kill)
    end)
  end

  defp run_field_names do
    Synapse.Runtime.Run.__struct__() |> Map.from_struct() |> Map.keys()
  end

  defp runtime_source do
    sources =
      [Path.join([__DIR__, "..", "lib", "synapse", "runtime.ex"])] ++
        Path.wildcard(Path.join([__DIR__, "..", "lib", "synapse", "runtime", "*.ex"]))

    sources |> Enum.map(&File.read!/1) |> Enum.join("\n")
  end

  defp run_server_state do
    cancellation = :atomics.new(1, signed: false)
    await_state = :atomics.new(1, signed: false)

    {:ok, state} =
      State.new(
        run_id: "phase9-unavailable-task-supervisor",
        owner: self(),
        run_ref: make_ref(),
        cancel_ref: make_ref(),
        cancellation: cancellation,
        await_state: await_state,
        event_sink: fn _event -> :ok end
      )

    state
  end

  defp dead_process do
    process = spawn(fn -> :ok end)
    monitor = Process.monitor(process)
    assert_receive {:DOWN, ^monitor, :process, ^process, _reason}
    process
  end

  defp temporary_root do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    Path.join(System.tmp_dir!(), "synapse-runtime-phase9-#{suffix}")
  end

  defp stop_supervisor(supervisor) do
    if Process.alive?(supervisor), do: Supervisor.stop(supervisor)
  catch
    :exit, _reason -> :ok
  end

  defp supervisor_children(supervisor) do
    Map.new(Supervisor.which_children(supervisor), fn {id, pid, _type, _modules} -> {id, pid} end)
  end

  defp await_pid_file(path, attempts \\ 200)
  defp await_pid_file(_path, 0), do: flunk("Real shutdown command did not publish its PID")

  defp await_pid_file(path, attempts) do
    case File.read(path) do
      {:ok, contents} ->
        String.trim(contents)

      {:error, :enoent} ->
        Process.sleep(10)
        await_pid_file(path, attempts - 1)
    end
  end

  defp os_process_alive?(pid) do
    case System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end
end
