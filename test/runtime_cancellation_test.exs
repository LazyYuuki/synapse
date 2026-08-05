defmodule Synapse.Runtime.CancellationTest.Provider do
  @behaviour Synapse.Provider

  alias Synapse.Provider

  @impl true
  def stream(_request, _event_sink, context) do
    config = :persistent_term.get({__MODULE__, context.operation_id})
    send(config.test_pid, {:cancellation_provider_called, self(), context.operation_id})

    case config.mode do
      :success ->
        {:ok, config.response}

      :retryable_failure ->
        {:error, provider_error(context.operation_id, :transport, true)}

      :wait_for_cancel ->
        await_cancel(config.test_pid, context.cancel_ref, context.operation_id)
    end
  end

  defp await_cancel(test_pid, cancel_ref, operation_id) do
    receive do
      {:cancel, ^cancel_ref} ->
        send(test_pid, {:cancellation_provider_consumed, self(), operation_id})
        {:error, provider_error(operation_id, :interrupted, false, true)}

      {:cancellation_probe, caller} ->
        send(caller, {:cancellation_provider_waiting, self(), operation_id})
        await_cancel(test_pid, cancel_ref, operation_id)

      _unrelated ->
        await_cancel(test_pid, cancel_ref, operation_id)
    end
  end

  defp provider_error(operation_id, kind, retryable, output_started \\ false) do
    {:ok, error} =
      Provider.Error.new(
        kind: kind,
        message: "Provider request failed",
        retryable: retryable,
        output_started: output_started,
        operation_id: operation_id
      )

    error
  end
end

