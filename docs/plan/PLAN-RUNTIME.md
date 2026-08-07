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
semantics, API wire handling or frontend rendering, persistence, verification
workflows, worktrees, a durable daemon, or the target multi-run coordinator tree.

## Runtime Outcome

Runtime is complete when a trusted caller can start one validated Run Request,
receive an opaque run handle, await or cancel the run, and receive one structured
Agent terminal after the temporary RunServer, Agent task, and Workspace resource
have settled. If RunServer itself is lost, `await` instead returns one sanitized
Runtime Error with reason `runtime_lost`; no Run Event can be guaranteed after the
process owning its sink and event state has died.

The first deterministic proof is:

```text
Run Request + trusted Runtime configuration
  -> temporary Runtime RunServer
  -> linked temporary TaskSupervisor Agent child
  -> Runtime opens one Workspace owned by the Agent child
  -> Runtime builds Agent Context
  -> Agent Runner uses Fake Provider and Fake Workspace
  -> Runtime closes Workspace
  -> exactly one terminal Run Event is published
  -> await returns Agent Result or Agent Error
  -> no Runtime-owned child remains
```

The first real-process proof cancels a harmless long-running command in a
temporary Workspace and confirms that RunServer, Agent task, Workspace owner,
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
- Never automatically restart RunServer, Agent task, Workspace mutation owner, Provider
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
| 0 | Confirm ownership, API, terminal, and supervision decisions | Complete |
| 1 | Runtime contracts and failure vocabulary | Complete |
| 2 | Application and temporary Workspace supervision | Complete |
| 3 | Start one Runtime-owned run | Complete |
| 4 | Await and terminal publication | Complete |
| 5 | Persistent cancellation propagation | Complete |
| 6 | Worker crash and ambiguity conversion | Complete |
| 7 | Deadline, inactivity, and shutdown integration | Complete |
| 8 | Deterministic and Real Workspace acceptance | Complete |
| 9 | Reliability and security hardening | Complete |
| 10 | ExDoc and comprehension review | Complete |

Update this table only when a phase passes its completion gate.

## Architectural Position

```text
                  API RunSession or trusted caller
                              |
                              v
                    +-------------------+
                    | Synapse.Runtime   |
                    | start/await/cancel|
                    +---------+---------+
                              |
                              v
                    +-------------------+
                    | Runtime.RunServer |
                    | temporary owner   |
                    +---------+---------+
                              |
                              v
                    +-------------------+
                    | TaskSupervisor    |
                    | linked Agent task |
                    +---------+---------+
                              |
                  +-----------+-----------+
                  |                       |
                  v                       v
        +-------------------+   +-------------------+
        | Agent.Runner      |   | Workspace Handle  |
        | synchronous loop  |   | Agent-task owner  |
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
API RunSession or trusted adapter
  -> Runtime
  -> Run Request and Run Events
  -> Agent Context and Agent Runner
  -> Workspace open/close
  -> OTP TaskSupervisor and DynamicSupervisor

Runtime
  -X-> Provider request encoding, SSE, Req, Finch, or credentials
  -X-> Tool schemas, argument decoding, or dispatch policy
  -X-> File, System, Port, MuonTrap, or direct project operations
  -X-> API wire mapping, frontend presentation, or workflow result policy
  -X-> persistence, verification, Git, worktrees, or extensions
```

Provider, Agent, Tool, and Workspace consume lifetime data through their existing
contracts. None imports or calls Runtime.

## Runtime Boundary

### Runtime Owns

- Validation of trusted Runtime start configuration.
- One opaque handle for the single active MVP run.
- One temporary RunServer owning mutable lifecycle state.
- One linked temporary TaskSupervisor child executing Agent Runner.
- Opening one Workspace before Agent starts.
- Closing that Workspace on every catchable terminal path.
- Deriving maximum Workspace Access exactly from Run capabilities.
- Building trusted Agent Context from Runtime configuration and the opened Handle.
- A fresh operation cancellation reference for the run.
- Persistent out-of-band cancellation state.
- Routing cancellation to the process currently blocked in Agent Runner.
- Monitoring the Agent task and converting unexpected exits conservatively even
  when no caller is currently awaiting.
- Gating the terminal Run Event until normal close succeeds or owner-down cleanup
  is observed.
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
- API commands, wire encoding, frontend presentation, or workflow result policy.
- Verification, acceptance, evidence, commits, or work-item state.
- Concurrent-run coordination across multiple Handles for the same root.
- Persistent RunCoordinator, durable Registry/event store, or reconnectable clients
  across Manager/application restart. The higher API owns the process-lifetime local
  protocol and reconnect view.

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
- Runtime must make the Agent task the Workspace opening owner.
- Runtime must close the Handle normally, while owner monitoring remains the
  fallback for task death or uncatchable termination.

## Architectural Invariants

- Every accepted run has one fresh opaque Runtime Run handle.
- A Run handle never exposes a bare Task, PID, monitor, Workspace Handle,
  cancellation reference, callback, or mutable cell through ordinary inspection.
- Runtime validates Run Request and trusted configuration before starting Agent.
- One temporary RunServer owns cancellation, event tracking, terminal gating,
  await delivery, and the Agent task monitor.
- The Agent task, not RunServer or the higher adapter caller, owns the Workspace Handle.
- RunServer starts Agent through `Task.Supervisor.async/3`, traps task exits, and
  never restarts it.
- Runtime starts Agent with `trap_exit: false`, and production Agent Runner never
  changes that flag. Under that invariant, the link prevents an abnormal RunServer
  exit from orphaning Agent; the monitor and trapped exit let RunServer observe an
  Agent crash without being taken down before conversion. Arbitrary trusted code
  that enables `trap_exit` inside the internal task boundary is unsupported.
- Workspace Access is an exact trusted mapping from `fs_read`, `fs_write`, and
  `process_exec`; Runtime never widens authority.
- Runtime opens Workspace before Agent emits `RunStarted`.
- Runtime confirms normal Workspace close or owner-down backend termination before
  publishing a terminal Run Event or returning a terminal from `await`.
- Agent remains the sole owner of ordinary successful, failed, interrupted, and
  budget terminal semantics.
- A valid buffered Agent terminal is the run's semantic linearization point unless
  Workspace close fails. If Agent exits after producing it, Runtime preserves that
  terminal once Workspace settlement is observed; a later cancellation or task
  DOWN does not replace it.
- Runtime may synthesize a terminal only for Runtime startup-after-acceptance,
  cleanup, cancellation, or unexpected-worker outcomes that Agent could not
  return itself.
- RunServer loss is the outer MVP failure boundary. The handle owner can detect it
  through the RunServer monitor and return `Runtime.Error{reason: :runtime_lost}`,
  but cannot reconstruct a Run Event, active Tool, output visibility, or buffered
  terminal state that died with RunServer.
- At most one terminal Run Event is exposed to the caller.
- Runtime never synthesizes `TurnCompleted` after a crash because exact attempt,
  call, and output counters may be unknown.
- A crash after accepted `ToolStarted` and before matching `ToolCompleted` is
  ambiguous, regardless of the advertised Tool side-effect class.
- A crash after visible text is an interruption, not an ordinary clean failure.
- Arbitrary crash reasons and exception data are never copied into public data.
- Terminal precedence is Workspace close failure, valid buffered Agent terminal,
  cancellation, unmatched Tool ambiguity, visible output interruption, then
  ordinary worker failure. Workspace close failure and cancellation retain bounded
  prior ambiguity details when present.
- Cancellation first sets persistent state and only then sends the matching
  mailbox message directly to the Agent task.
- Repeated cancellation is safe and starts no new operation.
- An `await` timeout does not cancel, kill, or detach the run.
- Await is owner-only, a timeout preserves the await right, and one successful
  await consumes it; a later await returns `:already_awaited`.
- Await accepts only `:infinity` or a non-negative integer and returns
  `:invalid_timeout` for malformed waiting policy.
- Runtime permits exactly one active MVP RunServer; a second start returns
  `runtime_busy` rather than opening another Handle.
- Runtime does not impose a false timeout around current synchronous Workspace
  initialization. Cancellable bounded Workspace open remains deferred.
