defmodule Synapse.Run.ContractsTest do
  use ExUnit.Case, async: true

  alias Synapse.Agent.{Error, Result}
  alias Synapse.Budget
  alias Synapse.Provider
  alias Synapse.Provider.OutputItem.Message
  alias Synapse.Run.{Event, Request}
  alias Synapse.Tool.CapabilitySet

  doctest Event
  doctest Request

  test "constructs a trusted Request and preserves prompt bytes exactly" do
    prompt = "  inspect\nthis project  "

    assert {:ok, request} =
             Request.new(
               id: "run-1",
               prompt: prompt,
               cwd: "/tmp/project",
               model: "test-model",
               capabilities: capabilities(),
               budget: Budget.default()
             )

    assert request.prompt == prompt
    assert Request.valid?(request)
    assert request.capabilities == capabilities()
    assert request.budget == Budget.default()
  end

  test "rejects every malformed Request field and unknown authority" do
    valid = request_attrs()

    invalid = [
      {:id, ""},
      {:id, "bad\nid"},
      {:id, String.duplicate("i", 257)},
      {:prompt, "   "},
      {:prompt, <<255>>},
      {:prompt, String.duplicate("p", 1_048_577)},
      {:cwd, ""},
      {:cwd, "relative/project"},
      {:cwd, "bad\0path"},
      {:cwd, String.duplicate("c", 4_097)},
      {:model, "bad\nmodel"},
      {:model, String.duplicate("m", 257)},
      {:capabilities, %{}},
      {:budget, %{}}
    ]

    Enum.each(invalid, fn {field, value} ->
      assert {:error, {^field, _reason}} = Request.new(Map.put(valid, field, value))
    end)

    assert {:error, {:unknown_fields, [:provider]}} =
             valid |> Map.put(:provider, Synapse.Provider.Fake) |> Request.new()

    assert {:error, {:unknown_fields, [:unknown]}} =
             valid |> Map.put("api_key", "synthetic-secret") |> Request.new()

    assert {:error, {:attributes, :must_be_keyword_or_map}} =
             Request.new([{:id, "run"} | :bad])
  end

  test "Request inspection redacts prompt and cwd" do
    {:ok, request} = Request.new(request_attrs())
    inspected = inspect(request)

    assert inspected =~ "run-1"
    assert inspected =~ "test-model"
    refute inspected =~ "recognizable-prompt"
    refute inspected =~ "/synthetic/private/root"
  end

  test "constructs every progress event with exact fields" do
    assert {:ok, %Event.RunStarted{}} =
             Event.new(:run_started, run_id: "run-1", model: "test-model")

    assert {:ok, %Event.TurnStarted{}} =
             Event.new(:turn_started,
               run_id: "run-1",
               turn: 1,
               operation_id: "provider-op"
             )

    assert {:ok, %Event.TextDelta{delta: "hello"}} =
             Event.new(:text_delta,
               run_id: "run-1",
               turn: 1,
               operation_id: "provider-op",
               item_id: "item-1",
               content_index: 0,
               delta: "hello"
             )

    assert {:ok, %Event.ToolStarted{ordinal: 1}} =
             Event.new(:tool_started, tool_event_attrs())

    assert {:ok, %Event.ToolCompleted{status: :error}} =
             Event.new(
               :tool_completed,
               Map.merge(tool_event_attrs(), %{
                 status: :error,
                 metadata: %{"outcome" => "not_applied", "tool" => "read"}
               })
             )

    assert {:ok, %Event.TurnCompleted{outcome: :continued}} =
             Event.new(:turn_completed,
               run_id: "run-1",
               turn: 1,
               outcome: :continued,
               provider_attempts: 1,
               tool_calls: 1,
               output_bytes: 10
             )
  end

  test "validates terminal events and matching run identity" do
    result = agent_result("run-1")
    error = agent_error("run-1", :budget, :turn_budget_exhausted)

    assert {:ok, %Event.RunCompleted{result: ^result}} =
             Event.new(:run_completed, run_id: "run-1", result: result)

    assert {:ok, %Event.RunFailed{error: ^error}} =
             Event.new(:run_failed, run_id: "run-1", error: error)

    interrupted = agent_error("run-1", :cancelled, :run_cancelled)

    assert {:ok, %Event.RunInterrupted{error: ^interrupted}} =
             Event.new(:run_interrupted, run_id: "run-1", error: interrupted)

    assert {:error, {:result, :run_id_must_match}} =
             Event.new(:run_completed, run_id: "other-run", result: result)

    assert {:error, {:error, :run_id_must_match}} =
             Event.new(:run_failed, run_id: "other-run", error: error)
  end

  test "rejects unsafe Tool event metadata and malformed event values" do
    base = Map.merge(tool_event_attrs(), %{status: :ok})

    for metadata <- [
          %{"content" => "secret"},
          %{"command" => "rm -rf"},
          %{"safe" => String.duplicate("x", 4_097)},
          %{atom_key: "value"},
          %{"pid" => self()}
        ] do
      assert {:error, {:metadata, :must_be_bounded_safe_json_object}} =
               Event.new(:tool_completed, Map.put(base, :metadata, metadata))
    end

    assert {:error, {:status, :must_be_tool_result_status}} =
             Event.new(:tool_completed, Map.merge(base, %{status: :unknown, metadata: %{}}))

    assert {:error, {:turn, :must_be_positive_int64}} =
             Event.new(:turn_started, run_id: "run-1", turn: 0, operation_id: "op")

    assert {:error, {:kind, :must_be_known}} = Event.new(:unknown, %{})

    assert {:error, {:unknown_fields, [:prompt]}} =
             Event.new(:run_started, run_id: "run-1", model: "model", prompt: "secret")
  end

  test "event inspection redacts text, identities, and metadata" do
    {:ok, delta} =
      Event.new(:text_delta,
        run_id: "run-secret",
        turn: 1,
        operation_id: "operation-secret",
        item_id: "item-secret",
        content_index: 0,
        delta: "recognizable-output"
      )

    {:ok, completed} =
      Event.new(
        :tool_completed,
        Map.merge(tool_event_attrs(), %{
          status: :ok,
          metadata: %{"tool" => "recognizable-tool"}
        })
      )

    refute inspect(delta) =~ "recognizable"
    refute inspect(delta) =~ "secret"
    refute inspect(completed) =~ "recognizable-tool"
    assert inspect(completed) =~ ":ok"
  end

  defp request_attrs do
    %{
      id: "run-1",
      prompt: "recognizable-prompt",
      cwd: "/synthetic/private/root",
      model: "test-model",
      capabilities: capabilities(),
      budget: Budget.default()
    }
  end

  defp capabilities do
    {:ok, capabilities} =
      CapabilitySet.new(fs_read: true, fs_write: true, process_exec: true)

    capabilities
  end

  defp tool_event_attrs do
    %{
      run_id: "run-1",
      turn: 1,
      operation_id: "tool-operation",
      call_id: "call-1",
      name: "read",
      ordinal: 1
    }
  end

  defp agent_result(run_id) do
    response =
      %Provider.Response{
        id: "response-1",
        model: "test-model",
        output_items: [%Message{id: "message-1", role: :assistant, content: "done"}]
      }

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
        message: "synthetic terminal",
        run_id: run_id,
        turn: 1,
        operation_id: nil,
        details: %{}
      )

    error
  end
end
