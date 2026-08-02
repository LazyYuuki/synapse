defmodule Synapse.Tool.IntegrationTest do
  use ExUnit.Case, async: false

  alias Synapse.Provider
  alias Synapse.Provider.{Request, Response, ResponsesCodec}
  alias Synapse.Provider.Event.ToolCallCompleted
  alias Synapse.Provider.OutputItem.FunctionCall
  alias Synapse.Tool.{Call, CapabilitySet, Context, Executor, Limits, Result}
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

  describe "completed Provider Response to Tool continuation" do
    test "executes all four complete calls and preserves only the pairing ID across boundaries" do
      old_revision = revision(1)
      new_revision = revision(2)
      edit_revision = revision(3)
      edited_revision = revision(4)

      provider_calls = [
        provider_call(
          "provider-item-read",
          "call-read",
          "read",
          %{"path" => "read.txt", "offset" => nil, "limit" => nil}
        ),
        provider_call(
          "provider-item-write",
          "call-write",
          "write",
          %{
            "path" => "created.txt",
            "content" => "new",
            "expected_revision" => "missing"
          }
        ),
        provider_call(
          "provider-item-edit",
          "call-edit",
          "edit",
          %{
            "path" => "edit.txt",
            "old_text" => "old",
            "new_text" => "new",
            "expected_revision" => Revision.encode(edit_revision)
          }
        ),
        provider_call(
          "provider-item-bash",
          "call-bash",
          "bash",
          %{"command" => "printf ok", "timeout_ms" => nil}
        )
      ]

      response = completed_response("response-all-tools", provider_calls)

      operation_ids = %{
        "call-read" => "workspace-op-a1",
        "call-write" => "workspace-op-a2",
        "call-edit" => "workspace-op-a3",
        "call-bash" => "workspace-op-a4"
      }

      entries = [
        Fake.expect_read(
          read_request("read.txt"),
          operation_context(operation_ids["call-read"], :read),
          {:ok, read_result("read.txt", old_revision, "old")}
        ),
        Fake.expect_write(
          write_request("created.txt", "new", :missing),
          operation_context(operation_ids["call-write"], :write),
          {:ok,
           mutation_result(
             operation_ids["call-write"],
             "created.txt",
             :missing,
             new_revision,
             3
           )}
        ),
        Fake.expect_edit(
          edit_request("edit.txt", "old", "new", edit_revision),
          operation_context(operation_ids["call-edit"], :write),
          {:ok,
           mutation_result(
             operation_ids["call-edit"],
             "edit.txt",
             edit_revision,
             edited_revision,
             3
           )}
        ),
        Fake.expect_run(
          process_spec("printf ok"),
          operation_context(operation_ids["call-bash"], :exec),
          process_events(operation_ids["call-bash"], "ok"),
          {:ok, process_result(operation_ids["call-bash"], 0, "ok")}
        )
      ]

      handle = fake_handle(entries)

      assert {:ok, calls, results, continuation} =
               execute_completed_response(
                 {:ok, response},
                 context_builder(handle, operation_ids)
               )

      assert Enum.map(calls, & &1.call_id) == Enum.map(provider_calls, & &1.call_id)
      assert Enum.map(results, & &1.call_id) == Enum.map(provider_calls, & &1.call_id)
      assert Enum.map(results, & &1.status) == [:ok, :ok, :ok, :ok]

      assert Enum.all?(calls, fn call ->
               not Map.has_key?(Map.from_struct(call), :id)
             end)

      assert Enum.map(provider_calls, & &1.id) == [
               "provider-item-read",
               "provider-item-write",
               "provider-item-edit",
               "provider-item-bash"
             ]

      output_items = Enum.filter(continuation, &(&1["type"] == "function_call_output"))
      call_items = Enum.filter(continuation, &(&1["type"] == "function_call"))

      assert Enum.map(output_items, & &1["call_id"]) == Enum.map(results, & &1.call_id)
      assert Enum.map(output_items, & &1["output"]) == Enum.map(results, & &1.content)
      assert Enum.map(call_items, & &1["call_id"]) == Enum.map(provider_calls, & &1.call_id)
      assert Enum.map(call_items, & &1["id"]) == Enum.map(provider_calls, & &1.id)
      assert Enum.all?(output_items, &(not Map.has_key?(&1, "id")))

      expected_continuation =
        provider_calls
        |> Enum.zip(results)
        |> Enum.flat_map(fn {provider_call, result} ->
          [function_call_input(provider_call), function_output(result)]
        end)

      assert continuation == expected_continuation

      assert {:ok, request} = Request.new(model: "test-model", input_items: continuation)
      assert {:ok, encoded} = ResponsesCodec.encode(request)

      encoded_outputs =
        Enum.filter(encoded["input"], &(&1["type"] == "function_call_output"))

      assert Enum.map(encoded_outputs, & &1["call_id"]) == Enum.map(results, & &1.call_id)
      assert Enum.map(encoded_outputs, & &1["output"]) == Enum.map(results, & &1.content)

      encoded_calls = Enum.filter(encoded["input"], &(&1["type"] == "function_call"))
      assert Enum.map(encoded_calls, & &1["id"]) == Enum.map(provider_calls, & &1.id)
      assert :ok = Fake.assert_finished(handle)
    end

    test "failed, interrupted, incomplete, and forged terminal inputs execute nothing" do
      expected_call =
        provider_call(
          "provider-item-never",
          "call-never",
          "read",
          %{"path" => "never.txt", "offset" => nil, "limit" => nil}
        )

      expected_entry =
        Fake.expect_read(
          read_request("never.txt"),
          operation_context("workspace-never-op", :read),
          {:ok, read_result("never.txt", revision(1), "never")}
        )

      handle = fake_handle([expected_entry])

      context_builder = fn call ->
        send(self(), {:unexpected_context, call.call_id})
        tool_context(handle, call, "workspace-never-op")
      end

      failed = provider_error(:upstream, false)
      interrupted = provider_error(:interrupted, true)

      progress = %ToolCallCompleted{
        item_id: expected_call.id,
        call_id: expected_call.call_id,
        name: expected_call.name,
        arguments: expected_call.arguments
      }

      forged_incomplete = %Response{
        id: "forged-incomplete",
        model: "test-model",
        output_items: [%FunctionCall{expected_call | id: ""}],
        status: :completed
      }

      forged_failed = %Response{
        id: "forged-failed",
        model: "test-model",
        output_items: [expected_call],
        status: :failed
      }

      too_large_call = %FunctionCall{
        id: String.duplicate("x", Limits.default().max_call_id_bytes + 1),
        call_id: "call-too-large",
        name: "read",
        arguments: %{"path" => "never.txt", "offset" => nil, "limit" => nil}
      }

      unconstructable_response =
        completed_response("response-unconstructable", [expected_call, too_large_call])

      inputs = [
        {:error, failed},
        {:error, interrupted},
        progress,
        expected_call,
        {:ok, forged_incomplete},
        {:ok, forged_failed},
        {:ok, unconstructable_response}
      ]

      Enum.each(inputs, fn input ->
        assert execute_completed_response(input, context_builder) ==
                 {:error, :provider_not_completed}
      end)

      refute_receive {:unexpected_context, _call_id}
      assert {:ok, 1} = Fake.remaining_operations(handle)
    end
  end

  describe "sequential Fake Workspace scenarios" do
    test "runs read -> write -> bash in Provider source order" do
      old_revision = revision(1)
      new_revision = revision(2)

      calls = [
        provider_call(
          "item-read-write",
          "call-read-write",
          "read",
          %{"path" => "target.txt", "offset" => nil, "limit" => nil}
        ),
        provider_call(
          "item-write",
          "call-write-target",
          "write",
          %{
            "path" => "target.txt",
            "content" => "new",
            "expected_revision" => Revision.encode(old_revision)
          }
        ),
        provider_call(
          "item-bash-after-write",
          "call-bash-after-write",
          "bash",
          %{"command" => "printf checked", "timeout_ms" => 1_000}
        )
      ]

      operation_ids = %{
        "call-read-write" => "workspace-write-sequence-1",
        "call-write-target" => "workspace-write-sequence-2",
        "call-bash-after-write" => "workspace-write-sequence-3"
      }

      handle =
        fake_handle([
          Fake.expect_read(
            read_request("target.txt"),
            operation_context(operation_ids["call-read-write"], :read),
            {:ok, read_result("target.txt", old_revision, "old")}
          ),
          Fake.expect_write(
            write_request("target.txt", "new", old_revision),
            operation_context(operation_ids["call-write-target"], :write),
            {:ok,
             mutation_result(
               operation_ids["call-write-target"],
               "target.txt",
               old_revision,
               new_revision,
               3
             )}
          ),
          Fake.expect_run(
            process_spec("printf checked", 1_000),
            operation_context(operation_ids["call-bash-after-write"], :exec),
            process_events(operation_ids["call-bash-after-write"], "checked"),
            {:ok, process_result(operation_ids["call-bash-after-write"], 0, "checked")}
          )
        ])

      assert {:ok, tool_calls, results, outputs} =
               execute_completed_response(
                 {:ok, completed_response("response-read-write-bash", calls)},
                 context_builder(handle, operation_ids)
               )

      assert Enum.map(tool_calls, & &1.name) == ["read", "write", "bash"]
      assert Enum.map(results, &decode(&1)["tool"]) == ["read", "write", "bash"]
      assert Enum.map(outputs, & &1["call_id"]) |> Enum.uniq() |> length() == 3
      assert :ok = Fake.assert_finished(handle)
    end

    test "runs read -> edit -> bash in Provider source order" do
      old_revision = revision(1)
      new_revision = revision(2)

      calls = [
        provider_call(
          "item-read-edit",
          "call-read-edit",
          "read",
          %{"path" => "target.txt", "offset" => nil, "limit" => nil}
        ),
        provider_call(
          "item-edit",
          "call-edit-target",
          "edit",
          %{
            "path" => "target.txt",
            "old_text" => "old",
            "new_text" => "new",
            "expected_revision" => Revision.encode(old_revision)
          }
        ),
        provider_call(
          "item-bash-after-edit",
          "call-bash-after-edit",
          "bash",
          %{"command" => "printf checked", "timeout_ms" => 1_000}
        )
      ]

      operation_ids = %{
        "call-read-edit" => "workspace-edit-sequence-1",
        "call-edit-target" => "workspace-edit-sequence-2",
        "call-bash-after-edit" => "workspace-edit-sequence-3"
      }

      handle =
        fake_handle([
          Fake.expect_read(
            read_request("target.txt"),
            operation_context(operation_ids["call-read-edit"], :read),
            {:ok, read_result("target.txt", old_revision, "old")}
          ),
          Fake.expect_edit(
            edit_request("target.txt", "old", "new", old_revision),
            operation_context(operation_ids["call-edit-target"], :write),
            {:ok,
             mutation_result(
               operation_ids["call-edit-target"],
               "target.txt",
               old_revision,
               new_revision,
               3
             )}
          ),
          Fake.expect_run(
            process_spec("printf checked", 1_000),
            operation_context(operation_ids["call-bash-after-edit"], :exec),
            process_events(operation_ids["call-bash-after-edit"], "checked"),
            {:ok, process_result(operation_ids["call-bash-after-edit"], 0, "checked")}
          )
        ])

      assert {:ok, tool_calls, results, _outputs} =
               execute_completed_response(
                 {:ok, completed_response("response-read-edit-bash", calls)},
                 context_builder(handle, operation_ids)
               )

      assert Enum.map(tool_calls, & &1.name) == ["read", "edit", "bash"]
      assert Enum.map(results, &decode(&1)["tool"]) == ["read", "edit", "bash"]
      assert :ok = Fake.assert_finished(handle)
    end

    test "unknown, invalid, denied, and ordinary failed calls remain paired and sequential" do
      stale_revision = revision(1)

      calls = [
        provider_call("item-unknown", "call-unknown", "not_registered", %{}),
        provider_call(
          "item-invalid",
          "call-invalid",
          "read",
          %{"path" => "missing-fields.txt"}
        ),
        provider_call(
          "item-denied",
          "call-denied",
          "bash",
          %{"command" => "true", "timeout_ms" => nil}
        ),
        provider_call(
          "item-failed",
          "call-failed",
          "write",
          %{
            "path" => "failed.txt",
            "content" => "new",
            "expected_revision" => Revision.encode(stale_revision)
          }
        ),
        provider_call("item-after-failure", "call-after-failure", "still_unknown", %{})
      ]

      stale =
        workspace_error(
          :conflict,
          :stale_revision,
          :not_applied,
          :write,
          "workspace-failure-sequence-4",
          "failed.txt"
        )

      handle =
        fake_handle([
          Fake.expect_write(
            write_request("failed.txt", "new", stale_revision),
            operation_context("workspace-failure-sequence-4", :write),
            {:error, stale}
          )
        ])

      operation_ids = %{
        "call-unknown" => "workspace-failure-sequence-1",
        "call-invalid" => "workspace-failure-sequence-2",
        "call-denied" => "workspace-failure-sequence-3",
        "call-failed" => "workspace-failure-sequence-4",
        "call-after-failure" => "workspace-failure-sequence-5"
      }

      context_builder = fn call ->
        capabilities =
          if call.call_id == "call-denied",
            do: capabilities(exec: false),
            else: capabilities()

        tool_context(handle, call, operation_ids[call.call_id], capabilities)
      end

      assert {:ok, tool_calls, results, outputs} =
               execute_completed_response(
                 {:ok, completed_response("response-paired-failures", calls)},
                 context_builder
               )

      assert Enum.map(tool_calls, & &1.call_id) == Enum.map(calls, & &1.call_id)
      assert Enum.map(results, & &1.call_id) == Enum.map(calls, & &1.call_id)

      projected_outputs =
        Enum.filter(outputs, &(&1["type"] == "function_call_output"))

      assert Enum.map(projected_outputs, & &1["call_id"]) == Enum.map(calls, & &1.call_id)

      assert Enum.map(results, &decode(&1)["error"]["reason"]) == [
               "unknown_tool",
               "invalid_arguments",
               "capability_denied",
               "stale_revision",
               "unknown_tool"
             ]

      assert Enum.all?(results, &(&1.status == :error))
      assert :ok = Fake.assert_finished(handle)
    end

    test "ambiguity stops later admission without claiming an Agent Loop" do
      calls = [
        provider_call(
          "item-ambiguous",
          "call-ambiguous",
          "write",
          %{"path" => "maybe.txt", "content" => "value", "expected_revision" => "missing"}
        ),
        provider_call(
          "item-after-ambiguity",
          "call-after-ambiguity",
          "bash",
          %{"command" => "printf must-not-run", "timeout_ms" => nil}
        )
      ]

      ambiguous =
        workspace_error(
          :ambiguous,
          :durability_unknown,
          :unknown,
          :write,
          "workspace-ambiguity-1",
          "maybe.txt"
        )

      operation_ids = %{
        "call-ambiguous" => "workspace-ambiguity-1",
        "call-after-ambiguity" => "workspace-ambiguity-2"
      }

      later_operation = operation_ids["call-after-ambiguity"]

      handle =
        fake_handle([
          Fake.expect_write(
            write_request("maybe.txt", "value", :missing),
            operation_context(operation_ids["call-ambiguous"], :write),
            {:error, ambiguous}
          ),
          Fake.expect_run(
            process_spec("printf must-not-run"),
            operation_context(later_operation, :exec),
            process_events(later_operation, "must-not-run"),
            {:ok, process_result(later_operation, 0, "must-not-run")}
          )
        ])

      assert {:ok, [tool_call], [result], continuation} =
               execute_completed_response(
                 {:ok, completed_response("response-ambiguity-stop", calls)},
                 context_builder(handle, operation_ids)
               )

      assert tool_call.call_id == "call-ambiguous"
      assert result.status == :ambiguous

      assert [output] =
               Enum.filter(continuation, &(&1["type"] == "function_call_output"))

      assert output["call_id"] == result.call_id
      assert {:ok, 1} = Fake.remaining_operations(handle)
    end
  end

  test "Tool implementation modules contain no direct host, network, or higher-layer calls" do
    sources =
      "lib/synapse/tool/*.ex"
      |> Elixir.Path.wildcard()
      |> Enum.map(&File.read!/1)

    forbidden = [
      ~r/\bFile\./,
      ~r/\bSystem\./,
      ~r/\bPort\./,
      ~r/\bReq\./,
      ~r/\bAgent\./,
      ~r/\bRuntime\./,
      ~r/\bCLI\./,
      ~r/\bMuonTrap\b/
    ]

    Enum.each(sources, fn source ->
      Enum.each(forbidden, fn pattern -> refute source =~ pattern end)
    end)

    source = File.read!("test/tool_integration_test.exs")
    refute source =~ "Process." <> "sleep"
    refute source =~ "Task." <> "async"
  end

  defp execute_completed_response(
         {:ok, %Response{status: :completed} = response},
         context_builder
       )
       when is_function(context_builder, 1) do
    with {:ok, response} <- Response.new(Map.from_struct(response)),
         {:ok, admitted_calls} <- admit_all_calls(response.output_items) do
      admitted_calls
      |> Enum.reduce_while({:ok, [], [], []}, fn {provider_call, call},
                                                 {:ok, calls, results, continuation} ->
        result = Executor.execute(call, context_builder.(call))

        next =
          {:ok, [call | calls], [result | results],
           [function_output(result), function_call_input(provider_call) | continuation]}

        if result.status == :ambiguous, do: {:halt, next}, else: {:cont, next}
      end)
      |> reverse_execution()
    else
      {:error, _reason} -> {:error, :provider_not_completed}
    end
  end

  defp execute_completed_response(_provider_result, _context_builder),
    do: {:error, :provider_not_completed}

  defp reverse_execution({:ok, calls, results, continuation}),
    do: {:ok, Enum.reverse(calls), Enum.reverse(results), Enum.reverse(continuation)}

  defp reverse_execution(error), do: error

  defp admit_all_calls(output_items) do
    output_items
    |> Enum.filter(&is_struct(&1, FunctionCall))
    |> Enum.reduce_while({:ok, []}, fn provider_call, {:ok, calls} ->
      case Call.from_provider(provider_call) do
        {:ok, call} -> {:cont, {:ok, [{provider_call, call} | calls]}}
        {:error, _reason} -> {:halt, {:error, :invalid_function_call}}
      end
    end)
    |> case do
      {:ok, calls} -> {:ok, Enum.reverse(calls)}
      error -> error
    end
  end

  defp function_call_input(provider_call) do
    %{
      "type" => "function_call",
      "id" => provider_call.id,
      "call_id" => provider_call.call_id,
      "name" => provider_call.name,
      "arguments" => provider_call.arguments
    }
  end

  defp function_output(result) do
    %{
      "type" => "function_call_output",
      "call_id" => result.call_id,
      "output" => result.content
    }
  end

  defp completed_response(id, calls) do
    {:ok, response} = Response.new(id: id, model: "test-model", output_items: calls)
    response
  end

  defp provider_call(id, call_id, name, arguments),
    do: %FunctionCall{id: id, call_id: call_id, name: name, arguments: arguments}

  defp provider_error(kind, output_started) do
    {:ok, error} =
      Provider.Error.new(
        kind: kind,
        message: "Provider did not complete successfully",
        retryable: false,
        output_started: output_started,
        operation_id: "provider-failure"
      )

    error
  end

  defp context_builder(handle, operation_ids) do
    fn call -> tool_context(handle, call, Map.fetch!(operation_ids, call.call_id)) end
  end

  defp tool_context(handle, _call, operation_id, capabilities \\ capabilities()) do
    {:ok, context} =
      Context.new(
        workspace: handle,
        capabilities: capabilities,
        operation_id: operation_id,
        limits: Limits.default()
      )

    context
  end

  defp capabilities(options \\ []) do
    {:ok, capabilities} =
      CapabilitySet.new(
        fs_read: Keyword.get(options, :read, true),
        fs_write: Keyword.get(options, :write, true),
        process_exec: Keyword.get(options, :exec, true)
      )

    capabilities
  end

  defp operation_context(operation_id, access) do
    access =
      case access do
        :read -> %Access{read: true, write: false, exec: false}
        :write -> %Access{read: false, write: true, exec: false}
        :exec -> %Access{read: false, write: false, exec: true}
      end

    {:ok, context} = OperationContext.new(operation_id: operation_id, access: access)
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
      WriteRequest.new(
        path: path,
        content: content,
        expected_revision: expected_revision
      )

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

  defp process_spec(command, timeout_ms \\ nil) do
    limits = Limits.default()

    {:ok, spec} =
      ProcessSpec.new(
        executable: "/bin/bash",
        arguments: ["-lc", command],
        cwd: ".",
        inactivity_ms: limits.default_bash_inactivity_ms,
        timeout_ms: timeout_ms || limits.default_bash_timeout_ms,
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

  defp fake_handle(script) do
    {:ok, handle} = Fake.open(script)
    on_exit(fn -> Workspace.close(handle) end)
    handle
  end

  defp decode(%Result{} = result) do
    {:ok, content} = Elixir.JSON.decode(result.content)
    content
  end
end
