defmodule Synapse.API.Supervisor do
  @moduledoc """
  Owns the optional local API process tree in dependency order.

  RunManager starts first, SessionSupervisor second, and Bandit last under
  `:rest_for_one`. Listener failure restarts only Bandit; session-owner failure
  restarts it and Bandit; Manager failure restarts the complete API suffix without
  replaying temporary RunSession work.

  The tree is conditional: ordinary application startup keeps only Workspace,
  Task, and Runtime infrastructure, while enabled trusted configuration appends
  this supervisor after Runtime. Reverse shutdown stops Bandit first, then sessions
  while Manager and lower cleanup infrastructure remain available. Manager or
  application restart loses all process-lifetime API projection and replay state.

  See the [local API guide](api.html) for the complete restart and shutdown matrix.
  """

  use Supervisor

  alias Synapse.API.{Config, Router, RunManager, RunSession, SessionSupervisor}

  @doc "Starts one enabled production or isolated API tree."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options) do
    name = Keyword.get(options, :name, __MODULE__)
    start_options = if is_nil(name), do: [], else: [name: name]
    Supervisor.start_link(__MODULE__, options, start_options)
  end

  @doc "Returns the exact ordered Manager, session owner, and listener child specs."
  @spec child_specs(keyword()) :: [Supervisor.child_spec()]
  def child_specs(options) do
    config = Keyword.fetch!(options, :config)
    manager = Keyword.get(options, :manager, RunManager)
    sessions = Keyword.get(options, :session_supervisor, SessionSupervisor)
    runtime = Keyword.get(options, :runtime, RunSession.RuntimeBoundary.default())

    if Config.valid?(config) and config.enabled and valid_name?(manager) and valid_name?(sessions) and
         RunSession.RuntimeBoundary.valid?(runtime) do
      starter = RunSession.session_starter(sessions, config, runtime)

      [
        Supervisor.child_spec(
          {RunManager,
           name: manager, config: config, session_starter: starter, cancel_run: runtime.cancel},
          id: RunManager,
          restart: :permanent,
          shutdown: 5_000,
          type: :worker
        ),
        Supervisor.child_spec(
          {SessionSupervisor, name: sessions},
          id: SessionSupervisor,
          restart: :permanent,
          shutdown: 5_000,
          type: :supervisor
        ),
        listener_spec(config, manager)
      ]
    else
      raise ArgumentError, "invalid API supervisor options"
    end
  rescue
    _exception -> raise ArgumentError, "invalid API supervisor options"
  catch
    _kind, _reason -> raise ArgumentError, "invalid API supervisor options"
  end

  @doc "Returns the supervised Bandit PID for listener-info and port-zero discovery."
  @spec listener(Supervisor.supervisor()) :: {:ok, pid()} | {:error, :listener_unavailable}
  def listener(supervisor \\ __MODULE__) do
    case Supervisor.which_children(supervisor) do
      children when is_list(children) ->
        case List.keyfind(children, Bandit, 0) do
          {Bandit, pid, :supervisor, _modules} when is_pid(pid) -> {:ok, pid}
          _missing -> {:error, :listener_unavailable}
        end
    end
  rescue
    _exception -> {:error, :listener_unavailable}
  catch
    _kind, _reason -> {:error, :listener_unavailable}
  end

  @impl true
  def init(options), do: Supervisor.init(child_specs(options), strategy: :rest_for_one)

  defp listener_spec(config, manager) do
    options = [
      plug: {Router, manager: manager, config: config},
      ip: {127, 0, 0, 1},
      port: config.port,
      startup_log: false,
      http_options: [
        compress: false,
        log_protocol_errors: false,
        log_client_closures: false,
        log_exceptions_with_status_codes: []
      ],
      http_1_options: [
        enabled: true,
        max_request_line_length: config.max_http_request_line_bytes,
        max_header_count: config.max_http_headers,
        max_header_length: config.max_http_header_line_bytes
      ],
      http_2_options: [enabled: false],
      websocket_options: [
        max_frame_size: Config.max_incoming_frame_wire_bytes(config),
        max_fragmented_message_size: config.max_incoming_message_bytes,
        validate_text_frames: true,
        compress: false,
        log_protocol_errors: false
      ],
      thousand_island_options: [
        num_acceptors: 1,
        num_connections: config.max_connections,
        read_timeout: config.connection_inactivity_ms,
        silent_terminate_on_error: true,
        shutdown_timeout: 5_000
      ]
    ]

    Bandit.child_spec(options)
    |> Supervisor.child_spec(id: Bandit, restart: :permanent, shutdown: 6_000, type: :supervisor)
  end

  defp valid_name?(name),
    do: is_atom(name) or match?({:global, _term}, name) or match?({:via, _module, _term}, name)
end
