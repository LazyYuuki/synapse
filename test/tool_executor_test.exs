defmodule Synapse.Tool.ExecutorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Synapse.Tool.{
    Call,
    CapabilitySet,
    Context,
    DispatchContext,
    Dispatcher,
    Executor,
    FixedResult,
    Invocation,
    Limits,
    Result
  }

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

  describe "capability and Context reduction" do
    test "CapabilitySet checks only fixed trusted capability atoms" do
      %CapabilitySet{} = capabilities = capabilities(read: true, write: false, exec: true)

      assert CapabilitySet.allows?(capabilities, :fs_read)
      refute CapabilitySet.allows?(capabilities, :fs_write)
      assert CapabilitySet.allows?(capabilities, :process_exec)
      refute CapabilitySet.allows?(capabilities, "fs_read")
      refute CapabilitySet.allows?(capabilities, :unknown)
      refute CapabilitySet.allows?(%CapabilitySet{capabilities | fs_read: :yes}, :fs_read)
    end

    test "authorizes each capability for internal dispatch and preserves lifetime identity" do
      handle = fake_handle()
      cancel_ref = make_ref()
      owner = self()

      sink = fn operation_context ->
        send(owner, {:unexpected_sink_call, operation_context})
        :ok
      end

      context =
        context(handle,
          cancel_ref: cancel_ref,
          deadline: 123_456,
          activity_sink: sink
        )

      expected = [
        {:fs_read, %Access{read: true, write: false, exec: false}},
        {:fs_write, %Access{read: false, write: true, exec: false}},
        {:process_exec, %Access{read: false, write: false, exec: true}}
      ]

      Enum.each(expected, fn {capability, expected_access} ->
        assert {:ok, dispatch_context} = Context.authorize(context, capability)
        assert %DispatchContext{} = dispatch_context
        assert dispatch_context.workspace == handle
        assert dispatch_context.limits == context.limits
        assert dispatch_context.operation_context.access == expected_access
        assert dispatch_context.operation_context.operation_id == context.operation_id
        assert dispatch_context.operation_context.cancel_ref == cancel_ref
        assert dispatch_context.operation_context.deadline == 123_456
        assert dispatch_context.operation_context.activity_sink == sink
        assert inspect(dispatch_context) == "#Synapse.Tool.DispatchContext<redacted>"
      end)

      refute_receive {:unexpected_sink_call, _context}
    end

    test "intersects selected capability with denied Handle access" do
      {:ok, denied_access} = Access.new(read: false, write: false, exec: false)
      handle = fake_handle(access: denied_access)
      context = context(handle)

      for capability <- [:fs_read, :fs_write, :process_exec] do
        assert {:ok, dispatch_context} = Context.authorize(context, capability)
        assert dispatch_context.operation_context.access == denied_access
      end
    end

    test "denies absent Tool capability and does not consume cancellation" do
      handle = fake_handle()
      cancel_ref = make_ref()
      send(self(), {:cancel, cancel_ref})

      context =
        context(handle,
          capabilities: capabilities(read: false, write: true, exec: true),
          cancel_ref: cancel_ref
        )

      assert {:error, :capability_denied} = Context.authorize(context, :fs_read)
      assert_receive {:cancel, ^cancel_ref}
    end

    test "DispatchContext rejects broad or forged reduced authority" do
      handle = fake_handle()
      context = context(handle)
      {:ok, dispatch_context} = Context.authorize(context, :fs_read)

      broad_access = %Access{read: true, write: true, exec: false}
      broad_operation = %{dispatch_context.operation_context | access: broad_access}

      assert {:error, :invalid_dispatch_context} =
               DispatchContext.new(
                 workspace: handle,
                 operation_context: broad_operation,
                 limits: context.limits
               )

      assert {:error, :invalid_dispatch_context} =
               DispatchContext.new(
                 workspace: %{handle | token: nil},
                 operation_context: dispatch_context.operation_context,
                 limits: context.limits
               )
    end
  end

  describe "Executor admission and static dispatch" do
    test "rejects unconstructable Calls before admission" do
      handle = fake_handle()
      context = context(handle)

      assert Executor.execute(%{}, context) == {:error, :invalid_call}
      assert Executor.execute(nil, context) == {:error, :invalid_call}

      forged = %Call{call_id: "", name: "read", arguments: %{}}
      assert Executor.execute(forged, context) == {:error, :invalid_call}
    end

    test "returns a paired invalid-context Result for a valid Call" do
      call = call("read")

      for invalid_context <- [nil, %{}, %{workspace: :forged}] do
        result = Executor.execute(call, invalid_context)
        assert %Result{call_id: call_id, status: :error} = result
        assert call_id == call.call_id
        assert result_reason(result) == "invalid_context"
      end
    end

    test "returns paired unknown, denied, and invalid-argument Results without Workspace work" do
      handle = fake_handle()

      unknown = Executor.execute(call("not_registered"), context(handle))
      assert_result(unknown, :error, "unknown_tool")

      denied_context =
        context(handle, capabilities: capabilities(read: false, write: false, exec: false))

      denied = Executor.execute(call("read"), denied_context)
      assert_result(denied, :error, "capability_denied")

      invalid_read_arguments =
        call("read", %{"unexpected" => "not validated until the Read adapter"})

      assert_result(
        Executor.execute(invalid_read_arguments, context(handle)),
        :error,
        "invalid_arguments"
      )

      assert :ok = Fake.assert_finished(handle)
    end

    test "revalidates Call under operation limits" do
      handle = fake_handle()
      {:ok, limits} = Limits.new(max_tool_name_bytes: 4)
      context = context(handle, limits: limits)

      assert_result(Executor.execute(call("write"), context), :error, "invalid_call")
      assert_result(Executor.execute(call("read"), context), :error, "invalid_arguments")
    end

    test "retains a trusted pairing ID when the caller lowers its admission limit" do
      handle = fake_handle()
      {:ok, limits} = Limits.new(max_call_id_bytes: 1)
      context = context(handle, limits: limits)
      call = call("bash")

      result = Executor.execute(call, context)

      assert_result(result, :error, "invalid_arguments")
      assert result.call_id == call.call_id
    end

    test "fixed diagnostics fit exact Result protocol floors" do
      handle = fake_handle()

      {:ok, limits} =
        Limits.new(max_result_content_bytes: 256, max_result_metadata_json_bytes: 2)

      context = context(handle, limits: limits)

      results = [
        Executor.execute(call("unknown"), context),
        Executor.execute(
          call("read"),
          context(handle,
            limits: limits,
            capabilities: capabilities(read: false, write: false, exec: false)
          )
        ),
        Executor.execute(call("read"), context)
      ]

      assert Enum.all?(results, &match?(%Result{}, &1))
      assert Enum.all?(results, &(byte_size(&1.content) <= 256 and &1.metadata == %{}))
    end

    test "repeated concurrent calls are deterministic and retain no Executor state" do
      handle = fake_handle()
      context = context(handle)

      results =
        1..20
        |> Task.async_stream(fn _index -> Executor.execute(call("read"), context) end,
          ordered: false,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &(result_reason(&1) == "invalid_arguments"))
      assert Enum.uniq(Enum.map(results, & &1.content)) |> length() == 1
      assert Process.whereis(Executor) == nil
      assert :ets.whereis(Executor) == :undefined
      assert :ok = Fake.assert_finished(handle)
    end
  end

  describe "static Workspace dispatch" do
    test "dispatches each registered module through only its exact Workspace operation" do
      revision = revision(1)
      next_revision = revision(2)
      operation_id = "tool-operation"

      requests = [
        {Synapse.Tool.Read, :fs_read, read_request(), read_result("file.txt", revision, "text")},
        {Synapse.Tool.Write, :fs_write, write_request(),
         mutation_result(operation_id, "file.txt", :missing, next_revision, 4)},
        {Synapse.Tool.Edit, :fs_write, edit_request(revision),
         mutation_result(operation_id, "file.txt", revision, next_revision, 3)},
        {Synapse.Tool.Bash, :process_exec, process_spec(), process_result(operation_id)}
      ]

      Enum.each(requests, fn {module, capability, request, result} ->
        access = access_for(capability)

        {:ok, operation_context} =
          OperationContext.new(operation_id: operation_id, access: access)

        entry = fake_entry(module, request, operation_context, result)
        handle = fake_handle(script: [entry])

        assert {:ok, dispatch_context} = Context.authorize(context(handle), capability)
        assert dispatch_context.operation_context == operation_context
        assert {:ok, dispatch} = Dispatcher.prepare(module, request, dispatch_context)
        assert {:ok, {:ok, ^result}} = Invocation.dispatch(dispatch)
        assert :ok = Fake.assert_finished(handle)
      end)
    end

    test "a faulty Read adapter cannot substitute a write request or broaden authority" do
      handle = fake_handle()
      {:ok, dispatch_context} = Context.authorize(context(handle), :fs_read)
      request = write_request()

      assert {:error, :invalid_dispatch} =
               Dispatcher.prepare(Synapse.Tool.Read, request, dispatch_context)

      broad_operation = %{
        dispatch_context.operation_context
        | access: %Access{read: true, write: true, exec: false}
      }

      assert {:error, :invalid_dispatch_context} =
               DispatchContext.new(
                 workspace: handle,
                 operation_context: broad_operation,
                 limits: dispatch_context.limits
               )

      reduced_handle = %{handle | access: dispatch_context.operation_context.access}
      refute Fake.valid_handle?(reduced_handle)
      assert {:error, %Error{reason: :invalid_handle}} = Workspace.close(reduced_handle)
      assert Fake.valid_handle?(handle)

      assert :ok = Fake.assert_finished(handle)
    end

    test "Dispatcher rejects requests above lowered Tool limits before Workspace" do
      handle = fake_handle()
      {:ok, limits} = Limits.new(max_read_lines: 1, default_read_lines: 1)
      tool_context = context(handle, limits: limits)
      {:ok, dispatch_context} = Context.authorize(tool_context, :fs_read)
      {:ok, broad_request} = ReadRequest.new(path: "file.txt", line_count: 2)

      assert {:error, :invalid_request} =
               Dispatcher.prepare(Synapse.Tool.Read, broad_request, dispatch_context)

      assert :ok = Fake.assert_finished(handle)
    end

    test "Workspace repeats Handle access denial as defense in depth" do
      denied = %Access{read: false, write: false, exec: false}
      handle = fake_handle(access: denied)
      {:ok, dispatch_context} = Context.authorize(context(handle), :fs_read)

      assert dispatch_context.operation_context.access == denied

      assert {:ok, dispatch} =
               Dispatcher.prepare(Synapse.Tool.Read, read_request(), dispatch_context)

      assert {:ok, {:error, %Error{reason: :access_denied, outcome: :not_applied}}} =
               Invocation.dispatch(dispatch)

      assert :ok = Fake.assert_finished(handle)
    end

    test "dispatch preserves exact operation identity and lifetime fields" do
      access = access_for(:fs_read)
      cancel_ref = make_ref()
      sink = fn _operation_context -> :ok end

      {:ok, expected_context} =
        OperationContext.new(
          operation_id: "lifetime-operation",
          access: access,
          cancel_ref: cancel_ref,
          deadline: 123_456,
          activity_sink: sink
        )

      request = read_request()
      result = read_result("file.txt", revision(1), "text")
      entry = Fake.expect_read(request, expected_context, {:ok, result})
      handle = fake_handle(script: [entry])

      tool_context =
        context(handle,
          operation_id: "lifetime-operation",
          cancel_ref: cancel_ref,
          deadline: 123_456,
          activity_sink: sink
        )

      assert {:ok, dispatch_context} = Context.authorize(tool_context, :fs_read)
      assert {:ok, dispatch} = Dispatcher.prepare(Synapse.Tool.Read, request, dispatch_context)
      assert {:ok, {:ok, ^result}} = Invocation.dispatch(dispatch)
      assert :ok = Fake.assert_finished(handle)
    end

    test "Tool callbacks expose no Workspace Handle or operation context argument" do
      assert Synapse.Tool.behaviour_info(:callbacks) |> Enum.sort() ==
               [prepare: 2, present: 3, specification: 0]

      source = File.read!("lib/synapse/tool/executor.ex")
      assert source =~ "module.prepare(call, dispatch_context.limits)"
      assert source =~ "module.present(call, outcome, dispatch_context.limits)"
      refute source =~ "module.prepare(call, dispatch_context)"
      refute source =~ "module.present(call, outcome, dispatch_context)"
    end
  end

  describe "internal callback hardening" do
    test "preparation accepts only a typed request or expected invalid arguments" do
      request = read_request()
      assert Invocation.prepare(fn -> {:ok, request} end) == {:ok, request}

      assert Invocation.prepare(fn -> {:error, :invalid_arguments} end) ==
               {:error, :invalid_arguments}

      callbacks = [
        fn -> raise "synthetic exception secret" end,
        fn -> throw(:synthetic_throw) end,
        fn -> exit(:synthetic_exit) end,
        fn -> :invalid_return end
      ]

      Enum.each(callbacks, fn callback ->
        assert Invocation.prepare(callback) == {:error, :callback_failed}
      end)
    end

    test "dispatch catches exception, throw, exit, and malformed terminal outcomes" do
      callbacks = [
        fn -> raise "synthetic exception secret" end,
        fn -> throw(:synthetic_throw) end,
        fn -> exit(:synthetic_exit) end,
        fn -> :invalid_return end
      ]

      Enum.each(callbacks, fn callback ->
        assert Invocation.dispatch(callback) == {:error, :dispatch_failed}
      end)

      owner = self()

      assert Invocation.dispatch(fn ->
               send(owner, :dispatch_invoked)
               :invalid_return
             end) == {:error, :dispatch_failed}

      assert_receive :dispatch_invoked
      refute_receive :dispatch_invoked
    end

    test "presentation validates pairing and preserves retained terminal outcome on failure" do
      call = call("read")
      limits = Limits.default()
      outcome = {:ok, read_result("file.txt", revision(1), "text")}
      {:ok, expected} = Result.ok(call_id: call.call_id, content: ~s({"status":"ok"}))

      assert Invocation.present(fn -> expected end, call, limits, outcome) == expected

      {:ok, wrong_id} = Result.ok(call_id: "other-call", content: ~s({"status":"ok"}))

      for callback <- [fn -> wrong_id end, fn -> :invalid end] do
        fallback = Invocation.present(callback, call, limits, outcome)
        assert fallback.status == :ok
        assert fallback.call_id == call.call_id
      end

      log =
        capture_log(fn ->
          fallback =
            Invocation.present(
              fn -> raise "synthetic-exception-secret" end,
              call,
              limits,
              outcome
            )

          assert fallback.status == :ok
          refute fallback.content =~ "synthetic"
        end)

      refute log =~ "synthetic-exception-secret"

      ambiguous = {:error, workspace_error(:ambiguous, :backend_unavailable, :unknown)}
      fallback = Invocation.present(fn -> :invalid end, call, limits, ambiguous)
      assert_result(fallback, :ambiguous, "presentation_failed")
      assert result_outcome(fallback) == "unknown"
    end

    test "dispatch failure classification remains conservative by effect" do
      call = call("write")
      limits = Limits.default()

      assert_result(
        FixedResult.error(call.call_id, :internal_error, limits),
        :error,
        "internal_error"
      )

      ambiguous = FixedResult.ambiguous(call.call_id, limits)
      assert_result(ambiguous, :ambiguous, "callback_failed")
      assert result_outcome(ambiguous) == "unknown"
      {:ok, content} = Elixir.JSON.decode(ambiguous.content)
      assert content["error"]["message"] =~ "do not retry blindly"
    end
  end

  defp call(name, arguments \\ %{}) do
    {:ok, call} =
      Call.new(
        call_id: "call-#{name}",
        name: name,
        arguments: arguments
      )

    call
  end

  defp context(handle, options \\ []) do
    attributes =
      options
      |> Keyword.put_new(:capabilities, capabilities())
      |> Keyword.put_new(:limits, Limits.default())
      |> Keyword.put(:workspace, handle)
      |> Keyword.put_new(:operation_id, "tool-operation")

    {:ok, context} = Context.new(attributes)
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

  defp read_request do
    {:ok, request} =
      ReadRequest.new(path: "file.txt", start_line: 1, line_count: 1, max_bytes: 1_024)

    request
  end

  defp write_request do
    {:ok, request} =
      WriteRequest.new(path: "file.txt", content: "text", expected_revision: :missing)

    request
  end

  defp edit_request(revision) do
    {:ok, request} =
      EditRequest.new(
        path: "file.txt",
        old_text: "old",
        new_text: "new",
        expected_revision: revision
      )

    request
  end

  defp process_spec do
    {:ok, spec} =
      ProcessSpec.new(
        executable: "/bin/bash",
        arguments: ["-lc", "true"],
        cwd: ".",
        mutation: :unknown,
        timeout_ms: Limits.default().default_bash_timeout_ms,
        inactivity_ms: Limits.default().default_bash_inactivity_ms,
        max_output_bytes: Limits.default().default_bash_output_bytes
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

  defp mutation_result(operation_id, path, previous_revision, revision, bytes_written) do
    {:ok, result} =
      MutationResult.new(
        operation_id: operation_id,
        path: path,
        previous_revision: previous_revision,
        revision: revision,
        bytes_written: bytes_written,
        changed: true,
        diff: "changed",
        diff_truncated: false
      )

    result
  end

  defp process_result(operation_id) do
    {:ok, result} =
      ProcessResult.new(
        operation_id: operation_id,
        termination: :exited,
        exit_code: 0,
        output: "",
        output_bytes: 0,
        truncated: false,
        elapsed_ms: 0
      )

    result
  end

  defp fake_entry(Synapse.Tool.Read, request, context, result),
    do: Fake.expect_read(request, context, {:ok, result})

  defp fake_entry(Synapse.Tool.Write, request, context, result),
    do: Fake.expect_write(request, context, {:ok, result})

  defp fake_entry(Synapse.Tool.Edit, request, context, result),
    do: Fake.expect_edit(request, context, {:ok, result})

  defp fake_entry(Synapse.Tool.Bash, request, context, result) do
    {:ok, started} = ProcessEvent.Started.new(operation_id: context.operation_id)
    Fake.expect_run(request, context, [started], {:ok, result})
  end

  defp access_for(:fs_read), do: %Access{read: true, write: false, exec: false}
  defp access_for(:fs_write), do: %Access{read: false, write: true, exec: false}
  defp access_for(:process_exec), do: %Access{read: false, write: false, exec: true}

  defp workspace_error(kind, reason, outcome) do
    {:ok, error} =
      Error.new(
        kind: kind,
        reason: reason,
        operation: :write,
        message: "Workspace operation failed",
        outcome: outcome
      )

    error
  end

  defp revision(byte) do
    {:ok, revision} = Revision.from_mac(:binary.copy(<<byte>>, 32))
    revision
  end

  defp fake_handle(options \\ []) do
    {script, options} = Keyword.pop(options, :script, [])
    {:ok, handle} = Fake.open(script, options)
    on_exit(fn -> Workspace.close(handle) end)
    handle
  end

  defp assert_result(result, status, reason) do
    assert %Result{status: ^status} = result
    assert result_reason(result) == reason
    result
  end

  defp result_reason(result) do
    {:ok, content} = Elixir.JSON.decode(result.content)
    content["error"]["reason"]
  end

  defp result_outcome(result) do
    {:ok, content} = Elixir.JSON.decode(result.content)
    content["error"]["outcome"]
  end
end
