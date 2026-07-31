# Synapse

The second brain to rule it all.

Synapse is an experimental coding-agent harness built with Elixir and the BEAM VM. It explores whether smaller models such as MiniMax M3 and DeepSeek v4 Flash can produce production-grade applications end to end when they are given a small, durable, failure-tolerant runtime.

The goal is not an agent that never fails. The goal is an agent where failure is a normal, durable, inspectable attempt, and the next attempt always begins from an explicit known-good boundary.

## Status

Synapse is currently in the architecture and prototyping stage. Provider streaming
and Workspace Phases 0-10 are implemented, including canonical APFS paths, bounded
revisioned reads, atomic writes and exact edits, plus bounded project commands
with isolated runtime directories, a minimal environment, streaming output,
mutation permits, matching cancellation, independent inactivity and absolute
deadlines, direct-child cleanup, and a deterministic scripted Fake backend for
side-effect-free Tool tests. Model-facing tools remain planned in
[`docs/plan/PLAN-TOOL-SYSTEM.md`](docs/plan/PLAN-TOOL-SYSTEM.md). This document
describes both current behavior and intended constraints.

The step-by-step plan for the first functional model-tool-loop MVP is [`docs/plan/PLAN.md`](docs/plan/PLAN.md).

## Design Decisions

The initial product decisions are:

- Run Synapse as a persistent local BEAM daemon.
- Treat CLI and TUI applications as disposable clients of that daemon.
- Use trusted Elixir scripts for the first hot-reloadable extension layer.
- Use the current checkout for interactive sessions.
- Use a separate git worktree for autonomous task attempts.
- Keep the kernel small and move optional behavior into extensions.
- Prefer durable evidence and deterministic verification over agent-reported success.
- Coordinate all writes through revision-checked file leases rather than allowing last-writer-wins mutation.
- Restart failed autonomous attempts from the last known-good commit with a fresh context instead of resuming a partial reasoning process.
- Enforce tool capabilities in the runtime based on request source, identity, project, and workflow policy.
- Keep secrets behind a local credential broker and expose only opaque secret references to tools and runs.
- Make direct OpenAI Codex, the Tokamak Codex pool, and standard OpenAI-compatible endpoints first-class providers.
- Treat human comprehension, complete LSP documentation, and generated ExDoc guides as acceptance requirements for every feature.

## Philosophy

### Built to fail

Any model request, tool execution, extension, terminal client, or run process may fail at any point. A failure must not:

- Corrupt the session history.
- Silently replay a side effect.
- Destroy uncommitted work.
- Prevent the UI from reconnecting.
- Prevent a later attempt from starting from the last accepted state.

Runs are disposable. History, evidence, accepted commits, and project state are durable.

### Minimal but extensible

Extensibility should come from a few stable composition points, not from a large core or dozens of overlapping hook systems.

The core should provide:

- A provider-neutral streaming protocol.
- A small model and tool loop.
- Typed lifecycle events.
- Durable sessions and context projection.
- Supervised run and task processes.
- A versioned extension registry.

Features such as MCP, web search, subagents, memory systems, and specialized workflows should be built on those primitives instead of being embedded in the kernel.

### Comprehension over velocity

Synapse is also a deliberate Elixir and OTP learning journey. It should not become a one-off codebase that works only while an AI can explain it. The owner should be able to inspect, understand, maintain, debug, and extend every important part of the system without depending on an AI assistant.

Development should proceed in small, meticulous vertical slices. A feature is not complete merely because it compiles or passes tests. Its purpose, public contract, process ownership, failure behavior, and intended usage must also be understandable from the source and generated documentation.

Documentation should explain why an abstraction exists, when it should be used, when it should not be used, and how it fits into the larger runtime. Restating the implementation line by line is not sufficient. The primary optimization target is durable comprehension, not maximum generated-code throughput.

### Verification over confidence

The model may propose that a task is finished, but only the runtime may accept it. Acceptance requires recorded evidence such as successful tests, builds, lint checks, artifact inspection, or an explicit human decision.

Verification could be a process itself, imagine that there is a checklist that needs to be fulfilled in that process, before it can send a message over to its supervisor or subsequent process. For example:

- pass all tests
- pass linter for style check
- artifacts is running
- pass end-2-end test

A bunch of processes will verify the above then put the message into the verification process until all is ticked off then it can put a message to check off the tasks and then end itself. It shoudln't be up to the model to decide when a task is done, it should write the test to verify that a test pass, but other than that it should be programatically approved.

### No invisible state mutation

Each model turn uses an immutable snapshot of its model, tools, prompt, context, budgets, and extension generation. Runtime configuration changes may be adopted only at a safe turn boundary.

## High-Level Architecture

```text
CLI / Bubble Tea / libvaxis client
                 |
        framed local protocol
                 |
        Persistent BEAM daemon
                 |
   +-------------+----------------+
   |             |                |
Project       RunSupervisor   ExtensionManager
Manager           |
   |          RunCoordinator
   |              |
SQLite       Provider tasks
Git          Tool tasks
worktrees    Verification tasks
```

Synapse should begin as one Mix application rather than an umbrella. Package boundaries should be introduced only after real reuse or deployment boundaries appear.

## Kernel Boundaries

The kernel understands:

- Messages and model responses.
- Turns and tool calls.
- Typed events.
- Cancellation.
- Session projection.
- Run lifecycle.

The kernel does not understand:

- Terminal rendering.
- Git workflow policy.
- Project planning policy.
- MCP.
- Web search.
- Subagents.
- Provider-specific product behavior.

Those concerns are adapters, extensions, or workflow layers built on top of the kernel.

## OTP Process Model

The initial supervision tree should contain:

