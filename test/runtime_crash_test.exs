defmodule Synapse.Runtime.CrashTest.Provider do
  @behaviour Synapse.Provider

  alias Synapse.Provider.Event.TextDelta

  @impl true
  def stream(_request, event_sink, context) do
    config = :persistent_term.get({__MODULE__, context.operation_id})
    send(config.test_pid, {:crash_provider_called, config.label, self()})

    case config.mode do
      :raise ->
        raise "SYNTHETIC_RUNTIME_CRASH_SECRET"

      :throw ->
        throw("SYNTHETIC_RUNTIME_CRASH_SECRET")

      :exit ->
        exit("SYNTHETIC_RUNTIME_CRASH_SECRET")

      :visible_then_raise ->
        :ok =
          event_sink.(%TextDelta{
            item_id: "crash-message",
            content_index: 0,
            delta: "visible output"
          })

        raise "SYNTHETIC_RUNTIME_CRASH_SECRET"

      :block ->
        receive do
          :unexpected_release -> {:error, :malformed_provider_result}
        end
    end
  end
end

defmodule Synapse.Runtime.CrashTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Synapse.Agent.{Error, OperationId}
  alias Synapse.Budget
  alias Synapse.Run.Event.{RunFailed, RunInterrupted, TurnCompleted}
  alias Synapse.Run.Request
  alias Synapse.Runtime
  alias Synapse.Runtime.CrashTest.Provider, as: TestProvider
  alias Synapse.Tool.CapabilitySet
  alias Synapse.Workspace

  test "Provider raise, throw, and exit become sanitized failed terminals without restart" do
    Enum.each([:raise, :throw, :exit], fn mode ->
      label = "provider-#{mode}"
      request = run_request("runtime-crash-#{mode}")
      configure_provider(request, label, mode)

      log =
        capture_log(fn ->
          assert {:ok, run} = start_run(request, event_sink(self(), label))
          register_cleanup(run)
          assert_receive {:crash_provider_called, ^label, task}
          assert task == run.task

          assert {:error, %Error{kind: :internal, reason: :run_worker_crashed} = error} =
                   Runtime.await(run, :infinity)

          assert error.details == %{}
          refute inspect(error) =~ "SYNTHETIC_RUNTIME_CRASH_SECRET"
          assert_receive {:phase6_event, ^label, %RunFailed{}}
          refute_received {:phase6_event, ^label, %RunInterrupted{}}
          assert_settled_without_restart(run, label)
        end)

      refute log =~ "SYNTHETIC_RUNTIME_CRASH_SECRET"
    end)
  end

  test "a Provider crash after accepted visible output is interrupted without invented counters" do
    label = "visible-provider-crash"
    request = run_request("runtime-crash-visible")
    configure_provider(request, label, :visible_then_raise)

    assert {:ok, run} = start_run(request, event_sink(self(), label))
    register_cleanup(run)
    assert_receive {:crash_provider_called, ^label, task}
    assert task == run.task

    assert {:error, %Error{kind: :internal, reason: :run_worker_crashed}} =
             Runtime.await(run, :infinity)

    events = drain_events(label)
    assert Enum.any?(events, &match?(%RunInterrupted{}, &1))
    refute Enum.any?(events, &match?(%RunFailed{}, &1))
    refute Enum.any?(events, &match?(%TurnCompleted{}, &1))
    assert_settled_without_restart(run, label)
  end

  test "an uncatchable Agent kill uses RunServer state and waits for Workspace owner cleanup" do
    label = "uncatchable-kill"
    request = run_request("runtime-crash-kill")
    configure_provider(request, label, :block)
    test_pid = self()

    opener = fn open_request ->
      {:ok, handle} =
        Workspace.Fake.open([],
          owner: open_request.owner,
          limits: open_request.limits,
          access: open_request.access
        )

      send(test_pid, {:phase6_workspace_opened, handle.state})
      {:ok, handle}
    end

    sink = fn event ->
      backend = :persistent_term.get({__MODULE__, :kill_backend}, nil)

      if match?(%RunFailed{}, event) do
        send(test_pid, {:kill_terminal_observed, event, process_alive?(backend)})
      else
        send(test_pid, {:phase6_event, label, event})
      end

      :ok
    end

    assert {:ok, run} =
             Runtime.start_run(request, sink,
               provider: TestProvider,
               workspace_opener: opener
             )

    register_cleanup(run)
    assert_receive {:phase6_workspace_opened, backend}
    :persistent_term.put({__MODULE__, :kill_backend}, backend)
    on_exit(fn -> :persistent_term.erase({__MODULE__, :kill_backend}) end)
    assert_receive {:crash_provider_called, ^label, task}
    assert task == run.task

    backend_monitor = Process.monitor(backend)
    Process.exit(task, :kill)

    assert {:error, %Error{kind: :internal, reason: :run_worker_crashed}} =
             Runtime.await(run, :infinity)

    assert_receive {:DOWN, ^backend_monitor, :process, ^backend, _reason}
    assert_receive {:kill_terminal_observed, %RunFailed{}, false}
    assert_settled_without_restart(run, label)
  end

  defp configure_provider(request, label, mode) do
    {:ok, operation_id} = OperationId.provider(request.id, 1, 1)

    :persistent_term.put(
      {TestProvider, operation_id},
      %{test_pid: self(), label: label, mode: mode}
    )

    on_exit(fn -> :persistent_term.erase({TestProvider, operation_id}) end)
  end

  defp start_run(request, sink) do
    Runtime.start_run(request, sink,
      provider: TestProvider,
      workspace_opener: fake_opener()
    )
  end

  defp run_request(id) do
    {:ok, capabilities} =
      CapabilitySet.new(fs_read: true, fs_write: true, process_exec: true)

    {:ok, request} =
      Request.new(
        id: id,
        prompt: "Exercise conservative Runtime crash conversion",
        cwd: "/synthetic/runtime/crash",
        model: "runtime-crash-model",
        capabilities: capabilities,
        budget: Budget.default()
      )

    request
  end

  defp event_sink(test_pid, label) do
    fn event ->
      send(test_pid, {:phase6_event, label, event})
      :ok
    end
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

  defp drain_events(label, events \\ []) do
    receive do
      {:phase6_event, ^label, event} -> drain_events(label, [event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp assert_settled_without_restart(run, label) do
    refute Process.alive?(run.server)
    refute Process.alive?(run.task)
    refute_received {:crash_provider_called, ^label, _replacement_task}
    assert Task.Supervisor.children(Synapse.TaskSupervisor) == []
    assert DynamicSupervisor.count_children(Synapse.Runtime.Supervisor).active == 0
  end

  defp process_alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp process_alive?(_pid), do: false

  defp register_cleanup(run) do
    on_exit(fn ->
      if Process.alive?(run.server), do: Process.exit(run.server, :kill)
    end)
  end
end
