defmodule Synapse.Tool.Executor do
  @moduledoc """
  Authorizes and dispatches exactly one complete Tool Call synchronously.

  Executor revalidates Call and trusted Context, performs lookup only through the
  static Registry, checks the registered Spec capability, and retains broad caller
  authority inside an internal dispatch context. Tool adapters receive only Call,
  Limits, and a terminal Workspace outcome; they never receive a Workspace Handle
  or OperationContext. It owns no queue, Task, timer, process, retry policy, or
  multi-call ordering.

  A value that cannot form a bounded Call returns `{:error, :invalid_call}` before
  Tool admission because no trustworthy pairing ID exists. Once Call is valid,
  malformed Context, unknown name, denied capability, unavailable adapter, and
  pre-callback internal failure are fixed paired error Results. Read, Write, Edit,
  and Bash are available built-ins.

  Preparation failure is known pre-dispatch. Once a typed request is prepared,
  only the static Dispatcher can select a Workspace function. Dispatch failure is
  classified by effect, while presentation failure preserves a retained terminal
  Workspace outcome. Executor never retries.
  """

  alias Synapse.Tool.{
    Call,
    Context,
    Dispatcher,
    FixedResult,
    Invocation,
    Limits,
    Registry,
    Result,
    Spec
  }

  @typedoc "A pre-admission Call contract failure with no trustworthy pairing result."
  @type admission_error :: {:error, :invalid_call}

  @doc """
  Executes one Call under trusted Context or returns a fixed paired admission
  result.

  This function is synchronous so later Workspace cancellation reaches the same
  process that called Executor. It does not emit Run Events or continue Agent
  conversation state.
  """
  @spec execute(term(), term()) :: Result.t() | admission_error()
  def execute(call, context) do
    with {:ok, call} <- normalize_call(call, Limits.default()) do
      execute_valid_call(call, context)
    else
      _invalid -> {:error, :invalid_call}
    end
  end

  defp execute_valid_call(call, context) do
    case normalize_context(context) do
      {:ok, context} ->
        limits = pairing_limits(context.limits, call.call_id)
        context = %{context | limits: limits}

        with {:ok, call} <- normalize_call(call, limits) do
          dispatch(call, context)
        else
          _invalid -> FixedResult.error(call.call_id, :invalid_call, limits)
        end

      {:error, :invalid_context} ->
        FixedResult.error(call.call_id, :invalid_context, Limits.default())
    end
  end

  defp dispatch(call, context) do
    case Registry.fetch(call.name) do
      {:ok, module} -> dispatch_known(module, call, context)
      :error -> FixedResult.error(call.call_id, :unknown_tool, context.limits)
    end
  end

  defp dispatch_known(module, call, context) do
    with {:ok, spec} <- registered_specification(module, call.name),
         true <-
           Synapse.Tool.CapabilitySet.allows?(context.capabilities, spec.capability) or
             {:error, :capability_denied},
         {:ok, dispatch_context} <- Context.authorize(context, spec.capability) do
      if adapter_available?(module) do
        execute_adapter(module, call, dispatch_context, spec)
      else
        FixedResult.error(call.call_id, :tool_unavailable, context.limits)
      end
    else
      {:error, :capability_denied} ->
        FixedResult.error(call.call_id, :capability_denied, context.limits)

      _invalid ->
        FixedResult.error(call.call_id, :internal_error, context.limits)
    end
  end

  defp execute_adapter(module, call, dispatch_context, spec) do
    case Invocation.prepare(fn -> module.prepare(call, dispatch_context.limits) end) do
      {:ok, request} ->
        dispatch_request(module, request, call, dispatch_context, spec)

      {:error, :invalid_arguments} ->
        FixedResult.error(call.call_id, :invalid_arguments, dispatch_context.limits)

      {:error, :callback_failed} ->
        FixedResult.error(call.call_id, :internal_error, dispatch_context.limits)
    end
  end

  defp dispatch_request(module, request, call, dispatch_context, spec) do
    case Dispatcher.prepare(module, request, dispatch_context) do
      {:ok, dispatch} ->
        invoke_dispatch(module, dispatch, call, dispatch_context, spec)

      {:error, :invalid_request} ->
        FixedResult.error(call.call_id, :invalid_arguments, dispatch_context.limits)

      {:error, :invalid_dispatch} ->
        FixedResult.error(call.call_id, :internal_error, dispatch_context.limits)
    end
  end

  defp invoke_dispatch(module, dispatch, call, dispatch_context, spec) do
    case Invocation.dispatch(dispatch) do
      {:ok, outcome} ->
        Invocation.present(
          fn -> module.present(call, outcome, dispatch_context.limits) end,
          call,
          dispatch_context.limits,
          outcome
        )

      {:error, :dispatch_failed} ->
        FixedResult.dispatch_failure(call.call_id, spec.effect, dispatch_context.limits)
    end
  end

  defp adapter_available?(module) do
    function_exported?(module, :prepare, 2) and function_exported?(module, :present, 3)
  end

  defp registered_specification(module, name) do
    try do
      case module.specification() do
        %Spec{name: ^name} = spec -> Spec.new(Map.from_struct(spec))
        _invalid -> {:error, :invalid_specification}
      end
    rescue
      _exception -> {:error, :invalid_specification}
    catch
      _kind, _reason -> {:error, :invalid_specification}
    end
  end

  defp normalize_call(%Call{} = call, limits), do: Call.new(Map.from_struct(call), limits)
  defp normalize_call(_call, _limits), do: {:error, :invalid_call}

  defp normalize_context(%Context{} = context) do
    case Context.new(Map.from_struct(context)) do
      {:ok, context} -> {:ok, context}
      {:error, _reason} -> {:error, :invalid_context}
    end
  end

  defp normalize_context(_context), do: {:error, :invalid_context}

  defp pairing_limits(limits, call_id) do
    required = max(limits.max_call_id_bytes, byte_size(call_id))
    {:ok, limits} = Limits.new(%{Map.from_struct(limits) | max_call_id_bytes: required})
    limits
  end
end
