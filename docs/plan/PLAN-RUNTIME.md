# Runtime Implementation Checklist

## Purpose

This document is the implementation checklist for the Runtime component defined
in [`PLAN.md`](PLAN.md).

It turns the supervision, cancellation, deadline, failure-recovery, and human
comprehension requirements in [`../../README.md`](../../README.md) into an ordered
set of coding, testing, documentation, and learning tasks for the first runnable
MVP.

The checklist is intentionally limited to Runtime. It does not implement Agent
conversation policy, Provider transport, Tool execution, Workspace file/process
semantics, CLI parsing or rendering, persistence, verification workflows,
worktrees, a reconnectable daemon, or the target multi-run coordinator tree.

## Runtime Outcome

Runtime is complete when a trusted caller can start one validated Run Request,
receive an opaque run handle, await or cancel the run, and receive one structured
Agent terminal after every Runtime-owned process and Workspace resource has
settled.

The first deterministic proof is:

```text
Run Request + trusted Runtime configuration
  -> temporary TaskSupervisor child
  -> Runtime opens one Workspace owned by that child
  -> Runtime builds Agent Context
  -> Agent Runner uses Fake Provider and Fake Workspace
  -> Runtime closes Workspace
  -> exactly one terminal Run Event is published
  -> await returns Agent Result or Agent Error
  -> no Runtime-owned child remains
```

The first real-process proof cancels a harmless long-running command in a
temporary Workspace and confirms that the Runtime task, Workspace owner,
MuonTrap helper, and owned direct command have terminated.

Runtime completion means the Agent process and its owned resources settled. It
does not mean the model's work was verified, accepted, committed, persisted, or
safe to merge.

## Checklist Rules

- Check an item only after implementation, focused tests, public documentation,
  and the relevant learning guide are complete.
- Do not check a phase merely because code exists.
- Use Fake Provider and Fake Workspace for ordinary lifecycle tests.
- Use temporary roots only for Real Workspace and process-cleanup tests.
- Never use a user checkout for cancellation, crash, timeout, or application-stop
  tests.
- Never automatically restart a run task, Workspace mutation owner, Provider
  attempt, Tool call, or side-effecting worker.
- Never convert a crash into success or a known not-applied outcome when a Tool
  may have started.
- Never include arbitrary exit reasons, exceptions, stacktraces, prompts,
  commands, paths, process output, credentials, callbacks, references, or
  Workspace Handles in Runtime errors, events, logs, or ordinary inspection.
- Keep cancellation idempotent and observable after a lower layer consumes the
  matching mailbox message.
- Do not duplicate Provider or Workspace inactivity watchdogs in Runtime.
- Avoid timing sleeps in deterministic tests. Use monitors, barriers, explicit
  messages, and bounded receives.
- Keep each phase small enough to review and understand independently.
- If a public contract changes, update this plan and the parent architecture
  before continuing.

## Progress Summary

| Phase | Deliverable | Status |
| --- | --- | --- |
| 0 | Confirm ownership, API, terminal, and supervision decisions | Planned |
| 1 | Runtime contracts and failure vocabulary | Planned |
| 2 | Application and temporary Workspace supervision | Planned |
| 3 | Start one Runtime-owned run | Planned |
| 4 | Await and terminal publication | Planned |
| 5 | Persistent cancellation propagation | Planned |
| 6 | Worker crash and ambiguity conversion | Planned |
| 7 | Deadline, inactivity, and shutdown integration | Planned |
| 8 | Deterministic and Real Workspace acceptance | Planned |
| 9 | Reliability and security hardening | Planned |
| 10 | ExDoc and comprehension review | Planned |

Update this table only when a phase passes its completion gate.

## Architectural Position

```text
                      CLI or trusted caller
                              |
                              v
                    +-------------------+
                    | Synapse.Runtime   |
                    | start/await/cancel|
                    +---------+---------+
                              |
                              v
                    +-------------------+
                    | TaskSupervisor    |
                    | temporary run task|
                    +---------+---------+
                              |
                  +-----------+-----------+
                  |                       |
                  v                       v
        +-------------------+   +-------------------+
        | Agent.Runner      |   | Workspace Handle  |
        | synchronous loop  |   | Runtime-owned     |
        +---------+---------+   +---------+---------+
                  |                       |
          +-------+-------+               v
          |               |      +-------------------+
          v               v      | Workspace         |
     Provider       Tool.Executor | DynamicSupervisor |
                                      temporary owner
```

Runtime supervises the outer run lifetime. It does not reach inside Provider or
Workspace to become the direct owner of their private workers or ports.

## Dependency Direction

```text
CLI or trusted adapter
  -> Runtime
  -> Run Request and Run Events
  -> Agent Context and Agent Runner
  -> Workspace open/close
  -> OTP TaskSupervisor and DynamicSupervisor

Runtime
  -X-> Provider request encoding, SSE, Req, Finch, or credentials
  -X-> Tool schemas, argument decoding, or dispatch policy
  -X-> File, System, Port, MuonTrap, or direct project operations
  -X-> terminal rendering or exit-code policy
  -X-> persistence, verification, Git, worktrees, or extensions
```

Provider, Agent, Tool, and Workspace consume lifetime data through their existing
contracts. None imports or calls Runtime.

## Runtime Boundary

### Runtime Owns

- Validation of trusted Runtime start configuration.
- One opaque handle for one active run.
- One temporary TaskSupervisor child executing the run.
- Opening one Workspace before Agent starts.
- Closing that Workspace on every catchable terminal path.
- Deriving maximum Workspace Access exactly from Run capabilities.
- Building trusted Agent Context from Runtime configuration and the opened Handle.
- A fresh operation cancellation reference for the run.
- Persistent out-of-band cancellation state.
- Routing cancellation to the process currently blocked in Agent Runner.
- Monitoring the run task and converting unexpected exits conservatively.
- Gating the terminal Run Event until Workspace closure succeeds.
- Returning one structured terminal from `await`.
- Application child order and restart/shutdown policy.

### Runtime Does Not Own

- Conversation, turn, Tool order, output, retry, or final-text semantics.
- Provider retry decisions or request snapshots.
- Provider HTTP worker, Finch connection pool, or SSE reducer state.
- Workspace path, revision, mutation, process, Port, or output semantics.
- Tool argument validation, capability selection, or Result presentation.
- A second inactivity timer for operations already bounded by Provider or
  Workspace.
