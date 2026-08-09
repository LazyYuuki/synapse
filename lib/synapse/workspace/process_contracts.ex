defmodule Synapse.Workspace.ProcessSpec do
  @moduledoc """
  A bounded external command specification consumed by ProcessRunner.

  Tool or another trusted caller selects an absolute executable and passes
  arguments separately. Workspace performs no implicit shell parsing. Model-facing
  Bash explicitly maps to `/bin/bash`, `-lc`, and `mutation: :unknown`.

  `timeout_ms` bounds total execution. `inactivity_ms` independently bounds the
  interval between accepted output events. Process existence alone is not
  meaningful activity. `max_output_bytes` bounds only the retained prefix exposed
  to callers; additional output is acknowledged and discarded without stopping
  the process, and the terminal Result records `truncated: true`.
  """

  alias Synapse.Workspace.{Limits, Validation}

  @enforce_keys [
    :executable,
    :arguments,
    :cwd,
    :inactivity_ms,
    :timeout_ms,
    :max_output_bytes,
    :mutation
  ]
  defstruct @enforce_keys

  @typedoc "Trusted coordination declaration; `:read_only` is not OS-enforced."
  @type mutation :: :read_only | :unknown

  @typedoc "An absolute executable, argv, relative cwd, and lowered process limits."
  @type t :: %__MODULE__{
          executable: String.t(),
          arguments: [String.t()],
          cwd: String.t(),
          inactivity_ms: pos_integer(),
          timeout_ms: pos_integer(),
          max_output_bytes: pos_integer(),
          mutation: mutation()
        }

  @typedoc "A field-specific invalid command specification."
  @type validation_error :: {atom(), atom()} | {:unknown_fields, [term()]}

  @doc "Validates command shape and lowered limits without starting a process."
  @spec new(keyword() | map(), Limits.t()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs, limits \\ Limits.default()) do
    allowed = @enforce_keys

    with {:ok, attrs} <- Validation.attributes(attrs, allowed),
         arguments <- Map.get(attrs, :arguments, []),
         cwd <- Map.get(attrs, :cwd, "."),
         inactivity_ms <-
           Map.get(attrs, :inactivity_ms, limits.default_process_inactivity_ms),
         timeout_ms <- Map.get(attrs, :timeout_ms, limits.default_process_timeout_ms),
         max_output_bytes <-
           Map.get(attrs, :max_output_bytes, limits.default_process_output_bytes),
         mutation <- Map.get(attrs, :mutation, :unknown),
         true <-
           valid_executable?(attrs[:executable], limits) or
             {:error, {:executable, :must_be_bounded_absolute_path}},
         true <-
           valid_arguments?(arguments, limits) or
             {:error, {:arguments, :must_be_bounded_utf8_arguments}},
         true <-
           Validation.relative_path?(cwd, limits.max_path_bytes, allow_dot: true) or
             {:error, {:cwd, :must_be_bounded_relative_path}},
         true <-
           within?(inactivity_ms, limits.max_process_inactivity_ms) or
             {:error, {:inactivity_ms, :must_be_within_workspace_limit}},
         true <-
           within?(timeout_ms, limits.max_process_timeout_ms) or
             {:error, {:timeout_ms, :must_be_within_workspace_limit}},
         true <-
           within?(max_output_bytes, limits.max_process_output_bytes) or
             {:error, {:max_output_bytes, :must_be_within_workspace_limit}},
         true <-
           mutation in [:read_only, :unknown] or
             {:error, {:mutation, :must_be_known}} do
      {:ok,
       %__MODULE__{
         executable: attrs.executable,
         arguments: arguments,
         cwd: cwd,
         inactivity_ms: inactivity_ms,
         timeout_ms: timeout_ms,
         max_output_bytes: max_output_bytes,
         mutation: mutation
       }}
    end
  end

  defp valid_executable?(executable, limits) do
    Validation.bounded_string?(executable, limits.max_path_bytes, false) and
      :binary.match(executable, <<0>>) == :nomatch and Path.type(executable) == :absolute
  end

  defp valid_arguments?(arguments, limits) when is_list(arguments) do
    Validation.bounded_proper_list?(arguments, limits.max_process_arguments) and
      Enum.all?(arguments, fn argument ->
        Validation.bounded_string?(argument, limits.max_process_argument_bytes) and
          :binary.match(argument, <<0>>) == :nomatch
      end) and
      Enum.reduce(arguments, 0, &(byte_size(&1) + &2)) <= limits.max_process_argument_bytes
  end

  defp valid_arguments?(_arguments, _limits), do: false
  defp within?(value, maximum), do: is_integer(value) and value > 0 and value <= maximum
