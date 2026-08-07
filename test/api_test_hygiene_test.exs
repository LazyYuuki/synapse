defmodule Synapse.API.TestHygieneTest do
  use ExUnit.Case, async: true

  test "API tests use bounded receives and no finite sleeps" do
    violations =
      __DIR__
      |> Path.join("api_*test.exs")
      |> Path.wildcard()
      |> Enum.reject(&(Path.expand(&1) == Path.expand(__ENV__.file)))
      |> Enum.flat_map(&violations/1)

    assert violations == [],
           "API test hygiene violations:\n" <>
             Enum.map_join(violations, "\n", &format_violation/1)
  end

  defp violations(path) do
    ast = path |> File.read!() |> Code.string_to_quoted!(file: path)

    {_ast, violations} =
      Macro.prewalk(ast, [], fn
        {:receive, metadata, [blocks]} = node, violations when is_list(blocks) ->
          violations =
            if Keyword.has_key?(blocks, :after) do
              violations
            else
              [{path, metadata[:line], "receive without after"} | violations]
            end

          {node, violations}

        {{:., _, [{:__aliases__, _, [:Process]}, :sleep]}, metadata, arguments} = node,
        violations ->
          {node, sleep_violation(path, metadata, arguments, violations)}

        {{:., _, [:timer, :sleep]}, metadata, arguments} = node, violations ->
          {node, sleep_violation(path, metadata, arguments, violations)}

        node, violations ->
          {node, violations}
      end)

    Enum.reverse(violations)
  end

  defp sleep_violation(_path, _metadata, [:infinity], violations), do: violations

  defp sleep_violation(path, metadata, _arguments, violations) do
    [{path, metadata[:line], "finite sleep"} | violations]
  end

  defp format_violation({path, line, message}),
    do: "#{Path.relative_to_cwd(path)}:#{line}: #{message}"
end