- Event sinks are trusted synchronous callbacks that must return promptly. Runtime
  invokes each terminal event at most once and treats only return value `:ok` as
  accepted; it cannot guarantee exactly-once external side effects.
- Temporary RunServer, Agent task, and Workspace children use
  `restart: :temporary`.
- OTP never restarts or replays a side-effecting one-shot child.
- Agent semantic Provider retry remains the only in-run automatic retry.
- Application child order is Workspace Supervisor, TaskSupervisor, then Runtime
  Supervisor, producing reverse shutdown order Runtime, Task, Workspace.

## Confirmed MVP Decision Record

These decisions were confirmed against the completed lower components and Elixir
1.20 Task, TaskSupervisor, Supervisor, and DynamicSupervisor semantics. They match
the minimal architecture in `PLAN.md`, not the future persistent-daemon tree in
`README.md`.

| Concern | Confirmed MVP decision | Reason |
| --- | --- | --- |
| Lifecycle owner | One temporary `Synapse.Runtime.RunServer` GenServer | Cancellation, await, event gating, and crash conversion require an autonomous state owner |
| Agent execution | One linked TaskSupervisor `async/3` child with `restart: :temporary` and `shutdown: :brutal_kill` | Runner stays synchronous; link prevents orphaning and trapped exits permit conversion |
| Run lookup | Opaque handle returned directly to one trusted owner/awaiter | Runtime has no Registry; the API may add ephemeral lookup above it |
| Workspace owner | Agent task PID | Task death activates existing Workspace owner cleanup |
| Workspace supervision | Real MutationServers start under one DynamicSupervisor with `restart: :temporary` | Makes process ownership visible without replaying side effects |
| Lower workers | Remain private to Provider and Workspace | Their components already own monitors, timeouts, ports, and cleanup |
| Provider | Trusted Runtime configuration, default Tokamak | Model input cannot select arbitrary modules |
| Access | Exact CapabilitySet-to-Workspace Access mapping | Runtime must never widen host authority |
| Cancellation state | Shared persistent flag plus one matching reference/message | Lower operations may consume the mailbox message |
| Cancellation API | Idempotent and asynchronous | The terminal is observed through `await` |
| Await | Owner-only; timeout preserves the right; success consumes it once | Task result messages and opaque handle ownership stay deterministic |
| Absolute deadline | Agent computes Budget deadline; Runtime may supply an earlier monotonic deadline | Preserves one effective deadline through existing contexts |
| Inactivity | Provider and Workspace enforce their own configured inactivity | A second Runtime watchdog would race and duplicate ownership |
| Workspace readiness | Synchronous two-phase `ready -> accept/abort`, without an MVP open timeout | Current Workspace initialization is not cancellable while DynamicSupervisor waits for child init |
| Event delivery | Forward non-terminal events synchronously; retain one terminal until Workspace settlement | Callers must not see completion before cleanup |
| Event sink | Prompt-returning trusted callback; terminal invoked at most once | Blocking arbitrary callbacks cannot be preempted safely in-process |
| Crash tracking | RunServer stores only visible-output, active-Tool, Workspace, and terminal state | Allows autonomous conservative conversion without an unbounded mailbox |
| Terminal precedence | Workspace close failure, valid buffered Agent terminal, cancellation, active Tool, visible output, ordinary crash | Cleanup failure is visible while bounded prior ambiguity evidence is preserved |
| Crash after ToolStarted | `tool_ambiguous` and no replay | Side-effect outcome is not safely known |
| Crash after visible text | `RunInterrupted` with sanitized Runtime worker error | Partial output is not ordinary completion |
| Task restart | Never | Restart would replay Provider or Tool work |
| RunServer loss | Await returns typed Runtime Error `runtime_lost`; no Run Event guarantee | The outer lifecycle owner, sink, and crash state no longer exist |
| Concurrent runs | Reject a second active run with `runtime_busy` | Concurrent runs and cross-Handle same-root coordination are MVP non-goals |
| Synchronous convenience | No `Runtime.run/3` in MVP | Start/cancel/await ownership must remain explicit for owner-only await and delegated cancellation |
| Persistence | None | Run handle and events are in-memory MVP data |

### Why RunServer And Agent Task Are Separate

Agent Runner owns immutable conversation policy and blocks synchronously in
Provider or Tool work. RunServer owns mutable process-lifecycle policy and must
remain able to observe task exit, serialize events, retain one terminal, and send
the final result even when the handle owner is not currently calling `await`.
Combining both roles in one Task would make crash conversion demand-driven by the
awaiter and would lose the only process capable of publishing an abnormal
terminal when that Task dies.

RunServer therefore uses GenServer because it owns bounded mutable state and a
message protocol. Agent remains a plain function in a Task because its state is
already immutable function data. The Agent task is linked and monitored: the link
prevents RunServer death from orphaning Agent, while trapped task exits and the
monitor let RunServer convert Agent failure without being taken down by it.

Supervision does not imply replay. Both children are temporary, and Agent starts
exactly once. Provider and Workspace keep their existing private workers because
only those components know how to close the HTTP request, classify operation
inactivity, stop the owned command, and distinguish known from ambiguous effects.

## Confirmed Supervision Tree

```text
Synapse.Application
`-- Synapse.Supervisor                 :one_for_one
    |-- Synapse.Workspace.Supervisor   DynamicSupervisor
    |   `-- Workspace.MutationServer   temporary per real Handle
    |-- Synapse.TaskSupervisor         Task.Supervisor
    |   `-- Agent Runner Task          temporary, linked to RunServer
    `-- Synapse.Runtime.Supervisor     DynamicSupervisor, max_children: 1
        `-- Synapse.Runtime.RunServer  temporary per accepted run
```

Children are started in the order shown. OTP stops them in reverse order:
RunServer first, Agent tasks second, and Workspace owners last. RunServer shutdown
propagates through the Agent link; Workspace owner monitoring and its supervisor
remain available while active runs are terminating.

The tree deliberately does not add RunRegistry, EventRegistry, Store,
CapabilityPolicy, CredentialBroker, ExtensionManager, ProjectManager,
RunSupervisor, or TransportSupervisor. Those belong to the target daemon and
must not be created as empty placeholders.

## Confirmed Public Boundary

The MVP public functions and return shapes are:

```elixir
Synapse.Runtime.start_run(run_request, event_sink, options \\ [])
# => {:ok, runtime_run} | {:error, runtime_start_error}

Synapse.Runtime.cancel(runtime_run)
# => :ok | {:error, :invalid_run}