end

defmodule Synapse.Workspace.ProcessEvent do
  @moduledoc """
  Ordered bounded progress emitted by a Workspace process operation.

  ProcessRunner creates events and synchronously sends them to Tool or another
  caller. Events are non-terminal; `ProcessResult` or `Workspace.Error` remains
  authoritative. Output payloads are arbitrary untrusted bounded binaries and may
  contain secrets, project content, or absolute host paths. Workspace does not
  sanitize or redact them.
  """

  alias Synapse.Workspace.ProcessEvent.{Output, Started}

  @typedoc "The closed MVP process-event union."
  @type t :: Started.t() | Output.t()
end

defmodule Synapse.Workspace.ProcessEvent.Started do
  @moduledoc """
  Announces that ProcessRunner started the owned MuonTrap-wrapped command.

  Workspace emits this before every output event. The operation ID is bounded
  correlation data and contains no executable, argv, cwd, or environment.
  """

  alias Synapse.Workspace.{Limits, Validation}

  @enforce_keys [:operation_id]
  defstruct [:operation_id]

  @typedoc "The first event from one successfully started owned command."
  @type t :: %__MODULE__{operation_id: String.t()}

  @typedoc "A field-specific invalid start event."
  @type validation_error :: {atom(), atom()} | {:unknown_fields, [term()]}

  @doc "Validates one Workspace-produced start event."
  @spec new(keyword() | map(), Limits.t()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs, limits \\ Limits.default()) do
    with {:ok, attrs} <- Validation.attributes(attrs, [:operation_id]),
         true <-
           Validation.bounded_string?(
             attrs[:operation_id],
             limits.max_operation_id_bytes,
             false
           ) or {:error, {:operation_id, :must_be_bounded_non_empty_string}} do
      {:ok, struct!(__MODULE__, attrs)}
    end
  end
end

defmodule Synapse.Workspace.ProcessEvent.Output do
  @moduledoc """
  One ordered arbitrary-binary output chunk from an owned command.

  `sequence` is monotonic within one operation. Workspace counts raw bytes before
  any Tool-level UTF-8 replacement, escaping, redaction, or presentation.
  """

  alias Synapse.Workspace.{Limits, Validation}

  @enforce_keys [:operation_id, :sequence, :data]
  defstruct [:operation_id, :sequence, :data]

  @typedoc "A bounded raw command-output observation."
  @type t :: %__MODULE__{
          operation_id: String.t(),
          sequence: pos_integer(),
          data: binary()
        }

  @typedoc "A field-specific invalid output event."
  @type validation_error :: {atom(), atom()} | {:unknown_fields, [term()]}

  @doc "Validates one Workspace-produced raw output event and chunk ceiling."
  @spec new(keyword() | map(), Limits.t()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs, limits \\ Limits.default()) do
    allowed = [:operation_id, :sequence, :data]

    with {:ok, attrs} <- Validation.attributes(attrs, allowed),
         true <-
           Validation.bounded_string?(
             attrs[:operation_id],
             limits.max_operation_id_bytes,
             false
           ) or {:error, {:operation_id, :must_be_bounded_non_empty_string}},
         true <-
           Validation.positive_int64?(attrs[:sequence]) or
             {:error, {:sequence, :must_be_positive_integer}},
         true <-
           (is_binary(attrs[:data]) and attrs.data != "" and
              byte_size(attrs.data) <= limits.max_process_event_bytes) or
             {:error, {:data, :must_be_bounded_binary}} do
      {:ok, struct!(__MODULE__, attrs)}
    end
  end
