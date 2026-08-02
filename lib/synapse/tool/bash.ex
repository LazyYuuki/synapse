defmodule Synapse.Tool.Bash do
  @moduledoc """
  Implements one bounded model-facing Bash command.

  Bash accepts shell source and a nullable lowered total timeout. Preparation
  revalidates the complete Call, normalizes a null timeout to trusted policy, and
  fixes `/bin/bash -lc`, workspace cwd, inactivity/output limits, and unknown
  mutation footprint in one `Workspace.ProcessSpec`. The adapter receives no
  Handle and starts no process; Executor's static Dispatcher alone calls Workspace
  with an exec-only OperationContext and a synchronous payload-discarding event
  sink. Same-user execution is not a sandbox.

  Natural exit zero is success and natural non-zero exit is a known completed
  error. Cancellation or another forced stop after start is ambiguous because the
  command may have mutated state. Executor never retries Bash. See
  `docs/learning/TOOL-SYSTEM.md`.
  """

  @behaviour Synapse.Tool

  alias Synapse.Tool.{Call, Limits, Presentation, Spec}
  alias Synapse.Workspace.ProcessSpec
  alias Synapse.Workspace.Limits, as: WorkspaceLimits

  @argument_names ~w(command timeout_ms)

  {:ok, specification} =
    Spec.new(%{
      name: "bash",
      description:
        "Run one bounded Bash command from the workspace root. This is same-user execution, not a sandbox.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "command" => %{
            "type" => "string",
            "description" => "Bash source passed to /bin/bash -lc."
          },
          "timeout_ms" => %{
            "type" => ["integer", "null"],
            "minimum" => 1,
            "maximum" => 900_000,
            "description" => "Lower total timeout, or null for the trusted default."
          }
        },
        "required" => @argument_names,
        "additionalProperties" => false
      },
      capability: :process_exec,
      effect: :unknown
    })

  @specification specification

  @impl true
  @doc "Returns the immutable strict Bash specification used by the static Registry."
  @spec specification() :: Spec.t()
  def specification, do: @specification

  @impl true
  @doc "Validates model arguments and prepares one fixed unknown-footprint Bash process."
  @spec prepare(Call.t(), Limits.t()) ::
          {:ok, ProcessSpec.t()} | {:error, :invalid_arguments}
  def prepare(
        %Call{
          name: "bash",
          arguments: %{"command" => command, "timeout_ms" => timeout_ms} = arguments
        } = call,
        %Limits{} = limits
      )
      when map_size(arguments) == 2 do
    with {:ok, limits} <- Limits.new(Map.from_struct(limits)),
         {:ok, _call} <- Call.new(Map.from_struct(call), limits),
         true <- valid_command?(command),
         {:ok, timeout_ms} <- timeout(timeout_ms, limits),
         {:ok, _normalized_call} <-
           Call.new(
             Map.from_struct(%{
               call
               | arguments: %{"command" => command, "timeout_ms" => timeout_ms}
             }),
             limits
           ),
         {:ok, spec} <-
           ProcessSpec.new(
             [
               executable: "/bin/bash",
               arguments: ["-lc", command],
               cwd: ".",
               inactivity_ms: limits.default_bash_inactivity_ms,
               timeout_ms: timeout_ms,
               max_output_bytes: limits.default_bash_output_bytes,
               mutation: :unknown
             ],
             WorkspaceLimits.default()
           ) do
      {:ok, spec}
    else
      _invalid -> {:error, :invalid_arguments}
    end
  end

  def prepare(_call, _limits), do: {:error, :invalid_arguments}

  @impl true
  @doc "Presents one retained Workspace process outcome as bounded repaired JSON."
  @spec present(Call.t(), Synapse.Tool.workspace_outcome(), Limits.t()) ::
          Synapse.Tool.Result.t()
  def present(%Call{call_id: call_id}, outcome, %Limits{} = limits),
    do: Presentation.bash(call_id, outcome, limits)

  defp valid_command?(command),
    do:
      is_binary(command) and command != "" and String.valid?(command) and
        not contains_nul?(command)

  defp timeout(nil, limits), do: {:ok, limits.default_bash_timeout_ms}

  defp timeout(timeout_ms, limits)
       when is_integer(timeout_ms) and timeout_ms > 0 and
              timeout_ms <= limits.default_bash_timeout_ms,
       do: {:ok, timeout_ms}

  defp timeout(_timeout_ms, _limits), do: {:error, :invalid_timeout}

  defp contains_nul?(value), do: :binary.match(value, <<0>>) != :nomatch
end