Synapse.Runtime.await(runtime_run, timeout \\ :infinity)
# => {:ok, Synapse.Agent.Result.t()}
#  | {:error, Synapse.Agent.Error.t()}
#  | {:error, Synapse.Runtime.Error.t()}
#  | {:error,
#     :await_timeout | :already_awaited | :not_owner | :invalid_run | :invalid_timeout}
```

`Runtime.run/3` is not part of the MVP. API RunSession retains the owner-only await
right while one deliberate trusted delegate may retain the same opaque handle only
to call `cancel/1`.

### Runtime Run Handle

The public value is opaque and ordinarily redacted. A possible internal shape is:

```elixir
%Synapse.Runtime.Run{
  id: run_id,
  owner: owner_pid,
  server: run_server_pid,
  task: agent_task_pid,
  run_ref: run_ref,
  cancel_ref: cancel_ref,
  cancellation: persistent_cell,
  await_state: persistent_cell
}
```

These fields are implementation authority, not stable public data. Callers may
use only Runtime functions. The owner restriction is an MVP mailbox-ownership
rule: `await` must run in the process that called `start_run`, while `cancel` may
be called by another trusted process holding the handle. RunServer sends one
terminal message to that owner after cleanup and event delivery; the await-state
cell distinguishes available, waiting, and consumed states without retaining a
completed coordinator process.

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
`cwd`, the Agent-task owner PID, validated limits, and exact mapped Access, then
calls `Workspace.open/1`. A trusted test opener may create a Fake Handle owned by
the same Agent task. Runtime still closes either Handle through
`Workspace.close/1`.

Callbacks, modules, limits, and deadlines are trusted application configuration.
They never enter Run Request, model context, events, errors, or ordinary
inspection. Production API configuration must use the default real Workspace
opener.

The current Workspace open path performs trusted local APFS initialization
synchronously. Runtime waits for it without a separate timeout because killing
the caller cannot cancel a DynamicSupervisor blocked in child initialization.
Bounded cancellable Workspace opening requires a later Workspace protocol change;
the MVP must document this limitation instead of claiming a false five-second
cleanup guarantee.

### Runtime Error

Failures before an active run is accepted use a small Runtime-owned error rather
than forging an Agent turn or Run Event. RunServer loss after acceptance uses the
same bounded type because Agent classification and Run Event state are no longer
available. Initial reasons are:

```text
invalid_run_request
invalid_runtime_options
runtime_unavailable
runtime_busy
workspace_open_failed
runtime_lost
```

The value carries a bounded sanitized message and optional run ID, but no root,
Handle, callback, process identity, exception, or raw Workspace error. After
acceptance, ordinary terminals use Agent Result/Error and Run Events;
`runtime_lost` is the explicit infrastructure exception.

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
  -> start temporary RunServer under Runtime Supervisor
  -> RunServer starts one linked temporary Agent task
  -> Agent task derives exact Workspace Access
  -> Agent task opens Workspace with itself as owner
  -> Agent task builds Agent Context
  -> synchronous ready handshake reports Handle or sanitized open failure
  -> RunServer accepts or aborts startup
  -> accepted Agent Runner begins and emits RunStarted
```

`start_run` blocks for current synchronous Workspace readiness, but it does not
wait for Provider or Tool work. Runner cannot start before RunServer sends the
accept message. If startup fails, no Run handle is returned, RunServer and Agent
task stop, and no Agent Run Event is forged.

### Normal Completion

```text
Agent returns Result or Error
  -> Agent task closes Workspace
  -> RunServer confirms Workspace owner DOWN
  -> RunServer validates matching buffered terminal Event
  -> RunServer invokes the retained terminal Event once
  -> RunServer sends terminal to handle owner and stops
  -> await consumes the terminal message once and confirms RunServer DOWN
  -> await returns terminal
```

If the terminal event sink fails, Runtime returns a structured event-sink failure
where possible but cannot guarantee delivery through the failed sink.

### Cancellation

```text
cancel(run)
  -> atomically mark persistent cancellation true
  -> send {:cancel, cancel_ref} directly to Agent task
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
Agent task exits without a valid terminal
  -> RunServer observes trapped EXIT and monitored DOWN
  -> read bounded owned lifecycle state
  -> preserve buffered terminal or classify cancellation / active Tool / output / crash
  -> wait for Workspace owner DOWN where observable
  -> publish one sanitized terminal Event if the sink remains available
  -> send one structured Agent Error to await owner and stop
```

Runtime never exposes the raw `DOWN` reason. It never assumes cleanup proves that
a daemonized descendant or hostile same-user process is gone.

If RunServer itself exits before sending the owner terminal, `await` rechecks its
mailbox for an already-sent terminal and otherwise returns sanitized Runtime Error
`runtime_lost`. The Agent link and Workspace owner monitor still drive cleanup,
but no remaining process has enough state to emit an honest Run Event.

## Event Rules

- Continue using the implemented `Synapse.Run.Event` union.
- Do not add a second public Runtime operation-event vocabulary for the MVP.
- Route Agent events synchronously through RunServer in source order.
- Treat the event sink as trusted, fallible, and required to return promptly.
- For TextDelta, set visible-output state only when the sink returns `:ok`.
- For ToolStarted, set active Tool only when the sink returns `:ok`.
- For ToolCompleted, clear active Tool when the known completion event reaches
  RunServer, even if downstream delivery then fails.
- Retain at most one terminal Agent event inside RunServer.
- Publish that terminal only after normal close succeeds or owner-down backend
  termination is observed.
- Store only bounded state required for crash conversion: visible-output flag,
  active Tool identity, Workspace owner, and terminal-seen state.
- Do not retain TextDelta content, Tool arguments, Tool Result content, commands,
  paths, or process output.
- Clear active Tool state only after the operation has a known ToolCompleted
  boundary.
- Never publish a second terminal after an accepted RunCompleted, RunFailed, or
  RunInterrupted.
- Never synthesize exact turn accounting after an abnormal exit.
- Invoke a terminal event through the sink at most once. A callback that performs
  an external side effect and then raises cannot be made exactly-once by Runtime.
- Runtime itself owns no sequence numbers, timestamps, persistence barriers,
  replay, or coalescing. The MVP API may add bounded ephemeral sequence and replay
  projections above this sink; durable forms remain post-MVP.

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
| RunServer dies after acceptance without sending terminal | Runtime Error / runtime_lost | None guaranteed |
| Agent returns Result | Agent Result after close | RunCompleted |
| Agent returns Error | Same Agent Error after close | RunFailed or RunInterrupted |
| Agent exits after one valid buffered terminal | Preserve buffered Agent terminal after Workspace settlement | Matching buffered terminal event |
| Workspace close fails after Agent terminal | internal / workspace_close_failed with bounded prior ambiguity evidence | RunFailed |
| Worker crash with no visible output or active Tool | internal / run_worker_crashed | RunFailed |
| Worker crash after visible model output | internal / run_worker_crashed | RunInterrupted |
| Worker crash with unmatched ToolStarted | tool / tool_ambiguous | RunFailed |
| Cancelled worker with no unmatched Tool | cancelled / run_cancelled | RunInterrupted |
| Cancelled worker with unmatched Tool | cancelled / run_cancelled with bounded ambiguity details | RunInterrupted |
| Event sink fails | internal / event_sink_failed where constructible | Terminal delivery not guaranteed |

Runtime may know less than Agent after a crash. Conservative uncertainty is
required; a nicer-looking but unjustified ordinary failure is incorrect.

## Phase 0: Confirm Runtime Decisions

### Decision Evidence

| Evidence | Confirmed consequence |
| --- | --- |
| `Agent.Runner.run/2` is synchronous and starts no process | Agent remains a function executed by one temporary Task |
| `Task.Supervisor.async/3` links and monitors a temporary task | RunServer traps exits, owns the Task result/monitor, and task restart stays forbidden |
| Task shutdown grace affects only a task trapping exits | Agent child uses explicit `shutdown: :brutal_kill`; cooperative cancel remains the normal path |
| Supervisors start children in list order and stop in reverse | Root order is Workspace, Task, Runtime so shutdown is Runtime, Task, Workspace |
| MutationServer already has `restart: :temporary` and monitors `OpenRequest.owner` | Agent task is the opening owner and owner death remains the cleanup fallback |
| DynamicSupervisor blocks while child initialization runs | MVP Workspace readiness has no false timeout; cancellable bounded open is deferred |
| Provider and Workspace already own workers, ports, inactivity, and cleanup | Runtime supervises outer lifecycle and passes policy without duplicate watchdogs |
| Run Events accept only Agent Result/Error terminals | Runtime adds two internal Agent Error reasons rather than a second terminal union |
| Event callbacks are synchronous and may run outside Agent task | RunServer serializes event state; the downstream sink must return promptly |

The current verified toolchain is Elixir 1.20.2 and Erlang/OTP 28.5.0.3. Phase 0
uses the documented Elixir 1.20 TaskSupervisor, Supervisor, and DynamicSupervisor
contracts; implementation tests must prove the selected behavior on the pinned
toolchain.

### Architecture

- [x] Re-read Runtime sections in `PLAN.md`, Agent Loop plan, Workspace plan, and
  Provider plan against current source.
- [x] Confirm one temporary RunServer owns lifecycle state and one linked temporary
  Task executes synchronous Agent Runner.
- [x] Confirm Runtime requires no Registry, persistent coordinator, daemon, or
  reconnectable client; a higher adapter may add process-lifetime lookup.
- [x] Confirm RunServer and real Workspace MutationServers each use a dedicated
  DynamicSupervisor with `restart: :temporary` children.
