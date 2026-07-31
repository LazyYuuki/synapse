defmodule Synapse do
  @moduledoc """
  The public namespace for the Synapse coding-agent harness.

  Synapse is being built as a set of explicit components: providers, workspace
  operations, tools, the agent loop, runtime supervision, and user interfaces.
  Provider and Workspace are implemented foundations. The project does not yet
  expose a product-level run API because model-facing tools, the Agent Loop,
  Runtime operations, and the CLI remain intentionally absent.

  Start with the project architecture in `README.md` and the implementation
  sequence in `docs/plan/PLAN.md` when learning or contributing to the system.
  """
end