```text
Synapse.Supervisor
|-- Synapse.RunRegistry
|-- Synapse.EventRegistry
|-- Synapse.Store
|-- Synapse.CapabilityPolicy
|-- Synapse.CredentialBroker
|-- Synapse.MutationCoordinator
|-- Synapse.ExtensionManager
|-- Synapse.ProjectManager
|-- Synapse.TaskSupervisor
|-- Synapse.RunSupervisor
`-- Synapse.TransportSupervisor
```

The important process boundaries are:

- A `DynamicSupervisor` starts active runs on demand.
- Each active run has one coordinator process.
- Model streams, tools, verification commands, and git operations execute in supervised temporary tasks or dedicated port-owner processes.
- A unique `Registry` locates runs by binary IDs.
- A duplicate `Registry` provides local event subscriptions.
- SQLite is the durable source of truth.
- A capability policy authorizes every tool invocation independently of what the model was shown.
- A credential broker resolves secret references only for authorized provider requests and subprocesses.
- A mutation coordinator owns revision validation and exclusive write leases for each workspace.
- The TUI is not part of a run's supervision tree.

The run coordinator owns only state-machine concerns such as phase, queues, cancellation, active operation references, event sequence, selected extension generation, and worktree identity. It must not perform blocking HTTP, subprocess, or database work inside its callbacks.

One-shot workers that may cause side effects should be temporary. OTP must not automatically restart and replay them after a crash.

## Turn Snapshots

Every model turn receives an immutable snapshot:

```elixir
%Synapse.TurnSnapshot{
  model: model,
  messages: messages,
  tools: tools,
  system_prompt: system_prompt,
  extension_generation: generation,
  budgets: budgets
}
```

An extension or settings reload may change the next snapshot, but it may not mutate an in-flight provider request. A run can explicitly adopt a newer extension generation after a completed turn.

## Agent Loop

The low-level loop should remain small:

```text
Create turn snapshot
        |
Stream model response
        |
Collect complete tool calls
        |
Validate arguments
        |
Execute tools
        |
Append tool results
        |
Continue or finish
```

The loop has two continuation mechanisms:

- Tool calls and steering messages continue the current piece of work.
- Follow-up messages begin additional work after the current inner loop would otherwise settle.

Agent-specific messages may exist in durable history, but they must be converted into provider-compatible messages immediately before a request.

## Event Model

One canonical event vocabulary should drive persistence, terminal rendering, JSON automation, RPC clients, extensions, tests, and telemetry.

Initial event types should include:

```elixir
%Synapse.Event.RunStarted{}
%Synapse.Event.TurnStarted{}
%Synapse.Event.MessageDelta{}
%Synapse.Event.MessageCompleted{}
%Synapse.Event.ToolStarted{}
%Synapse.Event.ToolUpdated{}
%Synapse.Event.ToolCompleted{}
%Synapse.Event.VerificationStarted{}
%Synapse.Event.VerificationCompleted{}
%Synapse.Event.RunInterrupted{}
%Synapse.Event.RunFinished{}
%Synapse.Event.RunSettled{}
```

Every event should carry:

- A run ID.
- A monotonically increasing sequence number.
- A timestamp.
- An operation ID when applicable.
- A structured payload.

`RunFinished` and `RunSettled` are intentionally different. The model may have stopped while retries, compaction, verification, or queued follow-up work still remain.

Persistence-sensitive handlers are ordering barriers and must complete before the operation advances. UI and telemetry subscribers are observational and may lag or reconnect.

Token deltas should be coalesced before publication and persistence. Synapse should persist completed messages and important lifecycle transitions rather than one database row per token.

## Provider Abstraction

Provider support is a first-release requirement rather than a later compatibility layer. The initial priority order is:

1. Direct OpenAI Codex using a Synapse-managed sign-in or an explicitly imported Codex credential.
2. The Tokamak Codex pool through Tokamak's public Responses proxy, without launching the Tokamak CLI.
3. Standard OpenAI-compatible Responses endpoints.
4. Standard OpenAI-compatible Chat Completions endpoints for local and remote providers that do not implement Responses.

Provider identity, model metadata, credentials, and wire protocol are separate concerns.

Direct OpenAI, direct Codex, Tokamak generic inference, and the Tokamak Codex pool should share Responses and SSE codecs while retaining separate endpoint, authentication, request-shaping, and retry policies. Chat Completions is a separate wire codec normalized into the same internal provider events.

Tokamak's current Codex pool is a server-side credential pool, not a pool of running agent processes. Synapse should call `POST /v1/agent-pool/codex-proxy/responses` with a Tokamak API key. Tokamak selects and refreshes the pooled Codex credential and transparently streams the Responses result. There is currently no acquire, release, or session-pinning protocol.

Tokamak currently imports and refreshes Codex credentials but does not implement the initial OpenAI sign-in flow. Direct Codex sign-in must therefore be implemented as a separate Synapse credential provider or bootstrapped through an installed Codex client and then imported. Private ChatGPT Codex endpoints and headers are version-sensitive and must not leak into the generic OpenAI-compatible adapter.

The detailed implementation plan, current Tokamak contracts, wire event mapping, credential handling, and known compatibility risks are documented in [`docs/PROVIDERS.md`](docs/PROVIDERS.md).

A provider normalizes vendor-specific responses into the implemented event union:

```text
MessageStarted
TextDelta
ToolCallStarted
ToolCallDelta
ToolCallCompleted
MessageCompleted
Diagnostic
```

The current transport runs each HTTP request in a monitored temporary worker with a coordinator watchdog; future Runtime supervision will own operation processes above it. Server-sent event data is buffered across HTTP chunk boundaries before JSON decoding. Cancellation terminates the worker that owns the underlying request, not only display output.

Provider failures become one structured terminal `Provider.Error`; progress events are non-terminal.

## Tools

A tool is data plus behavior. It provides:

- A stable string name.
- A model-visible description.
- A JSON Schema for its arguments.
- Execution behavior.
- Structured result metadata.
- Concurrency and mutation policy.
- Idempotency and retry policy.
- Time and output limits.

A minimal tool behavior may resemble:

```elixir
@callback specification() :: Synapse.Tool.Spec.t()

@callback execute(Synapse.Tool.Call.t(), Synapse.Tool.Context.t()) ::
  Synapse.Tool.Result.t()