- [x] Confirm Provider and Workspace private workers remain component-owned.
- [x] Confirm root child start order Workspace, Task, Runtime and reverse shutdown.
- [x] Confirm `max_children: 1` rejects concurrent MVP runs with `runtime_busy`.
- [x] Confirm RunServer loss is the outer lifecycle boundary and returns typed
  `runtime_lost` without a Run Event guarantee.

### Public API

- [x] Confirm exact `start_run/3`, `cancel/1`, and `await/2` names and return shapes.
- [x] Defer `run/3`; the owner adapter retains the handle and may delegate explicit
  cancellation to one trusted process.
- [x] Confirm one owner/awaiter mailbox rule and `:already_awaited` terminal state.
- [x] Confirm cancellation may be called from another trusted process.
- [x] Confirm await timeout does not cancel and does not consume the await right.
- [x] Confirm malformed await timeout returns `:invalid_timeout`.
- [x] Confirm synchronous two-phase Workspace readiness without a separate MVP
  timeout; bounded cancellable open is deferred honestly.
- [x] Confirm trusted Runtime options and deterministic Workspace opener seam.

### Terminal Semantics

- [x] Confirm terminal events are retained until normal close or owner-down backend
  termination is observed.
- [x] Confirm only `run_worker_crashed` and `workspace_close_failed` are added to
  Agent Error.
- [x] Confirm crash-after-output becomes interruption.
- [x] Confirm unmatched Tool crash becomes ambiguity.
- [x] Confirm terminal precedence: Workspace close failure, valid buffered Agent
  terminal, cancellation, unmatched Tool, visible output, ordinary crash.
- [x] Confirm Workspace close failure preserves bounded prior ambiguity evidence.
- [x] Confirm Runtime never synthesizes TurnCompleted after a crash.
- [x] Confirm terminal sink invocation occurs at most once; failed delivery still
  returns a structured await terminal where possible.
- [x] Confirm prompt-returning sink is a trusted MVP contract and blocking sink
  isolation is deferred.

### Learning Gate

- [x] Explain why Runtime is not the Agent Loop.
- [x] Explain why RunServer is a GenServer while Agent remains a Task function.
- [x] Explain why supervising a Task does not justify restarting it.
- [x] Explain why lower operation workers remain under Provider/Workspace
  ownership.
- [x] Explain why Workspace settlement must precede public terminal completion.
- [x] Record every amended decision in this document before implementation.

### Phase Complete When

- [x] The public API, process tree, ownership, cancellation, terminal, and crash
  decisions are explicit.
- [x] No unresolved decision would change Runtime's process topology or public
  contract.

## Phase 1: Implement Runtime Contracts

### Code

- [x] Create `Synapse.Runtime` public facade and shared result types.
- [x] Create opaque `Synapse.Runtime.Run` handle.
- [x] Create bounded `Synapse.Runtime.Error` for start failures and accepted-run
  `runtime_lost` infrastructure failure.
- [x] Define bounded RunServer state, cancellation cell values, await states, and
  internal ready/accept/abort/terminal messages.
- [x] Add minimum Runtime-owned reasons to `Synapse.Agent.Error`.
- [x] Validate trusted Runtime options without starting a process.
- [x] Validate Provider module through the existing behaviour contract.
- [x] Validate Workspace and Tool limits together.
- [x] Validate optional monotonic deadline and retry-delay callback.
- [x] Add redacted Inspect implementations for all authority-bearing contracts.

### Tests

- [x] Valid default configuration.
- [x] Valid trusted Fake Provider and Workspace opener configuration.
- [x] Invalid Request, Provider module, sink, deadline, limits, opener, and retry
  delay.
- [x] Unknown option rejection.
- [x] Run and configuration inspection expose no PID, Task, root, callback,
  reference, Handle, prompt, or secret.
- [x] Runtime start errors contain no raw Workspace error or path.
- [x] Runtime-lost error contains no dead coordinator reason or stale lifecycle
  state.
- [x] New Agent Error reasons remain bounded and allowlisted.

### Documentation And Learning

- [x] Document who creates, owns, and consumes every Runtime contract.
- [x] Explain why Run handle is opaque.
- [x] Explain why Runtime start errors are distinct from accepted-run terminals.
- [x] Explain trusted injection versus model-controlled input.

### Phase Complete When

- [x] Contracts compile with warnings as errors.
- [x] Contract and inspection tests pass.
- [x] No Task, Workspace, Provider, or timer starts in contract constructors.
- [x] LSP hover explains every public field and return shape.

## Phase 2: Build Application Supervision

### Application Tree

- [x] Start named `Synapse.Workspace.Supervisor` as a DynamicSupervisor.
- [x] Start named `Synapse.TaskSupervisor` as a Task.Supervisor.
- [x] Start named `Synapse.Runtime.Supervisor` as a DynamicSupervisor with
  `max_children: 1`.
- [x] Keep root strategy `:one_for_one`.
- [x] Start Workspace, Task, and Runtime supervisors in that exact order.
- [x] Document root-child restart and shutdown policies.

### RunServer Integration

- [x] Create temporary `Synapse.Runtime.RunServer` child specification.
- [x] Trap linked Agent-task exits and monitor the same Task result.
- [x] Start Agent with `Task.Supervisor.async/3`, `shutdown: :brutal_kill`, and
  temporary restart policy.
- [x] Ensure abnormal RunServer exit propagates through the link to Agent.
- [x] Reject a second active RunServer as sanitized `runtime_busy`.

### Workspace Integration

- [x] Start real MutationServer through Workspace Supervisor.
- [x] Retain `restart: :temporary`.
- [x] Retain opening-owner monitoring.
- [x] Keep Fake Workspace independently owner-monitored for deterministic tests.
- [x] Preserve existing `Workspace.open/1` and opaque Handle facade.
- [x] Return structured unavailable error if Workspace Supervisor is absent.

### Tests

- [x] Exact named application children and child types.
- [x] Root supervisor restart does not change child policy.
- [x] RunServer is a temporary Runtime Supervisor child and never restarts.
- [x] Agent task is linked, monitored, temporary, and uses brutal shutdown.
- [x] A second active run is rejected before another Workspace opens.
- [x] Real Workspace opens as a DynamicSupervisor child.
- [x] Explicit close removes the temporary child.
- [x] Opening-owner death removes the temporary child.
- [x] Abnormal MutationServer exit is not restarted.
- [x] Application stop terminates RunServer, then Agent tasks, then Workspace
  supervisor.

### Documentation And Learning

- [x] Explain Supervisor versus DynamicSupervisor versus TaskSupervisor.
- [x] Explain permanent infrastructure children versus temporary side-effecting
  children.
- [x] Add the exact MVP supervision diagram.
- [x] Document why empty future-daemon children are not added.

### Phase Complete When

- [x] Application starts and stops cleanly with the three infrastructure children.
- [x] Temporary RunServer and Agent children never restart.
- [x] Temporary Workspace owners never restart.
- [x] Existing Workspace tests remain green.
- [x] Supervision tree is understandable through ExDoc.

## Phase 3: Start One Runtime-Owned Run

### Start Path

- [x] Revalidate Run Request and Runtime options.
- [x] Allocate one fresh cancellation reference and persistent state cell.
- [x] Start one temporary RunServer through Runtime Supervisor.
- [x] Have RunServer start one linked temporary Agent task through TaskSupervisor.
- [x] Derive exact Workspace Access from Run capabilities.
- [x] Open Workspace with the Agent task as owner.
- [x] Build and validate Agent Context before reporting ready.
- [x] Complete synchronous `ready -> accept/abort` startup before returning Run
  handle.
- [x] Do not claim or implement a Runtime Workspace-open timeout in the MVP.
- [x] Map Workspace-open failure to sanitized Runtime start error.
- [x] Pass Provider, Handle, instructions, sink, cancellation, deadline, limits,
  activity seams, and retry policy through Agent Context.
- [x] Prevent Runner from emitting RunStarted before RunServer accepts startup.
- [x] Call Agent Runner exactly once.

### Authority

