defmodule Synapse do
  @moduledoc """
  The public namespace for the Synapse coding-agent harness.

  Synapse is being built as a set of explicit components: providers, workspace
  operations, tools, the agent loop, runtime supervision, and user interfaces.
  Provider and Workspace are implemented foundations. Tool contracts, static
  registry, one-call Executor, bounded presentation, and the Read, Write, Edit, and
  Bash adapters are in place. The project does not yet expose a product-level run
  API because the Agent Loop, Runtime operations, and CLI remain intentionally
  absent.

  Start with the project architecture in `README.md` and the implementation
  sequence in `docs/plan/PLAN.md` when learning or contributing to the system.
  """
end
