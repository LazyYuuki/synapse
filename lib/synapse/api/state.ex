defmodule Synapse.API.ActiveTool do
  @moduledoc false

  alias Synapse.API.Policy
  alias Synapse.Tool.Validation

  @allowed_fields [:turn, :operation_id, :call_id, :name, :ordinal]
  @enforce_keys @allowed_fields
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          turn: pos_integer(),
          operation_id: String.t(),
          call_id: String.t(),
          name: String.t(),
          ordinal: pos_integer()
        }

  @spec new(keyword() | map(), struct()) :: {:ok, t()} | {:error, term()}
  def new(attrs, config) do
    with true <- Policy.valid?(config) or {:error, {:config, :must_be_valid}},
         {:ok, attrs} <- Validation.attributes(attrs, @allowed_fields),
         true <- positive_int64?(attrs[:turn]) or {:error, {:turn, :must_be_positive_int64}},
         true <-
           Validation.identifier?(
             attrs[:operation_id],
             Policy.max_operation_id_bytes(config)
           ) or {:error, {:operation_id, :must_be_bounded_identifier}},
         true <-
           Validation.identifier?(
             attrs[:call_id],
             Policy.max_call_id_bytes(config)
           ) or {:error, {:call_id, :must_be_bounded_identifier}},
         true <-
           Validation.identifier?(
             attrs[:name],
             Policy.max_tool_name_bytes(config)
           ) or {:error, {:name, :must_be_bounded_identifier}},
         true <-
           positive_int64?(attrs[:ordinal]) or {:error, {:ordinal, :must_be_positive_int64}} do
      {:ok, struct!(__MODULE__, attrs)}
    end
  end

  @spec valid?(term(), struct()) :: boolean()
  def valid?(%__MODULE__{} = tool, config),
    do: match?({:ok, %__MODULE__{}}, new(Map.from_struct(tool), config))

  def valid?(_tool, _config), do: false

  defp positive_int64?(value), do: Validation.int64?(value) and value > 0
end

defmodule Synapse.API.Projection do
  @moduledoc false

  alias Synapse.API.{ActiveTool, Policy}
  alias Synapse.Tool.Validation

  @enforce_keys [
    :status,
    :model,
    :turn,
    :text,
    :active_tool,
    :provider_attempts,
    :tool_calls,
    :output_bytes
  ]
  defstruct @enforce_keys

  @type status ::
          :starting
          | :running
          | :cancel_requested
          | :owner_lost
          | :completed
          | :failed
          | :interrupted

  @type t :: %__MODULE__{
          status: status(),
          model: String.t() | nil,
          turn: non_neg_integer(),
          text: String.t(),
          active_tool: ActiveTool.t() | nil,
          provider_attempts: non_neg_integer(),
          tool_calls: non_neg_integer(),
          output_bytes: non_neg_integer()
        }

  @spec new() :: t()
  def new do
    %__MODULE__{
      status: :starting,
      model: nil,
      turn: 0,
      text: "",
      active_tool: nil,
      provider_attempts: 0,
      tool_calls: 0,
      output_bytes: 0
    }
  end

  @spec valid?(term(), struct()) :: boolean()
  def valid?(%__MODULE__{} = projection, config) do
    Policy.valid?(config) and projection.status in statuses() and
      (is_nil(projection.model) or projection.model in config.model_allowlist) and
      counter?(projection.turn) and bounded_text?(projection.text, config) and
      (is_nil(projection.active_tool) or ActiveTool.valid?(projection.active_tool, config)) and
      counter?(projection.provider_attempts) and counter?(projection.tool_calls) and
      counter?(projection.output_bytes)
  end

  def valid?(_projection, _config), do: false

  @spec known_status?(term()) :: boolean()
  def known_status?(status), do: status in statuses()

  defp statuses,
    do: [:starting, :running, :cancel_requested, :owner_lost, :completed, :failed, :interrupted]

  defp counter?(value), do: Validation.int64?(value) and value >= 0

  defp bounded_text?(text, config),
    do:
      is_binary(text) and String.valid?(text) and
        byte_size(text) <= config.max_projection_text_bytes
