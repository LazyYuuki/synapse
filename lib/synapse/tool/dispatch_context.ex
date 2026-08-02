defmodule Synapse.Tool.DispatchContext do
  @moduledoc """
  Executor-owned authority retained around pure Tool callbacks.

  This opaque redacted value combines the authenticated Workspace Handle, one
  exact reduced OperationContext, and trusted Tool Limits. `Context.authorize/2`
  constructs it for Executor; built-in adapters never receive it. It is documented
  for boundary maintenance and is not an application extension API.
  """

  alias Synapse.Tool.{Limits, Validation}
  alias Synapse.Workspace.{Access, Handle, OperationContext}
  alias Synapse.Workspace.Limits, as: WorkspaceLimits

  @enforce_keys [:workspace, :operation_context, :limits]
  defstruct [:workspace, :operation_context, :limits]

  @typedoc "Opaque Executor-owned authority whose fields are outside the supported application contract."
  @opaque t :: %__MODULE__{
            workspace: Handle.t(),
            operation_context: OperationContext.t(),
            limits: Limits.t()
          }

  @doc "Validates the Executor-owned Handle, reduced operation authority, and limits."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, :invalid_dispatch_context}
  def new(attrs) do
    with {:ok, attrs} <-
           Validation.attributes(attrs, [:workspace, :operation_context, :limits]),
         true <- valid_workspace?(attrs[:workspace]),
         {:ok, limits} <- normalize_limits(attrs[:limits]),
         true <- limits_fit_workspace?(limits, attrs.workspace.limits),
         {:ok, operation_context} <-
           normalize_operation_context(attrs[:operation_context], attrs.workspace.limits),
         true <- Access.within?(operation_context.access, attrs.workspace.access),
         true <- reduced_access?(operation_context.access) do
      {:ok,
       %__MODULE__{
         workspace: attrs.workspace,
         operation_context: operation_context,
         limits: limits
       }}
    else
      _invalid -> {:error, :invalid_dispatch_context}
    end
  end

  defp valid_workspace?(%Handle{
         backend: backend,
         state: state,
         token: token,
         limits: limits,
         access: access
       }) do
    is_atom(backend) and (is_pid(state) or is_reference(state)) and is_reference(token) and
      WorkspaceLimits.valid?(limits) and Access.valid?(access)
  end

  defp valid_workspace?(_workspace), do: false

  defp normalize_limits(%Limits{} = limits) do
    case Limits.new(Map.from_struct(limits)) do
      {:ok, limits} -> {:ok, limits}
      {:error, _reason} -> {:error, :invalid_limits}
    end
  end

  defp normalize_limits(_limits), do: {:error, :invalid_limits}

  defp normalize_operation_context(%OperationContext{} = context, workspace_limits),
    do: OperationContext.new(Map.from_struct(context), workspace_limits)

  defp normalize_operation_context(_context, _workspace_limits),
    do: {:error, :invalid_operation_context}

  defp reduced_access?(%Access{read: read, write: write, exec: exec}) do
    Enum.count([read, write, exec], & &1) <= 1
  end

  defp limits_fit_workspace?(tool, workspace) do
    tool.max_operation_id_bytes <= workspace.max_operation_id_bytes and
      tool.max_path_bytes <= workspace.max_path_bytes and
      tool.default_read_lines <= workspace.default_read_lines and
      tool.max_read_lines <= workspace.max_read_lines and
      tool.default_read_source_bytes <= workspace.default_read_bytes and
      tool.max_read_source_bytes <= workspace.max_read_bytes and
      tool.default_bash_output_bytes <= workspace.default_process_output_bytes and
      tool.max_bash_output_bytes <= workspace.max_process_output_bytes and
      tool.default_bash_timeout_ms <= workspace.default_process_timeout_ms and
      tool.max_bash_timeout_ms <= workspace.max_process_timeout_ms and
      tool.default_bash_inactivity_ms <= workspace.default_process_inactivity_ms and
      tool.max_bash_inactivity_ms <= workspace.max_process_inactivity_ms
  end
end

defimpl Inspect, for: Synapse.Tool.DispatchContext do
  def inspect(_context, _options), do: "#Synapse.Tool.DispatchContext<redacted>"
end