- Durable event sequence numbers, timestamps, storage, subscriptions, or replay.
- CLI signals, terminal rendering, or process exit codes.
- Verification, acceptance, evidence, commits, or work-item state.
- Concurrent-run coordination across multiple Handles for the same root.
- Persistent RunCoordinator, Registry, daemon, local protocol, or reconnectable
  clients.

## Current Ownership Facts

The Runtime plan must build on the code that already exists rather than replace
its ownership model.

### Agent Runner

- `Synapse.Agent.Runner.run/2` is synchronous.
- The process executing Runner owns immutable Agent State.
- Runner starts no Task, GenServer, timer, ETS table, Port, or Workspace.
- Runner constructs Provider StreamContext and Tool Context from trusted Agent
  Context values.
- Runner owns semantic safe Provider retry; Runtime must not replay Runner.
- Unexpected exceptions, throws, and exits may still leave Runner for Runtime to
  convert.

### Tokamak Provider

- The process calling `Provider.Tokamak.stream/3` is the operation coordinator.
- Tokamak starts and monitors one temporary HTTP worker that owns the Req stream.
- Its watchdog stops the HTTP worker if the coordinator dies.
- Tokamak enforces cancellation, Provider inactivity, and the absolute deadline.
- Runtime must not separately supervise or restart that private HTTP worker.

### Workspace

- A real Workspace opens one MutationServer that monitors the opening owner.
- File and process operations have their own leases, workers, monitors, deadlines,
  and cleanup rules.
- Workspace process cancellation confirms the MuonTrap helper and owned direct
  command; daemonized descendants may escape.
- Runtime must make the run task the Workspace opening owner.
- Runtime must close the Handle normally, while owner monitoring remains the
  fallback for task death or uncatchable termination.

## Architectural Invariants

- Every accepted run has one fresh opaque Runtime Run handle.
- A Run handle never exposes a bare Task, PID, monitor, Workspace Handle,
  cancellation reference, callback, or mutable cell through ordinary inspection.
- Runtime validates Run Request and trusted configuration before starting Agent.
- The run task, not the CLI caller, owns the Workspace Handle.
- Workspace Access is an exact trusted mapping from `fs_read`, `fs_write`, and
  `process_exec`; Runtime never widens authority.
- Runtime opens Workspace before Agent emits `RunStarted`.
- Runtime closes Workspace before publishing a terminal Run Event or returning a
  terminal from `await`.
- Agent remains the sole owner of ordinary successful, failed, interrupted, and
  budget terminal semantics.
- Runtime may synthesize a terminal only for Runtime startup-after-acceptance,
  cleanup, cancellation, or unexpected-worker outcomes that Agent could not
  return itself.
- At most one terminal Run Event is exposed to the caller.
- Runtime never synthesizes `TurnCompleted` after a crash because exact attempt,
  call, and output counters may be unknown.
- A crash after accepted `ToolStarted` and before matching `ToolCompleted` is
  ambiguous, regardless of the advertised Tool side-effect class.
- A crash after visible text is an interruption, not an ordinary clean failure.
- Arbitrary crash reasons and exception data are never copied into public data.
- Cancellation first sets persistent state and only then sends the matching
  mailbox message.
- Repeated cancellation is safe and starts no new operation.
- An `await` timeout does not cancel, kill, or detach the run.
- Temporary run and Workspace children use `restart: :temporary`.
- OTP never restarts or replays a side-effecting one-shot child.
- Agent semantic Provider retry remains the only in-run automatic retry.
- Runtime does not promise safe overlapping runs against one checkout in the MVP.

## Draft MVP Decision Record

Phase 0 must confirm or amend these decisions before implementation. They are
selected to match the completed lower components and the minimal architecture in
`PLAN.md`, not the future persistent-daemon tree in `README.md`.

| Concern | Draft MVP decision | Reason |
| --- | --- | --- |
| Run execution | One temporary supervised Task executes Workspace open, Agent Runner, and Workspace close | Runner is synchronous and needs no permanent GenServer |
| Run lookup | Opaque handle returned directly to one trusted owner/awaiter | Registry and reconnectable lookup are post-MVP |
| Workspace owner | Runtime run task PID | Task death activates existing Workspace owner cleanup |
| Workspace supervision | Real MutationServers start under one DynamicSupervisor with `restart: :temporary` | Makes process ownership visible without replaying side effects |
| Lower workers | Remain private to Provider and Workspace | Their components already own monitors, timeouts, ports, and cleanup |
| Provider | Trusted Runtime configuration, default Tokamak | Model input cannot select arbitrary modules |
| Access | Exact CapabilitySet-to-Workspace Access mapping | Runtime must never widen host authority |
| Cancellation state | Shared persistent flag plus one matching reference/message | Lower operations may consume the mailbox message |
| Cancellation API | Idempotent and asynchronous | The terminal is observed through `await` |
| Await timeout | Return timeout without terminating the run | Waiting policy is not cancellation policy |
| Absolute deadline | Agent computes Budget deadline; Runtime may supply an earlier monotonic deadline | Preserves one effective deadline through existing contexts |
| Inactivity | Provider and Workspace enforce their own configured inactivity | A second Runtime watchdog would race and duplicate ownership |
| Event delivery | Forward non-terminal events synchronously; retain one terminal until Workspace close | Callers must not see completion before cleanup |
| Crash tracking | Mirror only bounded lifecycle transitions, never every text delta | Allows conservative conversion without an unbounded mailbox |
| Crash after ToolStarted | `tool_ambiguous` and no replay | Side-effect outcome is not safely known |
| Crash after visible text | `RunInterrupted` with sanitized Runtime worker error | Partial output is not ordinary completion |
| Task restart | Never | Restart would replay Provider or Tool work |
| Concurrent runs | Unsupported rather than coordinated | Cross-handle same-root coordination needs a later RunSupervisor/Registry policy |
| Persistence | None | Run handle and events are in-memory MVP data |

## Proposed Supervision Tree

```text
Synapse.Application
`-- Synapse.Supervisor                 :one_for_one
    |-- Synapse.Workspace.Supervisor   DynamicSupervisor
    |   `-- Workspace.MutationServer   temporary per real Handle
    `-- Synapse.TaskSupervisor         Task.Supervisor
        `-- Runtime run Task           temporary per accepted run
```

