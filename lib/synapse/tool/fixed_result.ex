defmodule Synapse.Tool.FixedResult do
  @moduledoc false

  alias Synapse.Tool.{Limits, Result}
  alias Synapse.Workspace.{Error, ProcessResult}

  @invalid_call ~s({"status":"error","error":{"kind":"tool","reason":"invalid_call","message":"Tool Call exceeds operation limits","outcome":"not_applied"}})
  @invalid_context ~s({"status":"error","error":{"kind":"tool","reason":"invalid_context","message":"Tool Context is invalid","outcome":"not_applied"}})
  @unknown_tool ~s({"status":"error","error":{"kind":"tool","reason":"unknown_tool","message":"Tool name is not registered","outcome":"not_applied"}})
  @capability_denied ~s({"status":"error","error":{"kind":"tool","reason":"capability_denied","message":"Tool capability is denied","outcome":"not_applied"}})
  @invalid_arguments ~s({"status":"error","error":{"kind":"tool","reason":"invalid_arguments","message":"Tool arguments are invalid","outcome":"not_applied"}})
  @tool_unavailable ~s({"status":"error","error":{"kind":"tool","reason":"tool_unavailable","message":"Tool implementation is not available","outcome":"not_applied"}})
  @internal_error ~s({"status":"error","error":{"kind":"tool","reason":"internal_error","message":"Tool execution failed","outcome":"not_applicable"}})
  @callback_failed ~s({"status":"ambiguous","error":{"kind":"tool","reason":"callback_failed","message":"Tool dispatch failed with an unknown side-effect outcome; inspect current workspace state and do not retry blindly","outcome":"unknown"}})
  @presentation_ambiguous ~s({"status":"ambiguous","error":{"kind":"tool","reason":"presentation_failed","message":"Tool result presentation failed; inspect current workspace state and do not retry blindly","outcome":"unknown"}})
  @presentation_ok ~s({"status":"ok","presentation":"unavailable"})
  @presentation_not_applied ~s({"status":"error","error":{"kind":"tool","reason":"presentation_failed","message":"Tool result presentation failed","outcome":"not_applied"}})
  @presentation_not_applicable ~s({"status":"error","error":{"kind":"tool","reason":"presentation_failed","message":"Tool result presentation failed","outcome":"not_applicable"}})
  @presentation_completed ~s({"status":"error","error":{"kind":"tool","reason":"presentation_failed","message":"Tool result presentation failed","outcome":"completed"}})

  @spec error(String.t(), atom(), Limits.t()) :: Result.t()
  def error(call_id, reason, limits) do
    content = error_content(reason)

    {:ok, result} =
      Result.error([call_id: call_id, content: content, metadata: %{}], limits)

    result
  end

  @spec ambiguous(String.t(), Limits.t()) :: Result.t()
  def ambiguous(call_id, limits) do
    {:ok, result} =
      Result.ambiguous(
        [call_id: call_id, content: @callback_failed, metadata: %{}],
        limits
      )

    result
  end

  @doc false
  @spec dispatch_failure(String.t(), Synapse.Tool.Spec.effect(), Limits.t()) :: Result.t()
  def dispatch_failure(call_id, :read_only, limits), do: error(call_id, :internal_error, limits)

  def dispatch_failure(call_id, effect, limits) when effect in [:mutation, :unknown],
    do: ambiguous(call_id, limits)

  @spec presentation_fallback(String.t(), Synapse.Tool.workspace_outcome(), Limits.t()) ::
          Result.t()
  def presentation_fallback(call_id, {:error, %Error{outcome: :unknown}}, limits),
    do: result(:ambiguous, call_id, @presentation_ambiguous, limits)

  def presentation_fallback(call_id, {:error, %Error{outcome: outcome}}, limits)
      when outcome in [:not_applied, :not_applicable] do
    content =
      if outcome == :not_applied,
        do: @presentation_not_applied,
        else: @presentation_not_applicable

    result(:error, call_id, content, limits)
  end

  def presentation_fallback(
        call_id,
        {:ok, %ProcessResult{termination: :exited, exit_code: 0}},
        limits
      ),
      do: result(:ok, call_id, @presentation_ok, limits)

  def presentation_fallback(
        call_id,
        {:ok, %ProcessResult{termination: :exited, exit_code: exit_code}},
        limits
      )
      when is_integer(exit_code) and exit_code != 0,
      do: result(:error, call_id, @presentation_completed, limits)

  def presentation_fallback(call_id, {:ok, %ProcessResult{}}, limits),
    do: result(:error, call_id, @presentation_completed, limits)

  def presentation_fallback(call_id, {:ok, _workspace_result}, limits),
    do: result(:ok, call_id, @presentation_ok, limits)

  def presentation_fallback(call_id, _invalid, limits),
    do: error(call_id, :internal_error, limits)

  defp error_content(:invalid_call), do: @invalid_call
  defp error_content(:invalid_context), do: @invalid_context
  defp error_content(:unknown_tool), do: @unknown_tool
  defp error_content(:capability_denied), do: @capability_denied
  defp error_content(:invalid_arguments), do: @invalid_arguments
  defp error_content(:tool_unavailable), do: @tool_unavailable
  defp error_content(:internal_error), do: @internal_error

  defp result(:ok, call_id, content, limits) do
    {:ok, result} = Result.ok([call_id: call_id, content: content, metadata: %{}], limits)
    result
  end

  defp result(:error, call_id, content, limits) do
    {:ok, result} = Result.error([call_id: call_id, content: content, metadata: %{}], limits)
    result
  end

  defp result(:ambiguous, call_id, content, limits) do
    {:ok, result} = Result.ambiguous([call_id: call_id, content: content, metadata: %{}], limits)
    result
  end
end
