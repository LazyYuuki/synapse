defmodule Synapse.Tool.Phase10Test do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  require Logger

  alias Synapse.Provider
  alias Synapse.Provider.Event.{ToolCallCompleted, ToolCallDelta}
  alias Synapse.Provider.OutputItem.FunctionCall

  alias Synapse.Tool.{
    Call,
    CapabilitySet,
    Context,
    Executor,
    FixedResult,
    Invocation,
    Registry,
    Result,
    Spec,
    Validation
  }

  alias Synapse.Workspace

  alias Synapse.Workspace.{
    Access,
    Error,
    Fake,
    Handle,
    MutationResult,
    ProcessResult,
    Revision
  }

  alias Synapse.Tool.Limits, as: ToolLimits
  alias Synapse.Workspace.Limits, as: WorkspaceLimits

  @int64_min -9_223_372_036_854_775_808
  @int64_max 9_223_372_036_854_775_807
  @synthetic_secret "sk-proj-SYNTHETIC-PHASE10-CREDENTIAL"
  @synthetic_path "/Users/synthetic/private/project"

  defmodule CrashingReadBackend do
    def workspace_backend?, do: true
    def valid_handle?(_handle), do: true
    def close(_handle), do: :ok

    def read(handle, _request, _context) do
      send(handle.state, :crashing_read_invoked)
      raise "synthetic-read-exception-secret"
    end
  end

  defmodule MalformedReadBackend do
    def workspace_backend?, do: true
    def valid_handle?(_handle), do: true
    def close(_handle), do: :ok

    def read(handle, _request, _context) do
      send(handle.state, :malformed_read_invoked)
      :malformed
    end
  end

  test "signed integer and trusted bignum boundaries fail closed" do
    assert Validation.int64?(@int64_min)
    assert Validation.int64?(@int64_max)
    refute Validation.int64?(@int64_min - 1)
    refute Validation.int64?(@int64_max + 1)

    for integer <- [@int64_min, @int64_max] do
      assert {:ok, _call} =
               Call.new(call_id: "integer-call", name: "unknown", arguments: %{"n" => integer})
    end

    for integer <- [@int64_min - 1, @int64_max + 1] do
      assert {:error, {:arguments, :must_be_bounded_string_keyed_json_object}} =
               Call.new(call_id: "integer-call", name: "unknown", arguments: %{"n" => integer})
    end

    assert {:ok, _spec} = integer_spec(@int64_min, @int64_max)

    assert {:error, {:parameters, :must_be_complete_strict_flat_object_schema}} =
             integer_spec(@int64_min - 1, @int64_max)

    assert {:error, {:parameters, :must_be_complete_strict_flat_object_schema}} =
             integer_spec(@int64_min, @int64_max + 1)

    huge = Bitwise.bsl(1, 512)

    ToolLimits.default()
    |> Map.from_struct()
    |> Map.keys()
    |> Enum.each(fn field ->
      assert {:error, {^field, :must_be_reasonable_positive_integer}} =
               ToolLimits.new(%{field => huge})
    end)
  end

  test "presentation exception, throw, exit, malformed return, and wrong pairing preserve outcome" do
    call = call("write", %{})
    limits = ToolLimits.default()
    previous = revision(1)
    current = revision(2)

    outcomes = [
      {:successful_mutation, {:ok, mutation_result(previous, current)}, :ok, nil},
      {:known_not_applied, {:error, workspace_error(:conflict, :stale_revision, :not_applied)},
       :error, "not_applied"},
      {:completed_nonzero, {:ok, process_result(7)}, :error, "completed"},
      {:unknown, {:error, workspace_error(:ambiguous, :backend_unavailable, :unknown)},
       :ambiguous, "unknown"}
    ]

    {:ok, wrong_id} = Result.ok(call_id: "wrong-call", content: ~s({"status":"ok"}))

    callbacks = [
      fn -> raise "#{@synthetic_secret}-raise" end,
      fn -> throw({:synthetic, @synthetic_secret}) end,
      fn -> exit({:synthetic, @synthetic_secret}) end,
      fn -> :malformed end,
      fn -> wrong_id end
    ]

    log =
      capture_log(fn ->
        Enum.each(outcomes, fn {_name, outcome, expected_status, expected_outcome} ->
          Enum.each(callbacks, fn callback ->
            result = Invocation.present(callback, call, limits, outcome)
            content = decode(result)

            assert result.status == expected_status
            assert result.call_id == call.call_id
            assert byte_size(result.content) <= limits.max_result_content_bytes
            assert String.valid?(result.content)

            if expected_status == :ok do
              assert content["presentation"] == "unavailable"
            else
              assert content["error"]["reason"] == "presentation_failed"
              assert content["error"]["outcome"] == expected_outcome
            end

            refute result.content =~ @synthetic_secret
          end)
        end)
      end)

    refute log =~ @synthetic_secret
  end

  test "read-only dispatch backend failure is ordinary, paired, sanitized, and invoked once" do
    for {backend, message} <- [
          {CrashingReadBackend, :crashing_read_invoked},
          {MalformedReadBackend, :malformed_read_invoked}
        ] do
      result =
        Executor.execute(
          read_call("file.txt"),
          context(backend_handle(backend), "phase10-read-failure")
        )

      content = decode(result)
      assert result.status == :error
      assert content["error"]["reason"] == "backend_unavailable"
      assert content["error"]["outcome"] == "not_applicable"
      refute result.content =~ "synthetic-read-exception-secret"
      assert_receive ^message
      refute_receive ^message
    end
  end

  test "central dispatch failure classification is fixed by registered effect" do
    limits = ToolLimits.default()

    read_only = FixedResult.dispatch_failure("call-read", :read_only, limits)
    mutation = FixedResult.dispatch_failure("call-write", :mutation, limits)
    unknown = FixedResult.dispatch_failure("call-bash", :unknown, limits)

    assert read_only.status == :error
    assert decode(read_only)["error"]["reason"] == "internal_error"
    assert decode(read_only)["error"]["outcome"] == "not_applicable"

    Enum.each([mutation, unknown], fn result ->
      assert result.status == :ambiguous
      assert decode(result)["error"]["reason"] == "callback_failed"
      assert decode(result)["error"]["outcome"] == "unknown"
    end)
  end

  test "mutating pre-dispatch rejection is explicitly not applied and consumes no Workspace work" do
    handle = fake_handle([])

    invalid_calls = [
      call("write", %{"path" => "file.txt"}),
      call("edit", %{
        "path" => "file.txt",
        "old_text" => "",
        "new_text" => "new",
        "expected_revision" => Revision.encode(revision(1))
      }),
      call("bash", %{"command" => "", "timeout_ms" => nil})
    ]

    Enum.each(invalid_calls, fn invalid_call ->
      result = Executor.execute(invalid_call, context(handle, "phase10-invalid"))
      assert result.status == :error
      assert decode(result)["error"]["outcome"] == "not_applied"
    end)

    denied =
      Executor.execute(
        call("write", %{
          "path" => "file.txt",
          "content" => "content",
          "expected_revision" => "missing"
        }),
        context(handle, "phase10-denied", capabilities(false, false, false))
      )

    assert denied.status == :error
    assert decode(denied)["error"]["reason"] == "capability_denied"
    assert decode(denied)["error"]["outcome"] == "not_applied"
    assert :ok = Fake.assert_finished(handle)
  end

  test "many near-limit Calls and Results leave no process, atom, ETS, or global state" do
    handle = fake_handle([])
    tool_context = context(handle, "phase10-stress")

    warm = call("unknown-warm", %{"payload" => String.duplicate("w", 63_000)})
    assert Executor.execute(warm, tool_context).status == :error
    _warm_runtime_snapshots = {:ets.all(), Process.registered(), :global.registered_names()}
    :erlang.garbage_collect()

    before_atoms = :erlang.system_info(:atom_count)
    parent = self()

    {worker, monitor} =
      spawn_monitor(fn ->
        Enum.each(1..250, fn index ->
          payload = Integer.to_string(index) <> String.duplicate("x", 62_990)
          call = call("unknown-phase10-#{index}", %{"payload" => payload})
          result = Executor.execute(call, tool_context)
          true = result.status == :error

          content = ~s({"status":"ok","evidence":"#{payload}"})
          {:ok, %Result{}} = Result.ok(call_id: "large-result-#{index}", content: content)
        end)

        :erlang.garbage_collect()
        {:binary, binaries} = Process.info(self(), :binary)
        send(parent, {:phase10_worker_binaries, self(), binaries})
      end)

    assert_receive {:phase10_worker_binaries, ^worker, binaries}, 10_000
    assert Enum.sum(Enum.map(binaries, fn {_reference, bytes, _references} -> bytes end)) < 16_384
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 10_000
    refute Process.alive?(worker)

    :erlang.garbage_collect()
    assert :erlang.system_info(:atom_count) == before_atoms
    assert Process.whereis(Executor) == nil
    assert :ets.whereis(Executor) == :undefined
    assert :global.whereis_name(Executor) == :undefined
    assert :ok = Fake.assert_finished(handle)
  end

  test "Executor executes synchronously without spawning or owning mutable runtime state" do
    handle = fake_handle([])
    tool_context = context(handle, "phase10-no-state")
    call = call("unknown-no-state", %{})

    :erlang.trace(self(), true, [:procs])
    result = Executor.execute(call, tool_context)
    :erlang.trace(self(), false, [:procs])

    assert result.status == :error
    refute_receive {:trace, _tracer, :spawn, _pid, _mfa}

    source = File.read!("lib/synapse/tool/executor.ex")

    for forbidden <- [
          "GenServer",
          "Agent.",
          "Task.",
          "spawn(",
          "spawn_link(",
          ":ets.",
          ":persistent_term",
          "Process.register",
          ":global."
        ] do
      refute source =~ forbidden
    end

    assert :ok = Fake.assert_finished(handle)
  end

  test "Tool structs and source expose no direct host or dynamic authority fields" do
    structs = [
      Call.__struct__(),
      Result.__struct__(),
      Spec.__struct__(),
      CapabilitySet.__struct__(),
      Context.__struct__(),
      ToolLimits.__struct__()
    ]

    forbidden_fields =
      MapSet.new([
        :root,
        :environment,
        :env,
        :port,
        :backend,
        :state,
        :token,
        :credential,
        :credentials,
        :secret,
        :executable,
        :module,
        :function
      ])

    Enum.each(structs, fn struct ->
      fields = struct |> Map.from_struct() |> Map.keys() |> MapSet.new()
      assert MapSet.disjoint?(fields, forbidden_fields)
    end)

    sources =
      ["lib/synapse/tool.ex" | Elixir.Path.wildcard("lib/synapse/tool/*.ex")]
      |> Enum.map(&File.read!/1)
      |> Enum.join("\n")

    for forbidden <- [
          ~r/\bFile\./,
          ~r/\bSystem\./,
          ~r/\bPort\./,
          ~r/\bReq\./,
          ~r/\bMuonTrap\b/,
          ~r/String\.to_atom/,
          ~r/String\.to_existing_atom/,
          ~r/binary_to_atom/,
          ~r/list_to_atom/,
          ~r/Module\.concat/,
          ~r/Code\.eval/
        ] do
      refute sources =~ forbidden
    end

    refute sources =~ "Logger."
  end

  test "ordinary Tool and Provider inspection and logging redact synthetic sensitive values" do
    provider_call = %FunctionCall{
      id: "item-#{@synthetic_secret}",
      call_id: "call-#{@synthetic_secret}",
      name: @synthetic_path,
      arguments: %{
        "path" => @synthetic_path,
        "command" => "print #{@synthetic_secret}"
      }
    }

    progress = %ToolCallCompleted{
      item_id: provider_call.id,
      call_id: provider_call.call_id,
      name: provider_call.name,
      arguments: provider_call.arguments
    }

    delta = %ToolCallDelta{
      item_id: provider_call.id,
      call_id: provider_call.call_id,
      delta: @synthetic_secret
    }

    response = %Provider.Response{
      id: "response-#{@synthetic_secret}",
      model: "model",
      output_items: [provider_call]
    }

    sse_event = %Provider.SSEEvent{data: @synthetic_secret, id: @synthetic_path}

    decoder = %Provider.SSEDecoder{
      line_fragments: [@synthetic_secret],
      data_lines: [@synthetic_path]
    }

    stream = %Provider.ResponsesStream{
      operation_id: @synthetic_secret,
      items: %{provider_call.id => %{arguments: provider_call.arguments}}
    }

    {:ok, provider_request} =
      Provider.Request.new(
        model: "model",
        input_items: [
          %{
            "type" => "function_call",
            "id" => provider_call.id,
            "call_id" => provider_call.call_id,
            "name" => provider_call.name,
            "arguments" => provider_call.arguments
          }
        ]
      )

    {:ok, provider_error} =
      Provider.Error.new(
        kind: :protocol,
        message: @synthetic_secret,
        retryable: false,
        output_started: true,
        operation_id: "operation-#{@synthetic_secret}"
      )

    tool_call = %Call{
      call_id: provider_call.call_id,
      name: @synthetic_path,
      arguments: provider_call.arguments
    }

    values = [
      tool_call,
      provider_call,
      progress,
      delta,
      response,
      provider_request,
      provider_error,
      sse_event,
      decoder,
      stream
    ]

    inspected = inspect(values)
    refute inspected =~ @synthetic_secret
    refute inspected =~ @synthetic_path

    log = capture_log(fn -> Logger.warning("phase10 inspected=#{inspect(values)}") end)
    refute log =~ @synthetic_secret
    refute log =~ @synthetic_path
  end

  test "Provider continuation fixture uses canonical calls and valid bounded Tool Result JSON" do
    {fixture, _bindings} =
      Code.eval_file("test/fixtures/responses/tool_continuation_request.fixture")

    fixture["input"]
    |> Enum.filter(&(&1["type"] == "function_call"))
    |> Enum.each(fn item ->
      {:ok, arguments} = Elixir.JSON.decode(item["arguments"])

      provider_call = %FunctionCall{
        id: item["id"],
        call_id: item["call_id"],
        name: item["name"],
        arguments: arguments
      }

      assert {:ok, call} = Call.from_provider(provider_call)
      assert {:ok, module} = Registry.fetch(call.name)
      assert {:ok, _request} = module.prepare(call, ToolLimits.default())
    end)

    fixture["input"]
    |> Enum.filter(&(&1["type"] == "function_call_output"))
    |> Enum.each(fn item ->
      {:ok, decoded} = Elixir.JSON.decode(item["output"])
      status = %{"ok" => :ok, "error" => :error, "ambiguous" => :ambiguous}[decoded["status"]]

      assert {:ok, %Result{}} =
               Result.new(
                 call_id: item["call_id"],
                 status: status,
                 content: item["output"],
                 metadata: %{}
               )
    end)
  end

  test "intended Workspace evidence remains model-visible and explicitly untrusted" do
    evidence = "synthetic-returned-evidence-#{@synthetic_secret}"

    result =
      Synapse.Tool.Presentation.bash(
        "call-evidence",
        {:ok, process_result(0, evidence)},
        ToolLimits.default()
      )

    assert result.status == :ok
    assert decode(result)["output"] == evidence

    guide = File.read!("docs/learning/TOOL-SYSTEM.md")
    assert guide =~ "deliberately model-visible"
    assert guide =~ "may contain secrets"
    refute guide =~ "process output is secret-free"
  end

  test "model-facing Bash cannot replace fixed process policy or grant authority" do
    extras = ["executable", "arguments", "cwd", "environment", "mutation", "capability", "secret"]

    Enum.each(extras, fn field ->
      arguments = %{"command" => "true", "timeout_ms" => nil, field => "forged"}

      assert Synapse.Tool.Bash.prepare(call("bash", arguments), ToolLimits.default()) ==
               {:error, :invalid_arguments}
    end)

    assert Registry.fetch("Elixir.System") == :error
    assert Registry.fetch(@synthetic_path) == :error
  end

  defp integer_spec(minimum, maximum) do
    Spec.new(%{
      name: "integer-boundary",
      description: "Synthetic integer boundary.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "value" => %{
            "type" => "integer",
            "description" => "Synthetic integer.",
            "minimum" => minimum,
            "maximum" => maximum
          }
        },
        "required" => ["value"],
        "additionalProperties" => false
      },
      capability: :fs_read,
      effect: :read_only
    })
  end

  defp call(name, arguments) do
    {:ok, call} = Call.new(call_id: "phase10-call", name: name, arguments: arguments)
    call
  end

  defp read_call(path),
    do: call("read", %{"path" => path, "offset" => nil, "limit" => nil})

  defp context(handle, operation_id, capabilities \\ capabilities(true, true, true)) do
    {:ok, context} =
      Context.new(
        workspace: handle,
        capabilities: capabilities,
        operation_id: operation_id,
        limits: ToolLimits.default()
      )

    context
  end

  defp capabilities(read, write, exec) do
    {:ok, capabilities} =
      CapabilitySet.new(fs_read: read, fs_write: write, process_exec: exec)

    capabilities
  end

  defp backend_handle(backend) do
    %Handle{
      backend: backend,
      state: self(),
      token: make_ref(),
      limits: WorkspaceLimits.default(),
      access: %Access{read: true, write: true, exec: true}
    }
  end

  defp fake_handle(script) do
    {:ok, handle} = Fake.open(script)
    on_exit(fn -> Workspace.close(handle) end)
    handle
  end

  defp revision(byte) do
    {:ok, revision} = Revision.from_mac(:binary.copy(<<byte>>, 32))
    revision
  end

  defp mutation_result(previous, revision) do
    {:ok, result} =
      MutationResult.new(
        operation_id: "phase10-mutation",
        path: "file.txt",
        previous_revision: previous,
        revision: revision,
        bytes_written: 3,
        changed: true,
        diff: "changed",
        diff_truncated: false
      )

    result
  end

  defp process_result(exit_code, output \\ "") do
    {:ok, result} =
      ProcessResult.new(
        operation_id: "phase10-process",
        termination: :exited,
        exit_code: exit_code,
        output: output,
        output_bytes: byte_size(output),
        truncated: false,
        elapsed_ms: 1
      )

    result
  end

  defp workspace_error(kind, reason, outcome) do
    operation = if reason == :stale_revision, do: :write, else: :run

    {:ok, error} =
      Error.new(
        kind: kind,
        reason: reason,
        operation: operation,
        message: "Workspace operation failed",
        outcome: outcome
      )

    error
  end

  defp decode(%Result{} = result) do
    {:ok, content} = Elixir.JSON.decode(result.content)
    content
  end
end