```

The paired Result carries `status: :ok | :error | :ambiguous`; expected failure
and uncertainty are data rather than exceptions or tuple-shape policy.

The initial toolset should contain:

- `read`
- `write`
- `edit`
- `bash`

`grep` and `glob` should follow shortly afterward.

### Execution semantics

The first MVP Executor handles one call synchronously and Agent will invoke calls
in source order. Parallel scheduling and artifact spill describe the target
architecture and remain deferred until the sequential boundary is complete.

- Every valid tool call submitted to the Executor receives a corresponding paired
  result, including unknown, invalid-argument, rejected, cancelled, failed, and
  ambiguous calls.
- Tool calls from a provider response truncated by its output limit are never executed because their arguments may be incomplete.
- Side-effecting tools are not automatically replayed after a process crash.
- Parallel-safe tools may execute concurrently.
- Exclusive tools wait for earlier work and block later work until complete.
- Mutations to the same canonical file path are serialized and revision-checked.
- Tools with an unknown mutation footprint, such as unrestricted shell execution, require an exclusive workspace mutation lease.
- Tool output is bounded and may spill into an inspectable artifact.
- Model-supplied tool names never become atoms.

### Concurrent file mutation

The current Workspace MVP uses one whole-workspace mutation lease per handle.
Revision-checked whole-file create, replacement, and exact-one text edits are
owned by its MutationServer and executed in one linked mutation worker. They use a
synced same-directory stage, no-overwrite hard-link creation, atomic rename
replacement, and bounded UTF-8 diff data. This deliberately conservative design
precedes the per-path and multi-file coordinator described below.

The target architecture expands that MVP as follows.

Autonomous runs are isolated from one another with separate git worktrees. Multiple workers or subagents operating inside the same worktree must still coordinate through one `MutationCoordinator`; they may not write files directly and rely on timing.

A read returns a normalized relative path, a bounded numbered line window, and an opaque revision derived from the complete content hash and relevant filesystem metadata. It never returns the canonical absolute root. Every edit, write, delete, rename, or append request includes the revision it was based on. The mutation coordinator then:

1. Canonicalizes the path and checks the caller's capabilities.
2. Acquires an exclusive, short-lived lease for that path.
3. Compares the expected revision with the current revision.
4. Rejects the request as stale if another mutation committed first.
5. Applies the patch to staged content and runs cheap validation.
6. Replaces the file atomically where the filesystem permits it.
7. Records the old revision, new revision, actor, operation ID, and diff.
8. Releases the lease and publishes the mutation event.

A stale writer must reread the file and produce a new patch. Synapse must never silently merge arbitrary model output or allow the last writer to overwrite earlier accepted changes. If edits are mechanically mergeable, a dedicated merge operation may propose a result, but it is still revision-checked before commit.

Leases should normally cover one mutation rather than assigning a file to an agent for an entire task. Long-lived file ownership creates abandoned locks, unnecessary blocking, and stale context. A workflow may reserve a file group for a short critical section when a coordinated refactor requires it.

Multi-file operations acquire leases in canonical path order to avoid deadlocks. They stage and validate all intended changes before committing any of them. Since ordinary filesystems do not provide atomic transactions across multiple files, the surrounding autonomous worktree remains the final rollback boundary.

Append is not a special concurrency escape hatch. An `append` tool must also provide an expected revision and pass through the mutation coordinator. Logs written by infrastructure should use a single-writer process or SQLite rather than having arbitrary agent processes append directly to the same file.

All model-facing mutation tools must use this path. A shell command can bypass
file-level coordination, so model-facing shell execution always declares an
unknown mutation footprint and acquires the exclusive workspace lease. The MVP
does not enforce OS-level read-only execution; that declaration is reserved for
trusted fixed application commands. OS write denial and the repository diff scan
after unknown commands are target hardening features and remain explicitly
deferred until their implementation phases.

### Tool search

A `search_tools` capability can query registry metadata and activate a smaller tool subset for the next turn. This avoids exposing hundreds of tool schemas in every request.

The kernel should not care whether a registered tool came from core code, an Elixir extension, MCP, an external executable, or a remote service.

## Project Management

The initializer, executor, and verifier should initially be workflow roles, not separate agent frameworks. The same run engine executes each role with a different policy and context projection.

### Initializer

The initializer produces a durable project brief containing:

- Build, test, lint, and formatting commands.
- Repository structure and conventions.
- Environment requirements.
- Project constraints.
- The definition of done.

It also produces small work items containing:

- A concrete goal.
- Dependencies on other work items.
- Allowed scope.
- Acceptance criteria.
- Verification commands.
- Attempt and resource budgets.

The result should be a small dependency graph, not a large prose plan that will immediately become stale.

### Work item lifecycle

```text
pending
  -> preparing
  -> executing
  -> verifying
  -> committing
  -> accepted
