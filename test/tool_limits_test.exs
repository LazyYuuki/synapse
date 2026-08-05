defmodule Synapse.Tool.LimitsTest do
  use ExUnit.Case, async: true

  alias Synapse.Tool.Limits
  alias Synapse.Workspace.Limits, as: WorkspaceLimits

  test "defaults match the Phase 0 decision record" do
    limits = Limits.default()

    assert limits.max_call_id_bytes == 512
    assert limits.max_argument_json_bytes == 64_000
    assert limits.max_schema_bytes_per_tool == 16_384
    assert limits.max_result_content_bytes == 64_000
    assert limits.max_result_metadata_json_bytes == 4_096
    assert limits.max_operation_id_bytes == 256
    assert limits.default_read_lines == 100
    assert limits.max_read_lines == 1_000
    assert limits.default_bash_timeout_ms == 300_000
    assert limits.max_bash_timeout_ms == 900_000
    assert Limits.valid?(limits)
  end

  test "every field is positive, lowerable, and capped by its default hard maximum" do
    defaults = Limits.default() |> Map.from_struct()

    minimums =
      Map.new(defaults, fn
        {:max_result_content_bytes, _value} -> {:max_result_content_bytes, 256}
        {:max_result_metadata_json_bytes, _value} -> {:max_result_metadata_json_bytes, 2}
        {:max_error_message_bytes, _value} -> {:max_error_message_bytes, 128}
        {field, _value} -> {field, 1}
      end)

    assert {:ok, %Limits{} = minimum_limits} = Limits.new(minimums)
    assert minimum_limits.max_result_content_bytes == 256
    assert minimum_limits.max_result_metadata_json_bytes == 2
    assert minimum_limits.max_error_message_bytes == 128

    assert Enum.all?(
             Map.drop(Map.from_struct(minimum_limits), [
               :max_result_content_bytes,
               :max_result_metadata_json_bytes,
               :max_error_message_bytes
             ]),
             fn {_field, value} -> value == 1 end
           )

    Enum.each(defaults, fn {field, maximum} ->
      assert {:error, {^field, :must_be_reasonable_positive_integer}} =
               Limits.new([{field, maximum + 1}])

      assert {:error, {^field, :must_be_reasonable_positive_integer}} =
               Limits.new([{field, 0}])
    end)
  end

  test "result protocol floors always permit fixed paired diagnostics" do
    assert {:ok, _limits} =
             Limits.new(max_result_content_bytes: 256, max_result_metadata_json_bytes: 2)

    assert {:error, {:max_result_content_bytes, :must_be_reasonable_positive_integer}} =
             Limits.new(max_result_content_bytes: 255)

    assert {:error, {:max_result_metadata_json_bytes, :must_be_reasonable_positive_integer}} =
             Limits.new(max_result_metadata_json_bytes: 1)

    assert {:error, {:max_error_message_bytes, :must_be_reasonable_positive_integer}} =
             Limits.new(max_error_message_bytes: 127)
  end

  test "default values cannot exceed their lowered related maximums" do
    relationships = [
      {:default_read_lines, :max_read_lines},
      {:default_read_source_bytes, :max_read_source_bytes},
      {:default_bash_output_bytes, :max_bash_output_bytes},
      {:default_bash_timeout_ms, :max_bash_timeout_ms},
      {:default_bash_inactivity_ms, :max_bash_inactivity_ms}
    ]

    Enum.each(relationships, fn {default, maximum} ->
      assert {:error, {^default, :must_not_exceed_related_maximum}} =
               Limits.new([{maximum, 1}])

      assert {:ok, limits} = Limits.new([{default, 1}, {maximum, 1}])
      assert Map.fetch!(limits, default) == Map.fetch!(limits, maximum)
    end)
  end

  test "rejects unknown, malformed, and forged limit data" do
    %Limits{} = defaults = Limits.default()

    assert {:error, {:unknown_fields, [:other]}} = Limits.new(other: 1)

    assert {:error, {:attributes, :must_be_keyword_or_map}} =
             Limits.new([{:max_call_id_bytes, 1} | :bad])

    assert {:error, {:max_call_id_bytes, :must_be_reasonable_positive_integer}} =
             Limits.new(max_call_id_bytes: 1.0)

    refute Limits.valid?(%Limits{defaults | max_argument_entries: 0})
    refute Limits.valid?(%{})
  end

  test "compares every delegated Tool ceiling with validated Workspace limits" do
    tool = Limits.default()
    workspace = WorkspaceLimits.default()

    assert Limits.fits_workspace?(tool, workspace)

    {:ok, narrow_reads} =
      WorkspaceLimits.new(default_read_lines: tool.default_read_lines - 1)

    refute Limits.fits_workspace?(tool, narrow_reads)
    refute Limits.fits_workspace?(%{tool | max_path_bytes: 0}, workspace)
    refute Limits.fits_workspace?(tool, %{workspace | max_path_bytes: 0})
    refute Limits.fits_workspace?(%{}, workspace)
    refute Limits.fits_workspace?(tool, %{})
  end
end
