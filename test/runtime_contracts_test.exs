defmodule Synapse.Runtime.ContractsTest do
  use ExUnit.Case, async: true

  alias Synapse.Agent
  alias Synapse.Agent.Error, as: AgentError
  alias Synapse.Budget
  alias Synapse.Provider
  alias Synapse.Provider.OutputItem.Message, as: ProviderMessage
  alias Synapse.Run.Request
  alias Synapse.Runtime
  alias Synapse.Runtime.{Error, Options, Run, RunServer}
  alias Synapse.Runtime.RunServer.{Message, State}
  alias Synapse.Tool.{CapabilitySet, Limits}
  alias Synapse.Workspace
  alias Synapse.Workspace.Limits, as: WorkspaceLimits

  doctest Error
  doctest Options

  defmodule StreamOnly do
    def stream(_request, _sink, _context), do: raise("must not be called")
  end

  defmodule TestProvider do
    @behaviour Synapse.Provider

    @impl true
    def stream(_request, _sink, _context) do
      send(self(), :runtime_provider_called)
      raise "must not be called"
    end
  end

  test "Options defaults match confirmed Runtime policy without invoking dependencies" do
    provider_load_state = :code.is_loaded(Synapse.Provider.Tokamak)

    assert {:ok, options} = Options.new()
    assert Options.valid?(options)
    assert options.provider == Synapse.Provider.Tokamak
    assert options.instructions == "You are the Synapse coding agent."
    assert options.workspace_limits == WorkspaceLimits.default()
    assert options.tool_limits == Limits.default()
    assert options.deadline == :infinity
    assert options.retry_delay.(1) == 250
    assert options.retry_delay.(2) == 1_000
    assert is_function(options.workspace_opener, 1)
    assert :code.is_loaded(Synapse.Provider.Tokamak) == provider_load_state
    refute_received _message
  end

  test "Options accepts trusted Fake dependencies and signed monotonic deadlines without probing" do
    test_pid = self()

    retry_delay = fn _ordinal ->
      send(test_pid, :runtime_retry_delay_called)
      0
    end

    opener = fn _open_request ->
      send(test_pid, :runtime_workspace_opener_called)
      {:error, :must_not_open}
    end

    {:ok, tool_limits} = Limits.new(default_read_lines: 50)

    assert {:ok, options} =
             Options.new(
               provider: Synapse.Provider.Fake,
               instructions: "Fixed Runtime instructions",
               workspace_limits: WorkspaceLimits.default(),
               tool_limits: tool_limits,
               deadline: -123,
               retry_delay: retry_delay,
               workspace_opener: opener
             )

    assert options.provider == Synapse.Provider.Fake
    assert options.deadline == -123
    assert options.retry_delay == retry_delay
    assert options.workspace_opener == opener
    refute_received :runtime_retry_delay_called
    refute_received :runtime_workspace_opener_called
  end

  test "Options rejects malformed fields, callbacks, providers, and unknown authority" do
    base = %{}

    invalid = [
      {:provider, StreamOnly},
      {:provider, :not_a_provider},
      {:provider, self()},
      {:instructions, <<255>>},
      {:instructions, String.duplicate("i", 65_537)},
      {:workspace_limits, %{}},
      {:tool_limits, %{}},
      {:deadline, nil},
      {:deadline, 1.0},
      {:deadline, 9_223_372_036_854_775_808},
      {:retry_delay, fn -> 0 end},
      {:workspace_opener, fn -> :ok end}
    ]

    Enum.each(invalid, fn {field, value} ->
      assert {:error, {^field, _reason}} = Options.new(Map.put(base, field, value))
    end)

    for field <- [:api_key, :endpoint, :workspace, :event_sink, :provider_activity_sink] do
      assert {:error, {:unknown_fields, [^field]}} = Options.new([{field, :forbidden}])
    end

    assert {:error, {:attributes, :must_be_keyword_or_map}} =
             Options.new([{:provider, TestProvider} | :bad])
  end

  test "Options requires Tool limits to fit Workspace and Agent operation identities" do
    {:ok, short_ids} = Limits.new(max_operation_id_bytes: 84)

    assert {:error, {:tool_limits, :must_fit_workspace_and_agent_operation_ids}} =
             Options.new(tool_limits: short_ids)

    {:ok, narrow_workspace} = WorkspaceLimits.new(default_read_lines: 99)

    assert {:error, {:tool_limits, :must_fit_workspace_and_agent_operation_ids}} =
             Options.new(workspace_limits: narrow_workspace)

    {:ok, matching_tool} = Limits.new(default_read_lines: 99)

    assert {:ok, _options} =
             Options.new(workspace_limits: narrow_workspace, tool_limits: matching_tool)
  end

  test "Options normalization and inspection reject forged or disclosed authority" do
    {:ok, options} =
      Options.new(
        provider: TestProvider,
        instructions: "RECOGNIZABLE_RUNTIME_INSTRUCTIONS",
        retry_delay: fn _ordinal -> 0 end,
        workspace_opener: fn _request -> {:error, :not_opened} end
      )

    assert inspect(options) == "#Synapse.Runtime.Options<redacted>"
    refute inspect(options) =~ "RECOGNIZABLE"
    refute inspect(options) =~ "TestProvider"
    refute Options.valid?(%Options{options | deadline: 1.0})
  end

  test "Runtime facade validates inputs and sanitizes Workspace readiness failure" do
    request = run_request()
    run_id = request.id
    test_pid = self()

    sink = fn event ->
      send(test_pid, {:runtime_event, event})
      :ok
    end

    options = [
      provider: TestProvider,
      retry_delay: fn _ordinal ->
        send(test_pid, :runtime_retry_delay_called)
        0
      end,
      workspace_opener: fn _request ->
        send(test_pid, :runtime_workspace_opener_called)
        {:error, :must_not_open}
      end
    ]

    assert {:error, %Error{reason: :workspace_open_failed, run_id: ^run_id}} =
             Runtime.start_run(request, sink, options)

    refute_received {:runtime_event, _event}
    refute_received :runtime_retry_delay_called
    assert_received :runtime_workspace_opener_called

    assert {:error, %Error{reason: :invalid_run_request, run_id: nil}} =
             Runtime.start_run(%{}, sink)

    assert {:error, %Error{reason: :invalid_runtime_options, run_id: ^run_id}} =
             Runtime.start_run(request, fn -> :ok end)

    assert {:error, %Error{reason: :invalid_runtime_options, run_id: ^run_id}} =
             Runtime.start_run(request, sink, api_key: "SYNTHETIC_RUNTIME_SECRET")
  end

  test "Runtime Error uses one closed reason-to-message mapping" do
    expected = %{
      invalid_run_request: "Run Request is invalid",
      invalid_runtime_options: "Runtime options are invalid",
      runtime_unavailable: "Runtime infrastructure is unavailable",
      runtime_busy: "Runtime is busy",
      workspace_open_failed: "Workspace could not be opened",
      runtime_lost: "Runtime coordinator was lost"
    }

    Enum.each(expected, fn {reason, message} ->
      assert {:ok, error} = Error.new(reason: reason, run_id: "run-1")
      assert error.message == message
      assert Error.valid?(error)
      assert inspect(error) == "#Synapse.Runtime.Error<reason=#{inspect(reason)} redacted>"
      refute inspect(error) =~ "run-1"
      refute inspect(error) =~ message
    end)
  end

  test "Runtime Error rejects caller prose, raw failures, and forged structs" do
    assert {:error, {:reason, :must_be_known}} = Error.new(reason: :unknown)

    assert {:error, {:run_id, :must_be_bounded_identifier_or_nil}} =
             Error.new(reason: :runtime_lost, run_id: "bad\nid")

    for field <- [:message, :details, :path, :workspace_error, :exit_reason, :stacktrace] do
      assert {:error, {:unknown_fields, [^field]}} =
               Error.new([{field, "SYNTHETIC_RUNTIME_SECRET"}, {:reason, :runtime_lost}])
    end

    {:ok, error} = Error.new(reason: :runtime_lost, run_id: "run-1")
    refute Error.valid?(%Error{error | message: "SYNTHETIC_RUNTIME_SECRET"})

    forged = %Error{error | reason: "SYNTHETIC_RUNTIME_SECRET"}
    assert inspect(forged) == "#Synapse.Runtime.Error<invalid redacted>"
    refute inspect(forged) =~ "SYNTHETIC_RUNTIME_SECRET"
  end

  test "Run is opaque, has no public constructor, and validates atomics resources" do
    run = run_handle()

    assert Run.valid?(run)
    refute function_exported?(Run, :new, 1)
    assert inspect(run) == "#Synapse.Runtime.Run<opaque>"
    refute inspect(run) =~ "run-1"
    refute inspect(run) =~ inspect(self())
    refute inspect(run) =~ "Reference"

    refute Run.valid?(%Run{run | cancellation: make_ref()})
    refute Run.valid?(%Run{run | await_state: make_ref()})
    refute Run.valid?(%Run{run | id: "bad\nid"})
    refute Run.valid?(%Run{run | await_state: run.cancellation})
    refute Run.valid?(%Run{run | cancel_ref: run.run_ref})

    :atomics.put(run.cancellation, 1, 2)
    refute Run.valid?(run)
  end

  test "RunServer atomics contract accepts only one unsigned cell in known states" do
    cancellation = atomics(0)
    awaiting = atomics(0)

    assert RunServer.valid_cancellation_cell?(cancellation)
    assert RunServer.valid_await_cell?(awaiting)

    assert :ok = :atomics.compare_exchange(cancellation, 1, 0, 1)
    assert RunServer.valid_cancellation_cell?(cancellation)
    assert :atomics.compare_exchange(cancellation, 1, 0, 1) == 1

    assert :ok = :atomics.compare_exchange(awaiting, 1, 0, 1)
    assert :ok = :atomics.compare_exchange(awaiting, 1, 1, 2)
    assert RunServer.valid_await_cell?(awaiting)

    :atomics.put(awaiting, 1, 3)
    refute RunServer.valid_await_cell?(awaiting)
    refute RunServer.valid_cancellation_cell?(make_ref())
    refute RunServer.valid_await_cell?(:atomics.new(2, signed: false))
  end

  test "RunServer State constructs fixed bounded lifecycle slots without invoking sink" do
    test_pid = self()
    attrs = state_attrs(fn event -> send(test_pid, {:runtime_state_sink, event}) end)

    assert {:ok, state} = State.new(attrs)
    assert state.phase == :starting
    assert state.task == nil
    assert state.workspace_backend == nil
    assert state.workspace_monitor == nil
    assert state.workspace_status == :not_open
    refute state.visible_output?
    assert state.active_tool == nil
    assert state.buffered_terminal == nil
    assert state.worker_terminal == nil
    assert state.sink_status == :open
    assert inspect(state) == "#Synapse.Runtime.RunServer.State<redacted>"
    refute_received {:runtime_state_sink, _event}

    refute Map.has_key?(Map.from_struct(state), :request)
    refute Map.has_key?(Map.from_struct(state), :options)
    refute Map.has_key?(Map.from_struct(state), :workspace)
    refute Map.has_key?(Map.from_struct(state), :events)

    forged = %{state | phase: "SYNTHETIC_RUNTIME_SECRET"}
    refute inspect(forged) =~ "SYNTHETIC_RUNTIME_SECRET"
  end

  test "RunServer State rejects malformed authority and unknown lifecycle injection" do
    base = state_attrs(fn _event -> :ok end)

    invalid = [
      {:run_id, "bad\nid"},
      {:owner, :not_a_pid},
      {:run_ref, "not-a-reference"},
      {:cancel_ref, "not-a-reference"},
      {:cancellation, make_ref()},
      {:await_state, make_ref()},
      {:event_sink, fn -> :ok end}
    ]

    Enum.each(invalid, fn {field, value} ->
      assert {:error, {^field, _reason}} = State.new(Map.put(base, field, value))
    end)

    assert {:error, {:await_state, :must_differ_from_cancellation}} =
             State.new(%{base | await_state: base.cancellation})

    assert {:error, {:authority, :must_be_pairwise_distinct}} =
             State.new(%{base | cancel_ref: base.run_ref})

    :atomics.put(base.cancellation, 1, 1)

    assert {:error, {:cancellation, :must_be_one_cell_cancellation_atomics}} =
             State.new(base)

    assert {:error, {:unknown_fields, [:phase]}} = State.new(Map.put(base, :phase, :running))
  end

  test "RunServer messages validate ready, failure, control, and Runtime terminals" do
    {:ok, handle} = Workspace.Fake.open([])
    run_ref = make_ref()

    try do
      assert {:ok, %Message{kind: :ready, payload: {:ok, ^handle}} = ready} =
               Message.ready(run_ref, self(), handle)

      assert inspect(ready) == "#Synapse.Runtime.RunServer.Message<redacted>"
      refute inspect(ready) =~ "Workspace.Handle"

      assert {:ok, %Message{kind: :ready, payload: {:error, :workspace_open_failed, nil}}} =
               Message.ready_failed(run_ref, self(), :workspace_open_failed)

      assert {:ok, %Message{kind: :accept, payload: nil}} = Message.accept(run_ref)
      assert {:ok, %Message{kind: :abort, payload: nil}} = Message.abort(run_ref)

      assert {:ok, %Message{kind: :started, payload: server}} =
               Message.started(run_ref, self(), self())

      assert server == self()

      assert {:ok, %Message{kind: :start_failed, payload: {server, :runtime_unavailable}}} =
               Message.start_failed(run_ref, self(), self(), :runtime_unavailable)

      assert server == self()

      {:ok, runtime_error} = Error.new(reason: :runtime_lost, run_id: "run-1")

      assert {:error, :invalid_message} = Message.terminal(run_ref, {:error, runtime_error})

      assert {:error, :invalid_message} = Message.ready(make_ref(), self(), %{})

      assert {:error, :invalid_message} =
               Message.ready_failed("bad", self(), :workspace_open_failed)

      assert {:error, :invalid_message} = Message.accept("bad")
      assert {:error, :invalid_message} = Message.terminal(run_ref, {:error, :raw_reason})

      forged = %{ready | kind: "SYNTHETIC_RUNTIME_SECRET"}
      refute inspect(forged) =~ "SYNTHETIC_RUNTIME_SECRET"
    after
      Workspace.close(handle)
    end
  end

  test "RunServer terminal messages revalidate Agent Result and Error" do
    run_ref = make_ref()
    result = agent_result()
    error = agent_error(:run_worker_crashed)

    assert {:ok, %Message{payload: {:ok, ^result}}} = Message.terminal(run_ref, {:ok, result})

    assert {:ok, %Message{payload: {:error, ^error}}} =
             Message.terminal(run_ref, {:error, error})

    assert {:error, :invalid_message} =
             Message.terminal(run_ref, {:ok, %{result | output_bytes: 0}})
  end

  test "Agent Error accepts only the two Runtime reasons under internal kind" do
    for reason <- [:run_worker_crashed, :workspace_close_failed] do
      assert {:ok, %AgentError{kind: :internal, reason: ^reason} = error} =
               AgentError.new(agent_error_attrs(reason))

      assert inspect(error) =~ "reason=#{inspect(reason)}"

      for kind <- [:provider, :protocol, :tool, :budget, :cancelled] do
        assert {:error, {:reason, :must_match_kind}} =
                 AgentError.new(%{agent_error_attrs(reason) | kind: kind})
      end
    end

    assert {:ok, error} =
             AgentError.new(%{
               agent_error_attrs(:workspace_close_failed)
               | details: %{
                   "call_id" => "call-1",
                   "tool_name" => "bash",
                   "operation_id" => "tool-operation",
                   "outcome" => "unknown",
                   "status" => "ambiguous"
                 }
             })

    refute inspect(error) =~ "call-1"

    assert {:error, {:details, :must_be_bounded_allowlisted_json_object}} =
             AgentError.new(%{
               agent_error_attrs(:run_worker_crashed)
               | details: %{"exception" => "secret"}
             })

    forged = %{error | reason: "SYNTHETIC_RUNTIME_SECRET"}
    assert inspect(forged) == "#Synapse.Agent.Error<invalid redacted>"
    refute inspect(forged) =~ "SYNTHETIC_RUNTIME_SECRET"
  end

  test "cancel and await validate handles while await restores rights after timeout" do
    run = run_handle()

    assert :ok = Runtime.cancel(run)
    assert_receive {:cancel, cancel_ref}
    assert cancel_ref == run.cancel_ref
    assert :atomics.get(run.cancellation, 1) == 1
    assert {:error, :invalid_run} = Runtime.cancel(%{})
    assert {:error, :invalid_run} = Runtime.await(%{}, :infinity)
    assert {:error, :await_timeout} = Runtime.await(run, 0)
    assert :atomics.get(run.await_state, 1) == 0
    assert {:error, :invalid_timeout} = Runtime.await(run, -1)
    assert {:error, :invalid_timeout} = Runtime.await(run, 1.0)
  end

  defp run_request do
    {:ok, capabilities} =
      CapabilitySet.new(fs_read: true, fs_write: true, process_exec: true)

    {:ok, request} =
      Request.new(
        id: "run-1",
        prompt: "SYNTHETIC_RUNTIME_PROMPT",
        cwd: "/synthetic/runtime/root",
        model: "test-model",
        capabilities: capabilities,
        budget: Budget.default()
      )

    request
  end

  defp run_handle do
    %Run{
      id: "run-1",
      owner: self(),
      server: self(),
      task: self(),
      run_ref: make_ref(),
      cancel_ref: make_ref(),
      cancellation: atomics(0),
      await_state: atomics(0)
    }
  end

  defp state_attrs(event_sink) do
    %{
      run_id: "run-1",
      owner: self(),
      run_ref: make_ref(),
      cancel_ref: make_ref(),
      cancellation: atomics(0),
      await_state: atomics(0),
      event_sink: event_sink
    }
  end

  defp atomics(value) do
    cell = :atomics.new(1, signed: false)
    :atomics.put(cell, 1, value)
    cell
  end

  defp agent_result do
    {:ok, response} =
      Provider.Response.new(
        id: "runtime-response",
        model: "test-model",
        output_items: [
          %ProviderMessage{id: "runtime-message", role: :assistant, content: "finished"}
        ]
      )

    {:ok, result} =
      Agent.Result.new(
        run_id: "run-1",
        text: "finished",
        final_response: response,
        turns: 1,
        tool_calls: 0,
        provider_retries: 0,
        output_bytes: 8
      )

    result
  end

  defp agent_error(reason) do
    {:ok, error} = AgentError.new(agent_error_attrs(reason))
    error
  end

  defp agent_error_attrs(reason) do
    %{
      kind: :internal,
      reason: reason,
      message: "Runtime-owned failure",
      run_id: "run-1",
      turn: 1,
      operation_id: nil,
      details: %{}
    }
  end
end
