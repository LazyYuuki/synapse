defmodule Synapse.API.LiveTokamakTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Synapse.API.{Config, RunManager, SessionSupervisor}
  alias Synapse.API.TestClient, as: Client

  @moduletag :live_tokamak
  @moduletag timeout: 420_000

  @missing_environment Enum.reject(["TOKAMAK_API_KEY", "SYNAPSE_MODEL"], fn name ->
                         case System.get_env(name) do
                           value when is_binary(value) ->
                             String.valid?(value) and String.trim(value) != ""

                           _missing ->
                             false
                         end
                       end)

  @live_skip (cond do
                not Synapse.Workspace.Platform.supported?() ->
                  "requires a supported Real Workspace platform"

                @missing_environment != [] ->
                  "requires non-empty runtime environment: #{Enum.join(@missing_environment, ", ")}"

                true ->
                  false
              end)

  @moduletag skip: @live_skip
  @text_marker "SYNAPSE_API_LIVE_TEXT_OK"
  @file_content "SYNAPSE_API_LIVE_FILE_OK\n"
  @verify_marker "SYNAPSE_API_LIVE_VERIFY_OK"
  @command_marker "SYNAPSE_API_LIVE_COMMAND_EXECUTED"
  @final_marker "SYNAPSE_API_LIVE_CODING_OK"
  @run_timeout_ms 210_000
  @keepalive_ms 20_000

  test "mix synapse.server completes one live text run through protocol v1" do
    root = temporary_root("text")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    server = start_server_process()
    on_exit(fn -> if Port.info(server.port_handle), do: kill_process(server.os_pid) end)
    {:ok, client} = Client.open(server.port)
    assert_open_secret_safe(client)
    assert_hello(client.hello)

    payload = %{
      "prompt" =>
        "Return only the exact text #{@text_marker}. Do not call any tool and do not add punctuation.",
      "cwd" => root,
      "budget" => text_budget()
    }

    log =
      capture_log(fn ->
        assert {:ok, command, encoded} =
                 Client.send_command(client, "run.start", "live-text-start", payload)

        assert_client_command(command, ~w(budget cwd prompt))
        assert {:ok, accepted} = receive_live_json(client, 10_000)
        run_id = accepted_run_id(accepted, "live-text-start")
        result = collect_terminal(client, run_id, 0, [accepted], [], live_deadline())
        send(self(), {:live_text_result, result, encoded})
      end)

    assert_receive {:live_text_result, result, encoded_command}, 240_000
    terminal = result.terminal
    assert terminal["payload"]["status"] == "completed"
    assert terminal["payload"]["error"] == nil
    assert String.trim(terminal["payload"]["result"]["text"]) == @text_marker
    assert terminal["payload"]["result"]["tool_calls"] == 0
    assert Enum.any?(result.events, &(get_in(&1, ["event", "type"]) == "text.delta"))
    refute Enum.any?(result.events, &(get_in(&1, ["event", "type"]) == "tool.started"))
    barrier = assert_terminal_barrier(client, result.run_id)
    assert :ok = Client.close(client)
    server_output = stop_server_process(server)

    disclosure_check([client.hello, barrier | result.frames], [
      inspect(client.response_headers),
      encoded_command,
      log,
      server.ready_output,
      server_output
    ])

    refute log =~ @text_marker
    refute server_output =~ @text_marker
    File.rm_rf!(root)
    refute File.exists?(root)
  end

  test "production API completes a live coding run with reconnect and cleanup" do
    assert_core_idle()
    root = temporary_root("coding")
    File.mkdir!(root)
    File.write!(Path.join(root, "README.md"), "SYNAPSE_API_LIVE_README\n")
    on_exit(fn -> File.rm_rf!(root) end)

    startup_log =
      capture_log(fn -> send(self(), {:live_api_started, start_api()}) end)

    assert_receive {:live_api_started, api}, 10_000
    {:ok, client_a} = Client.open(api.port)
    assert_open_secret_safe(client_a)
    assert_hello(client_a.hello)

    payload = %{
      "prompt" => coding_prompt(),
      "cwd" => root,
      "budget" => coding_budget()
    }

    log =
      capture_log(fn ->
        assert {:ok, start_command, start_encoded} =
                 Client.send_command(client_a, "run.start", "live-coding-start", payload)

        assert_client_command(start_command, ~w(budget cwd prompt))
        assert {:ok, accepted} = receive_live_json(client_a, 10_000)
        run_id = accepted_run_id(accepted, "live-coding-start")
        session = :sys.get_state(api.manager).runs[run_id].session_pid
        session_monitor = Process.monitor(session)
        first = receive_sequence(client_a, run_id, 1, live_deadline())
        assert Process.alive?(session)
        assert :sys.get_state(api.manager).active_run_id == run_id
        assert is_nil(:sys.get_state(api.manager).runs[run_id].terminal)
        assert :ok = Client.close(client_a)
        {:ok, client_b} = Client.open(api.port)
        assert_open_secret_safe(client_b)
        assert_hello(client_b.hello)

        assert {:ok, subscribe_command, subscribe_encoded} =
                 Client.send_command(client_b, "run.subscribe", "live-coding-resume", %{
                   "run_id" => run_id,
                   "after_seq" => 1
                 })

        assert_client_command(subscribe_command, ~w(after_seq run_id))
        assert {:ok, snapshot} = receive_live_json(client_b, 10_000)
        assert snapshot["type"] == "run.snapshot"
        assert snapshot["request_id"] == "live-coding-resume"
        assert snapshot["payload"]["mode"] == "replay"
        refute snapshot["payload"]["reset"]
        assert snapshot["payload"]["last_seq"] >= 1

        result =
          collect_terminal(
            client_b,
            run_id,
            1,
            [accepted, first, snapshot],
            [first["payload"]],
            live_deadline()
          )

        assert_receive {:DOWN, ^session_monitor, :process, ^session, :normal}, 10_000

        assert {:ok, completed_command, completed_encoded} =
                 Client.send_command(client_b, "run.subscribe", "live-coding-completed", %{
                   "run_id" => run_id
                 })

        assert_client_command(completed_command, ~w(run_id))
        assert {:ok, completed_snapshot} = receive_live_json(client_b, 10_000)
        assert completed_snapshot["payload"]["mode"] == "snapshot"
        assert completed_snapshot["payload"]["terminal"] == result.terminal["payload"]
        barrier = assert_terminal_barrier(client_b, run_id)
        assert :ok = Client.close(client_b)

        send(self(), {
          :live_coding_result,
          result,
          completed_snapshot,
          barrier,
          [client_a.hello, client_b.hello],
          [inspect(client_a.response_headers), inspect(client_b.response_headers)],
          [start_encoded, subscribe_encoded, completed_encoded]
        })
      end)

    assert_receive {:live_coding_result, result, completed_snapshot, barrier, hellos, headers,
                    encoded_commands},
                   240_000

    terminal = result.terminal
    assert terminal["payload"]["status"] == "completed"
    assert terminal["payload"]["error"] == nil
    assert terminal["payload"]["result"]["text"] =~ @final_marker
    assert terminal["payload"]["result"]["tool_calls"] >= 1
    assert result.cursor == terminal["payload"]["seq"]
    assert Enum.any?(result.events, &(get_in(&1, ["event", "type"]) == "tool.started"))
    assert Enum.any?(result.events, &bash_completed?/1)

    started_tools =
      result.events
      |> Enum.filter(&(get_in(&1, ["event", "type"]) == "tool.started"))
      |> Enum.map(&get_in(&1, ["event", "name"]))

    assert Enum.all?(["read", "write", "bash"], &(&1 in started_tools))
    assert File.read!(Path.join(root, "hello.txt")) == @file_content
    assert File.read!(Path.join(root, "verification-command.txt")) == @command_marker

    assert {@verify_marker, 0} =
             System.cmd(
               "/bin/bash",
               ["-lc", verification_command()],
               cd: root,
               stderr_to_stdout: true
             )

    frames = hellos ++ [completed_snapshot, barrier | result.frames]
    assert_secret_surfaces_safe([log], "coding log")
    refute log =~ @final_marker
    assert_api_idle(api)
    shutdown_log = capture_log(fn -> stop_api(api) end)
    disclosure_check(frames, headers ++ [startup_log, log, shutdown_log | encoded_commands])
    File.rm_rf!(root)
    refute File.exists?(root)
  end

  defp start_api do
    model = System.fetch_env!("SYNAPSE_MODEL")

    {:ok, config} =
      Config.new(
        enabled: true,
        launch_cwd: File.cwd!(),
        default_model: model,
        port: 0
      )

    reference = make_ref()
    manager_name = {:global, {:api_live_manager, reference}}
    sessions_name = {:global, {:api_live_sessions, reference}}

    {:ok, supervisor} =
      Synapse.API.Supervisor.start_link(
        name: nil,
        config: config,
        manager: manager_name,
        session_supervisor: sessions_name
      )

    on_exit(fn ->
      stop_if_alive(supervisor)
      force_core_cleanup()
    end)

    manager = child_pid(supervisor, RunManager)
    sessions = child_pid(supervisor, SessionSupervisor)
    listener = child_pid(supervisor, Bandit)
    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(listener)

    %{
      supervisor: supervisor,
      manager: manager,
      sessions: sessions,
      listener: listener,
      port: port,
      manager_name: manager_name,
      sessions_name: sessions_name
    }
  end

  defp start_server_process(attempts \\ 3)

  defp start_server_process(0), do: flunk("mix synapse.server could not bind a local port")

  defp start_server_process(attempts) do
    assigned_port = available_port()

    port =
      Port.open({:spawn_executable, System.find_executable("mix")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:cd, File.cwd!()},
        {:args, ["synapse.server"]},
        {:env,
         [
           {~c"MIX_ENV", ~c"test"},
           {~c"SYNAPSE_API_PORT", String.to_charlist(Integer.to_string(assigned_port))}
         ]}
      ])

    {:os_pid, os_pid} = List.keyfind(Port.info(port), :os_pid, 0)

    case wait_for_server(port, "WebSocket: ws://127.0.0.1:#{assigned_port}/v1/socket", "") do
      {:ok, ready_output} ->
        %{
          port_handle: port,
          os_pid: os_pid,
          port: assigned_port,
          ready_output: ready_output
        }

      {:error, _output} ->
        if Port.info(port), do: kill_process(os_pid)
        start_server_process(attempts - 1)
    end
  end

  defp stop_server_process(server) do
    _result =
      System.cmd("kill", ["-TERM", Integer.to_string(server.os_pid)], stderr_to_stdout: true)

    await_server_exit(server.port_handle, "")
  end

  defp wait_for_server(port, expected, output) do
    if output =~ expected do
      {:ok, output}
    else
      receive do
        {^port, {:data, data}} -> wait_for_server(port, expected, output <> data)
        {^port, {:exit_status, _status}} -> {:error, output}
      after
        30_000 -> {:error, output}
      end
    end
  end

  defp await_server_exit(port, output) do
    receive do
      {^port, {:data, data}} -> await_server_exit(port, output <> data)
      {^port, {:exit_status, status}} when status in [0, 143] -> output
      {^port, {:exit_status, _status}} -> flunk("live server exited unsuccessfully")
    after
      20_000 -> flunk("live server shutdown timed out")
    end
  end

  defp collect_terminal(client, run_id, cursor, frames, events, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      flunk("live API run timed out")
    end

    case receive_live_json(client, @keepalive_ms) do
      {:ok, %{"type" => "pong"} = frame} ->
        collect_terminal(client, run_id, cursor, [frame | frames], events, deadline)

      {:ok, %{"type" => "run.event", "payload" => payload} = frame} ->
        assert payload["run_id"] == run_id
        assert payload["seq"] == cursor + 1

        collect_terminal(
          client,
          run_id,
          cursor + 1,
          [frame | frames],
          [payload | events],
          deadline
        )

      {:ok, %{"type" => "run.terminal", "payload" => payload} = terminal} ->
        assert payload["run_id"] == run_id
        assert payload["seq"] == cursor + 1

        %{
          run_id: run_id,
          cursor: cursor + 1,
          terminal: terminal,
          frames: Enum.reverse([terminal | frames]),
          events: Enum.reverse(events)
        }

      {:ok, %{"type" => "server.error"}} ->
        flunk("live API returned server.error")

      {:ok, _unexpected} ->
        flunk("live API returned an unexpected frame")

      {:error, :timeout} ->
        request_id = "live-keepalive-#{System.unique_integer([:positive])}"
        assert {:ok, _command, _encoded} = Client.send_command(client, "ping", request_id, %{})
        collect_terminal(client, run_id, cursor, frames, events, deadline)

      {:error, _reason} ->
        flunk("live API connection failed")
    end
  end

  defp receive_sequence(client, run_id, expected, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      flunk("live API emitted no sequenced frame")
    end

    case receive_live_json(client, @keepalive_ms) do
      {:ok, %{"type" => type, "payload" => payload} = frame}
      when type in ["run.event", "run.terminal"] ->
        assert payload["run_id"] == run_id
        assert payload["seq"] == expected
        frame

      {:ok, %{"type" => "pong"}} ->
        receive_sequence(client, run_id, expected, deadline)

      {:error, :timeout} ->
        assert {:ok, _command, _encoded} =
                 Client.send_command(client, "ping", "live-first-keepalive", %{})

        receive_sequence(client, run_id, expected, deadline)

      _failure ->
        flunk("live API failed before its first sequence")
    end
  end

  defp assert_terminal_barrier(client, run_id) do
    request_id = "live-terminal-barrier-#{String.slice(run_id, -4, 4)}"
    assert {:ok, _command, _encoded} = Client.send_command(client, "ping", request_id, %{})
    assert {:ok, pong} = receive_live_json(client, 10_000)

    assert pong == %{
             "version" => 1,
             "type" => "pong",
             "request_id" => request_id,
             "payload" => %{}
           }

    pong
  end

  defp receive_live_json(client, timeout) do
    case Client.receive_json(client, timeout) do
      {:ok, frame} = result ->
        assert_frame_secret_safe(frame)
        result

      error ->
        error
    end
  end

  defp assert_open_secret_safe(client) do
    assert_secret_surfaces_safe(
      [JSON.encode!(client.hello), inspect(client.response_headers)],
      "WebSocket handshake"
    )
  end

  defp assert_frame_secret_safe(frame) do
    assert_secret_surfaces_safe([JSON.encode!(frame)], "server frame")
  end

  defp assert_secret_surfaces_safe(surfaces, classification) do
    key = System.fetch_env!("TOKAMAK_API_KEY")
    assert_secret_absent(surfaces, key, classification)
    assert_secret_absent(surfaces, String.trim(key), classification)
  end

  defp assert_hello(hello) do
    assert hello == %{
             "version" => 1,
             "type" => "server.hello",
             "request_id" => nil,
             "payload" => %{
               "protocol" => 1,
               "replay" => "memory",
               "max_active_runs" => 1,
               "cwd" => File.cwd!(),
               "max_output_bytes" => 524_288
             }
           }
  end

  defp accepted_run_id(frame, request_id) do
    assert frame["type"] == "run.accepted"
    assert frame["request_id"] == request_id
    assert frame["payload"]["status"] == "starting"
    run_id = frame["payload"]["run_id"]
    assert Regex.match?(~r/^run_[A-Za-z0-9_-]{22}$/, run_id)
    run_id
  end

  defp assert_client_command(command, payload_keys) do
    assert Map.keys(command) |> Enum.sort() == ~w(payload request_id type version)
    assert Map.keys(command["payload"]) |> Enum.sort() == Enum.sort(payload_keys)

    encoded = JSON.encode!(command)

    Enum.each(
      ~w(api_key authorization bearer capabilities runtime_options workspace_opener callback handle),
      fn forbidden -> refute String.contains?(String.downcase(encoded), forbidden) end
    )
  end

  defp disclosure_check(frames, other_surfaces) do
    key = System.fetch_env!("TOKAMAK_API_KEY")
    trimmed_key = String.trim(key)
    frame_surfaces = Enum.map(frames, &JSON.encode!/1)
    surfaces = frame_surfaces ++ other_surfaces
    assert_secret_absent(surfaces, key, "raw API key")
    assert_secret_absent(surfaces, trimmed_key, "trimmed API key")

    joined = surfaces |> Enum.join("\n") |> String.downcase()

    Enum.each(
      [
        "authorization",
        "bearer ",
        "final_response",
        "%synapse.provider.response",
        "#synapse.provider.response<",
        "#synapse.runtime.run<",
        "#synapse.workspace.handle<",
        "#pid<",
        "#reference<",
        "#function<",
        "run_ref",
        "cancel_ref",
        "runtime_run",
        "workspace_handle",
        "&synapse.workspace.open/1",
        "&synapse.runtime.",
        "workspace_opener",
        "retry_delay"
      ],
      fn forbidden ->
        if String.contains?(joined, forbidden), do: flunk("live authority crossed API boundary")
      end
    )
  end

  defp assert_secret_absent(_surfaces, "", _classification), do: :ok

  defp assert_secret_absent(surfaces, secret, classification) do
    if Enum.any?(surfaces, &(:binary.match(&1, secret) != :nomatch)) do
      flunk("#{classification} crossed API boundary")
    end
  end

  defp text_budget do
    %{
      "max_turns" => 2,
      "max_tool_calls" => 1,
      "max_wall_time_ms" => 180_000,
      "provider_inactivity_ms" => 90_000,
      "tool_inactivity_ms" => 120_000,
      "max_output_bytes" => 8_000,
      "max_provider_retries" => 1
    }
  end

  defp coding_budget do
    %{
      "max_turns" => 8,
      "max_tool_calls" => 12,
      "max_wall_time_ms" => 180_000,
      "provider_inactivity_ms" => 90_000,
      "tool_inactivity_ms" => 120_000,
      "max_output_bytes" => 16_000,
      "max_provider_retries" => 1
    }
  end

  defp coding_prompt do
    """
    Complete this exact acceptance task using the provided tools, then return #{@final_marker}.
    1. Read README.md and confirm it contains SYNAPSE_API_LIVE_README.
    2. Create hello.txt with exactly SYNAPSE_API_LIVE_FILE_OK followed by one newline. Use the write tool with expected_revision missing.
    3. Run Bash with this exact command: #{verification_command()}
    Do not access any other path. Do not skip the Bash verification.
    """
  end

  defp verification_command do
    "test \"$(cat README.md)\" = SYNAPSE_API_LIVE_README && " <>
      "test \"$(cat hello.txt)\" = SYNAPSE_API_LIVE_FILE_OK && " <>
      "printf '#{@command_marker}' > verification-command.txt && printf #{@verify_marker}"
  end

  defp bash_completed?(%{
         "event" => %{"type" => "tool.completed", "name" => "bash", "status" => "ok"}
       }),
       do: true

  defp bash_completed?(_event), do: false

  defp live_deadline, do: System.monotonic_time(:millisecond) + @run_timeout_ms

  defp assert_api_idle(api) do
    assert_core_idle()
    assert DynamicSupervisor.count_children(api.sessions).active == 0
    state = :sys.get_state(api.manager)
    assert state.active_run_id == nil

    assert Enum.all?(state.runs, fn {_run_id, record} ->
             is_nil(record.session_pid) and is_nil(record.runtime_run) and
               is_nil(record.pending_terminal) and not is_nil(record.terminal)
           end)
  end

  defp assert_core_idle do
    assert DynamicSupervisor.count_children(Synapse.Runtime.Supervisor).active == 0
    assert Task.Supervisor.children(Synapse.TaskSupervisor) == []
    assert DynamicSupervisor.count_children(Synapse.Workspace.Supervisor).active == 0
  end

  defp stop_api(api) do
    pids = [api.listener, api.sessions, api.manager, api.supervisor]
    monitors = Enum.map(pids, &{&1, Process.monitor(&1)})
    Supervisor.stop(api.supervisor)

    Enum.each(monitors, fn {pid, monitor} ->
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 7_000
    end)

    assert :global.whereis_name(elem(api.manager_name, 1)) == :undefined
    assert :global.whereis_name(elem(api.sessions_name, 1)) == :undefined
  end

  defp child_pid(supervisor, id) do
    Supervisor.which_children(supervisor)
    |> Enum.find_value(fn
      {^id, pid, _type, _modules} -> pid
      _child -> nil
    end)
  end

  defp stop_if_alive(pid) do
    if is_pid(pid) and Process.alive?(pid), do: Supervisor.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  defp force_core_cleanup do
    runtime =
      DynamicSupervisor.which_children(Synapse.Runtime.Supervisor)
      |> Enum.map(&elem(&1, 1))

    tasks = Task.Supervisor.children(Synapse.TaskSupervisor)

    workspace =
      DynamicSupervisor.which_children(Synapse.Workspace.Supervisor)
      |> Enum.map(&elem(&1, 1))

    Enum.each(runtime ++ tasks ++ workspace, fn pid ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)
  end

  defp available_port do
    {:ok, socket} =
      :gen_tcp.listen(0,
        mode: :binary,
        active: false,
        ip: {127, 0, 0, 1},
        reuseaddr: false
      )

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp kill_process(os_pid) do
    _result = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  rescue
    _exception -> :ok
  end

  defp temporary_root(label) do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    Path.join(System.tmp_dir!(), "synapse-api-live-#{label}-#{suffix}")
  end
end
