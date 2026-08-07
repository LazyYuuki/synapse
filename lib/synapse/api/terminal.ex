defmodule Synapse.API.TerminalError do
  @moduledoc false

  @reason :internal_contract_failed
  @message "Run settlement contract failed"

  @enforce_keys [:reason, :message]
  defstruct @enforce_keys

  @type t :: %__MODULE__{reason: :internal_contract_failed, message: String.t()}

  @spec new() :: t()
  def new, do: %__MODULE__{reason: @reason, message: @message}

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = error), do: error == new()
  def valid?(_error), do: false
end

defmodule Synapse.API.ConfirmedTerminal do
  @moduledoc """
  Bounded terminal value shared by wire encoding and RunManager state.

  A confirmed terminal contains one API run ID, one positive signed-64-bit
  sequence, an authoritative status, and exactly one validated result or error.
  Agent success retains only the five public result fields; Provider
  `final_response` never enters this contract. Runtime and API errors use their
  own closed sanitized structs rather than imitating Agent errors.

  A terminal becomes visible only after RunSession's owner-only await result agrees
  with the pending terminal event. `runtime_lost` is the sole explicit terminal
  whose Runtime cleanup settlement could not be confirmed.

  See the [local API guide](api.html) for terminal sequencing and failure behavior.
  """

  alias Synapse.Agent.Error, as: AgentError
  alias Synapse.API.Command.Cancel
  alias Synapse.API.{Config, PendingTerminal, Policy, TerminalError}
  alias Synapse.Runtime.Error, as: RuntimeError
  alias Synapse.Tool.Validation

  @enforce_keys [:run_id, :seq, :status, :result, :error]
  defstruct @enforce_keys

  @typedoc "The five public Agent result fields retained after terminal confirmation."
  @type result :: %{
          text: String.t(),
          turns: pos_integer(),
          tool_calls: non_neg_integer(),
          provider_retries: non_neg_integer(),
          output_bytes: non_neg_integer()
        }
  @typedoc "The fixed API-owned settlement-contract error fields."
  @type api_error :: %{reason: :internal_contract_failed, message: String.t()}

  @typedoc "The closed Agent, Runtime, or API-owned terminal error union."
  @type error :: AgentError.t() | RuntimeError.t() | api_error()

  @typedoc "A cleanup-gated terminal projection safe for replay and wire encoding."
  @type t :: %__MODULE__{
          run_id: String.t(),
          seq: pos_integer(),
          status: :completed | :failed | :interrupted,
          result: result() | nil,
          error: error() | nil
        }

  @doc "Confirms a compact terminal projection received through the Runtime event sink."
  @spec from_pending(struct(), pos_integer(), Config.t()) ::
          {:ok, t()} | {:error, :invalid_terminal}
  def from_pending(%PendingTerminal{} = pending, seq, %Config{} = config) do
    terminal = %__MODULE__{
      run_id: pending.run_id,
      seq: seq,
      status: pending.status,
      result: pending.result,
      error: pending.error
    }

    if PendingTerminal.valid?(pending, config) and valid?(terminal, config),
      do: {:ok, terminal},
      else: {:error, :invalid_terminal}
  end

  def from_pending(_pending, _seq, _config), do: {:error, :invalid_terminal}

  @doc "Constructs a terminal for one validated Runtime-owned failure."
  @spec from_runtime(String.t(), pos_integer(), RuntimeError.t(), Config.t()) ::
          {:ok, t()} | {:error, :invalid_terminal}
  def from_runtime(run_id, seq, %RuntimeError{} = error, %Config{} = config) do
    status = if error.reason == :runtime_lost, do: :interrupted, else: :failed

    terminal = %__MODULE__{
      run_id: run_id,
      seq: seq,
      status: status,
      result: nil,
      error: error
    }

    if valid?(terminal, config), do: {:ok, terminal}, else: {:error, :invalid_terminal}
  end

  def from_runtime(_run_id, _seq, _error, _config), do: {:error, :invalid_terminal}

  @doc "Constructs the one fixed API-owned settlement-contract terminal."
  @spec internal_contract_failed(String.t(), pos_integer(), Config.t()) ::
          {:ok, t()} | {:error, :invalid_terminal}
  def internal_contract_failed(run_id, seq, %Config{} = config) do
    terminal = %__MODULE__{
      run_id: run_id,
      seq: seq,
      status: :interrupted,
      result: nil,
      error: TerminalError.new()
    }

    if valid?(terminal, config), do: {:ok, terminal}, else: {:error, :invalid_terminal}
  end

  def internal_contract_failed(_run_id, _seq, _config), do: {:error, :invalid_terminal}

  @doc "Returns whether a terminal exactly satisfies one closed source variant."
  @spec valid?(term(), struct()) :: boolean()
  def valid?(%__MODULE__{} = terminal, config) do
    Policy.valid?(config) and Cancel.valid_run_id?(terminal.run_id, config) and
      positive_int64?(terminal.seq) and valid_variant?(terminal, config)
  end

  def valid?(_terminal, _config), do: false

  defp valid_variant?(
         %__MODULE__{status: :completed, result: result, error: nil} = terminal,
         config
       ) do
    pending = %PendingTerminal{
      run_id: terminal.run_id,
      status: :completed,
      result: result,
      error: nil
    }

    PendingTerminal.valid?(pending, config)
  end

  defp valid_variant?(
         %__MODULE__{status: status, result: nil, error: %AgentError{} = error} = terminal,
         config
       )
       when status in [:failed, :interrupted] do
    pending = %PendingTerminal{
      run_id: terminal.run_id,
      status: status,
      result: nil,
      error: error
    }

    PendingTerminal.valid?(pending, config)
  end

  defp valid_variant?(
         %__MODULE__{status: status, result: nil, error: %RuntimeError{} = error} = terminal,
         _config
       ) do
    expected_status = if error.reason == :runtime_lost, do: :interrupted, else: :failed

    status == expected_status and RuntimeError.valid?(error) and
      (is_nil(error.run_id) or error.run_id == terminal.run_id)
  end

  defp valid_variant?(
         %__MODULE__{status: :interrupted, result: nil, error: %TerminalError{} = error},
         _config
       ),
       do: TerminalError.valid?(error)

  defp valid_variant?(_terminal, _config), do: false

  defp positive_int64?(value), do: Validation.int64?(value) and value > 0
end

defimpl Inspect, for: Synapse.API.TerminalError do
  def inspect(%{reason: :internal_contract_failed}, _options),
    do: "#Synapse.API.TerminalError<reason=:internal_contract_failed redacted>"

  def inspect(_error, _options), do: "#Synapse.API.TerminalError<invalid redacted>"
end

defimpl Inspect, for: Synapse.API.ConfirmedTerminal do
  def inspect(%{status: status, seq: seq}, _options)
      when status in [:completed, :failed, :interrupted] and is_integer(seq) and seq > 0 and
             seq <= 9_223_372_036_854_775_807,
      do: "#Synapse.API.ConfirmedTerminal<status=#{inspect(status)} seq=#{seq} redacted>"

  def inspect(_terminal, _options), do: "#Synapse.API.ConfirmedTerminal<invalid redacted>"
end
