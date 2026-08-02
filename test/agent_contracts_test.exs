defmodule Synapse.Agent.ContractsTest do
  use ExUnit.Case, async: true

  alias Synapse.Agent.{Context, Error, Result, Runner, State}
  alias Synapse.Budget
  alias Synapse.Provider
  alias Synapse.Provider.OutputItem.Message
  alias Synapse.Run.Request
  alias Synapse.Tool.{CapabilitySet, Limits}
  alias Synapse.Workspace
  alias Synapse.Workspace.Fake

  doctest Context
  doctest Error
  doctest Result

  defmodule StreamOnly do
    def stream(_request, _sink, _context), do: raise("must not be called")
  end

  defmodule TestProvider do
    @behaviour Synapse.Provider

    @impl true
    def stream(_request, _sink, _context), do: raise("must not be called")
  end

  test "constructs trusted Context with defaults without invoking callbacks" do
    {:ok, handle} = Fake.open([])
    test_pid = self()

    cancelled? = fn ->
      send(test_pid, :cancel_probe_called)
      false
    end

    retry_delay = fn _ordinal ->
      send(test_pid, :retry_delay_called)
      0
    end

    try do
      assert {:ok, context} =
               Context.new(
                 provider: TestProvider,
                 workspace: handle,
                 event_sink: fn _event -> :ok end,
                 cancelled?: cancelled?,
                 retry_delay: retry_delay
               )

      assert Context.valid?(context)
      assert context.instructions == "You are the Synapse coding agent."
      assert context.cancel_ref == nil
      assert context.deadline == :infinity
      assert context.provider_activity_sink == nil
      assert context.tool_activity_sink == nil
      assert context.tool_limits == Limits.default()
      refute_received :cancel_probe_called
      refute_received :retry_delay_called
    after
      Workspace.close(handle)
    end
  end

  test "accepts exact Context lifetime and callback fields" do
    {:ok, handle} = Fake.open([])
    cancel_ref = make_ref()
    event_sink = fn _event -> :ok end
    provider_activity = fn _context -> :ok end
    tool_activity = fn _context -> :ok end
    cancelled? = fn -> false end

    retry_delay = fn
      1 -> 250
      _ordinal -> 1_000
    end

    try do
      assert {:ok, context} =
               Context.new(
                 provider: Synapse.Provider.Fake,
                 workspace: handle,
                 instructions: "Fixed trusted instructions",
                 event_sink: event_sink,
                 cancel_ref: cancel_ref,
                 cancelled?: cancelled?,
                 deadline: 123_456,
                 provider_activity_sink: provider_activity,
                 tool_activity_sink: tool_activity,
                 tool_limits: Limits.default(),
                 retry_delay: retry_delay
               )

      assert context.cancel_ref == cancel_ref
      assert context.deadline == 123_456
      assert context.cancelled?.() == false
      assert context.retry_delay.(1) == 250
      assert context.retry_delay.(2) == 1_000
    after
      Workspace.close(handle)
    end
  end

  test "rejects arbitrary providers, malformed callbacks, Handles, and Tool Limits" do
    {:ok, handle} = Fake.open([])
    base = %{provider: TestProvider, workspace: handle, event_sink: fn _event -> :ok end}

    try do
      invalid = [
        {:provider, StreamOnly},
        {:provider, :not_a_module},
        {:workspace, %{}},
        {:instructions, <<255>>},
        {:instructions, String.duplicate("i", 65_537)},
        {:event_sink, fn -> :ok end},
        {:cancel_ref, "not-a-reference"},
        {:cancelled?, fn _arg -> false end},
        {:deadline, 1.0},
        {:provider_activity_sink, fn -> :ok end},
        {:tool_activity_sink, fn -> :ok end},
        {:retry_delay, fn -> 0 end},
        {:tool_limits, %{}}
      ]

      Enum.each(invalid, fn {field, value} ->
        assert {:error, {^field, _reason}} = Context.new(Map.put(base, field, value))
      end)

      {:ok, short_ids} = Limits.new(max_operation_id_bytes: 84)

      assert {:error, {:tool_limits, :must_fit_workspace_and_agent_operation_ids}} =
               Context.new(Map.put(base, :tool_limits, short_ids))

      assert {:error, {:unknown_fields, [:api_key]}} =
               Context.new(Map.put(base, :api_key, "synthetic-secret"))

      assert {:error, {:attributes, :must_be_keyword_or_map}} =
               Context.new([{:provider, TestProvider} | :bad])
    after
      Workspace.close(handle)
    end
  end

  test "Context inspection redacts all authority and callbacks" do
    {:ok, handle} = Fake.open([])

    try do
      {:ok, context} =
        Context.new(
          provider: TestProvider,
          workspace: handle,
          instructions: "recognizable-instructions",
          event_sink: fn _event -> :ok end,
          cancel_ref: make_ref()
        )

      inspected = inspect(context)
      assert inspected == "#Synapse.Agent.Context<redacted>"
      refute inspected =~ "recognizable"
      refute inspected =~ "TestProvider"
      refute inspected =~ "Reference"
    after
      Workspace.close(handle)
    end
  end

  test "constructs initial immutable State with one Provider input item" do
    run = run_request()
    input_items = [user_item(run.prompt)]

    assert {:ok, state} =
             State.new(
               run: run,
               input_items: input_items,
               started_at: -1_000,
               deadline: :infinity
             )

    assert state.run == run
    assert state.input_items == input_items
    assert state.turn == 0
    assert state.tool_calls == 0
    assert state.provider_retries == 0
    assert state.output_bytes == 0
    assert state.started_at == -1_000
    assert state.deadline == 899_000
    assert state.status == :running
    assert inspect(state) == "#Synapse.Agent.State<status=:running redacted>"
  end

  test "rejects malformed initial State dependencies and unknown counters" do
    run = run_request()
    base = %{run: run, input_items: [user_item(run.prompt)], started_at: 0, deadline: 1}

    assert {:error, {:run, :must_be_run_request}} = State.new(Map.put(base, :run, %{}))

    for input <- [[], [%{"type" => "unsupported"}], :not_a_list] do
      assert {:error, {:input_items, :must_be_non_empty_provider_input}} =
               State.new(Map.put(base, :input_items, input))
    end

    assert {:error, {:started_at, :must_be_monotonic_time}} =
             State.new(Map.put(base, :started_at, 1.0))

    assert {:error, {:deadline, :must_be_monotonic_time_or_infinity}} =
             State.new(Map.put(base, :deadline, nil))

    assert {:error, {:deadline, :wall_time_addition_overflow}} =
             State.new(Map.put(base, :started_at, 9_223_372_036_854_775_807))

    assert {:ok, earlier} = State.new(%{base | started_at: 100, deadline: 500})
    assert earlier.deadline == 500

    assert {:error, {:unknown_fields, [:turn]}} = State.new(Map.put(base, :turn, 1))
  end

  test "constructs and bounds successful Result" do
    response = final_response("Finished")

    assert {:ok, result} =
             Result.new(
               run_id: "run-1",
               text: "Finished",
               final_response: response,
               turns: 2,
               tool_calls: 3,
               provider_retries: 1,
               output_bytes: 128
             )

    assert result.final_response == response
    assert inspect(result) == "#Synapse.Agent.Result<turns=2 tool_calls=3 redacted>"
    refute inspect(result) =~ "Finished"

    assert {:error, {:output_bytes, :must_include_final_text}} =
             Result.new(%{Map.from_struct(result) | output_bytes: 7})

    assert {:error, {:text, :must_be_bounded_non_empty_utf8_string}} =
             Result.new(%{Map.from_struct(result) | text: "   "})

    assert {:error, {:final_response, :must_be_completed_provider_response}} =
             Result.new(%{Map.from_struct(result) | final_response: %{}})
  end

  test "constructs every Error category and enforces reason pairing" do
    examples = [
      {:internal, :invalid_run_request},
      {:provider, :provider_failed},
      {:protocol, :empty_provider_response},
      {:tool, :tool_ambiguous},
      {:budget, :turn_budget_exhausted},
      {:cancelled, :run_cancelled}
    ]

    Enum.each(examples, fn {kind, reason} ->
      assert {:ok, %Error{kind: ^kind, reason: ^reason}} =
               Error.new(error_attrs(kind, reason))
    end)

    assert {:error, {:reason, :must_match_kind}} =
             Error.new(error_attrs(:budget, :provider_failed))

    assert {:error, {:kind, :must_be_known}} =
             Error.new(error_attrs(:unknown, :provider_failed))
  end

  test "Error details are bounded and key-allowlisted" do
    attrs = error_attrs(:provider, :provider_failed)

    assert {:ok, error} =
             Error.new(%{
               attrs
               | operation_id: "provider-operation",
                 details: %{
                   "provider_kind" => "unavailable",
                   "http_status" => 503,
                   "retryable" => true,
                   "output_started" => false,
                   "attempts" => 1
                 }
             })

    assert error.details["output_started"] == false

    for details <- [
          %{"content" => "secret"},
          %{"command" => "secret"},
          %{"provider_kind" => %{"content" => "secret"}},
          %{"provider_kind" => String.duplicate("x", 4_097)},
          %{atom_key: "value"},
          %{"provider_kind" => self()}
        ] do
      assert {:error, {:details, :must_be_bounded_allowlisted_json_object}} =
               Error.new(%{attrs | details: details})
    end

    assert inspect(error) =~ "kind=:provider"
    refute inspect(error) =~ "unavailable"
    refute inspect(error) =~ "provider-operation"
  end

  test "Runner rejects invalid boundary contracts before Provider calls or events" do
    {:ok, handle} = Fake.open([])
    test_pid = self()

    try do
      {:ok, context} =
        Context.new(
          provider: TestProvider,
          workspace: handle,
          event_sink: fn event ->
            send(test_pid, {:unexpected_event, event})
            :ok
          end
        )

      assert {:error, %Error{reason: :invalid_run_request}} = Runner.run(%{}, context)
      assert {:error, %Error{reason: :invalid_agent_context}} = Runner.run(run_request(), %{})
      refute_received {:unexpected_event, _event}
      assert {:ok, 0} = Fake.remaining_operations(handle)
    after
      Workspace.close(handle)
    end
  end

  test "Runner source imports no transport, host, Runtime, terminal, or execution API" do
    source = File.read!(Path.join([__DIR__, "..", "lib", "synapse", "agent", "runner.ex"]))

    forbidden = [
      "Req.",
      "Finch.",
      "File.",
      "System.",
      "Port.",
      "MuonTrap",
      "Runtime.",
      "CLI.",
      "Terminal",
      "Workspace.open",
      "Workspace.close"
    ]

    Enum.each(forbidden, &refute(source =~ &1))
  end

  defp run_request do
    {:ok, request} =
      Request.new(
        id: "run-1",
        prompt: "Inspect the project",
        cwd: "/synthetic/project",
        model: "test-model",
        capabilities: capabilities(),
        budget: Budget.default()
      )

    request
  end

  defp capabilities do
    {:ok, capabilities} =
      CapabilitySet.new(fs_read: true, fs_write: true, process_exec: true)

    capabilities
  end

  defp user_item(prompt) do
    %{
      "type" => "message",
      "role" => "user",
      "content" => [%{"type" => "input_text", "text" => prompt}]
    }
  end

  defp final_response(content) do
    {:ok, response} =
      Provider.Response.new(
        id: "response-final",
        model: "test-model",
        output_items: [%Message{id: "message-final", role: :assistant, content: content}]
      )

    response
  end

  defp error_attrs(kind, reason) do
    %{
      kind: kind,
      reason: reason,
      message: "Synthetic terminal",
      run_id: "run-1",
      turn: 0,
      operation_id: nil,
      details: %{}
    }
  end
end
