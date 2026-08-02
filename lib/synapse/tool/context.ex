defmodule Synapse.Tool.Context do
  @moduledoc """
  Trusted authority and lifetime data for one Tool call.

  Agent or Runtime creates Context independently of model arguments. It carries
  one opaque Workspace Handle, fixed Tool capabilities, a separate bounded
  Workspace operation ID, cancellation and deadline data, a synchronous activity
  sink, and lowered Tool limits. Executor authorizes these values into an internal
  dispatch context containing the exact `Synapse.Workspace.OperationContext` for
  the selected Tool. That dispatch context is never passed to a Tool adapter.

  Construction structurally checks the opaque Handle without calling or
  authenticating its backend. Workspace remains authoritative at execution time.
  Tool limits must fit the Handle's Workspace ceilings, but capabilities are not
  required to match Handle Access here; their effective intersection is enforced
  by Executor and Workspace as defense in depth.
  """

  alias Synapse.Tool.{CapabilitySet, DispatchContext, Limits, Validation}
  alias Synapse.Workspace.{Access, Handle}
  alias Synapse.Workspace.Limits, as: WorkspaceLimits
  alias Synapse.Workspace.OperationContext

  @enforce_keys [:workspace, :capabilities, :operation_id, :limits]
  defstruct workspace: nil,
            capabilities: nil,
            operation_id: nil,
            cancel_ref: nil,
            deadline: :infinity,
            activity_sink: nil,
            limits: nil

  @typedoc "A synchronous meaningful-activity callback later passed to Workspace."
  @type activity_sink :: (OperationContext.t() -> :ok)

  @typedoc "Trusted workspace, authority, lifetime, and resource policy."
  @type t :: %__MODULE__{
          workspace: Handle.t(),
          capabilities: CapabilitySet.t(),
          operation_id: String.t(),
          cancel_ref: reference() | nil,
          deadline: integer() | :infinity,
          activity_sink: activity_sink() | nil,
          limits: Limits.t()
        }

  @typedoc "A field-specific invalid trusted Tool Context."
  @type validation_error ::
          {:attributes, :must_be_keyword_or_map}
          | {:unknown_fields, [term()]}
          | {:workspace, :must_be_workspace_handle}
          | {:capabilities, :must_be_tool_capability_set}
          | {:operation_id, :must_be_bounded_non_empty_utf8_identifier}
          | {:cancel_ref, :must_be_reference_or_nil}
          | {:deadline, :must_be_monotonic_time_or_infinity}
          | {:activity_sink, :must_be_arity_one_function_or_nil}
          | {:limits, :must_be_tool_limits}
          | {:limits, :must_fit_workspace_limits}

  @doc "Validates trusted Context shape without invoking Workspace or starting timers."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs) do
    allowed = [
      :workspace,
      :capabilities,
      :operation_id,
      :cancel_ref,
      :deadline,
      :activity_sink,
      :limits
    ]

    with {:ok, attrs} <- Validation.attributes(attrs, allowed),
         {:ok, workspace} <- normalize_workspace(attrs[:workspace]),
         {:ok, capabilities} <- normalize_capabilities(attrs[:capabilities]),
         {:ok, limits} <- normalize_limits(attrs[:limits]),
         true <-
           limits_fit_workspace?(limits, workspace.limits) or
             {:error, {:limits, :must_fit_workspace_limits}},
         true <-
           Validation.identifier?(attrs[:operation_id], limits.max_operation_id_bytes) or
             {:error, {:operation_id, :must_be_bounded_non_empty_utf8_identifier}},
         true <-
           is_nil(attrs[:cancel_ref]) or is_reference(attrs[:cancel_ref]) or
             {:error, {:cancel_ref, :must_be_reference_or_nil}},
         deadline <- Map.get(attrs, :deadline, :infinity),
         true <-
           deadline == :infinity or Validation.int64?(deadline) or
             {:error, {:deadline, :must_be_monotonic_time_or_infinity}},
         activity_sink <- Map.get(attrs, :activity_sink),
         true <-
           is_nil(activity_sink) or is_function(activity_sink, 1) or
             {:error, {:activity_sink, :must_be_arity_one_function_or_nil}} do
      {:ok,
       %__MODULE__{
         workspace: workspace,
         capabilities: capabilities,
         operation_id: attrs.operation_id,
         cancel_ref: Map.get(attrs, :cancel_ref),
         deadline: deadline,
         activity_sink: activity_sink,
         limits: limits
       }}
    end
  end

  @doc """
  Authorizes one trusted Context for a fixed registered capability.

  This is an Executor-owned internal seam, not an application extension API. It
  revalidates Context, checks CapabilitySet, derives an exact reduced Workspace
  Access value, and returns a redacted DispatchContext. Model data cannot call it
  or supply capability/Handle authority.
  """
  @spec authorize(t(), Synapse.Tool.Spec.capability()) ::
          {:ok, DispatchContext.t()} | {:error, :invalid_context | :capability_denied}
  def authorize(context, capability) do
    with {:ok, context} <- normalize_context(context),
         true <-
           CapabilitySet.allows?(context.capabilities, capability) or
             {:error, :capability_denied},
         {:ok, access} <- reduced_access(context.workspace.access, capability),
         {:ok, operation_context} <-
           OperationContext.new(
             %{
               operation_id: context.operation_id,
               access: access,
               cancel_ref: context.cancel_ref,
               deadline: context.deadline,
               activity_sink: context.activity_sink
             },
             context.workspace.limits
           ),
         {:ok, dispatch_context} <-
           DispatchContext.new(
             workspace: context.workspace,
             operation_context: operation_context,
             limits: context.limits
           ) do
      {:ok, dispatch_context}
    else
      {:error, :capability_denied} = error -> error
      _invalid -> {:error, :invalid_context}
    end
  end

  defp normalize_workspace(
         %Handle{
           backend: backend,
           state: state,
           token: token,
           limits: limits,
           access: access
         } = workspace
       ) do
    if is_atom(backend) and (is_pid(state) or is_reference(state)) and is_reference(token) and
         WorkspaceLimits.valid?(limits) and Access.valid?(access),
       do: {:ok, workspace},
       else: {:error, {:workspace, :must_be_workspace_handle}}
  end

  defp normalize_workspace(_workspace), do: {:error, {:workspace, :must_be_workspace_handle}}

  defp normalize_capabilities(%CapabilitySet{} = capabilities) do
    case CapabilitySet.new(Map.from_struct(capabilities)) do
      {:ok, capabilities} -> {:ok, capabilities}
      {:error, _reason} -> {:error, {:capabilities, :must_be_tool_capability_set}}
    end
  end

  defp normalize_capabilities(_capabilities),
    do: {:error, {:capabilities, :must_be_tool_capability_set}}

  defp normalize_limits(%Limits{} = limits) do
    case Limits.new(Map.from_struct(limits)) do
      {:ok, limits} -> {:ok, limits}
      {:error, _reason} -> {:error, {:limits, :must_be_tool_limits}}
    end
  end

  defp normalize_limits(_limits), do: {:error, {:limits, :must_be_tool_limits}}

  defp normalize_context(%__MODULE__{} = context), do: new(Map.from_struct(context))
  defp normalize_context(_context), do: {:error, :invalid_context}

  defp reduced_access(handle_access, :fs_read),
    do: Access.new(read: handle_access.read, write: false, exec: false)

  defp reduced_access(handle_access, :fs_write),
    do: Access.new(read: false, write: handle_access.write, exec: false)

  defp reduced_access(handle_access, :process_exec),
    do: Access.new(read: false, write: false, exec: handle_access.exec)

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
