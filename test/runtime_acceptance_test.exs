defmodule Synapse.Runtime.AcceptanceTest.ObservingFake do
  alias Synapse.Workspace.{Fake, Handle}

  def workspace_backend?, do: true

  def valid_handle?(%Handle{} = handle), do: Fake.valid_handle?(fake_handle(handle))

  def close(%Handle{} = handle) do
    fake = fake_handle(handle)
    %{test_pid: test_pid} = :persistent_term.get({__MODULE__, handle.state})
    send(test_pid, {:acceptance_fake_closing, handle.state, Fake.remaining_operations(fake)})
    Fake.close(fake)
  end

  def read(handle, request, context),
    do: Fake.read(fake_handle(handle), request, context)

  def write(handle, request, context),
    do: Fake.write(fake_handle(handle), request, context)

  def edit(handle, request, context),
    do: Fake.edit(fake_handle(handle), request, context)

  def run(handle, spec, event_sink, context) do
    %{test_pid: test_pid} = :persistent_term.get({__MODULE__, handle.state})
    send(test_pid, {:acceptance_fake_run, spec, context})
    Fake.run(fake_handle(handle), spec, event_sink, context)
  end

  defp fake_handle(handle), do: %{handle | backend: Fake}
end

defmodule Synapse.Runtime.AcceptanceTest do
  use ExUnit.Case, async: false

  alias Synapse.Agent.OperationId
  alias Synapse.Provider.{Fake, Response}
  alias Synapse.Provider.OutputItem.{FunctionCall, Message}
  alias Synapse.Run.Event
  alias Synapse.Runtime
  alias Synapse.Runtime.AcceptanceTest.ObservingFake
  alias Synapse.Tool.{CapabilitySet, Limits}
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

  test "public Runtime completes exact Fake read, write, bash, and final text without host effects" do
    test_pid = self()
    root = nonexistent_temporary_root("fake")
    request = run_request("runtime-fake-acceptance", root)
    deadline = System.monotonic_time(:millisecond) + 60_000
    provider_ids = provider_ids(request, 2)
    tool_ids = Map.new(1..3, &{&1, tool_id(request, 1, &1)})
    calls = fake_calls()

    script = [
      {:turn, [], {:ok, response!("runtime-fake-tools", calls)}},
      {:turn, [], {:ok, text_response("runtime-fake-final", "Read, wrote, and verified.")}}
    ]

    {:ok, provider_owner} = Fake.start_link(provider_ids, script)
    on_exit(fn -> stop_if_alive(provider_owner) end)
    opener = controlled_fake_opener(test_pid)
    sink = acceptance_sink(test_pid, :fake)

    caller =
      spawn(fn ->
        result =
          Runtime.start_run(request, sink,
            provider: Fake,
            deadline: deadline,
            workspace_opener: opener
          )

        send(test_pid, {:acceptance_start_result, self(), result})

        receive do
          {:await_acceptance, run} ->
            send(test_pid, {:acceptance_await_result, Runtime.await(run, :infinity)})
        end
      end)

    caller_monitor = Process.monitor(caller)
    assert_receive {:acceptance_fake_open, task, open_request}
    assert open_request.owner == task
    assert open_request.root == root
    [server] = runtime_children()
    state = :sys.get_state(server)
    assert state.task.pid == task

    entries = fake_entries(tool_ids, state.cancel_ref, deadline)
    send(task, {:acceptance_open_fake, entries})
    assert_receive {:acceptance_fake_ready, ^task, backend}

    :persistent_term.put(
      {ObservingFake, backend},
      %{test_pid: test_pid}
    )

    :persistent_term.put({__MODULE__, :fake_backend}, backend)

    on_exit(fn -> :persistent_term.erase({ObservingFake, backend}) end)
    on_exit(fn -> :persistent_term.erase({__MODULE__, :fake_backend}) end)
    send(task, :acceptance_release_fake)

    assert_receive {:acceptance_start_result, ^caller, {:ok, run}}
    assert run.task == task
    assert run.server == server
    send(caller, {:await_acceptance, run})

    assert_receive {:acceptance_fake_run, observed_spec, observed_context}
    assert observed_spec == process_spec("mix test")
    assert observed_context == operation_context(tool_ids[3], :exec, run.cancel_ref, deadline)

    assert_receive {:acceptance_fake_closing, ^backend, {:ok, 0}}
    assert_receive {:fake_terminal_settlement, %Event.RunCompleted{}, false}
    assert_receive {:acceptance_await_result, {:ok, result}}
    assert result.text == "Read, wrote, and verified."
    assert result.turns == 2
    assert result.tool_calls == 3
    assert result.provider_retries == 0

    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}
    assert Enum.all?(provider_ids, &(Fake.remaining_turns(&1) == {:ok, 0}))

    events = drain_events(:fake)

    assert Enum.map(events, & &1.__struct__) == [
             Event.RunStarted,
             Event.TurnStarted,
             Event.ToolStarted,
             Event.ToolCompleted,
             Event.ToolStarted,
             Event.ToolCompleted,
             Event.ToolStarted,
             Event.ToolCompleted,
             Event.TurnCompleted,
             Event.TurnStarted,
             Event.TurnCompleted,
             Event.RunCompleted
           ]

    assert Enum.map(Enum.filter(events, &match?(%Event.ToolStarted{}, &1)), & &1.name) ==
             ~w(read write bash)

    assert Enum.all?(Enum.filter(events, &match?(%Event.ToolCompleted{}, &1)), fn event ->
             event.status == :ok
           end)

    assert [
             %Event.TurnCompleted{outcome: :continued, tool_calls: 3},
             %Event.TurnCompleted{outcome: :completed, tool_calls: 0}
           ] =
             Enum.filter(events, &match?(%Event.TurnCompleted{}, &1))

    refute File.exists?(root)
    refute Process.alive?(backend)
    assert_runtime_empty()
  end

  test "Runtime and lower components preserve their dependency boundaries" do
    runtime_sources =
      Path.wildcard(Path.join([__DIR__, "..", "lib", "synapse", "runtime", "*.ex"])) ++
        [Path.join([__DIR__, "..", "lib", "synapse", "runtime.ex"])]

    runtime_source = runtime_sources |> Enum.map(&File.read!/1) |> Enum.join("\n")

    Enum.each(
      [
        "Workspace.read",
        "Workspace.write",
        "Workspace.edit",
        "Workspace.run",
        "Req.",
        "Finch.",
        "ResponsesCodec",
        "SSEDecoder",
        "MuonTrap",
        "File.",
        "System.",
        "Port."
      ],
      &refute(runtime_source =~ &1)
    )

    assert runtime_source =~ "Runner.run"
    assert runtime_source =~ "Workspace.open"
    assert runtime_source =~ "Workspace.close"

    lower_source =
      ~w(provider agent tool workspace)
      |> Enum.flat_map(fn component ->
        Path.wildcard(Path.join([__DIR__, "..", "lib", "synapse", component, "**", "*.ex"]))
      end)
      |> Enum.map(&File.read!/1)
      |> Enum.join("\n")

    refute Regex.match?(~r/(alias|import|require)\s+Synapse\.Runtime/, lower_source)
    refute lower_source =~ "Synapse.Runtime."
  end

  @tag skip: not Synapse.Workspace.Platform.supported?()
  test "public Runtime verifies a temporary Real Workspace and settles every owner" do
    root = create_temporary_root("real-success")
    on_exit(fn -> File.rm_rf!(root) end)
    File.write!(Path.join(root, "source.txt"), "SYNAPSE_RUNTIME_SOURCE\n")
    label = :real_success
    request = run_request("runtime-real-acceptance", root)
    provider_ids = provider_ids(request, 2)

    command =
      "printf '%s' $$ > command.pid; " <>
        "test \"$(cat source.txt)\" = SYNAPSE_RUNTIME_SOURCE; " <>
        "test \"$(cat created.txt)\" = runtime-acceptance; " <>
        "printf SYNAPSE_RUNTIME_VERIFY_OK"

    calls = [
      call("real-read", "real-call-read", "read", %{
        "path" => "source.txt",
        "offset" => nil,
        "limit" => nil
      }),
      call("real-write", "real-call-write", "write", %{
        "path" => "created.txt",
        "content" => "runtime-acceptance\n",
        "expected_revision" => "missing"
      }),
      call("real-bash", "real-call-bash", "bash", %{
        "command" => command,
        "timeout_ms" => 5_000
      })
    ]

    script = [
      {:turn, [], {:ok, response!("runtime-real-tools", calls)}},
      {:turn, [], {:ok, text_response("runtime-real-final", "Temporary project verified.")}}
    ]

    {:ok, provider_owner} = Fake.start_link(provider_ids, script)
    on_exit(fn -> stop_if_alive(provider_owner) end)

    assert {:ok, run} =
             Runtime.start_run(request, real_sink(self(), label, true),
               provider: Fake,
               workspace_opener: real_opener(self(), label)
             )

    register_run_cleanup(run)
    assert_receive {:acceptance_real_opened, ^label, task, backend, environment}
    assert task == run.task
    configure_real_observer(label, backend)
    backend_monitor = Process.monitor(backend)
    guard_monitor = Process.monitor(environment.guard)
    assert_receive {:acceptance_event, ^label, %Event.RunStarted{} = run_started}
    send(run.server, {:release_acceptance_run_started, label})
    events = collect_through_terminal(label, [run_started])

    assert {:ok, result} = Runtime.await(run, :infinity)
    assert result.text == "Temporary project verified."
    assert result.turns == 2
    assert result.tool_calls == 3
    assert_receive {:acceptance_real_terminal, ^label, %Event.RunCompleted{}, false}
    assert_receive {:DOWN, ^backend_monitor, :process, ^backend, _reason}
    assert_receive {:DOWN, ^guard_monitor, :process, _guard, _reason}

    assert File.read!(Path.join(root, "created.txt")) == "runtime-acceptance\n"
    command_pid = root |> Path.join("command.pid") |> File.read!() |> String.trim()
    refute os_process_alive?(command_pid)
    refute File.exists?(environment.root)

    assert {"SYNAPSE_RUNTIME_VERIFY_OK", 0} =
             System.cmd(
               "/bin/bash",
               [
                 "-lc",
                 "test \"$(cat source.txt)\" = SYNAPSE_RUNTIME_SOURCE && " <>
                   "test \"$(cat created.txt)\" = runtime-acceptance && " <>
                   "printf SYNAPSE_RUNTIME_VERIFY_OK"
               ],
               cd: root,
               stderr_to_stdout: true
             )

    assert Enum.all?(provider_ids, &(Fake.remaining_turns(&1) == {:ok, 0}))

    assert Enum.map(Enum.filter(events, &match?(%Event.ToolStarted{}, &1)), & &1.name) ==
             ~w(read write bash)

    assert Enum.count(events, &match?(%Event.ToolCompleted{status: :ok}, &1)) == 3
    assert_runtime_empty()
  end

  @tag skip: not Synapse.Workspace.Platform.supported?()
  test "public Runtime cancels a temporary Real command and confirms direct cleanup" do
    root = create_temporary_root("real-cancel")
    on_exit(fn -> File.rm_rf!(root) end)
    label = :real_cancel
    request = run_request("runtime-real-cancel", root)
    provider_ids = provider_ids(request, 2)

    command =
      "printf '%s' $$ > long.pid; printf ready; " <>
        "trap '' TERM; while :; do :; done"

    calls = [
      call("cancel-bash", "cancel-call-bash", "bash", %{
        "command" => command,
        "timeout_ms" => 60_000
      })
    ]

    script = [
      {:turn, [], {:ok, response!("runtime-cancel-tools", calls)}},
      {:turn, [], {:ok, text_response("runtime-cancel-never", "must not run")}}
    ]

    {:ok, provider_owner} = Fake.start_link(provider_ids, script)
    on_exit(fn -> stop_if_alive(provider_owner) end)

    assert {:ok, run} =
             Runtime.start_run(request, real_sink(self(), label, false),
               provider: Fake,
               workspace_opener: real_opener(self(), label)
             )

    register_run_cleanup(run)
    assert_receive {:acceptance_real_opened, ^label, task, backend, environment}
    assert task == run.task
    configure_real_observer(label, backend)
    backend_monitor = Process.monitor(backend)
    guard_monitor = Process.monitor(environment.guard)
    assert_receive {:acceptance_event, ^label, %Event.ToolStarted{name: "bash"}}
    command_pid = await_pid_file(Path.join(root, "long.pid"))

    assert :ok = Runtime.cancel(run)

    assert {:error, %Synapse.Agent.Error{kind: :cancelled, reason: :run_cancelled} = error} =
             Runtime.await(run, :infinity)

    assert error.details["status"] == "ambiguous"
    assert error.details["outcome"] == "unknown"
    assert_receive {:acceptance_real_terminal, ^label, %Event.RunInterrupted{}, false}
    assert_receive {:DOWN, ^backend_monitor, :process, ^backend, _reason}
    assert_receive {:DOWN, ^guard_monitor, :process, _guard, _reason}
    refute os_process_alive?(command_pid)
    refute File.exists?(environment.root)
    assert Enum.all?(provider_ids, &(Fake.remaining_turns(&1) == {:ok, 1}))

    events = drain_events(label)
    refute Enum.any?(events, &match?(%Event.TurnStarted{turn: 2}, &1))
    assert Enum.any?(events, &match?(%Event.RunInterrupted{}, &1))
    assert_runtime_empty()
  end

  defp controlled_fake_opener(test_pid) do
    fn open_request ->
      send(test_pid, {:acceptance_fake_open, self(), open_request})

      receive do
        {:acceptance_open_fake, entries} ->
          {:ok, handle} =
            WorkspaceFake.open(entries,
              owner: open_request.owner,
              limits: open_request.limits,
              access: open_request.access
            )

          observed = %{handle | backend: ObservingFake}
          send(test_pid, {:acceptance_fake_ready, self(), handle.state})

          receive do
            :acceptance_release_fake -> {:ok, observed}
          end
      end
    end
  end

  defp fake_calls do
    [
      call("item-read", "call-read", "read", %{
        "path" => "source.txt",
        "offset" => nil,
        "limit" => nil
      }),
      call("item-write", "call-write", "write", %{
        "path" => "created.txt",
        "content" => "new",
        "expected_revision" => "missing"
      }),
      call("item-bash", "call-bash", "bash", %{
        "command" => "mix test",
        "timeout_ms" => nil
      })
    ]
  end

  defp fake_entries(tool_ids, cancel_ref, deadline) do
    read_revision = revision(1)
    write_revision = revision(2)

    [
      WorkspaceFake.expect_read(
        read_request("source.txt"),
        operation_context(tool_ids[1], :read, cancel_ref, deadline),
        {:ok, read_result("source.txt", read_revision, "old")}
      ),
      WorkspaceFake.expect_write(
        write_request("created.txt", "new", :missing),
        operation_context(tool_ids[2], :write, cancel_ref, deadline),
        {:ok, mutation_result(tool_ids[2], "created.txt", write_revision)}
      ),
      WorkspaceFake.expect_run(
        process_spec("mix test"),
        operation_context(tool_ids[3], :exec, cancel_ref, deadline),
        process_events(tool_ids[3], "ok"),
        {:ok, process_result(tool_ids[3], "ok")}
      )
    ]
  end

  defp acceptance_sink(test_pid, :fake) do
    fn
      %Event.RunCompleted{} = event ->
        backend = :persistent_term.get({__MODULE__, :fake_backend}, nil)
        send(test_pid, {:fake_terminal_settlement, event, process_alive?(backend)})
        send(test_pid, {:acceptance_event, :fake, event})
        :ok

      event ->
        send(test_pid, {:acceptance_event, :fake, event})
        :ok
    end
  end

  defp real_opener(test_pid, label) do
    fn open_request ->
      case Workspace.open(open_request) do
        {:ok, handle} ->
          environment = :sys.get_state(handle.state).process_environment
          send(test_pid, {:acceptance_real_opened, label, self(), handle.state, environment})
          {:ok, handle}

        {:error, _error} = failure ->
          failure
      end
    end
  end

  defp real_sink(test_pid, label, block_started?) do
    fn event ->
      send(test_pid, {:acceptance_event, label, event})

      if block_started? and match?(%Event.RunStarted{}, event) do
        receive do
          {:release_acceptance_run_started, ^label} -> :ok
        end
      end

      if match?(%Event.RunCompleted{}, event) or match?(%Event.RunFailed{}, event) or
           match?(%Event.RunInterrupted{}, event) do
        backend = :persistent_term.get({__MODULE__, {:real_backend, label}}, nil)
        send(test_pid, {:acceptance_real_terminal, label, event, process_alive?(backend)})
      end

      :ok
    end
  end

  defp configure_real_observer(label, backend) do
    key = {__MODULE__, {:real_backend, label}}
    :persistent_term.put(key, backend)
    on_exit(fn -> :persistent_term.erase(key) end)
  end

  defp run_request(id, root) do
    {:ok, capabilities} =
      CapabilitySet.new(fs_read: true, fs_write: true, process_exec: true)

    {:ok, request} =
      Synapse.Run.Request.new(
        id: id,
        prompt: "Inspect, change, and verify the synthetic project",
        cwd: root,
        model: "test-model",
        capabilities: capabilities,
        budget: Synapse.Budget.default()
      )

    request
  end

  defp provider_ids(request, turns),
    do: Enum.map(1..turns, fn turn -> elem(OperationId.provider(request.id, turn, 1), 1) end)

  defp tool_id(request, turn, ordinal),
    do: elem(OperationId.tool(request.id, turn, ordinal), 1)

  defp response!(id, output_items) do
    {:ok, response} = Response.new(id: id, model: "test-model", output_items: output_items)
    response
  end

  defp text_response(id, text),
    do: response!(id, [%Message{id: "message-#{id}", role: :assistant, content: text}])

  defp call(id, call_id, name, arguments),
    do: %FunctionCall{id: id, call_id: call_id, name: name, arguments: arguments}

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

  defp mutation_result(operation_id, path, revision) do
    {:ok, result} =
      MutationResult.new(
        operation_id: operation_id,
        path: path,
        previous_revision: :missing,
        revision: revision,
        bytes_written: 3,
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

  defp drain_events(label, events \\ []) do
    receive do
      {:acceptance_event, ^label, event} -> drain_events(label, [event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp collect_through_terminal(label, events) do
    receive do
      {:acceptance_event, ^label, event} ->
        events = [event | events]

        if match?(%Event.RunCompleted{}, event) or match?(%Event.RunFailed{}, event) or
             match?(%Event.RunInterrupted{}, event),
           do: Enum.reverse(events),
           else: collect_through_terminal(label, events)
    after
      10_000 ->
        modules = Enum.map(Enum.reverse(events), & &1.__struct__)
        flunk("Runtime Real acceptance emitted no terminal after #{inspect(modules)}")
    end
  end

  defp runtime_children do
    Synapse.Runtime.Supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
  end

  defp assert_runtime_empty do
    assert DynamicSupervisor.count_children(Synapse.Runtime.Supervisor).active == 0
    assert Task.Supervisor.children(Synapse.TaskSupervisor) == []
    assert DynamicSupervisor.count_children(Synapse.Workspace.Supervisor).active == 0
  end

  defp register_run_cleanup(run) do
    on_exit(fn ->
      if Process.alive?(run.server), do: Process.exit(run.server, :kill)
    end)
  end

  defp process_alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp process_alive?(_pid), do: false

  defp stop_if_alive(pid) do
    if Process.alive?(pid), do: Agent.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  defp nonexistent_temporary_root(label) do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

    Path.join(
      System.tmp_dir!(),
      "synapse-runtime-#{label}-#{suffix}"
    )
  end

  defp create_temporary_root(label) do
    root = nonexistent_temporary_root(label)
    File.mkdir!(root)
    root
  end

  defp await_pid_file(path, attempts \\ 200)
  defp await_pid_file(_path, 0), do: flunk("Real command did not publish its PID")

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
