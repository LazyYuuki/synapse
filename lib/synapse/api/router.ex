defmodule Synapse.API.Router.Arguments do
  @moduledoc false

  @enforce_keys [:socket, :max_origin_bytes, :timeout, :max_frame_size]
  defstruct @enforce_keys
end

defmodule Synapse.API.Router do
  @moduledoc """
  Fixed loopback HTTP and WebSocket upgrade boundary for the local API.

  The only routes are `GET /health` and `GET /v1/socket`. The latter upgrades to
  protocol-v1 text JSON; no frontend assets are served.

  Router validates the request authority against the actual listener port before
  routing. WebSocket upgrades additionally require an empty query, no credential
  or subprotocol headers, an absent or exact local Origin, and a canonical
  RFC 6455 key. Rejected values and parser reasons are never reflected or logged.

  Missing Origin is deliberately accepted for native clients. Loopback and Origin
  checks reduce accidental browser/LAN exposure but are not authentication: any
  local process able to reach the listener can request server-policy authority. In
  particular, `process.exec` runs as the server's OS user and is not sandboxed. Protocol
  clients cannot submit credentials, capabilities, Provider modules, callbacks,
  Workspace handles, or Runtime options. See the [local API guide](api.html).
  """

  @behaviour Plug

  alias Synapse.API.{Config, Socket}
  alias Synapse.API.Router.Arguments
  alias Synapse.Tool.Validation

  @health ~s({"status":"ok","protocol":1})
  @forbidden ~s({"error":"forbidden"})
  @not_found ~s({"error":"not_found"})
  @method_not_allowed ~s({"error":"method_not_allowed"})
  @upgrade_required ~s({"error":"upgrade_required"})
  @forbidden_headers ["authorization", "cookie", "sec-websocket-protocol"]
  @host_pattern ~r/\A(localhost|127\.0\.0\.1):([1-9][0-9]{0,4})\z/i
  @origin_pattern ~r/\A(https?):\/\/(localhost|127\.0\.0\.1|\[::1\]):([1-9][0-9]{0,4})(\/)?\z/i

  @impl true
  def init(options) do
    with true <- exact_options?(options),
         manager <- Keyword.fetch!(options, :manager),
         %Config{enabled: true} = config <- Keyword.fetch!(options, :config),
         true <- Config.valid?(config),
         {:ok, socket} <- Socket.arguments(manager, config) do
      %Arguments{
        socket: socket,
        max_origin_bytes: config.max_origin_bytes,
        timeout: config.connection_inactivity_ms,
        max_frame_size: Config.max_incoming_frame_wire_bytes(config)
      }
    else
      _invalid -> raise ArgumentError, "invalid API router options"
    end
  rescue
    _exception -> raise ArgumentError, "invalid API router options"
  catch
    _kind, _reason -> raise ArgumentError, "invalid API router options"
  end

  @impl true
  def call(conn, %Arguments{} = arguments) do
    if valid_arguments?(arguments) and local_host?(conn) do
      route(conn, arguments)
    else
      respond(conn, 403, @forbidden)
    end
  rescue
    _exception -> respond(conn, 403, @forbidden)
  catch
    _kind, _reason -> respond(conn, 403, @forbidden)
  end

  def call(conn, _arguments), do: respond(conn, 403, @forbidden)

  defp route(%{method: "GET", request_path: "/health"} = conn, _arguments),
    do: respond(conn, 200, @health)

  defp route(%{request_path: "/health"} = conn, _arguments) do
    conn
    |> Plug.Conn.put_resp_header("allow", "GET")
    |> respond(405, @method_not_allowed)
  end

  defp route(%{request_path: "/v1/socket"} = conn, arguments) do
    if socket_policy?(conn, arguments) do
      upgrade_or_respond(conn, arguments)
    else
      respond(conn, 403, @forbidden)
    end
  end

  defp route(conn, _arguments), do: respond(conn, 404, @not_found)

  defp upgrade_or_respond(conn, arguments) do
    with :ok <- WebSockAdapter.UpgradeValidation.validate_upgrade(conn),
         true <- canonical_websocket_key?(conn) do
      conn
      |> strip_extension_headers()
      |> Plug.Conn.put_resp_header("cache-control", "no-store")
      |> WebSockAdapter.upgrade(Synapse.API.Socket, arguments.socket,
        early_validate_upgrade: false,
        timeout: arguments.timeout,
        compress: false,
        max_frame_size: arguments.max_frame_size
      )
    else
      _invalid ->
        conn
        |> Plug.Conn.put_resp_header("upgrade", "websocket")
        |> respond(426, @upgrade_required)
    end
  end

  defp local_host?(conn) do
    with %{address: {127, 0, 0, 1}, port: listener_port} <- Plug.Conn.get_sock_data(conn),
         true <- listener_port in 1..65_535,
         [authority] <- Plug.Conn.get_req_header(conn, "host"),
         [_, host, port_string] <- Regex.run(@host_pattern, authority),
         {port, ""} <- Integer.parse(port_string),
         true <- port_string == Integer.to_string(port),
         true <- port == listener_port,
         normalized <- String.downcase(host, :ascii),
         true <- String.downcase(conn.host, :ascii) == normalized,
         true <- conn.port == listener_port do
      true
    else
      _invalid -> false
    end
  end

  defp socket_policy?(conn, arguments) do
    conn.query_string == "" and no_forbidden_headers?(conn) and
      valid_origin_headers?(Plug.Conn.get_req_header(conn, "origin"), arguments.max_origin_bytes)
  end

  defp no_forbidden_headers?(conn),
    do: Enum.all?(@forbidden_headers, &(Plug.Conn.get_req_header(conn, &1) == []))

  defp valid_origin_headers?([], _maximum), do: true

  defp valid_origin_headers?([origin], maximum) do
    byte_size(origin) <= maximum and valid_origin?(origin)
  end

  defp valid_origin_headers?(_origins, _maximum), do: false

  defp valid_origin?(origin) do
    with [_, scheme, lexical_host, port_string | _optional_slash] <-
           Regex.run(@origin_pattern, origin),
         {port, ""} <- Integer.parse(port_string),
         true <- port_string == Integer.to_string(port),
         true <- port in 1..65_535,
         {:ok, uri} <- URI.new(origin),
         host <- String.downcase(uri.host || "", :ascii),
         true <- String.downcase(scheme, :ascii) in ["http", "https"],
         true <- host in ["localhost", "127.0.0.1", "::1"],
         true <- lexical_origin_host?(lexical_host, host),
         true <- uri.port == port,
         true <- is_nil(uri.userinfo),
         true <- uri.path in [nil, "", "/"],
         true <- is_nil(uri.query) and is_nil(uri.fragment) do
      true
    else
      _invalid -> false
    end
  end

  defp lexical_origin_host?("[::1]", "::1"), do: true

  defp lexical_origin_host?(lexical, parsed),
    do: String.downcase(lexical, :ascii) == parsed

  defp canonical_websocket_key?(conn) do
    case Plug.Conn.get_req_header(conn, "sec-websocket-key") do
      [key] ->
        case Base.decode64(key) do
          {:ok, decoded} -> byte_size(decoded) == 16 and Base.encode64(decoded) == key
          :error -> false
        end

      _invalid ->
        false
    end
  end

  defp strip_extension_headers(conn) do
    headers =
      Enum.reject(conn.req_headers, fn {name, _value} -> name == "sec-websocket-extensions" end)

    %{conn | req_headers: headers}
  end

  defp respond(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_header("content-type", "application/json")
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> Plug.Conn.send_resp(status, body)
  end

  defp exact_options?(options) do
    Validation.proper_list?(options, 2) and Keyword.keyword?(options) and length(options) == 2 and
      options |> Keyword.keys() |> Enum.sort() == [:config, :manager]
  end

  defp valid_arguments?(%Arguments{} = arguments),
    do:
      is_struct(arguments.socket, Synapse.API.Socket.Arguments) and
        is_integer(arguments.max_origin_bytes) and arguments.max_origin_bytes > 0 and
        is_integer(arguments.timeout) and arguments.timeout > 0 and
        is_integer(arguments.max_frame_size) and arguments.max_frame_size > 0
end

defimpl Inspect, for: Synapse.API.Router.Arguments do
  def inspect(_arguments, _options), do: "#Synapse.API.Router.Arguments<redacted>"
end