- [x] Map `fs_read` only to Workspace `read`.
- [x] Map `fs_write` only to Workspace `write`.
- [x] Map `process_exec` only to Workspace `exec`.
- [x] Never derive Provider, capabilities, limits, callbacks, or deadline from
  prompt or model output.
- [x] Ensure Tool limits cannot exceed Workspace ceilings.
- [x] Keep API key lookup inside Provider transport.

### Tests

- [x] Start a text-only Fake run and receive an opaque handle.
- [x] Exact Workspace owner is the Agent task, not RunServer, test, or API process.
- [x] RunServer owns task monitor, sink, lifecycle tracking, and await delivery.
- [x] Exact Access mapping for all capability combinations.
- [x] Agent receives exact trusted Context values.
- [x] Workspace-open failure starts no Provider turn.
- [x] Start caller death during readiness triggers abort and eventual owner cleanup.
- [x] Agent Task child spec is temporary with brutal shutdown.
- [x] Distinct runs receive distinct references and task identities.

### Documentation And Learning

- [x] Trace Request cwd into Workspace OpenRequest without calling it canonical
  before Workspace validates it.
- [x] Trace capabilities into Handle Access and per-operation reduction.
- [x] Explain why Agent receives a Handle but Run Request does not.
- [x] Explain current synchronous Workspace-open limitation.
- [x] Add start-handshake sequence diagram.

### Startup Handshake

```text
Caller          Runtime          RunServer         Agent Task        Workspace
  |                |                 |                  |                |
  | start_run      |                 |                  |                |
  |--------------->| validate        |                  |                |
  |                | allocate refs   |                  |                |
  |                | start---------->| monitor caller   |                |
  |                |                 | async linked---->| derive Access  |
  |                |                 |                  | OpenRequest    |
  |                |                 |                  | owner=self     |
  |                |                 |                  | open---------->|
  |                |                 |                  |<------Handle---|
  |                |                 |                  | Context.new    |
  |                |                 |<------ready------|                |
  |                |                 | accept---------->|                |
  |                |<------started---|                  | Runner.run     |
  |<----Run---------|                 |                  | exactly once   |
```

Request `cwd` remains uncanonicalized input until Workspace opens it. Capabilities
map independently to Handle `read`, `write`, and `exec`; the Request never carries
the resulting Handle. On readiness failure, Agent sends only a fixed reason and an
optional backend PID. RunServer sends `abort`, waits for both Agent-task DOWN and
backend DOWN when observable, then returns the sanitized start error. Raw opener,
Workspace, close, and process-exit terms never cross the boundary. Caller death
during the synchronous open follows the same abort and settlement path. There is
no Runtime Workspace-open timeout in the MVP.

### Phase Complete When

- [x] One Fake text run starts only through public Runtime.
- [x] Runtime coordinates Workspace open while Agent task owns the Handle.
- [x] No startup failure leaks an owned process or Handle.
- [x] Runtime imports no host-operation or Provider wire modules.

## Phase 4: Await And Publish One Terminal

### Await

- [x] Receive RunServer terminal message through the opaque Run handle.
- [x] Validate returned Agent Result/Error before exposing it.
- [x] Restrict await to the handle owner for the MVP.
- [x] Monitor RunServer while waiting and recheck a queued terminal before
  classifying coordinator DOWN.
- [x] Return typed `runtime_lost` when RunServer dies without a queued terminal.
- [x] Confirm RunServer DOWN after receiving terminal before returning to caller.
- [x] Transition shared await state from available to waiting to consumed.
- [x] Reject a second successful await as `:already_awaited`.
- [x] Return await timeout without sending cancellation or killing the task.
- [x] Restore the available await state after timeout.
- [x] Allow a later await after timeout.

### Terminal Gate

- [x] Route non-terminal Agent events synchronously through RunServer.
- [x] Require downstream event sink callbacks to return promptly.
- [x] Track accepted visible output and active Tool transitions without retaining
  model content.
- [x] Retain at most one terminal Agent event in RunServer.
- [x] Validate terminal event and returned tuple agree on run ID and outcome.
- [x] Close Workspace in every normal Agent terminal path.
- [x] Monitor Workspace owner and publish retained terminal only after successful
  close or owner-down backend termination.
- [x] Convert close failure to one sanitized Runtime terminal.
- [x] Never expose the earlier Agent terminal after close failure.
- [x] Preserve only bounded prior ambiguity correlation in close-failure details.
- [x] Invoke the external terminal event at most once and treat only `:ok` as
  acceptance.
- [x] Send terminal to await owner and stop RunServer after Agent and Workspace
  resources settle.

### Tests

- [x] Successful result: close precedes RunCompleted and await return.
- [x] Agent failure: close precedes RunFailed and await return.
- [x] Agent interruption: close precedes RunInterrupted and await return.
- [x] Await timeout leaves task alive and later await succeeds.
- [x] Second await and non-owner await are rejected.
- [x] Await owner death does not cancel Agent or prevent autonomous cleanup/event
  publication.
- [x] Mismatched or missing Agent terminal is a Runtime contract failure.
- [x] Workspace close failure overrides buffered completion without two terminals.
- [x] RunServer loss returns Runtime Error and makes no synthetic Run Event claim.
- [x] Event sink failure never leaks a Workspace owner.

### Documentation And Learning

- [x] Explain task result versus Run Event terminal.
- [x] Explain why RunServer temporarily buffers one terminal.
- [x] Explain why await timeout differs from run deadline and cancellation.
- [x] Explain at-most-once sink invocation versus exactly-once external effect.
- [x] Add normal completion and cleanup sequence diagram.

### Terminal And Await Semantics

Agent Runner synchronously sends one terminal Run Event before returning its
Result/Error tuple. RunServer buffers the event wrapper because only it records
`RunCompleted` versus `RunFailed` versus `RunInterrupted`; the Task result supplies
the independently validated payload. Runtime requires exact run ID, payload, and
failed-versus-interrupted agreement before preserving that terminal.

```text
Agent Task       Workspace        RunServer          Event sink        Await owner
    | Runner terminal |               |                   |                 |
    |-------------------------------> | buffer            |                 |
    | Runner returns  |               |                   |                 |
    | close---------->|               |                   |                 |
    |<-----settled----|               |                   |                 |
    | Task result/DOWN--------------->| validate/gate     |                 |
    |                                 | terminal--------->| at most once    |
    |                                 |<---------:ok------|                 |
    |                                 | terminal message------------------->|
    |                                 | stop              |                 |
    |                                 |--------------------------------DOWN>|
    |                                 |                   |       return terminal
```

Close failure overrides the buffered terminal only after owner-down backend
settlement and retains at most confirmed bounded ambiguity correlation. A failed
terminal callback is never retried: it may already have performed its external
effect before raising, so Runtime guarantees at-most-one invocation, not
exactly-once external behavior.

Await timeout is only a caller receive policy. It neither changes the aggregate
run deadline nor sends cancellation. CAS restores the available await right, and
a terminal removed while waiting for RunServer DOWN is requeued before timeout is
returned. A valid terminal or `runtime_lost` consumes the right permanently.

### Phase Complete When

- [x] Every accepted ordinary path publishes at most one terminal.
- [x] No caller observes RunCompleted before Workspace closure.
- [x] Await never exposes Task exit tuples or Workspace errors directly.
- [x] Repeated waiting behavior is explicit and tested.

## Phase 5: Propagate Persistent Cancellation

### Cancellation Control

- [x] Store cancellation in a process-independent persistent cell.
- [x] Mark the cell before sending the mailbox message.
- [x] Send only `{:cancel, cancel_ref}` directly to the Agent task PID retained in
  the opaque handle.
- [x] Make cancellation idempotent before, during, and after terminal completion.
- [x] Permit trusted non-owner processes to call cancel.
- [x] Keep cancel non-blocking; await owns terminal observation.

### Lower-Layer Propagation

- [x] Agent cancellation probe reads the persistent cell.
- [x] Agent passes the exact reference into every Provider and Tool context.
- [x] Provider cancellation stops its owned request worker.
- [x] Workspace cancellation stops or classifies the active operation according to
  existing semantics.