defmodule Synapse.Runtime.CancellationTest do
  use ExUnit.Case, async: false

  alias Synapse.Agent.{Error, OperationId, Result}
  alias Synapse.Budget
  alias Synapse.Provider
  alias Synapse.Provider.OutputItem.Message, as: ProviderMessage
  alias Synapse.Run.Event.{RunCompleted, RunInterrupted, RunStarted}
  alias Synapse.Run.Request
  alias Synapse.Runtime
  alias Synapse.Runtime.CancellationTest.Provider, as: TestProvider
  alias Synapse.Tool.CapabilitySet
  alias Synapse.Workspace

  test "cancellation before the first Provider attempt is non-owner safe and idempotent" do
    test_pid = self()
    request = run_request("runtime-cancel-before-provider")
    operation_id = configure_provider(request, :success)

    sink = fn
      %RunStarted{} = event ->
        send(test_pid, {:run_started_barrier, self(), event})

        receive do
          :release_run_started -> :ok
        end

      event ->
        send(test_pid, {:cancellation_event, event})
        :ok
    end

    assert {:ok, run} = start_run(request, sink)
    register_cleanup(run)
    assert_receive {:run_started_barrier, server, %RunStarted{}}
    assert server == run.server

    caller = self()

    non_owner =
      spawn(fn ->
        send(caller, {:non_owner_cancelled, Runtime.cancel(run)})
      end)

    monitor = Process.monitor(non_owner)
    assert_receive {:non_owner_cancelled, :ok}
    assert_receive {:DOWN, ^monitor, :process, ^non_owner, :normal}
    assert :atomics.get(run.cancellation, 1) == 1
    assert :ok = Runtime.cancel(run)

    send(server, :release_run_started)

    assert {:error, %Error{kind: :cancelled, reason: :run_cancelled}} =
             Runtime.await(run, :infinity)

    assert_receive {:cancellation_event, %RunInterrupted{}}
    refute_received {:cancellation_provider_called, _task, ^operation_id}
    assert :ok = Runtime.cancel(run)
    assert :atomics.get(run.cancellation, 1) == 1
    assert_runtime_settled(run)
  end

  test "active Provider consumes only the exact message while persistent cancellation remains" do
    request = run_request("runtime-cancel-provider")
    operation_id = configure_provider(request, :wait_for_cancel)

    assert {:ok, run} = start_run(request, event_sink(self()))
    register_cleanup(run)
    assert_receive {:cancellation_provider_called, task, ^operation_id}
    assert task == run.task

    send(task, {:cancel, make_ref()})
    send(task, {:unrelated, :message})
    send(task, {:cancellation_probe, self()})
    assert_receive {:cancellation_provider_waiting, ^task, ^operation_id}
    refute_received {:cancellation_provider_consumed, _task, _operation_id}

    assert :ok = Runtime.cancel(run)
    assert_receive {:cancellation_provider_consumed, ^task, ^operation_id}
    refute_received {:cancel, _reference}
    assert :atomics.get(run.cancellation, 1) == 1

    assert {:error, %Error{kind: :cancelled, reason: :run_cancelled}} =
             Runtime.await(run, :infinity)

    assert_receive {:cancellation_event, %RunInterrupted{}}
    assert_runtime_settled(run)
  end

  test "cancellation during Provider retry delay starts no second attempt" do
    test_pid = self()
    request = run_request("runtime-cancel-retry", max_provider_retries: 1)
    {:ok, first_operation_id} = OperationId.provider(request.id, 1, 1)
    {:ok, second_operation_id} = OperationId.provider(request.id, 1, 2)
    configure_operation(first_operation_id, :retryable_failure, response(request))
    configure_operation(second_operation_id, :success, response(request))

    retry_delay = fn ordinal ->
      send(test_pid, {:runtime_retry_delay, self(), ordinal})
      10_000
    end

    assert {:ok, run} =
             Runtime.start_run(request, event_sink(test_pid),
               provider: TestProvider,
               retry_delay: retry_delay,
               workspace_opener: fake_opener()
             )

    register_cleanup(run)
    assert_receive {:cancellation_provider_called, task, ^first_operation_id}
    assert task == run.task
    assert_receive {:runtime_retry_delay, ^task, 1}

    assert :ok = Runtime.cancel(run)

    assert {:error, %Error{kind: :cancelled, reason: :run_cancelled}} =
             Runtime.await(run, :infinity)

    refute_received {:cancellation_provider_called, _task, ^second_operation_id}
    assert_receive {:cancellation_event, %RunInterrupted{}}
    assert_runtime_settled(run)
  end

  test "a safe Provider retry succeeds through public Runtime" do
    request = run_request("runtime-retry-success", max_provider_retries: 1)
    {:ok, first_operation_id} = OperationId.provider(request.id, 1, 1)
    {:ok, second_operation_id} = OperationId.provider(request.id, 1, 2)
    configure_operation(first_operation_id, :retryable_failure, response(request))
    configure_operation(second_operation_id, :success, response(request))

    assert {:ok, run} =
             Runtime.start_run(request, event_sink(self()),
               provider: TestProvider,
               retry_delay: fn _ordinal -> 0 end,
               workspace_opener: fake_opener()
             )

    register_cleanup(run)
    assert_receive {:cancellation_provider_called, task, ^first_operation_id}
    assert task == run.task
    assert_receive {:cancellation_provider_called, ^task, ^second_operation_id}
    assert {:ok, %Result{provider_retries: 1}} = Runtime.await(run, :infinity)
    assert_runtime_settled(run)
  end

  test "await timeout preserves the right for later cancellation" do
    request = run_request("runtime-timeout-then-cancel")
    operation_id = configure_provider(request, :wait_for_cancel)

    assert {:ok, run} = start_run(request, event_sink(self()))
    register_cleanup(run)
    assert_receive {:cancellation_provider_called, task, ^operation_id}
    assert task == run.task
    assert {:error, :await_timeout} = Runtime.await(run, 0)
    assert :atomics.get(run.await_state, 1) == 0
    assert Process.alive?(run.task)

    assert :ok = Runtime.cancel(run)

    assert {:error, %Error{kind: :cancelled, reason: :run_cancelled}} =
             Runtime.await(run, :infinity)

    assert_runtime_settled(run)
  end

  test "an already buffered natural terminal wins a later cancellation" do
    test_pid = self()
    request = run_request("runtime-cancel-after-terminal")
    configure_provider(request, :success)

    sink = fn
      %RunCompleted{} = event ->
        send(test_pid, {:completed_barrier, self(), event})

        receive do
          :release_completed -> :ok
        end

      event ->
        send(test_pid, {:cancellation_event, event})
        :ok
    end

    assert {:ok, run} = start_run(request, sink)
    register_cleanup(run)
    assert_receive {:completed_barrier, server, %RunCompleted{}}
    assert server == run.server

    assert :ok = Runtime.cancel(run)
    assert :ok = Runtime.cancel(run)
    send(server, :release_completed)

    assert {:ok, %Result{run_id: run_id}} = Runtime.await(run, :infinity)
    assert run_id == request.id
    refute_received {:cancellation_event, %RunInterrupted{}}
    assert :ok = Runtime.cancel(run)
    assert_runtime_settled(run)
  end

  defp start_run(request, sink) do
    Runtime.start_run(request, sink,
      provider: TestProvider,
      workspace_opener: fake_opener()
    )
  end

  defp configure_provider(request, mode) do
    {:ok, operation_id} = OperationId.provider(request.id, 1, 1)
    configure_operation(operation_id, mode, response(request))
    operation_id
  end

  defp configure_operation(operation_id, mode, response) do
    :persistent_term.put(
      {TestProvider, operation_id},
      %{test_pid: self(), mode: mode, response: response}
    )

    on_exit(fn -> :persistent_term.erase({TestProvider, operation_id}) end)
  end

  defp run_request(id, budget_options \\ []) do
    {:ok, capabilities} =
      CapabilitySet.new(fs_read: true, fs_write: true, process_exec: true)

    {:ok, budget} = Budget.new(budget_options)

    {:ok, request} =
      Request.new(
        id: id,
        prompt: "Exercise Runtime cancellation",
        cwd: "/synthetic/runtime/cancellation",
        model: "runtime-cancellation-model",
        capabilities: capabilities,
        budget: budget
      )

    request
  end

  defp response(request) do
    {:ok, response} =
      Provider.Response.new(
        id: "response-#{request.id}",
        model: request.model,
        output_items: [
          %ProviderMessage{id: "message-#{request.id}", role: :assistant, content: "finished"}
        ]
      )

    response
  end

  defp event_sink(test_pid) do
    fn event ->
      send(test_pid, {:cancellation_event, event})
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

  defp register_cleanup(run) do
    on_exit(fn ->
      if Process.alive?(run.server), do: Process.exit(run.server, :kill)
    end)
  end

  defp assert_runtime_settled(run) do
    refute Process.alive?(run.server)
    refute Process.alive?(run.task)
    assert DynamicSupervisor.count_children(Synapse.Runtime.Supervisor).active == 0
  end
end
