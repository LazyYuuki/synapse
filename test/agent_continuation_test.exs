defmodule Synapse.Agent.ContinuationTest do
  use ExUnit.Case, async: true

  alias Synapse.Agent.{Admission, Context, OperationId, Projection, Runner}
  alias Synapse.Agent.Error, as: AgentError
  alias Synapse.Provider.{Request, Response}
  alias Synapse.Provider.Fake, as: ProviderFake
  alias Synapse.Provider.OutputItem.{FunctionCall, Message}
  alias Synapse.Run.Event
  alias Synapse.Tool.{Call, CapabilitySet, Limits, Registry}
  alias Synapse.Workspace

  alias Synapse.Workspace.{
    Access,
    EditRequest,
    Error,
    Fake,
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

  setup do
    Process.put(:agent_continuation_deadline, System.monotonic_time(:millisecond) + 60_000)
    :ok
  end

  test "projects one mixed Read turn into the exact second Request and final Result" do
    test_pid = self()
    run = run_request()
    read_revision = revision(1)
    read_outcome = read_result("mix.exs", read_revision, "project")
    provider_ids = provider_operation_ids(run, 2)
    tool_id = tool_operation_id(run, 1, 1)

    read_call =
      call("item-read", "call-read", "read", %{
        "path" => "mix.exs",
        "offset" => nil,
        "limit" => nil
      })

    first_response =
      response!("response-read", [
        message("message-before", "I will inspect it."),
        read_call,
        message("message-after", "Read complete.")
      ])

    final_response = text_response("response-final", "The project is ready.")

    entries = [
      Fake.expect_read(
        read_request("mix.exs"),
        operation_context(tool_id, :read),
        {:ok, read_outcome}
      )
    ]

    assert {{:ok, result}, {:ok, 0}, [0, 0]} =
             run_with(run, entries, provider_ids, event_sink(test_pid), fn context ->
               first_request = initial_request(run, context)
               read_result = present(read_call, {:ok, read_outcome})

               second_request =
                 continuation_request(first_request, context, first_response, [read_result], 2)

               [
                 {:turn, first_request, [], {:ok, first_response}},
                 {:turn, second_request, [], {:ok, final_response}}
               ]
             end)

    assert result.text == "The project is ready."
    assert result.turns == 2
    assert result.tool_calls == 1
    assert result.provider_retries == 0

    {:ok, admission} = Admission.preflight(first_response, Limits.default())
    read_result = present(read_call, {:ok, read_outcome})

    assert result.output_bytes ==
             admission.output_bytes + byte_size(read_result.content) + byte_size(result.text)

    assert_receive {:run_event, %Event.TurnCompleted{turn: 1, outcome: :continued, tool_calls: 1}}

    assert_receive {:run_event, %Event.TurnStarted{turn: 2, operation_id: second_operation_id}}
    assert second_operation_id == Enum.at(provider_ids, 1)
    assert_receive {:run_event, %Event.TurnCompleted{turn: 2, outcome: :completed}}
    assert_receive {:run_event, %Event.RunCompleted{result: ^result}}
  end

  test "completes exact Read, Write, Bash continuation then final text" do
    test_pid = self()
    run = run_request()
    read_revision = revision(1)
    write_revision = revision(2)
    provider_ids = provider_operation_ids(run, 2)
    tool_ids = Map.new(1..3, &{&1, tool_operation_id(run, 1, &1)})

    calls = [
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

    read_outcome = read_result("source.txt", read_revision, "old")
    write_outcome = mutation_result(tool_ids[2], "created.txt", :missing, write_revision, 3)
    bash_outcome = process_result(tool_ids[3], 0, "ok")
    first_response = response!("response-rwb", calls)
    final_response = text_response("response-rwb-final", "Read, wrote, and verified.")

    entries = [
      Fake.expect_read(
        read_request("source.txt"),
        operation_context(tool_ids[1], :read),
        {:ok, read_outcome}
      ),
      Fake.expect_write(
        write_request("created.txt", "new", :missing),
        operation_context(tool_ids[2], :write),
        {:ok, write_outcome}
      ),
      Fake.expect_run(
        process_spec("mix test"),
        operation_context(tool_ids[3], :exec),
        process_events(tool_ids[3], "ok"),
        {:ok, bash_outcome}
      )
    ]

    assert {{:ok, result}, {:ok, 0}, [0, 0]} =
             run_with(run, entries, provider_ids, event_sink(test_pid), fn context ->
               first_request = initial_request(run, context)

               results = [
                 present(Enum.at(calls, 0), {:ok, read_outcome}),
                 present(Enum.at(calls, 1), {:ok, write_outcome}),
                 present(Enum.at(calls, 2), {:ok, bash_outcome})
               ]

               second_request =
                 continuation_request(first_request, context, first_response, results, 2)

               projected =
                 Enum.drop(second_request.input_items, length(first_request.input_items))

               assert Enum.map(projected, & &1["type"]) == [
                        "function_call",
                        "function_call_output",
                        "function_call",
                        "function_call_output",
                        "function_call",
                        "function_call_output"
                      ]

               assert Enum.map(projected, & &1["call_id"]) == [
                        "call-read",
                        "call-read",
                        "call-write",
                        "call-write",
                        "call-bash",
                        "call-bash"
                      ]

               [
                 {:turn, first_request, [], {:ok, first_response}},
                 {:turn, second_request, [], {:ok, final_response}}
               ]
             end)

    assert result.text == "Read, wrote, and verified."
    assert result.turns == 2
    assert result.tool_calls == 3
    assert result.provider_retries == 0

    {:ok, admission} = Admission.preflight(first_response, Limits.default())

    [read_result, write_result, bash_result] = [
      present(Enum.at(calls, 0), {:ok, read_outcome}),
      present(Enum.at(calls, 1), {:ok, write_outcome}),
      present(Enum.at(calls, 2), {:ok, bash_outcome})
    ]

    result_bytes =
      Enum.sum(Enum.map([read_result, write_result, bash_result], &byte_size(&1.content)))

    read_arguments = Enum.at(calls, 0).arguments
    write_arguments = Enum.at(calls, 1).arguments
    bash_arguments = Enum.at(calls, 2).arguments

    assert result.output_bytes ==
             admission.output_bytes + result_bytes + byte_size(result.text)

    operation_ids = provider_ids ++ Map.values(tool_ids)
    assert Enum.uniq(operation_ids) == operation_ids

    assert [
             %Event.RunStarted{run_id: run_id},
             %Event.TurnStarted{turn: 1, operation_id: first_provider_id},
             %Event.ToolStarted{
               call_id: "call-read",
               name: "read",
               ordinal: 1,
               operation_id: read_id,
               arguments: ^read_arguments
             },
             %Event.ToolCompleted{
               call_id: "call-read",
               name: "read",
               ordinal: 1,
               operation_id: read_id,
               status: :ok,
               content: read_content
             },
             %Event.ToolStarted{
               call_id: "call-write",
               name: "write",
               ordinal: 2,
               operation_id: write_id,
               arguments: ^write_arguments
             },
             %Event.ToolCompleted{
               call_id: "call-write",
               name: "write",
               ordinal: 2,
               operation_id: write_id,
               status: :ok,
               content: write_content
             },
             %Event.ToolStarted{
               call_id: "call-bash",
               name: "bash",
               ordinal: 3,
               operation_id: bash_id,
               arguments: ^bash_arguments
             },
             %Event.ToolCompleted{
               call_id: "call-bash",
               name: "bash",
               ordinal: 3,
               operation_id: bash_id,
               status: :ok,
               content: bash_content
             },
             %Event.TurnCompleted{
               turn: 1,
               outcome: :continued,
               provider_attempts: 1,
               tool_calls: 3
             },
             %Event.TurnStarted{turn: 2, operation_id: second_provider_id},
             %Event.TurnCompleted{
               turn: 2,
               outcome: :completed,
               provider_attempts: 1,
               tool_calls: 0
             },
             %Event.RunCompleted{result: ^result}
           ] = collect_events([])

    assert read_content == read_result.content
    assert write_content == write_result.content
    assert bash_content == bash_result.content

    assert run_id == run.id
    assert [first_provider_id, second_provider_id] == provider_ids
    assert read_id == tool_ids[1]
    assert write_id == tool_ids[2]
    assert bash_id == tool_ids[3]
  end

  test "completes Read, Edit, Bash and multiple-call continuation" do
    run = run_request()
    source_revision = revision(1)
    edited_revision = revision(2)
    provider_ids = provider_operation_ids(run, 2)
    tool_ids = Map.new(1..3, &{&1, tool_operation_id(run, 1, &1)})

    calls = [
      call("item-read", "call-read", "read", %{
        "path" => "edit.txt",
        "offset" => nil,
        "limit" => nil
      }),
      call("item-edit", "call-edit", "edit", %{
        "path" => "edit.txt",
        "old_text" => "old",
        "new_text" => "new",
        "expected_revision" => Revision.encode(source_revision)
      }),
      call("item-bash", "call-bash", "bash", %{
        "command" => "mix test",
        "timeout_ms" => nil
      })
    ]

    entries = [
      Fake.expect_read(
        read_request("edit.txt"),
        operation_context(tool_ids[1], :read),
        {:ok, read_result("edit.txt", source_revision, "old")}
      ),
      Fake.expect_edit(
        edit_request("edit.txt", "old", "new", source_revision),
        operation_context(tool_ids[2], :write),
        {:ok, mutation_result(tool_ids[2], "edit.txt", source_revision, edited_revision, 3)}
      ),
      Fake.expect_run(
        process_spec("mix test"),
        operation_context(tool_ids[3], :exec),
        process_events(tool_ids[3], "ok"),
        {:ok, process_result(tool_ids[3], 0, "ok")}
      )
    ]

    script = [
      {:turn, [], {:ok, response!("response-reb", calls)}},
      {:turn, [], {:ok, text_response("response-reb-final", "Edited and verified.")}}
    ]

    assert {{:ok, result}, {:ok, 0}, [0, 0]} =
             run_with_script(run, entries, provider_ids, script)

    assert result.tool_calls == 3
    assert result.turns == 2
  end

  test "ordinary unknown and invalid calls can be corrected on later turns" do
    for {label, first_call} <- [
          {"unknown", call("item-unknown", "call-unknown", "not_registered", %{})},
          {"invalid", call("item-invalid", "call-invalid", "read", %{"path" => "missing"})}
        ] do
      run = run_request()
      provider_ids = provider_operation_ids(run, 3)
      read_tool_id = tool_operation_id(run, 2, 1)
      corrected = read_call("item-corrected", "call-corrected", "corrected.txt")

      entries = [
        Fake.expect_read(
          read_request("corrected.txt"),
          operation_context(read_tool_id, :read),
          {:ok, read_result("corrected.txt", revision(1), "fixed")}
        )
      ]

      script = [
        {:turn, [], {:ok, response!("response-#{label}-error", [first_call])}},
        {:turn, [], {:ok, response!("response-#{label}-correction", [corrected])}},
        {:turn, [], {:ok, text_response("response-#{label}-final", "Corrected #{label} call.")}}
      ]

      assert {{:ok, result}, {:ok, 0}, [0, 0, 0]} =
               run_with_script(run, entries, provider_ids, script)

      assert result.turns == 3
      assert result.tool_calls == 2
    end
  end

  test "capability-denied call can be corrected with an allowed Tool" do
    {:ok, capabilities} =
      CapabilitySet.new(fs_read: true, fs_write: false, process_exec: false)

    run = run_request(capabilities: capabilities)
    provider_ids = provider_operation_ids(run, 3)
    read_tool_id = tool_operation_id(run, 2, 1)

    denied =
      call("item-denied", "call-denied", "bash", %{
        "command" => "true",
        "timeout_ms" => nil
      })

    corrected = read_call("item-corrected", "call-corrected", "corrected.txt")

    entries = [
      Fake.expect_read(
        read_request("corrected.txt"),
        operation_context(read_tool_id, :read),
        {:ok, read_result("corrected.txt", revision(1), "fixed")}
      )
    ]

    script = [
      {:turn, [], {:ok, response!("response-denied", [denied])}},
      {:turn, [], {:ok, response!("response-denied-correction", [corrected])}},
      {:turn, [], {:ok, text_response("response-denied-final", "Corrected denied call.")}}
    ]

    assert {{:ok, result}, {:ok, 0}, [0, 0, 0]} =
             run_with_script(run, entries, provider_ids, script)

    assert result.turns == 3
    assert result.tool_calls == 2
  end

  test "stale mutation can reread, correct, and finish" do
    run = run_request()
    stale_revision = revision(1)
    current_revision = revision(2)
    written_revision = revision(3)
    provider_ids = provider_operation_ids(run, 4)
    write_one_id = tool_operation_id(run, 1, 1)
    read_id = tool_operation_id(run, 2, 1)
    write_two_id = tool_operation_id(run, 3, 1)

    stale =
      workspace_error(
        :conflict,
        :stale_revision,
        :not_applied,
        :write,
        write_one_id,
        "stale.txt"
      )

    entries = [
      Fake.expect_write(
        write_request("stale.txt", "new", stale_revision),
        operation_context(write_one_id, :write),
        {:error, stale}
      ),
      Fake.expect_read(
        read_request("stale.txt"),
        operation_context(read_id, :read),
        {:ok, read_result("stale.txt", current_revision, "current")}
      ),
      Fake.expect_write(
        write_request("stale.txt", "new", current_revision),
        operation_context(write_two_id, :write),
        {:ok, mutation_result(write_two_id, "stale.txt", current_revision, written_revision, 3)}
      )
    ]

    script = [
      {:turn, [],
       {:ok,
        response!("response-stale", [
          write_call("item-write-stale", "call-write-stale", "stale.txt", "new", stale_revision)
        ])}},
      {:turn, [],
       {:ok, response!("response-reread", [read_call("item-reread", "call-reread", "stale.txt")])}},
      {:turn, [],
       {:ok,
        response!("response-rewrite", [
          write_call("item-rewrite", "call-rewrite", "stale.txt", "new", current_revision)
        ])}},
      {:turn, [], {:ok, text_response("response-stale-final", "Recovered from stale revision.")}}
    ]

    assert {{:ok, result}, {:ok, 0}, [0, 0, 0, 0]} =
             run_with_script(run, entries, provider_ids, script)

    assert result.turns == 4
    assert result.tool_calls == 3
  end

  test "ambiguous Tool result is projected back to the model instead of terminating" do
    run = run_request()
    provider_ids = provider_operation_ids(run, 2)
    tool_id = tool_operation_id(run, 1, 1)

    write_call =
      call("item-write-ambiguous", "call-write-ambiguous", "write", %{
        "path" => "maybe.txt",
        "content" => "new",
        "expected_revision" => "missing"
      })

    ambiguous =
      workspace_error(
        :ambiguous,
        :durability_unknown,
        :unknown,
        :write,
        tool_id,
        "maybe.txt"
      )

    first_response = response!("response-ambiguous", [write_call])
    final_response = text_response("response-after-ambiguity", "I inspected the uncertainty.")

    entries = [
      Fake.expect_write(
        write_request("maybe.txt", "new", :missing),
        operation_context(tool_id, :write),
        {:error, ambiguous}
      )
    ]

    assert {{:ok, result}, {:ok, 0}, [0, 0]} =
             run_with(run, entries, provider_ids, fn _event -> :ok end, fn context ->
               first_request = initial_request(run, context)
               ambiguous_result = present(write_call, {:error, ambiguous})
               assert ambiguous_result.status == :ambiguous

               second_request =
                 continuation_request(
                   first_request,
                   context,
                   first_response,
                   [ambiguous_result],
                   2
                 )

               [
                 {:turn, first_request, [], {:ok, first_response}},
                 {:turn, second_request, [], {:ok, final_response}}
               ]
             end)

    assert result.text == "I inspected the uncertainty."
    assert result.turns == 2
    assert result.tool_calls == 1
  end

  test "natural Bash failure becomes model feedback before diagnosis" do
    run = run_request()
    provider_ids = provider_operation_ids(run, 2)
    bash_id = tool_operation_id(run, 1, 1)

    bash_call =
      call("item-bash", "call-bash", "bash", %{"command" => "exit 7", "timeout_ms" => nil})

    entries = [
      Fake.expect_run(
        process_spec("exit 7"),
        operation_context(bash_id, :exec),
        process_events(bash_id, "failed"),
        {:ok, process_result(bash_id, 7, "failed")}
      )
    ]

    script = [
      {:turn, [], {:ok, response!("response-bash-failed", [bash_call])}},
      {:turn, [],
       {:ok, text_response("response-bash-diagnosis", "The command failed naturally.")}}
    ]

    assert {{:ok, result}, {:ok, 0}, [0, 0]} =
             run_with_script(run, entries, provider_ids, script)

    assert result.text == "The command failed naturally."
    assert result.tool_calls == 1
  end

  test "final text succeeds after a configured turn ceiling" do
    {:ok, budget} = Synapse.Budget.new(max_turns: 2)
    run = run_request(budget: budget)
    provider_ids = provider_operation_ids(run, 2)

    script = [
      {:turn, [],
       {:ok,
        response!("response-max-tool", [call("item-unknown", "call-unknown", "unknown", %{})])}},
      {:turn, [], {:ok, text_response("response-max-final", "Finished at the limit.")}}
    ]

    assert {{:ok, result}, {:ok, 0}, [0, 0]} =
             run_with_script(run, [], provider_ids, script)

    assert result.turns == 2
    assert result.text == "Finished at the limit."
  end

  test "a Tool turn continues past a configured turn ceiling" do
    {:ok, budget} = Synapse.Budget.new(max_turns: 1)
    run = run_request(budget: budget)
    provider_ids = provider_operation_ids(run, 2)

    script = [
      {:turn, [],
       {:ok,
        response!("response-turn-budget", [call("item-unknown", "call-unknown", "unknown", %{})])}},
      {:turn, [], {:ok, text_response("response-after-old-budget", "Continued safely.")}}
    ]

    assert {{:ok, %{turns: 2, text: "Continued safely."}}, {:ok, 0}, [0, 0]} =
             run_with_script(run, [], provider_ids, script)
  end

  test "persistent cancellation after a known batch prevents continuation" do
    Process.put(:cancel_continuation, false)
    run = run_request()
    [provider_id] = provider_operation_ids(run, 1)

    sink = fn
      %Event.ToolCompleted{} ->
        Process.put(:cancel_continuation, true)
        :ok

      _event ->
        :ok
    end

    script = [
      {:turn, [],
       {:ok,
        response!("response-cancel-next", [call("item-unknown", "call-unknown", "unknown", %{})])}}
    ]

    assert {{:error, %AgentError{kind: :cancelled, reason: :run_cancelled}}, {:ok, 0}, [0]} =
             run_with(
               run,
               [],
               [provider_id],
               sink,
               fn _context -> script end,
               cancelled?: fn -> Process.get(:cancel_continuation, false) end
             )
  end

  defp run_with_script(run, entries, provider_ids, script) do
    run_with(run, entries, provider_ids, fn _event -> :ok end, fn _context -> script end)
  end

  defp run_with(run, entries, provider_ids, sink, script_builder, context_options \\ []) do
    {:ok, workspace} = Fake.open(entries)

    try do
      attributes =
        Keyword.merge(
          [
            provider: ProviderFake,
            workspace: workspace,
            event_sink: sink,
            deadline: Process.get(:agent_continuation_deadline)
          ],
          context_options
        )

      {:ok, context} = Context.new(attributes)

      script = script_builder.(context)

      ProviderFake.with_script(provider_ids, script, fn ->
        result = Runner.run(run, context)

        provider_remaining =
          Enum.map(provider_ids, fn id -> elem(ProviderFake.remaining_turns(id), 1) end)

        {result, Fake.remaining_operations(workspace), provider_remaining}
      end)
    after
      Workspace.close(workspace)
    end
  end

  defp initial_request(run, context) do
    {:ok, state} = Projection.initial_state(run, context, 0)
    {:ok, request} = Projection.provider_request(state, context)
    request
  end

  defp continuation_request(first_request, context, response, results, turn) do
    {:ok, projected} = Projection.response_input(response, results, context.tool_limits)

    {:ok, request} =
      Request.new(
        model: first_request.model,
        instructions: first_request.instructions,
        input_items: first_request.input_items ++ projected,
        tools: Registry.specifications(),
        metadata: %{"run_id" => first_request.metadata["run_id"], "turn" => turn}
      )

    request
  end

  defp present(provider_call, outcome) do
    {:ok, call} = Call.from_provider(provider_call)

    module =
      case call.name do
        "read" -> Synapse.Tool.Read
        "write" -> Synapse.Tool.Write
        "edit" -> Synapse.Tool.Edit
        "bash" -> Synapse.Tool.Bash
      end

    module.present(call, outcome, Limits.default())
  end

  defp event_sink(test_pid) do
    fn event ->
      send(test_pid, {:run_event, event})
      :ok
    end
  end

  defp collect_events(events) do
    receive do
      {:run_event, event} -> collect_events([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp run_request(options \\ []) do
    {:ok, capabilities} =
      CapabilitySet.new(fs_read: true, fs_write: true, process_exec: true)

    {:ok, run} =
      Synapse.Run.Request.new(
        id: "run-continuation-#{System.unique_integer([:positive, :monotonic])}",
        prompt: "Continue until complete",
        cwd: "/tmp/project",
        model: "test-model",
        capabilities: Keyword.get(options, :capabilities, capabilities),
        budget: Keyword.get(options, :budget, Synapse.Budget.default())
      )

    run
  end

  defp provider_operation_ids(run, turns),
    do: Enum.map(1..turns, fn turn -> elem(OperationId.provider(run.id, turn, 1), 1) end)

  defp tool_operation_id(run, turn, ordinal),
    do: elem(OperationId.tool(run.id, turn, ordinal), 1)

  defp response!(id, output_items) do
    {:ok, response} = Response.new(id: id, model: "test-model", output_items: output_items)
    response
  end

  defp text_response(id, content),
    do: response!(id, [message("message-#{id}", content)])

  defp message(id, content), do: %Message{id: id, role: :assistant, content: content}

  defp call(id, call_id, name, arguments),
    do: %FunctionCall{id: id, call_id: call_id, name: name, arguments: arguments}

  defp read_call(id, call_id, path),
    do: call(id, call_id, "read", %{"path" => path, "offset" => nil, "limit" => nil})

  defp write_call(id, call_id, path, content, revision),
    do:
      call(id, call_id, "write", %{
        "path" => path,
        "content" => content,
        "expected_revision" => Revision.encode(revision)
      })

  defp operation_context(operation_id, access) do
    access =
      case access do
        :read -> %Access{read: true, write: false, exec: false}
        :write -> %Access{read: false, write: true, exec: false}
        :exec -> %Access{read: false, write: false, exec: true}
      end

    {:ok, context} =
      OperationContext.new(
        operation_id: operation_id,
        access: access,
        deadline: Process.get(:agent_continuation_deadline)
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

  defp edit_request(path, old_text, new_text, expected_revision) do
    {:ok, request} =
      EditRequest.new(
        path: path,
        old_text: old_text,
        new_text: new_text,
        expected_revision: expected_revision
      )

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

  defp mutation_result(operation_id, path, previous, revision, bytes_written) do
    {:ok, result} =
      MutationResult.new(
        operation_id: operation_id,
        path: path,
        previous_revision: previous,
        revision: revision,
        bytes_written: bytes_written,
        changed: true,
        diff: "changed",
        diff_truncated: false
      )

    result
  end

  defp process_result(operation_id, exit_code, output) do
    {:ok, result} =
      ProcessResult.new(
        operation_id: operation_id,
        termination: :exited,
        exit_code: exit_code,
        output: output,
        output_bytes: byte_size(output),
        truncated: false,
        elapsed_ms: 1
      )

    result
  end

  defp process_events(operation_id, output) do
    {:ok, started} = ProcessEvent.Started.new(operation_id: operation_id)
    {:ok, event} = ProcessEvent.Output.new(operation_id: operation_id, sequence: 1, data: output)
    [started, event]
  end

  defp workspace_error(kind, reason, outcome, operation, operation_id, path) do
    {:ok, error} =
      Error.new(
        kind: kind,
        reason: reason,
        operation: operation,
        message: "Workspace operation failed",
        operation_id: operation_id,
        path: path,
        outcome: outcome
      )

    error
  end

  defp revision(byte) do
    {:ok, revision} = Revision.from_mac(:binary.copy(<<byte>>, 32))
    revision
  end
end