end

defmodule Synapse.Workspace.ProcessResult do
  @moduledoc """
  The known terminal observation of one owned external command.

  Non-zero exit remains a successful observation. Read-only cancellation and
  timeout may also use this contract. Retained-output truncation preserves the
  natural exit and sets `truncated: true`. Forced stop of an unknown-footprint
  command is instead an ambiguous Workspace Error. Output remains raw untrusted
  child data and may contain sensitive content or host paths.
  """

  alias Synapse.Workspace.{Limits, Validation}

  @enforce_keys [
    :operation_id,
    :termination,
    :exit_code,
    :output,
    :output_bytes,
    :truncated,
    :elapsed_ms
  ]
  defstruct @enforce_keys

  @typedoc "A known process termination class."
  @type termination :: :exited | :cancelled | :timed_out | :output_limit

  @typedoc "A bounded retained output and known process outcome."
  @type t :: %__MODULE__{
          operation_id: String.t(),
          termination: termination(),
          exit_code: non_neg_integer() | nil,
          output: binary(),
          output_bytes: non_neg_integer(),
          truncated: boolean(),
          elapsed_ms: non_neg_integer()
        }

  @typedoc "A field-specific invalid process result."
  @type validation_error :: {atom(), atom()} | {:unknown_fields, [term()]}

  @doc "Validates one Workspace-produced process result and raw output accounting."
  @spec new(keyword() | map(), Limits.t()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs, limits \\ Limits.default()) do
    with {:ok, attrs} <- Validation.attributes(attrs, @enforce_keys),
         true <-
           Validation.bounded_string?(
             attrs[:operation_id],
             limits.max_operation_id_bytes,
             false
           ) or {:error, {:operation_id, :must_be_bounded_non_empty_string}},
         true <-
           attrs[:termination] in [:exited, :cancelled, :timed_out, :output_limit] or
             {:error, {:termination, :must_be_known}},
         true <-
           valid_exit_code?(attrs[:termination], attrs[:exit_code]) or
             {:error, {:exit_code, :must_match_termination}},
         true <-
           (is_binary(attrs[:output]) and
              byte_size(attrs.output) <= limits.max_process_output_bytes) or
             {:error, {:output, :must_be_bounded_binary}},
         true <-
           valid_output_bytes?(attrs[:output_bytes], limits) or
             {:error, {:output_bytes, :must_be_bounded_non_negative_integer}},
         true <-
           attrs.output_bytes >= byte_size(attrs.output) or
             {:error, {:output_bytes, :must_cover_retained_output}},
         true <- is_boolean(attrs[:truncated]) or {:error, {:truncated, :must_be_boolean}},
         true <- valid_truncation?(attrs) or {:error, {:truncated, :must_match_output}},
         true <-
           (is_integer(attrs[:elapsed_ms]) and attrs.elapsed_ms >= 0 and
              attrs.elapsed_ms <= limits.max_process_timeout_ms + 2 * limits.kill_grace_ms) or
             {:error, {:elapsed_ms, :must_be_bounded_non_negative_integer}} do
      {:ok, struct!(__MODULE__, attrs)}
    end
  end

  defp valid_exit_code?(:exited, code), do: is_integer(code) and code in 0..255
  defp valid_exit_code?(_termination, nil), do: true
  defp valid_exit_code?(_termination, _code), do: false

  defp valid_output_bytes?(bytes, limits) do
    Validation.non_negative_int64?(bytes) and
      bytes <= limits.max_process_output_bytes + limits.max_process_event_bytes
  end

  defp valid_truncation?(%{truncated: true, output_bytes: bytes, output: output}),
    do: bytes > byte_size(output)

  defp valid_truncation?(%{termination: :output_limit}), do: false

  defp valid_truncation?(%{truncated: false, output_bytes: bytes, output: output}),
    do: bytes == byte_size(output)
end
