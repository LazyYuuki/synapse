defmodule Synapse.Runtime.StartTest.Provider do
  @behaviour Synapse.Provider

  @impl true
  def stream(request, event_sink, context) do
    configuration =
      :persistent_term.get({__MODULE__, context.operation_id}, :not_configured)

    case configuration do
      %{test_pid: test_pid, response: response, events: events, block?: block?} ->
        send(test_pid, {:runtime_provider_called, self(), request, context})

        if block? do
          receive do
            {:release_runtime_provider, operation_id}
            when operation_id == context.operation_id ->
              :ok
          end
        end

        Enum.each(events, fn event ->
          if event_sink.(event) != :ok, do: raise("Runtime event relay rejected Provider event")
        end)

        {:ok, response}

      :not_configured ->
        raise "Runtime test Provider was not configured"
    end
  end
end

defmodule Synapse.Runtime.StartTest.CloseFailBackend do
  alias Synapse.Workspace.{Error, Handle}

  def workspace_backend?, do: true

  def open(owner, limits, access, test_pid) do
    backend =
      spawn(fn ->
        monitor = Process.monitor(owner)

        receive do
          {:DOWN, ^monitor, :process, ^owner, _reason} ->
            send(test_pid, {:close_fail_owner_down, self()})

            receive do
              :finish_close_fail_cleanup -> :ok
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

defmodule Synapse.Runtime.StartTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Synapse.Agent.OperationId
  alias Synapse.Budget
  alias Synapse.Provider
  alias Synapse.Provider.Event.TextDelta, as: ProviderTextDelta
  alias Synapse.Provider.OutputItem.FunctionCall
  alias Synapse.Provider.OutputItem.Message, as: ProviderMessage

  alias Synapse.Run.Event.{
    RunCompleted,
    RunFailed,
    RunInterrupted,
    RunStarted,
    TextDelta,
    TurnCompleted,
    TurnStarted
  }

  alias Synapse.Run.Request
  alias Synapse.Runtime
  alias Synapse.Runtime.Error
  alias Synapse.Runtime.StartTest.CloseFailBackend
  alias Synapse.Runtime.StartTest.Provider, as: TestProvider
  alias Synapse.Tool.CapabilitySet
  alias Synapse.Tool.Limits, as: ToolLimits
  alias Synapse.Workspace
  alias Synapse.Workspace.{Access, OperationContext, ReadLine, ReadRequest, ReadResult, Revision}

  test "public Runtime starts one text-only Fake run after exact readiness" do
    request = run_request("runtime-text")
    operation_id = configure_provider(request, block?: true, text_delta?: true)
    test_pid = self()
    deadline = System.monotonic_time(:millisecond) + 60_000

    opener = fn open_request ->
      {:ok, handle} =
        Workspace.Fake.open([],
          owner: open_request.owner,
          limits: open_request.limits,
          access: open_request.access
        )

      send(test_pid, {:runtime_workspace_opened, self(), open_request, handle.state})
      {:ok, handle}
    end

    sink = fn event ->
      send(test_pid, {:runtime_event, event})
      :ok
    end

    assert {:ok, run} =
             Runtime.start_run(request, sink,
               provider: TestProvider,
               instructions: "Exact trusted Runtime instructions",
               deadline: deadline,
               workspace_opener: opener
             )

    register_run_cleanup(run, operation_id)

    assert Runtime.Run.valid?(run)
    assert inspect(run) == "#Synapse.Runtime.Run<opaque>"

    assert_receive {:runtime_workspace_opened, task, open_request, workspace_backend}
    assert task == run.task
    assert open_request.owner == task
    assert open_request.root == request.cwd
    assert open_request.access == %Access{read: true, write: true, exec: true}
    assert open_request.limits == Synapse.Workspace.Limits.default()
    assert task != self()
    assert task != run.server
    assert :sys.get_state(workspace_backend).owner == task

    assert_receive {:runtime_provider_called, ^task, provider_request, stream_context}
    assert provider_request.model == request.model
    assert provider_request.instructions == "Exact trusted Runtime instructions"
    assert first_prompt(provider_request) == request.prompt
    assert stream_context.operation_id == operation_id
    assert stream_context.cancel_ref == run.cancel_ref
    assert stream_context.deadline == deadline
    assert stream_context.inactivity_ms == request.budget.provider_inactivity_ms
    assert stream_context.activity_sink == nil

    run_state = :sys.get_state(run.server)
    assert run_state.owner == self()
    assert run_state.task.pid == task
    assert run_state.event_sink == sink
    assert run_state.workspace_backend == workspace_backend
    assert is_reference(run_state.workspace_monitor)
    assert run_state.phase == :running
    refute Map.has_key?(Map.from_struct(run_state), :request)
    refute Map.has_key?(Map.from_struct(run_state), :options)
    refute Map.has_key?(Map.from_struct(run_state), :workspace)

    {:links, links} = Process.info(run.server, :links)
    assert task in links
    {:monitors, monitors} = Process.info(run.server, :monitors)
    assert {:process, task} in monitors
    assert Process.info(task, :trap_exit) == {:trap_exit, false}
    assert Task.Supervisor.children(Synapse.TaskSupervisor) == [task]

    task_monitor = Process.monitor(task)
    server_monitor = Process.monitor(run.server)
    workspace_monitor = Process.monitor(workspace_backend)
    send(task, {:release_runtime_provider, operation_id})

    assert_receive {:DOWN, ^workspace_monitor, :process, ^workspace_backend, _reason}
    assert_receive {:DOWN, ^task_monitor, :process, ^task, :normal}
    assert_receive {:DOWN, ^server_monitor, :process, _, :normal}

    events = drain_events()

    assert Enum.map(events, & &1.__struct__) == [
             RunStarted,
             TurnStarted,
             TextDelta,
             TurnCompleted,
             RunCompleted
           ]

    refute Enum.any?(events, &match?(%RunFailed{}, &1))
    refute Enum.any?(events, &match?(%RunInterrupted{}, &1))
    assert DynamicSupervisor.count_children(Synapse.Runtime.Supervisor).active == 0
  end

  test "maps all capability combinations exactly before Provider starts" do
    Enum.each(0..7, fn mask ->
      capabilities =
        capabilities(
          Bitwise.band(mask, 1) == 1,
          Bitwise.band(mask, 2) == 2,
          Bitwise.band(mask, 4) == 4
        )

      request = run_request("runtime-access-#{mask}", capabilities)
      run_id = request.id
      test_pid = self()

      opener = fn open_request ->
        send(test_pid, {:captured_open_request, mask, self(), open_request})
        {:error, {:raw_workspace_failure, "/SYNTHETIC/SECRET/PATH"}}
      end

      assert {:error, %Error{reason: :workspace_open_failed, run_id: ^run_id}} =
               Runtime.start_run(request, fn _event -> :ok end,
                 provider: TestProvider,
                 workspace_opener: opener
               )

      assert_receive {:captured_open_request, ^mask, task, open_request}
      assert task == open_request.owner
      assert open_request.root == request.cwd

      assert open_request.access == %Access{
               read: capabilities.fs_read,
               write: capabilities.fs_write,
               exec: capabilities.process_exec
             }

      refute_received {:runtime_provider_called, _task, _request, _context}
      assert DynamicSupervisor.count_children(Synapse.Runtime.Supervisor).active == 0
    end)
  end

  test "Workspace opener failures are sanitized, log-free, and start no Provider turn" do
    failures = [
      fn _request -> {:error, {:secret, "/SYNTHETIC/SECRET/PATH"}} end,
      fn _request -> raise "SYNTHETIC_RUNTIME_OPENER_SECRET" end,
      fn _request -> throw("SYNTHETIC_RUNTIME_OPENER_SECRET") end,
      fn _request -> exit("SYNTHETIC_RUNTIME_OPENER_SECRET") end
    ]

    Enum.with_index(failures, fn opener, index ->
      request = run_request("runtime-open-failure-#{index}")
      configure_provider(request)

      log =
        capture_log(fn ->
          assert {:error, %Error{reason: :workspace_open_failed} = error} =
                   Runtime.start_run(request, fn _event -> :ok end,
                     provider: TestProvider,
                     workspace_opener: opener
                   )

          refute inspect(error) =~ "SYNTHETIC"
          refute error.message =~ "SYNTHETIC"
        end)

      refute log =~ "SYNTHETIC_RUNTIME_OPENER_SECRET"
      refute log =~ "/SYNTHETIC/SECRET/PATH"
      refute_received {:runtime_provider_called, _task, _request, _context}
      assert DynamicSupervisor.count_children(Synapse.Runtime.Supervisor).active == 0
      assert Task.Supervisor.children(Synapse.TaskSupervisor) == []
    end)
  end

  test "exact cancellation, deadline, activity, and reduced Access reach Provider and Tool" do
    request = run_request("runtime-context", capabilities(true, false, false))
    deadline = System.monotonic_time(:millisecond) + 60_000
    {:ok, first_provider_id} = OperationId.provider(request.id, 1, 1)
    {:ok, second_provider_id} = OperationId.provider(request.id, 2, 1)
    {:ok, tool_id} = OperationId.tool(request.id, 1, 1)

    first_response =
      provider_response(request, "runtime-tool-response", [
        %FunctionCall{
          id: "runtime-tool-item",
          call_id: "runtime-tool-call",
          name: "read",
          arguments: %{"path" => "mix.exs", "offset" => nil, "limit" => nil}
        }
      ])

    configure_provider_operation(first_provider_id, first_response)
    configure_provider_operation(second_provider_id, response(request, "Context finished"), true)
    test_pid = self()

    opener = fn open_request ->
      send(test_pid, {:runtime_tool_opener_ready, self(), open_request})

      receive do
        {:open_runtime_tool_workspace, entry} ->
          {:ok, handle} =
            Workspace.Fake.open([entry],
              owner: open_request.owner,
              limits: open_request.limits,
              access: open_request.access
            )

          send(test_pid, {:runtime_tool_workspace, handle})
          {:ok, handle}
      end
    end

    caller =
      spawn(fn ->
        result =
          Runtime.start_run(request, fn _event -> :ok end,
            provider: TestProvider,
            deadline: deadline,
            workspace_opener: opener
          )

        send(test_pid, {:runtime_tool_start, result})
      end)

    caller_monitor = Process.monitor(caller)

    assert_receive {:runtime_tool_opener_ready, task, open_request}
    [server] = runtime_children()
    state = :sys.get_state(server)
    assert state.task.pid == task

    {:ok, read_access} = Access.new(read: true, write: false, exec: false)

    {:ok, operation_context} =
      OperationContext.new(
        operation_id: tool_id,
        access: read_access,
        cancel_ref: state.cancel_ref,
        deadline: deadline,
        activity_sink: nil
      )

    tool_limits = ToolLimits.default()

    {:ok, read_request} =
      ReadRequest.new(
        path: "mix.exs",
        start_line: 1,
        line_count: tool_limits.default_read_lines,
        max_bytes: tool_limits.default_read_source_bytes
      )

    {:ok, revision} = Revision.from_mac(:binary.copy(<<1>>, 32))
    {:ok, line} = ReadLine.new(number: 1, text: "project", ending: :none, truncated: false)

    {:ok, read_result} =
      ReadResult.new(
        path: "mix.exs",
        revision: revision,
        lines: [line],
        next_line: nil,
        file_bytes: 7
      )

    entry = Workspace.Fake.expect_read(read_request, operation_context, {:ok, read_result})
    send(task, {:open_runtime_tool_workspace, entry})

    assert_receive {:runtime_tool_workspace, handle}
    assert handle.access == open_request.access
    assert {:runtime_tool_start, {:ok, run}} = receive_runtime_tool_start()
    register_run_cleanup(run, second_provider_id)
    assert run.task == task
    assert run.cancel_ref == state.cancel_ref

    assert_receive {:runtime_provider_called, ^task, _first_request, first_context}
    assert first_context.operation_id == first_provider_id
    assert first_context.cancel_ref == run.cancel_ref
    assert first_context.deadline == deadline
    assert first_context.activity_sink == nil

    assert_receive {:runtime_provider_called, ^task, _second_request, second_context}
    assert second_context.operation_id == second_provider_id
    assert second_context.cancel_ref == run.cancel_ref
    assert second_context.deadline == deadline
    assert second_context.activity_sink == nil
    assert Workspace.Fake.remaining_operations(handle) == {:ok, 0}

    task_monitor = Process.monitor(task)
    server_monitor = Process.monitor(server)
    send(task, {:release_runtime_provider, second_provider_id})
    assert_receive {:DOWN, ^task_monitor, :process, ^task, :normal}
    assert_receive {:DOWN, ^server_monitor, :process, ^server, :normal}
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}
  end

  test "a mismatched opener Handle is closed before sanitized startup failure" do
    request = run_request("runtime-mismatched-handle")
    test_pid = self()
    {:ok, no_access} = Access.new(read: false, write: false, exec: false)

    opener = fn open_request ->
      {:ok, handle} =
        Workspace.Fake.open([],
          owner: open_request.owner,
          limits: open_request.limits,
          access: no_access
        )

      send(test_pid, {:mismatched_workspace, handle.state})
      {:ok, handle}
    end

    assert {:error, %Error{reason: :workspace_open_failed}} =
             Runtime.start_run(request, fn _event -> :ok end,
               provider: TestProvider,
               workspace_opener: opener
             )

    assert_receive {:mismatched_workspace, backend}
    refute Process.alive?(backend)
    assert DynamicSupervisor.count_children(Synapse.Runtime.Supervisor).active == 0
  end

  test "startup failure waits for owner-down Workspace settlement after close failure" do
    request = run_request("runtime-close-failure")
    test_pid = self()
    {:ok, no_access} = Access.new(read: false, write: false, exec: false)

    opener = fn open_request ->
      handle =
        CloseFailBackend.open(
          open_request.owner,
          open_request.limits,
          no_access,
          test_pid
        )

      send(test_pid, {:close_fail_workspace_opened, self(), handle.state})
      {:ok, handle}
    end

    caller =
      spawn(fn ->
        result =
          Runtime.start_run(request, fn _event -> :ok end,
            provider: TestProvider,
            workspace_opener: opener
          )

        send(test_pid, {:close_fail_start_result, result})
      end)

    caller_monitor = Process.monitor(caller)
    assert_receive {:close_fail_workspace_opened, task, backend}
    assert task != caller
    assert_receive {:close_fail_owner_down, ^backend}
    refute_received {:close_fail_start_result, _result}
    assert Process.alive?(backend)

    send(backend, :finish_close_fail_cleanup)

    assert_receive {:close_fail_start_result, {:error, %Error{reason: :workspace_open_failed}}}

    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}
    refute Process.alive?(backend)
    assert DynamicSupervisor.count_children(Synapse.Runtime.Supervisor).active == 0
  end

  test "caller death during blocked readiness aborts Runner and cleans task and Workspace" do
    request = run_request("runtime-dead-caller")
    configure_provider(request)
    test_pid = self()

    opener = fn open_request ->
      {:ok, handle} =
        Workspace.Fake.open([],
          owner: open_request.owner,
          limits: open_request.limits,
          access: open_request.access
        )

      send(test_pid, {:blocked_readiness, self(), handle.state})

      receive do
        :release_runtime_opener -> {:ok, handle}
      end
    end

    caller =
      spawn(fn ->
        result =
          Runtime.start_run(request, fn _event -> :ok end,
            provider: TestProvider,
            workspace_opener: opener
          )

        send(test_pid, {:unexpected_start_result, result})
      end)

    assert_receive {:blocked_readiness, task, backend}
    [server] = runtime_children()
    task_monitor = Process.monitor(task)
    backend_monitor = Process.monitor(backend)
    server_monitor = Process.monitor(server)
    caller_monitor = Process.monitor(caller)

    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}

    send(task, :release_runtime_opener)
    assert_receive {:DOWN, ^backend_monitor, :process, ^backend, _reason}
    assert_receive {:DOWN, ^task_monitor, :process, ^task, :normal}
    assert_receive {:DOWN, ^server_monitor, :process, ^server, :normal}
    refute_received {:runtime_provider_called, _task, _request, _context}
    refute_received {:unexpected_start_result, _result}
    assert DynamicSupervisor.count_children(Synapse.Runtime.Supervisor).active == 0
  end

  test "a second public start is busy before its opener or Agent task starts" do
    first = run_request("runtime-busy-first")
    second = run_request("runtime-busy-second")
    second_id = second.id
    first_operation = configure_provider(first, block?: true)
    test_pid = self()

    assert {:ok, first_run} =
             Runtime.start_run(first, fn _event -> :ok end,
               provider: TestProvider,
               workspace_opener: fake_opener()
             )

    register_run_cleanup(first_run, first_operation)

    assert_receive {:runtime_provider_called, first_task, _request, _context}
    assert first_task == first_run.task

    assert {:error, %Error{reason: :runtime_busy, run_id: ^second_id}} =
             Runtime.start_run(second, fn _event -> :ok end,
               provider: TestProvider,
               workspace_opener: fn open_request ->
                 send(test_pid, {:second_opener_called, open_request})
                 fake_open(open_request)
               end
             )

    refute_received {:second_opener_called, _request}
    assert Task.Supervisor.children(Synapse.TaskSupervisor) == [first_task]

    task_monitor = Process.monitor(first_task)
    server_monitor = Process.monitor(first_run.server)
    send(first_task, {:release_runtime_provider, first_operation})
    assert_receive {:DOWN, ^task_monitor, :process, ^first_task, :normal}
    assert_receive {:DOWN, ^server_monitor, :process, _, :normal}
  end

  test "sequential runs receive distinct process and control authority" do
    runs =
      Enum.map(1..2, fn ordinal ->
        request = run_request("runtime-distinct-#{ordinal}")
        operation_id = configure_provider(request, block?: true)

        assert {:ok, run} =
                 Runtime.start_run(request, fn _event -> :ok end,
                   provider: TestProvider,
                   workspace_opener: fake_opener()
                 )

        register_run_cleanup(run, operation_id)

        assert_receive {:runtime_provider_called, task, _request, _context}
        assert task == run.task
        task_monitor = Process.monitor(task)
        server_monitor = Process.monitor(run.server)
        send(task, {:release_runtime_provider, operation_id})
        assert_receive {:DOWN, ^task_monitor, :process, ^task, :normal}
        assert_receive {:DOWN, ^server_monitor, :process, _, :normal}
        run
      end)

    [first, second] = runs

    refute first.run_ref == second.run_ref
    refute first.cancel_ref == second.cancel_ref
    refute first.cancellation == second.cancellation
    refute first.await_state == second.await_state
    refute first.task == second.task
    refute first.server == second.server
  end

  test "Runtime startup imports no host-operation or Provider wire modules" do
    runtime_root = Path.join([__DIR__, "..", "lib", "synapse"])

    sources =
      [
        Path.join(runtime_root, "runtime.ex")
        | Path.wildcard(Path.join(runtime_root, "runtime/*.ex"))
      ]
      |> Enum.map(&(File.read!(&1) |> strip_module_documentation()))

    forbidden = [
      "File.",
      "System.",
      "Port.",
      "MuonTrap",
      "Req.",
      "Finch.",
      "ResponsesCodec",
      "ResponsesStream",
      "SSEDecoder",
      "Workspace.Real",
      "Workspace.Fake"
    ]

    Enum.each(sources, fn source ->
      Enum.each(forbidden, &refute(source =~ &1))
    end)
  end

  defp configure_provider(request, options \\ []) do
    {:ok, operation_id} = OperationId.provider(request.id, 1, 1)
    response = Keyword.get(options, :response, response(request, "Runtime finished"))

    events =
      if Keyword.get(options, :text_delta?, false) do
        [%ProviderTextDelta{item_id: "runtime-message", content_index: 0, delta: "Runtime"}]
      else
        []
      end

    configure_provider_operation(
      operation_id,
      response,
      Keyword.get(options, :block?, false),
      events
    )

    operation_id
  end

  defp configure_provider_operation(operation_id, response, block? \\ false, events \\ []) do
    :persistent_term.put(
      {TestProvider, operation_id},
      %{test_pid: self(), response: response, events: events, block?: block?}
    )

    on_exit(fn -> :persistent_term.erase({TestProvider, operation_id}) end)
  end

  defp run_request(id, capabilities \\ capabilities(true, true, true)) do
    {:ok, request} =
      Request.new(
        id: id,
        prompt: "Inspect the Runtime project",
        cwd: "/synthetic/runtime/project",
        model: "runtime-test-model",
        capabilities: capabilities,
        budget: Budget.default()
      )

    request
  end

  defp capabilities(read, write, exec) do
    {:ok, capabilities} =
      CapabilitySet.new(fs_read: read, fs_write: write, process_exec: exec)

    capabilities
  end

  defp response(request, text) do
    provider_response(request, "response-#{request.id}", [
      %ProviderMessage{id: "runtime-message", role: :assistant, content: text}
    ])
  end

  defp provider_response(request, id, output_items) do
    {:ok, response} =
      Provider.Response.new(
        id: id,
        model: request.model,
        output_items: output_items
      )

    response
  end

  defp fake_opener do
    fn open_request -> fake_open(open_request) end
  end

  defp fake_open(open_request) do
    Workspace.Fake.open([],
      owner: open_request.owner,
      limits: open_request.limits,
      access: open_request.access
    )
  end

  defp first_prompt(provider_request) do
    [
      %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => prompt}]
      }
    ] = provider_request.input_items

    prompt
  end

  defp receive_runtime_tool_start do
    receive do
      {:runtime_tool_start, _result} = message -> message
    end
  end

  defp drain_events(events \\ []) do
    receive do
      {:runtime_event, event} -> drain_events([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp runtime_children do
    Synapse.Runtime.Supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
  end

  defp register_run_cleanup(run, operation_id) do
    on_exit(fn ->
      send(run.task, {:release_runtime_provider, operation_id})

      if Process.alive?(run.server) do
        server_monitor = Process.monitor(run.server)
        task_monitor = Process.monitor(run.task)
        Process.exit(run.server, :kill)

        receive do
          {:DOWN, ^server_monitor, :process, _, _reason} -> :ok
        after
          1_000 -> :ok
        end

        receive do
          {:DOWN, ^task_monitor, :process, _, _reason} -> :ok
        after
          1_000 -> :ok
        end
      end
    end)
  end

  defp strip_module_documentation(source) do
    Regex.replace(~r/@moduledoc\s+""".*?"""/s, source, "")
  end
end