end

defmodule Synapse.API.Subscriber do
  @moduledoc false

  alias Synapse.Tool.Validation

  @allowed_fields [:pid, :monitor, :cursor, :notified]
  @enforce_keys @allowed_fields
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          pid: pid(),
          monitor: reference(),
          cursor: non_neg_integer(),
          notified: boolean()
        }

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, attrs} <- Validation.attributes(attrs, @allowed_fields),
         true <- is_pid(attrs[:pid]) or {:error, {:pid, :must_be_pid}},
         true <- is_reference(attrs[:monitor]) or {:error, {:monitor, :must_be_reference}},
         true <-
           (Validation.int64?(attrs[:cursor]) and attrs.cursor >= 0) or
             {:error, {:cursor, :must_be_non_negative_int64}},
         true <- is_boolean(attrs[:notified]) or {:error, {:notified, :must_be_boolean}} do
      {:ok, struct!(__MODULE__, attrs)}
    end
  end

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = subscriber),
    do: match?({:ok, %__MODULE__{}}, new(Map.from_struct(subscriber)))

  def valid?(_subscriber), do: false
end

defmodule Synapse.API.ReplayEntry do
  @moduledoc false

  alias Synapse.API.Config
  alias Synapse.Tool.Validation

  @input_fields [:seq, :type, :encoded]
  @enforce_keys @input_fields ++ [:encoded_bytes, :accounted_bytes]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          seq: pos_integer(),
          type: :event | :terminal,
          encoded: iodata(),
          encoded_bytes: non_neg_integer(),
          accounted_bytes: pos_integer()
        }

  @spec new(keyword() | map(), Config.t()) :: {:ok, t()} | {:error, term()}
  def new(attrs, %Config{} = config) do
    with true <- Config.valid?(config) or {:error, {:config, :must_be_valid}},
         {:ok, attrs} <- Validation.attributes(attrs, @input_fields),
         true <-
           (Validation.int64?(attrs[:seq]) and attrs.seq > 0) or
             {:error, {:seq, :must_be_positive_int64}},
         true <- attrs[:type] in [:event, :terminal] or {:error, {:type, :must_be_known}},
         {:ok, encoded_bytes} <- encoded_bytes(attrs[:encoded]),
         true <-
           encoded_bytes <= config.max_outgoing_message_bytes or
             {:error, {:encoded_bytes, :must_fit_outgoing_message}},
         accounted_bytes <- encoded_bytes + Config.replay_entry_overhead_bytes(),
         true <-
           accounted_bytes <= config.max_replay_bytes or
             {:error, {:accounted_bytes, :must_fit_replay}} do
      {:ok,
       struct!(
         __MODULE__,
         Map.merge(attrs, %{encoded_bytes: encoded_bytes, accounted_bytes: accounted_bytes})
       )}
    end
  end

  def new(_attrs, _config), do: {:error, {:config, :must_be_valid}}

  @spec valid?(term(), Config.t()) :: boolean()
  def valid?(%__MODULE__{} = entry, %Config{} = config) do
    attrs = Map.take(Map.from_struct(entry), @input_fields)
    match?({:ok, ^entry}, new(attrs, config))
  end

  def valid?(_entry, _config), do: false

  defp encoded_bytes(encoded) do
    bytes = IO.iodata_length(encoded)
    if bytes >= 0, do: {:ok, bytes}, else: {:error, {:encoded, :must_be_iodata}}
  rescue
    _exception -> {:error, {:encoded, :must_be_iodata}}
  catch
    _kind, _reason -> {:error, {:encoded, :must_be_iodata}}
  end
end

