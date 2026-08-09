defmodule Synapse.Agent.ContextWindowTest do
  use ExUnit.Case, async: true

  alias Synapse.Agent.ContextWindow
  alias Synapse.Tool.Registry

  test "fixed estimate includes instructions, Tool schemas, envelope, and reserve" do
    assert {:ok, empty_fixed} = ContextWindow.fixed_input_tokens("", [])
    assert {:ok, tools_fixed} = ContextWindow.fixed_input_tokens("", Registry.specifications())

    assert {:ok, instructions_fixed} =
             ContextWindow.fixed_input_tokens(
               String.duplicate("instruction ", 100),
               Registry.specifications()
             )

    assert empty_fixed > 0
    assert tools_fixed > empty_fixed
    assert instructions_fixed > tools_fixed
  end

  test "estimates structured history and current prompt at bytes divided by three" do
    conversation = [
      %{"role" => "user", "content" => "Earlier question"},
      %{"role" => "assistant", "content" => "Earlier answer"}
    ]

    assert {:ok, without_fixed} =
             ContextWindow.estimate_tokens(conversation, "Current question", 1)

    assert {:ok, with_fixed} =
             ContextWindow.estimate_tokens(conversation, "Current question", 101)

    assert with_fixed - without_fixed == 100

    assert {:ok, longer} =
             ContextWindow.estimate_tokens(
               conversation,
               "Current question" <> String.duplicate("x", 3),
               101
             )

    assert longer == with_fixed + 1
    assert ContextWindow.max_input_tokens() == 272_000
  end

  test "rejects malformed estimator inputs without raising" do
    assert {:error, :invalid_fixed_context} = ContextWindow.fixed_input_tokens(<<255>>, [])
    assert {:error, :invalid_fixed_context} = ContextWindow.fixed_input_tokens("ok", %{})
    assert {:error, :invalid_dynamic_context} = ContextWindow.estimate_tokens([], <<255>>, 1)
    assert {:error, :invalid_dynamic_context} = ContextWindow.estimate_tokens([], "ok", 0)
  end
end
