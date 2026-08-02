defmodule Synapse.Run.Event do
  @moduledoc """
  Closed union of synchronous Agent run lifecycle observations.

  Agent creates events with `new/2` and sends them to the trusted synchronous
  `Synapse.Agent.Context.event_sink`. Events provide ordered UI-independent
  progress but are not durable records in the MVP: sequence numbers, timestamps,
  persistence, and replay remain Runtime work.

  Every event carries a run ID. Turn and operation events carry their explicit
  identities. Tool completion exposes typed status and allowlisted safe metadata,
  never Tool Result content or arguments. Terminal events carry validated Agent
  Result or Error contracts.

  TextDelta and RunCompleted are content-bearing despite redacted ordinary
  inspection. The trusted event sink must apply its own logging and persistence
  disclosure policy.

  ## Example

      iex> {:ok, event} = Synapse.Run.Event.new(:turn_started, %{
      ...>   run_id: "run-doc",
      ...>   turn: 1,
      ...>   operation_id: "provider-operation-doc"
      ...> })
      iex> event.turn
      1
  """

  alias Synapse.Agent.{Error, Result}
  alias Synapse.Run.Event
  alias Synapse.Tool.Validation

  alias Event.{
    RunCompleted,
    RunFailed,
    RunInterrupted,
    RunStarted,
    TextDelta,
    ToolCompleted,
    ToolStarted,
    TurnCompleted,
    TurnStarted
  }

  @max_run_id_bytes 256
  @max_model_bytes 256
  @max_operation_id_bytes 256
  @max_provider_id_bytes 512
  @max_tool_name_bytes 64
  @max_delta_bytes 64_000
  @max_metadata_bytes 4_096
  @max_metadata_entries 32
  @max_metadata_depth 4
  @max_int 9_223_372_036_854_775_807

  @typedoc "A stable constructor selector for one event struct."
  @type kind ::
          :run_started
          | :turn_started
          | :text_delta
          | :tool_started
          | :tool_completed
          | :turn_completed
          | :run_completed
          | :run_failed
          | :run_interrupted

  @typedoc "The closed set of normalized MVP Run Events."
  @type t ::
          RunStarted.t()
          | TurnStarted.t()
          | TextDelta.t()
          | ToolStarted.t()
          | ToolCompleted.t()
          | TurnCompleted.t()
          | RunCompleted.t()
          | RunFailed.t()
          | RunInterrupted.t()

  @typedoc "A field-specific invalid event or unknown event kind."
  @type validation_error ::
          {:attributes, :must_be_keyword_or_map}
          | {:unknown_fields, [term()]}
          | {atom(), atom()}
          | {:kind, :must_be_known}

  @doc "Validates one exact event shape and constructs its typed struct."
  @spec new(kind(), keyword() | map()) :: {:ok, t()} | {:error, validation_error()}
  def new(kind, attrs)

  def new(:run_started, attrs) do
    with {:ok, attrs} <- attrs(attrs, [:run_id, :model]),
         :ok <- run_id(attrs[:run_id]),
         :ok <- identifier(:model, attrs[:model], @max_model_bytes) do
      {:ok, struct!(RunStarted, attrs)}
    end
  end

  def new(:turn_started, attrs) do
    with {:ok, attrs} <- attrs(attrs, [:run_id, :turn, :operation_id]),
         :ok <- run_id(attrs[:run_id]),
         :ok <- positive(:turn, attrs[:turn]),
         :ok <- operation_id(attrs[:operation_id]) do
      {:ok, struct!(TurnStarted, attrs)}
    end
  end

  def new(:text_delta, attrs) do
    fields = [:run_id, :turn, :operation_id, :item_id, :content_index, :delta]

    with {:ok, attrs} <- attrs(attrs, fields),
         :ok <- run_id(attrs[:run_id]),
         :ok <- positive(:turn, attrs[:turn]),
         :ok <- operation_id(attrs[:operation_id]),
         :ok <- identifier(:item_id, attrs[:item_id], @max_provider_id_bytes),
         :ok <- non_negative(:content_index, attrs[:content_index]),
         :ok <- bounded_utf8(:delta, attrs[:delta], @max_delta_bytes) do
      {:ok, struct!(TextDelta, attrs)}
    end
  end

  def new(:tool_started, attrs) do
    fields = [:run_id, :turn, :operation_id, :call_id, :name, :ordinal]

    with {:ok, attrs} <- attrs(attrs, fields),
         :ok <- tool_base(attrs),
         :ok <- positive(:ordinal, attrs[:ordinal]) do
      {:ok, struct!(ToolStarted, attrs)}
    end
  end

  def new(:tool_completed, attrs) do
    fields = [:run_id, :turn, :operation_id, :call_id, :name, :ordinal, :status, :metadata]

    with {:ok, attrs} <- attrs(attrs, fields),
         :ok <- tool_base(attrs),
         :ok <- positive(:ordinal, attrs[:ordinal]),
         true <-
           attrs[:status] in [:ok, :error, :ambiguous] or
             {:error, {:status, :must_be_tool_result_status}},
         true <-
           safe_metadata?(attrs[:metadata]) or
             {:error, {:metadata, :must_be_bounded_safe_json_object}} do
      {:ok, struct!(ToolCompleted, attrs)}
    end
  end

  def new(:turn_completed, attrs) do
    fields = [:run_id, :turn, :outcome, :provider_attempts, :tool_calls, :output_bytes]

    with {:ok, attrs} <- attrs(attrs, fields),
         :ok <- run_id(attrs[:run_id]),
         :ok <- positive(:turn, attrs[:turn]),
         true <-
           attrs[:outcome] in [:continued, :completed, :failed, :interrupted] or
             {:error, {:outcome, :must_be_known}},
         :ok <- positive(:provider_attempts, attrs[:provider_attempts]),
         :ok <- non_negative(:tool_calls, attrs[:tool_calls]),
         :ok <- non_negative(:output_bytes, attrs[:output_bytes]) do
      {:ok, struct!(TurnCompleted, attrs)}
    end
  end

  def new(:run_completed, attrs) do
    with {:ok, attrs} <- attrs(attrs, [:run_id, :result]),
         :ok <- run_id(attrs[:run_id]),
         {:ok, result} <- normalize_result(attrs[:result]),
         true <- result.run_id == attrs.run_id or {:error, {:result, :run_id_must_match}} do
      {:ok, struct!(RunCompleted, run_id: attrs.run_id, result: result)}
    end
  end

  def new(:run_failed, attrs), do: terminal_error(RunFailed, attrs)
  def new(:run_interrupted, attrs), do: terminal_error(RunInterrupted, attrs)
  def new(_kind, _attrs), do: {:error, {:kind, :must_be_known}}

  defp terminal_error(module, attrs) do
    with {:ok, attrs} <- attrs(attrs, [:run_id, :error]),
         :ok <- run_id(attrs[:run_id]),
         {:ok, error} <- normalize_error(attrs[:error]),
         true <- error.run_id == attrs.run_id or {:error, {:error, :run_id_must_match}} do
      {:ok, struct!(module, run_id: attrs.run_id, error: error)}
    end
  end

  defp normalize_result(%Result{} = result) do
    case Result.new(Map.from_struct(result)) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, _reason} -> {:error, {:result, :must_be_agent_result}}
    end
  end

  defp normalize_result(_result), do: {:error, {:result, :must_be_agent_result}}

  defp normalize_error(%Error{} = error) do
    case Error.new(Map.from_struct(error)) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, _reason} -> {:error, {:error, :must_be_agent_error}}
    end
  end

  defp normalize_error(_error), do: {:error, {:error, :must_be_agent_error}}

  defp tool_base(attrs) do
    with :ok <- run_id(attrs[:run_id]),
         :ok <- positive(:turn, attrs[:turn]),
         :ok <- operation_id(attrs[:operation_id]),
         :ok <- identifier(:call_id, attrs[:call_id], @max_provider_id_bytes),
         :ok <- identifier(:name, attrs[:name], @max_tool_name_bytes) do
      :ok
    end
  end

  defp run_id(value), do: identifier(:run_id, value, @max_run_id_bytes)
  defp operation_id(value), do: identifier(:operation_id, value, @max_operation_id_bytes)

  defp identifier(field, value, maximum) do
    if Validation.identifier?(value, maximum),
      do: :ok,
      else: {:error, {field, :must_be_bounded_non_empty_utf8_identifier}}
  end

  defp bounded_utf8(field, value, maximum) do
    if is_binary(value) and byte_size(value) <= maximum and String.valid?(value),
      do: :ok,
      else: {:error, {field, :must_be_bounded_utf8_string}}
  end

  defp positive(field, value) do
    if is_integer(value) and value > 0 and value <= @max_int,
      do: :ok,
      else: {:error, {field, :must_be_positive_int64}}
  end

  defp non_negative(field, value) do
    if is_integer(value) and value >= 0 and value <= @max_int,
      do: :ok,
      else: {:error, {field, :must_be_non_negative_int64}}
  end

  defp safe_metadata?(metadata),
    do:
      Validation.safe_metadata_object?(
        metadata,
        @max_metadata_bytes,
        @max_metadata_entries,
        @max_metadata_depth
      )

  defp attrs(attrs, allowed), do: Validation.attributes(attrs, allowed)