Children are started in the order shown. OTP stops them in reverse order, so run
tasks receive shutdown before the Workspace supervisor. That preserves the
Workspace owner monitor and cleanup service while active runs are terminating.

The tree deliberately does not add RunRegistry, EventRegistry, Store,
CapabilityPolicy, CredentialBroker, ExtensionManager, ProjectManager,
RunSupervisor, or TransportSupervisor. Those belong to the target daemon and
must not be created as empty placeholders.

## Proposed Public Boundary

The exact names must be confirmed in Phase 0, but the MVP semantics should be:

```elixir
Synapse.Runtime.start_run(run_request, event_sink, options \\ [])
# => {:ok, runtime_run} | {:error, runtime_start_error}

Synapse.Runtime.cancel(runtime_run)
# => :ok | {:error, :invalid_run}

Synapse.Runtime.await(runtime_run, timeout \\ :infinity)
# => {:ok, Synapse.Agent.Result.t()}
#  | {:error, Synapse.Agent.Error.t()}
#  | {:error, :await_timeout | :not_owner | :invalid_run}
```

After start/cancel/await behavior is proven, `Runtime.run/3` may be added as the
thin synchronous composition used by simple trusted callers. It must not hide a
different retry, timeout, event, or cleanup policy.

### Runtime Run Handle

The public value is opaque and ordinarily redacted. A possible internal shape is:

```elixir
%Synapse.Runtime.Run{
  id: run_id,
  owner: owner_pid,
  task: task,
  task_ref: task_ref,
  cancel_ref: cancel_ref,
  cancellation: persistent_cell,
  tracker_ref: tracker_ref
}
```

These fields are implementation authority, not stable public data. Callers may
use only Runtime functions. The owner restriction is an MVP mailbox-ownership
rule: `await` must run in the process that called `start_run`, while `cancel` may
be called by another trusted process holding the handle.

### Runtime Configuration

Trusted options may initially select:

```text
provider
instructions
workspace limits
Tool limits
optional earlier absolute monotonic deadline
retry-delay policy
test-only Workspace opener
```

The default Workspace opener constructs `Workspace.OpenRequest` from Request
`cwd`, the run-task owner PID, validated limits, and exact mapped Access, then
calls `Workspace.open/1`. A trusted test opener may create a Fake Handle owned by
the same run task. Runtime still closes either Handle through `Workspace.close/1`.

Callbacks, modules, limits, and deadlines are trusted application configuration.
They never enter Run Request, model context, events, errors, or ordinary
inspection. Production CLI code must use the default real Workspace opener.

### Runtime Start Error

Failures before an active run is accepted should use a small Runtime-owned start
error rather than forging an Agent turn or Run Event. Initial reasons should
cover:

```text
invalid_run_request
invalid_runtime_options
runtime_unavailable
workspace_open_failed
```

The value carries a bounded sanitized message and optional run ID, but no root,
Handle, callback, process identity, exception, or raw Workspace error. Once
`start_run` returns a Run handle, later terminals use Agent Result/Error and Run
Events.

### Agent Error Additions

Runtime needs stable terminal reasons that the current closed Agent Error union
cannot represent. Add only the minimum internal reasons required after a run has
been accepted:

```text
run_worker_crashed
workspace_close_failed
```

An unmatched Tool uses the existing `tool_ambiguous` reason. Cancellation uses
the existing `run_cancelled` reason. Runtime-generated errors must pass the same
bounded allowlisted details validation as Agent-generated errors.

## Run Lifecycle

### Start

```text
validate Request and Runtime options
  -> allocate cancel reference and persistent cancellation cell
  -> start temporary run Task
  -> run Task derives exact Workspace Access
  -> run Task opens Workspace with itself as owner
  -> startup handshake confirms Handle or sanitized open failure
  -> run Task builds Agent Context
  -> Agent Runner begins and emits RunStarted
```

`start_run` may block for the bounded Workspace-open handshake, but it must not
wait for Provider or Tool work. If startup fails, no Run handle is returned and
no Agent Run Event is forged.

### Normal Completion

```text
Agent returns Result or Error
  -> Runtime validates matching buffered terminal Event
  -> Runtime closes Workspace
  -> Runtime publishes the retained terminal Event
  -> run Task returns terminal
  -> await demonitor/flushes task ownership
  -> await returns terminal
```

If the terminal event sink fails, Runtime returns a structured event-sink failure
where possible but cannot guarantee delivery through the failed sink.

### Cancellation

```text
cancel(run)
  -> atomically mark persistent cancellation true
  -> send {:cancel, cancel_ref} to run Task
  -> active Provider/Workspace coordinator consumes matching message
  -> Agent persistent probe remains true
  -> no later operation starts
  -> Workspace closes
  -> RunInterrupted is published
  -> await returns run_cancelled
```

Cancellation is a request, not proof of immediate OS-level termination. Runtime
waits for the structured lower-layer terminal and Workspace closure. If a bounded
shutdown policy later forces task termination, any unmatched Tool is ambiguous.

### Unexpected Worker Exit

```text
run Task exits without a valid terminal
  -> await observes monitored DOWN
  -> read bounded mirrored lifecycle state
  -> classify cancellation / partial output / unmatched Tool / ordinary crash
  -> wait for or confirm Workspace owner cleanup where observable
  -> publish one sanitized terminal Event if the sink remains available
  -> return one structured Agent Error
```

Runtime never exposes the raw `DOWN` reason. It never assumes cleanup proves that
a daemonized descendant or hostile same-user process is gone.

## Event Rules

- Continue using the implemented `Synapse.Run.Event` union.
- Do not add a second public Runtime operation-event vocabulary for the MVP.
- Forward Agent non-terminal events synchronously and in source order.
- Treat the event sink as trusted but fallible.
- Retain at most one terminal Agent event inside the run task.
- Publish that terminal only after Workspace close succeeds.
- Mirror only bounded state required for crash conversion: visible-output flag,
  active Tool identity, and terminal-seen state.
- Do not mirror TextDelta content, Tool arguments, Tool Result content, commands,
  paths, or process output.
- Clear active Tool state only after the operation has a known ToolCompleted
  boundary.
- Never publish a second terminal after an accepted RunCompleted, RunFailed, or
  RunInterrupted.
