defmodule Synapse do
  @moduledoc """
  The public namespace for the Synapse coding-agent harness.

  Synapse is being built as a set of explicit components: providers, workspace
  operations, tools, the agent loop, runtime supervision, and user interfaces.
  Provider and Workspace are implemented foundations. Tool contracts, static
  registry, one-call Executor, bounded presentation, and the Read, Write, Edit,
  and Bash adapters are in place. Agent Loop Phases 0-10 now provide Budget, Run,
  Context, State, Result, Error, Event, full-history projection, immutable Provider
  Requests, deterministic operation IDs, and one synchronous text-only Provider
  turn, pure whole-batch FunctionCall admission, sequential Tool execution,
  immutable full-history continuation, checked aggregate budget/deadline
  enforcement, safe Provider retry, interruption, and persistent cancellation
  policy, deterministic full-loop integration, temporary Real Workspace evidence,
  opt-in live Tokamak acceptance, and the final reliability, security, and ExDoc
  review. Runtime operations and CLI remain absent.

  Start with the project architecture in `README.md` and the implementation
  sequence in `docs/plan/PLAN.md` when learning or contributing to the system. The
  Agent maintenance guide is `docs/learning/AGENT-LOOP.md`.
  """
end