- [x] Agent starts no later Provider or Tool after cancellation.
- [x] Runtime closes Workspace before publishing RunInterrupted.

### Tests

- [x] Cancellation before first Provider attempt.
- [x] Cancellation during Fake Provider operation.
- [x] Cancellation during Provider retry delay.
- [x] Cancellation during known-not-applied Tool operation.
- [x] Cancellation during ambiguous Tool operation.
- [x] Cancellation during a Real long-running command in a temporary Workspace.
- [x] Persistent probe remains true after lower layer consumes mailbox message.
- [x] Cancel-versus-natural-completion race emits one terminal.
- [x] Repeated and post-terminal cancel calls are harmless.
- [x] Unrelated and mismatched cancellation messages are ignored.

### Documentation And Learning

- [x] Explain mailbox cancellation versus persistent cancellation state.
- [x] Explain cancellation request versus confirmed cleanup.
- [x] Explain why cancellation does not imply not-applied Tool outcome.
- [x] Add end-to-end cancellation sequence diagram.

`Runtime.cancel/1` first changes the process-independent atomics cell from zero to
one, then sends the exact `{:cancel, cancel_ref}` message to the retained Agent task.
The message wakes a matching receive in an active Provider, retry delay, or Workspace
operation. The persistent cell remains set after that message has been consumed, so
the Agent's later checkpoints still prevent another Provider or Tool operation.
Unrelated messages and cancellation messages carrying another reference have no
cancellation authority.

Cancellation is a request, not cleanup confirmation. `cancel/1` therefore returns
immediately, while `await/2` returns the structured terminal only after Agent and
Workspace settlement. A cancellation arriving after a valid Agent terminal was
buffered does not replace that terminal. Likewise, cancellation cannot prove that a
Tool side effect was not applied: known-not-applied Workspace results remain known,
while an operation that may have started preserves bounded ambiguity evidence.

```text
trusted caller        Runtime handle       Agent task        active operation
      |                      |                  |                    |
      | cancel(run)          |                  |                    |
      |--------------------->| CAS cell 0 -> 1 |                    |
      |                      |----------------->| {:cancel, ref}     |
      |<---------------------| :ok              |------------------->|
      |                      |                  | classify/clean up  |
      | await(run)           |                  |<-------------------|
      |--------------------->|                  | close Workspace    |
      |                      | terminal after settlement             |
      |<---------------------|                  |                    |
```

### Phase Complete When

- [x] Cancellation reaches every active production operation through existing
  contracts.
- [x] No later operation starts after cancellation.
- [x] Known and ambiguous Tool outcomes remain distinguishable.
- [x] No cancelled test leaves a Runtime-owned process running.

## Phase 6: Convert Worker Crashes Conservatively

### Bounded Lifecycle Tracking

- [x] Track whether any user-visible model output was accepted.
- [x] Track only the current accepted ToolStarted identity.
- [x] Clear active Tool when matching ToolCompleted reaches RunServer.
- [x] Track whether an external terminal was accepted.
- [x] Retain Workspace owner identity until backend DOWN confirms settlement.
- [x] Bound RunServer state by fixed fields and Agent Budget, not text-delta
  count/content.

### Crash Conversion

- [x] Catch ordinary exceptions, throws, and exits around Runner and cleanup.
- [x] Trap linked Agent exits and monitor Agent for uncatchable abnormal exits.
- [x] Sanitize every crash without inspecting arbitrary reason content publicly.
- [x] Apply exact precedence: Workspace close failure, valid buffered Agent
  terminal, cancellation, unmatched Tool, visible output, ordinary crash.
- [x] Convert no-output/no-Tool crash to `run_worker_crashed` and RunFailed.
- [x] Convert crash after visible output to RunInterrupted.
- [x] Convert unmatched ToolStarted to `tool_ambiguous` and stop.
- [x] If cancellation was set, preserve run_cancelled and bounded ambiguity details.
- [x] Emit no TurnCompleted with invented counters.
- [x] Never restart the crashed task.
- [x] Never retry Provider, Tool, or Workspace work after crash.

### Tests

- [x] Inject Provider raise, throw, exit, and malformed worker termination.
- [x] Crash before RunStarted.
- [x] Crash after TurnStarted with no output.
- [x] Crash after first accepted TextDelta.
- [x] Crash after ToolStarted before Workspace invocation.
- [x] Crash during a Tool with unknown side-effect outcome.
- [x] Crash after ToolCompleted and before next turn.
- [x] Crash after buffered terminal and before return preserves that terminal only
  after Workspace settlement.
- [x] Forced uncatchable Agent kill uses RunServer-owned state.
- [x] Abnormal RunServer kill terminates linked Agent and triggers Workspace owner
  cleanup without task restart.
- [x] Await converts RunServer loss to `runtime_lost` without exposing exit reason
  or inventing Run Event state.
- [x] Raw exception, exit reason, stacktrace, prompt, path, command, and output are
  absent from terminal data and captured logs.
- [x] A counter/barrier proves temporary task is not restarted.

### Documentation And Learning

- [x] Explain link, trapped exit, and monitor behavior between RunServer and Agent
  task.
- [x] Explain why supervision does not imply restart.
- [x] Explain why missing ToolCompleted means ambiguity.
- [x] Explain which crashes Runtime can catch and which only a monitor observes.
- [x] Add crash-classification diagram.

RunServer traps exits so a linked Agent failure cannot kill the process that owns
terminal classification, and it separately monitors the Agent so even uncatchable
termination produces a deterministic `DOWN`. The Agent wrapper catches ordinary
raise, throw, and exit values before they reach Task logging; `:kill` cannot be
caught and is observed only through the monitor. No arbitrary reason is inspected
or copied into public data.

Supervision defines ownership, not replay policy. Both RunServer and its Agent task
are temporary children, and the Task has brutal supervisor shutdown. A failure is
converted once from retained state; neither child, Provider attempt, Tool call, nor
Workspace operation is restarted. A `ToolStarted` without its exact matching
`ToolCompleted` remains active because Runtime cannot know whether the side effect
began, so fallback reports `tool_ambiguous` rather than inventing a not-applied
result.

```text
Agent settles or DOWN
        |
        v
Workspace close failed? ---- yes ---> RunFailed(workspace_close_failed)
        | no
valid buffered terminal? ---- yes ---> preserve Agent terminal
        | no
cancellation set? ----------- yes ---> RunInterrupted(run_cancelled)
        | no
active ToolStarted? --------- yes ---> RunFailed(tool_ambiguous)
        | no
visible output accepted? ---- yes ---> RunInterrupted(run_worker_crashed)
        | no
        +---------------------------> RunFailed(run_worker_crashed)
```

### Phase Complete When

- [x] Every injected worker exit returns one sanitized structured terminal.
- [x] No crash path replays an operation.
- [x] Uncertain side effects are never mislabeled not-applied.
- [x] No raw BEAM failure term crosses Runtime's public boundary.

## Phase 7: Integrate Deadlines, Inactivity, And Application Shutdown

### Deadline Wiring

- [x] Preserve Run Budget as Agent's aggregate wall-time policy.
- [x] Accept only an optional earlier absolute monotonic Runtime deadline.
- [x] Pass that deadline through Agent Context without wall-clock conversion.
- [x] Confirm Agent chooses the earlier Budget/Runtime deadline.
- [x] Confirm the same effective deadline reaches Provider and Workspace contexts.
- [x] Start no operation after deadline expiration.

### Inactivity Ownership

- [x] Confirm Provider inactivity comes from Run Budget through StreamContext.
- [x] Confirm Tool inactivity lowers Tool/Workspace process policy.
- [x] Do not create a second Runtime operation timer.
- [x] Use activity sinks only for bounded observation or future telemetry seams.
- [x] Document why meaningful activity is component-specific.

### Application Shutdown

- [x] Confirm Runtime Supervisor stops RunServer before TaskSupervisor and
  Workspace Supervisor.
- [x] Confirm RunServer shutdown link stops Agent before Workspace Supervisor.
- [x] Confirm Agent-task death triggers Workspace owner cleanup.
- [x] Confirm Provider watchdog stops an owned HTTP request when coordinator dies.
- [x] Confirm Workspace cleanup stops the owned direct command and private runtime
  environment under documented limits.
