defmodule Synapse.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/LazyYuuki/synapse"

  def project do
    [
      app: :synapse,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      description: "A minimal, failure-tolerant coding-agent harness for the BEAM",
      source_url: @source_url,
      deps: deps(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Synapse.Application, []}
    ]
  end

  defp deps do
    [
      {:req, "~> 0.7.1"},
      {:muontrap, "== 1.8.0"},
      {:ex_doc, "~> 0.40.3", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "main",
      source_url: @source_url,
      extras: [
        "README.md",
        "docs/PROVIDERS.md",
        "docs/plan/PLAN.md",
        "docs/plan/PLAN-PROVIDER.md",
        "docs/plan/PLAN-WORKSPACE.md",
        "docs/plan/PLAN-TOOL-SYSTEM.md",
        "docs/learning/MIX.md",
        "docs/learning/PROVIDER.md",
        "docs/learning/WORKSPACE.md",
        "docs/CLAUDE-HARNESS.md"
      ],
      groups_for_extras: [
        Architecture: ["docs/PROVIDERS.md"],
        Plans: [
          "docs/plan/PLAN.md",
          "docs/plan/PLAN-PROVIDER.md",
          "docs/plan/PLAN-WORKSPACE.md",
          "docs/plan/PLAN-TOOL-SYSTEM.md"
        ],
        Learning: [
          "docs/learning/MIX.md",
          "docs/learning/PROVIDER.md",
          "docs/learning/WORKSPACE.md"
        ],
        Research: ["docs/CLAUDE-HARNESS.md"]
      ],
      groups_for_modules: [
        "Workspace Facade And Core": [
          Synapse.Workspace,
          Synapse.Workspace.Real,
          Synapse.Workspace.Fake,
          Synapse.Workspace.Fake.Entry,
          Synapse.Workspace.OpenRequest,
          Synapse.Workspace.Handle,
          Synapse.Workspace.Access,
          Synapse.Workspace.Limits,
          Synapse.Workspace.OperationContext,
          Synapse.Workspace.Revision,
          Synapse.Workspace.Error
        ],
        "Workspace Files": [
          Synapse.Workspace.ReadRequest,
          Synapse.Workspace.ReadLine,
          Synapse.Workspace.ReadResult,
          Synapse.Workspace.WriteRequest,
          Synapse.Workspace.EditRequest,
          Synapse.Workspace.MutationResult
        ],
        "Workspace Processes": [
          Synapse.Workspace.ProcessSpec,
          Synapse.Workspace.ProcessEvent,
          Synapse.Workspace.ProcessEvent.Started,
          Synapse.Workspace.ProcessEvent.Output,
          Synapse.Workspace.ProcessResult
        ],
        "Provider Contracts": [
          Synapse.Provider,
          Synapse.Provider.Request,
          Synapse.Provider.Response,
          Synapse.Provider.Error,
          Synapse.Provider.StreamContext,
          Synapse.Provider.Event,
          Synapse.Provider.OutputItem
        ],
        "Provider Events": [
          Synapse.Provider.Event.MessageStarted,
          Synapse.Provider.Event.TextDelta,
          Synapse.Provider.Event.ToolCallStarted,
          Synapse.Provider.Event.ToolCallDelta,
          Synapse.Provider.Event.ToolCallCompleted,
          Synapse.Provider.Event.MessageCompleted,
          Synapse.Provider.Event.Diagnostic
        ],
        "Provider Output": [
          Synapse.Provider.OutputItem.Message,
          Synapse.Provider.OutputItem.FunctionCall
        ],
        "Responses Wire": [
          Synapse.Provider.ResponsesCodec,
          Synapse.Provider.SSEDecoder,
          Synapse.Provider.SSEDecoder.Error,
          Synapse.Provider.SSEEvent,
          Synapse.Provider.ResponsesStream
        ],
        "Provider Implementations": [
          Synapse.Provider.Tokamak,
          Synapse.Provider.Fake,
          Synapse.Provider.Credentials,
          Synapse.Provider.Credentials.Secret
        ]
      ]
    ]
  end
end