defmodule Synapse.API.PendingTerminal do
  @moduledoc false

  alias Synapse.API.Command.Cancel
  alias Synapse.API.Config
  alias Synapse.API.Policy
  alias Synapse.Agent.Error
  alias Synapse.Run.Event
  alias Synapse.Tool.Validation

  @result_fields [:text, :turns, :tool_calls, :provider_retries, :output_bytes]
  @enforce_keys [:run_id, :status, :result, :error]
  defstruct @enforce_keys

  @type result :: %{
          text: String.t(),
          turns: pos_integer(),
          tool_calls: non_neg_integer(),
          provider_retries: non_neg_integer(),
          output_bytes: non_neg_integer()
        }
  @type t :: %__MODULE__{
          run_id: String.t(),
          status: :completed | :failed | :interrupted,
          result: result() | nil,
          error: Error.t() | nil
        }

  @spec new(Event.t(), Config.t()) :: {:ok, t()} | {:error, term()}
  def new(%Event.RunCompleted{} = event, %Config{} = config) do
    with true <- Config.valid?(config) or {:error, {:config, :must_be_valid}},
         {:ok, normalized} <- Event.new(:run_completed, Map.from_struct(event)),
         true <-
           result_within_policy?(normalized.result, config) or
             {:error, {:result, :must_fit_server_policy}} do
      result = Map.take(Map.from_struct(normalized.result), @result_fields)

      {:ok,
       %__MODULE__{
         run_id: normalized.run_id,
         status: :completed,
         result: result,
         error: nil
       }}
    end
  end

  def new(%Event.RunFailed{} = event, %Config{} = config),
    do: error_terminal(:run_failed, :failed, event, config)

  def new(%Event.RunInterrupted{} = event, %Config{} = config),
    do: error_terminal(:run_interrupted, :interrupted, event, config)

  def new(_event, _config), do: {:error, {:terminal, :must_be_terminal_run_event}}

  @spec valid?(term(), Config.t()) :: boolean()
  def valid?(%__MODULE__{status: :completed, result: result, error: nil} = terminal, config) do
    Policy.valid?(config) and Cancel.valid_run_id?(terminal.run_id, config) and
      valid_result?(result, config)
  end

  def valid?(%__MODULE__{status: status, result: nil, error: %Error{} = error} = terminal, config)
      when status in [:failed, :interrupted] do
    Policy.valid?(config) and Cancel.valid_run_id?(terminal.run_id, config) and
      valid_error?(error, terminal.run_id)
  end

  def valid?(_terminal, _config), do: false

  defp error_terminal(kind, status, event, config) do
    with true <- Config.valid?(config) or {:error, {:config, :must_be_valid}},
         {:ok, normalized} <- Event.new(kind, Map.from_struct(event)),
         true <-
           Cancel.valid_run_id?(normalized.run_id, config) or
             {:error, {:run_id, :must_be_valid}} do
      {:ok,
       %__MODULE__{
         run_id: normalized.run_id,
         status: status,
         result: nil,
         error: normalized.error
       }}
    end
  end

  defp result_within_policy?(result, config) do
    Cancel.valid_run_id?(result.run_id, config) and
      byte_size(result.text) <= config.max_projection_text_bytes and positive_int64?(result.turns) and
      counter?(result.tool_calls) and counter?(result.provider_retries) and
      counter?(result.output_bytes)
  end

  defp valid_result?(result, config) when is_map(result) and not is_struct(result) do
    Map.keys(result) |> Enum.sort() == Enum.sort(@result_fields) and
      Validation.bounded_non_empty_string?(result[:text], config.max_projection_text_bytes) and
      positive_int64?(result[:turns]) and counter?(result[:tool_calls]) and
      counter?(result[:provider_retries]) and counter?(result[:output_bytes]) and
      result.output_bytes >= byte_size(result.text)
  end

  defp valid_result?(_result, _config), do: false

  defp valid_error?(error, run_id) do
    case Error.new(Map.from_struct(error)) do
      {:ok, normalized} -> normalized == error and normalized.run_id == run_id
      {:error, _reason} -> false
    end
  end

  defp positive_int64?(value), do: Validation.int64?(value) and value > 0
  defp counter?(value), do: Validation.int64?(value) and value >= 0