```

Any phase may transition to `blocked`, `interrupted`, or `failed`.

The model may propose completion, but only the coordinator may accept a work item after its mandatory evidence has passed.

## Verification

Verification produces durable evidence rather than an agent-generated boolean.

It may include three layers:

1. Deterministic checks such as tests, builds, type checking, and linting.
2. Diff policies such as allowed files, forbidden paths, generated artifacts, and unexpected dependencies.
3. An optional reviewer model for behavioral or architectural review.

Mandatory deterministic checks must pass before an autonomous attempt is committed. Synapse records command arguments, exit codes, bounded output, timestamps, artifacts, and resulting commit hashes.

The verifier should be able to distinguish:

- Passed.
- Failed with clear evidence.
- Blocked by the environment.
- Ambiguous because an operation's outcome could not be observed safely.

Documentation and comprehension are part of deterministic verification. A feature with missing public documentation, typespecs, architectural context, or generated documentation is incomplete even when its behavioral tests pass.

## Documentation And Learning

Synapse should be capable of generating a complete local documentation site with ExDoc. That site should provide an understandable path from the product architecture to a module, from a module to its public functions, and from each public function to examples and relevant tests.

### LSP documentation contract

Elixir's documentation chunks and typespecs should make source exploration useful through ElixirLS or another LSP client. Hovering over a module or public function should answer its purpose and proper usage without requiring the reader to reconstruct intent from implementation details.

Every public module should have an `@moduledoc` that explains:

- Why the module exists.
- The responsibility it owns and the responsibilities it deliberately does not own.
- Where it sits in the supervision tree or data flow.
- Whether it is a process, pure transformation, boundary adapter, registry, policy, or storage component.
- Its lifecycle, concurrency assumptions, and state ownership where applicable.
- The normal entry points and the situations in which callers should use them.
- Relevant failure, cancellation, retry, and security semantics.
- Links to related modules and longer guides.

Every public function, macro, callback, and protocol operation should have an `@doc` that explains:

- The operation's purpose rather than only its mechanics.
- When callers should and should not use it.
- The meaning of its arguments and return values.
- Expected errors and exceptional outcomes.
- Side effects, mutations, messages, external operations, and required capabilities.
- Ordering, ownership, timeout, idempotency, and concurrency guarantees where relevant.
- A focused example when usage is not obvious.

Public APIs should also include accurate `@spec` declarations. Public structs and domain values should expose useful `@type` or `t()` definitions. Behaviours should document the semantic contract of each callback, not just its accepted shape.

Private helpers do not need repetitive comments that narrate obvious code. They should have intention-revealing names and small scopes. A comment is appropriate when it preserves a non-obvious invariant, tradeoff, protocol quirk, or reason that a simpler-looking implementation would be unsafe.

`@moduledoc false` and `@doc false` should be exceptional. They are appropriate for generated code or genuinely private implementation surfaces, not as a shortcut around explaining an important subsystem.

### ExDoc as a product artifact

`ex_doc` should be configured from the beginning as a development dependency. `mix docs` must generate a navigable documentation site throughout development, not only before a release.

The ExDoc configuration should:

- Use this README as the project landing page.
- Include architecture, provider, extension, security, persistence, mutation, and operational guides as extras.
- Group modules by subsystem so readers can navigate the kernel, runtime, providers, tools, storage, project management, extensions, security, and clients.
- Cross-link modules, callbacks, types, guides, and source code.
- Include supervision, event-flow, attempt-lifecycle, and data-ownership diagrams where they improve understanding.
- Publish version and source references so generated documentation can be tied to the code that produced it.

Documentation generation should run in CI or the local verification pipeline. Missing documentation, broken references, invalid doctests, and documentation warnings should fail verification where the tooling can detect them.

### Guides for understanding the BEAM

Architecture guides should teach the Elixir and OTP decisions embodied by Synapse. They should explain topics such as:

- Why a component is a GenServer, Task, supervisor, Registry, behaviour, protocol, or pure module.
- How links, monitors, cancellation, restarts, and temporary children affect failure semantics.
- Which process owns mutable state and why other processes communicate through messages.
- How immutable data, append-only history, and context projections fit together.
- How backpressure, mailbox growth, timeouts, and process termination are handled.
- Why a particular boundary is operational isolation rather than a security sandbox.

These guides should be grounded in Synapse's actual implementation rather than becoming generic Elixir tutorials. The goal is to make the codebase itself a coherent course in building a production-oriented BEAM application.

### Feature acceptance standard

Every feature or substantial refactor should leave behind:

- Documented public modules, functions, callbacks, and types.
- Tests that demonstrate the behavioral contract and important failures.
- Examples or doctests for non-obvious public usage.
- An updated guide when the feature changes architecture, lifecycle, data ownership, security, or operations.
- A recorded design decision when an important tradeoff would otherwise be lost.
- A small, reviewable change whose purpose can be explained independently of the generating model's transcript.

The comprehension review asks whether the owner can move from the relevant guide to the modules, public functions, tests, and runtime behavior without relying on hidden context. If that path is unclear, the feature is not finished.

Documentation must evolve in the same commit as behavior. Stale documentation is a defect, and generated prose that does not match the implementation is worse than missing prose because it creates false confidence.

## Git And Workspace Isolation

Synapse supports two workspace modes.

### Interactive mode

Interactive sessions edit the user's current checkout so changes appear immediately in their editor.

The run records the initial repository status. It must never automatically discard pre-existing user changes or assume that every dirty file belongs to the agent. Automatic cleanup is inherently unsafe in this mode.

### Autonomous mode

Each autonomous attempt receives an isolated git worktree created from an explicit base commit.

The success path is:

```text
execute -> verify -> commit -> offer integration
```

On failure, Synapse should:

- Preserve a dirty failed worktree as an inspectable artifact.
- Record its failure, repository status, and last operation.
- Start a later attempt from the last accepted commit.
- Never force-remove a dirty worktree automatically.

A worktree isolates editing and concurrent attempts. It is not a security sandbox. Worktrees still share the repository object database and references.

An accepted commit is the work-item boundary. Synapse should not create a git commit after every model turn.

## Persistence And Sessions

SQLite should be the durable source of truth for projects, work items, attempts, sessions, extension generations, and worktree ownership. JSONL can be provided as an export and interoperability format.

Session history is append-only and branchable. A transcript entry contains:

```text
id
parent_id
type
payload
timestamp
```

The active leaf is persisted explicitly so branch selection survives a daemon restart.

Model context is a projection of durable history:

```text
durable branch
  -> select active path
  -> apply compaction boundary
  -> omit private events
  -> convert application messages
  -> provider messages