- Never synthesize exact turn accounting after an abnormal exit.
- Durable sequence numbers, timestamps, persistence barriers, replay, and
  coalescing remain post-MVP.

## Timeout And Activity Rules

Runtime distinguishes four policies:

| Policy | Owner | MVP behavior |
| --- | --- | --- |
| Aggregate wall time | Agent State from Run Budget, optionally lowered by Runtime | Checked before operations and passed as one absolute monotonic deadline |
| Provider inactivity | Tokamak coordinator from StreamContext | Stops owned HTTP worker and returns Provider timeout |
| Tool/process inactivity | Workspace process owner from OperationContext and ProcessSpec | Stops owned command and reports known or ambiguous outcome |
| Await timeout | Runtime caller | Stops waiting only; does not cancel the run |

Activity callbacks preserve component decoupling and may support later telemetry,
but Runtime must not add a competing timer around a lower operation that already
owns exact activity semantics. A malicious or contract-violating injected module
that ignores cancellation and deadlines is outside the production Provider and
Workspace guarantees; forced task shutdown remains conservative and may be
ambiguous.

## Failure Classification

| Situation | Terminal classification | Event |
| --- | --- | --- |
| Invalid Request/options before acceptance | Runtime start error | None |
| Workspace cannot open before Agent starts | Runtime start error | None |
| Agent returns Result | Agent Result after close | RunCompleted |
| Agent returns Error | Same Agent Error after close | RunFailed or RunInterrupted |
| Workspace close fails after Agent terminal | internal / workspace_close_failed | RunFailed |
| Worker crash with no visible output or active Tool | internal / run_worker_crashed | RunFailed |
| Worker crash after visible model output | internal / run_worker_crashed | RunInterrupted |
| Worker crash with unmatched ToolStarted | tool / tool_ambiguous | RunFailed |
| Cancelled worker with no unmatched Tool | cancelled / run_cancelled | RunInterrupted |
| Cancelled worker with unmatched Tool | cancelled / run_cancelled with bounded ambiguity details | RunInterrupted |
| Event sink fails | internal / event_sink_failed where constructible | Terminal delivery not guaranteed |

Runtime may know less than Agent after a crash. Conservative uncertainty is
required; a nicer-looking but unjustified ordinary failure is incorrect.

## Phase 0: Confirm Runtime Decisions

### Architecture

- [ ] Re-read Runtime sections in `PLAN.md`, Agent Loop plan, Workspace plan, and
  Provider plan against current source.
- [ ] Confirm one temporary supervised run Task remains sufficient for the MVP.
- [ ] Confirm no dedicated Run GenServer, Registry, or DynamicSupervisor of run
  coordinators is required.
- [ ] Confirm real Workspace MutationServers move under one DynamicSupervisor.
- [ ] Confirm Provider and Workspace private workers remain component-owned.
- [ ] Confirm application child start and shutdown order.
- [ ] Confirm concurrent runs against one root are unsupported rather than
  silently safe.

### Public API

- [ ] Confirm names and exact return shapes for start, cancel, await, and optional
  synchronous run convenience.
- [ ] Confirm one owner/awaiter mailbox rule.
- [ ] Confirm cancellation may be called from another trusted process.
- [ ] Confirm await timeout does not cancel.
- [ ] Confirm Workspace-open handshake behavior and bound.
- [ ] Confirm Runtime options and deterministic injection seam.

### Terminal Semantics

- [ ] Confirm terminal events are retained until Workspace close.
- [ ] Confirm minimum Agent Error reason additions.
- [ ] Confirm crash-after-output becomes interruption.
- [ ] Confirm unmatched Tool crash becomes ambiguity.
- [ ] Confirm Runtime never synthesizes TurnCompleted after a crash.
- [ ] Confirm behavior when terminal event delivery itself fails.

### Learning Gate

- [ ] Explain why Runtime is not the Agent Loop.
- [ ] Explain why supervising a Task does not justify restarting it.
- [ ] Explain why lower operation workers remain under Provider/Workspace
  ownership.
- [ ] Explain why Workspace closure must precede public terminal completion.
- [ ] Record every amended decision in this document before implementation.

### Phase Complete When

- [ ] The public API, process tree, ownership, cancellation, terminal, and crash
  decisions are explicit.
- [ ] No unresolved decision would change Runtime's process topology or public
  contract.

## Phase 1: Implement Runtime Contracts

### Code

- [ ] Create `Synapse.Runtime` public facade and shared result types.
- [ ] Create opaque `Synapse.Runtime.Run` handle.
- [ ] Create bounded `Synapse.Runtime.Error` for pre-acceptance start failures.
- [ ] Add minimum Runtime-owned reasons to `Synapse.Agent.Error`.
- [ ] Validate trusted Runtime options without starting a process.
- [ ] Validate Provider module through the existing behaviour contract.
- [ ] Validate Workspace and Tool limits together.
- [ ] Validate optional monotonic deadline and retry-delay callback.
- [ ] Add redacted Inspect implementations for all authority-bearing contracts.

### Tests

- [ ] Valid default configuration.
- [ ] Valid trusted Fake Provider and Workspace opener configuration.
- [ ] Invalid Request, Provider module, sink, deadline, limits, opener, and retry
  delay.
- [ ] Unknown option rejection.
- [ ] Run and configuration inspection expose no PID, Task, root, callback,
  reference, Handle, prompt, or secret.
- [ ] Runtime start errors contain no raw Workspace error or path.
- [ ] New Agent Error reasons remain bounded and allowlisted.

### Documentation And Learning

- [ ] Document who creates, owns, and consumes every Runtime contract.
- [ ] Explain why Run handle is opaque.
- [ ] Explain why Runtime start errors are distinct from accepted-run terminals.
- [ ] Explain trusted injection versus model-controlled input.

### Phase Complete When

- [ ] Contracts compile with warnings as errors.
- [ ] Contract and inspection tests pass.
- [ ] No Task, Workspace, Provider, or timer starts in contract constructors.
- [ ] LSP hover explains every public field and return shape.

## Phase 2: Build Application Supervision

### Application Tree

- [ ] Start named `Synapse.Workspace.Supervisor` as a DynamicSupervisor.
- [ ] Start named `Synapse.TaskSupervisor` as a Task.Supervisor.
- [ ] Keep root strategy `:one_for_one`.
- [ ] Start Workspace supervisor before Task supervisor.
- [ ] Document root-child restart and shutdown policies.

