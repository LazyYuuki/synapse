defmodule Synapse.Workspace.ProcessRunnerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Synapse.Workspace

  alias Synapse.Workspace.{
    Access,
    Error,
    Limits,
    MutationServer,
    OpenRequest,
    OperationContext,
    Platform,
    ProcessEnvironment,
    ProcessEvent,
    ProcessResult,
    ProcessSpec,
    ReadRequest
  }

  @moduletag skip: not Platform.supported?()

  test "runs in the validated cwd with separated argv and closed target stdin" do
    in_temporary_directory(fn root ->
      File.mkdir!(Elixir.Path.join(root, "subdir"))
      handle = open_workspace(root)

      assert {:ok, %ProcessResult{output: output, exit_code: 0}} =
               run(handle, "/bin/pwd", [], cwd: "subdir")

      assert File.stat!(String.trim(output)).inode ==
               File.stat!(Elixir.Path.join(root, "subdir")).inode

      assert {:ok, %ProcessResult{output: "a b|$(literal)|semi;colon", exit_code: 0}} =
               run(
                 handle,
                 "/usr/bin/printf",
                 ["%s|%s|%s", "a b", "$(literal)", "semi;colon"]
               )

      assert {:ok, %ProcessResult{output: "eof"}} =
               run(
                 handle,
                 "/bin/sh",
                 ["-c", "if read value; then printf data; else printf eof; fi"]
               )

      assert {:ok, %ProcessResult{output: "explicit-bash"}} =
               run(handle, "/bin/bash", ["-lc", "printf explicit-bash"], mutation: :unknown)

      assert :ok = Workspace.close(handle)
    end)
  end

  test "emits Started first and preserves bounded arbitrary-binary output order" do
    in_temporary_directory(fn root ->
      {:ok, limits} = Limits.new(max_process_event_bytes: 16)
      handle = open_workspace(root, limits)
      owner = self()

      sink = fn event ->
        send(owner, {:process_event, event})
        :ok
      end

      script = "printf '\\303'; sleep 0.05; printf '\\251'; printf '\\377'; printf '%040d' 0"

      assert {:ok, %ProcessResult{output: output, output_bytes: output_bytes}} =
               run(handle, "/bin/sh", ["-c", script], event_sink: sink, max_output_bytes: 128)

      events = receive_process_events([])
      assert [%ProcessEvent.Started{} | output_events] = events
      assert Enum.all?(output_events, &match?(%ProcessEvent.Output{}, &1))
      assert Enum.map(output_events, & &1.sequence) == Enum.to_list(1..length(output_events))
      assert Enum.all?(output_events, &(byte_size(&1.data) <= 16))
      assert IO.iodata_to_binary(Enum.map(output_events, & &1.data)) == output
      assert output_bytes == byte_size(output)
      assert binary_part(output, 0, 3) == <<195, 169, 255>>
      assert :ok = Workspace.close(handle)
    end)
  end

  test "returns structured empty, non-zero, and signal exits" do
    in_temporary_directory(fn root ->
      handle = open_workspace(root)

      assert {:ok,
              %ProcessResult{
                termination: :exited,
                exit_code: 0,
                output: "",
                truncated: false
              }} = run(handle, "/usr/bin/true", [])

      assert {:ok, %ProcessResult{termination: :exited, exit_code: 7}} =
               run(handle, "/bin/sh", ["-c", "exit 7"])

      assert {:ok, %ProcessResult{termination: :exited, exit_code: 143}} =
               run(handle, "/bin/sh", ["-c", "kill -TERM $$"])

      assert :ok = Workspace.close(handle)
    end)
  end

  test "enforces exact and exceeded output ceilings under one accounting policy" do
    in_temporary_directory(fn root ->
      {:ok, limits} = Limits.new(kill_grace_ms: 50)
      handle = open_workspace(root, limits)

      assert {:ok,
              %ProcessResult{
                termination: :exited,
                output: "1234567890",
                output_bytes: 10,
                truncated: false
              }} =
               run(handle, "/usr/bin/printf", ["1234567890"], max_output_bytes: 10)

      assert {:ok,
              %ProcessResult{
                termination: :output_limit,
                output: "1234567890",
                output_bytes: 11,
                truncated: true,
                exit_code: nil
              }} =
               run(handle, "/usr/bin/printf", ["1234567890X"], max_output_bytes: 10)

      assert {:error, %Error{kind: :ambiguous, reason: :output_limit, outcome: :unknown}} =
               run(
                 handle,
                 "/bin/sh",
                 ["-c", "printf 1234567890X; sleep 10"],
                 mutation: :unknown,
                 max_output_bytes: 10
               )

      assert :ok = Workspace.close(handle)
    end)
  end

  test "enforces the configured process-event count in Real and the facade" do
    in_temporary_directory(fn root ->
      {:ok, limits} = Limits.new(max_process_events: 1, kill_grace_ms: 50)
      handle = open_workspace(root, limits)
      owner = self()

      sink = fn event ->
        send(owner, {:bounded_event, event})
        :ok
      end

      assert {:ok,
              %ProcessResult{
                termination: :output_limit,
                output: "",
                output_bytes: output_bytes,
                truncated: true
              }} = run(handle, "/usr/bin/printf", ["data"], event_sink: sink)

      assert output_bytes > 0
      assert_receive {:bounded_event, %ProcessEvent.Started{}}
      refute_receive {:bounded_event, %ProcessEvent.Output{}}
      assert :ok = Workspace.close(handle)
    end)
  end

  test "applies synchronous sink backpressure and stops on sink failures" do
    in_temporary_directory(fn root ->
      {:ok, limits} = Limits.new(kill_grace_ms: 50)
      handle = open_workspace(root, limits)
      owner = self()

      slow_sink = fn event ->
        send(owner, {:slow_event, event})
        Process.sleep(40)
        :ok
      end

      started_at = System.monotonic_time(:millisecond)

      assert {:ok, %ProcessResult{output: "one-two"}} =
               run(handle, "/bin/sh", ["-c", "printf one; sleep 0.05; printf -- -two"],
                 event_sink: slow_sink
               )

      assert System.monotonic_time(:millisecond) - started_at >= 80

      rejecting_sink = fn
        %ProcessEvent.Started{} -> :ok
        %ProcessEvent.Output{} -> :invalid
      end

      assert {:error, %Error{reason: :event_sink_failed, outcome: :not_applicable}} =
               run(handle, "/bin/sh", ["-c", "printf data; sleep 10"], event_sink: rejecting_sink)

      raising_sink = fn
        %ProcessEvent.Started{} -> :ok
        %ProcessEvent.Output{} -> raise "synthetic sink failure"
      end

      assert {:error, %Error{reason: :event_sink_failed}} =
               run(handle, "/usr/bin/printf", ["data"], event_sink: raising_sink)

      assert {:error, %Error{kind: :ambiguous, reason: :event_sink_failed, outcome: :unknown}} =
               run(handle, "/bin/sh", ["-c", "printf data; sleep 10"],
                 mutation: :unknown,
                 event_sink: rejecting_sink
               )

      assert :ok = Workspace.close(handle)
    end)
  end

  test "constructs an exact secret-free environment with private HOME and TMPDIR" do
    in_temporary_directory(fn root ->
      secret_values = %{
        "TOKAMAK_API_KEY" => "tok_live_FAKE_WORKSPACE_123456789",
        "OPENAI_API_KEY" => "sk-proj-FAKE_WORKSPACE_123456789",
        "AWS_SECRET_ACCESS_KEY" => "FAKEAWSsecretKey1234567890",
        "GITHUB_TOKEN" => "ghp_FAKEWORKSPACE123456789012345678",
        "SSH_AUTH_SOCK" => "/tmp/fake-workspace-agent.sock",
        "SYNTHETIC_PASSWORD" => "Bearer-FAKE-WORKSPACE-PASSWORD"
      }

      secret_names = Map.keys(secret_values)

      originals = Map.new(secret_names, &{&1, System.get_env(&1)})
      Enum.each(secret_values, fn {name, value} -> System.put_env(name, value) end)

      on_exit(fn ->
        Enum.each(originals, fn
          {name, nil} -> System.delete_env(name)
          {name, value} -> System.put_env(name, value)
        end)
      end)

      handle = open_workspace(root)
      System.put_env("ADDED_AFTER_OPEN_SECRET", "also-must-not-leak")
      on_exit(fn -> System.delete_env("ADDED_AFTER_OPEN_SECRET") end)

      assert {:ok, %ProcessResult{output: output}} = run(handle, "/usr/bin/env", [])

      environment =
        output
        |> String.split("\n", trim: true)
        |> Map.new(fn entry ->
          [name, value] = String.split(entry, "=", parts: 2)
          {name, value}
        end)

      assert environment |> Map.keys() |> Enum.sort() ==
               ProcessEnvironment.allowed_names() |> Enum.sort()

      Enum.each(secret_values, fn {_name, value} -> refute output =~ value end)

      assert environment["TERM"] == "dumb"
      assert environment["SHLVL"] == "0"
      assert environment["GIT_CONFIG_GLOBAL"] == "/dev/null"
      assert environment["GIT_CONFIG_NOSYSTEM"] == "1"
      assert permission_mode(environment["HOME"]) == 0o700
      assert permission_mode(environment["TMPDIR"]) == 0o700
      assert environment["HOME"] != environment["TMPDIR"]

      runtime_root = Elixir.Path.dirname(environment["HOME"])
      assert File.dir?(runtime_root)
      assert :ok = Workspace.close(handle)
      refute File.exists?(runtime_root)
    end)
  end

  test "read-only processes coexist with file access while unknown processes exclude it" do
    in_temporary_directory(fn root ->
      File.write!(Elixir.Path.join(root, "file.txt"), "content")
      handle = open_workspace(root)
      owner = self()

      read_only_sink = blocking_started_sink(owner, :read_only_started)

      read_only =
        spawn_link(fn ->
          result =
            run(handle, "/bin/sh", ["-c", "sleep 0.1"],
              operation_id: "read-only-process",
              event_sink: read_only_sink
            )

          send(owner, {:read_only_result, result})
        end)

      assert_receive {:read_only_started, sink_process}, 5_000
      assert Process.alive?(read_only)

      assert {:ok, read_lease} =
               MutationServer.acquire(handle.state, handle.token, "overlap-read", :read)

      assert :ok = MutationServer.release(read_lease)

      assert {:ok, write_lease} =
               MutationServer.acquire(handle.state, handle.token, "overlap-write", :write)

      assert :ok = MutationServer.release(write_lease)

      assert {:error, :workspace_busy} =
               MutationServer.acquire(
                 handle.state,
                 handle.token,
                 "blocked-unknown",
                 :unknown_process
               )

      send(sink_process, :continue_process_event)
      assert_receive {:read_only_result, {:ok, %ProcessResult{exit_code: 0}}}, 5_000

      unknown_sink = blocking_started_sink(owner, :unknown_started)

      spawn_link(fn ->
        result =
          run(handle, "/bin/sh", ["-c", "sleep 0.1"],
            operation_id: "unknown-process",
            mutation: :unknown,
            event_sink: unknown_sink
          )

        send(owner, {:unknown_result, result})
      end)

      assert_receive {:unknown_started, unknown_sink_process}, 5_000

      {:ok, request} = ReadRequest.new(path: "file.txt")

      assert {:error, %Error{reason: :workspace_busy}} =
               Workspace.read(handle, request, context("blocked-read"))

      assert {:error, :workspace_busy} =
               MutationServer.acquire(handle.state, handle.token, "blocked-write", :write)

      send(unknown_sink_process, :continue_process_event)
      assert_receive {:unknown_result, {:ok, %ProcessResult{exit_code: 0}}}, 5_000
      assert :ok = Workspace.close(handle)
    end)
  end

  test "returns sanitized start, cwd, timeout, and activity failures" do
    in_temporary_directory(fn root ->
      {:ok, limits} = Limits.new(kill_grace_ms: 50)
      handle = open_workspace(root, limits)

      assert {:error, %Error{reason: :executable_not_found, outcome: :not_applicable}} =
               run(handle, "/definitely/missing/synapse-executable", [])

      assert {:error, %Error{reason: :not_found, path: "missing-cwd"}} =
               run(handle, "/usr/bin/true", [], cwd: "missing-cwd")

      assert {:ok, %ProcessResult{termination: :timed_out, exit_code: nil}} =
               run(handle, "/bin/sh", ["-c", "sleep 10"], timeout_ms: 50)

      assert {:error, %Error{kind: :ambiguous, reason: :deadline_elapsed, outcome: :unknown}} =
               run(handle, "/bin/sh", ["-c", "sleep 10"],
                 mutation: :unknown,
                 timeout_ms: 50
               )

      assert {:error, %Error{reason: :activity_sink_failed}} =
               run(handle, "/usr/bin/true", [],
                 context_options: [activity_sink: fn _context -> :invalid end]
               )

      assert :ok = Workspace.close(handle)
    end)
  end

  test "retains accepted output before timeout and confirms forced child cleanup" do
    in_temporary_directory(fn root ->
      {:ok, limits} = Limits.new(kill_grace_ms: 50)
      handle = open_workspace(root, limits)
      pid_file = Elixir.Path.join(root, "timeout.pid")
      script = "printf '%s' $$ > \"$1\"; printf prefix; trap '' TERM; while :; do :; done"

      assert {:ok,
              %ProcessResult{
                termination: :timed_out,
                output: "prefix",
                output_bytes: 6,
                truncated: false
              }} =
               run(handle, "/bin/sh", ["-c", script, "sh", pid_file], timeout_ms: 100)

      os_pid = pid_file |> File.read!() |> String.to_integer()
      refute os_process_alive?(os_pid)
      assert :ok = Workspace.close(handle)
    end)
  end

  test "matching cancellation retains accepted output, stops the child, and releases the lease" do
    in_temporary_directory(fn root ->
      {:ok, limits} = Limits.new(kill_grace_ms: 50)
      handle = open_workspace(root, limits)
      owner = self()
      cancel_ref = make_ref()
      pid_file = Elixir.Path.join(root, "cancel.pid")

      sink = fn event ->
        send(owner, {:cancel_event, event})
        :ok
      end

      runner =
        spawn_link(fn ->
          result =
            run(
              handle,
              "/bin/sh",
              [
                "-c",
                "printf '%s' $$ > \"$1\"; printf ready; trap '' TERM; while :; do :; done",
                "sh",
                pid_file
              ],
              event_sink: sink,
              context_options: [cancel_ref: cancel_ref],
              timeout_ms: 5_000
            )

          send(owner, {:cancel_result, result})
        end)

      assert_receive {:cancel_event, %ProcessEvent.Started{}}, 5_000
      assert_receive {:cancel_event, %ProcessEvent.Output{data: "ready"}}, 5_000
      os_pid = await_pid_file(pid_file)
      send(runner, {:cancel, cancel_ref})

      assert_receive {:cancel_result,
                      {:ok,
                       %ProcessResult{
                         termination: :cancelled,
                         output: "ready",
                         exit_code: nil
                       }}},
                     5_000

      refute os_process_alive?(os_pid)

      assert {:ok, lease} =
               MutationServer.acquire(handle.state, handle.token, "after-cancel", :write)

      assert :ok = MutationServer.release(lease)
      refute_receive {:cancel_event, _event}, 50
      assert :ok = Workspace.close(handle)
    end)
  end

  test "ignores nonmatching cancellation and makes interrupted unknown commands ambiguous" do
    in_temporary_directory(fn root ->
      {:ok, limits} = Limits.new(kill_grace_ms: 50)
      handle = open_workspace(root, limits)
      owner = self()
      cancel_ref = make_ref()

      runner =
        spawn_link(fn ->
          result =
            run(handle, "/bin/sh", ["-c", "printf started; sleep 0.15"],
              context_options: [cancel_ref: cancel_ref],
              event_sink: fn event ->
                send(owner, {:matching_event, event})
                :ok
              end
            )

          send(owner, {:matching_result, result})

          receive do
            message -> send(owner, {:preserved_runner_message, message})
          after
            0 -> send(owner, :missing_runner_message)
          end
        end)

      assert_receive {:matching_event, %ProcessEvent.Output{data: "started"}}, 5_000
      nonmatching_ref = make_ref()
      send(runner, {:cancel, nonmatching_ref})

      assert_receive {:matching_result,
                      {:ok, %ProcessResult{termination: :exited, output: "started"}}},
                     5_000

      assert_receive {:preserved_runner_message, {:cancel, ^nonmatching_ref}}, 1_000

      unknown_runner =
        spawn_link(fn ->
          result =
            run(handle, "/bin/sh", ["-c", "printf started; sleep 10"],
              operation_id: "unknown-cancel",
              mutation: :unknown,
              context_options: [cancel_ref: cancel_ref],
              event_sink: fn event ->
                send(owner, {:unknown_cancel_event, event})
                :ok
              end,
              timeout_ms: 5_000
            )

          send(owner, {:unknown_cancel_result, result})
        end)

      assert_receive {:unknown_cancel_event, %ProcessEvent.Output{data: "started"}}, 5_000
      send(unknown_runner, {:cancel, cancel_ref})

      assert_receive {:unknown_cancel_result,
                      {:error, %Error{kind: :ambiguous, reason: :cancelled, outcome: :unknown}}},
                     5_000

      assert :ok = Workspace.close(handle)
    end)
  end

  test "pre-start cancellation and deadline do not start unknown commands" do
    in_temporary_directory(fn root ->
      handle = open_workspace(root)
      cancel_ref = make_ref()
      cancelled_path = Elixir.Path.join(root, "cancelled-before-start")

      send(self(), {:cancel, cancel_ref})

      assert {:error, %Error{reason: :cancelled, outcome: :not_applied}} =
               run(handle, "/usr/bin/touch", [cancelled_path],
                 mutation: :unknown,
                 context_options: [cancel_ref: cancel_ref]
               )

      refute File.exists?(cancelled_path)
      deadline_path = Elixir.Path.join(root, "deadline-before-start")

      assert {:error, %Error{reason: :deadline_elapsed, outcome: :not_applied}} =
               run(handle, "/usr/bin/touch", [deadline_path],
                 mutation: :unknown,
                 context_options: [deadline: System.monotonic_time(:millisecond)]
               )

      refute File.exists?(deadline_path)
      assert :ok = Workspace.close(handle)
    end)
  end

  test "cancellation after target exit still produces one terminal outcome" do
    in_temporary_directory(fn root ->
      {:ok, limits} = Limits.new(kill_grace_ms: 50)
      handle = open_workspace(root, limits)
      owner = self()
      cancel_ref = make_ref()
      pid_file = Elixir.Path.join(root, "exit-cancel-race.pid")

      sink = fn event ->
        send(owner, {:exit_cancel_event, event})

        receive do
          :release_exit_cancel_sink -> :ok
        end
      end

      runner =
        spawn_link(fn ->
          result =
            run(
              handle,
              "/bin/sh",
              ["-c", "printf '%s' $$ > \"$1\"; exit 0", "sh", pid_file],
              event_sink: sink,
              context_options: [cancel_ref: cancel_ref],
              timeout_ms: 2_000
            )

          send(owner, {:exit_cancel_result, result})
        end)

      assert_receive {:exit_cancel_event, %ProcessEvent.Started{}}, 5_000
      os_pid = await_pid_file(pid_file)
      assert eventually(fn -> not os_process_alive?(os_pid) end)
      send(runner, {:cancel, cancel_ref})

      assert_receive {:exit_cancel_result,
                      {:ok, %ProcessResult{termination: :cancelled, output: ""}}},
                     5_000

      refute_receive {:exit_cancel_result, _duplicate}, 50
      refute_receive {:exit_cancel_event, _post_terminal}, 50
      assert :ok = Workspace.close(handle)
    end)
  end

  test "enforces accepted-output inactivity independently from the absolute deadline" do
    in_temporary_directory(fn root ->
      {:ok, limits} = Limits.new(kill_grace_ms: 50)
      handle = open_workspace(root, limits)

      assert {:ok, %ProcessResult{termination: :timed_out, output: "activity"}} =
               run(handle, "/bin/sh", ["-c", "printf activity; sleep 10"],
                 inactivity_ms: 60,
                 timeout_ms: 2_000
               )

      deadline = System.monotonic_time(:millisecond) + 70

      assert {:ok, %ProcessResult{termination: :timed_out}} =
               run(handle, "/bin/sh", ["-c", "while :; do printf x; sleep 0.02; done"],
                 inactivity_ms: 1_000,
                 timeout_ms: 2_000,
                 context_options: [deadline: deadline],
                 max_output_bytes: 1_024
               )

      assert {:error, %Error{kind: :ambiguous, reason: :inactivity_timeout, outcome: :unknown}} =
               run(handle, "/bin/sh", ["-c", "sleep 10"],
                 operation_id: "unknown-inactivity",
                 mutation: :unknown,
                 inactivity_ms: 50,
                 timeout_ms: 2_000
               )

      assert :ok = Workspace.close(handle)
    end)
  end

  test "late sink acceptance cannot defeat inactivity or an absolute deadline" do
    in_temporary_directory(fn root ->
      {:ok, limits} = Limits.new(kill_grace_ms: 50)
      handle = open_workspace(root, limits)

      slow_output_sink = fn
        %ProcessEvent.Started{} ->
          :ok

        %ProcessEvent.Output{} ->
          Process.sleep(80)
          :ok
      end

      assert {:ok, %ProcessResult{termination: :timed_out, output: ""}} =
               run(handle, "/bin/sh", ["-c", "printf late; sleep 10"],
                 event_sink: slow_output_sink,
                 inactivity_ms: 40,
                 timeout_ms: 2_000
               )

      slow_started_sink = fn _event ->
        Process.sleep(80)
        :ok
      end

      assert {:ok, %ProcessResult{termination: :timed_out, output: ""}} =
               run(handle, "/usr/bin/true", [],
                 event_sink: slow_started_sink,
                 inactivity_ms: 1_000,
                 timeout_ms: 2_000,
                 context_options: [deadline: System.monotonic_time(:millisecond) + 40]
               )

      assert :ok = Workspace.close(handle)
    end)
  end

  test "operation coordinator death stops its direct child and releases ownership" do
    in_temporary_directory(fn root ->
      {:ok, limits} = Limits.new(kill_grace_ms: 50)
      handle = open_workspace(root, limits)
      pid_file = Elixir.Path.join(root, "coordinator-death.pid")

      coordinator =
        spawn(fn ->
          run(
            handle,
            "/bin/sh",
            ["-c", "printf '%s' $$ > \"$1\"; trap '' TERM; while :; do :; done", "sh", pid_file],
            mutation: :unknown,
            timeout_ms: 5_000
          )
        end)

      os_pid = await_pid_file(pid_file)
      Process.exit(coordinator, :kill)

      assert eventually(fn -> not os_process_alive?(os_pid) end)

      assert eventually(fn ->
               case MutationServer.acquire(
                      handle.state,
                      handle.token,
                      "after-coordinator-death",
                      :write
                    ) do
                 {:ok, lease} -> MutationServer.release(lease) == :ok
                 _failure -> false
               end
             end)

      assert Process.alive?(handle.state)
      assert :ok = Workspace.close(handle)
    end)
  end

  test "Port guard death during sink backpressure is normalized after direct-child cleanup" do
    in_temporary_directory(fn root ->
      {:ok, limits} = Limits.new(kill_grace_ms: 50)
      handle = open_workspace(root, limits)
      owner = self()
      pid_file = Elixir.Path.join(root, "guard-death.pid")

      sink = fn event ->
        send(owner, {:guard_death_event, event, self()})

        receive do
          :release_guard_death_sink -> :ok
        end
      end

      spawn_link(fn ->
        result =
          run(
            handle,
            "/bin/sh",
            ["-c", "printf '%s' $$ > \"$1\"; while :; do :; done", "sh", pid_file],
            event_sink: sink,
            timeout_ms: 5_000
          )

        send(owner, {:guard_death_result, result})
      end)

      assert_receive {:guard_death_event, %ProcessEvent.Started{}, sink_process}, 5_000
      os_pid = await_pid_file(pid_file)
      coordinator = process_coordinator_for_sink(sink_process)
      {:dictionary, dictionary} = Process.info(coordinator, :dictionary)
      guard = Keyword.fetch!(dictionary, :synapse_process_port_guard)
      Process.exit(guard, :kill)
      send(sink_process, :release_guard_death_sink)

      assert_receive {:guard_death_result,
                      {:error, %Error{reason: :runner_failed, outcome: :not_applicable}}},
                     5_000

      refute os_process_alive?(os_pid)
      assert Process.alive?(handle.state)
      assert :ok = Workspace.close(handle)
    end)
  end

  test "raw Port death is observed by the guard and normalized after child cleanup" do
    in_temporary_directory(fn root ->
      {:ok, limits} = Limits.new(kill_grace_ms: 50)
      handle = open_workspace(root, limits)
      owner = self()
      pid_file = Elixir.Path.join(root, "raw-port-death.pid")
      sink = blocking_started_sink(owner, :raw_port_started)

      spawn_link(fn ->
        result =
          run(
            handle,
            "/bin/sh",
            ["-c", "printf '%s' $$ > \"$1\"; while :; do :; done", "sh", pid_file],
            event_sink: sink,
            timeout_ms: 5_000
          )

        send(owner, {:raw_port_death_result, result})
      end)

      assert_receive {:raw_port_started, sink_process}, 5_000
      os_pid = await_pid_file(pid_file)
      coordinator = process_coordinator_for_sink(sink_process)
      {:dictionary, dictionary} = Process.info(coordinator, :dictionary)
      guard = Keyword.fetch!(dictionary, :synapse_process_port_guard)
      {:links, links} = Process.info(guard, :links)
      port = Enum.find(links, &is_port/1) || flunk("Port guard did not own a Port")
      true = Port.close(port)
      send(sink_process, :continue_process_event)

      assert_receive {:raw_port_death_result,
                      {:error, %Error{reason: :runner_failed, outcome: :not_applicable}}},
                     5_000

      refute os_process_alive?(os_pid)
      assert Process.alive?(handle.state)
      assert :ok = Workspace.close(handle)
    end)
  end

  test "inner runner death is normalized without leaking its direct child or lease" do
    in_temporary_directory(fn root ->
      {:ok, limits} = Limits.new(kill_grace_ms: 50)
      handle = open_workspace(root, limits)
      owner = self()
      pid_file = Elixir.Path.join(root, "inner-runner-death.pid")
      sink = blocking_started_sink(owner, :inner_runner_started)

      spawn_link(fn ->
        result =
          run(
            handle,
            "/bin/sh",
            ["-c", "printf '%s' $$ > \"$1\"; while :; do :; done", "sh", pid_file],
            event_sink: sink,
            timeout_ms: 5_000
          )

        send(owner, {:inner_runner_death_result, result})
      end)

      assert_receive {:inner_runner_started, sink_process}, 5_000
      os_pid = await_pid_file(pid_file)
      coordinator = process_coordinator_for_sink(sink_process)
      {:monitors, monitors} = Process.info(coordinator, :monitors)

      inner_runner =
        Enum.find_value(monitors, fn
          {:process, pid} when pid != sink_process -> pid
          _monitor -> nil
        end) || flunk("coordinator did not monitor its inner runner")

      Process.exit(inner_runner, :kill)

      assert_receive {:inner_runner_death_result,
                      {:error, %Error{reason: :runner_failed, outcome: :not_applicable}}},
                     5_000

      refute os_process_alive?(os_pid)

      assert {:ok, lease} =
               MutationServer.acquire(handle.state, handle.token, "after-inner-runner", :write)

      assert :ok = MutationServer.release(lease)
      assert :ok = Workspace.close(handle)
    end)
  end

  test "abnormal sink-worker death stops the command without later events" do
    in_temporary_directory(fn root ->
      {:ok, limits} = Limits.new(kill_grace_ms: 50)
      handle = open_workspace(root, limits)
      owner = self()
      pid_file = Elixir.Path.join(root, "sink-worker-death.pid")
      sink = blocking_started_sink(owner, :sink_worker_started)

      spawn_link(fn ->
        result =
          run(
            handle,
            "/bin/sh",
            ["-c", "printf '%s' $$ > \"$1\"; while :; do :; done", "sh", pid_file],
            event_sink: sink,
            timeout_ms: 5_000
          )

        send(owner, {:sink_worker_death_result, result})
      end)

      assert_receive {:sink_worker_started, sink_process}, 5_000
      os_pid = await_pid_file(pid_file)
      Process.unlink(sink_process)
      Process.exit(sink_process, :kill)

      assert_receive {:sink_worker_death_result,
                      {:error, %Error{reason: :event_sink_failed, outcome: :not_applicable}}},
                     5_000

      refute os_process_alive?(os_pid)
      refute_receive {:sink_worker_started, _later_sink}
      assert :ok = Workspace.close(handle)
    end)
  end

  test "server-owned process-worker death invalidates the handle after child cleanup" do
    in_temporary_directory(fn root ->
      {:ok, limits} = Limits.new(kill_grace_ms: 50)
      handle = open_workspace(root, limits)
      owner = self()
      pid_file = Elixir.Path.join(root, "process-worker-death.pid")
      sink = blocking_started_sink(owner, :process_worker_started)

      spawn(fn ->
        result =
          run(
            handle,
            "/bin/sh",
            ["-c", "printf '%s' $$ > \"$1\"; while :; do :; done", "sh", pid_file],
            mutation: :unknown,
            event_sink: sink,
            timeout_ms: 5_000
          )

        send(owner, {:process_worker_death_result, result})
      end)

      assert_receive {:process_worker_started, sink_process}, 5_000
      os_pid = await_pid_file(pid_file)
      process_worker = process_coordinator_for_sink(sink_process)
      server_monitor = Process.monitor(handle.state)

      capture_log(fn ->
        Process.exit(process_worker, :kill)

        assert_receive {:process_worker_death_result,
                        {:error, %Error{reason: :runner_failed, outcome: :unknown}}},
                       5_000

        assert_receive {:DOWN, ^server_monitor, :process, _server, _reason}, 5_000
      end)

      assert eventually(fn -> not os_process_alive?(os_pid) end)
      assert :ok = Workspace.close(handle)
    end)
  end

  test "output-limit return and lease release follow TERM/KILL cleanup" do
    in_temporary_directory(fn root ->
      {:ok, limits} = Limits.new(kill_grace_ms: 50)
      handle = open_workspace(root, limits)
      pid_file = Elixir.Path.join(root, "output-limit.pid")

      script =
        "printf '%s' $$ > \"$1\"; trap '' TERM; printf 1234567890X; while :; do :; done"

      assert {:ok, %ProcessResult{termination: :output_limit}} =
               run(handle, "/bin/sh", ["-c", script, "sh", pid_file], max_output_bytes: 10)

      os_pid = pid_file |> File.read!() |> String.to_integer()
      refute os_process_alive?(os_pid)

      File.rm!(pid_file)

      assert {:error, %Error{kind: :ambiguous, reason: :output_limit, outcome: :unknown}} =
               run(handle, "/bin/sh", ["-c", script, "sh", pid_file],
                 mutation: :unknown,
                 max_output_bytes: 10
               )

      unknown_os_pid = pid_file |> File.read!() |> String.to_integer()
      refute os_process_alive?(unknown_os_pid)

      assert {:ok, lease} =
               MutationServer.acquire(handle.state, handle.token, "after-output-limit", :write)

      assert :ok = MutationServer.release(lease)
      assert :ok = Workspace.close(handle)
    end)
  end

  test "server and opening-owner death terminate an active direct child" do
    in_temporary_directory(fn root ->
      {:ok, limits} = Limits.new(kill_grace_ms: 50)
      handle = open_workspace(root, limits)
      pid_file = Elixir.Path.join(root, "server-death.pid")
      home_file = Elixir.Path.join(root, "server-death.home")
      owner = self()

      spawn_link(fn ->
        result =
          run(
            handle,
            "/bin/sh",
            [
              "-c",
              "printf '%s' $$ > \"$1\"; printf '%s' \"$HOME\" > \"$2\"; while :; do :; done",
              "sh",
              pid_file,
              home_file
            ],
            mutation: :unknown,
            timeout_ms: 5_000
          )

        send(owner, {:server_death_run, result})
      end)

      os_pid = await_pid_file(pid_file)
      runtime_root = home_file |> await_file() |> Elixir.Path.dirname()
      server = handle.state
      Process.exit(server, :kill)

      assert_receive {:server_death_run, {:error, %Error{kind: :ambiguous, outcome: :unknown}}},
                     5_000

      assert eventually(fn -> not os_process_alive?(os_pid) end)
      assert eventually(fn -> not File.exists?(runtime_root) end)
      assert :ok = Workspace.close(handle)

      opening_owner = spawn(fn -> Process.sleep(:infinity) end)
      owner_handle = open_workspace(root, limits, opening_owner)
      owner_pid_file = Elixir.Path.join(root, "owner-death.pid")
      owner_home_file = Elixir.Path.join(root, "owner-death.home")

      spawn_link(fn ->
        result =
          run(
            owner_handle,
            "/bin/sh",
            [
              "-c",
              "printf '%s' $$ > \"$1\"; printf '%s' \"$HOME\" > \"$2\"; while :; do :; done",
              "sh",
              owner_pid_file,
              owner_home_file
            ],
            mutation: :unknown,
            timeout_ms: 5_000
          )

        send(owner, {:owner_death_run, result})
      end)

      owner_os_pid = await_pid_file(owner_pid_file)
      owner_runtime_root = owner_home_file |> await_file() |> Elixir.Path.dirname()
      Process.exit(opening_owner, :kill)

      assert_receive {:owner_death_run, {:error, %Error{kind: :ambiguous, outcome: :unknown}}},
                     5_000

      assert eventually(fn -> not os_process_alive?(owner_os_pid) end)
      assert eventually(fn -> not File.exists?(owner_runtime_root) end)
      assert :ok = Workspace.close(owner_handle)
    end)
  end

  test "close waits for an active process and rejects new admission" do
    in_temporary_directory(fn root ->
      handle = open_workspace(root)
      owner = self()
      pid_file = Elixir.Path.join(root, "close.pid")

      spawn_link(fn ->
        result =
          run(
            handle,
            "/bin/sh",
            ["-c", "printf '%s' $$ > \"$1\"; sleep 0.2", "sh", pid_file],
            mutation: :read_only,
            operation_id: "close-process"
          )

        send(owner, {:close_process_result, result})
      end)

      _os_pid = await_pid_file(pid_file)
      spawn_link(fn -> send(owner, {:close_process_close, Workspace.close(handle)}) end)

      assert eventually(fn ->
               not MutationServer.valid_handle?(
                 handle.state,
                 handle.token,
                 handle.limits,
                 handle.access
               )
             end)

      assert_receive {:close_process_result, {:ok, %ProcessResult{exit_code: 0}}}, 5_000
      assert_receive {:close_process_close, :ok}, 10_000
      refute Process.alive?(handle.state)
    end)
  end

  test "executes an absolute executable containing an equals sign without reinterpretation" do
    in_temporary_directory(fn root ->
      executable = Elixir.Path.join(root, "tool=name")
      File.write!(executable, "#!/bin/sh\nprintf 'equals-executable:%s' \"$1\"\n")
      File.chmod!(executable, 0o700)
      handle = open_workspace(root)

      assert {:ok, %ProcessResult{output: "equals-executable:argument", exit_code: 0}} =
               run(handle, executable, ["argument"])

      assert :ok = Workspace.close(handle)
    end)
  end

  defp run(handle, executable, arguments, options \\ []) do
    operation_id = Keyword.get(options, :operation_id, "process-operation")
    event_sink = Keyword.get(options, :event_sink, fn _event -> :ok end)
    context_options = Keyword.get(options, :context_options, [])

    spec_options =
      options
      |> Keyword.take([:cwd, :inactivity_ms, :timeout_ms, :max_output_bytes, :mutation])
      |> Keyword.put_new(:mutation, :read_only)
      |> Keyword.put(:executable, executable)
      |> Keyword.put(:arguments, arguments)

    {:ok, spec} = ProcessSpec.new(spec_options)
    Workspace.run(handle, spec, event_sink, context(operation_id, context_options))
  end

  defp blocking_started_sink(owner, tag) do
    fn
      %ProcessEvent.Started{} ->
        send(owner, {tag, self()})

        receive do
          :continue_process_event -> :ok
        end

      %ProcessEvent.Output{} ->
        :ok
    end
  end

  defp receive_process_events(events) do
    receive do
      {:process_event, event} -> receive_process_events([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp context(operation_id, options \\ []) do
    {:ok, access} = Access.new(read: true, write: true, exec: true)

    options =
      options
      |> Keyword.put(:operation_id, operation_id)
      |> Keyword.put(:access, access)

    {:ok, operation_context} = OperationContext.new(options)
    operation_context
  end

  defp open_workspace(root, limits \\ Limits.default(), owner \\ self()) do
    {:ok, access} = Access.new(read: true, write: true, exec: true)
    {:ok, request} = OpenRequest.new(root: root, owner: owner, limits: limits, access: access)
    {:ok, handle} = Workspace.open(request)
    handle
  end

  defp await_pid_file(path, attempts \\ 200)
  defp await_pid_file(_path, 0), do: flunk("child did not publish its PID")

  defp await_pid_file(path, attempts) do
    case File.read(path) do
      {:ok, value} when value != "" ->
        String.to_integer(value)

      _missing ->
        Process.sleep(10)
        await_pid_file(path, attempts - 1)
    end
  end

  defp await_file(path, attempts \\ 200)
  defp await_file(_path, 0), do: flunk("child did not publish its runtime path")

  defp await_file(path, attempts) do
    case File.read(path) do
      {:ok, value} when value != "" ->
        String.trim(value)

      _missing ->
        Process.sleep(10)
        await_file(path, attempts - 1)
    end
  end

  defp process_coordinator_for_sink(sink_process) do
    {:monitored_by, monitors} = Process.info(sink_process, :monitored_by)

    Enum.find(monitors, fn process ->
      case Process.info(process, :dictionary) do
        {:dictionary, dictionary} ->
          Keyword.has_key?(dictionary, :synapse_process_port_guard)

        nil ->
          false
      end
    end) || flunk("sink worker had no ProcessRunner coordinator")
  end

  defp os_process_alive?(os_pid) do
    case System.cmd("/bin/kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  defp eventually(fun, attempts \\ 200)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp permission_mode(path), do: Bitwise.band(File.stat!(path).mode, 0o7777)

  defp in_temporary_directory(fun) do
    root =
      Elixir.Path.join(
        System.tmp_dir!(),
        "synapse-workspace-process-#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}"
      )

    File.mkdir!(root)

    try do
      fun.(root)
    after
      File.rm_rf!(root)
    end
  end
end
