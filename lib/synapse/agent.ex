defmodule Synapse.Agent do
  @moduledoc """
  Defines the UI-independent boundary for one bounded model-Tool loop.

  `Synapse.Agent.Runner` owns immutable conversation state plus semantic turn,
  retry, Tool-order, budget, and terminal policy. It projects complete
  Provider/Tool turns through full conversation history and
  continues until final text or a structured terminal. Provider owns transport,
  Tool Executor owns one validated operation, Workspace owns host effects, and
  Runtime will own supervised process lifetime. Safe pre-output Provider retries
  and persistent cancellation observation remain Agent semantic policy.

  See `docs/learning/AGENT-LOOP.md` for ownership, projection, security, testing,
  and deferred-work guidance.

  ## Text-only Fake example

      iex> {:ok, capabilities} = Synapse.Tool.CapabilitySet.new(
      ...>   fs_read: false, fs_write: false, process_exec: false
      ...> )
      iex> {:ok, run} = Synapse.Run.Request.new(
      ...>   id: "runner-doc", prompt: "Answer.", cwd: "/tmp/project",
      ...>   model: "test-model", capabilities: capabilities,
      ...>   budget: Synapse.Budget.default()
      ...> )
      iex> {:ok, workspace} = Synapse.Workspace.Fake.open([])
      iex> {:ok, context} = Synapse.Agent.Context.new(
      ...>   provider: Synapse.Provider.Fake, workspace: workspace,
      ...>   event_sink: fn _event -> :ok end
      ...> )
      iex> {:ok, state} = Synapse.Agent.Projection.initial_state(run, context, 0)
      iex> {:ok, expected_request} = Synapse.Agent.Projection.provider_request(state, context)
      iex> {:ok, operation_id} = Synapse.Agent.OperationId.provider(run.id, 1, 1)
      iex> {:ok, response} = Synapse.Provider.Response.new(
      ...>   id: "response-doc", model: "test-model",
      ...>   output_items: [
      ...>     %Synapse.Provider.OutputItem.Message{
      ...>       id: "message-doc", role: :assistant, content: "Finished"
      ...>     }
      ...>   ]
      ...> )
      iex> result = Synapse.Provider.Fake.with_script(
      ...>   operation_id,
      ...>   [{:turn, expected_request, [], {:ok, response}}],
      ...>   fn -> Synapse.Agent.Runner.run(run, context) end
      ...> )
      iex> {:ok, agent_result} = result
      iex> agent_result.text
      "Finished"
      iex> Synapse.Workspace.close(workspace)
      :ok

  ## Provider-to-Tool-to-final Fake example

      iex> {:ok, capabilities} = Synapse.Tool.CapabilitySet.new(
      ...>   fs_read: false, fs_write: false, process_exec: false
      ...> )
      iex> {:ok, run} = Synapse.Run.Request.new(
      ...>   id: "runner-loop-doc", prompt: "Try a tool.", cwd: "/tmp/project",
      ...>   model: "test-model", capabilities: capabilities,
      ...>   budget: Synapse.Budget.default()
      ...> )
      iex> {:ok, workspace} = Synapse.Workspace.Fake.open([])
      iex> {:ok, context} = Synapse.Agent.Context.new(
      ...>   provider: Synapse.Provider.Fake, workspace: workspace,
      ...>   event_sink: fn _event -> :ok end
      ...> )
      iex> call = %Synapse.Provider.OutputItem.FunctionCall{
      ...>   id: "item-doc", call_id: "call-doc", name: "not_registered", arguments: %{}
      ...> }
      iex> {:ok, call_response} = Synapse.Provider.Response.new(
      ...>   id: "response-call-doc", model: "test-model", output_items: [call]
      ...> )
      iex> final_message = %Synapse.Provider.OutputItem.Message{
      ...>   id: "message-final-doc", role: :assistant, content: "Corrected and finished"
      ...> }
      iex> {:ok, final_response} = Synapse.Provider.Response.new(
      ...>   id: "response-final-doc", model: "test-model", output_items: [final_message]
      ...> )
      iex> {:ok, first_id} = Synapse.Agent.OperationId.provider(run.id, 1, 1)
      iex> {:ok, second_id} = Synapse.Agent.OperationId.provider(run.id, 2, 1)
      iex> result = Synapse.Provider.Fake.with_script(
      ...>   [first_id, second_id],
      ...>   [
      ...>     {:turn, [], {:ok, call_response}},
      ...>     {:turn, [], {:ok, final_response}}
      ...>   ],
      ...>   fn -> Synapse.Agent.Runner.run(run, context) end
      ...> )
      iex> {:ok, agent_result} = result
      iex> {agent_result.turns, agent_result.tool_calls, agent_result.text}
      {2, 1, "Corrected and finished"}
      iex> Synapse.Workspace.close(workspace)
      :ok
  """

  @typedoc "Successful or structured failed completion of one Agent run."
  @type result :: {:ok, Synapse.Agent.Result.t()} | {:error, Synapse.Agent.Error.t()}
end
