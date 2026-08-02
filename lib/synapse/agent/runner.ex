defmodule Synapse.Agent.Runner do
  @moduledoc """
  Executes the current synchronous bounded Agent loop.

  Runner implements the immutable Provider/Tool continuation loop. It validates
  trusted contracts, creates initial State, emits ordered Run Events,
  streams Provider attempts, and treats only completed terminal Responses as
  authoritative. Provider progress events are observations: only TextDelta maps
  to a Run Event, and ToolCall progress never executes a Tool.

  A final Response succeeds only when it has no FunctionCalls and its assistant
  Messages join to non-empty text. FunctionCall batches are structurally converted
  and budgeted as a whole, then executed once each in source order under distinct
  trusted Tool Contexts. Ordinary Tool errors remain paired and do not stop the
  batch; ambiguity stops every later call. A complete known batch is projected
  atomically into a new State before the next full-history Provider Request.

  Runner remains a synchronous function suitable for a temporary supervised Task.
  Provider callbacks capture explicit immutable values and never depend on
  callback `self/0` or Runner-local mutation. Each synchronous callback applies
  backpressure to Provider streaming until the Run Event sink accepts it.

  A logical turn owns one immutable Provider Request. A Provider attempt is one
  `stream/3` call for that request; each safe retry reuses the snapshot with a new
  operation ID. TextDelta events remain progress only, so Runner derives final text
  from the completed Response rather than reconstructing incomplete deltas.

  Tool authority flows only from trusted contracts: Workspace Handle and lifetime
  sinks come from Agent Context, capabilities come from Run Request, limits come
  from Agent Context, and the effective deadline comes from State. Model arguments
  can alter none of them.

  Every continuation sends the complete locally projected history rather than
  relying on Provider account state. Runner appends only after every admitted call
  has one known paired Result, so a malformed or ambiguous partial batch never
  enters the next request. Future context compaction must preserve each
  FunctionCall and function output as an indivisible pair. Follow-up and steering
  queues remain outside the current loop.

  State charges a logical turn immediately before its Provider operation, a Tool
  call immediately before ToolStarted, completed normalized Provider output after
  terminal success, and each known Result before any later operation. The same
  effective monotonic deadline is passed to Provider and Tool contexts and checked
  before every operation and continuation. Retry accounting remains a separate
  State transition because retries do not create logical turns.

  Semantic Provider retry is separate from future Runtime process supervision.
  Runner retries only allowlisted retryable failures before any output became
  visible, reusing the exact immutable Request with a fresh attempt operation ID.
  Text or Tool-call progress blocks transparent replay because a second attempt
  could duplicate user-visible output or side effects.

  ```text
  Provider failure before output
    -> retryable + budget + deadline + not cancelled
    -> bounded delay -> fresh operation ID -> exact same Request

  Provider output started -> interrupted, never replay
  ```

  Cancellation uses both a matching operation `cancel_ref` and a persistent
  `cancelled?` probe. Lower layers may consume the mailbox message, while Runner
  rechecks the probe before and after operations and during retry waits. Runtime
  still owns actual message routing, active-operation tracking, and worker
  supervision.

  ```text
  cancellation probe true
    -> start no later operation
    -> known Tool result: interrupted
    -> ambiguous Tool result: interrupted with ambiguity evidence
  ```

  ## Acceptance layers

  Deterministic Fake Provider and Workspace tests prove exact requests, projection,
  event order, accounting, and scripted side-effect admission without network or
  host effects. Temporary Real Workspace tests prove the same public Runner can
  drive bounded local file and process adapters, but not model behavior. Opt-in
  live Tokamak tests prove the real Provider can drive that Runner, but remain
  nondeterministic and credential-gated.

  ```text
  Run Request
    -> Runner -> Provider Request
    <- completed Response with FunctionCalls
    -> Tool Executor -> Workspace operations
    <- paired Results
    -> immutable full-history Provider Request
    <- final text Response
    -> Agent Result + RunCompleted
  ```

  Acceptance verifies file content and command exit evidence independently of the
  model's final claim. Agent completion still is not workflow acceptance: Runtime
  supervision, CLI exit policy, evidence workflows, commits, and work-item state
  remain outside this component.

  ```text
  terminal Response -> whole-batch Admission
    -> Tool Context -> ToolStarted -> Executor once -> retain Result -> ToolCompleted
    -> next call on :ok/:error
    -> stop immediately on :ambiguous or event-sink failure
  ```

  """

  alias Synapse.Agent.{Admission, Context, Error, OperationId, Projection, Result, State}
  alias Synapse.Provider
  alias Synapse.Provider.{Response, StreamContext}
  alias Synapse.Provider.Event.TextDelta, as: ProviderTextDelta
  alias Synapse.Provider.OutputItem.{FunctionCall, Message}
  alias Synapse.Run.{Event, Request}
  alias Synapse.Tool.Executor
  alias Synapse.Tool.Context, as: ToolContext
  alias Synapse.Tool.Limits, as: ToolLimits
  alias Synapse.Tool.Result, as: ToolResult

  @attempt 1

  @doc """
  Runs one validated Request under trusted Context until final text or a terminal Error.

  Event callbacks are synchronous and apply Provider backpressure. A rejected event
  terminates the run. Expected Provider, Tool, budget, cancellation, and protocol
  outcomes return a typed tuple; unexpected lower-layer exceptions and exits remain
  process failures for Runtime supervision to convert in a future phase.
  """
  @spec run(Request.t(), Context.t()) :: Synapse.Agent.result()
  def run(request, context) do
    with {:ok, request} <- normalize_request(request),
         {:ok, context} <- normalize_context(context),
         {:ok, state} <-
           Projection.initial_state(
             request,
             context,
             :erlang.monotonic_time(:millisecond)
           ),
         :ok <- emit(context, :run_started, run_id: request.id, model: request.model) do
      next_turn(request, context, state)
    else
      {:error, :invalid_run_request} ->
        terminal_error(:invalid_run_request, "Run Request is invalid", "invalid-run")

      {:error, :invalid_context} ->
        run_id = if Request.valid?(request), do: request.id, else: "invalid-run"
        terminal_error(:invalid_agent_context, "Agent Context is invalid", run_id)

      {:error, :event_sink_failed} ->
        terminal_error(:event_sink_failed, "Run Event sink failed", request.id)

      {:error, reason} ->
        terminal_error(
          :invalid_agent_context,
          "Agent initialization failed",
          safe_run_id(request),
          %{
            "status" => inspect(reason)
          }
        )
    end
  end

  defp next_turn(run, context, state) do
    with :ok <- cancellation_guard(context),
         {:ok, provider_request} <- Projection.provider_request(state, context),
         {:ok, state} <- State.admit_turn(state, monotonic_now()),
         turn <- state.turn,
         {:ok, operation_id} <- OperationId.provider(run.id, turn, @attempt),
         :ok <-
           emit(context, :turn_started,
             run_id: run.id,
             turn: turn,
             operation_id: operation_id
           ),
         {:ok, stream_context} <- stream_context(state, context, operation_id) do
      stream(
        run,
        context,
        state,
        turn,
        provider_request,
        stream_context,
        operation_id,
        @attempt
      )
    else
      {:error, :run_cancelled} ->
        fail_before_turn_cancelled(run, context, state)

      {:error, :turn_budget_exhausted} ->
        fail_before_turn(
          run,
          context,
          state,
          :turn_budget_exhausted,
          "Run turn budget exhausted",
          %{"observed" => state.turn + 1, "maximum" => run.budget.max_turns}
        )

      {:error, :wall_time_budget_exhausted} ->
        fail_before_turn(
          run,
          context,
          state,
          :wall_time_budget_exhausted,
          "Run wall-time budget exhausted",
          %{"status" => "deadline_elapsed"}
        )

      {:error, :event_sink_failed} ->
        terminal_error(:event_sink_failed, "Run Event sink failed", run.id)

      {:error, _reason} ->
        fail_internal(
          run,
          context,
          max(state.turn, 1),
          nil,
          :conversation_projection_failed,
          "Next Provider Request is invalid",
          0,
          0
        )
    end
  end

  defp monotonic_now, do: :erlang.monotonic_time(:millisecond)

  defp cancelled?(context) do
    try do
      context.cancelled?.() == true
    rescue
      _exception -> true
    catch
      _kind, _reason -> true
    end
  end

  defp cancellation_guard(context),
    do: if(cancelled?(context), do: {:error, :run_cancelled}, else: :ok)

  defp stream(
         run,
         context,
         state,
         turn,
         provider_request,
         stream_context,
         operation_id,
         attempt
       ) do
    event_sink = provider_event_sink(run.id, context, turn, operation_id)

    case context.provider.stream(provider_request, event_sink, stream_context) do
      {:ok, response} ->
        if cancelled?(context) do
          fail_cancelled(run, context, turn, operation_id, 0, 0, attempt)
        else
          handle_response(run, context, state, turn, operation_id, response, attempt)
        end

      {:error, %Provider.Error{} = error} ->
        handle_provider_error(
          run,
          context,
          state,
          turn,
          provider_request,
          operation_id,
          attempt,
          error
        )

      _invalid ->
        fail_protocol(
          run,
          context,
          turn,
          operation_id,
          "Provider returned an invalid terminal",
          :empty_provider_response,
          0,
          0,
          attempt
        )
    end
  end

  defp handle_response(run, context, state, turn, operation_id, response, provider_attempts) do
    case normalize_response(response) do
      {:ok, response} ->
        classify_response(
          run,
          context,
          state,
          turn,
          operation_id,
          response,
          provider_attempts
        )

      {:error, :invalid_response} ->
        reason =
          if function_call_response?(response),
            do: :invalid_function_call_batch,
            else: :empty_provider_response

        fail_protocol(
          run,
          context,
          turn,
          operation_id,
          "Provider Response is invalid",
          reason,
          0,
          0,
          provider_attempts
        )
    end
  end

  defp classify_response(
         run,
         context,
         state,
         turn,
         operation_id,
         response,
         provider_attempts
       ) do
    calls = Enum.filter(response.output_items, &is_struct(&1, FunctionCall))
    messages = Enum.filter(response.output_items, &is_struct(&1, Message))
    text = Enum.map_join(messages, "\n", & &1.content)

    cond do
      calls != [] ->
        admit_calls(
          run,
          context,
          state,
          turn,
          operation_id,
          response,
          provider_attempts
        )

      String.trim(text) == "" ->
        fail_protocol(
          run,
          context,
          turn,
          operation_id,
          "Provider Response contained no final text",
          :empty_provider_response,
          0,
          0,
          provider_attempts
        )

      true ->
        complete(run, context, state, turn, response, text, provider_attempts)
    end
  end

  defp admit_calls(
         run,
         context,
         state,
         turn,
         operation_id,
         response,
         provider_attempts
       ) do
    remaining_calls = run.budget.max_tool_calls - state.tool_calls
    remaining_output = run.budget.max_output_bytes - state.output_bytes

    case Admission.preflight(
           response,
           context.tool_limits,
           remaining_calls,
           remaining_output
         ) do
      {:ok, admission} ->
        case State.add_output(state, admission.output_bytes) do
          {:ok, state} ->
            execute_calls(
              run,
              context,
              state,
              turn,
              operation_id,
              admission,
              provider_attempts
            )

          {:error, :output_budget_exhausted} ->
            fail_budget(
              run,
              context,
              turn,
              operation_id,
              :output_budget_exhausted,
              "Run output budget exhausted",
              state.output_bytes + admission.output_bytes,
              run.budget.max_output_bytes,
              0,
              0,
              provider_attempts
            )

          {:error, _reason} ->
            fail_internal(
              run,
              context,
              turn,
              operation_id,
              :conversation_projection_failed,
              "Provider output accounting failed",
              0,
              0,
              provider_attempts
            )
        end

      {:error, :invalid_function_call_batch} ->
        fail_protocol(
          run,
          context,
          turn,
          operation_id,
          "Provider Response contained an invalid FunctionCall batch",
          :invalid_function_call_batch,
          0,
          0,
          provider_attempts
        )

      {:error, {:tool_call_budget_exhausted, observed, _remaining}} ->
        fail_budget(
          run,
          context,
          turn,
          operation_id,
          :tool_call_budget_exhausted,
          "Run Tool-call budget exhausted",
          state.tool_calls + observed,
          run.budget.max_tool_calls,
          0,
          0,
          provider_attempts
        )

      {:error, {:output_budget_exhausted, observed, _remaining}} ->
        fail_budget(
          run,
          context,
          turn,
          operation_id,
          :output_budget_exhausted,
          "Run output budget exhausted",
          state.output_bytes + observed,
          run.budget.max_output_bytes,
          0,
          0,
          provider_attempts
        )
    end
  end

  defp execute_calls(
         run,
         context,
         state,
         turn,
         provider_operation_id,
         admission,
         provider_attempts
       ) do
    admission.calls
    |> Enum.with_index(1)
    |> Enum.reduce_while(
      {:ok, [], state, 0, admission.output_bytes},
      fn {call, ordinal}, {:ok, results, execution_state, executed, turn_output_bytes} ->
        case cancellation_guard(context) do
          :ok ->
            case State.admit_tool(execution_state, monotonic_now()) do
              {:ok, admitted_state} ->
                execute_admitted_call(
                  run,
                  context,
                  admitted_state,
                  turn,
                  call,
                  ordinal,
                  results,
                  executed,
                  turn_output_bytes
                )

              {:error, :wall_time_budget_exhausted} ->
                {:halt, {:error, :wall_time_budget_exhausted, executed, turn_output_bytes}}

              {:error, :tool_call_budget_exhausted} ->
                {:halt, {:error, :tool_call_budget_exhausted, executed, turn_output_bytes}}

              {:error, _reason} ->
                {:halt, {:error, :invalid_tool_context, nil, executed}}
            end

          {:error, :run_cancelled} ->
            {:halt, {:error, :run_cancelled, nil, executed, turn_output_bytes}}
        end
      end
    )
    |> finish_execution(
      run,
      context,
      state,
      turn,
      provider_operation_id,
      admission,
      provider_attempts
    )
  end

  defp execute_admitted_call(
         run,
         context,
         admitted_state,
         turn,
         call,
         ordinal,
         results,
         executed,
         turn_output_bytes
       ) do
    case execute_call(run, context, admitted_state, turn, call, ordinal) do
      {:ok, result, tool_operation_id} ->
        retained_results = [result | results]
        executed = executed + 1

        case emit_tool_completed(
               run,
               context,
               turn,
               call,
               result,
               ordinal,
               tool_operation_id
             ) do
          :ok when result.status == :ambiguous ->
            {:halt,
             {:ambiguous, call, result, tool_operation_id, Enum.reverse(retained_results),
              executed, turn_output_bytes}}

          :ok ->
            result_bytes = byte_size(result.content)

            case State.add_output(admitted_state, result_bytes) do
              {:ok, next_state} ->
                next_output_bytes = turn_output_bytes + result_bytes

                if cancelled?(context) do
                  {:halt,
                   {:error, :run_cancelled, tool_operation_id, executed, next_output_bytes}}
                else
                  {:cont, {:ok, retained_results, next_state, executed, next_output_bytes}}
                end

              {:error, :output_budget_exhausted} ->
                {:halt,
                 {:error, :output_budget_exhausted, admitted_state.output_bytes + result_bytes,
                  executed, turn_output_bytes + result_bytes}}

              {:error, _reason} ->
                {:halt, {:error, :executor_contract, tool_operation_id, executed}}
            end

          {:error, :event_sink_failed} ->
            {:halt, {:error, :event_sink_failed, executed}}
        end

      {:error, :event_sink_failed} ->
        {:halt, {:error, :event_sink_failed, executed}}

      {:error, :invalid_tool_context, tool_operation_id} ->
        {:halt, {:error, :invalid_tool_context, tool_operation_id, executed}}

      {:error, :executor_contract, tool_operation_id} ->
        {:halt, {:error, :executor_contract, tool_operation_id, executed + 1}}
    end
  end

  defp execute_call(run, context, state, turn, call, ordinal) do
    case OperationId.tool(run.id, turn, ordinal) do
      {:ok, operation_id} ->
        execute_call(run, context, state, turn, call, ordinal, operation_id)

      {:error, _reason} ->
        {:error, :invalid_tool_context, nil}
    end
  end

  defp execute_call(run, context, state, turn, call, ordinal, operation_id) do
    with {:ok, tool_context} <- tool_context(run, context, state, operation_id),
         :ok <-
           emit(context, :tool_started,
             run_id: run.id,
             turn: turn,
             operation_id: operation_id,
             call_id: call.call_id,
             name: call.name,
             ordinal: ordinal
           ) do
      case Executor.execute(call, tool_context) do
        %ToolResult{} = result ->
          case normalize_tool_result(result, call, context.tool_limits) do
            {:ok, result} -> {:ok, result, operation_id}
            {:error, :executor_contract} -> {:error, :executor_contract, operation_id}
          end

        {:error, :invalid_call} ->
          {:error, :executor_contract, operation_id}

        _invalid ->
          {:error, :executor_contract, operation_id}
      end
    else
      {:error, :event_sink_failed} -> {:error, :event_sink_failed}
      {:error, _reason} -> {:error, :invalid_tool_context, operation_id}
    end
  end

  defp tool_context(run, context, state, operation_id) do
    with {:ok, limits} <- effective_tool_limits(context.tool_limits, run.budget) do
      ToolContext.new(
        workspace: context.workspace,
        capabilities: run.capabilities,
        operation_id: operation_id,
        cancel_ref: context.cancel_ref,
        deadline: state.deadline,
        activity_sink: context.tool_activity_sink,
        limits: limits
      )
    end
  end

  defp effective_tool_limits(limits, budget) do
    max_inactivity = min(limits.max_bash_inactivity_ms, budget.tool_inactivity_ms)
    default_inactivity = min(limits.default_bash_inactivity_ms, max_inactivity)

    ToolLimits.new(%{
      Map.from_struct(limits)
      | default_bash_inactivity_ms: default_inactivity,
        max_bash_inactivity_ms: max_inactivity
    })
  end

  defp normalize_tool_result(%ToolResult{} = result, call, limits) do
    case ToolResult.new(Map.from_struct(result), limits) do
      {:ok, %ToolResult{call_id: call_id} = result} when call_id == call.call_id ->
        {:ok, result}

      _invalid ->
        {:error, :executor_contract}
    end
  end

  defp emit_tool_completed(run, context, turn, call, result, ordinal, operation_id) do
    emit(context, :tool_completed,
      run_id: run.id,
      turn: turn,
      operation_id: operation_id,
      call_id: call.call_id,
      name: call.name,
      ordinal: ordinal,
      status: result.status,
      metadata: tool_event_metadata(call, result)
    )
  end

  defp tool_event_metadata(call, result) do
    %{}
    |> maybe_event_tool(call, result.metadata["tool"])
    |> maybe_event_outcome(result.metadata["outcome"])
  end

  defp maybe_event_tool(metadata, call, tool) when tool == call.name,
    do: Map.put(metadata, "tool", tool)

  defp maybe_event_tool(metadata, _call, _tool), do: metadata

  defp maybe_event_outcome(metadata, outcome)
       when outcome in ["completed", "not_applied", "not_applicable", "unknown"],
       do: Map.put(metadata, "outcome", outcome)

  defp maybe_event_outcome(metadata, _outcome), do: metadata

  defp finish_execution(
         {:ok, results, execution_state, executed, turn_output_bytes},
         run,
         context,
         _state,
         turn,
         provider_operation_id,
         admission,
         provider_attempts
       ) do
    results = Enum.reverse(results)

    continue_after_tools(
      run,
      context,
      execution_state,
      turn,
      provider_operation_id,
      admission,
      results,
      executed,
      turn_output_bytes,
      provider_attempts
    )
  end

  defp finish_execution(
         {:ambiguous, call, _result, operation_id, _retained_results, executed,
          turn_output_bytes},
         run,
         context,
         _state,
         turn,
         _provider_operation_id,
         _admission,
         provider_attempts
       ) do
    details = %{
      "call_id" => call.call_id,
      "tool_name" => call.name,
      "operation_id" => operation_id,
      "outcome" => "unknown",
      "status" => "ambiguous"
    }

    if cancelled?(context) do
      fail_cancelled(
        run,
        context,
        turn,
        operation_id,
        turn_output_bytes,
        executed,
        provider_attempts,
        details
      )
    else
      {:ok, error} =
        Error.new(
          kind: :tool,
          reason: :tool_ambiguous,
          message: "Tool result has an unknown side-effect outcome",
          run_id: run.id,
          turn: turn,
          operation_id: operation_id,
          details: details
        )

      emit_failure(context, error, :failed, turn_output_bytes, executed, provider_attempts)
    end
  end

  defp finish_execution(
         {:error, :run_cancelled, operation_id, executed, turn_output_bytes},
         run,
         context,
         _state,
         turn,
         provider_operation_id,
         _admission,
         provider_attempts
       ) do
    fail_cancelled(
      run,
      context,
      turn,
      operation_id || provider_operation_id,
      turn_output_bytes,
      executed,
      provider_attempts
    )
  end

  defp finish_execution(
         {:error, :output_budget_exhausted, observed, executed, turn_output_bytes},
         run,
         context,
         _state,
         turn,
         provider_operation_id,
         _admission,
         provider_attempts
       ) do
    fail_budget(
      run,
      context,
      turn,
      provider_operation_id,
      :output_budget_exhausted,
      "Run output budget exhausted",
      observed,
      run.budget.max_output_bytes,
      turn_output_bytes,
      executed,
      provider_attempts
    )
  end

  defp finish_execution(
         {:error, :wall_time_budget_exhausted, executed, turn_output_bytes},
         run,
         context,
         _state,
         turn,
         provider_operation_id,
         _admission,
         provider_attempts
       ) do
    fail_wall_time(
      run,
      context,
      turn,
      provider_operation_id,
      turn_output_bytes,
      executed,
      provider_attempts
    )
  end

  defp finish_execution(
         {:error, :tool_call_budget_exhausted, executed, turn_output_bytes},
         run,
         context,
         _state,
         turn,
         provider_operation_id,
         _admission,
         provider_attempts
       ) do
    fail_budget(
      run,
      context,
      turn,
      provider_operation_id,
      :tool_call_budget_exhausted,
      "Run Tool-call budget exhausted",
      executed + 1,
      run.budget.max_tool_calls,
      turn_output_bytes,
      executed,
      provider_attempts
    )
  end

  defp finish_execution(
         {:error, :event_sink_failed, _executed},
         run,
         _context,
         _state,
         _turn,
         _provider_operation_id,
         _admission,
         _provider_attempts
       ),
       do: terminal_error(:event_sink_failed, "Run Event sink failed", run.id)

  defp finish_execution(
         {:error, :invalid_tool_context, operation_id, executed},
         run,
         context,
         _state,
         turn,
         _provider_operation_id,
         admission,
         provider_attempts
       ) do
    fail_internal(
      run,
      context,
      turn,
      operation_id,
      :invalid_agent_context,
      "Tool Context is invalid",
      admission.output_bytes,
      executed,
      provider_attempts
    )
  end

  defp finish_execution(
         {:error, :executor_contract, operation_id, executed},
         run,
         context,
         _state,
         turn,
         _provider_operation_id,
         admission,
         provider_attempts
       ) do
    fail_internal(
      run,
      context,
      turn,
      operation_id,
      :tool_executor_contract_failed,
      "Tool Executor violated its Result contract",
      admission.output_bytes,
      executed,
      provider_attempts
    )
  end

  defp continue_after_tools(
         run,
         context,
         state,
         turn,
         provider_operation_id,
         admission,
         results,
         executed,
         turn_output_bytes,
         provider_attempts
       ) do
    with {:ok, next_state} <-
           Projection.append_response(state, context, admission.response, results),
         true <- turn < run.budget.max_turns or {:error, :turn_budget_exhausted},
         true <- not cancelled?(context) or {:error, :run_cancelled},
         true <-
           State.deadline_open?(next_state, monotonic_now()) or
             {:error, :wall_time_budget_exhausted},
         :ok <-
           emit(context, :turn_completed,
             run_id: run.id,
             turn: turn,
             outcome: :continued,
             provider_attempts: provider_attempts,
             tool_calls: executed,
             output_bytes: turn_output_bytes
           ) do
      next_turn(run, context, next_state)
    else
      {:error, :turn_budget_exhausted} ->
        fail_budget(
          run,
          context,
          turn,
          provider_operation_id,
          :turn_budget_exhausted,
          "Run turn budget exhausted",
          turn + 1,
          run.budget.max_turns,
          turn_output_bytes,
          executed,
          provider_attempts
        )

      {:error, :run_cancelled} ->
        fail_cancelled(
          run,
          context,
          turn,
          provider_operation_id,
          turn_output_bytes,
          executed,
          provider_attempts
        )

      {:error, :wall_time_budget_exhausted} ->
        fail_wall_time(
          run,
          context,
          turn,
          provider_operation_id,
          turn_output_bytes,
          executed,
          provider_attempts
        )

      {:error, :event_sink_failed} ->
        terminal_error(:event_sink_failed, "Run Event sink failed", run.id)

      {:error, _reason} ->
        fail_internal(
          run,
          context,
          turn,
          provider_operation_id,
          :conversation_projection_failed,
          "Completed Tool batch could not be projected",
          turn_output_bytes,
          executed,
          provider_attempts
        )
    end
  end

  defp complete(run, context, state, turn, response, text, provider_attempts) do
    turn_output_bytes = byte_size(text)

    with {:ok, completed_state} <- State.add_output(state, turn_output_bytes),
         {:ok, result} <-
           Result.new(
             run_id: run.id,
             text: text,
             final_response: response,
             turns: turn,
             tool_calls: completed_state.tool_calls,
             provider_retries: completed_state.provider_retries,
             output_bytes: completed_state.output_bytes
           ),
         :ok <-
           emit(context, :turn_completed,
             run_id: run.id,
             turn: turn,
             outcome: :completed,
             provider_attempts: provider_attempts,
             tool_calls: 0,
             output_bytes: turn_output_bytes
           ),
         :ok <- emit(context, :run_completed, run_id: run.id, result: result) do
      {:ok, result}
    else
      {:error, :output_budget_exhausted} ->
        fail_budget(
          run,
          context,
          turn,
          nil,
          :output_budget_exhausted,
          "Run output budget exhausted",
          state.output_bytes + turn_output_bytes,
          run.budget.max_output_bytes,
          turn_output_bytes,
          0,
          provider_attempts
        )

      {:error, :counter_overflow} ->
        fail_internal(
          run,
          context,
          turn,
          nil,
          :conversation_projection_failed,
          "Final output accounting overflowed",
          0,
          0,
          provider_attempts
        )

      {:error, :event_sink_failed} ->
        terminal_error(:event_sink_failed, "Run Event sink failed", run.id)

      {:error, _reason} ->
        terminal_error(:invalid_run_request, "Agent Result is invalid", run.id)
    end
  end

  defp fail_protocol(
         run,
         context,
         turn,
         operation_id,
         message,
         reason,
         output_bytes,
         tool_calls,
         provider_attempts
       ) do
    {:ok, error} =
      Error.new(
        kind: :protocol,
        reason: reason,
        message: message,
        run_id: run.id,
        turn: turn,
        operation_id: operation_id,
        details: %{}
      )

    emit_failure(context, error, :failed, output_bytes, tool_calls, provider_attempts)
  end

  defp fail_internal(
         run,
         context,
         turn,
         operation_id,
         reason,
         message,
         output_bytes,
         tool_calls,
         provider_attempts \\ @attempt
       ) do
    {:ok, error} =
      Error.new(
        kind: :internal,
        reason: reason,
        message: message,
        run_id: run.id,
        turn: turn,
        operation_id: operation_id,
        details: %{}
      )

    emit_failure(context, error, :failed, output_bytes, tool_calls, provider_attempts)
  end

  defp fail_budget(
         run,
         context,
         turn,
         operation_id,
         reason,
         message,
         observed,
         maximum,
         output_bytes,
         tool_calls,
         provider_attempts
       ) do
    {:ok, error} =
      Error.new(
        kind: :budget,
        reason: reason,
        message: message,
        run_id: run.id,
        turn: turn,
        operation_id: operation_id,
        details: %{"observed" => observed, "maximum" => maximum}
      )

    emit_failure(context, error, :failed, output_bytes, tool_calls, provider_attempts)
  end

  defp fail_before_turn(run, context, state, reason, message, details) do
    {:ok, error} =
      Error.new(
        kind: :budget,
        reason: reason,
        message: message,
        run_id: run.id,
        turn: state.turn,
        operation_id: nil,
        details: details
      )

    case emit(context, :run_failed, run_id: run.id, error: error) do
      :ok ->
        {:error, error}

      {:error, :event_sink_failed} ->
        terminal_error(:event_sink_failed, "Run Event sink failed", run.id)
    end
  end

  defp fail_before_turn_cancelled(run, context, state) do
    {:ok, error} =
      Error.new(
        kind: :cancelled,
        reason: :run_cancelled,
        message: "Run was cancelled",
        run_id: run.id,
        turn: state.turn,
        operation_id: nil,
        details: %{}
      )

    case emit(context, :run_interrupted, run_id: run.id, error: error) do
      :ok ->
        {:error, error}

      {:error, :event_sink_failed} ->
        terminal_error(:event_sink_failed, "Run Event sink failed", run.id)
    end
  end

  defp fail_cancelled(
         run,
         context,
         turn,
         operation_id,
         output_bytes,
         tool_calls,
         provider_attempts
       ),
       do:
         fail_cancelled(
           run,
           context,
           turn,
           operation_id,
           output_bytes,
           tool_calls,
           provider_attempts,
           %{}
         )

  defp fail_cancelled(
         run,
         context,
         turn,
         operation_id,
         output_bytes,
         tool_calls,
         provider_attempts,
         details
       ) do
    {:ok, error} =
      Error.new(
        kind: :cancelled,
        reason: :run_cancelled,
        message: "Run was cancelled",
        run_id: run.id,
        turn: turn,
        operation_id: operation_id,
        details: details
      )

    emit_failure(context, error, :interrupted, output_bytes, tool_calls, provider_attempts)
  end

  defp fail_wall_time(
         run,
         context,
         turn,
         operation_id,
         output_bytes,
         tool_calls,
         provider_attempts
       ) do
    {:ok, error} =
      Error.new(
        kind: :budget,
        reason: :wall_time_budget_exhausted,
        message: "Run wall-time budget exhausted",
        run_id: run.id,
        turn: turn,
        operation_id: operation_id,
        details: %{"status" => "deadline_elapsed"}
      )

    emit_failure(context, error, :failed, output_bytes, tool_calls, provider_attempts)
  end

  defp handle_provider_error(
         run,
         context,
         state,
         turn,
         provider_request,
         operation_id,
         attempt,
         provider_error
       ) do
    case Provider.Error.new(Map.from_struct(provider_error)) do
      {:ok, %Provider.Error{operation_id: ^operation_id} = provider_error} ->
        cond do
          cancelled?(context) ->
            fail_cancelled(run, context, turn, operation_id, 0, 0, attempt)

          safe_retry?(provider_error) ->
            retry_provider(
              run,
              context,
              state,
              turn,
              provider_request,
              attempt,
              provider_error
            )

          true ->
            emit_provider_error(run, context, turn, operation_id, attempt, provider_error)
        end

      {:ok, %Provider.Error{}} ->
        fail_protocol(
          run,
          context,
          turn,
          operation_id,
          "Provider Error operation ID did not match",
          :empty_provider_response,
          0,
          0,
          attempt
        )

      {:error, _reason} ->
        fail_protocol(
          run,
          context,
          turn,
          operation_id,
          "Provider Error is invalid",
          :empty_provider_response,
          0,
          0,
          attempt
        )
    end
  end

  defp safe_retry?(provider_error) do
    provider_error.retryable and not provider_error.output_started and
      provider_error.kind in [:rate_limited, :unavailable, :timeout, :transport, :upstream]
  end

  defp retry_provider(
         run,
         context,
         state,
         turn,
         provider_request,
         attempt,
         provider_error
       ) do
    case State.admit_provider_retry(state, monotonic_now()) do
      {:ok, retry_state} ->
        retry_ordinal = retry_state.provider_retries

        case wait_for_retry(context, retry_state, retry_ordinal) do
          :ok ->
            next_attempt = attempt + 1

            with {:ok, operation_id} <- OperationId.provider(run.id, turn, next_attempt),
                 {:ok, stream_context} <- stream_context(retry_state, context, operation_id) do
              stream(
                run,
                context,
                retry_state,
                turn,
                provider_request,
                stream_context,
                operation_id,
                next_attempt
              )
            else
              {:error, _reason} ->
                fail_internal(
                  run,
                  context,
                  turn,
                  nil,
                  :invalid_agent_context,
                  "Provider retry context is invalid",
                  0,
                  0,
                  attempt
                )
            end

          {:error, :run_cancelled} ->
            fail_cancelled(run, context, turn, nil, 0, 0, attempt)

          {:error, :wall_time_budget_exhausted} ->
            fail_wall_time(run, context, turn, nil, 0, 0, attempt)

          {:error, :invalid_retry_delay} ->
            fail_internal(
              run,
              context,
              turn,
              nil,
              :invalid_agent_context,
              "Provider retry delay is invalid",
              0,
              0,
              attempt
            )
        end

      {:error, :provider_retry_budget_exhausted} ->
        emit_provider_error(
          run,
          context,
          turn,
          provider_error.operation_id,
          attempt,
          provider_error,
          :provider_retry_exhausted
        )

      {:error, :wall_time_budget_exhausted} ->
        fail_wall_time(run, context, turn, nil, 0, 0, attempt)

      {:error, _reason} ->
        fail_internal(
          run,
          context,
          turn,
          nil,
          :invalid_agent_context,
          "Provider retry accounting failed",
          0,
          0,
          attempt
        )
    end
  end

  defp wait_for_retry(context, state, retry_ordinal) do
    with :ok <- cancellation_guard(context),
         {:ok, delay} <- retry_delay(context, retry_ordinal),
         true <-
           retry_delay_within_deadline?(state.deadline, delay) or
             {:error, :wall_time_budget_exhausted},
         :ok <- await_retry_delay(context, delay),
         :ok <- cancellation_guard(context),
         true <-
           State.deadline_open?(state, monotonic_now()) or
             {:error, :wall_time_budget_exhausted} do
      :ok
    end
  end

  defp retry_delay_within_deadline?(:infinity, _delay), do: true

  defp retry_delay_within_deadline?(deadline, delay),
    do: monotonic_now() + delay < deadline

  defp retry_delay(context, retry_ordinal) do
    try do
      case context.retry_delay.(retry_ordinal) do
        delay when is_integer(delay) and delay >= 0 and delay <= 10_000 -> {:ok, delay}
        _invalid -> {:error, :invalid_retry_delay}
      end
    rescue
      _exception -> {:error, :invalid_retry_delay}
    catch
      _kind, _reason -> {:error, :invalid_retry_delay}
    end
  end

  defp await_retry_delay(context, 0), do: cancellation_guard(context)

  defp await_retry_delay(%Context{cancel_ref: nil}, delay) do
    receive do
    after
      delay -> :ok
    end
  end

  defp await_retry_delay(%Context{cancel_ref: cancel_ref}, delay) do
    receive do
      {:cancel, ^cancel_ref} -> {:error, :run_cancelled}
    after
      delay -> :ok
    end
  end

  defp emit_provider_error(
         run,
         context,
         turn,
         operation_id,
         attempt,
         provider_error,
         reason \\ nil
       ) do
    reason =
      reason ||
        if(provider_error.output_started,
          do: :provider_interrupted_after_output,
          else: :provider_failed
        )

    interrupted? =
      provider_error.output_started or provider_error.kind in [:interrupted, :timeout]

    {:ok, error} =
      Error.new(
        kind: :provider,
        reason: reason,
        message: "Provider request failed",
        run_id: run.id,
        turn: turn,
        operation_id: operation_id,
        details: %{
          "provider_kind" => Atom.to_string(provider_error.kind),
          "http_status" => provider_error.status,
          "retryable" => provider_error.retryable,
          "output_started" => provider_error.output_started,
          "attempts" => attempt
        }
      )

    emit_failure(
      context,
      error,
      if(interrupted?, do: :interrupted, else: :failed),
      0,
      0,
      attempt
    )
  end

  defp emit_failure(
         context,
         error,
         outcome,
         output_bytes,
         tool_calls,
         provider_attempts
       ) do
    terminal_kind = if outcome == :interrupted, do: :run_interrupted, else: :run_failed

    with :ok <-
           emit(context, :turn_completed,
             run_id: error.run_id,
             turn: error.turn,
             outcome: outcome,
             provider_attempts: provider_attempts,
             tool_calls: tool_calls,
             output_bytes: output_bytes
           ),
         :ok <- emit(context, terminal_kind, run_id: error.run_id, error: error) do
      {:error, error}
    else
      {:error, :event_sink_failed} ->
        terminal_error(:event_sink_failed, "Run Event sink failed", error.run_id)
    end
  end

  defp provider_event_sink(run_id, context, turn, operation_id) do
    fn
      %ProviderTextDelta{} = delta ->
        emit(context, :text_delta,
          run_id: run_id,
          turn: turn,
          operation_id: operation_id,
          item_id: delta.item_id,
          content_index: delta.content_index,
          delta: delta.delta
        )

      _event ->
        :ok
    end
  end

  defp emit(context, kind, attrs) do
    with {:ok, event} <- Event.new(kind, attrs),
         true <- callback_ok?(context.event_sink, event) do
      :ok
    else
      _failure -> {:error, :event_sink_failed}
    end
  end

  defp callback_ok?(callback, event) do
    try do
      callback.(event) == :ok
    rescue
      _exception -> false
    catch
      _kind, _reason -> false
    end
  end

  defp stream_context(state, context, operation_id) do
    StreamContext.new(
      operation_id: operation_id,
      cancel_ref: context.cancel_ref,
      inactivity_ms: state.run.budget.provider_inactivity_ms,
      deadline: state.deadline,
      activity_sink: context.provider_activity_sink
    )
  end

  defp normalize_request(%Request{} = request) do
    case Request.new(Map.from_struct(request)) do
      {:ok, request} -> {:ok, request}
      {:error, _reason} -> {:error, :invalid_run_request}
    end
  end

  defp normalize_request(_request), do: {:error, :invalid_run_request}

  defp normalize_context(%Context{} = context) do
    case Context.new(Map.from_struct(context)) do
      {:ok, context} -> {:ok, context}
      {:error, _reason} -> {:error, :invalid_context}
    end
  end

  defp normalize_context(_context), do: {:error, :invalid_context}

  defp normalize_response(%Response{} = response) do
    case Response.new(Map.from_struct(response)) do
      {:ok, response} -> {:ok, response}
      {:error, _reason} -> {:error, :invalid_response}
    end
  end

  defp normalize_response(_response), do: {:error, :invalid_response}

  defp function_call_response?(%Response{output_items: output_items}) when is_list(output_items),
    do: Enum.any?(output_items, &is_struct(&1, FunctionCall))

  defp function_call_response?(_response), do: false

  defp safe_run_id(%Request{} = request), do: request.id
  defp safe_run_id(_request), do: "invalid-run"

  defp terminal_error(reason, message, run_id, details \\ %{}) do
    {:ok, error} =
      Error.new(
        kind: :internal,
        reason: reason,
        message: message,
        run_id: run_id,
        turn: 0,
        operation_id: nil,
        details: details
      )

    {:error, error}
  end
end
