defmodule Synapse.API.Phase0Test do
  use ExUnit.Case, async: true

  defmodule Worker do
    use GenServer

    def start_link({role, test_pid}), do: GenServer.start_link(__MODULE__, {role, test_pid})

    @impl true
    def init({role, test_pid}) do
      send(test_pid, {:api_phase0_started, role, self()})
      {:ok, role}
    end
  end

  defmodule SocketFixture do
    @behaviour WebSock

    @impl true
    def init(test_pid), do: {:push, {:text, "hello"}, test_pid}

    @impl true
    def handle_in({"close", opcode: :text}, test_pid),
      do: {:stop, :normal, 1000, test_pid}

    def handle_in({"multiple", opcode: :text}, test_pid),
      do: {:push, [{:text, "one"}, {:text, "two"}], test_pid}

    def handle_in({"info", opcode: :text}, test_pid) do
      send(self(), {:api_phase0_push_from_info, test_pid})
      {:ok, test_pid}
    end

    def handle_in({data, opcode: opcode}, test_pid) when opcode in [:text, :binary],
      do: {:push, {opcode, data}, test_pid}

    @impl true
    def handle_info({:api_phase0_push_from_info, test_pid}, test_pid),
      do: {:push, {:text, "from-info"}, test_pid}
  end

  defmodule PlugFixture do
    @behaviour Plug

    @impl true
    def init(test_pid), do: test_pid

    @impl true
    def call(conn, test_pid) do
      send(test_pid, {:api_phase0_origins, Plug.Conn.get_req_header(conn, "origin")})

      WebSockAdapter.upgrade(conn, SocketFixture, test_pid,
        compress: false,
        timeout: 60_000,
        max_frame_size: 64
      )
    end
  end

  test "the intended API rest_for_one order has the required restart boundaries" do
    children = [
      Supervisor.child_spec({Worker, {:manager, self()}}, id: :manager),
      Supervisor.child_spec(
        {DynamicSupervisor, strategy: :one_for_one, max_children: 1},
        id: :sessions
      ),
      Supervisor.child_spec({Worker, {:listener, self()}}, id: :listener)
    ]

    {:ok, supervisor} = Supervisor.start_link(children, strategy: :rest_for_one)
    on_exit(fn -> stop_if_alive(supervisor) end)

    assert_receive {:api_phase0_started, :manager, manager}, 1_000
    assert_receive {:api_phase0_started, :listener, listener}, 1_000
    sessions = child_pid(supervisor, :sessions)

    Process.exit(manager, :kill)
    assert_receive {:api_phase0_started, :manager, replacement_manager}, 1_000
    assert_receive {:api_phase0_started, :listener, replacement_listener}, 1_000

    replacement_sessions = child_pid(supervisor, :sessions)
    assert replacement_manager != manager
    assert replacement_sessions != sessions
    assert replacement_listener != listener

    Process.exit(replacement_sessions, :kill)
    assert_receive {:api_phase0_started, :listener, second_listener}, 1_000

    second_sessions = child_pid(supervisor, :sessions)
    assert child_pid(supervisor, :manager) == replacement_manager
    assert second_sessions != replacement_sessions
    assert second_listener != replacement_listener

    Process.exit(second_listener, :kill)
    assert_receive {:api_phase0_started, :listener, third_listener}, 1_000
    assert child_pid(supervisor, :manager) == replacement_manager
    assert child_pid(supervisor, :sessions) == second_sessions
    assert third_listener != second_listener
  end

  test "Elixir JSON behavior used by protocol v1 remains explicit" do
    assert JSON.decode!(~s({"key":"value"})) == %{"key" => "value"}
    duplicate = JSON.decode!(~s({"key":1,"key":2}))
    assert map_size(duplicate) == 1
    assert duplicate["key"] in [1, 2]
    assert {:error, {:invalid_byte, 1, 255}} = JSON.decode(<<34, 255, 34>>)

    large_integer = JSON.decode!("9223372036854775808")
    assert large_integer == 9_223_372_036_854_775_808

    nested = String.duplicate("[", 64) <> "0" <> String.duplicate("]", 64)
    assert {:ok, _decoded} = JSON.decode(nested)

    encoded =
      <<0, 8, 9, 10, 12, 13, 34, 92, 127, 195, 169>>
      |> JSON.encode_to_iodata!()
      |> IO.iodata_to_binary()

    assert byte_size(encoded) > 11
    assert encoded =~ ~S(\u0000)
    assert encoded =~ ~S(\")
    assert encoded =~ ~S(\\)
    assert encoded =~ "é"
  end

  test "selected server and client interfaces are directly available" do
    Enum.each(
      [Bandit, ThousandIsland, WebSock, WebSockAdapter, :gun],
      &Code.ensure_loaded!/1
    )

    assert function_exported?(Bandit, :child_spec, 1)
    assert function_exported?(ThousandIsland, :listener_info, 1)
    assert function_exported?(WebSockAdapter, :upgrade, 4)
    assert {:init, 1} in WebSock.behaviour_info(:callbacks)
    assert {:handle_in, 2} in WebSock.behaviour_info(:callbacks)
    assert {:handle_info, 2} in WebSock.behaviour_info(:callbacks)
    assert function_exported?(:gun, :open, 3)
    assert function_exported?(:gun, :ws_upgrade, 4)
    assert function_exported?(:gun, :ws_send, 3)
  end

  test "the selected stack supports port zero, headers, frames, and close codes" do
    {:ok, bandit} =
      Bandit.start_link(
        plug: {PlugFixture, self()},
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false,
        http_2_options: [enabled: false],
        websocket_options: [
          max_frame_size: 64,
          max_fragmented_message_size: 64,
          validate_text_frames: true,
          compress: false,
          log_protocol_errors: false
        ],
        thousand_island_options: [
          num_acceptors: 1,
          num_connections: 2,
          read_timeout: 60_000,
          shutdown_timeout: 1_000
        ]
      )

    on_exit(fn -> stop_if_alive(bandit) end)
    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)
    assert port > 0

    {:ok, connection} = :gun.open({127, 0, 0, 1}, port, %{protocols: [:http]})
    on_exit(fn -> :gun.close(connection) end)
    assert_receive {:gun_up, ^connection, :http}, 5_000

    origins = ["http://localhost:3000", "http://127.0.0.1:3000"]
    headers = Enum.map(origins, &{"origin", &1})
    stream = :gun.ws_upgrade(connection, "/socket", headers, %{compress: true})

    assert_receive {:api_phase0_origins, ^origins}, 5_000

    assert_receive {:gun_upgrade, ^connection, ^stream, ["websocket"], response_headers}, 5_000

    refute Enum.any?(response_headers, fn {name, _value} ->
             name == "sec-websocket-extensions"
           end)

    assert_receive {:gun_ws, ^connection, ^stream, {:text, "hello"}}, 1_000

    assert :ok = :gun.ws_send(connection, stream, {:text, "text"})
    assert_receive {:gun_ws, ^connection, ^stream, {:text, "text"}}, 1_000

    assert :ok = :gun.ws_send(connection, stream, {:binary, <<0, 1, 2>>})
    assert_receive {:gun_ws, ^connection, ^stream, {:binary, <<0, 1, 2>>}}, 1_000

    assert :ok = :gun.ws_send(connection, stream, {:text, "multiple"})
    assert_receive {:gun_ws, ^connection, ^stream, {:text, "one"}}, 1_000
    assert_receive {:gun_ws, ^connection, ^stream, {:text, "two"}}, 1_000

    assert :ok = :gun.ws_send(connection, stream, {:text, "info"})
    assert_receive {:gun_ws, ^connection, ^stream, {:text, "from-info"}}, 1_000

    assert :ok = :gun.ws_send(connection, stream, {:text, "close"})
    assert_receive {:gun_ws, ^connection, ^stream, {:close, 1000, _reason}}, 1_000
    connection_monitor = Process.monitor(connection)
    :gun.close(connection)
    assert_receive {:DOWN, ^connection_monitor, :process, ^connection, _reason}, 5_000

    {:ok, oversized_connection} = :gun.open({127, 0, 0, 1}, port, %{protocols: [:http]})
    on_exit(fn -> :gun.close(oversized_connection) end)
    assert_receive {:gun_up, ^oversized_connection, :http}, 1_000

    oversized_stream =
      :gun.ws_upgrade(oversized_connection, "/socket", [{"origin", hd(origins)}], %{})

    assert_receive {:api_phase0_origins, ["http://localhost:3000"]}, 5_000

    assert_receive {:gun_upgrade, ^oversized_connection, ^oversized_stream, ["websocket"],
                    _headers},
                   5_000

    assert_receive {:gun_ws, ^oversized_connection, ^oversized_stream, {:text, "hello"}}, 5_000

    assert :ok =
             :gun.ws_send(
               oversized_connection,
               oversized_stream,
               {:text, String.duplicate("x", 64)}
             )

    assert_receive {:gun_ws, ^oversized_connection, ^oversized_stream, {:close, 1009, _reason}},
                   5_000
  end

  defp child_pid(supervisor, id) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {^id, pid, _type, _modules} -> pid
      _child -> nil
    end)
  end

  defp stop_if_alive(supervisor) do
    Supervisor.stop(supervisor)
  catch
    :exit, _reason -> :ok
  end
end
