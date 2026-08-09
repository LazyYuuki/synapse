defmodule Synapse.Agent.State do
  @moduledoc """
  Immutable in-memory state owned by the process executing Agent Runner.

  State contains the validated Run Request, ordered normalized Provider input,
  aggregate accounting counters, monotonic start/deadline values, and one terminal status.
  Provider event callbacks may emit observations but never mutate State.

  Projection constructs initial `:running` state with zero counters. State computes
  the effective absolute deadline from Runtime's supplied `deadline`. Pure transition
  functions accept supplied monotonic timestamps, use checked signed 64-bit
  arithmetic, and return new values only at explicit operation boundaries.

  Runner-owned snapshots use `status: :running`; successful and failed terminal
  authority lives in Agent Result/Error. Reserved terminal status sentinels are
  rejected by every transition and projection so they cannot be continued.
  """

  alias Synapse.Provider.Request, as: ProviderRequest
  alias Synapse.Run.Request
  alias Synapse.Tool.Validation

  @allowed_fields [:run, :input_items, :started_at, :deadline]

  @enforce_keys [
    :run,
    :input_items,
    :turn,
    :tool_calls,
    :provider_retries,
    :output_bytes,
    :started_at,
    :deadline,
    :status
  ]
  defstruct @enforce_keys

  @typedoc "A running or terminal state classification."
  @type status :: :running | :completed | :failed | :interrupted

  @typedoc "One immutable state snapshot in the Runner-owned lineage."
  @type t :: %__MODULE__{
          run: Request.t(),
          input_items: [Synapse.Provider.json_object()],
          turn: non_neg_integer(),
          tool_calls: non_neg_integer(),
          provider_retries: non_neg_integer(),
          output_bytes: non_neg_integer(),
          started_at: integer(),
          deadline: integer(),
          status: status()
        }

  @typedoc "An invalid initial State dependency."
  @type validation_error ::
          {:attributes, :must_be_keyword_or_map}
          | {:unknown_fields, [term()]}
          | {:run, :must_be_run_request}
          | {:input_items, :must_be_non_empty_provider_input}
          | {:started_at, :must_be_monotonic_time}
          | {:deadline, :must_be_monotonic_time_or_infinity}
          | {:deadline, :wall_time_addition_overflow}

  @typedoc "A rejected pure counter or deadline transition."
  @type transition_error ::
          :invalid_state
          | :invalid_timestamp
          | :counter_overflow
          | :wall_time_budget_exhausted

  @doc "Constructs initial running State with zero counters and validated input."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs) do
    with {:ok, attrs} <- Validation.attributes(attrs, @allowed_fields),
         {:ok, run} <- normalize_run(attrs[:run]),
         {:ok, input_items} <- normalize_input(attrs[:input_items], run.model),
         true <-
           Validation.int64?(attrs[:started_at]) or
             {:error, {:started_at, :must_be_monotonic_time}},
         deadline <- attrs[:deadline],
         true <-
           deadline == :infinity or Validation.int64?(deadline) or
             {:error, {:deadline, :must_be_monotonic_time_or_infinity}} do
      {:ok,
       %__MODULE__{
         run: run,
         input_items: input_items,
         turn: 0,
         tool_calls: 0,
         provider_retries: 0,
         output_bytes: 0,
         started_at: attrs.started_at,
         deadline: deadline,
         status: :running
       }}
    end
  end

  @doc "Admits one logical turn before its initial Provider operation."
  @spec admit_turn(t(), integer()) :: {:ok, t()} | {:error, transition_error()}
  def admit_turn(state, now) do
    with :ok <- valid_transition(state, now),
         :ok <- before_deadline(state, now),
         {:ok, turn} <- checked_increment(state.turn) do
      {:ok, %{state | turn: turn}}
    end
  end

  @doc "Admits one Tool execution and increments the aggregate call counter."
  @spec admit_tool(t(), integer()) :: {:ok, t()} | {:error, transition_error()}
  def admit_tool(state, now) do
    with :ok <- valid_transition(state, now),
         :ok <- before_deadline(state, now),
         {:ok, tool_calls} <- checked_increment(state.tool_calls) do
      {:ok, %{state | tool_calls: tool_calls}}
    end
  end

  @doc "Records one additional Provider attempt without incrementing the logical turn."
  @spec admit_provider_retry(t(), integer()) :: {:ok, t()} | {:error, transition_error()}
  def admit_provider_retry(state, now) do
    with :ok <- valid_transition(state, now),
         :ok <- before_deadline(state, now),
         {:ok, retries} <- checked_increment(state.provider_retries) do
      {:ok, %{state | provider_retries: retries}}
    end
  end

  @doc "Adds complete normalized model-visible bytes to aggregate output accounting."
  @spec add_output(t(), non_neg_integer()) :: {:ok, t()} | {:error, transition_error()}
  def add_output(state, bytes) do
    with :ok <- valid_state(state),
         true <-
           (is_integer(bytes) and bytes >= 0) or {:error, :counter_overflow},
         {:ok, output_bytes} <- checked_add(state.output_bytes, bytes) do
      {:ok, %{state | output_bytes: output_bytes}}
    end
  end

  @doc "Returns whether a supplied monotonic timestamp remains before the effective deadline."
  @spec deadline_open?(t(), integer()) :: boolean()
  def deadline_open?(state, now),
    do: match?(:ok, valid_transition(state, now)) and match?(:ok, before_deadline(state, now))

  defp normalize_run(%Request{} = run) do
    case Request.new(Map.from_struct(run)) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, _reason} -> {:error, {:run, :must_be_run_request}}
    end
  end

  defp normalize_run(_run), do: {:error, {:run, :must_be_run_request}}

  defp normalize_input(input_items, model) when is_list(input_items) and input_items != [] do
    case ProviderRequest.new(model: model, input_items: input_items) do
      {:ok, request} -> {:ok, request.input_items}
      {:error, _reason} -> {:error, {:input_items, :must_be_non_empty_provider_input}}
    end
  end

  defp normalize_input(_input_items, _model),
    do: {:error, {:input_items, :must_be_non_empty_provider_input}}

  defp valid_transition(state, now) do
    with :ok <- valid_state(state),
         true <- Validation.int64?(now) or {:error, :invalid_timestamp} do
      :ok
    end
  end

  defp valid_state(%__MODULE__{status: :running} = state) do
    if Request.valid?(state.run) and valid_input_state?(state) and valid_counters?(state) and
         Validation.int64?(state.started_at) and
         (state.deadline == :infinity or Validation.int64?(state.deadline)),
       do: :ok,
       else: {:error, :invalid_state}
  end

  defp valid_state(_state), do: {:error, :invalid_state}

  defp valid_input_state?(state),
    do: match?({:ok, _input_items}, normalize_input(state.input_items, state.run.model))

  defp valid_counters?(state) do
    counter?(state.turn) and counter?(state.tool_calls) and counter?(state.provider_retries) and
      counter?(state.output_bytes)
  end

  defp counter?(value), do: is_integer(value) and value >= 0 and Validation.int64?(value)

  defp before_deadline(%{deadline: :infinity}, _now), do: :ok

  defp before_deadline(state, now) do
    if now < state.deadline,
      do: :ok,
      else: {:error, :wall_time_budget_exhausted}
  end

  defp checked_increment(value), do: checked_add(value, 1)

  defp checked_add(left, right) do
    value = left + right

    if Validation.int64?(value), do: {:ok, value}, else: {:error, :counter_overflow}
  end
end

defimpl Inspect, for: Synapse.Agent.State do
  def inspect(state, _options),
    do: "#Synapse.Agent.State<status=#{inspect(state.status)} redacted>"
end
