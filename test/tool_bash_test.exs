defmodule Synapse.Tool.BashTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Synapse.Tool.{
    Bash,
    Call,
    CapabilitySet,
    Context,
    Dispatcher,
    Executor,
    Invocation,
    Limits,
    Result
  }

  alias Synapse.Workspace

  alias Synapse.Workspace.{
    Access,
    Error,
    Fake,
    Handle,
    OpenRequest,
    OperationContext,
    Platform,
    ProcessEvent,
    ProcessResult,
    ProcessSpec
  }

  alias Synapse.Workspace.Limits, as: WorkspaceLimits

  defmodule CrashingBashBackend do
    def workspace_backend?, do: true
    def valid_handle?(_handle), do: true
    def close(_handle), do: :ok

    def run(handle, _spec, _sink, _context) do
      send(handle.state, :crashing_bash_invoked)
      raise "synthetic Bash backend failure"
    end
  end

  defmodule MalformedBashBackend do
    def workspace_backend?, do: true
    def valid_handle?(_handle), do: true
    def close(_handle), do: :ok

    def run(handle, _spec, _sink, _context) do
      send(handle.state, :malformed_bash_invoked)
      :malformed
    end
  end

  describe "argument preparation" do
    test "fixes executable, argv, cwd, policy limits, and unknown mutation footprint" do
      limits = Limits.default()

      assert {:ok, spec} = Bash.prepare(bash_call("printf ok", nil), limits)
      assert spec.executable == "/bin/bash"
      assert spec.arguments == ["-lc", "printf ok"]
      assert spec.cwd == "."
      assert spec.timeout_ms == limits.default_bash_timeout_ms
      assert spec.inactivity_ms == limits.default_bash_inactivity_ms
      assert spec.max_output_bytes == limits.default_bash_output_bytes
      assert spec.mutation == :unknown
    end

    test "accepts lowered and trusted-maximum timeout and rejects invalid timeout values" do
      limits = Limits.default()

      assert {:ok, %ProcessSpec{timeout_ms: 1}} = Bash.prepare(bash_call("true", 1), limits)

      assert {:ok, %ProcessSpec{timeout_ms: timeout}} =
               Bash.prepare(bash_call("true", limits.default_bash_timeout_ms), limits)

      assert timeout == limits.default_bash_timeout_ms

      for invalid <- [0, -1, limits.default_bash_timeout_ms + 1, 1.0, "100", false] do
        assert Bash.prepare(bash_call("true", invalid), limits) ==
                 {:error, :invalid_arguments}
      end
    end

    test "trusted lowered defaults are retained in ProcessSpec" do
      {:ok, limits} =
        Limits.new(
          default_bash_output_bytes: 1_024,
          default_bash_timeout_ms: 2_000,
          default_bash_inactivity_ms: 1_000
        )

      assert {:ok, spec} = Bash.prepare(bash_call("true", nil), limits)
      assert spec.max_output_bytes == 1_024
      assert spec.timeout_ms == 2_000
      assert spec.inactivity_ms == 1_000
    end

    test "rejects empty, NUL-containing, invalid UTF-8, wrong-field, and wrong-name calls" do
      limits = Limits.default()
      %Call{} = valid = bash_call("true", nil)

      invalid = [
        %{valid | arguments: %{valid.arguments | "command" => ""}},
        %{valid | arguments: %{valid.arguments | "command" => "bad\0command"}},
        %Call{valid | arguments: %{valid.arguments | "command" => <<255>>}},
        %{valid | arguments: Map.delete(valid.arguments, "timeout_ms")},
        %{valid | arguments: Map.put(valid.arguments, "extra", true)},
        %{valid | arguments: %{valid.arguments | "command" => 1}},
        %{valid | name: "read"}
      ]

      Enum.each(invalid, fn call ->
        assert Bash.prepare(call, limits) == {:error, :invalid_arguments}
      end)
    end

    test "accepts the exact normalized command envelope and rejects one byte beyond" do
      limits = Limits.default()
      maximum = largest_command_size(limits)

      assert {:ok, spec} =
               Bash.prepare(bash_call(String.duplicate("x", maximum), nil), limits)

      assert byte_size(List.last(spec.arguments)) == maximum

      forged = raw_bash_call(String.duplicate("x", maximum + 1), nil)
      assert Bash.prepare(forged, limits) == {:error, :invalid_arguments}
    end
  end

  describe "Fake Workspace adapter" do
    test "dispatches one exact ProcessSpec and accepts correlated events without logging payloads" do
      operation_id = "bash-events"
      spec = process_spec("printf secret-event", Limits.default(), nil)
      context = operation_context(operation_id)
      started = started_event(operation_id)
      output = output_event(operation_id, 1, "secret-event-payload")
      result = process_result(operation_id, 0, "secret-event-payload", elapsed_ms: 4)

      handle =
        fake_handle([
          Fake.expect_run(spec, context, [started, output], {:ok, result})
        ])

      log =
        capture_log(fn ->
          presented =
            Executor.execute(
              bash_call("printf secret-event", nil),
              tool_context(handle, operation_id: operation_id)
            )

          content = decode(presented)
          assert presented.status == :ok
          assert content["output"] == "secret-event-payload"
          assert content["output_bytes"] == 20
        end)

      refute log =~ "secret-event"
      assert :ok = Fake.assert_finished(handle)
    end

    test "maps natural zero and non-zero exits without losing completed evidence" do
      cases = [
        {"bash-zero", "printf ok", 0, "ok\n", :ok},
        {"bash-nonzero", "printf failed; exit 7", 7, "failed\n", :error}
      ]

      entries =
        Enum.map(cases, fn {operation_id, command, exit_code, output, _status} ->
          spec = process_spec(command, Limits.default(), nil)
          events = events(operation_id, output)
          result = process_result(operation_id, exit_code, output, elapsed_ms: 12)
          Fake.expect_run(spec, operation_context(operation_id), events, {:ok, result})
        end)

      handle = fake_handle(entries)

      Enum.each(cases, fn {operation_id, command, exit_code, output, status} ->
        presented =
          Executor.execute(
            bash_call(command, nil),
            tool_context(handle, operation_id: operation_id)
          )

        content = decode(presented)
        assert presented.status == status
        assert content["exit_code"] == exit_code
        assert content["termination"] == "exited"
        assert content["elapsed_ms"] == 12
        assert content["output"] == output
        assert content["output_bytes"] == byte_size(output)

        if status == :error, do: assert(content["outcome"] == "completed")
      end)

      assert :ok = Fake.assert_finished(handle)
    end

    test "repairs arbitrary output and structurally clips large model-visible evidence" do
      cases = [
        {"bash-empty", "empty", ""},
        {"bash-multiline", "multiline", "one\ntwo\r\n"},
        {"bash-binary", "binary", <<255, 0, 1, 10>>}
      ]

      entries =
        Enum.map(cases, fn {operation_id, command, output} ->
          Fake.expect_run(
            process_spec(command, Limits.default(), nil),
            operation_context(operation_id),
            events(operation_id, output),
            {:ok, process_result(operation_id, 0, output)}
          )
        end)

      large = String.duplicate("x", 65_536)
      large_operation = "bash-large"
      large_spec = process_spec("large", Limits.default(), nil)

      large_events =
        [started_event(large_operation)] ++
          (large
           |> chunk_binary(16_384)
           |> Enum.with_index(1)
           |> Enum.map(fn {chunk, sequence} ->
             output_event(large_operation, sequence, chunk)
           end))

      handle =
        fake_handle(
          entries ++
            [
              Fake.expect_run(
                large_spec,
                operation_context(large_operation),
                large_events,
                {:ok, process_result(large_operation, 0, large)}
              )
            ]
        )

      Enum.each(cases, fn {operation_id, command, output} ->
        result =
          Executor.execute(
            bash_call(command, nil),
            tool_context(handle, operation_id: operation_id)
          )

        repaired = decode(result)["output"]
        assert String.valid?(repaired)

        if operation_id == "bash-binary" do
          assert repaired == <<239, 191, 189, 0, 1, 10>>
          assert decode(result)["output_bytes"] == byte_size(output)
        else
          assert repaired == output
        end
      end)

      large_result =
        Executor.execute(
          bash_call("large", nil),
          tool_context(handle, operation_id: large_operation)
        )

      large_content = decode(large_result)
      assert large_content["output_bytes"] == 65_536
      assert large_content["truncated"] == false
      assert large_content["presentation_truncated"] == true
      assert byte_size(large_content["output"]) < 65_536
      assert :ok = Fake.assert_finished(handle)
    end

    test "pre-start cancellation and deadline are known and consume no script entry" do
      operation_id = "bash-never-started"
      cancel_ref = make_ref()
      spec = process_spec("true", Limits.default(), nil)
      context = operation_context(operation_id)
      result = process_result(operation_id, 0, "")

      handle =
        fake_handle([
          Fake.expect_run(spec, context, [started_event(operation_id)], {:ok, result})
        ])

      send(self(), {:cancel, cancel_ref})

      cancelled =
        Executor.execute(
          bash_call("true", nil),
          tool_context(handle, operation_id: "bash-pre-cancel", cancel_ref: cancel_ref)
        )

      assert_workspace_error(cancelled, :error, "cancelled", "not_applied")

      deadline =
        Executor.execute(
          bash_call("true", nil),
          tool_context(
            handle,
            operation_id: "bash-pre-deadline",
            deadline: System.monotonic_time(:millisecond)
          )
        )

      assert_workspace_error(deadline, :error, "deadline_elapsed", "not_applied")
      assert {:ok, 1} = Fake.remaining_operations(handle)
    end

    test "pre-start process failures stay known while post-start forced stops stay ambiguous" do
      prestart = [
        {:unavailable, :process_start_failed},
        {:not_found, :executable_not_found}
      ]

      poststart = [
        :cancelled,
        :deadline_elapsed,
        :inactivity_timeout,
        :output_limit,
        :event_sink_failed,
        :runner_failed
      ]

      prestart_entries =
        Enum.map(prestart, fn {kind, reason} ->
          operation_id = "bash-pre-#{reason}"
          error = workspace_error(kind, reason, :not_applied, operation_id)

          Fake.expect_run(
            process_spec(Atom.to_string(reason), Limits.default(), nil),
            operation_context(operation_id),
            [],
            {:error, error}
          )
        end)

      poststart_entries =
        Enum.map(poststart, fn reason ->
          operation_id = "bash-post-#{reason}"
          output = "accepted-#{reason}"
          error = workspace_error(:ambiguous, reason, :unknown, operation_id)

          Fake.expect_run(
            process_spec(Atom.to_string(reason), Limits.default(), nil),
            operation_context(operation_id),
            events(operation_id, output),
            {:error, error}
          )
        end)

      handle = fake_handle(prestart_entries ++ poststart_entries)

      Enum.each(prestart, fn {_kind, reason} ->
        operation_id = "bash-pre-#{reason}"

        result =
          Executor.execute(
            bash_call(Atom.to_string(reason), nil),
            tool_context(handle, operation_id: operation_id)
          )

        assert_workspace_error(result, :error, Atom.to_string(reason), "not_applied")
      end)

      Enum.each(poststart, fn reason ->
        operation_id = "bash-post-#{reason}"

        result =
          Executor.execute(
            bash_call(Atom.to_string(reason), nil),
            tool_context(handle, operation_id: operation_id)
          )

        assert_workspace_error(result, :ambiguous, Atom.to_string(reason), "unknown")
        assert decode(result)["error"]["message"] =~ "do not retry blindly"
      end)

      assert :ok = Fake.assert_finished(handle)
    end

    test "trusted activity-sink failure after start is ambiguous without exposing output" do
      operation_id = "bash-activity-failure"
      spec = process_spec("activity", Limits.default(), nil)
      started = started_event(operation_id)
      output = output_event(operation_id, 1, "must-not-surface")
      result = process_result(operation_id, 0, "must-not-surface")
      activity_sink = fn _context -> :reject end

      handle =
        fake_handle([
          Fake.expect_run(
            spec,
            operation_context(operation_id, activity_sink: activity_sink),
            [started, output],
            {:ok, result}
          )
        ])

      presented =
        Executor.execute(
          bash_call("activity", nil),
          tool_context(
            handle,
            operation_id: operation_id,
            activity_sink: activity_sink
          )
        )

      assert_workspace_error(presented, :ambiguous, "activity_sink_failed", "unknown")
      refute presented.content =~ "must-not-surface"
      assert :ok = Fake.assert_finished(handle)
    end

    test "invalid arguments, lowered Workspace command ceiling, and denied authorities do no work" do
      handle = fake_handle([])

      invalid = Executor.execute(bash_call("", nil), tool_context(handle))
      assert_tool_error(invalid, "invalid_arguments")

      denied =
        Executor.execute(
          bash_call("true", nil),
          tool_context(
            handle,
            capabilities: capabilities(read: true, write: true, exec: false)
          )
        )

      assert_tool_error(denied, "capability_denied")
      assert :ok = Fake.assert_finished(handle)

      denied_handle =
        fake_handle([], access: %Access{read: true, write: true, exec: false})

      workspace_denied =
        Executor.execute(bash_call("true", nil), tool_context(denied_handle))

      assert_workspace_error(workspace_denied, :error, "access_denied", "not_applied")

      {:ok, workspace_limits} = WorkspaceLimits.new(max_process_argument_bytes: 8)
      lowered_handle = fake_handle([], limits: workspace_limits)

      lowered =
        Executor.execute(
          bash_call("12345678", nil),
          tool_context(lowered_handle)
        )

      assert_tool_error(lowered, "invalid_arguments")
      assert :ok = Fake.assert_finished(lowered_handle)
    end

    test "unknown backend failure is ambiguous and never replayed" do
      for {backend, message} <- [
            {CrashingBashBackend, :crashing_bash_invoked},
            {MalformedBashBackend, :malformed_bash_invoked}
          ] do
        result =
          Executor.execute(
            bash_call("true", nil),
            tool_context(backend_handle(backend), operation_id: "bash-backend-failure")
          )

        assert_workspace_error(result, :ambiguous, "backend_unavailable", "unknown")
        assert_receive ^message
        refute_receive ^message
      end
    end

    test "Dispatcher rejects expansion of trusted timeout, inactivity, and output policy" do
      limits = Limits.default()
      handle = fake_handle([])
      {:ok, dispatch_context} = Context.authorize(tool_context(handle), :process_exec)

      forged = [
        [timeout_ms: limits.default_bash_timeout_ms + 1],
        [inactivity_ms: limits.default_bash_inactivity_ms + 1],
        [max_output_bytes: limits.default_bash_output_bytes + 1]
      ]

      Enum.each(forged, fn override ->
        attrs =
          [
            executable: "/bin/bash",
            arguments: ["-lc", "true"],
            cwd: ".",
            inactivity_ms: limits.default_bash_inactivity_ms,
            timeout_ms: limits.default_bash_timeout_ms,
            max_output_bytes: limits.default_bash_output_bytes,
            mutation: :unknown
          ]
          |> Keyword.merge(override)

        {:ok, spec} = ProcessSpec.new(attrs)
        assert Dispatcher.prepare(Bash, spec, dispatch_context) == {:error, :invalid_request}
      end)

      assert :ok = Fake.assert_finished(handle)
    end

    test "presentation callback failure preserves a retained successful zero exit" do
      call = bash_call("true", nil)
      outcome = {:ok, process_result("bash-present-zero", 0, "")}

      result = Invocation.present(fn -> :invalid end, call, Limits.default(), outcome)

      assert result.status == :ok
      assert decode(result)["presentation"] == "unavailable"
    end

    test "an ambiguous Fake operation is consumed once without script replay" do
      operation_id = "bash-no-replay"
      spec = process_spec("true", Limits.default(), nil)
      context = operation_context(operation_id)
      error = workspace_error(:ambiguous, :runner_failed, :unknown, operation_id)

      entry = Fake.expect_run(spec, context, [started_event(operation_id)], {:error, error})
      handle = fake_handle([entry, entry])

      result =
        Executor.execute(
          bash_call("true", nil),
          tool_context(handle, operation_id: operation_id)
        )

      assert_workspace_error(result, :ambiguous, "runner_failed", "unknown")
      assert {:ok, 1} = Fake.remaining_operations(handle)
    end
  end

  describe "Real Workspace integration" do
    @describetag skip: not Platform.supported?()

    test "runs at workspace cwd with zero, non-zero, output, and elapsed evidence" do
      in_temporary_directory(fn root ->
        handle = real_handle(root)

        try do
          cwd =
            Executor.execute(
              bash_call("/bin/pwd", 5_000),
              tool_context(handle, operation_id: "bash-real-cwd")
            )

          cwd_content = decode(cwd)
          assert cwd.status == :ok
          assert File.stat!(String.trim(cwd_content["output"])).inode == File.stat!(root).inode
          refute inspect(cwd.metadata) =~ root

          zero =
            Executor.execute(
              bash_call("printf 'one\\ntwo\\n'", 5_000),
              tool_context(handle, operation_id: "bash-real-zero")
            )

          zero_content = decode(zero)
          assert zero.status == :ok
          assert zero_content["exit_code"] == 0
          assert zero_content["output"] == "one\ntwo\n"
          assert zero_content["elapsed_ms"] >= 0

          nonzero =
            Executor.execute(
              bash_call("printf failed; exit 7", 5_000),
              tool_context(handle, operation_id: "bash-real-nonzero")
            )

          nonzero_content = decode(nonzero)
          assert nonzero.status == :error
          assert nonzero_content["outcome"] == "completed"
          assert nonzero_content["exit_code"] == 7
          assert nonzero_content["output"] == "failed"
        after
          Workspace.close(handle)
        end
      end)
    end

    test "generic Bash receives none of the synthetic provider, cloud, GitHub, or SSH environment" do
      secret_values = %{
        "TOKAMAK_API_KEY" => "tok_live_FAKE_TOOL_BASH",
        "OPENAI_API_KEY" => "sk-proj-FAKE-TOOL-BASH",
        "AWS_SECRET_ACCESS_KEY" => "FAKE-AWS-TOOL-BASH",
        "GITHUB_TOKEN" => "ghp_FAKE_TOOL_BASH",
        "SSH_AUTH_SOCK" => "/tmp/fake-tool-bash-agent.sock"
      }

      originals = Map.new(secret_values, fn {name, _value} -> {name, System.get_env(name)} end)
      Enum.each(secret_values, fn {name, value} -> System.put_env(name, value) end)

      try do
        in_temporary_directory(fn root ->
          handle = real_handle(root)

          try do
            result =
              Executor.execute(
                bash_call("/usr/bin/env", 5_000),
                tool_context(handle, operation_id: "bash-real-environment")
              )

            output = decode(result)["output"]

            Enum.each(secret_values, fn {name, value} ->
              refute output =~ name
              refute output =~ value
            end)
          after
            Workspace.close(handle)
          end
        end)
      after
        Enum.each(originals, fn
          {name, nil} -> System.delete_env(name)
          {name, value} -> System.put_env(name, value)
        end)
      end
    end

    test "matching cancellation and timeout clean the direct unknown-footprint command" do
      in_temporary_directory(fn root ->
        {:ok, workspace_limits} = WorkspaceLimits.new(kill_grace_ms: 50)
        handle = real_handle(root, workspace_limits)

        try do
          cancel_ref = make_ref()
          owner = self()

          task =
            Task.async(fn ->
              result =
                Executor.execute(
                  bash_call(
                    "printf '%s' $$ > cancel.pid; printf ready; trap '' TERM; while :; do :; done",
                    5_000
                  ),
                  tool_context(
                    handle,
                    operation_id: "bash-real-cancel",
                    cancel_ref: cancel_ref,
                    activity_sink: fn _context ->
                      send(owner, :bash_real_activity)
                      :ok
                    end
                  )
                )

              result
            end)

          assert_receive :bash_real_activity, 5_000
          cancelled_pid = await_pid_file(Elixir.Path.join(root, "cancel.pid"))
          send(task.pid, {:cancel, cancel_ref})

          cancelled = Task.await(task, 5_000)
          assert_workspace_error(cancelled, :ambiguous, "cancelled", "unknown")
          refute os_process_alive?(cancelled_pid)

          timed_out =
            Executor.execute(
              bash_call(
                "printf '%s' $$ > timeout.pid; printf ready; trap '' TERM; while :; do :; done",
                100
              ),
              tool_context(handle, operation_id: "bash-real-timeout")
            )

          timeout_pid = await_pid_file(Elixir.Path.join(root, "timeout.pid"))
          assert_workspace_error(timed_out, :ambiguous, "deadline_elapsed", "unknown")
          refute os_process_alive?(timeout_pid)
        after
          Workspace.close(handle)
        end
      end)
    end

    test "opening-owner death maps the active unknown-footprint run to ambiguous" do
      in_temporary_directory(fn root ->
        {:ok, workspace_limits} = WorkspaceLimits.new(kill_grace_ms: 50)
        opening_owner = spawn(fn -> Process.sleep(:infinity) end)
        handle = real_handle(root, workspace_limits, opening_owner)

        task =
          Task.async(fn ->
            Executor.execute(
              bash_call(
                "printf '%s' $$ > owner.pid; printf ready; trap '' TERM; while :; do :; done",
                5_000
              ),
              tool_context(handle, operation_id: "bash-real-owner-death")
            )
          end)

        os_pid = await_pid_file(Elixir.Path.join(root, "owner.pid"))
        Process.exit(opening_owner, :kill)

        result = Task.await(task, 5_000)
        assert_workspace_error(result, :ambiguous, "runner_failed", "unknown")
        refute os_process_alive?(os_pid)
        Workspace.close(handle)
      end)
    end

    test "Bash source has no direct host process or filesystem API" do
      source = File.read!("lib/synapse/tool/bash.ex")

      refute source =~ ~r/\bFile\./
      refute source =~ ~r/\bSystem\./
      refute source =~ ~r/\bPort\./
      refute source =~ "MuonTrap"
      refute source =~ "Workspace.run"
    end
  end

  defp bash_call(command, timeout_ms) do
    {:ok, call} = Call.new(Map.from_struct(raw_bash_call(command, timeout_ms)))
    call
  end

  defp raw_bash_call(command, timeout_ms) do
    %Call{
      call_id: "call-bash",
      name: "bash",
      arguments: %{"command" => command, "timeout_ms" => timeout_ms}
    }
  end

  defp process_spec(command, limits, timeout_ms) do
    {:ok, spec} = Bash.prepare(bash_call(command, timeout_ms), limits)
    spec
  end

  defp process_result(operation_id, exit_code, output, options \\ []) do
    {:ok, result} =
      ProcessResult.new(
        operation_id: operation_id,
        termination: :exited,
        exit_code: exit_code,
        output: output,
        output_bytes: byte_size(output),
        truncated: false,
        elapsed_ms: Keyword.get(options, :elapsed_ms, 0)
      )

    result
  end

  defp started_event(operation_id) do
    {:ok, event} = ProcessEvent.Started.new(operation_id: operation_id)
    event
  end

  defp output_event(operation_id, sequence, data) do
    {:ok, event} =
      ProcessEvent.Output.new(operation_id: operation_id, sequence: sequence, data: data)

    event
  end

  defp events(operation_id, ""), do: [started_event(operation_id)]

  defp events(operation_id, output),
    do: [started_event(operation_id), output_event(operation_id, 1, output)]

  defp operation_context(operation_id, options \\ []) do
    {:ok, context} =
      OperationContext.new(
        operation_id: operation_id,
        access: %Access{read: false, write: false, exec: true},
        activity_sink: Keyword.get(options, :activity_sink)
      )

    context
  end

  defp tool_context(handle, options \\ []) do
    attrs =
      options
      |> Keyword.put_new(:capabilities, capabilities())
      |> Keyword.put_new(:operation_id, "tool-bash-operation")
      |> Keyword.put_new(:limits, Limits.default())
      |> Keyword.put(:workspace, handle)

    {:ok, context} = Context.new(attrs)
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

  defp workspace_error(kind, reason, outcome, operation_id) do
    path = if reason in [:cancelled, :deadline_elapsed], do: ".", else: nil

    {:ok, error} =
      Error.new(
        kind: kind,
        reason: reason,
        operation: :run,
        message: "Workspace process failed",
        operation_id: operation_id,
        path: path,
        outcome: outcome
      )

    error
  end

  defp fake_handle(script, options \\ []) do
    {:ok, handle} = Fake.open(script, options)
    on_exit(fn -> Workspace.close(handle) end)
    handle
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

  defp real_handle(root, limits \\ WorkspaceLimits.default(), owner \\ self()) do
    {:ok, request} =
      OpenRequest.new(
        root: root,
        owner: owner,
        limits: limits,
        access: %Access{read: true, write: true, exec: true}
      )

    {:ok, handle} = Workspace.open(request)
    handle
  end

  defp largest_command_size(limits),
    do: largest_command_size(1, limits.max_argument_json_bytes, limits)

  defp largest_command_size(low, high, _limits) when low == high, do: low

  defp largest_command_size(low, high, limits) do
    middle = div(low + high + 1, 2)
    call = raw_bash_call(String.duplicate("x", middle), nil)

    case Bash.prepare(call, limits) do
      {:ok, _spec} -> largest_command_size(middle, high, limits)
      {:error, :invalid_arguments} -> largest_command_size(low, middle - 1, limits)
    end
  end

  defp chunk_binary(binary, size), do: for(<<chunk::binary-size(^size) <- binary>>, do: chunk)

  defp decode(%Result{} = result) do
    {:ok, content} = Elixir.JSON.decode(result.content)
    content
  end

  defp assert_tool_error(result, reason) do
    assert result.status == :error
    assert decode(result)["error"]["kind"] == "tool"
    assert decode(result)["error"]["reason"] == reason
  end

  defp assert_workspace_error(result, status, reason, outcome) do
    assert result.status == status
    assert decode(result)["error"]["kind"] == "workspace"
    assert decode(result)["error"]["reason"] == reason
    assert decode(result)["error"]["outcome"] == outcome
  end

  defp await_pid_file(path, attempts \\ 200)
  defp await_pid_file(_path, 0), do: flunk("Bash child did not publish its PID")

  defp await_pid_file(path, attempts) do
    case File.read(path) do
      {:ok, value} when value != "" ->
        String.to_integer(value)

      _missing ->
        Process.sleep(10)
        await_pid_file(path, attempts - 1)
    end
  end

  defp os_process_alive?(os_pid) do
    case System.cmd("/bin/kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  defp in_temporary_directory(fun) do
    root =
      Elixir.Path.join(
        System.tmp_dir!(),
        "synapse-tool-bash-#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}"
      )

    File.mkdir!(root)

    try do
      fun.(root)
    after
      File.rm_rf!(root)
    end
  end
end
