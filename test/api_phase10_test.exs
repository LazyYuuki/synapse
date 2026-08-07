defmodule Synapse.API.Phase10Test do
  use ExUnit.Case, async: true

  doctest Synapse.API.Config
  doctest Synapse.API.Protocol
  doctest Synapse.API.Wire

  @api_modules [
    Mix.Tasks.Synapse.Server,
    Synapse.API.Config,
    Synapse.API.Protocol,
    Synapse.API.ConfirmedTerminal,
    Synapse.API.Wire,
    Synapse.API.RunManager,
    Synapse.API.RunSession,
    Synapse.API.Socket,
    Synapse.API.Router,
    Synapse.API.SessionSupervisor,
    Synapse.API.Supervisor
  ]

  @documented_api %{
    Synapse.API.Config => [
      default: 0,
      new: 1,
      load: 2,
      valid?: 1,
      lower_budget: 2,
      max_incoming_frame_wire_bytes: 1
    ],
    Synapse.API.Protocol => [decode: 2],
    Synapse.API.ConfirmedTerminal => [
      from_pending: 3,
      from_runtime: 4,
      internal_contract_failed: 3,
      valid?: 2
    ],
    Synapse.API.Wire => [
      hello: 1,
      error: 3,
      run_accepted: 3,
      cancel_requested: 4,
      snapshot: 3,
      async_snapshot: 2,
      event: 4,
      owner_lost: 3,
      terminal: 2,
      pong: 2
    ],
    Synapse.API.RunManager => [
      start_link: 1,
      start_run: 2,
      cancel: 2,
      subscribe: 3,
      pull: 3,
      unsubscribe: 2,
      unsubscribe_all: 1,
      register_runtime_run: 3,
      record_event: 2,
      settle: 3
    ],
    Synapse.API.SessionSupervisor => [start_link: 1],
    Synapse.API.Supervisor => [start_link: 1, child_specs: 1, listener: 1]
  }

  test "public local API modules and supported functions have documentation" do
    Enum.each(@api_modules, fn module ->
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

  test "internal command, state, policy, and socket contracts stay out of public ExDoc" do
    for module <- [
          Synapse.API.Command,
          Synapse.API.Policy,
          Synapse.API.Projection,
          Synapse.API.RunRecord,
          Synapse.API.Router.Arguments,
          Synapse.API.Socket.Arguments,
          Synapse.API.Socket.State,
          Synapse.API.RunSession.RuntimeBoundary,
          Synapse.API.RunSession.State,
          Synapse.API.TerminalError
        ] do
      {:docs_v1, _annotation, _language, _format, :hidden, _metadata, _docs} =
        Code.fetch_docs(module)
    end
  end

  test "maintenance guide contains the protocol and all comprehension traces" do
    guide = File.read!(project_path("docs/learning/API.md"))

    for section <- [
          "# Local API Maintenance Guide",
          "## Protocol V1 Reference",
          "## Process And Authority Map",
          "## Start And Admission Trace",
          "## Event And Terminal Trace",
          "## Cancellation And Cursor Races",
          "## Replay And Failure Consequences",
          "## Wire Content And Authority Boundary",
          "## Deterministic Verification Map"
        ] do
      assert guide =~ section
    end

    for phrase <- [
          "process-lifetime",
          "same-user process",
          "cannot interrupt synchronous\nWorkspace opening",
          "runtime_lost",
          "RunManager exits",
          "Provider `final_response`",
          "excluded from normal"
        ] do
      assert guide =~ phrase
    end
  end

  test "ExDoc includes the API extras and dedicated module group" do
    mix_source = File.read!(project_path("mix.exs"))

    assert count_occurrences(mix_source, "docs/plan/PLAN-API.md") == 2
    assert count_occurrences(mix_source, "docs/learning/API.md") == 2
    assert mix_source =~ ~s("Local WebSocket API")
    assert mix_source =~ "Mix.Tasks.Synapse.Server"
  end

  test "active architecture docs describe API as a higher process-lifetime adapter" do
    readme = File.read!(project_path("README.md"))
    runtime = File.read!(project_path("docs/learning/RUNTIME.md"))
    agent = File.read!(project_path("docs/learning/AGENT-LOOP.md"))

    assert readme =~ "The higher API adapter adds ephemeral run lookup"
    assert readme =~ "not RunManager/application restart"
    assert runtime =~ "higher local API adds bounded process-lifetime lookup"
    assert agent =~ "The higher local API owns ephemeral"

    refute readme =~ "there is no durable sequence, Registry lookup, subscription, replay"
    refute agent =~ "trusted caller or future CLI"
  end

  test "all relative Markdown documentation links resolve" do
    markdown_paths =
      [project_path("README.md") | Path.wildcard(project_path("docs/**/*.md"))]

    Enum.each(markdown_paths, fn source_path ->
      source = File.read!(source_path)

      for [target] <- Regex.scan(~r/\]\((?!https?:|mailto:)([^)#]+\.md)(?:#[^)]+)?\)/, source) do
        resolved = Path.expand(target, Path.dirname(source_path))
        assert File.regular?(resolved), "#{source_path} links to missing #{target}"
      end
    end)
  end

  defp project_path(path), do: Path.join([__DIR__, "..", path])

  defp count_occurrences(source, pattern) do
    source
    |> :binary.matches(pattern)
    |> length()
  end
end