end

defmodule Synapse.API.RunRecord do
  @moduledoc false

  alias Synapse.API.Command.Cancel

  alias Synapse.API.{
    ActiveTool,
    Config,
    ConfirmedTerminal,
    PendingTerminal,
    Projection,
    ReplayEntry,
    Subscriber
  }

  alias Synapse.Runtime.Run
  alias Synapse.Tool.Validation

  @enforce_keys [
    :id,
    :status,
    :cancel_requested,
    :session_pid,
    :session_monitor,
    :runtime_run,
    :last_seq,
    :projection,
    :run_started,
    :open_turn,
    :provider_operation_id,
    :last_completed_turn,
    :last_turn_outcome,
    :last_tool_ordinal,
    :owner_lost_tool,
    :pending_terminal,
    :terminal,
    :replay,
    :replay_bytes,
    :subscribers,
    :created_ordinal,
    :completed_ordinal,
    :sink_rejected,
    :accounted_bytes
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: String.t(),
          status: Projection.status(),
          cancel_requested: boolean(),
          session_pid: pid() | nil,
          session_monitor: reference() | nil,
          runtime_run: Run.t() | nil,
          last_seq: non_neg_integer(),
          projection: Projection.t(),
          run_started: boolean(),
          open_turn: pos_integer() | nil,
          provider_operation_id: String.t() | nil,
          last_completed_turn: non_neg_integer(),
          last_turn_outcome: :continued | :completed | :failed | :interrupted | nil,
          last_tool_ordinal: non_neg_integer(),
          owner_lost_tool: ActiveTool.t() | nil,
          pending_terminal: PendingTerminal.t() | nil,
          terminal: ConfirmedTerminal.t() | nil,
          replay: :queue.queue(ReplayEntry.t()),
          replay_bytes: non_neg_integer(),
          subscribers: %{optional(pid()) => Subscriber.t()},
          created_ordinal: non_neg_integer(),
          completed_ordinal: non_neg_integer() | nil,
          sink_rejected: boolean(),
          accounted_bytes: non_neg_integer()
        }

  @spec new(String.t(), non_neg_integer(), Config.t()) ::
          {:ok, t()} | {:error, term()}
  def new(id, created_ordinal, %Config{} = config) when is_binary(id) do
    with true <- Config.valid?(config) or {:error, {:config, :must_be_valid}},
         accounted_bytes <-
           config.max_outgoing_message_bytes + Config.run_record_overhead_bytes() + byte_size(id),
         true <- Cancel.valid_run_id?(id, config) or {:error, {:id, :must_be_valid_run_id}},
         true <-
           (Validation.int64?(created_ordinal) and created_ordinal >= 0) or
             {:error, {:created_ordinal, :must_be_non_negative_int64}},
         true <-
           accounted_bytes <= config.max_active_state_bytes or
             {:error, {:accounted_bytes, :must_fit_active_state}} do
      {:ok,
       %__MODULE__{
         id: id,
         status: :starting,
         cancel_requested: false,
         session_pid: nil,
         session_monitor: nil,
         runtime_run: nil,
         last_seq: 0,
         projection: Projection.new(),
         run_started: false,
         open_turn: nil,
         provider_operation_id: nil,
         last_completed_turn: 0,
         last_turn_outcome: nil,
         last_tool_ordinal: 0,
         owner_lost_tool: nil,
         pending_terminal: nil,
         terminal: nil,
         replay: :queue.new(),
         replay_bytes: 0,
         subscribers: %{},
         created_ordinal: created_ordinal,
         completed_ordinal: nil,
         sink_rejected: false,
         accounted_bytes: accounted_bytes
       }}
    end
  end

  def new(_id, _created_ordinal, _config), do: {:error, {:config, :must_be_valid}}

  @spec valid?(term(), Config.t()) :: boolean()
  def valid?(%__MODULE__{} = record, %Config{} = config) do
    Config.valid?(config) and Cancel.valid_run_id?(record.id, config) and
      match?(%Projection{}, record.projection) and
      record.status == record.projection.status and is_boolean(record.cancel_requested) and
      counter?(record.last_seq) and Projection.valid?(record.projection, config) and
      valid_event_state?(record, config) and
      valid_pending_terminal?(record.pending_terminal, record.id, config) and
      valid_lifecycle?(record, config) and valid_replay?(record, config) and
      valid_subscribers?(record.subscribers, record.last_seq, config) and
      counter?(record.created_ordinal) and
      is_boolean(record.sink_rejected) and counter?(record.accounted_bytes) and
      valid_accounting?(record, config)
  end

  def valid?(_record, _config), do: false

  defp valid_session?(nil, nil), do: true
  defp valid_session?(pid, monitor), do: is_pid(pid) and is_reference(monitor)

  defp valid_runtime_run?(nil, _record), do: true

  defp valid_runtime_run?(%Run{} = run, record) do
    Run.valid?(run) and run.id == record.id and
      (is_nil(record.session_pid) or run.owner == record.session_pid)
  end

  defp valid_runtime_run?(_run, _record), do: false

  defp valid_pending_terminal?(nil, _run_id, _config), do: true

  defp valid_pending_terminal?(%PendingTerminal{} = terminal, run_id, config),
    do: terminal.run_id == run_id and PendingTerminal.valid?(terminal, config)

  defp valid_pending_terminal?(_terminal, _run_id, _config), do: false

  defp valid_lifecycle?(
         %{status: status, terminal: nil, completed_ordinal: nil} = record,
         _config
       )
       when status in [:starting, :running, :cancel_requested, :owner_lost] do
    valid_session?(record.session_pid, record.session_monitor) and
      valid_runtime_run?(record.runtime_run, record) and cancellation_status_valid?(record)
  end

  defp valid_lifecycle?(
         %{status: status, terminal: %ConfirmedTerminal{} = terminal} = record,
         config
       )
       when status in [:completed, :failed, :interrupted] do
    is_nil(record.pending_terminal) and is_nil(record.session_pid) and
      is_nil(record.session_monitor) and is_nil(record.runtime_run) and
      counter?(record.completed_ordinal) and terminal.run_id == record.id and
      terminal.seq == record.last_seq and terminal.status == status and
      ConfirmedTerminal.valid?(terminal, config) and record.cancel_requested in [true, false]
  end

  defp valid_lifecycle?(_record, _config), do: false

  defp cancellation_status_valid?(%{status: :cancel_requested, cancel_requested: true}), do: true

  defp cancellation_status_valid?(%{status: :owner_lost, cancel_requested: value}),
    do: is_boolean(value)

  defp cancellation_status_valid?(%{status: status, cancel_requested: false})
       when status in [:starting, :running],
       do: true

  defp cancellation_status_valid?(_record), do: false

  defp valid_event_state?(record, config) do
    is_boolean(record.run_started) and counter?(record.last_completed_turn) and
      record.last_turn_outcome in [nil, :continued, :completed, :failed, :interrupted] and
      counter?(record.last_tool_ordinal) and
      (is_nil(record.owner_lost_tool) or ActiveTool.valid?(record.owner_lost_tool, config)) and
      valid_started_state?(record, config) and
      valid_open_turn?(record, config)
  end

  defp valid_started_state?(%{run_started: false, projection: projection}, _config),
    do: is_nil(projection.model)

  defp valid_started_state?(%{run_started: true, projection: projection}, config),
    do: projection.model in config.model_allowlist

  defp valid_open_turn?(%{open_turn: nil, provider_operation_id: nil} = record, _config) do
    is_nil(record.projection.active_tool) and is_nil(record.owner_lost_tool) and
      (record.status in [:owner_lost, :completed, :failed, :interrupted] or
         record.projection.turn == record.last_completed_turn)
  end

  defp valid_open_turn?(%{open_turn: turn, provider_operation_id: operation_id} = record, config) do
    record.status in [:running, :cancel_requested, :owner_lost] and positive_int64?(turn) and
      turn == record.last_completed_turn + 1 and record.projection.turn == turn and
      Validation.identifier?(
        operation_id,
        config.runtime_options.tool_limits.max_operation_id_bytes
      ) and
      tool_turn_valid?(record.projection.active_tool, turn) and
      tool_turn_valid?(record.owner_lost_tool, turn) and
      not (match?(%ActiveTool{}, record.projection.active_tool) and
             match?(%ActiveTool{}, record.owner_lost_tool))
  end

  defp valid_open_turn?(_record, _config), do: false

  defp tool_turn_valid?(nil, _turn), do: true
  defp tool_turn_valid?(%ActiveTool{turn: turn}, turn), do: true
  defp tool_turn_valid?(_tool, _turn), do: false

  defp valid_replay?(record, config) do
    with {:ok, entries} <- queue_entries(record.replay),
         true <- length(entries) <= config.max_replay_events,
         true <- Enum.all?(entries, &ReplayEntry.valid?(&1, config)),
         true <- replay_sequences_valid?(entries, record),
         bytes <- Enum.reduce(entries, 0, &(&1.accounted_bytes + &2)) do
      bytes == record.replay_bytes and bytes <= config.max_replay_bytes
    else
      _invalid -> false
    end
  end

  defp replay_sequences_valid?(entries, record) do
    sequences = Enum.map(entries, & &1.seq)
    increasing? = Enum.chunk_every(sequences, 2, 1, :discard) |> Enum.all?(fn [a, b] -> a < b end)

    increasing? and Enum.all?(sequences, &(&1 <= record.last_seq)) and
      replay_types_valid?(entries, record)
  end

  defp replay_types_valid?(entries, %{terminal: nil}),
    do: Enum.all?(entries, &(&1.type == :event))

  defp replay_types_valid?(entries, %{terminal: %ConfirmedTerminal{seq: terminal_seq}}) do
    case Enum.filter(entries, &(&1.type == :terminal)) do
      [%ReplayEntry{seq: ^terminal_seq}] -> List.last(entries).type == :terminal
      _entries -> false
    end
  end

  defp replay_types_valid?(_entries, _record), do: false

  defp queue_entries(queue) do
    {:ok, :queue.to_list(queue)}
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp valid_subscribers?(subscribers, last_seq, config) when is_map(subscribers) do
    map_size(subscribers) <= config.max_subscribers_per_run and
      Enum.all?(subscribers, fn
        {pid, %Subscriber{pid: subscriber_pid} = subscriber}
        when is_pid(pid) and subscriber_pid == pid ->
          Subscriber.valid?(subscriber) and subscriber.cursor <= last_seq

        _invalid ->
          false
      end)
  end

  defp valid_subscribers?(_subscribers, _last_seq, _config), do: false

  defp valid_accounting?(record, config) do
    with {:ok, _entries} <- queue_entries(record.replay),
         true <- is_map(record.subscribers),
         projection_bytes <- projection_bytes(record.projection),
         true <- is_integer(projection_bytes) do
      expected =
        Config.run_record_overhead_bytes() + config.max_outgoing_message_bytes +
          byte_size(record.id) + projection_bytes + active_tool_bytes(record.owner_lost_tool) +
          record.replay_bytes +
          map_size(record.subscribers) * Config.subscriber_overhead_bytes()

      record.accounted_bytes == expected and expected <= config.max_active_state_bytes
    else
      _invalid -> false
    end
  end

  defp projection_bytes(%Projection{} = projection) do
    byte_size(projection.text) + optional_binary_bytes(projection.model) +
      active_tool_bytes(projection.active_tool)
  rescue
    _exception -> :error
  end

  defp active_tool_bytes(nil), do: 0

  defp active_tool_bytes(%Synapse.API.ActiveTool{} = tool),
    do: byte_size(tool.operation_id) + byte_size(tool.call_id) + byte_size(tool.name)

  defp optional_binary_bytes(nil), do: 0
  defp optional_binary_bytes(value) when is_binary(value), do: byte_size(value)

  defp positive_int64?(value), do: Validation.int64?(value) and value > 0
  defp counter?(value), do: Validation.int64?(value) and value >= 0