- [x] Preserve explicit limitation for daemonized descendants.

### Tests

- [x] Already elapsed Runtime deadline starts no Provider operation.
- [x] Earlier Runtime deadline beats Budget deadline.
- [x] Provider inactivity returns one interrupted terminal.
- [x] Process inactivity returns known or ambiguous terminal according to outcome.
- [x] Application stop during Fake Provider leaves no script owner.
- [x] Application stop during Real command leaves no owned direct command.
- [x] Application stop during Workspace mutation does not restart mutation owner.
- [x] Application shutdown makes no terminal-event guarantee after infrastructure
  teardown begins.
- [x] All deadline tests use monotonic time and deterministic barriers where
  possible.

### Documentation And Learning

- [x] Explain aggregate deadline, operation inactivity, operation timeout, await
  timeout, and supervisor shutdown separately.
- [x] Explain why process existence is not meaningful activity.
- [x] Explain component-owned timeout versus Runtime-owned lifetime.
- [x] State exact cleanup proof and descendant limitations.

The Agent's aggregate wall-time deadline is the earlier of monotonic
`started_at + Budget.max_wall_time_ms` and Runtime's optional absolute monotonic
deadline. Agent checks that boundary before starting later work and passes the same
effective value to Provider and Tool/Workspace contexts. Runtime performs no
wall-clock conversion and starts no competing operation timer.

Provider inactivity, process inactivity, process timeout, await timeout, and
application shutdown are different policies. Provider inactivity measures
Provider-owned byte/event progress. Process inactivity measures accepted command
output or another Workspace-defined activity signal. Process timeout bounds one
command regardless of activity. Await timeout bounds only the caller's receive and
does not stop the run. Application shutdown is an ownership teardown, not a run
terminal policy, and makes no Run Event guarantee after RunServer disappears.

A live process is not proof of meaningful progress: a socket worker can remain
alive without bytes, and a command can remain alive without output. Tokamak and
Workspace therefore own watchdogs where activity has component-specific meaning.
Runtime owns only the outer lifetime and propagates Budget/deadline values and
shutdown through links and monitors.

```text
application stop
      |
      v
Runtime Supervisor stops RunServer
      |
      +-- link terminates Agent task
              |
              +-- Provider watchdog terminates owned HTTP worker
              `-- Workspace owner monitor begins operation cleanup
      |
TaskSupervisor stops remaining tasks
      |
