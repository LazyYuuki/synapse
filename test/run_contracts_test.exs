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

  test "constructs a trusted Request, defaults conversation, and preserves prompt bytes exactly" do
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
    assert request.conversation == []
    assert Request.valid?(request)
    assert request.capabilities == capabilities()
    assert request.budget == Budget.default()
  end

  test "accepts only bounded complete user and assistant conversation pairs" do
    conversation = [
      %{"role" => "user", "content" => " Earlier question. "},
      %{"role" => "assistant", "content" => "Earlier answer.\n"}
    ]

    assert {:ok, request} =
             request_attrs()
             |> Map.put(:conversation, conversation)
             |> Request.new()

    assert request.conversation == conversation

    maximum_messages =
      List.duplicate(
        [
          %{"role" => "user", "content" => "u"},
          %{"role" => "assistant", "content" => "a"}
        ],
        64
      )
      |> List.flatten()

    assert {:ok, _request} =
             request_attrs()
             |> Map.put(:conversation, maximum_messages)
             |> Request.new()

    maximum_bytes = [
      %{"role" => "user", "content" => String.duplicate("u", 1_572_863)},
      %{"role" => "assistant", "content" => "a"}
    ]

    assert {:ok, _request} =
             request_attrs()
             |> Map.put(:conversation, maximum_bytes)
             |> Request.new()

    invalid = [
      nil,
      [%{"role" => "user", "content" => "incomplete"}],
      [%{"role" => "assistant", "content" => "wrong start"}],
      [
        %{"role" => "user", "content" => "first"},
        %{"role" => "user", "content" => "not alternating"}
      ],
      [
        %{"role" => "user", "content" => "question"},
        %{"role" => "system", "content" => "forbidden"}
      ],
      [
        %{"role" => "user", "content" => "question", "extra" => true},
        %{"role" => "assistant", "content" => "answer"}
      ],
      [
        %{role: "user", content: "atom keys"},
        %{"role" => "assistant", "content" => "answer"}
      ],
      [
        %{"role" => "user", "content" => "   \n"},
        %{"role" => "assistant", "content" => "answer"}
      ],
      [
        %{"role" => "user", "content" => <<255>>},
        %{"role" => "assistant", "content" => "answer"}
      ],
      [
        %{"role" => "user", "content" => String.duplicate("u", 1_572_864)},
        %{"role" => "assistant", "content" => "a"}
      ],
      maximum_messages ++
        [
          %{"role" => "user", "content" => "too many"},
          %{"role" => "assistant", "content" => "too many"}
        ],
      [
        %{"role" => "user", "content" => "question"},
        %{"role" => "assistant", "content" => "answer"}
        | :improper
      ]
    ]

    Enum.each(invalid, fn conversation ->
      assert {:error, {:conversation, :must_be_bounded_complete_user_assistant_pairs}} =
               request_attrs()
               |> Map.put(:conversation, conversation)
               |> Request.new()
    end)
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

  test "Request inspection redacts conversation, prompt, and cwd" do
    attrs =
      Map.put(request_attrs(), :conversation, [
        %{"role" => "user", "content" => "recognizable-history-user"},
        %{"role" => "assistant", "content" => "recognizable-history-assistant"}
      ])

    {:ok, request} = Request.new(attrs)
    inspected = inspect(request)

    assert inspected =~ "run-1"
    assert inspected =~ "test-model"
    refute inspected =~ "recognizable-prompt"
    refute inspected =~ "recognizable-history"
    refute inspected =~ "/synthetic/private/root"
    assert inspected =~ "conversation=redacted"
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

    arguments = %{"path" => "mix.exs", "offset" => nil, "limit" => nil}

    assert {:ok, %Event.ToolStarted{ordinal: 1, arguments: ^arguments}} =
             Event.new(:tool_started, Map.put(tool_event_attrs(), :arguments, arguments))

    content = ~s({"status":"error","error":{"reason":"synthetic"}})

    assert {:ok, %Event.ToolCompleted{status: :error, content: ^content}} =
             Event.new(
               :tool_completed,
               Map.merge(tool_event_attrs(), %{
                 status: :error,
                 metadata: %{"outcome" => "not_applied", "tool" => "read"},
                 content: content
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
    base =
      Map.merge(tool_event_attrs(), %{
        status: :ok,
        content: ~s({"status":"ok"})
      })

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

    assert {:error, {:arguments, :must_be_bounded_string_keyed_json_object}} =
             Event.new(:tool_started, Map.put(tool_event_attrs(), :arguments, %{atom: "value"}))

    assert {:error, {:content, :must_be_bounded_utf8_string}} =
             Event.new(
               :tool_completed,
               Map.merge(base, %{metadata: %{}, content: <<255>>})
             )

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
          metadata: %{"tool" => "recognizable-tool"},
          content: ~s({"status":"ok","value":"recognizable-result"})
        })
      )

    {:ok, started} =
      Event.new(
        :tool_started,
        Map.put(tool_event_attrs(), :arguments, %{
          "path" => "recognizable-argument",
          "credential" => "inert-model-value"
        })
      )

    refute inspect(delta) =~ "recognizable"
    refute inspect(delta) =~ "secret"
    refute inspect(started) =~ "recognizable-argument"
    refute inspect(started) =~ "inert-model-value"
    refute inspect(completed) =~ "recognizable-tool"
    refute inspect(completed) =~ "recognizable-result"
    assert inspect(completed) =~ ":ok"
  end

  test "Tool event model-visible fields enforce exact 64k encoded and UTF-8 boundaries" do
    base = tool_event_attrs()
    argument_padding = 64_000 - byte_size(JSON.encode!(%{"value" => ""}))
    arguments = %{"value" => String.duplicate("x", argument_padding)}
    assert byte_size(JSON.encode!(arguments)) == 64_000

    assert {:ok, %Event.ToolStarted{arguments: ^arguments}} =
             Event.new(:tool_started, Map.put(base, :arguments, arguments))

    assert {:error, {:arguments, :must_be_bounded_string_keyed_json_object}} =
             Event.new(
               :tool_started,
               Map.put(base, :arguments, %{"value" => arguments["value"] <> "x"})
             )

    content = String.duplicate("c", 64_000)

    assert {:ok, %Event.ToolCompleted{content: ^content}} =
             Event.new(
               :tool_completed,
               Map.merge(base, %{status: :ok, metadata: %{}, content: content})
             )

    assert {:error, {:content, :must_be_bounded_utf8_string}} =
             Event.new(
               :tool_completed,
               Map.merge(base, %{status: :ok, metadata: %{}, content: content <> "x"})
             )
  end

  test "Tool event contracts add model data but no authority or credential fields" do
    assert {:error, {:unknown_fields, [:workspace]}} =
             Event.new(
               :tool_started,
               tool_event_attrs()
               |> Map.put(:arguments, %{})
               |> Map.put(:workspace, self())
             )

    assert {:error, {:unknown_fields, [:api_key]}} =
             Event.new(
               :tool_completed,
               tool_event_attrs()
               |> Map.merge(%{status: :ok, metadata: %{}, content: "ok"})
               |> Map.put(:api_key, "credential")
             )
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
