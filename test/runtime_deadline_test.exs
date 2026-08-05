defmodule Synapse.Runtime.DeadlineTest.Provider do
  @behaviour Synapse.Provider

  alias Synapse.Provider

  @impl true
  def stream(_request, _event_sink, context) do
    config = :persistent_term.get({__MODULE__, context.operation_id})
    send(config.test_pid, {:deadline_provider_called, config.label, self(), context})

    case config.mode do
      :success -> {:ok, config.response}
      :timeout -> {:error, timeout_error(context.operation_id)}
    end
  end

  defp timeout_error(operation_id) do
    {:ok, error} =
      Provider.Error.new(
        kind: :timeout,
        message: "Provider request timed out",
        retryable: false,
        output_started: false,
        operation_id: operation_id
      )

    error
  end
end

defmodule Synapse.Runtime.DeadlineTest do
  use ExUnit.Case, async: false

  alias Synapse.Agent.{Error, OperationId, Result}
  alias Synapse.Budget
  alias Synapse.Run.Event.{RunFailed, RunInterrupted}
  alias Synapse.Run.Request
  alias Synapse.Runtime
  alias Synapse.Runtime.DeadlineTest.Provider, as: TestProvider
  alias Synapse.Tool.CapabilitySet
  alias Synapse.Workspace

  test "an already elapsed Runtime deadline starts no Provider operation" do
    label = "elapsed-runtime-deadline"
    request = run_request("runtime-deadline-elapsed")
    configure_provider(request, label, :success)
    deadline = System.monotonic_time(:millisecond) - 1

    assert {:ok, run} = start_run(request, label, deadline)
    register_cleanup(run)

    assert {:error, %Error{kind: :budget, reason: :wall_time_budget_exhausted}} =
             Runtime.await(run, :infinity)

    refute_received {:deadline_provider_called, ^label, _task, _context}
    assert_receive {:deadline_event, ^label, %RunFailed{}}
    assert_settled(run)
  end

  test "the effective Provider deadline is the earlier Runtime or Budget boundary" do
    now = System.monotonic_time(:millisecond)

    scenarios = [
      {"runtime-earlier", 60_000, now + 5_000, :exact_runtime},
      {"budget-earlier", 5_000, now + 60_000, :budget_before_runtime}
    ]

    Enum.each(scenarios, fn {label, wall_time_ms, runtime_deadline, expectation} ->
      request = run_request("runtime-deadline-#{label}", max_wall_time_ms: wall_time_ms)
      configure_provider(request, label, :success)

      assert {:ok, run} = start_run(request, label, runtime_deadline)
      register_cleanup(run)

      assert_receive {:deadline_provider_called, ^label, task, context}
      assert task == run.task

      case expectation do
        :exact_runtime -> assert context.deadline == runtime_deadline
        :budget_before_runtime -> assert context.deadline < runtime_deadline
      end

      assert context.inactivity_ms == request.budget.provider_inactivity_ms
      assert {:ok, %Result{run_id: run_id}} = Runtime.await(run, :infinity)
      assert run_id == request.id
      assert_settled(run)
    end)
  end

  test "Provider inactivity classification returns one interrupted terminal" do
    label = "provider-inactivity"
    request = run_request("runtime-provider-inactivity", provider_inactivity_ms: 37)
    configure_provider(request, label, :timeout)

    assert {:ok, run} = start_run(request, label, :infinity)
    register_cleanup(run)
    assert_receive {:deadline_provider_called, ^label, task, context}
    assert task == run.task
    assert context.inactivity_ms == 37

    assert {:error, %Error{kind: :provider, reason: :provider_failed} = error} =
             Runtime.await(run, :infinity)

    assert error.details["provider_kind"] == "timeout"
    assert_receive {:deadline_event, ^label, %RunInterrupted{}}
    refute_received {:deadline_event, ^label, %RunFailed{}}
    assert_settled(run)
  end

  defp start_run(request, label, deadline) do
    Runtime.start_run(request, event_sink(self(), label),
      provider: TestProvider,
      deadline: deadline,
      workspace_opener: fake_opener()
    )
  end

  defp configure_provider(request, label, mode) do
    {:ok, operation_id} = OperationId.provider(request.id, 1, 1)

    :persistent_term.put(
      {TestProvider, operation_id},
      %{test_pid: self(), label: label, mode: mode, response: response(request)}
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
        prompt: "Exercise Runtime deadlines",
        cwd: "/synthetic/runtime/deadline",
        model: "runtime-deadline-model",
        capabilities: capabilities,
        budget: budget
      )

    request
  end

  defp response(request) do
    {:ok, response} =
      Synapse.Provider.Response.new(
        id: "response-#{request.id}",
        model: request.model,
        output_items: [
          %Synapse.Provider.OutputItem.Message{
            id: "message-#{request.id}",
            role: :assistant,
            content: "finished"
          }
        ]
      )

    response
  end

  defp event_sink(test_pid, label) do
    fn event ->
      send(test_pid, {:deadline_event, label, event})
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

  defp assert_settled(run) do
    refute Process.alive?(run.server)
    refute Process.alive?(run.task)
    assert Task.Supervisor.children(Synapse.TaskSupervisor) == []
    assert DynamicSupervisor.count_children(Synapse.Runtime.Supervisor).active == 0
  end

  defp register_cleanup(run) do
    on_exit(fn ->
      if Process.alive?(run.server), do: Process.exit(run.server, :kill)
    end)
  end
end
