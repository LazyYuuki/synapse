defmodule Synapse.WebFixture.ControlledFake do
  @behaviour Synapse.Workspace.Backend

  alias Synapse.Workspace.{Fake, Handle}

  @impl true
  def workspace_backend?, do: true

  @impl true
  def valid_handle?(%Handle{} = handle), do: Fake.valid_handle?(fake(handle))

  @impl true
  def close(%Handle{} = handle) do
    fake = fake(handle)
    remaining = Fake.remaining_operations(fake)
    result = Fake.close(fake)
    GenServer.call(Synapse.WebFixture.Controller, {:closed, handle.state, remaining})
    result
  end

  @impl true
  def read(handle, request, context) do
    await(:read)
    Fake.read(fake(handle), request, context)
  end

  @impl true
  def write(handle, request, context) do
    await(:write)
    Fake.write(fake(handle), request, context)
  end

  @impl true
  def edit(handle, request, context) do
    await(:edit)
    Fake.edit(fake(handle), request, context)
  end

  @impl true
  def run(handle, spec, sink, context) do
    await(:bash)
    Fake.run(fake(handle), spec, sink, context)
  end

  defp await(operation) do
    send(Synapse.WebFixture.Controller, {:operation_waiting, operation, self()})

    receive do
      {:release, ^operation} -> :ok
    after
      30_000 -> exit({:fixture_release_timeout, operation})
    end
  end

  defp fake(handle), do: %{handle | backend: Fake}
end

defmodule Synapse.WebFixture.Provider do
  @behaviour Synapse.Provider

  @impl true
  def stream(request, sink, context) do
    wrapped = fn event ->
      :ok = sink.(event)

      if match?(%Synapse.Provider.Event.TextDelta{}, event) do
        send(Synapse.WebFixture.Controller, {:operation_waiting, :text, self()})

        receive do
          {:release, :text} -> :ok
        after
          30_000 -> exit(:fixture_text_release_timeout)
        end
      end

      :ok
    end

    Synapse.Provider.Fake.stream(request, wrapped, context)
  end
end

defmodule Synapse.WebFixture.Controller do
  use GenServer

  alias Synapse.Provider.Fake

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)
  def release(operation), do: GenServer.cast(__MODULE__, {:release, operation})
  def disconnect, do: GenServer.call(__MODULE__, :disconnect)
  def update_manager(manager), do: GenServer.call(__MODULE__, {:manager, manager})

  def register_backend(state, owner, ids),
    do: GenServer.call(__MODULE__, {:backend, state, owner, ids})

  @impl true
  def init(options) do
    {:ok,
     %{
       manager: Keyword.fetch!(options, :manager),
       evidence: Keyword.fetch!(options, :evidence),
       waiters: %{},
       releases: MapSet.new(),
       operations: [],
       providers: %{},
       closed: false
     }}
  end

  @impl true
  def handle_info({:operation_waiting, operation, pid}, state) do
    operations =
      if operation in [:read, :write, :bash],
        do: state.operations ++ [operation],
        else: state.operations

    if MapSet.member?(state.releases, operation) do
      send(pid, {:release, operation})

      {:noreply,
       %{
         state
         | releases: MapSet.delete(state.releases, operation),
           operations: operations
       }}
    else
      {:noreply,
       %{
         state
         | waiters: Map.put(state.waiters, operation, pid),
           operations: operations
       }}
    end
  end

  @impl true
  def handle_cast({:release, operation}, state) do
    case Map.pop(state.waiters, operation) do
      {nil, _waiters} ->
        {:noreply, %{state | releases: MapSet.put(state.releases, operation)}}

      {pid, waiters} ->
        send(pid, {:release, operation})
        {:noreply, %{state | waiters: waiters}}
    end
  end

  @impl true
  def handle_call({:backend, backend, owner, ids}, _from, state) do
    {:reply, :ok, %{state | providers: Map.put(state.providers, backend, {owner, ids})}}
  end

  def handle_call({:manager, manager}, _from, state),
    do: {:reply, :ok, %{state | manager: manager}}

  def handle_call({:closed, backend, remaining}, _from, state) do
    {provider, providers} = Map.pop(state.providers, backend)

    remaining_operations =
      case remaining do
        {:ok, value} -> value
        other -> inspect(other)
      end

    remaining_turns =
      if provider,
        do:
          Enum.map(elem(provider, 1), fn id ->
            case Fake.remaining_turns(id) do
              {:ok, value} -> value
              other -> inspect(other)
            end
          end),
        else: []

    if provider && Process.alive?(elem(provider, 0)), do: Agent.stop(elem(provider, 0))

    evidence = %{
      workspace_closed: true,
      operations: Enum.map(state.operations, &Atom.to_string/1),
      remaining_operations: remaining_operations,
      remaining_provider_turns: remaining_turns
    }

    File.write!(state.evidence, Jason.encode!(evidence))
    {:reply, :ok, %{state | providers: providers, closed: true}}
  end

  def handle_call(:disconnect, _from, state) do
    manager_state = :sys.get_state(state.manager)

    sockets =
      case manager_state.active_run_id do
        nil -> []
        run_id -> manager_state.runs[run_id].subscribers |> Map.keys()
      end

    Enum.each(sockets, &Process.exit(&1, :kill))
    {:reply, length(sockets), state}
  end
