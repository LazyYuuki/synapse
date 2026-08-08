defmodule Synapse.BudgetTest do
  use ExUnit.Case, async: true

  alias Synapse.Budget

  doctest Budget

  test "constructs defaults and trusted lowering" do
    assert Budget.default() == %Budget{
             max_turns: 20,
             max_tool_calls: 50,
             max_wall_time_ms: 900_000,
             provider_inactivity_ms: 120_000,
             tool_inactivity_ms: 180_000,
             max_output_bytes: 524_288,
             max_provider_retries: 2
           }

    assert {:ok, budget} =
             Budget.new(
               max_turns: 1,
               max_tool_calls: 1,
               max_wall_time_ms: 1,
               provider_inactivity_ms: 1,
               tool_inactivity_ms: 1,
               max_output_bytes: 1,
               max_provider_retries: 0
             )

    assert Budget.valid?(budget)
    assert budget.max_provider_retries == 0
  end

  test "accepts every exact hard maximum" do
    assert {:ok, budget} =
             Budget.new(
               max_turns: 100,
               max_tool_calls: 500,
               max_wall_time_ms: 3_600_000,
               provider_inactivity_ms: 900_000,
               tool_inactivity_ms: 900_000,
               max_output_bytes: 4_194_304,
               max_provider_retries: 5
             )

    assert Budget.valid?(budget)
  end

  test "rejects zero, negative, non-integer, and above-ceiling values" do
    fields = Map.keys(Map.from_struct(Budget.default()))

    Enum.each(fields -- [:max_provider_retries], fn field ->
      assert {:error, {^field, :must_be_in_recorded_range}} = Budget.new(%{field => 0})
      assert {:error, {^field, :must_be_in_recorded_range}} = Budget.new(%{field => -1})
      assert {:error, {^field, :must_be_in_recorded_range}} = Budget.new(%{field => 1.0})
    end)

    assert {:error, {:max_provider_retries, :must_be_in_recorded_range}} =
             Budget.new(max_provider_retries: -1)

    above = %{
      max_turns: 101,
      max_tool_calls: 501,
      max_wall_time_ms: 3_600_001,
      provider_inactivity_ms: 900_001,
      tool_inactivity_ms: 900_001,
      max_output_bytes: 4_194_305,
      max_provider_retries: 6
    }

    Enum.each(above, fn {field, value} ->
      assert {:error, {^field, :must_be_in_recorded_range}} = Budget.new(%{field => value})
    end)
  end

  test "rejects unknown and malformed attributes without echoing arbitrary keys" do
    assert {:error, {:unknown_fields, [:unexpected]}} = Budget.new(unexpected: 1)
    assert {:error, {:unknown_fields, [:unknown]}} = Budget.new(%{"secret-key" => 1})

    assert {:error, {:attributes, :must_be_keyword_or_map}} =
             Budget.new([{:max_turns, 1} | :bad])

    %Budget{} = default = Budget.default()
    refute Budget.valid?(%Budget{default | max_turns: 0})
    refute Budget.valid?(%{})
  end
end