### Workspace Integration

- [ ] Start real MutationServer through Workspace Supervisor.
- [ ] Retain `restart: :temporary`.
- [ ] Retain opening-owner monitoring.
- [ ] Keep Fake Workspace independently owner-monitored for deterministic tests.
- [ ] Preserve existing `Workspace.open/1` and opaque Handle facade.
- [ ] Return structured unavailable error if Workspace Supervisor is absent.

### Tests

- [ ] Exact named application children and child types.
- [ ] Root supervisor restart does not change child policy.
- [ ] Real Workspace opens as a DynamicSupervisor child.
- [ ] Explicit close removes the temporary child.
- [ ] Opening-owner death removes the temporary child.
- [ ] Abnormal MutationServer exit is not restarted.
- [ ] Application stop terminates run-task children before Workspace supervisor.

### Documentation And Learning

- [ ] Explain Supervisor versus DynamicSupervisor versus TaskSupervisor.
- [ ] Explain permanent infrastructure children versus temporary side-effecting
  children.
- [ ] Add the exact MVP supervision diagram.
- [ ] Document why empty future-daemon children are not added.

### Phase Complete When

- [ ] Application starts and stops cleanly with the two infrastructure children.
- [ ] Temporary Workspace owners never restart.
- [ ] Existing Workspace tests remain green.
- [ ] Supervision tree is understandable through ExDoc.

## Phase 3: Start One Runtime-Owned Run

### Start Path

- [ ] Revalidate Run Request and Runtime options.
- [ ] Allocate one fresh cancellation reference and persistent state cell.
- [ ] Start one temporary task through TaskSupervisor.
- [ ] Derive exact Workspace Access from Run capabilities.
- [ ] Open Workspace with the run task as owner.
- [ ] Complete a bounded startup handshake before returning Run handle.
- [ ] Map Workspace-open failure to sanitized Runtime start error.
- [ ] Build Agent Context only after Workspace succeeds.
- [ ] Pass Provider, Handle, instructions, sink, cancellation, deadline, limits,
  activity seams, and retry policy through Agent Context.
- [ ] Call Agent Runner exactly once.

### Authority

- [ ] Map `fs_read` only to Workspace `read`.
- [ ] Map `fs_write` only to Workspace `write`.
- [ ] Map `process_exec` only to Workspace `exec`.
- [ ] Never derive Provider, capabilities, limits, callbacks, or deadline from
  prompt or model output.
- [ ] Ensure Tool limits cannot exceed Workspace ceilings.
- [ ] Keep API key lookup inside Provider transport.

### Tests

- [ ] Start a text-only Fake run and receive an opaque handle.
- [ ] Exact Workspace owner is the run task, not test or CLI process.
- [ ] Exact Access mapping for all capability combinations.
- [ ] Agent receives exact trusted Context values.
- [ ] Workspace-open failure starts no Provider turn.
- [ ] Startup handshake timeout leaves no task or Workspace child.
- [ ] Task child spec is temporary.
- [ ] Distinct runs receive distinct references and task identities.

### Documentation And Learning

- [ ] Trace Request cwd into Workspace OpenRequest without calling it canonical
  before Workspace validates it.
- [ ] Trace capabilities into Handle Access and per-operation reduction.
- [ ] Explain why Agent receives a Handle but Run Request does not.
- [ ] Add start-handshake sequence diagram.

### Phase Complete When

- [ ] One Fake text run starts only through public Runtime.
- [ ] Runtime, not Agent or CLI, owns Workspace open.
- [ ] No startup failure leaks an owned process or Handle.
- [ ] Runtime imports no host-operation or Provider wire modules.

## Phase 4: Await And Publish One Terminal

### Await

- [ ] Receive task result through the opaque Run handle.
- [ ] Validate returned Agent Result/Error before exposing it.
- [ ] Restrict await to the handle owner for the MVP.
- [ ] Dismiss task monitor and flush ownership messages exactly once.
- [ ] Reject a second await deterministically.
- [ ] Return await timeout without sending cancellation or killing the task.
- [ ] Allow a later await after timeout.

### Terminal Gate

- [ ] Forward non-terminal Agent events synchronously.
- [ ] Retain at most one terminal Agent event.
- [ ] Validate terminal event and returned tuple agree on run ID and outcome.
- [ ] Close Workspace in every normal Agent terminal path.
- [ ] Publish retained terminal only after successful close.
- [ ] Convert close failure to one sanitized Runtime terminal.
- [ ] Never expose the earlier Agent terminal after close failure.
- [ ] Return only after the Runtime task and Workspace owner settled.

### Tests

- [ ] Successful result: close precedes RunCompleted and await return.
- [ ] Agent failure: close precedes RunFailed and await return.
- [ ] Agent interruption: close precedes RunInterrupted and await return.
- [ ] Await timeout leaves task alive and later await succeeds.
- [ ] Second await and non-owner await are rejected.
- [ ] Mismatched or missing Agent terminal is a Runtime contract failure.
- [ ] Workspace close failure overrides buffered completion without two terminals.
- [ ] Event sink failure never leaks a Workspace owner.

### Documentation And Learning

- [ ] Explain task result versus Run Event terminal.
- [ ] Explain why Runtime temporarily buffers one terminal.
- [ ] Explain why await timeout differs from run deadline and cancellation.
- [ ] Add normal completion and cleanup sequence diagram.

### Phase Complete When

- [ ] Every accepted ordinary path publishes at most one terminal.
- [ ] No caller observes RunCompleted before Workspace closure.
- [ ] Await never exposes Task exit tuples or Workspace errors directly.
- [ ] Repeated waiting behavior is explicit and tested.

## Phase 5: Propagate Persistent Cancellation

### Cancellation Control

- [ ] Store cancellation in a process-independent persistent cell.
- [ ] Mark the cell before sending the mailbox message.
- [ ] Send only `{:cancel, cancel_ref}` to the run task.
- [ ] Make cancellation idempotent before, during, and after terminal completion.
- [ ] Permit trusted non-owner processes to call cancel.
- [ ] Keep cancel non-blocking; await owns terminal observation.

### Lower-Layer Propagation

