defmodule Synapse.Runtime.AwaitTest.Provider do
  @behaviour Synapse.Provider

  alias Synapse.Provider
  alias Synapse.Provider.Event.TextDelta

  @impl true
  def stream(_request, event_sink, context) do
    config = :persistent_term.get({__MODULE__, context.operation_id})
    send(config.test_pid, {:await_provider_called, self(), context})

    if config.block? do
      receive do
        {:release_await_provider, operation_id} when operation_id == context.operation_id -> :ok
      end
    end

    case config.mode do
      :success ->
        {:ok, config.response}

      :failure ->
        {:error, provider_error(context.operation_id, false)}

      :interrupted ->
        :ok =
          event_sink.(%TextDelta{
            item_id: "await-message",
            content_index: 0,
            delta: "visible"
          })

        {:error, provider_error(context.operation_id, true)}
    end
  end

  defp provider_error(operation_id, output_started) do
    {:ok, error} =
      Provider.Error.new(
        kind: if(output_started, do: :protocol, else: :unavailable),
        message: "Provider request failed",
        retryable: false,
        output_started: output_started,
        operation_id: operation_id
      )

    error
  end
end

defmodule Synapse.Runtime.AwaitTest.CloseFailBackend do
  alias Synapse.Workspace.{Error, Handle}

  def workspace_backend?, do: true

  def open(owner, limits, access, test_pid) do
    backend =
      spawn(fn ->
        monitor = Process.monitor(owner)

        receive do
          {:DOWN, ^monitor, :process, ^owner, _reason} ->
            send(test_pid, {:await_close_owner_down, self()})

            receive do
              :finish_await_close_cleanup -> :ok
            end
        end
      end)

    %Handle{
      backend: __MODULE__,
      state: backend,
      token: make_ref(),
      limits: limits,
      access: access
    }
  end

  def valid_handle?(%Handle{backend: __MODULE__, state: backend}),
    do: Process.alive?(backend)

  def close(%Handle{}) do
    {:ok, error} =
      Error.new(
        kind: :unavailable,
        reason: :backend_unavailable,
        operation: :close,
        message: "Workspace backend is unavailable",
        outcome: :not_applicable
      )

    {:error, error}
  end
end

defmodule Synapse.Runtime.AwaitTest.ReferenceBackend do
  alias Synapse.Workspace.Handle

  def workspace_backend?, do: true

  def open(limits, access) do
    %Handle{
      backend: __MODULE__,
      state: make_ref(),
      token: make_ref(),
      limits: limits,
      access: access
    }
  end

  def valid_handle?(%Handle{backend: __MODULE__, state: state}), do: is_reference(state)
  def close(%Handle{}), do: :ok
end