```

Durable history and current model context are deliberately different views.

### Compaction

Compaction appends a summary entry and context boundary. It never deletes or rewrites original history.

Compaction must preserve tool-call and tool-result pairing and avoid splitting unsafe message boundaries. Repeated compactions should include relevant prior summary information and create meaningful context headroom rather than retriggering immediately.

## Hot Elixir Extensions

Synapse has two extension levels with different upgrade semantics.

### Script extensions

Hot-reloadable files under `.synapse/extensions/*.exs` evaluate to extension specifications made of data and closures:

```elixir
Synapse.Extension.new("project_tools")
|> Synapse.Extension.add_tool(tool)
|> Synapse.Extension.add_hook(:before_tool, before_tool)
|> Synapse.Extension.add_workflow(workflow)
```

The hot script contract should avoid `defmodule`. Dynamically replacing BEAM modules introduces current/old code limits, stale closures, atom-lifetime concerns, and state-migration requirements. Compiled modules belong to normal application releases.

The reload lifecycle is:

```text
file change
  -> debounce and hash
  -> evaluate in a disposable process
  -> validate API version and schemas
  -> run extension checks
  -> create an immutable generation
  -> atomically activate
```

New runs bind the active generation. Existing runs remain pinned until they finish or explicitly adopt a new generation at a safe turn boundary. Old generations are retired only after no active run references them.

An agent may therefore edit an extension, verify it, activate it, and use it on a later turn without restarting the daemon.

Elixir scripts are fully trusted. Evaluating one in another BEAM process provides fault isolation, not a security boundary. Extension code can still access the filesystem, environment, network, processes, ports, and application modules.

### Compiled core extensions

Compiled modules, NIFs, and application changes use normal release mechanics.

The preferred zero-visible-downtime core upgrade path is initially blue-green:

1. Build and verify a new release.
2. Start the new local daemon.
3. Route new clients and runs to it.
4. Allow the old daemon to drain active runs.
5. Stop the old daemon.

Formal OTP `appup` and `relup` upgrades may be added later if their state migration and operational complexity becomes justified.

Literal arbitrary self-replacement without ever starting a new process is not an initial requirement. The product requirement is uninterrupted, durable, resumable operation.

## Extension API

The first extension API should support:

- Registering tools.
- Registering providers.
- Registering workflows and commands.
- Adding prompt and context sources.
- Intercepting before and after tool execution.
- Observing canonical events.

Every interception point defines deterministic reduction semantics such as:

- Chain transformations in registration order.
- Accumulate independent results.
- Stop on the first explicit block.
- Observe without affecting execution.

Extensions do not receive arbitrary access to mutable run coordinator state. Extension handles include their generation and become invalid when their runtime is retired.

Tool result presentation uses structured data. Tools should not contain terminal-specific rendering code.

## Web Search And MCP

Neither web search nor MCP belongs in the kernel.

A query-aware web-fetch extension may implement:

```text
fetch
  -> parse DOM
  -> remove scripts, navigation, and noise
  -> rank sections against the query
  -> return bounded relevant blocks
```

An MCP adapter can discover remote capabilities and register them in the same tool registry as native tools. A tool-search capability can then expose only relevant tools to a model turn.

## Client And TUI

The BEAM daemon is the source of truth. CLI and TUI applications are disposable clients connected through a language-neutral local protocol.

The protocol should use length-framed JSON over a Unix domain socket. It must support:

- Commands with request IDs.
- Asynchronous run events.
- Cancellation.
- Snapshot retrieval.
- Resume from an event sequence.
- Interactive extension requests such as select, confirm, and input.

The first client should be a basic text and JSON interface. A full-screen TUI can follow after the protocol and event model stabilize.

Bubble Tea is a Go library and libvaxis is a Zig library. Either can be used in a separate frontend process. Synapse should not wrap a terminal framework in a NIF because a frontend bug must not crash or block the BEAM VM.

If a native Elixir TUI is preferred, TermUI can be evaluated through a focused prototype. Terminal resize, Unicode width, paste, suspend/resume, raw-mode restoration, and crash handling must be acceptance-tested before committing to it.

## Failure And Recovery Semantics

Synapse must distinguish retrying an operation from restarting an attempt. Retrying an uncertain mutating operation in place can duplicate or compound a side effect. Restarting an isolated autonomous attempt from its known base is safer and intentionally discards the partial model context.

- A provider request that fails before producing output may be retried under a configured policy.
- A provider request that partially streamed is not resumed as if the missing continuation were trustworthy.
- A read-only idempotent tool may be retried explicitly.
- A mutating tool is never replayed automatically after losing its result.
- An interrupted mutating tool is recorded as ambiguous until inspected.
- A coordinator crash reloads the attempt as interrupted rather than silently resuming side effects.
- UI crashes have no effect on run execution.

Every external operation receives an operation ID and produces start and terminal records. Missing terminal records identify interrupted or ambiguous operations during recovery.

### Activity deadlines

Each operation type defines an inactivity deadline and an absolute deadline. Activity includes provider deltas, subprocess output, explicit progress events, heartbeats from trusted workers, and observable state transitions. Process existence alone does not prove useful progress.

A provider stream or ordinary tool may begin with a two-to-three-minute inactivity deadline. Builds, test suites, downloads, migrations, and other legitimately quiet operations may declare a longer deadline. Deadlines are policy values attached to the operation specification rather than one global timeout.

When an inactivity deadline expires, current Workspace ownership requests cancellation, waits a bounded grace period, and confirms its MuonTrap helper and owned direct operation are down. It does not claim complete process-tree termination: daemonized descendants may escape. If Synapse cannot determine whether a mutation completed, the result is ambiguous rather than simply failed.

Every operation specification also defines a maximum retry count. No failed operation may loop indefinitely; five is the default upper bound, and side-effecting or permanently invalid operations use a lower bound or zero. Safe in-place retries and fresh-attempt retries are recorded separately so repeated infrastructure failures cannot hide an unproductive task.

### Fresh-attempt retries

An autonomous work item may be attempted up to five times by default. The limit is configurable by project, task type, cost budget, and failure class.

Each retry:

- Starts a new run process and fresh model context.
- Creates a clean worktree from the last accepted commit.
- Retains only the work-item specification, verified project state, prior failure classification, and bounded diagnostic evidence.
- Does not continue the previous model's half-completed reasoning transcript.
- Does not replay an uncertain side effect.
- Uses bounded backoff for infrastructure failures so a broken dependency is not hammered repeatedly.

The failed worktree and full transcript may be retained for inspection, but they are not used as the mutable base for the next attempt. After the configured attempt limit is reached, the work item becomes failed or blocked and requires a policy or human decision.

Interactive mode cannot safely wipe the user's checkout. If a failed interactive operation touched files, Synapse may automatically roll back only changes that its mutation journal proves it owns and only when their current revisions still match. Otherwise it preserves the workspace and asks for an explicit decision.

## Security Model

BEAM process isolation is not a security sandbox. Neither a GenServer, an Elixir script, a git worktree, nor a separate scheduler process protects the host from trusted code with filesystem or command access.

Initial security rules are:

- Never create atoms from model, provider, or extension input.
- Keep secrets out of extension contexts and child-process environments unless explicitly required.
- Invoke executables with separated argument lists rather than shell strings where possible.
- Canonicalize and enforce filesystem roots.
- Apply request, output, event, memory, and execution-time limits.
- Treat NIFs as trusted infrastructure capable of crashing the VM.
- Put genuinely untrusted execution in a separate OS user, container, or VM.
- Do not expose Erlang distribution to untrusted networks.

Current Workspace safety is deliberately narrower than a sandbox. Path checks
resist ordinary mistakes under a cooperative same-user threat model, not hostile
TOCTOU swaps after validation. File replacement is atomically visible but does not
claim parent-directory crash durability. Commands run as the same OS user with
ambient filesystem and network authority. Healthy-VM cleanup proves the owned
direct command; escaped descendants, daemonized processes, and uncatchable host or
VM death remain explicit limitations.

Project trust decides whether project-local code may be loaded. It is not a general tool permission system.

### Capability enforcement

Tool security must be enforced programmatically by the runtime, not by asking the model to obey a prompt. Every request enters Synapse with an authenticated source and a policy-defined capability set. Effective capabilities are the intersection of source, user, project, workflow, task, and approval policy.

Example capabilities include:

```text
fs.read
fs.write
process.exec
network.fetch
secret.use:OPENAI_KEY
git.commit
project.dispatch
```

Capabilities may be parameterized by canonical path roots, network origins, command templates, provider profiles, secret names, and budgets. `fs.read` for an external chat source should therefore mean access to approved project paths, not unrestricted host filesystem access.

An external chat integration can therefore be assigned only `fs.read` and selected query tools. Write, shell, secret, and dispatch tools are omitted from its turn snapshot, but omission is only a usability measure. The `ToolExecutor`, mutation coordinator, credential broker, and subprocess launcher all enforce the same capability token again when an operation executes.

Capabilities are unforgeable runtime data attached to a run. They are never created from model text, tool arguments, or extension output. A subagent receives an explicitly delegated subset and cannot grant itself or its descendants additional authority. Every denied and allowed sensitive operation is auditable.

### Secret broker

Secrets are entered through a trusted local path such as the TUI, local IPC command, operating-system credential provider, or administrative API. They are stored under symbolic names such as `OPENAI_KEY`; the model sees only the symbolic reference when it needs to select a configured provider or tool.

Secret values must never enter prompts, transcripts, event payloads, command-line arguments, diffs, or ordinary logs. The preferred storage is an operating-system keychain. If encrypted database fields are supported, the database encryption key must live outside that database and files must use owner-only permissions.

A trusted tool or provider declares the secret references it requires. At execution time the credential broker verifies the run capability, tool identity, intended executable or HTTP audience, and operation ID. It then injects the value directly into an HTTP authorization header, subprocess environment, or stdin. The child receives a minimal environment and secrets are not inherited by unrelated descendants.

For future credential-broker commands, the model should select a pre-approved command template containing placeholders, never a command string containing the resolved value. The returned command description retains placeholders.

Current Workspace events and results contain raw bounded subprocess output. That
untrusted data may contain secrets or absolute host paths and is not sanitized or
redacted by Workspace; it must not be persisted, published, or rendered to a model
without downstream Tool policy. A future credential broker should apply
exact-value and provider-specific pattern filters as defense in depth. Secret
leases should be short-lived, audience-scoped, revocable, and cleared from process
state as soon as practical. Secret access events record the symbolic name and
audience, never the value.

Secret injection alone cannot guarantee that a value will never reach the model. An arbitrary executable can print, encode, transform, or transmit any secret it receives. Stronger isolation requires broker-owned HTTP requests or fixed, audited executables with constrained arguments, environment, filesystem, and network access. Generic shell tools must not receive secrets. Redaction is defense in depth, not a security boundary.

## Observability And Evaluation

Synapse should instrument runs from the beginning. Useful spans include:

- Whole runs and individual turns.
- Provider requests and time to first token.
- Tool and extension calls.
- Verification operations.
- Extension validation and activation.
- Worktree creation, integration, and cleanup.
- Database operations.
- Cancellation and failure paths.

Metrics should use low-cardinality dimensions such as provider, model family, operation type, extension ID, and outcome. Run IDs, paths, prompts, generated code, credentials, and full command lines belong in appropriately redacted logs or traces, not metric labels.

To compare coding models meaningfully, every attempt should record:

- Model and provider configuration.
- Base and final commit hashes.
- Prompt and extension generation.
- Enabled tools.
- Number of attempts and human interventions.
- Token usage, duration, and cost.
- Verification results.
- Final acceptance decision.

This turns the question "can this model build a production-grade application?" into a repeatable engineering evaluation rather than a subjective impression.

## Lessons From Existing Agents

Synapse draws inspiration from [Pi](https://github.com/earendil-works/pi) and [Oh My Pi](https://github.com/can1357/oh-my-pi).

### Ideas to keep

- A provider-neutral streaming layer.
- A UI-independent agent loop.
- Append-only branching sessions.
- Context as a projection of durable history.
- One canonical event vocabulary.
- Explicit tool-call and tool-result pairing.
- Immutable turn snapshots.
- Shared and exclusive tool execution.
- Extension timeout and failure isolation.
- Compaction as a durable event rather than transcript rewriting.

### Complexity to avoid initially

- Multiple overlapping extension systems.
- A single giant session object responsible for every subsystem.
- MCP in the kernel.
- Plugin marketplaces.
- A large provider compatibility matrix.
- Built-in subagent orchestration.
- Multiple memory backends.
- Provider-specific retry heuristics everywhere.
- Dynamic mutation of active turns.
- Terminal rendering embedded inside tool implementations.
- Treating in-process extensions as a security boundary.

The core abstractions are worth learning from. The accumulated feature surface is not an appropriate starting point for a minimal harness.

## Lessons From Current Harness Implementations

The analysis in [`docs/CLAUDE-HARNESS.md`](docs/CLAUDE-HARNESS.md) covers the Agent-Computer Interface work in SWE-agent, Anthropic's long-running Claude Code experiments, OpenAI's Codex engineering practices, and the broader agent harness ecosystem. Together they reinforce that model selection is only one input to agent quality. The larger determinant is the environment in which the model observes, acts, receives feedback, and hands work to its future self.

These implementations provide several concrete requirements for Synapse.

### Treat the interface as cognitive architecture

An agent-computer interface is not a cosmetic wrapper around shell commands. It determines what the model can perceive, how much attention each observation consumes, and how quickly it can connect an action to its consequences.

Giving a model raw shell access is useful as an escape hatch, but it is a poor default interface for common operations. Purpose-built tools should reduce cognitive overhead and make unsafe or vague operations harder to perform.

Synapse should apply the following ACI constraints:

- Search results are capped, ranked, and summarized.
- An overly broad search returns a refinement request instead of thousands of lines.
- File reads use explicit line numbers and bounded windows.
- A default file window should be large enough to preserve local context but small enough to avoid flooding the turn. Approximately 100 lines is a useful starting point to evaluate.
- Read results include continuation hints so the model can navigate without repeating broad reads.
- Edit tools return the changed region and a structured diff immediately.
- Cheap syntax or formatting checks run as close to the edit as possible.
- An invalid edit should be rejected or clearly isolated before it creates a cascade of unrelated failures.
- Large tool output is replaced by a bounded summary and a reference to a durable artifact.

These limits are not merely cost controls. They protect the model's working attention from its own tendency to search too broadly or retain stale output.

### Use progressive disclosure

More context is not automatically better context. Irrelevant or stale tokens compete with the task, code, and constraints that currently matter.

Synapse should provide a short orientation context containing the current goal, project map, active constraints, and pointers to deeper information. Additional documentation, tool definitions, history, and source files should be retrieved only when needed.

This has several implications:

- Do not inject this entire README into every model turn.
- Keep a short agent-facing entry point that maps to deeper documents.
- Organize detailed architecture and domain knowledge under `docs/`.
- Load tools dynamically through tool search instead of advertising every possible capability on every turn.
- Prefer targeted context retrieval over a monolithic project instruction file.
- Compact stale observations while retaining recent actions and the current verified state.

Progressive disclosure also improves maintainability. Small maps and focused documents can be checked for freshness more reliably than one enormous prompt.

### Make the repository the source of project truth

From an agent's perspective, knowledge it cannot retrieve during a run does not exist. Requirements, architectural decisions, setup instructions, and domain constraints that live only in chat, external documents, or a person's memory cannot reliably guide autonomous work.

Synapse should distinguish two forms of durable state:

- The repository is the portable, versioned source of project intent and knowledge.
- SQLite is the daemon's operational store for events, leases, attempts, subscriptions, transient status, and queryable projections.

The repository should contain or generate structured artifacts such as:

```text
.synapse/project.json
.synapse/features.json
.synapse/progress.jsonl
docs/architecture/
docs/plans/
```

Exact filenames remain an implementation decision, but the responsibilities are important:

- The project manifest records repeatable setup, start, test, lint, and build commands.
- The feature manifest lists explicit user-visible behaviors and verification steps.
- Every feature begins incomplete and becomes accepted only after evidence is recorded.
- Plans contain progress, decisions, dependencies, and unresolved questions.
- Architecture documents explain domain boundaries and permitted dependency directions.
- Human-readable summaries help a new session orient itself without replaying the entire event log.

Structured formats should be preferred for authoritative status and acceptance criteria. Their schema makes accidental rewriting easier to detect than edits to free-form prose. The coding model may propose status changes, but the verifier or coordinator owns the accepted state.

### Standardize initialization and startup

Anthropic's long-running experiments show that a dedicated initializer is most valuable when it creates reusable scaffolding rather than attempting product features.

The initializer should produce:

- A deterministic bootstrap or initialization command.
- A structured feature list with end-to-end acceptance steps.
- A project progress and decision record.
- A baseline verification suite.
- An initial known-good git commit for autonomous work.

Every later autonomous session should follow a standard startup sequence:

```text
confirm repository and worktree
  -> read the project map and recent progress
  -> inspect recent accepted commits
  -> select one ready incomplete work item
  -> start the environment deterministically
  -> run baseline health checks
  -> repair existing breakage or begin the work item
```

If the baseline is already broken, the run must not layer a new feature on top of it without an explicit decision. This avoids compounding failures and makes the source of regressions easier to identify.

### Work on one verifiable behavior at a time

Long-running agents commonly fail by implementing many partially complete features in one context window. The next session then spends most of its budget reconstructing an incoherent intermediate state.

Synapse should make one work item the default unit of execution. A work item describes an observable behavior, not an implementation activity. For example, "a user can create a new conversation and see it in the sidebar" is a better unit than "implement conversation modules."

An accepted work item ends with:

- Its required checks passing.
- Its user-visible behavior verified where possible.
- Its progress and decision records updated.
- A descriptive commit in autonomous mode.
- A clean, reproducible handoff for the next attempt.

Failed or interrupted work remains an attempt artifact. It must not be confused with the last known-good project state.

### Close feedback loops at the point of action

Agent performance is bounded by what the harness lets the agent observe. Unit tests alone cannot prove that an interactive feature works for a user, and source inspection alone cannot expose runtime, browser, or distributed-system failures.

Feedback should be integrated as close as possible to the action that can cause a failure:

- Parse and lint feedback follows an edit immediately.
- Focused tests follow a local implementation step.
- Full required checks run before acceptance.
- Browser automation verifies real user flows for web applications.
- DOM snapshots and screenshots make visual state inspectable.
- Logs, metrics, and traces are queryable from the run that produced them.
- Each autonomous worktree can boot its own isolated application instance and observability data.

Browser automation and observability are extensions or project capabilities, not kernel responsibilities. They should still produce canonical tool results and verification evidence so the workflow does not depend on a particular MCP server or frontend.

### Enforce invariants mechanically

Models reproduce patterns that already exist, including weak or inconsistent ones. Prompt guidance alone is not sufficient to maintain architectural coherence as generated code accumulates.

Synapse should encourage projects to encode invariants as executable checks:

- Dependency direction and package boundary tests.
- Data validation at system boundaries.
- Naming and file-layout rules where consistency improves navigation.
- Checks for forbidden dependencies or APIs.
- Documentation index and freshness checks.
- Required test coverage for declared feature behaviors.

These checks should enforce boundaries rather than dictate implementations. Agents should have freedom inside a valid architecture.

Error messages are part of the ACI. A custom linter should state the violated rule, identify the relevant location, and suggest a valid remediation. An error written only for a human expert wastes additional turns while the model infers what the check intended.

### Make the application legible to the agent

Code is only one view of a running system. A production-oriented harness should eventually expose the same diagnostic surfaces a human engineer would use:

- Process and service health.
- Structured application logs.
- Metrics and traces.
- Browser-visible state.
- Database and queue state through constrained tools.
- Build, deployment, and CI results.

The correct abstraction is not unrestricted access to every production system. It is a bounded, queryable interface that returns relevant observations without flooding context or leaking credentials.

### Preserve human oversight at leverage points

As execution becomes cheaper, human attention should move toward specification, priority, risk, and outcome review.

The useful approval boundaries are:

- Confirming or correcting the initializer's project model.
- Approving high-risk or ambiguous specifications before execution.
- Reviewing evidence and diffs for sensitive work.
- Deciding how accepted autonomous commits are integrated.
- Changing architectural constraints and security policy.

Human review should not compensate for checks that can be made deterministic. Conversely, fast agent throughput is not a reason to remove gates around security-sensitive, destructive, or irreversible work.

### Treat failures as harness diagnostics

When a run repeatedly fails, the first question should not be whether a larger model or more elaborate prompt is required. Synapse should support an environment audit that asks:

- What necessary information was unavailable?
- What tool forced the model into a noisy or error-prone interaction?
- What feedback arrived too late?
- What stale context influenced the decision?
- What invariant depended on model judgment instead of a mechanical check?
- What part of setup or recovery was not reproducible?

Each answer maps to a durable harness improvement:

- Missing information becomes a repository document or retrieval capability.
- Missing actions become a focused tool.
- Missing feedback becomes a test, linter, browser check, or observability query.
- Context pollution becomes an output limit, search refinement, or projection rule.
- Repeated policy mistakes become mechanical constraints.

Synapse should record failure categories and recurring patterns so improvements can be evaluated across future attempts. This is the self-improvement loop that matters most: not asking the model to try harder, but making the environment systematically easier to reason about.

### Define Synapse's place in the stack

Current harness ecosystems separate human oversight, specification, lifecycle management, task running, orchestration, harness runtimes, and coding agents. Synapse should not attempt to replace every layer immediately.

Its initial scope is:

- A persistent local runtime.
- A coding-agent harness and ACI.
- A project and work-item lifecycle.
- Isolated autonomous task execution.
- Extension points for external specification, issue-tracking, CI, and review systems.

This positioning keeps the execution engine replaceable. MiniMax, Qwen, or a future model should be interchangeable reasoning engines inside the same observable and verifiable environment.

## Initial Dependencies

The likely minimal Elixir dependency set is:

- `req` and Finch for streaming HTTP.
- `muontrap` for contained, flow-controlled external process execution.
- `exqlite`, or `ecto_sqlite3` if migrations and schemas justify Ecto.
- `telemetry` for instrumentation.
- `ex_doc` as a development dependency for generated API documentation and guides.

Possible later dependencies include:

- `file_system` for immediate extension notifications.
- `term_ui` for a native full-screen prototype.
- `phoenix_pubsub` only if multi-node operation becomes a real requirement.

For a single local daemon, Elixir registries are sufficient for run lookup and local event subscriptions.

## Roadmap

### Phase 1: Durable agent kernel

- Create the OTP application and supervision tree.
- Define canonical events and the turn state machine.
- Implement a simulated provider for deterministic tests.
- Implement the local command and event protocol.
- Persist runs and completed messages.
- Implement source-scoped capabilities, the credential broker, and mutation coordinator.
- Configure ExDoc, module groups, guide extras, doctests, and documentation verification.
- Establish the public documentation and comprehension acceptance standard before adding product breadth.

### Phase 2: Coding loop

- Implement shared Responses and Chat Completions codecs.
- Implement direct OpenAI Codex sign-in or credential import.
- Implement direct Tokamak Codex-pool connectivity.
- Implement standard local and remote OpenAI-compatible endpoints.
- Add `read`, `bash`, `edit`, and `write`.
- Add revision-checked writes, cancellation, activity deadlines, output limits, and tool pairing.
- Support interactive current-checkout sessions.

### Phase 3: Autonomous work

- Add projects, project briefs, and work-item dependencies.
- Add deterministic verification and evidence records.
- Add isolated worktrees for autonomous attempts.
- Add clean attempt restart with bounded retry budgets.
- Commit accepted work and preserve failed attempts safely.

### Phase 4: Live extensibility

- Define the Elixir script extension API.
- Implement content-addressed extension generations.
- Validate and activate extensions without restarting runs.
- Allow explicit generation adoption at turn boundaries.

### Phase 5: Context and discovery

- Add session branching and summary compaction.
- Add tool search and dynamic tool activation.
- Add query-aware web fetching as an extension.
- Add MCP as a tool-registry adapter if needed.

### Phase 6: Product interface

- Build the full-screen Bubble Tea or libvaxis client.
- Add reconnect, snapshots, event replay, and interactive prompts.
- Add model-comparison and run-evaluation views.

## Non-Goals For The First Version

- Distributed Erlang or multi-node scheduling.
- Multi-user authentication and quotas.
- A plugin marketplace.
- Arbitrary untrusted in-process plugins.
- Built-in multi-agent orchestration.
- Automatic replay of interrupted mutating tools.
- Full OTP release hot-upgrade machinery.
- Supporting every model provider and wire protocol.
- A comprehensive permission-dialog framework.

## North Star

Synapse should make autonomous coding attempts boring to recover from:

- Every action is observable.
- Every accepted result is verified.
- Every attempt has a known base.
- Every side effect has an explicit outcome or is marked ambiguous.
- Every UI can disconnect and reconnect.
- Every extension update is versioned and reversible.
- Every failure leaves enough information for the next attempt to improve.
- Every public API explains its purpose, intended use, and operational contract through LSP documentation.
- Every subsystem is understandable through generated ExDoc guides without requiring access to an AI conversation.
- Every feature leaves the owner with more understanding of Elixir, OTP, and Synapse than before it was built.