end

defimpl Inspect, for: Synapse.API.PendingTerminal do
  def inspect(%{status: status}, _options) when status in [:completed, :failed, :interrupted],
    do: "#Synapse.API.PendingTerminal<status=#{inspect(status)} redacted>"

  def inspect(_terminal, _options), do: "#Synapse.API.PendingTerminal<invalid redacted>"
end

defimpl Inspect, for: Synapse.API.ActiveTool do
  def inspect(%{turn: turn}, _options)
      when is_integer(turn) and turn > 0 and turn <= 9_223_372_036_854_775_807,
      do: "#Synapse.API.ActiveTool<turn=#{turn} redacted>"

  def inspect(_tool, _options), do: "#Synapse.API.ActiveTool<invalid redacted>"
end

defimpl Inspect, for: Synapse.API.Projection do
  def inspect(%{status: status, turn: turn}, _options)
      when status in [
             :starting,
             :running,
             :cancel_requested,
             :owner_lost,
             :completed,
             :failed,
             :interrupted
           ] and is_integer(turn) and turn >= 0 and turn <= 9_223_372_036_854_775_807,
      do:
        "#Synapse.API.Projection<status=#{inspect(status)} turn=#{turn} text=redacted active_tool=redacted>"

  def inspect(_projection, _options), do: "#Synapse.API.Projection<invalid redacted>"
