defmodule Synapse.Runtime.Phase10Test do
  use ExUnit.Case, async: false

  doctest Synapse.Runtime

  @runtime_modules [
    Synapse.Application,
    Synapse.Supervisor,
    Synapse.Runtime,
    Synapse.Runtime.Options,
    Synapse.Runtime.Run,
    Synapse.Runtime.Error,
    Synapse.Runtime.AgentTask,
    Synapse.Runtime.Supervisor,
    Synapse.Runtime.RunServer,
    Synapse.Runtime.RunServer.State,
    Synapse.Runtime.RunServer.Message,
    Synapse.Workspace.Supervisor
  ]

  @documented_api %{
    Synapse.Runtime => [start_run: 3, cancel: 1, await: 2],
    Synapse.Runtime.Options => [new: 1, valid?: 1],
    Synapse.Runtime.Run => [valid?: 1],
    Synapse.Runtime.Error => [new: 1, valid?: 1],
    Synapse.Runtime.Supervisor => [start_link: 1],
    Synapse.Runtime.RunServer => [valid_cancellation_cell?: 1, valid_await_cell?: 1],
    Synapse.Runtime.RunServer.State => [new: 1],
    Synapse.Runtime.RunServer.Message => [
      ready: 3,
      ready_failed: 4,
      started: 3,
      start_failed: 4,
      accept: 1,
      abort: 1,
      terminal: 2
    ],
    Synapse.Supervisor => [start_link: 1, child_specs: 1],
    Synapse.Workspace.Supervisor => [start_link: 1]
  }

  test "Runtime modules and supported functions have generated documentation" do
    Enum.each(@runtime_modules, fn module ->
      {:docs_v1, _annotation, _language, _format, module_doc, _metadata, _docs} =
        Code.fetch_docs(module)

      assert is_map(module_doc), "#{inspect(module)} has no module documentation"
      assert map_size(module_doc) > 0
    end)

    Enum.each(@documented_api, fn {module, functions} ->
      {:docs_v1, _annotation, _language, _format, _module_doc, _metadata, docs} =
        Code.fetch_docs(module)

      documented =
        Map.new(docs, fn {{kind, name, arity}, _line, _signature, doc, _metadata} ->
          {{kind, name, arity}, doc}
        end)

      Enum.each(functions, fn {name, arity} ->
        assert is_map(documented[{:function, name, arity}]),
               "#{inspect(module)}.#{name}/#{arity} has no public function documentation"
      end)
    end)
  end

  test "internal exported hooks are hidden only with explicit module rationale" do
    runtime_root = Path.join([__DIR__, "..", "lib", "synapse", "runtime"])
    sources = Path.wildcard(Path.join(runtime_root, "*.ex")) |> Enum.map(&File.read!/1)
    joined = Enum.join(sources, "\n")

    refute joined =~ "@moduledoc false"
    assert length(Regex.scan(~r/^\s*@doc false$/m, joined)) == 7
    assert joined =~ "intentionally `@doc false`"

    assert hidden_doc?(Synapse.Runtime.AgentTask, :run, 6)
    assert hidden_doc?(Synapse.Runtime.Supervisor, :start_run_server, 3)
    assert hidden_doc?(Synapse.Runtime.RunServer, :emit_event, 4)
  end

  test "maintenance guide covers every required lifecycle explanation and diagram" do
    guide = File.read!(Path.join([__DIR__, "..", "docs", "learning", "RUNTIME.md"]))

    required_sections = [
      "# Runtime Maintenance Guide",
      "## Running Process Tree",
      "## Why RunServer Is A GenServer And Agent Is A Task",
      "## Start And Workspace Handshake",
      "## Progress And Normal Completion",
      "## Cancellation",
      "## Crash Classification",
      "## Deadlines And Timeouts",
      "## Application Shutdown",
      "## Examples",
      "## Security And Limitations",
      "## Deferred Architecture",
      "## Comprehension Check"
    ]

    Enum.each(required_sections, &assert(guide =~ &1))

    for phrase <- [
          "temporary",
          "never restarted",
          "Workspace settlement",
          "persistent",
          "tool_ambiguous",
          "await timeout",
          "no persistent daemon"
        ] do
      assert guide =~ phrase
    end

    mix_source = File.read!(Path.join([__DIR__, "..", "mix.exs"]))
    assert count_occurrences(mix_source, "docs/learning/RUNTIME.md") == 2
    assert mix_source =~ "Runtime Contracts And Supervision"
  end

  test "implemented lower-component docs no longer describe Runtime ownership as future" do
    paths = [
      "lib/synapse/agent.ex",
      "lib/synapse/agent/runner.ex",
      "docs/learning/AGENT-LOOP.md",
      "docs/learning/WORKSPACE.md",
      "docs/learning/MIX.md",
      "docs/PROVIDERS.md",
      "docs/plan/PLAN-AGENT-LOOP.md"
    ]

    source =
      paths
      |> Enum.map(&File.read!(Path.join([__DIR__, "..", &1])))
      |> Enum.join("\n")

    refute source =~ "future Runtime"
    refute source =~ "Runtime will later"
    refute source =~ "future Runtime process supervision"
  end

  defp hidden_doc?(module, name, arity) do
    {:docs_v1, _annotation, _language, _format, _module_doc, _metadata, docs} =
      Code.fetch_docs(module)

    Enum.any?(docs, fn
      {{:function, ^name, ^arity}, _line, _signature, :hidden, _metadata} -> true
      _entry -> false
    end)
  end

  defp count_occurrences(source, pattern) do
    source
    |> :binary.matches(pattern)
    |> length()
  end
end
