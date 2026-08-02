defmodule Synapse.Tool.Invocation do
  @moduledoc false

  alias Synapse.Tool.{Call, FixedResult, Limits, Result}
  alias Synapse.Workspace.{Error, MutationResult, ProcessResult, ReadResult}

  @doc false
  @spec prepare((-> term())) ::
          {:ok, Synapse.Tool.workspace_request()}
          | {:error, :invalid_arguments | :callback_failed}
  def prepare(callback) when is_function(callback, 0) do
    try do
      case callback.() do
        {:ok, request} -> {:ok, request}
        {:error, :invalid_arguments} -> {:error, :invalid_arguments}
        _invalid -> {:error, :callback_failed}
      end
    rescue
      _exception -> {:error, :callback_failed}
    catch
      _kind, _reason -> {:error, :callback_failed}
    end
  end

  @doc false
  @spec dispatch((-> term())) ::
          {:ok, Synapse.Tool.workspace_outcome()} | {:error, :dispatch_failed}
  def dispatch(callback) when is_function(callback, 0) do
    try do
      case callback.() do
        {:ok, result} = outcome
        when is_struct(result, ReadResult) or is_struct(result, MutationResult) or
               is_struct(result, ProcessResult) ->
          {:ok, outcome}

        {:error, %Error{}} = outcome ->
          {:ok, outcome}

        _invalid ->
          {:error, :dispatch_failed}
      end
    rescue
      _exception -> {:error, :dispatch_failed}
    catch
      _kind, _reason -> {:error, :dispatch_failed}
    end
  end

  @doc false
  @spec present((-> term()), Call.t(), Limits.t(), Synapse.Tool.workspace_outcome()) :: Result.t()
  def present(callback, %Call{} = call, %Limits{} = limits, outcome)
      when is_function(callback, 0) do
    try do
      callback.()
      |> validate_result(call, limits, outcome)
    rescue
      _exception -> FixedResult.presentation_fallback(call.call_id, outcome, limits)
    catch
      _kind, _reason -> FixedResult.presentation_fallback(call.call_id, outcome, limits)
    end
  end

  defp validate_result(%Result{} = result, call, limits, outcome) do
    case Result.new(Map.from_struct(result), limits) do
      {:ok, %Result{call_id: call_id} = result} when call_id == call.call_id -> result
      _invalid -> FixedResult.presentation_fallback(call.call_id, outcome, limits)
    end
  end

  defp validate_result(_result, call, limits, outcome),
    do: FixedResult.presentation_fallback(call.call_id, outcome, limits)
end