end

defmodule Synapse.WebFixture.Scenario do
  alias Synapse.Agent.OperationId
  alias Synapse.Provider.{Fake, Request, Response}
  alias Synapse.Provider.Event.{MessageCompleted, TextDelta}
  alias Synapse.Provider.OutputItem.{FunctionCall, Message}
  alias Synapse.Tool.Limits
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

  @model "fixture-model"
  @prompt "Inspect README.md, create created.txt, verify it with Bash, then finish."
  @final "Synapse fixture completed."
  @content "SYNAPSE_WEB_CREATED\n"
  @command "test \"$(cat created.txt)\" = SYNAPSE_WEB_CREATED && printf SYNAPSE_WEB_BASH_OK"

  def model, do: @model
  def prompt, do: @prompt
  def final, do: @final

  def open_workspace(open_request) do
    true = open_request.root == System.fetch_env!("SYNAPSE_FIXTURE_WORKSPACE")

    [{_id, server, :worker, _modules}] =
      DynamicSupervisor.which_children(Synapse.Runtime.Supervisor)

    runtime = :sys.get_state(server)
    true = runtime.task.pid == open_request.owner
    run_id = runtime.run_id
    provider_ids = Enum.map(1..2, fn turn -> elem(OperationId.provider(run_id, turn, 1), 1) end)
    tool_ids = Map.new(1..3, &{&1, elem(OperationId.tool(run_id, 1, &1), 1)})
    {:ok, owner} = Fake.start_link(provider_ids, script(initial_request(run_id), run_id))

    {:ok, handle} =
      WorkspaceFake.open(
        entries(tool_ids, runtime.cancel_ref, :persistent_term.get({__MODULE__, :deadline})),
        owner: open_request.owner,
        limits: open_request.limits,
        access: open_request.access
      )

    :ok = Synapse.WebFixture.Controller.register_backend(handle.state, owner, provider_ids)
    {:ok, %{handle | backend: Synapse.WebFixture.ControlledFake}}
  end

  defp initial_request(run_id) do
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

  defp script(initial, run_id) do
    calls = [
      call("item-read", "call-read", "read", %{
        "path" => "README.md",
        "offset" => nil,
        "limit" => nil
      }),
      call("item-write", "call-write", "write", %{
        "path" => "created.txt",
        "content" => @content,
        "expected_revision" => "missing"
      }),
      call("item-bash", "call-bash", "bash", %{"command" => @command, "timeout_ms" => nil})
    ]

    first = response!("fixture-tools", calls)

    final =
      response!("fixture-final", [
        %Message{id: "message-final", role: :assistant, content: @final}
      ])

    outcomes = [
      present(
        Enum.at(calls, 0),
        {:ok, read_result("README.md", revision(1), "SYNAPSE_WEB_FIXTURE")}
      ),
      present(
        Enum.at(calls, 1),
        {:ok, mutation_result(tool_id(run_id, 2), "created.txt", revision(2), @content)}
      ),
      present(Enum.at(calls, 2), {:ok, process_result(tool_id(run_id, 3), "SYNAPSE_WEB_BASH_OK")})
    ]

    {:ok, projected} = Synapse.Agent.Projection.response_input(first, outcomes, Limits.default())

    {:ok, continuation} =
      Request.new(
        model: initial.model,
        instructions: initial.instructions,
        input_items: initial.input_items ++ projected,
        tools: Synapse.Tool.Registry.specifications(),
        metadata: %{"run_id" => run_id, "turn" => 2}
      )

    [
      {:turn, initial, [], {:ok, first}},
      {:turn, continuation,
       [
         %TextDelta{item_id: "message-final", content_index: 0, delta: @final},
         %MessageCompleted{response: final}
       ], {:ok, final}}
    ]
  end

  defp entries(ids, cancel_ref, deadline) do
    [
      WorkspaceFake.expect_read(
        read_request("README.md"),
        context(ids[1], :read, cancel_ref, deadline),
        {:ok, read_result("README.md", revision(1), "SYNAPSE_WEB_FIXTURE")}
      ),
      WorkspaceFake.expect_write(
        write_request("created.txt", @content, :missing),
        context(ids[2], :write, cancel_ref, deadline),
        {:ok, mutation_result(ids[2], "created.txt", revision(2), @content)}
      ),
      WorkspaceFake.expect_run(
        process_spec(@command),
        context(ids[3], :exec, cancel_ref, deadline),
        process_events(ids[3], "SYNAPSE_WEB_BASH_OK"),
        {:ok, process_result(ids[3], "SYNAPSE_WEB_BASH_OK")}
      )
    ]
  end

  defp tool_id(run_id, ordinal), do: elem(OperationId.tool(run_id, 1, ordinal), 1)

  defp call(id, call_id, name, arguments),
    do: %FunctionCall{id: id, call_id: call_id, name: name, arguments: arguments}

  defp response!(id, items), do: elem(Response.new(id: id, model: @model, output_items: items), 1)

  defp present(provider_call, outcome) do
    {:ok, call} = Synapse.Tool.Call.from_provider(provider_call)

    module =
      %{"read" => Synapse.Tool.Read, "write" => Synapse.Tool.Write, "bash" => Synapse.Tool.Bash}[
        call.name
      ]

    module.present(call, outcome, Limits.default())
  end

  defp context(id, kind, cancel_ref, deadline) do
    access = %Access{read: kind == :read, write: kind == :write, exec: kind == :exec}

    elem(
      OperationContext.new(
        operation_id: id,
        access: access,
        cancel_ref: cancel_ref,
        deadline: deadline
      ),
      1
    )
  end

  defp read_request(path) do
    limits = Limits.default()

    elem(
      ReadRequest.new(
        path: path,
        start_line: 1,
        line_count: limits.default_read_lines,
        max_bytes: limits.default_read_source_bytes
      ),
      1
    )
  end

  defp write_request(path, content, revision),
    do: elem(WriteRequest.new(path: path, content: content, expected_revision: revision), 1)

  defp process_spec(command) do
    limits = Limits.default()

    elem(
      ProcessSpec.new(
        executable: "/bin/bash",
        arguments: ["-lc", command],
        cwd: ".",
        inactivity_ms: limits.default_bash_inactivity_ms,
        timeout_ms: limits.default_bash_timeout_ms,
        max_output_bytes: limits.default_bash_output_bytes,
        mutation: :unknown
      ),
      1
    )
  end

  defp read_result(path, revision, text) do
    line = elem(ReadLine.new(number: 1, text: text, ending: :none, truncated: false), 1)

    elem(
      ReadResult.new(
        path: path,
        revision: revision,
        lines: [line],
        next_line: nil,
        file_bytes: byte_size(text)
      ),
      1
    )
  end

  defp mutation_result(id, path, revision, content),
    do:
      elem(
        MutationResult.new(
          operation_id: id,
          path: path,
          previous_revision: :missing,
          revision: revision,
          bytes_written: byte_size(content),
          changed: true,
          diff: "changed",
          diff_truncated: false
        ),
        1
      )

  defp process_result(id, output),
    do:
      elem(
        ProcessResult.new(
          operation_id: id,
          termination: :exited,
          exit_code: 0,
          output: output,
          output_bytes: byte_size(output),
          truncated: false,
          elapsed_ms: 1
        ),
        1
      )

  defp process_events(id, output) do
    [
      elem(ProcessEvent.Started.new(operation_id: id), 1),
      elem(ProcessEvent.Output.new(operation_id: id, sequence: 1, data: output), 1)
    ]
  end

  defp revision(byte), do: elem(Revision.from_mac(:binary.copy(<<byte>>, 32)), 1)
