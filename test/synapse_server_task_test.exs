defmodule Mix.Tasks.Synapse.ServerTest do
  use ExUnit.Case, async: false

  test "the task rejects every argument without reflecting it" do
    secret = "SERVER_TASK_ARGUMENT_SECRET"

    error =
      assert_raise Mix.Error, fn ->
        Mix.Tasks.Synapse.Server.run(["--api-key", secret])
      end

    assert error.message == "synapse.server accepts no arguments"
    refute error.message =~ secret
  end

  test "invalid environment configuration exits without endpoint output, secret, or stacktrace" do
    secret = "SERVER_TASK_INVALID_PORT_SECRET"

    {output, status} =
      System.cmd(mix_executable(), ["synapse.server"],
        cd: project_root(),
        env: [
          {"MIX_ENV", "test"},
          {"SYNAPSE_MODEL", "model-a"},
          {"SYNAPSE_API_PORT", secret}
        ],
        stderr_to_stdout: true
      )

    assert status == 1
    assert output =~ "Invalid Synapse API configuration"
    refute output =~ secret
    refute output =~ "Health:"
    refute output =~ "WebSocket:"
    refute output =~ "(ArgumentError)"
    refute output =~ "lib/"
  end

  test "ordinary application startup ignores malformed server-only environment while disabled" do
    secret = "ORDINARY_STARTUP_INVALID_PORT_SECRET"

    expression =
      "IO.inspect(Enum.map(Supervisor.which_children(Synapse.Supervisor), &elem(&1, 0)), label: \"ordinary_children\"); IO.inspect(Process.whereis(Synapse.API.Supervisor), label: \"api_supervisor\")"

    {output, status} =
      System.cmd(mix_executable(), ["run", "-e", expression],
        cd: project_root(),
        env: [
          {"MIX_ENV", "test"},
          {"SYNAPSE_API_PORT", secret},
          {"SYNAPSE_MODEL", ""}
        ],
        stderr_to_stdout: true
      )

    assert status == 0
    assert output =~ "ordinary_children"
    assert output =~ "Synapse.Runtime.Supervisor"
    assert output =~ "api_supervisor: nil"
    refute output =~ "invalid_api_config"
    refute output =~ secret
  end

  test "fixed-port startup failure is sanitized" do
    secret = "TASK_PORT_CONFLICT_SECRET"

    {:ok, reserved} =
      :gen_tcp.listen(0,
        mode: :binary,
        active: false,
        ip: {127, 0, 0, 1},
        reuseaddr: false
      )

    on_exit(fn -> :gen_tcp.close(reserved) end)
    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(reserved)

    {output, status} =
      System.cmd(mix_executable(), ["synapse.server"],
        cd: project_root(),
        env: [
          {"MIX_ENV", "test"},
          {"SYNAPSE_MODEL", "model-a"},
          {"SYNAPSE_API_PORT", Integer.to_string(port)},
          {"TOKAMAK_API_KEY", secret}
        ],
        stderr_to_stdout: true
      )

    assert status == 1
    assert output =~ "Synapse API failed to start"
    refute output =~ "Health:"
    refute output =~ "WebSocket:"
    refute output =~ secret
    refute output =~ "lib/"

    expression =
      "Application.put_env(:synapse, :api, []); try do Mix.Tasks.Synapse.Server.run([]) rescue Mix.Error -> IO.inspect(Application.get_env(:synapse, :api), label: \"restored_api_config\"); IO.inspect(Enum.any?(Application.started_applications(), fn {name, _, _} -> name == :synapse end), label: \"synapse_started\") end"

    {rollback_output, rollback_status} =
      System.cmd(mix_executable(), ["run", "--no-start", "-e", expression],
        cd: project_root(),
        env: [
          {"MIX_ENV", "test"},
          {"SYNAPSE_MODEL", "model-a"},
          {"SYNAPSE_API_PORT", Integer.to_string(port)}
        ],
        stderr_to_stdout: true
      )

    assert rollback_status == 0
    assert rollback_output =~ "restored_api_config: []"
    assert rollback_output =~ "synapse_started: false"
  end

  test "the foreground task starts only the loopback API and reports ready endpoints" do
    executable = mix_executable()

    expression =
      "Application.put_env(:synapse, :api, port: 0, launch_cwd: \"/stale/configured/path\", default_model: \"model-a\"); " <>
        "Mix.Tasks.Synapse.Server.run([])"

    server =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:cd, project_root()},
        {:args, ["run", "--no-start", "-e", expression]},
        {:env, [{~c"MIX_ENV", ~c"test"}, {~c"SYNAPSE_MAX_OUTPUT_BYTES", ~c"262144"}]}
      ])

    {:os_pid, os_pid} = List.keyfind(Port.info(server), :os_pid, 0)
    on_exit(fn -> kill_process(os_pid) end)

    output = wait_for_output(server, "WebSocket: ws://127.0.0.1:", "")
    [_, port] = Regex.run(~r/WebSocket: ws:\/\/127\.0\.0\.1:(\d+)\/v1\/socket/, output)
    port_number = String.to_integer(port)
    assert output =~ "Health: http://127.0.0.1:#{port_number}/health"
    refute output =~ "0.0.0.0"

    {:ok, connection} =
      :gun.open({127, 0, 0, 1}, port_number, %{protocols: [:http], retry: 0})

    assert_receive {:gun_up, ^connection, :http}, 5_000

    stream =
      :gun.request(
        connection,
        "GET",
        "/health",
        [{"host", "127.0.0.1:#{port_number}"}],
        ""
      )

    assert_receive {:gun_response, ^connection, ^stream, :nofin, 200, _headers}, 5_000

    assert_receive {:gun_data, ^connection, ^stream, :fin, ~s({"status":"ok","protocol":1})},
                   5_000

    websocket =
      :gun.ws_upgrade(
        connection,
        "/v1/socket",
        [{"host", "127.0.0.1:#{port_number}"}],
        %{}
      )

    assert_receive {:gun_upgrade, ^connection, ^websocket, ["websocket"], _headers}, 5_000
    assert_receive {:gun_ws, ^connection, ^websocket, {:text, hello}}, 5_000

    assert JSON.decode!(hello) == %{
             "version" => 1,
             "type" => "server.hello",
             "request_id" => nil,
             "payload" => %{
               "protocol" => 1,
               "replay" => "memory",
               "max_active_runs" => 1,
               "cwd" => project_root(),
               "max_output_bytes" => 262_144
             }
           }

    :gun.close(connection)
    {_output, 0} = System.cmd("kill", ["-TERM", Integer.to_string(os_pid)])
    assert_receive {^server, {:exit_status, status}}, 10_000
    assert status in [0, 143]
  end

  @tag skip: not Synapse.Workspace.Platform.supported?()
  test "application shutdown terminates an active Real Workspace direct process" do
    {output, status} =
      System.cmd(mix_executable(), ["run", "test/fixtures/api_application_shutdown.fixture"],
        cd: project_root(),
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "PHASE8_APPLICATION_SHUTDOWN_OK"
    refute output =~ "shutdown shell remained alive"
    refute output =~ "owned process remained alive"
  end

  defp wait_for_output(server, expected, output) do
    if output =~ expected do
      output
    else
      receive do
        {^server, {:data, data}} ->
          wait_for_output(server, expected, output <> data)

        {^server, {:exit_status, status}} ->
          flunk("server exited early with #{status}: #{output}")
      after
        20_000 -> flunk("server readiness timed out: #{output}")
      end
    end
  end

  defp kill_process(os_pid) do
    _result = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  rescue
    _exception -> :ok
  end

  defp mix_executable, do: System.find_executable("mix")
  defp project_root, do: File.cwd!()
end