- [ ] Agent cancellation probe reads the persistent cell.
- [ ] Agent passes the exact reference into every Provider and Tool context.
- [ ] Provider cancellation stops its owned request worker.
- [ ] Workspace cancellation stops or classifies the active operation according to
  existing semantics.
- [ ] Agent starts no later Provider or Tool after cancellation.
- [ ] Runtime closes Workspace before publishing RunInterrupted.

### Tests

- [ ] Cancellation before first Provider attempt.
- [ ] Cancellation during Fake Provider operation.
- [ ] Cancellation during Provider retry delay.
- [ ] Cancellation during known-not-applied Tool operation.
- [ ] Cancellation during ambiguous Tool operation.
- [ ] Cancellation during a Real long-running command in a temporary Workspace.
- [ ] Persistent probe remains true after lower layer consumes mailbox message.
- [ ] Cancel-versus-natural-completion race emits one terminal.
- [ ] Repeated and post-terminal cancel calls are harmless.
- [ ] Unrelated and mismatched cancellation messages are ignored.

### Documentation And Learning

- [ ] Explain mailbox cancellation versus persistent cancellation state.
- [ ] Explain cancellation request versus confirmed cleanup.
- [ ] Explain why cancellation does not imply not-applied Tool outcome.
- [ ] Add end-to-end cancellation sequence diagram.

### Phase Complete When

- [ ] Cancellation reaches every active production operation through existing
  contracts.
- [ ] No later operation starts after cancellation.
- [ ] Known and ambiguous Tool outcomes remain distinguishable.
- [ ] No cancelled test leaves a Runtime-owned process running.

## Phase 6: Convert Worker Crashes Conservatively

### Bounded Lifecycle Tracking

- [ ] Track whether any user-visible model output was accepted.
- [ ] Track only the current accepted ToolStarted identity.
- [ ] Clear active Tool only at matching ToolCompleted.
- [ ] Track whether an external terminal was accepted.
- [ ] Mirror compact transitions to the await owner for uncatchable task exits.
- [ ] Bound tracking by fixed fields and Agent Budget, not text-delta count/content.

### Crash Conversion

- [ ] Catch ordinary exceptions, throws, and exits around Runner and cleanup.
- [ ] Monitor the run task for uncatchable abnormal exits.
- [ ] Sanitize every crash without inspecting arbitrary reason content publicly.
- [ ] Convert no-output/no-Tool crash to `run_worker_crashed` and RunFailed.
- [ ] Convert crash after visible output to RunInterrupted.
- [ ] Convert unmatched ToolStarted to `tool_ambiguous` and stop.
- [ ] If cancellation was set, preserve run_cancelled and bounded ambiguity details.
- [ ] Emit no TurnCompleted with invented counters.
- [ ] Never restart the crashed task.
- [ ] Never retry Provider, Tool, or Workspace work after crash.

### Tests

- [ ] Inject Provider raise, throw, exit, and malformed worker termination.
- [ ] Crash before RunStarted.
- [ ] Crash after TurnStarted with no output.
- [ ] Crash after first accepted TextDelta.
- [ ] Crash after ToolStarted before Workspace invocation.
- [ ] Crash during a Tool with unknown side-effect outcome.
- [ ] Crash after ToolCompleted and before next turn.
- [ ] Crash after buffered terminal and before return.
- [ ] Forced uncatchable task kill uses mirrored state.
- [ ] Raw exception, exit reason, stacktrace, prompt, path, command, and output are
  absent from terminal data and captured logs.
- [ ] A counter/barrier proves temporary task is not restarted.

### Documentation And Learning

- [ ] Explain link versus monitor behavior for the Runtime task.
- [ ] Explain why supervision does not imply restart.
- [ ] Explain why missing ToolCompleted means ambiguity.
- [ ] Explain which crashes Runtime can catch and which only a monitor observes.
- [ ] Add crash-classification diagram.

### Phase Complete When

- [ ] Every injected worker exit returns one sanitized structured terminal.
- [ ] No crash path replays an operation.
- [ ] Uncertain side effects are never mislabeled not-applied.
- [ ] No raw BEAM failure term crosses Runtime's public boundary.

## Phase 7: Integrate Deadlines, Inactivity, And Application Shutdown

### Deadline Wiring

- [ ] Preserve Run Budget as Agent's aggregate wall-time policy.
- [ ] Accept only an optional earlier absolute monotonic Runtime deadline.
- [ ] Pass that deadline through Agent Context without wall-clock conversion.
- [ ] Confirm Agent chooses the earlier Budget/Runtime deadline.
- [ ] Confirm the same effective deadline reaches Provider and Workspace contexts.
- [ ] Start no operation after deadline expiration.

### Inactivity Ownership

- [ ] Confirm Provider inactivity comes from Run Budget through StreamContext.
- [ ] Confirm Tool inactivity lowers Tool/Workspace process policy.
- [ ] Do not create a second Runtime operation timer.
- [ ] Use activity sinks only for bounded observation or future telemetry seams.
- [ ] Document why meaningful activity is component-specific.

### Application Shutdown

- [ ] Confirm TaskSupervisor stops active run tasks before Workspace Supervisor.
- [ ] Confirm run-task death triggers Workspace owner cleanup.
- [ ] Confirm Provider watchdog stops an owned HTTP request when coordinator dies.
- [ ] Confirm Workspace cleanup stops the owned direct command and private runtime
  environment under documented limits.
- [ ] Preserve explicit limitation for daemonized descendants.

### Tests

- [ ] Already elapsed Runtime deadline starts no Provider operation.
- [ ] Earlier Runtime deadline beats Budget deadline.
- [ ] Provider inactivity returns one interrupted terminal.
- [ ] Process inactivity returns known or ambiguous terminal according to outcome.
- [ ] Application stop during Fake Provider leaves no script owner.
- [ ] Application stop during Real command leaves no owned direct command.
- [ ] Application stop during Workspace mutation does not restart mutation owner.
- [ ] All deadline tests use monotonic time and deterministic barriers where
  possible.

### Documentation And Learning

- [ ] Explain aggregate deadline, operation inactivity, operation timeout, await
  timeout, and supervisor shutdown separately.
- [ ] Explain why process existence is not meaningful activity.
- [ ] Explain component-owned timeout versus Runtime-owned lifetime.
- [ ] State exact cleanup proof and descendant limitations.