end

defmodule Synapse.WebFixture.Main do
  def run do
    workspace = System.fetch_env!("SYNAPSE_FIXTURE_WORKSPACE")
    evidence = System.fetch_env!("SYNAPSE_FIXTURE_EVIDENCE")
    true = File.read!(Path.join(workspace, "README.md")) == "SYNAPSE_WEB_FIXTURE"
    Application.put_env(:synapse, :api, enabled: false)
    {:ok, _} = Application.ensure_all_started(:synapse)
    deadline = System.monotonic_time(:millisecond) + 300_000
    :persistent_term.put({Synapse.WebFixture.Scenario, :deadline}, deadline)

    {:ok, runtime_options} =
      Synapse.Runtime.Options.new(
        provider: Synapse.WebFixture.Provider,
        deadline: deadline,
        workspace_opener: &Synapse.WebFixture.Scenario.open_workspace/1
      )

    reference = make_ref()
    manager = {:global, {:web_fixture_manager, reference}}
    sessions = {:global, {:web_fixture_sessions, reference}}

    {:ok, config} =
      Synapse.API.Config.new(
        enabled: true,
        launch_cwd: File.cwd!(),
        port: 0,
        default_model: Synapse.WebFixture.Scenario.model(),
        model_allowlist: [Synapse.WebFixture.Scenario.model()],
        runtime_options: runtime_options
      )

    {:ok, api} = start_api(config, manager, sessions)

    manager_pid = :global.whereis_name(elem(manager, 1))

    {:ok, _controller} =
      Synapse.WebFixture.Controller.start_link(manager: manager_pid, evidence: evidence)

    {:ok, listener} = Synapse.API.Supervisor.listener(api)
    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(listener)
    {:ok, stable_config} = Synapse.API.Config.new(Map.put(Map.from_struct(config), :port, port))
    IO.puts("READY ws://127.0.0.1:#{port}/v1/socket")
    parent = self()
    spawn_link(fn -> read_commands(parent) end)
    wait(api, stable_config, manager, sessions)
  end

  defp read_commands(parent) do
    IO.stream(:stdio, :line)
    |> Enum.each(fn line ->
      case String.trim(line) do
        "release read" -> Synapse.WebFixture.Controller.release(:read)
        "release write" -> Synapse.WebFixture.Controller.release(:write)
        "release bash" -> Synapse.WebFixture.Controller.release(:bash)
        "release text" -> Synapse.WebFixture.Controller.release(:text)
        "disconnect" -> Synapse.WebFixture.Controller.disconnect()
        "restart" -> send(parent, :restart)
        "shutdown" -> send(parent, :shutdown)
        _ -> send(parent, :invalid_command)
      end
    end)
  end

  defp wait(api, config, manager, sessions) do
    receive do
      :shutdown ->
        Supervisor.stop(api)

      :invalid_command ->
        exit(:invalid_fixture_command)

      :restart ->
        Supervisor.stop(api)
        {:ok, replacement} = start_api(config, manager, sessions)
        manager_pid = :global.whereis_name(elem(manager, 1))
        :ok = Synapse.WebFixture.Controller.update_manager(manager_pid)
        wait(replacement, config, manager, sessions)
    end
  end

  defp start_api(config, manager, sessions) do
    Synapse.API.Supervisor.start_link(
      name: nil,
      config: config,
      manager: manager,
      session_supervisor: sessions
    )
  end
end

Synapse.WebFixture.Main.run()