defmodule Synapse.Runtime.AwaitTest do
  use ExUnit.Case, async: false

  alias Synapse.Agent.{Error, OperationId, Result}
  alias Synapse.Budget
  alias Synapse.Provider
  alias Synapse.Provider.OutputItem.Message, as: ProviderMessage
  alias Synapse.Run.Event.{RunCompleted, RunFailed, RunInterrupted}
  alias Synapse.Run.Request
  alias Synapse.Runtime
  alias Synapse.Runtime.AwaitTest.CloseFailBackend
  alias Synapse.Runtime.AwaitTest.Provider, as: TestProvider
  alias Synapse.Runtime.AwaitTest.ReferenceBackend
  alias Synapse.Runtime.Error, as: RuntimeError
  alias Synapse.Runtime.{Run, RunServer}
  alias Synapse.Runtime.RunServer.{Message, State}
  alias Synapse.Runtime.Supervisor, as: RuntimeSupervisor
  alias Synapse.Tool.CapabilitySet
  alias Synapse.Workspace
  alias Synapse.Workspace.{Access, Limits}

  test "await timeout preserves the right and later success follows Task and Workspace cleanup" do
    test_pid = self()
    request = run_request("await-success")
    run_id = request.id
    operation_id = configure_provider(request, :success, true)

    opener = capturing_opener(test_pid)

    # Sink runs in RunServer, so use persistent test-only process identities.
    sink = terminal_observing_sink(test_pid)

    assert {:ok, run} =
             Runtime.start_run(request, sink,
               provider: TestProvider,
               workspace_opener: opener
             )

    register_cleanup(run, operation_id)
    assert_receive {:await_workspace_opened, task, backend}
    assert task == run.task
    configure_terminal_observer(run.server, task, backend)
    assert_receive {:await_provider_called, ^task, _context}

    non_owner =
      spawn(fn ->
        receive do
          :await -> send(test_pid, {:non_owner_await, Runtime.await(run, 0)})
        end
      end)

    non_owner_monitor = Process.monitor(non_owner)
    send(non_owner, :await)
    assert_receive {:non_owner_await, {:error, :not_owner}}
    assert_receive {:DOWN, ^non_owner_monitor, :process, ^non_owner, :normal}
    assert :atomics.get(run.await_state, 1) == 0

    assert {:error, :await_timeout} = Runtime.await(run, 0)
    assert :atomics.get(run.await_state, 1) == 0
    assert Process.alive?(task)
    assert Process.alive?(run.server)
    assert Process.alive?(backend)

    send(task, {:release_await_provider, operation_id})
    assert {:ok, %Result{run_id: ^run_id}} = Runtime.await(run, :infinity)
    assert :atomics.get(run.await_state, 1) == 2
    refute Process.alive?(run.server)
    refute Process.alive?(task)
    refute Process.alive?(backend)

    assert_receive {:await_terminal_observed, %RunCompleted{}, false, false}
    assert {:error, :already_awaited} = Runtime.await(run, 0)
  end

  test "Agent failure and interruption publish matching terminals after cleanup" do
    Enum.each(
      [
        {:failure, RunFailed, :provider_failed},
        {:interrupted, RunInterrupted, :provider_interrupted_after_output}
      ],
      fn
        {mode, event_module, reason} ->
          test_pid = self()
          request = run_request("await-#{mode}")
          operation_id = configure_provider(request, mode, true)
          opener = capturing_opener(test_pid)
          sink = terminal_observing_sink(test_pid)

          assert {:ok, run} =
                   Runtime.start_run(request, sink,
                     provider: TestProvider,
                     workspace_opener: opener
                   )

          register_cleanup(run, operation_id)
          assert_receive {:await_workspace_opened, task, backend}
          configure_terminal_observer(run.server, task, backend)
          assert_receive {:await_provider_called, ^task, _context}
          send(task, {:release_await_provider, operation_id})

          assert {:error, %Error{reason: ^reason}} = Runtime.await(run, :infinity)
          assert_receive {:await_terminal_observed, terminal, false, false}
          assert terminal.__struct__ == event_module
      end
    )
  end

  test "await owner death does not cancel cleanup or terminal publication" do
    test_pid = self()
    request = run_request("await-owner-death")
    operation_id = configure_provider(request, :success, true)
    opener = capturing_opener(test_pid)
    sink = terminal_observing_sink(test_pid)

    owner =
      spawn(fn ->
        {:ok, run} =
          Runtime.start_run(request, sink,
            provider: TestProvider,
            workspace_opener: opener
          )

        send(test_pid, {:owner_started_run, run})
      end)

    owner_monitor = Process.monitor(owner)
    assert_receive {:owner_started_run, run}
    assert_receive {:await_workspace_opened, task, backend}
    configure_terminal_observer(run.server, task, backend)
    assert_receive {:await_provider_called, ^task, _context}
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}

    task_monitor = Process.monitor(task)
    server_monitor = Process.monitor(run.server)
    backend_monitor = Process.monitor(backend)
    send(task, {:release_await_provider, operation_id})

    assert_receive {:await_terminal_observed, %RunCompleted{}, false, false}
    assert_receive {:DOWN, ^backend_monitor, :process, ^backend, _reason}
    assert_receive {:DOWN, ^task_monitor, :process, ^task, :normal}
    assert_receive {:DOWN, ^server_monitor, :process, _, :normal}
  end

  test "RunServer loss returns runtime_lost without claiming a terminal event" do
    test_pid = self()
    request = run_request("await-runtime-lost")
    operation_id = configure_provider(request, :success, true)
    opener = capturing_opener(test_pid)

    sink = fn event ->
      if match?(%RunCompleted{}, event) or match?(%RunFailed{}, event) or
           match?(%RunInterrupted{}, event),
         do: send(test_pid, {:unexpected_lost_terminal, event})

      :ok
    end

    assert {:ok, run} =
             Runtime.start_run(request, sink,
               provider: TestProvider,
               workspace_opener: opener
             )

    assert_receive {:await_workspace_opened, task, backend}
    assert_receive {:await_provider_called, ^task, _context}
    task_monitor = Process.monitor(task)
    backend_monitor = Process.monitor(backend)
    Process.exit(run.server, :kill)

    assert {:error, %RuntimeError{reason: :runtime_lost}} = Runtime.await(run, :infinity)
    assert_receive {:DOWN, ^task_monitor, :process, ^task, _reason}
    assert_receive {:DOWN, ^backend_monitor, :process, ^backend, _reason}
    refute_received {:unexpected_lost_terminal, _event}
    send(task, {:release_await_provider, operation_id})
  end

  test "Runtime rejects reference-backed Workspace handles it cannot monitor for settlement" do
    request = run_request("await-reference-workspace")

    opener = fn open_request ->
      {:ok, ReferenceBackend.open(open_request.limits, open_request.access)}
    end

    assert {:error, %RuntimeError{reason: :workspace_open_failed}} =
             Runtime.start_run(request, fn _event -> :ok end,
               provider: TestProvider,
               workspace_opener: opener
             )

    assert DynamicSupervisor.count_children(Synapse.Runtime.Supervisor).active == 0
  end

  test "RunServer directly aborts a structurally valid reference-backed ready Handle" do
    {:ok, task_supervisor} = Task.Supervisor.start_link()
    {:ok, runtime_supervisor} = RuntimeSupervisor.start_link(name: nil)
    controls = controls()

    {:ok, state} =
      State.new(
        run_id: "await-reference-ready",
        owner: self(),
        run_ref: controls.run_ref,
        cancel_ref: controls.cancel_ref,
        cancellation: controls.cancellation,
        await_state: controls.await_state,
        event_sink: fn _event -> :ok end
      )

    agent = fn run_server ->
      {:ok, access} = Access.new(read: true, write: true, exec: true)
      handle = ReferenceBackend.open(Limits.default(), access)
      {:ok, ready} = Message.ready(state.run_ref, self(), handle)
      send(run_server, ready)

      receive do
        %Message{kind: :abort, run_ref: run_ref} when run_ref == state.run_ref -> :ok
      end

      :ok = Workspace.close(handle)
      :startup_aborted
    end

    assert {:ok, server} =
             RuntimeSupervisor.start_run_server(state, agent,
               supervisor: runtime_supervisor,
               task_supervisor: task_supervisor
             )

    monitor = Process.monitor(server)

    assert_receive %Message{
      kind: :start_failed,
      run_ref: run_ref,
      payload: {^server, :workspace_open_failed}
    }

    assert run_ref == state.run_ref
    assert_receive {:DOWN, ^monitor, :process, ^server, :normal}
    stop_supervisor(runtime_supervisor)
    stop_supervisor(task_supervisor)
  end

  test "Workspace close failure overrides buffered completion after owner-down settlement" do
    test_pid = self()
    request = run_request("await-close-failure")
    operation_id = configure_provider(request, :success, true)

    opener = fn open_request ->
      handle =
        CloseFailBackend.open(
          open_request.owner,
          open_request.limits,
          open_request.access,
          test_pid
        )

      send(test_pid, {:await_workspace_opened, self(), handle.state})
      {:ok, handle}
    end

    sink = fn event ->
      if match?(%RunCompleted{}, event) or match?(%RunFailed{}, event),
        do: send(test_pid, {:close_terminal_event, event})

      :ok
    end

    assert {:ok, run} =
             Runtime.start_run(request, sink,
               provider: TestProvider,
               workspace_opener: opener
             )

    register_cleanup(run, operation_id)
    assert_receive {:await_workspace_opened, task, backend}
    assert_receive {:await_provider_called, ^task, _context}
    send(task, {:release_await_provider, operation_id})
    assert_receive {:await_close_owner_down, ^backend}
    refute_received {:close_terminal_event, _event}

    send(backend, :finish_await_close_cleanup)

    assert {:error, %Error{kind: :internal, reason: :workspace_close_failed}} =
             Runtime.await(run, :infinity)

    assert_receive {:close_terminal_event, %RunFailed{error: error}}
    assert error.reason == :workspace_close_failed
    refute_received {:close_terminal_event, %RunCompleted{}}
  end

  test "progress sink failure stops further delivery and still cleans Workspace" do
    test_pid = self()
    request = run_request("await-progress-sink-failure")
    operation_id = configure_provider(request, :success, false)
    opener = capturing_opener(test_pid)

    sink = fn event ->
      send(test_pid, {:progress_sink_attempt, event})
      {:error, :closed}
    end

    assert {:ok, run} =
             Runtime.start_run(request, sink,
               provider: TestProvider,
               workspace_opener: opener
             )

    assert_receive {:await_workspace_opened, task, backend}
    backend_monitor = Process.monitor(backend)

    assert {:error, %Error{reason: :event_sink_failed}} = Runtime.await(run, :infinity)
    assert_receive {:DOWN, ^backend_monitor, :process, ^backend, _reason}
    assert_receive {:progress_sink_attempt, _event}
    refute_received {:progress_sink_attempt, _event}
    refute_received {:await_provider_called, _task, _context}
    send(task, {:release_await_provider, operation_id})
  end

  test "terminal sink is attempted once and callback failure becomes event_sink_failed" do
    Enum.each([:reject, :raise, :throw, :exit], fn mode ->
      test_pid = self()
      request = run_request("await-terminal-sink-#{mode}")
      operation_id = configure_provider(request, :success, false)
      opener = capturing_opener(test_pid)

      sink = fn
        %RunCompleted{} = event ->
          send(test_pid, {:terminal_sink_attempt, mode, event})

          case mode do
            :reject -> {:error, :closed}
            :raise -> raise "terminal sink failed"
            :throw -> throw(:terminal_sink_failed)
            :exit -> exit(:terminal_sink_failed)
          end

        _progress ->
          :ok
      end

      assert {:ok, run} =
               Runtime.start_run(request, sink,
                 provider: TestProvider,
                 workspace_opener: opener
               )

      assert_receive {:await_workspace_opened, _task, _backend}
      assert_receive {:await_provider_called, _task, _context}
      assert {:error, %Error{reason: :event_sink_failed}} = Runtime.await(run, :infinity)
      assert_receive {:terminal_sink_attempt, ^mode, %RunCompleted{}}
      refute_received {:terminal_sink_attempt, ^mode, _event}
      send(run.task, {:release_await_provider, operation_id})
    end)
  end

  test "queued terminal wins when await begins after RunServer DOWN" do
    test_pid = self()
    request = run_request("await-queued-terminal")
    run_id = request.id
    operation_id = configure_provider(request, :success, true)
    opener = capturing_opener(test_pid)

    assert {:ok, run} =
             Runtime.start_run(request, fn _event -> :ok end,
               provider: TestProvider,
               workspace_opener: opener
             )

    assert_receive {:await_workspace_opened, task, _backend}
    assert_receive {:await_provider_called, ^task, _context}
    server_monitor = Process.monitor(run.server)
    send(task, {:release_await_provider, operation_id})
    assert_receive {:DOWN, ^server_monitor, :process, _, :normal}

    assert {:ok, %Result{run_id: ^run_id}} = Runtime.await(run, :infinity)
  end

  test "terminal confirmation timeout requeues completion and restores await rights" do
    result = agent_result("await-confirmation-timeout")
    controls = controls()
    server = spawn(fn -> receive do: (:stop -> :ok) end)

    run = %Run{
      id: result.run_id,
      owner: self(),
      server: server,
      task: server,
      run_ref: controls.run_ref,
      cancel_ref: controls.cancel_ref,
      cancellation: controls.cancellation,
      await_state: controls.await_state
    }

    {:ok, terminal_message} = Message.terminal(run.run_ref, {:ok, result})
    send(self(), terminal_message)

    assert {:error, :await_timeout} = Runtime.await(run, 0)
    assert :atomics.get(run.await_state, 1) == 0
    assert Process.alive?(server)

    server_monitor = Process.monitor(server)
    send(server, :stop)
    assert_receive {:DOWN, ^server_monitor, :process, ^server, :normal}
    assert {:ok, ^result} = Runtime.await(run, :infinity)
    assert :atomics.get(run.await_state, 1) == 2
  end

  test "terminal evidence requires matching tuple and failed-versus-interrupted outcome" do
    result = agent_result("await-contract")
    mismatch_error = agent_error("await-contract", :provider, :provider_failed)
    cancelled_error = agent_error("await-contract", :cancelled, :run_cancelled)

    {:ok, timeout_error} =
      Error.new(
        kind: :provider,
        reason: :provider_failed,
        message: "Provider request failed",
        run_id: "await-contract",
        turn: 1,
        operation_id: "provider-operation",
        details: %{"provider_kind" => "timeout"}
      )

    scenarios = [
      {:missing, nil, {:ok, result}, RunFailed, :run_worker_crashed},
      {:mismatched, terminal_event({:ok, result}, :completed), {:error, mismatch_error},
       RunFailed, :run_worker_crashed},
      {:wrong_outcome, terminal_event({:error, cancelled_error}, :failed),
       {:error, cancelled_error}, RunFailed, :run_worker_crashed},
      {:matching_interruption, terminal_event({:error, cancelled_error}, :interrupted),
       {:error, cancelled_error}, RunInterrupted, :run_cancelled},
      {:matching_timeout, terminal_event({:error, timeout_error}, :interrupted),
       {:error, timeout_error}, RunInterrupted, :provider_failed}
    ]

    Enum.each(scenarios, fn {label, emitted_event, worker_terminal, expected_event,
                             expected_reason} ->
      {:ok, task_supervisor} = Task.Supervisor.start_link()
      {:ok, runtime_supervisor} = RuntimeSupervisor.start_link(name: nil)
      controls = controls()
      test_pid = self()

      {:ok, state} =
        State.new(
          run_id: "await-contract",
          owner: self(),
          run_ref: controls.run_ref,
          cancel_ref: controls.cancel_ref,
          cancellation: controls.cancellation,
          await_state: controls.await_state,
          event_sink: fn event ->
            send(test_pid, {:contract_terminal, label, event})
            :ok
          end
        )

      agent = contract_agent(state.run_ref, emitted_event, worker_terminal)

      assert {:ok, server} =
               RuntimeSupervisor.start_run_server(state, agent,
                 supervisor: runtime_supervisor,
                 task_supervisor: task_supervisor
               )

      assert_receive %Message{
        kind: :started,
        run_ref: run_ref,
        worker: task,
        payload: ^server
      }

      assert run_ref == controls.run_ref

      run = %Run{
        id: "await-contract",
        owner: self(),
        server: server,
        task: task,
        run_ref: controls.run_ref,
        cancel_ref: controls.cancel_ref,
        cancellation: controls.cancellation,
        await_state: controls.await_state
      }

      assert {:error, %Error{reason: ^expected_reason}} = Runtime.await(run, :infinity)

      assert_receive {:contract_terminal, ^label, event}
      assert event.__struct__ == expected_event
      assert event.error.reason == expected_reason

      stop_supervisor(runtime_supervisor)
      stop_supervisor(task_supervisor)
    end)
  end

  test "accepted visible output and exact Tool boundaries drive conservative fallback" do
    {:ok, text_delta} =
      Synapse.Run.Event.new(:text_delta,
        run_id: "await-tracking",
        turn: 1,
        operation_id: "provider-operation",
        item_id: "message-1",
        content_index: 0,
        delta: "visible secret not retained"
      )

    {:ok, turn_started} =
      Synapse.Run.Event.new(:turn_started,
        run_id: "await-tracking",
        turn: 1,
        operation_id: "provider-operation"
      )

    tool_attrs = [
      run_id: "await-tracking",
      turn: 1,
      operation_id: "tool-operation",
      call_id: "call-1",
      name: "write",
      ordinal: 1
    ]

    {:ok, tool_started} =
      Synapse.Run.Event.new(:tool_started, tool_attrs ++ [arguments: %{}])

    {:ok, tool_completed} =
      Synapse.Run.Event.new(
        :tool_completed,
        tool_attrs ++ [status: :ok, metadata: %{}, content: ~s({"status":"ok"})]
      )

    scenarios = [
      {:before_run_started, [], RunFailed, :run_worker_crashed, :agent_failed},
      {:malformed_return, [], RunFailed, :run_worker_crashed,
       {:malformed, "SYNTHETIC_WORKER_RETURN_SECRET"}},
      {:turn_without_output, [turn_started], RunFailed, :run_worker_crashed, :agent_failed},
      {:visible, [text_delta], RunInterrupted, :run_worker_crashed, :agent_failed},
      {:tool_before_workspace, [tool_started], RunFailed, :tool_ambiguous, :agent_failed},
      {:tool_during_unknown_outcome, [tool_started], RunFailed, :tool_ambiguous, :agent_failed},
      {:completed_tool, [tool_started, tool_completed], RunFailed, :run_worker_crashed,
       :agent_failed}
    ]

    Enum.each(scenarios, fn {label, events, expected_event, expected_reason, worker_outcome} ->
      {run, runtime_supervisor, task_supervisor} =
        start_tracking_run(label, events, worker_outcome)

      assert {:error, %Error{reason: ^expected_reason}} = Runtime.await(run, :infinity)
      assert_receive {:tracking_event, ^label, terminal}
      assert terminal.__struct__ == expected_event
      assert terminal.error.reason == expected_reason
      refute inspect(terminal) =~ "SYNTHETIC_WORKER_RETURN_SECRET"

      if expected_reason == :tool_ambiguous do
        assert terminal.error.details == %{
                 "call_id" => "call-1",
                 "tool_name" => "write",
                 "operation_id" => "tool-operation",
                 "outcome" => "unknown",
                 "status" => "ambiguous"
               }
      end

      stop_supervisor(runtime_supervisor)
      stop_supervisor(task_supervisor)
    end)
  end

  test "close failure keeps only ambiguity evidence from an agreement-valid terminal" do
    ambiguity_details = %{
      "call_id" => "call-ambiguity",
      "tool_name" => "write",
      "operation_id" => "tool-ambiguity",
      "outcome" => "unknown",
      "status" => "ambiguous"
    }

    {:ok, ambiguity_error} =
      Error.new(
        kind: :tool,
        reason: :tool_ambiguous,
        message: "Tool result is ambiguous",
        run_id: "await-close-ambiguity",
        turn: 1,
        operation_id: "tool-ambiguity",
        details: ambiguity_details
      )

    mismatched_error =
      agent_error("await-close-ambiguity", :provider, :provider_failed)

    scenarios = [
      {:matching, ambiguity_error, ambiguity_error, ambiguity_details},
      {:mismatched, ambiguity_error, mismatched_error, %{}}
    ]

    Enum.each(scenarios, fn {label, emitted_error, returned_error, expected_details} ->
      {run, backend, runtime_supervisor, task_supervisor} =
        start_close_ambiguity_run(label, emitted_error, returned_error)

      assert_receive {:await_close_owner_down, ^backend}
      refute_received {:close_ambiguity_terminal, ^label, _event}
      send(backend, :finish_await_close_cleanup)

      assert {:error, %Error{reason: :workspace_close_failed, details: ^expected_details}} =
               Runtime.await(run, :infinity)

      assert_receive {:close_ambiguity_terminal, ^label,
                      %RunFailed{error: %Error{reason: :workspace_close_failed}}}

      stop_supervisor(runtime_supervisor)
      stop_supervisor(task_supervisor)
    end)
  end

  defp configure_provider(request, mode, block?) do
    {:ok, operation_id} = OperationId.provider(request.id, 1, 1)

    :persistent_term.put(
      {TestProvider, operation_id},
      %{
        test_pid: self(),
        mode: mode,
        block?: block?,
        response: response(request, "Await finished")
      }
    )

    on_exit(fn -> :persistent_term.erase({TestProvider, operation_id}) end)
    operation_id
  end

  defp run_request(id) do
    {:ok, capabilities} =
      CapabilitySet.new(fs_read: true, fs_write: true, process_exec: true)

    {:ok, request} =
      Request.new(
        id: id,
        prompt: "Exercise Runtime await",
        cwd: "/synthetic/runtime/await",
        model: "await-model",
        capabilities: capabilities,
        budget: Budget.default()
      )

    request
  end

  defp response(request, text) do
    {:ok, response} =
      Provider.Response.new(
        id: "response-#{request.id}",
        model: request.model,
        output_items: [
          %ProviderMessage{id: "await-message", role: :assistant, content: text}
        ]
      )

    response
  end

  defp capturing_opener(test_pid) do
    fn open_request ->
      {:ok, handle} =
        Workspace.Fake.open([],
          owner: open_request.owner,
          limits: open_request.limits,
          access: open_request.access
        )

      send(test_pid, {:await_workspace_opened, self(), handle.state})
      {:ok, handle}
    end
  end

  defp terminal_observing_sink(test_pid) do
    fn event ->
      if match?(%RunCompleted{}, event) or match?(%RunFailed{}, event) or
           match?(%RunInterrupted{}, event) do
        case :persistent_term.get({__MODULE__, :terminal_observer}, nil) do
          %{server: server, task: task, backend: backend} when server == self() ->
            send(test_pid, {
              :await_terminal_observed,
              event,
              Process.alive?(task),
              Process.alive?(backend)
            })

          _missing ->
            send(test_pid, {:await_terminal_observed, event, :unknown, :unknown})
        end
      end

      :ok
    end
  end

  defp configure_terminal_observer(server, task, backend) do
    :persistent_term.put(
      {__MODULE__, :terminal_observer},
      %{server: server, task: task, backend: backend}
    )

    on_exit(fn -> :persistent_term.erase({__MODULE__, :terminal_observer}) end)
  end

  defp register_cleanup(run, operation_id) do
    on_exit(fn ->
      send(run.task, {:release_await_provider, operation_id})
      if Process.alive?(run.server), do: Process.exit(run.server, :kill)
    end)
  end

  defp controls do
    cancellation = :atomics.new(1, signed: false)
    await_state = :atomics.new(1, signed: false)

    %{
      run_ref: make_ref(),
      cancel_ref: make_ref(),
      cancellation: cancellation,
      await_state: await_state
    }
  end

  defp contract_agent(run_ref, emitted_event, worker_terminal) do
    fn run_server ->
      {:ok, access} = Access.new(read: true, write: true, exec: true)

      {:ok, handle} =
        Workspace.Fake.open([],
          owner: self(),
          limits: Limits.default(),
          access: access
        )

      {:ok, ready} = Message.ready(run_ref, self(), handle)
      send(run_server, ready)

      receive do
        %Message{kind: :accept, run_ref: ^run_ref} -> :ok
      end

      if emitted_event, do: :ok = RunServer.emit_event(run_server, run_ref, self(), emitted_event)
      :ok = Workspace.close(handle)
      {:agent_finished, worker_terminal, :workspace_closed}
    end
  end

  defp terminal_event({:ok, result}, :completed) do
    {:ok, event} = Synapse.Run.Event.new(:run_completed, run_id: result.run_id, result: result)
    event
  end

  defp terminal_event({:error, error}, outcome) do
    kind = if outcome == :interrupted, do: :run_interrupted, else: :run_failed
    {:ok, event} = Synapse.Run.Event.new(kind, run_id: error.run_id, error: error)
    event
  end

  defp agent_result(run_id) do
    {:ok, response} =
      Provider.Response.new(
        id: "contract-response",
        model: "await-model",
        output_items: [
          %ProviderMessage{id: "contract-message", role: :assistant, content: "done"}
        ]
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

  defp agent_error(run_id, kind, reason) do
    {:ok, error} =
      Error.new(
        kind: kind,
        reason: reason,
        message: "Synthetic Agent failure",
        run_id: run_id,
        turn: 1,
        operation_id: nil,
        details: %{}
      )

    error
  end

  defp stop_supervisor(supervisor) do
    Supervisor.stop(supervisor)
  catch
    :exit, _reason -> :ok
  end

  defp start_tracking_run(label, events, worker_outcome) do
    {:ok, task_supervisor} = Task.Supervisor.start_link()
    {:ok, runtime_supervisor} = RuntimeSupervisor.start_link(name: nil)
    controls = controls()
    test_pid = self()

    {:ok, state} =
      State.new(
        run_id: "await-tracking",
        owner: self(),
        run_ref: controls.run_ref,
        cancel_ref: controls.cancel_ref,
        cancellation: controls.cancellation,
        await_state: controls.await_state,
        event_sink: fn event ->
          if match?(%RunFailed{}, event) or match?(%RunInterrupted{}, event),
            do: send(test_pid, {:tracking_event, label, event})

          :ok
        end
      )

    agent = fn run_server ->
      {:ok, access} = Access.new(read: true, write: true, exec: true)

      {:ok, handle} =
        Workspace.Fake.open([],
          owner: self(),
          limits: Limits.default(),
          access: access
        )

      {:ok, ready} = Message.ready(state.run_ref, self(), handle)
      send(run_server, ready)

      receive do
        %Message{kind: :accept, run_ref: run_ref} when run_ref == state.run_ref -> :ok
      end

      Enum.each(events, fn event ->
        :ok = RunServer.emit_event(run_server, state.run_ref, self(), event)
      end)

      :ok = Workspace.close(handle)
      worker_outcome
    end

    {:ok, server} =
      RuntimeSupervisor.start_run_server(state, agent,
        supervisor: runtime_supervisor,
        task_supervisor: task_supervisor
      )

    assert_receive %Message{kind: :started, worker: task, payload: ^server}

    run = %Run{
      id: state.run_id,
      owner: self(),
      server: server,
      task: task,
      run_ref: state.run_ref,
      cancel_ref: state.cancel_ref,
      cancellation: state.cancellation,
      await_state: state.await_state
    }

    {run, runtime_supervisor, task_supervisor}
  end

  defp start_close_ambiguity_run(label, emitted_error, returned_error) do
    {:ok, task_supervisor} = Task.Supervisor.start_link()
    {:ok, runtime_supervisor} = RuntimeSupervisor.start_link(name: nil)
    controls = controls()
    test_pid = self()

    {:ok, state} =
      State.new(
        run_id: "await-close-ambiguity",
        owner: self(),
        run_ref: controls.run_ref,
        cancel_ref: controls.cancel_ref,
        cancellation: controls.cancellation,
        await_state: controls.await_state,
        event_sink: fn event ->
          if match?(%RunFailed{}, event),
            do: send(test_pid, {:close_ambiguity_terminal, label, event})

          :ok
        end
      )

    agent = fn run_server ->
      {:ok, access} = Access.new(read: true, write: true, exec: true)
      handle = CloseFailBackend.open(self(), Limits.default(), access, test_pid)
      send(test_pid, {:close_ambiguity_backend, label, handle.state})
      {:ok, ready} = Message.ready(state.run_ref, self(), handle)
      send(run_server, ready)

      receive do
        %Message{kind: :accept, run_ref: run_ref} when run_ref == state.run_ref -> :ok
      end

      {:ok, event} =
        Synapse.Run.Event.new(:run_failed, run_id: state.run_id, error: emitted_error)

      :ok = RunServer.emit_event(run_server, state.run_ref, self(), event)
      {:error, _close_error} = Workspace.close(handle)
      {:agent_finished, {:error, returned_error}, :workspace_close_failed}
    end

    {:ok, server} =
      RuntimeSupervisor.start_run_server(state, agent,
        supervisor: runtime_supervisor,
        task_supervisor: task_supervisor
      )

    assert_receive {:close_ambiguity_backend, ^label, backend}
    assert_receive %Message{kind: :started, worker: task, payload: ^server}

    run = %Run{
      id: state.run_id,
      owner: self(),
      server: server,
      task: task,
      run_ref: state.run_ref,
      cancel_ref: state.cancel_ref,
      cancellation: state.cancellation,
      await_state: state.await_state
    }

    {run, backend, runtime_supervisor, task_supervisor}
  end
end