end

defmodule Synapse.Run.Event.RunStarted do
  @moduledoc "Announces one validated run identity and selected model."
  @enforce_keys [:run_id, :model]
  defstruct @enforce_keys
  @type t :: %__MODULE__{run_id: String.t(), model: String.t()}
end

defmodule Synapse.Run.Event.TurnStarted do
  @moduledoc "Announces one logical turn and its first Provider attempt operation."
  @enforce_keys [:run_id, :turn, :operation_id]
  defstruct @enforce_keys
  @type t :: %__MODULE__{run_id: String.t(), turn: pos_integer(), operation_id: String.t()}
end

defmodule Synapse.Run.Event.TextDelta do
  @moduledoc """
  Carries one ordered, content-bearing Provider text fragment without terminal authority.

  `delta` is arbitrary untrusted model output. Event sinks must not log or persist it
  unless their own disclosure policy explicitly permits that content.
  """
  @enforce_keys [:run_id, :turn, :operation_id, :item_id, :content_index, :delta]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          run_id: String.t(),
          turn: pos_integer(),
          operation_id: String.t(),
          item_id: String.t(),
          content_index: non_neg_integer(),
          delta: String.t()
        }
end

defmodule Synapse.Run.Event.ToolStarted do
  @moduledoc "Announces one admitted Tool immediately before synchronous execution."
  @enforce_keys [:run_id, :turn, :operation_id, :call_id, :name, :ordinal]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          run_id: String.t(),
          turn: pos_integer(),
          operation_id: String.t(),
          call_id: String.t(),
          name: String.t(),
          ordinal: pos_integer()
        }
