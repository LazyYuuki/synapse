defmodule Synapse.Agent.Projection do
  @moduledoc """
  Pure full-history projection and immutable turn-request construction.

  Projection is the Agent-owned boundary between normalized application state and
  `Synapse.Provider.Request`. It projects bounded completed conversation history
  before the first exact current user message, advertises
  the four static MVP Tool schemas, retains completed assistant Messages and
  FunctionCalls, inserts each matching Tool Result immediately after its call,
  and validates the complete input before returning a new State or Request.

  Provider progress events never enter this module. Only a completed normalized
  `Synapse.Provider.Response` is accepted. Result `content` is model-visible;
  typed status and local metadata are deliberately omitted. Pairing rejects
  missing, extra, duplicate, malformed, or mismatched Results before conversation
  mutation.

  The MVP sends full projected history on every turn rather than using
  `previous_response_id` or account-specific server state. It does not inject the
  repository, environment, or plans into initial context; the model retrieves
  project evidence through bounded Tools.

  ```text
  user message
    -> assistant Message, if present
    -> FunctionCall A
    -> function_call_output A
    -> FunctionCall B
    -> function_call_output B
    -> next immutable Provider Request
  ```

  ## Example

      iex> {:ok, capabilities} = Synapse.Tool.CapabilitySet.new(
      ...>   fs_read: true, fs_write: true, process_exec: true
      ...> )
      iex> {:ok, run} = Synapse.Run.Request.new(
      ...>   id: "projection-doc",
      ...>   prompt: "Inspect the project.",
      ...>   cwd: "/tmp/project",
      ...>   model: "test-model",
      ...>   capabilities: capabilities,
      ...>   budget: Synapse.Budget.default()
      ...> )
      iex> {:ok, handle} = Synapse.Workspace.Fake.open([])
      iex> {:ok, context} = Synapse.Agent.Context.new(
      ...>   provider: Synapse.Provider.Fake,
      ...>   workspace: handle,
      ...>   event_sink: fn _event -> :ok end
      ...> )
      iex> {:ok, state} = Synapse.Agent.Projection.initial_state(run, context, 0)
      iex> {:ok, request} = Synapse.Agent.Projection.provider_request(state, context)
      iex> Enum.map(request.tools, & &1["name"])
      ["read", "write", "edit", "bash"]
      iex> Synapse.Workspace.close(handle)
      :ok

  A completed call and Result project as one immediate pair:

      iex> call = %Synapse.Provider.OutputItem.FunctionCall{
      ...>   id: "item-doc",
      ...>   call_id: "call-doc",
      ...>   name: "read",
      ...>   arguments: %{"path" => "mix.exs", "offset" => nil, "limit" => nil}
      ...> }
      iex> {:ok, response} = Synapse.Provider.Response.new(
      ...>   id: "response-doc", model: "test-model", output_items: [call]
      ...> )
      iex> {:ok, result} = Synapse.Tool.Result.ok(
      ...>   call_id: "call-doc", content: ~s({"status":"ok","tool":"read"})
      ...> )
      iex> {:ok, [call_input, output]} =
      ...>   Synapse.Agent.Projection.response_input(response, [result])
      iex> {call_input["id"], output["call_id"], output["output"]}
      {"item-doc", "call-doc", ~s({"status":"ok","tool":"read"})}
  """

  alias Synapse.Agent.{Context, State}
  alias Synapse.Provider.{Request, Response}
  alias Synapse.Provider.OutputItem.{FunctionCall, Message}
  alias Synapse.Run.Request, as: RunRequest
  alias Synapse.Tool.{Limits, Registry, Result, Validation}

  @max_results 500
  @reflection_interval 20
  @reflection_instruction """
  You have completed another 20 model turns in this run. Before taking more action, assess whether you are making concrete progress or repeating a loop. If you are blocked or stuck, stop using tools and answer the user with a concise explanation and the specific help you need. If continued work is justified, continue with a concrete next step. Do not mention this internal checkpoint merely because it occurred.
  """

  @typedoc "A rejected state, context, response, Result collection, or call pairing."
  @type error ::
          :invalid_run_request
          | :invalid_context
          | :invalid_state
          | :invalid_response
          | :invalid_results
          | :duplicate_result
          | :missing_result
          | :unexpected_result
          | :invalid_projected_input
          | {:state, State.validation_error()}
          | {:request, Request.validation_error()}

  @doc "Creates initial zero-counter State with completed history and the exact current prompt."
  @spec initial_state(RunRequest.t(), Context.t(), integer()) ::
          {:ok, State.t()} | {:error, error()}
  def initial_state(run, context, started_at) do
    with {:ok, run} <- normalize_run(run),
         {:ok, context} <- normalize_context(context),
         input_items <-
           Enum.map(run.conversation, &conversation_input/1) ++ [user_input(run.prompt)],
         {:ok, state} <-
           State.new(
             run: run,
             input_items: input_items,
             started_at: started_at,
             deadline: context.deadline
           ) do
      {:ok, state}
    else
      {:error, reason} when reason in [:invalid_run_request, :invalid_context] ->
        {:error, reason}

      {:error, reason} ->
        {:error, {:state, reason}}
    end
  end

  @doc "Builds one validated immutable Provider Request snapshot from current State."
  @spec provider_request(State.t(), Context.t()) ::
          {:ok, Request.t()} | {:error, error()}
  def provider_request(state, context) do
    with {:ok, state} <- normalize_state(state),
         {:ok, context} <- normalize_context(context),
         turn <- state.turn + 1,
         {:ok, request} <-
           Request.new(
             model: state.run.model,
             instructions: instructions_for_turn(context.instructions, turn),
             input_items: state.input_items,
             tools: Registry.specifications(),
             metadata: %{"run_id" => state.run.id, "turn" => turn}
           ) do
      {:ok, request}
    else
      {:error, :invalid_state} -> {:error, :invalid_state}
      {:error, :invalid_context} -> {:error, :invalid_context}
      {:error, reason} -> {:error, {:request, reason}}
    end
  end

  @doc false
  @spec instructions_for_turn(String.t(), pos_integer()) :: String.t()
  def instructions_for_turn(instructions, turn)
      when is_binary(instructions) and is_integer(turn) and turn > 1 and
             rem(turn - 1, @reflection_interval) == 0,
      do: instructions <> "\n\n" <> @reflection_instruction

  def instructions_for_turn(instructions, _turn), do: instructions

  @doc "Projects one completed Response and its exact paired Results into Provider input."
  @spec response_input(Response.t(), [Result.t()], Limits.t()) ::
          {:ok, [Synapse.Provider.json_object()]} | {:error, error()}
  def response_input(response, results, limits \\ Limits.default()) do
    with {:ok, response} <- normalize_response(response),
         {:ok, results} <- normalize_results(results, limits),
         {:ok, result_map} <- pair_results(response.output_items, results) do
      {:ok, project_output_items(response.output_items, result_map)}
    end
  end

  @doc "Appends a fully validated projected response to a new immutable State value."
  @spec append_response(State.t(), Context.t(), Response.t(), [Result.t()]) ::
          {:ok, State.t()} | {:error, error()}
  def append_response(state, context, response, results) do
    with {:ok, state} <- normalize_state(state),
         {:ok, context} <- normalize_context(context),
         {:ok, projected} <- response_input(response, results, context.tool_limits),
         input_items <- state.input_items ++ projected,
         {:ok, _validated} <- Request.new(model: state.run.model, input_items: input_items) do
      {:ok, %State{state | input_items: input_items}}
    else
      {:error, :invalid_state} -> {:error, :invalid_state}
      {:error, :invalid_context} -> {:error, :invalid_context}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, _reason} -> {:error, :invalid_projected_input}
    end
  end

  defp normalize_run(%RunRequest{} = run) do
    case RunRequest.new(Map.from_struct(run)) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, _reason} -> {:error, :invalid_run_request}
    end
  end

  defp normalize_run(_run), do: {:error, :invalid_run_request}

  defp normalize_context(%Context{} = context) do
    case Context.new(Map.from_struct(context)) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, _reason} -> {:error, :invalid_context}
    end
  end

  defp normalize_context(_context), do: {:error, :invalid_context}

  defp normalize_state(%State{status: :running} = state) do
    with true <- RunRequest.valid?(state.run),
         true <- state_counters_valid?(state),
         {:ok, request} <- Request.new(model: state.run.model, input_items: state.input_items) do
      {:ok, %State{state | input_items: request.input_items}}
    else
      _invalid -> {:error, :invalid_state}
    end
  end

  defp normalize_state(_state), do: {:error, :invalid_state}

  defp state_counters_valid?(state) do
    counter?(state.turn) and counter?(state.tool_calls) and counter?(state.provider_retries) and
      counter?(state.output_bytes) and Validation.int64?(state.started_at) and
      (state.deadline == :infinity or Validation.int64?(state.deadline))
  end

  defp counter?(value), do: is_integer(value) and value >= 0 and Validation.int64?(value)

  defp normalize_response(%Response{} = response) do
    case Response.new(Map.from_struct(response)) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, _reason} -> {:error, :invalid_response}
    end
  end

  defp normalize_response(_response), do: {:error, :invalid_response}

  defp normalize_results(results, %Limits{} = limits) do
    if Limits.valid?(limits) and Validation.proper_list?(results, @max_results + 1) and
         length(results) <= @max_results do
      Enum.reduce_while(results, {:ok, []}, fn result, {:ok, normalized} ->
        case normalize_result(result, limits) do
          {:ok, result} -> {:cont, {:ok, [result | normalized]}}
          {:error, :invalid_results} -> {:halt, {:error, :invalid_results}}
        end
      end)
      |> case do
        {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
        error -> error
      end
    else
      {:error, :invalid_results}
    end
  end

  defp normalize_results(_results, _limits), do: {:error, :invalid_results}

  defp normalize_result(%Result{} = result, limits) do
    case Result.new(Map.from_struct(result), limits) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, _reason} -> {:error, :invalid_results}
    end
  end

  defp normalize_result(_result, _limits), do: {:error, :invalid_results}

  defp pair_results(output_items, results) do
    call_ids =
      Enum.flat_map(output_items, fn
        %FunctionCall{call_id: call_id} -> [call_id]
        %Message{} -> []
      end)

    result_ids = Enum.map(results, & &1.call_id)

    cond do
      Enum.uniq(result_ids) != result_ids -> {:error, :duplicate_result}
      Enum.any?(call_ids, &(&1 not in result_ids)) -> {:error, :missing_result}
      Enum.any?(result_ids, &(&1 not in call_ids)) -> {:error, :unexpected_result}
      true -> {:ok, Map.new(results, &{&1.call_id, &1})}
    end
  end

  defp project_output_items(output_items, result_map) do
    Enum.flat_map(output_items, fn
      %Message{} = message ->
        [assistant_input(message)]

      %FunctionCall{} = call ->
        [function_call_input(call), function_output(Map.fetch!(result_map, call.call_id))]
    end)
  end

  defp user_input(prompt) do
    %{
      "type" => "message",
      "role" => "user",
      "content" => [%{"type" => "input_text", "text" => prompt}]
    }
  end

  defp conversation_input(%{"role" => "user", "content" => content}),
    do: user_input(content)

  defp conversation_input(%{"role" => "assistant", "content" => content}) do
    %{
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => content}]
    }
  end

  defp assistant_input(message) do
    %{
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => message.content}]
    }
  end

  defp function_call_input(call) do
    %{
      "type" => "function_call",
      "id" => call.id,
      "call_id" => call.call_id,
      "name" => call.name,
      "arguments" => call.arguments
    }
  end

  defp function_output(result) do
    %{
      "type" => "function_call_output",
      "call_id" => result.call_id,
      "output" => result.content
    }
  end
end