Workspace Supervisor stops remaining temporary owners
```

Tests compose those ownership boundaries: isolated root shutdown removes the
RunServer, Agent, Fake Provider script owner, and Fake Workspace owner; Tokamak
coordinator-death tests remove its request worker; Real Workspace owner-death tests
confirm its MuonTrap helper, owned direct command, and private runtime environment
are gone; mutation-owner tests prove temporary children are not restarted. This is
direct-owner cleanup, not complete process-tree containment. A descendant that
daemonizes, reparents, or starts a new session may escape on platforms without a
stronger cgroup/job-object policy.

### Phase Complete When

- [x] A hung production Provider request or command cannot block indefinitely.
- [x] Runtime adds no competing lower-operation timeout.
- [x] Application shutdown leaves no owned direct operation in tests.
- [x] Deadline and shutdown semantics are understandable from ExDoc.

## Phase 8: Deterministic And Real Acceptance

### Deterministic Fake Scenario

- [x] Start through public Runtime with Fake Provider and Fake Workspace.
- [x] Complete `read -> write -> bash -> final text` in source order.
- [x] Assert exact Run Events and terminal result.
- [x] Assert Workspace opened under Agent-task owner and settled before terminal.
- [x] Assert Provider and Workspace scripts are exhausted.
- [x] Assert Runtime Supervisor has no RunServer and TaskSupervisor has no Agent
  child.
- [x] Assert no network or host side effect occurred.

### Failure Matrix

- [x] Workspace-open failure.
- [x] Agent ordinary failure.
- [x] Provider retry then success.
- [x] Provider interruption after output.
- [x] Tool ambiguity.
- [x] Cancellation at each safe boundary.
- [x] Worker crash at each tracked boundary.
- [x] Workspace-close failure.
- [x] Await timeout followed by success and followed by cancellation.
- [x] Application shutdown with active work.

### Temporary Real Workspace

- [x] Open a synthetic temporary root only through Runtime.
- [x] Run Fake Provider through real Read, Write/Edit, and Bash verification.
- [x] Cancel one long-running harmless command.
- [x] Verify file and process outcomes independently of model text.
- [x] Confirm no RunServer, Agent task, MutationServer, private process environment,
  MuonTrap helper, or owned direct command remains.
- [x] Preserve documented descendant-process limitation.

### Boundary Audits

- [x] Runtime calls Workspace only for open/close, never file/process operations.
- [x] Runtime calls Agent only through Runner boundary.
- [x] Runtime imports no Req, Finch, SSE, credential, File, System, Port, MuonTrap,
  Tool adapter, or terminal module.
- [x] Provider, Agent, Tool, and Workspace import no Runtime module.
- [x] Deterministic tests require no Tokamak key.
- [x] Real tests touch only their own temporary roots.

`test/runtime_acceptance_test.exs` is the public boundary proof. Its Fake scenario
uses a non-existent synthetic root and an observing Fake backend: all three
Workspace entries and both Provider turns are consumed, exact Run Events are
published, close observes zero remaining operations, and no host root is created.
Its Real scenarios create random temporary roots, independently inspect resulting
files and command PIDs, and retain the MutationServer and private process-environment
identities long enough to prove they have terminated before acceptance returns.

The successful Real scenario performs Read, revision-checked Write, and Bash
verification before final text. The cancellation scenario starts a harmless
long-running unknown-footprint Bash command, records its direct PID, cancels through
the Runtime handle, preserves ambiguous Tool evidence, starts no second Provider
turn, and confirms the direct process, Workspace owner, and private environment are
gone. Existing focused Workspace tests prove the MuonTrap helper cleanup beneath
that same owner-death/cancellation contract. As elsewhere, deliberately daemonized,
reparented, or new-session descendants remain outside the portable guarantee.

The failure matrix is composed from the public Runtime start, await, cancellation,
crash, deadline, shutdown, and acceptance suites. Every row terminates through the
same bounded Agent Result/Error or pre-acceptance Runtime Error contract; no row
replays a side effect or requires a credential.

### Phase Complete When

- [x] Full Fake coding loop completes only through public Runtime.
- [x] Real cancellation and cleanup proof passes in a temporary Workspace.
- [x] Every failure matrix row returns one bounded terminal.
- [x] No acceptance test uses a user checkout or live credential.

## Phase 9: Reliability And Security Hardening

### Races And Resource Ownership

- [x] Stress cancel versus completion.
- [x] Stress await timeout versus terminal delivery.
- [x] Stress crash versus Workspace owner cleanup.
- [x] Stress application stop versus active Provider and process work.
- [x] Confirm startup handshake messages cannot be confused across runs.
- [x] Confirm stale Run handles cannot control later runs.
- [x] Confirm task, Workspace, and coordinator monitors are dismissed and mailbox
  ownership messages flushed.
- [x] Confirm persistent cancellation cells become collectible after handle/task
  release.
- [x] Confirm bounded transition tracking cannot grow per text delta.

### Failure Injection

- [x] TaskSupervisor unavailable.
- [x] Workspace Supervisor unavailable.
- [x] Workspace opener returns malformed data, raises, throws, or exits.
- [x] Agent returns malformed terminal.
- [x] Workspace close returns malformed data, raises, throws, exits, or hangs within
  the documented test seam.
- [x] Event sink rejects, raises, throws, or exits.
- [x] Document rather than simulate indefinite blocking: prompt callback return is
  a trusted in-process contract, not a Runtime timeout boundary.
- [x] Cancellation caller races task death.
- [x] Await owner dies without cancelling the run.

### Security Review

- [x] Search Runtime structs for prompts, roots, credentials, headers, commands,
  output, Handles, callbacks, PIDs, Tasks, monitors, and references.
- [x] Search Runtime logs and errors for raw exception and exit inspection.
- [x] Test with recognizable synthetic secrets, paths, prompts, commands, and
  process output.
- [x] Confirm Runtime never widens capability or limit values.
- [x] Confirm child processes do not inherit Tokamak credentials through Runtime.
- [x] Confirm no model value selects module, callback, supervisor, process, or
  cancellation authority.
- [x] State that BEAM supervision, Workspace, and worktrees are not security
  sandboxes.

`test/runtime_phase9_test.exs` repeats cancellation/completion, await/terminal, and
task-kill/Workspace-cleanup races across changing scheduler order. Every iteration
observes one terminal, no replacement task, empty Runtime and Task supervisors, no
remaining Runtime monitor, and no queued Runtime message for the settled run. A
stale handle and stale startup message are then carried across a later run to prove
that fresh references, PIDs, and atomics cells isolate authority.

RunServer accepts 1,000 synchronous text deltas while retaining only the fixed
`visible_output?` bit; neither event history nor delta content enters State. A run
whose owner exits without exporting its handle leaves no Runtime child or global
storage. Runtime source contains no ETS, persistent-term, or Registry retention, so
the atomics resources become collectible with the final process/handle reference.

Failure injection separately removes TaskSupervisor and Workspace Supervisor,
normalizes malformed/raising/throwing/exiting close callbacks, and forces Agent
death while a trusted close callback is intentionally blocked. The latter is the
documented seam: Runtime has no callback watchdog, but owner-down Workspace
settlement still permits an already buffered valid terminal to win. Event-sink and
opener callback failures remain covered by the start/await suites.

An isolated application tree is stopped while a Real unknown-footprint command is
active. Reverse shutdown kills RunServer and Agent, then owner monitoring confirms
the MutationServer, private environment guard, and direct command are gone. This
proves direct ownership cleanup without extending the guarantee to escaped
descendants.

The security audit checks every Runtime struct field and source file. Request model
data cannot select Provider modules, openers, callbacks, supervisors, PIDs, or
cancellation references; those remain trusted Options or opaque Runtime authority.
Capabilities and Tool/Workspace limits are copied or lowered, never widened.
Runtime logs no raw reason, reads no process environment, and transfers no Tokamak
credential into Workspace. Workspace's minimal child environment and Provider's
credential ownership remain lower-component contracts. BEAM supervision,
Workspace path policy, and worktrees are reliability/cooperation mechanisms, not
OS security sandboxes.

### Phase Complete When

- [x] Race and failure-injection tests pass repeatedly.
- [x] No monitor, message, Task, Workspace owner, or persistent cell leaks.
- [x] Runtime-generated public data contains only bounded sanitized fields.
- [x] Restart and replay remain impossible by child policy.

## Phase 10: ExDoc And Comprehension Review

### Module Documentation

- [x] Every public Runtime module has `@moduledoc`.
- [x] Every public function has purpose-oriented `@doc` and accurate `@spec`.
- [x] Every public struct has `t()` and documented ownership.
- [x] Every supervisor child documents purpose, restart, and shutdown policy.
- [x] `@moduledoc false` and `@doc false` are absent unless explicitly justified.

### Required Explanations

- [x] Why Runner is synchronous inside a temporary Runtime Task.
- [x] Why temporary RunServer is a GenServer while Agent remains a Task function.
- [x] Why Runtime owns Workspace open/close but not Workspace operations.
- [x] Why Provider and Workspace private workers are not re-supervised.
- [x] Why cancellation needs both a message and persistent state.
- [x] Why terminal publication waits for cleanup.
- [x] Why temporary children never restart.
- [x] Why crash after ToolStarted is ambiguous.
- [x] Why await timeout does not cancel.
- [x] Why Runtime has no Registry, daemon, persistence, or reconnectable client;
  ephemeral reconnect may be projected by a higher API adapter.

### Required Diagrams And Examples

- [x] Application supervision tree.
- [x] RunServer-to-Agent link and monitor ownership.
- [x] Start and Workspace-open handshake.
- [x] Normal completion and terminal gate.
- [x] Cancellation propagation.
- [x] Crash and ambiguity conversion.
- [x] Text-only Fake Runtime example.
- [x] Start, cancel, and await example.

### Project Documentation

- [x] Add `docs/learning/RUNTIME.md` as the maintenance guide.
- [x] Add Runtime plan and guide to ExDoc groups.
- [x] Add Runtime modules to ExDoc module groups.
- [x] Update `README.md` implementation status.
- [x] Update `PLAN.md` Runtime summary and build checklist.
- [x] Mark README's persistent daemon tree and durable event vocabulary clearly as
  target/post-MVP architecture.
- [x] Correct stale ownership wording discovered in Provider, Workspace, Tool, or
  Agent plans.

### Comprehension Gate

- [x] Can the owner draw the exact running process tree for one run?
- [x] Can the owner identify every permanent and temporary child and restart
  policy?
- [x] Can the owner explain why RunServer is required for autonomous terminal
  publication when await owner dies?
- [x] Can the owner explain which process owns Workspace and Agent State?
- [x] Can the owner trace cancellation from public API to Provider HTTP shutdown
  and Workspace process cleanup?
- [x] Can the owner distinguish Budget deadline, inactivity, process timeout,
  await timeout, and application shutdown?
- [x] Can the owner explain why terminal Run Event is delayed until close?
- [x] Can the owner classify crashes before output, after output, and during a
  Tool?
- [x] Can the owner prove no side-effecting child is automatically replayed?
- [x] Can the owner test Runtime without Tokamak or host side effects?
- [x] Can the owner list every deferred daemon and recovery capability?

### Phase Complete When

- [x] `mix docs` succeeds without Runtime documentation warnings.
- [x] All examples and doctests pass.
- [x] The Runtime process and resource lifecycle can be understood without the
  original design conversation.
- [x] Known cleanup and concurrency limitations are explicit.

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
  runtime_acceptance_test.exs
  runtime_phase9_test.exs
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

- [x] Phases 0 through 10 are complete.
- [x] Runtime boundary matches `PLAN.md` and completed lower components.
- [x] Application starts TaskSupervisor and Workspace Supervisor in documented
  order with Runtime Supervisor.
- [x] Every run uses one temporary RunServer and one linked temporary Agent task.
- [x] Runtime owns Workspace open and close for every accepted run.
- [x] Workspace settlement is observed before terminal publication and await
  return.
- [x] Start, cancel, and await use one opaque redacted Run handle.
- [x] Await timeout never implies cancellation.
- [x] Cancellation remains observable after lower message consumption.
- [x] Provider and Workspace retain private operation-worker ownership.
- [x] Runtime adds no duplicate inactivity watchdog.
- [x] Worker crashes become bounded conservative terminals.
- [x] RunServer loss becomes bounded `runtime_lost` and explicitly cannot guarantee
  a Run Event.
- [x] Unmatched Tool execution becomes ambiguous and is never replayed.
- [x] No side-effecting temporary child automatically restarts.
- [x] Application shutdown leaves no Runtime-owned direct operation in tests.
- [x] Deterministic tests need no network, API key, user files, or scheduler sleeps.
- [x] Runtime imports no Provider wire, Tool adapter, host-operation, or terminal
  modules.
- [x] ExDoc explains supervision, ownership, cancellation, deadlines, events,
  cleanup, crashes, security, and deferred work.
- [x] The owner can maintain Runtime without the original AI conversation.

## Deferred Runtime Work

Do not add these before the MVP Runtime is complete:

- Persistent local daemon and Unix socket.
- Persistent RunCoordinator, durable per-run subtree, or durable reconnectable run
  owner.
- Runtime-owned Run/Event Registry, subscriptions, reconnect, replay, or snapshots;
  the MVP API may project bounded process-lifetime forms above Runtime.
- Durable event sequence numbers, timestamps, persistence barriers, or telemetry.
- SQLite sessions, attempts, work items, evidence, or crash recovery.
- Concurrent runs, same-root coordination across Handles, or run queues beyond
  the explicit one-active-run MVP limit.
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
