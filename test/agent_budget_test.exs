defmodule Synapse.Agent.AccountingTest do
  use ExUnit.Case, async: true

  alias Synapse.Agent.State
  alias Synapse.Run.Request
  alias Synapse.Tool.CapabilitySet

  test "State counters account for work without aggregate run ceilings" do
    {:ok, budget} = Synapse.Budget.new(max_turns: 1, max_tool_calls: 1, max_output_bytes: 1)
    state = state(budget)

    assert {:ok, first_turn} = State.admit_turn(state, 101)
    assert {:ok, second_turn} = State.admit_turn(first_turn, 102)
    assert second_turn.turn == 2

    assert {:ok, first_tool} = State.admit_tool(second_turn, 103)
    assert {:ok, second_tool} = State.admit_tool(first_tool, 104)
    assert second_tool.tool_calls == 2

    assert {:ok, first_retry} = State.admit_provider_retry(second_tool, 105)
    assert {:ok, second_retry} = State.admit_provider_retry(first_retry, 106)
    assert second_retry.provider_retries == 2

    assert {:ok, first_output} = State.add_output(second_retry, 1)
    assert {:ok, second_output} = State.add_output(first_output, 1)
    assert second_output.output_bytes == 2
  end

  test "only an explicit Runtime deadline bounds the run lifetime" do
    infinite = state(Synapse.Budget.default())
    assert infinite.deadline == :infinity
    assert State.deadline_open?(infinite, 9_223_372_036_854_775_807)

    finite = state(Synapse.Budget.default(), 150)
    assert State.deadline_open?(finite, 149)
    refute State.deadline_open?(finite, 150)
    assert {:error, :wall_time_budget_exhausted} = State.admit_turn(finite, 150)
  end

  test "signed accounting overflow remains a representation failure" do
    state = state(Synapse.Budget.default())

    assert {:error, :counter_overflow} =
             State.add_output(state, 9_223_372_036_854_775_808)
  end

  defp state(budget, deadline \\ :infinity) do
    {:ok, capabilities} =
      CapabilitySet.new(fs_read: true, fs_write: true, process_exec: true)

    {:ok, run} =
      Request.new(
        id: "accounting-run",
        prompt: "Inspect",
        cwd: "/tmp/project",
        model: "test-model",
        capabilities: capabilities,
        budget: budget
      )

    {:ok, state} =
      State.new(
        run: run,
        input_items: [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => run.prompt}]
          }
        ],
        started_at: 100,
        deadline: deadline
      )

    state
  end
end
