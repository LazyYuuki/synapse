defmodule Synapse.Provider.StreamContext do
  @moduledoc """
  Runtime-owned operation context consumed by a Provider implementation.

  This dependency-inverted contract lets Runtime control request lifetime
  without Provider importing or calling Runtime.

  Fields:

  * `operation_id` correlates events and terminal errors.
  * `cancel_ref` identifies a `{:cancel, cancel_ref}` message sent to the process
    currently executing `Synapse.Provider.Tokamak.stream/3`.
  * `inactivity_ms` bounds time without meaningful provider activity.
  * `deadline` is an absolute `System.monotonic_time(:millisecond)` deadline or
    `:infinity`.
  * `activity_sink` optionally records meaningful activity synchronously.

  Provider transport owns a monitored HTTP worker and terminates it when the
  calling operation process receives the matching cancellation message. A
  `cancel_ref` may be absent for direct contract tests that cannot be cancelled.
  """

  @default_inactivity_ms 120_000
  @maximum_inactivity_ms 900_000

  @enforce_keys [:operation_id]
  defstruct operation_id: nil,
            cancel_ref: nil,
            inactivity_ms: @default_inactivity_ms,
            deadline: :infinity,
            activity_sink: nil

  @typedoc "Runtime-owned request-lifetime controls consumed by one Provider operation."
  @type t :: %__MODULE__{
          operation_id: String.t(),
          cancel_ref: reference() | nil,
          inactivity_ms: pos_integer(),
          deadline: integer() | :infinity,
          activity_sink: (t() -> :ok) | nil
        }

  @typedoc "A validation failure identifying the invalid operation field."
  @type validation_error ::
          {:operation_id, :must_be_non_empty_string}
          | {:cancel_ref, :must_be_reference_or_nil}
          | {:inactivity_ms, :must_be_reasonable_positive_integer}
          | {:deadline, :must_be_monotonic_time_or_infinity}
          | {:activity_sink, :must_be_arity_one_function_or_nil}

  @doc """
  Validates Runtime-supplied operation data and constructs a stream context.

  Construction performs no process or timer side effects. The Provider that
  consumes the context owns deadline, activity, and matching cancellation
  enforcement.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs) when is_list(attrs) or is_map(attrs) do
    attrs = Map.new(attrs)
    operation_id = Map.get(attrs, :operation_id)
    cancel_ref = Map.get(attrs, :cancel_ref)
    inactivity_ms = Map.get(attrs, :inactivity_ms, @default_inactivity_ms)
    deadline = Map.get(attrs, :deadline, :infinity)
    activity_sink = Map.get(attrs, :activity_sink)

    cond do
      not non_empty_string?(operation_id) ->
        {:error, {:operation_id, :must_be_non_empty_string}}

      not (is_nil(cancel_ref) or is_reference(cancel_ref)) ->
        {:error, {:cancel_ref, :must_be_reference_or_nil}}

      not (is_integer(inactivity_ms) and inactivity_ms > 0 and
               inactivity_ms <= @maximum_inactivity_ms) ->
        {:error, {:inactivity_ms, :must_be_reasonable_positive_integer}}

      not (deadline == :infinity or is_integer(deadline)) ->
        {:error, {:deadline, :must_be_monotonic_time_or_infinity}}

      not (is_nil(activity_sink) or is_function(activity_sink, 1)) ->
        {:error, {:activity_sink, :must_be_arity_one_function_or_nil}}

      true ->
        {:ok,
         %__MODULE__{
           operation_id: operation_id,
           cancel_ref: cancel_ref,
           inactivity_ms: inactivity_ms,
           deadline: deadline,
           activity_sink: activity_sink
         }}
    end
  end

  def new(_attrs), do: {:error, {:operation_id, :must_be_non_empty_string}}

  defp non_empty_string?(value),
    do: is_binary(value) and String.valid?(value) and String.trim(value) != ""
end