end

defimpl Inspect, for: Synapse.API.Subscriber do
  def inspect(%{cursor: cursor, notified: notified}, _options)
      when is_integer(cursor) and cursor >= 0 and cursor <= 9_223_372_036_854_775_807 and
             is_boolean(notified),
      do: "#Synapse.API.Subscriber<cursor=#{cursor} notified=#{notified} redacted>"

  def inspect(_subscriber, _options), do: "#Synapse.API.Subscriber<invalid redacted>"
end

defimpl Inspect, for: Synapse.API.ReplayEntry do
  def inspect(%{seq: seq, type: type, encoded_bytes: encoded_bytes}, _options)
      when is_integer(seq) and seq > 0 and seq <= 9_223_372_036_854_775_807 and
             type in [:event, :terminal] and is_integer(encoded_bytes) and encoded_bytes >= 0,
      do:
        "#Synapse.API.ReplayEntry<seq=#{seq} type=#{inspect(type)} encoded_bytes=#{encoded_bytes} encoded=redacted>"

  def inspect(_entry, _options), do: "#Synapse.API.ReplayEntry<invalid redacted>"
end

defimpl Inspect, for: Synapse.API.RunRecord do
  def inspect(%{status: status, last_seq: last_seq}, _options)
      when status in [
             :starting,
             :running,
             :cancel_requested,
             :owner_lost,
             :completed,
             :failed,
             :interrupted
           ] and is_integer(last_seq) and last_seq >= 0 and
             last_seq <= 9_223_372_036_854_775_807,
      do:
        "#Synapse.API.RunRecord<status=#{inspect(status)} last_seq=#{last_seq} id=redacted terminal=redacted replay=redacted subscribers=redacted authority=redacted>"

  def inspect(_record, _options), do: "#Synapse.API.RunRecord<invalid redacted>"
end