### Phase Complete When

- [ ] A hung production Provider request or command cannot block indefinitely.
- [ ] Runtime adds no competing lower-operation timeout.
- [ ] Application shutdown leaves no owned direct operation in tests.
- [ ] Deadline and shutdown semantics are understandable from ExDoc.

## Phase 8: Deterministic And Real Acceptance

### Deterministic Fake Scenario

- [ ] Start through public Runtime with Fake Provider and Fake Workspace.
- [ ] Complete `read -> write -> bash -> final text` in source order.
- [ ] Assert exact Run Events and terminal result.
- [ ] Assert Workspace opened under run-task owner and closed before terminal.
- [ ] Assert Provider and Workspace scripts are exhausted.
- [ ] Assert TaskSupervisor has no remaining run child.
- [ ] Assert no network or host side effect occurred.

### Failure Matrix

- [ ] Workspace-open failure.
- [ ] Agent ordinary failure.
- [ ] Provider retry then success.
- [ ] Provider interruption after output.
- [ ] Tool ambiguity.
- [ ] Cancellation at each safe boundary.
- [ ] Worker crash at each tracked boundary.
- [ ] Workspace-close failure.
- [ ] Await timeout followed by success and followed by cancellation.
- [ ] Application shutdown with active work.

### Temporary Real Workspace

- [ ] Open a synthetic temporary root only through Runtime.
- [ ] Run Fake Provider through real Read, Write/Edit, and Bash verification.
- [ ] Cancel one long-running harmless command.
- [ ] Verify file and process outcomes independently of model text.
- [ ] Confirm no Runtime task, MutationServer, private process environment,
  MuonTrap helper, or owned direct command remains.
- [ ] Preserve documented descendant-process limitation.

### Boundary Audits

- [ ] Runtime calls Workspace only for open/close, never file/process operations.
- [ ] Runtime calls Agent only through Runner boundary.
- [ ] Runtime imports no Req, Finch, SSE, credential, File, System, Port, MuonTrap,
  Tool adapter, or terminal module.
- [ ] Provider, Agent, Tool, and Workspace import no Runtime module.
- [ ] Deterministic tests require no Tokamak key.
- [ ] Real tests touch only their own temporary roots.

### Phase Complete When

- [ ] Full Fake coding loop completes only through public Runtime.
- [ ] Real cancellation and cleanup proof passes in a temporary Workspace.
- [ ] Every failure matrix row returns one bounded terminal.
- [ ] No acceptance test uses a user checkout or live credential.

## Phase 9: Reliability And Security Hardening

### Races And Resource Ownership

- [ ] Stress cancel versus completion.
- [ ] Stress await timeout versus terminal delivery.
- [ ] Stress crash versus Workspace owner cleanup.
- [ ] Stress application stop versus active Provider and process work.
- [ ] Confirm startup handshake messages cannot be confused across runs.
- [ ] Confirm stale Run handles cannot control later runs.
- [ ] Confirm all monitors are dismissed and mailbox ownership messages flushed.
- [ ] Confirm persistent cancellation cells become collectible after handle/task
  release.
- [ ] Confirm bounded transition tracking cannot grow per text delta.

### Failure Injection

- [ ] TaskSupervisor unavailable.
- [ ] Workspace Supervisor unavailable.
- [ ] Workspace opener returns malformed data, raises, throws, or exits.
- [ ] Agent returns malformed terminal.
- [ ] Workspace close returns malformed data, raises, throws, exits, or hangs within
  the documented test seam.
- [ ] Event sink rejects, raises, throws, exits, or blocks under a controlled
  cancellation test.
- [ ] Cancellation caller races task death.
- [ ] Await owner dies without cancelling the run.

### Security Review

- [ ] Search Runtime structs for prompts, roots, credentials, headers, commands,
  output, Handles, callbacks, PIDs, Tasks, monitors, and references.
- [ ] Search Runtime logs and errors for raw exception and exit inspection.
- [ ] Test with recognizable synthetic secrets, paths, prompts, commands, and
  process output.
- [ ] Confirm Runtime never widens capability or limit values.
- [ ] Confirm child processes do not inherit Tokamak credentials through Runtime.
- [ ] Confirm no model value selects module, callback, supervisor, process, or
  cancellation authority.
- [ ] State that BEAM supervision, Workspace, and worktrees are not security
  sandboxes.

### Phase Complete When

- [ ] Race and failure-injection tests pass repeatedly.
- [ ] No monitor, message, Task, Workspace owner, or persistent cell leaks.
- [ ] Runtime-generated public data contains only bounded sanitized fields.
- [ ] Restart and replay remain impossible by child policy.

## Phase 10: ExDoc And Comprehension Review

### Module Documentation

- [ ] Every public Runtime module has `@moduledoc`.
- [ ] Every public function has purpose-oriented `@doc` and accurate `@spec`.
- [ ] Every public struct has `t()` and documented ownership.
- [ ] Every supervisor child documents purpose, restart, and shutdown policy.
- [ ] `@moduledoc false` and `@doc false` are absent unless explicitly justified.

### Required Explanations

- [ ] Why Runner is synchronous inside a temporary Runtime Task.
- [ ] Why Runtime owns Workspace open/close but not Workspace operations.
- [ ] Why Provider and Workspace private workers are not re-supervised.
- [ ] Why cancellation needs both a message and persistent state.
- [ ] Why terminal publication waits for cleanup.
- [ ] Why temporary children never restart.
- [ ] Why crash after ToolStarted is ambiguous.
- [ ] Why await timeout does not cancel.
- [ ] Why the MVP has no Registry, daemon, persistence, or reconnectable client.

### Required Diagrams And Examples

- [ ] Application supervision tree.
- [ ] Start and Workspace-open handshake.
- [ ] Normal completion and terminal gate.
- [ ] Cancellation propagation.
- [ ] Crash and ambiguity conversion.
- [ ] Text-only Fake Runtime example.
- [ ] Start, cancel, and await example.

### Project Documentation

- [ ] Add `docs/learning/RUNTIME.md` as the maintenance guide.
- [ ] Add Runtime plan and guide to ExDoc groups.
- [ ] Add Runtime modules to ExDoc module groups.
- [ ] Update `README.md` implementation status.
- [ ] Update `PLAN.md` Runtime summary and build checklist.
- [ ] Mark README's persistent daemon tree and durable event vocabulary clearly as
  target/post-MVP architecture.
