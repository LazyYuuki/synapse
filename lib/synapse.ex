defmodule Synapse do
  @moduledoc """
  The public namespace for the Synapse coding-agent harness.

  Synapse implements Provider, Workspace, Tool, Agent, a single-active-run Runtime,
  and an opt-in loopback WebSocket API. Runtime exposes synchronous startup,
  owner-only await, and idempotent cancellation around one temporary RunServer and
  Agent Task. `mix synapse.server` conditionally adds the API process tree and its
  version-1 endpoint without adding a bundled frontend.

  The API adds bounded in-memory projection, sequence, subscription, snapshot, and
  replay state above Runtime. This state survives socket and listener loss, but it
  is not durable across RunManager or application restart. Remote authentication,
  concurrent runs, durable recovery, persistent workflow state, and a product
  client remain outside the MVP.

  Start with the project architecture in `README.md` and the implementation
  sequence in `docs/plan/PLAN.md` when learning or contributing to the system. The
  Runtime and API maintenance guides are `docs/learning/RUNTIME.md` and
  `docs/learning/API.md`.
  """
end
