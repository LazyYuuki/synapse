defmodule Synapse.Agent.Admission do
  @moduledoc """
  Pure whole-batch admission for one successful terminal Provider Response.

  Agent calls `preflight/4` only after Provider `stream/3` returns success. The
  function revalidates the complete Response, retains it unchanged for later
  conversation projection, converts every FunctionCall through
  `Synapse.Tool.Call.from_provider/2`, and rejects the whole batch if any call or
  structural validation fails.

  Admission is structural, not executable built-in validation. Unknown names and
  schema-invalid argument objects remain valid generic Calls so Executor can later
  return one paired model-visible error. Provider item IDs are retained only in
  `response`; they are deliberately absent from `calls`.

  Provider progress order has no authority. Source order comes only from the
  completed Response:

  ```text
  progress: call B, call A, message delta
                 x observations only

  terminal Response: Message -> FunctionCall A -> FunctionCall B -> Message
                                  |                 |
                                  +-> Tool Call A   +-> Tool Call B
  ```

  The complete batch is converted before this module returns, making
  the result a side-effect-free boundary before any Tool Context or execution.
  """

  alias Synapse.Provider.Response
  alias Synapse.Provider.OutputItem.{FunctionCall, Message}
  alias Synapse.Tool.{Call, Limits, Validation}

  @maximum_integer 9_223_372_036_854_775_807

  @enforce_keys [:response, :calls, :output_bytes]
  defstruct @enforce_keys

  @typedoc "A retained terminal Response, admitted Calls, and newly added Provider output."
  @type t :: %__MODULE__{
          response: Response.t(),
          calls: [Call.t()],
          output_bytes: non_neg_integer()
        }

  @typedoc "A whole-batch structural rejection."
  @type error :: :invalid_function_call_batch

  @doc """
  Revalidates and admits every terminal FunctionCall without executing a Tool.

  A Response with no FunctionCalls is not an admission batch.
  """
  @spec preflight(Response.t(), Limits.t()) :: {:ok, t()} | {:error, error()}
  def preflight(response, limits) do
    with {:ok, response} <- normalize_response(response),
         true <- Limits.valid?(limits),
         {:ok, function_calls} <- function_calls(response),
         {:ok, calls} <- convert_calls(function_calls, limits),
         true <- unique_call_ids?(calls),
         {:ok, output_bytes} <- output_bytes(response, limits) do
      {:ok, %__MODULE__{response: response, calls: calls, output_bytes: output_bytes}}
    else
      _invalid ->
        {:error, :invalid_function_call_batch}
    end
  end

  defp normalize_response(%Response{} = response) do
    case Response.new(Map.from_struct(response)) do
      {:ok, response} -> {:ok, response}
      {:error, _reason} -> :error
    end
  end

  defp normalize_response(_response), do: :error

  defp function_calls(response) do
    case Enum.filter(response.output_items, &is_struct(&1, FunctionCall)) do
      [] -> :error
      calls -> {:ok, calls}
    end
  end

  defp convert_calls(function_calls, limits) do
    Enum.reduce_while(function_calls, {:ok, []}, fn function_call, {:ok, calls} ->
      case Call.from_provider(function_call, limits) do
        {:ok, call} -> {:cont, {:ok, [call | calls]}}
        {:error, _reason} -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, calls} -> {:ok, Enum.reverse(calls)}
      :error -> :error
    end
  end

  defp unique_call_ids?(calls) do
    call_ids = Enum.map(calls, & &1.call_id)
    Enum.uniq(call_ids) == call_ids
  end

  defp output_bytes(response, limits) do
    Enum.reduce_while(response.output_items, {:ok, 0}, fn
      %Message{content: content}, {:ok, total} ->
        checked_add(total, byte_size(content))

      %FunctionCall{arguments: arguments}, {:ok, total} ->
        case Validation.bounded_json_bytes(
               arguments,
               limits.max_argument_json_bytes,
               limits.max_argument_entries,
               limits.max_argument_depth
             ) do
          {:ok, bytes} -> checked_add(total, bytes)
          :error -> {:halt, :error}
        end
    end)
  end

  defp checked_add(total, addition) when total <= @maximum_integer - addition,
    do: {:cont, {:ok, total + addition}}

  defp checked_add(_total, _addition), do: {:halt, :error}
end

defimpl Inspect, for: Synapse.Agent.Admission do
  def inspect(admission, _options) do
    "#Synapse.Agent.Admission<calls=#{length(admission.calls)} output_bytes=#{admission.output_bytes} redacted>"
  end
end