- [ ] Correct stale ownership wording discovered in Provider, Workspace, Tool, or
  Agent plans.

### Comprehension Gate

- [ ] Can the owner draw the exact running process tree for one run?
- [ ] Can the owner identify every permanent and temporary child and restart
  policy?
- [ ] Can the owner explain which process owns Workspace and Agent State?
- [ ] Can the owner trace cancellation from public API to Provider HTTP shutdown
  and Workspace process cleanup?
- [ ] Can the owner distinguish Budget deadline, inactivity, process timeout,
  await timeout, and application shutdown?
- [ ] Can the owner explain why terminal Run Event is delayed until close?
- [ ] Can the owner classify crashes before output, after output, and during a
  Tool?
- [ ] Can the owner prove no side-effecting child is automatically replayed?
- [ ] Can the owner test Runtime without Tokamak or host side effects?
- [ ] Can the owner list every deferred daemon and recovery capability?

### Phase Complete When

- [ ] `mix docs` succeeds without Runtime documentation warnings.
- [ ] All examples and doctests pass.
- [ ] The Runtime process and resource lifecycle can be understood without the
  original design conversation.
- [ ] Known cleanup and concurrency limitations are explicit.

## Test Matrix

| Layer | Primary proof | Network/host side effects |
| --- | --- | --- |
| Runtime contracts | Unit, types, and inspection tests | None |
| Application supervision | Supervisor child and restart-policy tests | None |
| Start/await/terminal | Fake Provider + Fake Workspace | None |
| Cancellation | Blocking deterministic fakes and barriers | None |
| Crash conversion | Dedicated crashing test Provider/opener | None |
| Deadline wiring | Fake Provider + Fake Workspace | None |
| Workspace supervision | Temporary Real Workspace | Temporary files only |
| Process cleanup | Temporary Real Workspace + harmless command | Temporary process only |
| Application shutdown | Fake and temporary Real operations | Temporary only |
| ExDoc | Documentation build and doctests | None |

## Suggested Test Layout

```text
test/
  runtime_contracts_test.exs
  runtime_supervision_test.exs
  runtime_start_test.exs
  runtime_await_test.exs
  runtime_cancellation_test.exs
  runtime_crash_test.exs
  runtime_deadline_test.exs
  runtime_real_workspace_test.exs
  runtime_phase10_test.exs
```

Prefer small dedicated test Providers and opener callbacks over broad mocking.
Use explicit ready/continue barriers so tests prove ownership transitions rather
than relying on scheduler timing.

## Suggested Commit Sequence

1. `Define Runtime contracts and decisions`
2. `Supervise Runtime and Workspace workers`
3. `Start one Runtime-owned Agent run`
4. `Gate terminal events on Workspace cleanup`
5. `Propagate persistent run cancellation`
6. `Convert Runtime worker crashes`
7. `Verify deadlines and application shutdown`
8. `Harden and document Runtime lifecycle`

Each commit must compile, pass focused tests, and include documentation for its
public behavior and limitations.

## Final Runtime Verification

```bash
mix format
mix format --check-formatted
mix compile --warnings-as-errors
mix test --warnings-as-errors
mix docs
mix deps.unlock --check-unused
mix hex.outdated
```

No live Tokamak request is required to complete Runtime. The existing opt-in live
Agent test may later be rerouted through public Runtime as an integration smoke
test, but deterministic Runtime behavior must never require credentials.

## Runtime Definition Of Done

- [ ] Phases 0 through 10 are complete.
- [ ] Runtime boundary matches `PLAN.md` and completed lower components.
- [ ] Application starts TaskSupervisor and Workspace Supervisor in documented
  order.
- [ ] Every run executes in one temporary supervised task.
- [ ] Runtime owns Workspace open and close for every accepted run.
- [ ] Workspace closes before terminal publication and await return.
- [ ] Start, cancel, and await use one opaque redacted Run handle.
- [ ] Await timeout never implies cancellation.
- [ ] Cancellation remains observable after lower message consumption.
- [ ] Provider and Workspace retain private operation-worker ownership.
- [ ] Runtime adds no duplicate inactivity watchdog.
- [ ] Worker crashes become bounded conservative terminals.
- [ ] Unmatched Tool execution becomes ambiguous and is never replayed.
- [ ] No side-effecting temporary child automatically restarts.
- [ ] Application shutdown leaves no Runtime-owned direct operation in tests.
- [ ] Deterministic tests need no network, API key, user files, or scheduler sleeps.
- [ ] Runtime imports no Provider wire, Tool adapter, host-operation, or terminal
  modules.
- [ ] ExDoc explains supervision, ownership, cancellation, deadlines, events,
  cleanup, crashes, security, and deferred work.
- [ ] The owner can maintain Runtime without the original AI conversation.

## Deferred Runtime Work

Do not add these before the MVP Runtime is complete:

- Persistent local daemon and Unix socket.
- Dedicated RunCoordinator GenServer or per-run DynamicSupervisor subtree.
- Run Registry, Event Registry, subscriptions, reconnect, replay, or snapshots.
- Durable event sequence numbers, timestamps, persistence barriers, or telemetry.
- SQLite sessions, attempts, work items, evidence, or crash recovery.
- Concurrent-run policy, same-root coordination across Handles, or run queues.
- Follow-up, steering, approval, or interactive-input queues.
- Verification workflows, acceptance gates, commits, or project state machines.
- Worktrees, fresh-attempt retries, rollback, merge, or integration policy.
- Automatic Tool retry or replay after uncertain outcomes.
- Durable operation journal and post-crash side-effect reconciliation.
- Parallel Tools, subagents, delegated supervision trees, or orchestration.
- Dynamic extensions, generation pinning, hot reload, MCP, or web search.
- Capability-token broker, credential broker, keychain, or secret leases.
- OS-user, container, VM, filesystem, network, syscall, CPU, memory, or process
  sandboxing.
- Clustered Erlang, distributed Registry, remote workers, or failover.

These features should reuse the opaque run control, temporary-child policy,
persistent cancellation, terminal gate, conservative crash classification, and
explicit ownership boundaries established by this checklist rather than
enlarging the MVP Runtime prematurely.
