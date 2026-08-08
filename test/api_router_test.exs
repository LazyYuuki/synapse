defmodule Synapse.API.RouterTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Synapse.API.{Config, Router}

  test "Router initialization retains redacted authority-free arguments" do
    config = config()
    manager = {:global, {:router_manager, make_ref()}}
    arguments = Router.init(manager: manager, config: config)

    assert inspect(arguments) == "#Synapse.API.Router.Arguments<redacted>"
    refute inspect(arguments) =~ inspect(manager)
    assert_raise ArgumentError, "invalid API router options", fn -> Router.init([]) end

    assert_raise ArgumentError, "invalid API router options", fn ->
      Router.init(manager: manager, config: Config.default())
    end

    assert_raise ArgumentError, "invalid API router options", fn ->
      Router.init(manager: manager, config: config, unknown: true)
    end
  end

  test "real loopback HTTP returns exact health and fixed failure responses" do
    %{port: port} = start_api()
    connection = open_connection(port)

    assert_response(connection, "GET", "/health", port, 200, ~s({"status":"ok","protocol":1}),
      expected_headers: [
        {"cache-control", "no-store"},
        {"content-type", "application/json"}
      ]
    )

    assert_response(
      connection,
      "POST",
      "/health",
      port,
      405,
      ~s({"error":"method_not_allowed"}),
      expected_headers: [{"allow", "GET"}]
    )

    assert_response(connection, "GET", "/missing", port, 404, ~s({"error":"not_found"}))
    assert_response(connection, "GET", "/health/", port, 404, ~s({"error":"not_found"}))
    assert_response(connection, "GET", "//health", port, 404, ~s({"error":"not_found"}))

    assert_response(
      connection,
      "GET",
      "/v1/socket/",
      port,
      404,
      ~s({"error":"not_found"})
    )

    assert_response(
      connection,
      "GET",
      "/v1/socket",
      port,
      426,
      ~s({"error":"upgrade_required"}),
      expected_headers: [{"upgrade", "websocket"}]
    )

    assert_response(
      connection,
      "GET",
      "/health",
      port,
      403,
      ~s({"error":"forbidden"}),
      request_headers: [{"host", "localhost:1"}]
    )
  end

  test "Host, query, forbidden headers, and rejected Origins return fixed 403 without disclosure" do
    %{port: port} = start_api()
    secret = "ROUTER_PHASE6_DISCLOSURE_SECRET"

    rejected = [
      {"/v1/socket?#{secret}", []},
      {"/v1/socket", [{"authorization", "Bearer #{secret}"}]},
      {"/v1/socket", [{"cookie", "session=#{secret}"}]},
      {"/v1/socket", [{"sec-websocket-protocol", secret}]},
      {"/v1/socket", [{"origin", "http://example.com:3000/#{secret}"}]},
      {"/v1/socket", [{"origin", "null"}]},
      {"/v1/socket", [{"origin", "http://localhost"}]},
      {"/v1/socket", [{"origin", "http://localhost:3000/path"}]},
      {"/v1/socket", [{"origin", "http://user@localhost:3000"}]},
      {"/v1/socket", [{"origin", "http://localhost:3000/?query=x"}]},
      {"/v1/socket", [{"origin", "http://localhost:3000/#fragment"}]},
      {"/v1/socket", [{"origin", "file://localhost:3000"}]},
      {"/v1/socket", [{"origin", "ws://localhost:3000"}]},
      {"/v1/socket", [{"origin", ""}]},
      {"/v1/socket", [{"origin", "NULL"}]},
      {"/v1/socket", [{"origin", "http://localhost:0"}]},
      {"/v1/socket", [{"origin", "http://localhost:03000"}]},
      {"/v1/socket", [{"origin", "http://localhost:65536"}]},
      {"/v1/socket", [{"origin", "http://[::2]:3000"}]},
      {"/v1/socket", [{"origin", "http://evil-localhost:3000"}]},
      {"/v1/socket", [{"origin", "http://attacker.localhost:3000"}]},
      {"/v1/socket", [{"origin", "http://localhost.evil:3000"}]},
      {"/v1/socket", [{"origin", "http://127.0.0.1.nip.io:3000"}]},
      {"/v1/socket", [{"origin", "http://127.1:3000"}]},
      {"/v1/socket", [{"origin", "http://2130706433:3000"}]},
      {"/v1/socket", [{"origin", "http://*.localhost:3000"}]},
      {"/v1/socket", [{"origin", "http://localhost:3000,http://evil:3000"}]},
      {"/v1/socket", [{"origin", "http://localhost:3000"}, {"origin", "http://localhost:3000"}]},
      {"/v1/socket", [{"origin", "http://localhost:3000"}, {"origin", "http://127.0.0.1:3000"}]}
    ]

    log =
      capture_log(fn ->
        Enum.each(rejected, fn {path, extra_headers} ->
          connection = open_connection(port)
          response = request(connection, "GET", path, port, extra_headers)
          assert response.status == 403
          assert response.body == ~s({"error":"forbidden"})
          refute response.body =~ secret
          refute inspect(response.headers) =~ secret
          :gun.close(connection)
        end)
      end)

    refute log =~ secret
  end

  test "Host accepts only canonical loopback authority at the actual listener port" do
    %{port: port} = start_api()
    secret = "REJECTED_HOST_DISCLOSURE_SECRET"

    Enum.each(["127.0.0.1:#{port}", "localhost:#{port}", "LOCALHOST:#{port}"], fn host ->
      connection = open_connection(port)
      response = request(connection, "GET", "/health", port, [{"host", host}])
      assert response.status == 200
      :gun.close(connection)
    end)

    rejected = [
      "localhost",
      "localhost:#{port + 1}",
      "localhost:0#{port}",
      "localhost.:#{port}",
      "evil-localhost:#{port}",
      "attacker.localhost:#{port}",
      "localhost.evil:#{port}",
      "localhost.example:#{port}",
      "127.0.0.1.evil:#{port}",
      "127.0.0.1.nip.io:#{port}",
      "127.0.0.2:#{port}",
      "127.000.000.001:#{port}",
      "127.1:#{port}",
      "2130706433:#{port}",
      "0x7f000001:#{port}",
      "017700000001:#{port}",
      "0.0.0.0:#{port}",
      "[::1]:#{port}",
      "[::ffff:127.0.0.1]:#{port}",
      "example.com:#{port}",
      "#{secret}.example:#{port}"
    ]

    log =
      capture_log(fn ->
        Enum.each(rejected, fn host ->
          connection = open_connection(port)
          response = request(connection, "GET", "/health", port, [{"host", host}])
          assert response.status == 403
          assert response.body == ~s({"error":"forbidden"})
          refute response.body =~ host
          :gun.close(connection)
        end)
      end)

    refute log =~ secret
  end

  test "valid native and local-Origin upgrades send hello first without extensions or subprotocol" do
    %{port: port} = start_api()

    origins = [
      nil,
      "http://localhost:3000",
      "HTTP://LOCALHOST:3000/",
      "https://127.0.0.1:4443",
      "https://127.0.0.1:65535",
      "http://[::1]:3000/"
    ]

    Enum.each(origins, fn origin ->
      connection = open_connection(port)
      headers = if origin, do: [{"origin", origin}], else: []
      {stream, response_headers, hello} = upgrade(connection, port, headers, %{compress: true})

      refute header?(response_headers, "sec-websocket-protocol")
      refute header?(response_headers, "sec-websocket-extensions")

      assert JSON.decode!(hello) == %{
               "version" => 1,
               "type" => "server.hello",
               "request_id" => nil,
               "payload" => %{
                 "protocol" => 1,
                 "replay" => "memory",
                 "max_active_runs" => 1,
                 "cwd" => "/synthetic/api-router-launch",
                 "max_output_bytes" => 524_288
               }
             }

      ping =
        JSON.encode!(%{"version" => 1, "type" => "ping", "request_id" => "p", "payload" => %{}})

      assert :ok = :gun.ws_send(connection, stream, {:text, ping})
      assert_receive {:gun_ws, ^connection, ^stream, {:text, pong}}, 2_000
      assert JSON.decode!(pong)["type"] == "pong"
      :gun.close(connection)
    end)
  end

  test "invalid keys and forbidden upgrade policy fail without crashing the listener" do
    %{listener: listener, port: port} = start_api()

    invalid = [
      [{"sec-websocket-key", "not-base64"}],
      [{"sec-websocket-key", Base.encode64(<<0::120>>)}],
      [{"sec-websocket-version", "12"}],
      [{"authorization", "secret"}],
      [{"origin", String.duplicate("x", 513)}]
    ]

    Enum.each(invalid, fn headers ->
      connection = open_connection(port)
      stream = :gun.ws_upgrade(connection, "/v1/socket", with_host(headers, port), %{})

      assert_receive {:gun_response, ^connection, ^stream, :nofin, status, _response_headers},
                     2_000

      assert status in [403, 426]
      assert Process.alive?(listener)
      :gun.close(connection)
    end)
  end

  test "raw handshakes reject lone malformed keys and ignore malformed extension offers" do
    %{listener: listener, port: port} = start_api()

    Enum.each(["not-base64", Base.encode64(<<0::120>>), Base.encode64(<<0::136>>)], fn key ->
      assert raw_upgrade(port, [{"Sec-WebSocket-Key", key}]) =~ "HTTP/1.1 426"
      assert Process.alive?(listener)
    end)

    key = Base.encode64(<<0::128>>)

    assert raw_upgrade(port, [{"Sec-WebSocket-Key", key}, {"Sec-WebSocket-Key", key}]) =~
             "HTTP/1.1 426"

    assert Process.alive?(listener)

    response =
      raw_upgrade(port, [
        {"Sec-WebSocket-Key", key},
        {"Sec-WebSocket-Extensions", "permessage-deflate; malformed==value"},
        {"Sec-WebSocket-Extensions", "synthetic-extension; =broken"}
      ])

    assert response =~ "HTTP/1.1 101"
    assert Process.alive?(listener)
  end

  test "Bandit owns malformed Host and HTTP parser limits before Router" do
    %{port: port} = start_api()

    assert raw_http(port, "GET /health HTTP/1.1\r\nConnection: close\r\n\r\n") =~ " 400 "

    duplicate =
      "GET /health HTTP/1.1\r\nHost: localhost:#{port}\r\nHost: 127.0.0.1:#{port}\r\nConnection: close\r\n\r\n"

    assert raw_http(port, duplicate) =~ " 400 "

    Enum.each(["user@localhost:#{port}", "localhost:#{port},evil:#{port}"], fn host ->
      request = "GET /health HTTP/1.1\r\nHost: #{host}\r\nConnection: close\r\n\r\n"
      response = raw_http(port, request)
      assert response =~ " 400 " or response =~ " 403 "
      refute response =~ host
    end)

    long_path = "/" <> String.duplicate("x", 8_192)

    long_request =
      "GET #{long_path} HTTP/1.1\r\nHost: localhost:#{port}\r\nConnection: close\r\n\r\n"

    assert raw_http(port, long_request) =~ " 414 "
  end

  test "real binary, invalid UTF-8, and oversized frames close with transport policy codes" do
    %{port: port, config: config} = start_api()

    {binary_connection, binary_stream, _headers, _hello} = open_upgrade(port)
    assert :ok = :gun.ws_send(binary_connection, binary_stream, {:binary, <<0, 1, 2>>})
    assert_receive {:gun_ws, ^binary_connection, ^binary_stream, {:close, 1003, _reason}}, 2_000
    :gun.close(binary_connection)

    {utf8_connection, utf8_stream, _headers, _hello} = open_upgrade(port)
    assert :ok = :gun.ws_send(utf8_connection, utf8_stream, {:text, <<0xC3, 0x28>>})
    assert_receive {:gun_ws, ^utf8_connection, ^utf8_stream, {:close, 1007, _reason}}, 2_000
    :gun.close(utf8_connection)

    {large_socket, response} = raw_upgrade_socket(port)

    assert :ok =
             :gen_tcp.send(
               large_socket,
               masked_frame(
                 0x81,
                 String.duplicate("x", config.max_incoming_frame_payload_bytes + 1)
               )
             )

    assert recv_close_code(large_socket, response) == 1009
    :gen_tcp.close(large_socket)
  end

  test "fragmented messages exceeding the assembled limit close 1009" do
    %{port: port} = start_api()
    {socket, response} = raw_upgrade_socket(port)
    assert response =~ "HTTP/1.1 101"
    payload = String.duplicate("x", 1_048_577)
    :ok = :gen_tcp.send(socket, masked_frame(0x01, payload))
    :ok = :gen_tcp.send(socket, masked_frame(0x80, payload))
    assert recv_close_code(socket, response) == 1009
    :gen_tcp.close(socket)
  end

  test "valid fragmented text reassembles across escape and UTF-8 boundaries" do
    %{port: port} = start_api()
    {socket, response} = raw_upgrade_socket(port)
    assert response =~ "HTTP/1.1 101"

    message =
      JSON.encode!(%{
        "version" => 1,
        "type" => "ping",
        "request_id" => "fragment-é-\"",
        "payload" => %{}
      })

    chunks = for <<byte <- message>>, do: <<byte>>
    [first | rest] = chunks
    {middle, [last]} = Enum.split(rest, length(rest) - 1)
    :ok = :gen_tcp.send(socket, masked_frame(0x01, first))
    Enum.each(middle, &(:ok = :gen_tcp.send(socket, masked_frame(0x00, &1))))
    :ok = :gen_tcp.send(socket, masked_frame(0x80, last))
    received = recv_until(socket, "fragment-é", response)
    assert received =~ "fragment-é"
    assert received =~ "pong"
    :gen_tcp.close(socket)
  end

  test "exact frame and assembled-message limits are accepted" do
    %{port: port, config: config} = start_api()
    request_id = "exact-frame"
    base = command("ping", request_id)
    payload = base <> String.duplicate(" ", config.max_incoming_message_bytes - byte_size(base))
    assert byte_size(payload) == config.max_incoming_message_bytes

    {connection, stream, _headers, _hello} = open_upgrade(port)
    assert :ok = :gun.ws_send(connection, stream, {:text, payload})
    assert_receive {:gun_ws, ^connection, ^stream, {:text, pong}}, 5_000
    assert JSON.decode!(pong)["request_id"] == request_id
    :gun.close(connection)

    {socket, response} = raw_upgrade_socket(port)
    split = div(byte_size(payload), 2)
    <<first::binary-size(^split), second::binary>> = payload
    :ok = :gen_tcp.send(socket, masked_frame(0x01, first))
    :ok = :gen_tcp.send(socket, masked_frame(0x80, second))
    received = recv_until(socket, request_id, response)
    assert received =~ request_id
    assert received =~ "pong"
    :gen_tcp.close(socket)
  end

  test "rapid reused commands remain serial and a real violation flood closes only its socket" do
    %{listener: listener, port: port} = start_api()
    {connection, stream, _headers, _hello} = open_upgrade(port)
    ping = command("ping", "rapid-reuse")

    Enum.each(1..64, fn _ordinal ->
      assert :ok = :gun.ws_send(connection, stream, {:text, ping})
    end)

    Enum.each(1..64, fn _ordinal ->
      assert_receive {:gun_ws, ^connection, ^stream, {:text, pong}}, 5_000
      assert JSON.decode!(pong)["request_id"] == "rapid-reuse"
    end)

    :gun.close(connection)

    {violating, violating_stream, _headers, _hello} = open_upgrade(port)

    Enum.each(1..8, fn _ordinal ->
      assert :ok = :gun.ws_send(violating, violating_stream, {:text, "{"})
      assert_receive {:gun_ws, ^violating, ^violating_stream, {:text, error}}, 2_000
      assert JSON.decode!(error)["payload"]["code"] == "invalid_json"
    end)

    assert :ok = :gun.ws_send(violating, violating_stream, {:text, "{"})
    assert_receive {:gun_ws, ^violating, ^violating_stream, {:close, 1008, _reason}}, 2_000
    assert Process.alive?(listener)
    :gun.close(violating)

    {fresh, fresh_stream, _headers, _hello} = open_upgrade(port)
    assert :ok = :gun.ws_send(fresh, fresh_stream, {:text, command("ping", "fresh")})
    assert_receive {:gun_ws, ^fresh, ^fresh_stream, {:text, fresh_pong}}, 2_000
    assert JSON.decode!(fresh_pong)["request_id"] == "fresh"
    :gun.close(fresh)
  end

  test "one configured connection is admitted and the next waits for capacity" do
    %{port: port} = start_api(max_connections: 1)
    {connection, _stream, _headers, _hello} = open_upgrade(port)

    {:ok, waiting} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [mode: :binary, active: false], 2_000)

    request =
      "GET /health HTTP/1.1\r\nHost: localhost:#{port}\r\nConnection: close\r\n\r\n"

    :ok = :gen_tcp.send(waiting, request)
    assert {:error, :timeout} = :gen_tcp.recv(waiting, 0, 100)
    :gun.close(connection)
    assert {:ok, response} = :gen_tcp.recv(waiting, 0, 2_000)
    assert response =~ "HTTP/1.1 200"
    :gen_tcp.close(waiting)
  end

  defp start_api(options \\ []) do
    config = config(options)
    manager = {:global, {:router_test_manager, make_ref()}}
    sessions = {:global, {:router_test_sessions, make_ref()}}

    {:ok, supervisor} =
      Synapse.API.Supervisor.start_link(
        name: nil,
        config: config,
        manager: manager,
        session_supervisor: sessions
      )

    on_exit(fn -> stop(supervisor) end)
    {:ok, listener} = Synapse.API.Supervisor.listener(supervisor)
    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(listener)
    %{supervisor: supervisor, listener: listener, port: port, config: config}
  end

  defp config(options \\ []) do
    attrs =
      Keyword.merge(
        [
          enabled: true,
          launch_cwd: "/synthetic/api-router-launch",
          default_model: "model-a",
          port: 0
        ],
        options
      )

    {:ok, config} = Config.new(attrs)
    config
  end

  defp open_connection(port) do
    {:ok, connection} = :gun.open({127, 0, 0, 1}, port, %{protocols: [:http], retry: 0})
    assert_receive {:gun_up, ^connection, :http}, 2_000
    connection
  end

  defp request(connection, method, path, port, extra_headers) do
    headers = with_host(extra_headers, port)
    stream = :gun.request(connection, method, path, headers, "")
    assert_receive {:gun_response, ^connection, ^stream, :nofin, status, response_headers}, 2_000
    assert_receive {:gun_data, ^connection, ^stream, :fin, body}, 2_000
    %{status: status, headers: response_headers, body: body}
  end

  defp assert_response(connection, method, path, port, status, body, options \\ []) do
    headers = Keyword.get(options, :request_headers, [])
    response = request(connection, method, path, port, headers)
    assert response.status == status
    assert response.body == body

    Enum.each(Keyword.get(options, :expected_headers, []), fn {name, value} ->
      assert header(response.headers, name) == value
    end)
  end

  defp upgrade(connection, port, headers, options) do
    stream = :gun.ws_upgrade(connection, "/v1/socket", with_host(headers, port), options)
    assert_receive {:gun_upgrade, ^connection, ^stream, ["websocket"], response_headers}, 2_000
    assert_receive {:gun_ws, ^connection, ^stream, {:text, hello}}, 2_000
    {stream, response_headers, hello}
  end

  defp open_upgrade(port) do
    connection = open_connection(port)
    {stream, headers, hello} = upgrade(connection, port, [], %{})
    {connection, stream, headers, hello}
  end

  defp with_host(headers, port) do
    if Enum.any?(headers, fn {name, _value} -> name == "host" end),
      do: headers,
      else: [{"host", "localhost:#{port}"} | headers]
  end

  defp raw_upgrade(port, extra_headers) do
    key? = Enum.any?(extra_headers, fn {name, _value} -> name == "Sec-WebSocket-Key" end)

    headers =
      [
        {"Host", "localhost:#{port}"},
        {"Connection", "Upgrade"},
        {"Upgrade", "websocket"},
        {"Sec-WebSocket-Version", "13"}
      ] ++
        if(key?,
          do: extra_headers,
          else: [{"Sec-WebSocket-Key", Base.encode64(<<0::128>>)} | extra_headers]
        )

    request =
      "GET /v1/socket HTTP/1.1\r\n" <>
        Enum.map_join(headers, "", fn {name, value} -> "#{name}: #{value}\r\n" end) <> "\r\n"

    raw_http(port, request)
  end

  defp raw_upgrade_socket(port) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [mode: :binary, active: false], 2_000)

    request =
      "GET /v1/socket HTTP/1.1\r\n" <>
        "Host: localhost:#{port}\r\n" <>
        "Connection: Upgrade\r\n" <>
        "Upgrade: websocket\r\n" <>
        "Sec-WebSocket-Version: 13\r\n" <>
        "Sec-WebSocket-Key: #{Base.encode64(<<0::128>>)}\r\n\r\n"

    :ok = :gen_tcp.send(socket, request)
    {socket, recv_headers(socket, "")}
  end

  defp raw_http(port, request) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [mode: :binary, active: false], 2_000)

    :ok = :gen_tcp.send(socket, request)
    result = recv_headers(socket, "")
    :gen_tcp.close(socket)
    result
  end

  defp recv_headers(socket, result) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, data} ->
        next = result <> data
        if next =~ "\r\n\r\n", do: next, else: recv_headers(socket, next)

      {:error, _reason} ->
        result
    end
  end

  defp masked_frame(first_byte, payload) do
    <<first_byte, 0xFF, byte_size(payload)::unsigned-big-integer-size(64), 0::32,
      payload::binary>>
  end

  defp command(type, request_id) do
    JSON.encode!(%{"version" => 1, "type" => type, "request_id" => request_id, "payload" => %{}})
  end

  defp recv_until(socket, needle, result) do
    if :binary.match(result, needle) != :nomatch do
      result
    else
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, data} -> recv_until(socket, needle, result <> data)
        {:error, _reason} -> result
      end
    end
  end

  defp recv_close_code(socket, response) do
    frames =
      case :binary.split(response, "\r\n\r\n") do
        [_headers, frames] -> frames
        [_incomplete] -> <<>>
      end

    recv_close_code_frames(socket, frames)
  end

  defp recv_close_code_frames(socket, frames) do
    case parse_close_code(frames) do
      {:ok, code} ->
        code

      :more ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, data} -> recv_close_code_frames(socket, frames <> data)
          {:error, reason} -> flunk("socket closed before a close frame: #{inspect(reason)}")
        end
    end
  end

  defp parse_close_code(<<first, second, rest::binary>>) do
    opcode = Bitwise.band(first, 0x0F)
    masked? = Bitwise.band(second, 0x80) != 0
    length_code = Bitwise.band(second, 0x7F)

    with false <- masked?,
         {:ok, length, payload_and_rest} <- frame_length(length_code, rest),
         true <- byte_size(payload_and_rest) >= length do
      <<payload::binary-size(^length), remaining::binary>> = payload_and_rest

      if opcode == 0x08 and byte_size(payload) >= 2 do
        <<code::unsigned-big-integer-size(16), _reason::binary>> = payload
        {:ok, code}
      else
        parse_close_code(remaining)
      end
    else
      _incomplete -> :more
    end
  end

  defp parse_close_code(_incomplete), do: :more

  defp frame_length(length, rest) when length <= 125, do: {:ok, length, rest}

  defp frame_length(126, <<length::unsigned-big-integer-size(16), rest::binary>>),
    do: {:ok, length, rest}

  defp frame_length(127, <<length::unsigned-big-integer-size(64), rest::binary>>),
    do: {:ok, length, rest}

  defp frame_length(_length, _incomplete), do: :more

  defp header(headers, name),
    do: headers |> Enum.find_value(fn {key, value} -> if key == name, do: value end)

  defp header?(headers, name), do: Enum.any?(headers, fn {key, _value} -> key == name end)

  defp stop(supervisor) do
    Supervisor.stop(supervisor)
  catch
    :exit, _reason -> :ok
  end
end
