defmodule Synapse.Runtime.Error do
  @moduledoc """
  Sanitized Runtime configuration, availability, and coordinator failure.

  Runtime Error is distinct from `Synapse.Agent.Error`. Before a run is accepted,
  there is no Agent turn or Run Event to classify. After acceptance,
  `:runtime_lost` identifies loss of the outer RunServer, whose event sink and
  lifecycle state no longer exist. Ordinary accepted-run terminals continue to
  use Agent Result/Error.

  Messages are fixed by reason rather than accepted from callers. This prevents a
  raw Workspace error, root, callback failure, coordinator exit reason, or
  stacktrace from entering the public contract accidentally. `run_id` is optional
  because an invalid Run Request has no trusted identity.

  ## Example

      iex> {:ok, error} = Synapse.Runtime.Error.new(
      ...>   reason: :runtime_unavailable,
      ...>   run_id: "run-doc"
      ...> )
      iex> {error.reason, error.message}
      {:runtime_unavailable, "Runtime infrastructure is unavailable"}
  """

  alias Synapse.Tool.Validation

  @max_run_id_bytes 256
  @messages %{
    invalid_run_request: "Run Request is invalid",
    invalid_runtime_options: "Runtime options are invalid",
    runtime_unavailable: "Runtime infrastructure is unavailable",
    runtime_busy: "Runtime is busy",
    workspace_open_failed: "Workspace could not be opened",
    runtime_lost: "Runtime coordinator was lost"
  }

  @enforce_keys [:reason, :message, :run_id]
  defstruct [:reason, :message, :run_id]

  @typedoc "A stable Runtime-owned failure reason."
  @type reason ::
          :invalid_run_request
          | :invalid_runtime_options
          | :runtime_unavailable
          | :runtime_busy
          | :workspace_open_failed
          | :runtime_lost

  @typedoc "A bounded Runtime failure with fixed sanitized prose."
  @type t :: %__MODULE__{
          reason: reason(),
          message: String.t(),
          run_id: String.t() | nil
        }

  @typedoc "A malformed reason, run identity, or attribute collection."
  @type validation_error ::
          {:attributes, :must_be_keyword_or_map}
          | {:unknown_fields, [term()]}
          | {:reason, :must_be_known}
          | {:run_id, :must_be_bounded_identifier_or_nil}

  @doc "Constructs one Runtime Error using fixed prose for the selected reason."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs) do
    with {:ok, attrs} <- Validation.attributes(attrs, [:reason, :run_id]),
         reason <- attrs[:reason],
         true <- Map.has_key?(@messages, reason) or {:error, {:reason, :must_be_known}},
         run_id <- Map.get(attrs, :run_id),
         true <-
           is_nil(run_id) or Validation.identifier?(run_id, @max_run_id_bytes) or
             {:error, {:run_id, :must_be_bounded_identifier_or_nil}} do
      {:ok, %__MODULE__{reason: reason, message: Map.fetch!(@messages, reason), run_id: run_id}}
    end
  end

  @doc "Returns whether an Error struct exactly matches its fixed normalized contract."
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = error) do
    case new(reason: error.reason, run_id: error.run_id) do
      {:ok, normalized} -> normalized == error
      {:error, _reason} -> false
    end
  end

  def valid?(_error), do: false
end

defimpl Inspect, for: Synapse.Runtime.Error do
  def inspect(%{reason: reason}, _options)
      when reason in [
             :invalid_run_request,
             :invalid_runtime_options,
             :runtime_unavailable,
             :runtime_busy,
             :workspace_open_failed,
             :runtime_lost
           ],
      do: "#Synapse.Runtime.Error<reason=#{inspect(reason)} redacted>"

  def inspect(_error, _options), do: "#Synapse.Runtime.Error<invalid redacted>"
end