end

defmodule Synapse.Run.Event.ToolCompleted do
  @moduledoc """
  Reports Agent-produced typed Tool status and bounded local metadata.

  It deliberately contains neither Tool Result content nor model arguments.
  """
  @enforce_keys [:run_id, :turn, :operation_id, :call_id, :name, :ordinal, :status, :metadata]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          run_id: String.t(),
          turn: pos_integer(),
          operation_id: String.t(),
          call_id: String.t(),
          name: String.t(),
          ordinal: pos_integer(),
          status: Synapse.Tool.Result.status(),
          metadata: Synapse.Tool.json_object()
        }
end

defmodule Synapse.Run.Event.TurnCompleted do
  @moduledoc "Closes one logical turn with bounded attempt, call, and output accounting."
  @enforce_keys [:run_id, :turn, :outcome, :provider_attempts, :tool_calls, :output_bytes]
  defstruct @enforce_keys

  @type outcome :: :continued | :completed | :failed | :interrupted
  @type t :: %__MODULE__{
          run_id: String.t(),
          turn: pos_integer(),
          outcome: outcome(),
          provider_attempts: pos_integer(),
          tool_calls: non_neg_integer(),
          output_bytes: non_neg_integer()
        }
end

defmodule Synapse.Run.Event.RunCompleted do
  @moduledoc """
  Carries the validated, content-bearing successful Agent terminal Result.

  Ordinary inspection is redacted, but direct field access exposes final model text
  and the final Provider Response to the trusted event sink.
  """
  @enforce_keys [:run_id, :result]
  defstruct @enforce_keys
  @type t :: %__MODULE__{run_id: String.t(), result: Synapse.Agent.Result.t()}
end

defmodule Synapse.Run.Event.RunFailed do
  @moduledoc "Carries a validated non-interruption Agent terminal Error."
  @enforce_keys [:run_id, :error]
  defstruct @enforce_keys
  @type t :: %__MODULE__{run_id: String.t(), error: Synapse.Agent.Error.t()}
end

defmodule Synapse.Run.Event.RunInterrupted do
  @moduledoc "Carries a validated cancellation, timeout, or partial-output terminal Error."
  @enforce_keys [:run_id, :error]
  defstruct @enforce_keys
  @type t :: %__MODULE__{run_id: String.t(), error: Synapse.Agent.Error.t()}
end

defimpl Inspect, for: Synapse.Run.Event.RunStarted do
  def inspect(_event, _options), do: "#Synapse.Run.Event.RunStarted<redacted>"
end

defimpl Inspect, for: Synapse.Run.Event.TurnStarted do
  def inspect(_event, _options), do: "#Synapse.Run.Event.TurnStarted<redacted>"
end

defimpl Inspect, for: Synapse.Run.Event.TextDelta do
  def inspect(_event, _options), do: "#Synapse.Run.Event.TextDelta<redacted>"
end

defimpl Inspect, for: Synapse.Run.Event.ToolStarted do
  def inspect(_event, _options), do: "#Synapse.Run.Event.ToolStarted<redacted>"
end

defimpl Inspect, for: Synapse.Run.Event.ToolCompleted do
  def inspect(event, _options),
    do: "#Synapse.Run.Event.ToolCompleted<status=#{inspect(event.status)} redacted>"
end

defimpl Inspect, for: Synapse.Run.Event.TurnCompleted do
  def inspect(event, _options),
    do: "#Synapse.Run.Event.TurnCompleted<outcome=#{inspect(event.outcome)} redacted>"
end

defimpl Inspect, for: Synapse.Run.Event.RunCompleted do
  def inspect(_event, _options), do: "#Synapse.Run.Event.RunCompleted<redacted>"
end

defimpl Inspect, for: Synapse.Run.Event.RunFailed do
  def inspect(_event, _options), do: "#Synapse.Run.Event.RunFailed<redacted>"
end

defimpl Inspect, for: Synapse.Run.Event.RunInterrupted do
  def inspect(_event, _options), do: "#Synapse.Run.Event.RunInterrupted<redacted>"
end
