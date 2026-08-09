# Runtime Maintenance Guide

This guide explains the implemented single-run MVP Runtime. It is the maintenance
companion to [`PLAN-RUNTIME.md`](../plan/PLAN-RUNTIME.md), not a description of the
post-MVP daemon, durable event store, reconnectable client, or multi-run tree.

## Public Boundary

The supported lifecycle API is deliberately small:

```elixir
{:ok, run} = Synapse.Runtime.start_run(request, event_sink, options)
:ok = Synapse.Runtime.cancel(run)
terminal = Synapse.Runtime.await(run, :infinity)
```

`start_run/3` validates trusted configuration, starts one temporary run, waits for
Workspace readiness, and returns an opaque `Synapse.Runtime.Run`. It does not wait
for model completion. `cancel/1` is asynchronous and may be called by any trusted
process holding the handle. `await/2` is owner-only and consumes one terminal right.

The handle contains process and reference authority but redacts ordinary inspection.
It is not serializable, persistent, or an unforgeable boundary against arbitrary
code already running in the same BEAM VM.

## Running Process Tree

The application has three permanent infrastructure children in dependency order:

```text
Synapse.Supervisor                         permanent Supervisor
|-- Synapse.Workspace.Supervisor           permanent DynamicSupervisor
|   `-- Workspace.Real.MutationServer      temporary per Real Handle
|-- Synapse.TaskSupervisor                 permanent Task.Supervisor
|   `-- Agent task                         temporary per run, brutal shutdown
`-- Synapse.Runtime.Supervisor             permanent DynamicSupervisor, max 1
    `-- Runtime.RunServer                  temporary per run, never restarted
```

For one accepted run, RunServer starts exactly one linked and monitored Agent Task.
The Agent Task opens Workspace with itself as the opening owner. A Real Workspace
MutationServer monitors that Task. Provider and Workspace may start private workers
under their existing ownership contracts; Runtime does not re-supervise them.

OTP stops static children in reverse order. RunServer therefore stops before the
TaskSupervisor, and Workspace supervision remains available while Agent-owner death
triggers cleanup.

## Why RunServer Is A GenServer And Agent Is A Task

Agent Runner is one synchronous bounded function with one immutable State lineage
and one terminal return. It needs no independent query API, registry, subscription,
or long-lived mailbox, so Runtime executes it in a temporary Task.

RunServer must outlive the caller's current receive and react to multiple lifecycle
sources: startup messages, synchronous Run Events, linked exits, task results, task
`DOWN`, Workspace `DOWN`, sink outcomes, cancellation state, and owner delivery. A
GenServer serializes those transitions and can publish a terminal even if the
original handle owner exits after startup.

```text
                       link: failure ownership
RunServer <========================================> Agent Task
    |                                                   |
    `---------------- monitor: observed DOWN ---------->'
                                                        |
                                                        `-- owns Workspace Handle
```

RunServer traps linked exits so Agent failure does not destroy the state needed for
classification. The monitor observes uncatchable termination such as `:kill`.
Agent itself uses `trap_exit: false`, so abnormal RunServer death cannot orphan it.

## Ownership Table

| Resource or policy | Owner | Reason |
| --- | --- | --- |
| Run admission and opaque authority | Runtime | One active MVP run and fresh control references |
| Mutable lifecycle and terminal selection | RunServer | Serialized bounded state independent of await timing |
| Agent State, turns, retries, budgets | Agent Task / Runner | Synchronous immutable semantic loop |
| Workspace Handle and normal close | Agent Task | Owner death is the cleanup fallback |
| File/process operations | Workspace and Tool | Runtime must not interpret operation semantics |
| Provider request worker | Provider | Transport, inactivity, and HTTP cleanup are private |
| Run Event delivery | RunServer | Accepted progress and one cleanup-gated terminal |
| Cancellation cell and message authority | Runtime handle | Persistent observation plus active-operation wakeup |

Runtime calls Workspace only to open and close. Runner constructs reduced Tool
Contexts and Tool Executor invokes Workspace operations. This keeps path, revision,
mutation, process, and ambiguity semantics in the component that can classify them.

## Start And Workspace Handshake

Trusted Request, sink, and Options are normalized before children start. Runtime
allocates fresh run, cancellation, and await authority, then starts RunServer.

```text
caller          RunServer             Agent Task              Workspace
  | start_run      |                      |                       |
  |--------------->| start linked Task    |                       |
  |                 |--------------------->| derive exact Access   |
  |                 |                      | open(owner=self)      |
  |                 |                      |---------------------->|
  |                 |<-------- ready(Handle, task PID) -----------|
  |                 | validate and monitor backend                |
  |                 |-------- accept ------>|                     |
  |<----- opaque Run|                      Runner.run              |
```

The Task derives Workspace Access exactly from `fs_read`, `fs_write`, and
`process_exec`. Options can lower Tool and Workspace limits but cannot exceed hard
component ceilings. Request/model values cannot select Provider modules, callbacks,
supervisors, PIDs, or cancellation references.

If Workspace open fails, raises, throws, exits, or returns malformed data before
acceptance, Runtime returns a sanitized `Synapse.Runtime.Error` and starts no Agent
turn.

## Progress And Normal Completion

Runner emits events synchronously. RunServer validates run identity, exact active
Tool transitions, and terminal shape. It forwards accepted progress immediately but
buffers the terminal event.

```text
Agent Task             RunServer             Workspace backend        owner
    | terminal event      |                         |                    |
    |-------------------->| buffer only             |                    |
    | close Workspace     |                         |                    |
    |---------------------------------------------->|                    |
    | close result        |<--------------------- DOWN/settled ----------|
    | task result + DOWN  |                         |                    |
    |-------------------->| select terminal         |                    |
    |                     | invoke terminal sink once                    |
    |                     |---------------------------------------------->|
    |                     | terminal message                             |
    |                     |---------------------------------------------->|
```

Terminal publication waits for both Task and Workspace settlement. This prevents a
caller from observing completion while an owned mutation or direct process remains.
A sink callback is attempted at most once because it may have performed an external
effect before raising.

Workspace close failure overrides completion. Otherwise a valid buffered Agent
terminal is the semantic linearization point and survives a later task exit or
cancellation once owner-down Workspace cleanup is confirmed.

## Cancellation

Cancellation requires both persistent and mailbox state:

```text
trusted caller       Runtime handle          Agent Task          active lower layer
     | cancel(run)         |                     |                      |
     |-------------------->| CAS cell 0 -> 1     |                      |
     |                     |-------------------->| {:cancel, ref}       |
     |<--------------------| :ok                 |--------------------->|
     |                     |                     | consume message       |
     |                     |                     | later probe sees cell |
```

The matching message wakes a Provider request, retry wait, or Workspace operation.
That lower layer may consume it. The atomics cell remains set, so Runner checkpoints
still prevent a later Provider or Tool from starting. Repeated and post-terminal
calls are harmless and send no duplicate message.

Cancellation is a request, not cleanup confirmation. `cancel/1` returns immediately;
`await/2` observes the terminal only after settlement. Cancellation does not prove a
Tool was not applied. If ToolStarted lacks matching ToolCompleted, Runtime preserves
`outcome: unknown` ambiguity evidence.

## Crash Classification

RunServer retains fixed evidence rather than event history or content:

```text
Task and Workspace settled
        |
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
        `---------------------------> RunFailed(run_worker_crashed)
```

Ordinary raise, throw, and exit values are caught and discarded without logging raw
content. Uncatchable Agent death is observed by monitor. No crash path retries or
restarts Agent, Provider, Tool, or Workspace work.

Missing ToolCompleted is ambiguous because Runtime knows only that execution was
announced; it cannot know whether the side effect began or committed. Inventing a
not-applied result would make unsafe replay possible.

## Deadlines And Timeouts

These policies are intentionally distinct:

| Policy | Owner | Effect |
| --- | --- | --- |
| Optional Runtime deadline | Runtime Options / Agent State | Explicit absolute monotonic boundary; defaults to infinity |
| Provider inactivity | Provider | Bounds silence meaningful to transport streaming |
| Process inactivity | Workspace | Bounds accepted-output silence |
| Process timeout | Workspace | Bounds one command regardless of activity |
| Await timeout | Run owner | Stops only the current receive and restores await right |
| Supervisor shutdown | OTP ownership tree | Terminates owners; no terminal-event guarantee |

Agent passes Runtime's optional deadline directly to Provider and Tool/Workspace
contexts. Runtime creates no competing operation watchdog. Process existence alone
is not meaningful activity.

## Application Shutdown

```text
stop Synapse.Supervisor
  -> stop Runtime Supervisor and RunServer
  -> RunServer link terminates Agent Task
  -> Provider watchdog terminates request worker
  -> Workspace owner monitor starts operation cleanup
  -> stop remaining TaskSupervisor children
  -> stop remaining Workspace Supervisor children
```

After RunServer disappears, no Run Event can be guaranteed because its sink and
tracking state are gone. Cleanup relies on links, monitors, Provider watchdogs, and
Workspace ownership instead.

Real Workspace confirms its MuonTrap helper and owned direct command are down. It
does not guarantee termination of a descendant that daemonizes, reparents, or starts
a new session on platforms without stronger process-tree containment.

## Examples

The executable text-only Fake example is in `Synapse.Runtime` module documentation.
The minimal production-shaped sequence is:

```elixir
event_sink = fn event ->
  consume_bounded_event(event)
  :ok
end

with {:ok, run} <- Synapse.Runtime.start_run(request, event_sink, options) do
  # Any trusted holder may request cancellation.
  if cancellation_requested?(), do: Synapse.Runtime.cancel(run)

  case Synapse.Runtime.await(run, 30_000) do
    {:ok, result} -> {:completed, result}
    {:error, :await_timeout} -> {:still_running, run}
    {:error, error} -> {:failed_or_interrupted, error}
  end
end
```

An await timeout does not cancel. The owner may await again or request cancellation
and then await the cleanup-gated terminal.

For deterministic tests, supply `Synapse.Provider.Fake` and an opener that calls
`Synapse.Workspace.Fake.open/2` using the exact owner, limits, and Access from the
validated OpenRequest. No Tokamak credential or host root is required.

## Debugging Map

| Symptom | First inspection |
| --- | --- |
| `runtime_busy` | `DynamicSupervisor.which_children(Synapse.Runtime.Supervisor)` |
| Start never returns | Trusted Workspace opener and readiness owner |
| Progress stops | Synchronous event sink, Provider inactivity, active Workspace operation |
| Await times out | RunServer still alive; timeout does not imply failure |
| `runtime_lost` | RunServer died; no terminal Event reconstruction is possible |
| `tool_ambiguous` | Last accepted ToolStarted identity and missing ToolCompleted |
| Terminal delayed | Agent Task or Workspace backend has not settled |
| Application stop delayed | Trusted callback or lower cleanup still owns synchronous work |

Runtime intentionally stores no prompt, cwd, command, output, Workspace Handle,
exception, or event list in RunServer State. Public Error values use fixed messages
and bounded allowlisted details. Ordinary inspection of Options, Run, State, Message,
Result, and Error is redacted.

## Test Map

| Test file | Primary contract |
| --- | --- |
| `runtime_contracts_test.exs` | Options, Run, Error, State, Message, inspection |
| `runtime_supervision_test.exs` | Permanent/temporary tree, links, monitors, shutdown |
| `runtime_start_test.exs` | Validation, readiness, Access, one-run admission |
| `runtime_await_test.exs` | Terminal gate, precedence, sink and await behavior |
| `runtime_cancellation_test.exs` | Persistent/message cancellation and races |
| `runtime_crash_test.exs` | Caught and monitor-only worker failures |
| `runtime_deadline_test.exs` | Deadline and inactivity propagation |
| `runtime_acceptance_test.exs` | Exact Fake loop and temporary Real evidence |
| `runtime_phase9_test.exs` | Repeated races, stale authority, failure/security audit |
| `runtime_phase10_test.exs` | ExDoc, guide, examples, and comprehension surface |

## Security And Limitations

Runtime is a reliability and ownership boundary, not an OS security sandbox. BEAM
processes in one VM can inspect or affect one another if trusted code chooses to do
so. Workspace Access is cooperative application policy. A worktree separates Git
state but does not isolate filesystem, network, process, credential, CPU, or memory
authority.

Trusted in-process callbacks are synchronous contracts. Runtime sanitizes callbacks
that return, raise, throw, or exit, but does not time out an opener, event sink,
retry-delay callback, or Workspace close. External owner shutdown is the recovery
boundary for a callback that never returns.

Runtime does not copy Tokamak credentials into Agent Context or Workspace. Provider
owns credentials and its HTTP worker. Workspace builds a minimal command environment.
Neither guarantee protects against arbitrary trusted BEAM code or escaped process
descendants.

## Deferred Architecture

Runtime deliberately owns no persistent daemon, RunCoordinator, run/event Registry,
SQLite event store, sequence numbers, subscriptions, replay, or snapshots. The
higher local API adds bounded process-lifetime lookup, subscriptions, snapshots,
reconnect, and replay. Durable sequence identity, storage, recovery across
Manager/application restart, steering queues, concurrent runs, worktree workflow,
verification state, credential broker, extension manager, and distributed failover
remain deferred.

Those features must reuse the current opaque authority, temporary-child no-restart
policy, persistent cancellation, terminal cleanup gate, and conservative ambiguity
classification rather than silently replacing them.

## Comprehension Check

1. Which process owns Agent State and the Workspace Handle?
2. Why is Agent a Task while RunServer is a GenServer?
3. What does the RunServer link guarantee, and what does its monitor observe?
4. Why are Provider and Workspace private workers not re-supervised by Runtime?
5. Why does cancellation use both a message and an atomics cell?
6. Why can terminal publication occur only after Workspace settlement?
7. What terminal follows a crash before output, after output, and during a Tool?
8. Why does await timeout preserve the right to await again?
9. Which timeout policy owns Provider silence and process silence?
10. Why can no temporary side-effecting child use automatic restart?
11. Which daemon, persistence, and durable reconnect capabilities remain deferred?

Answers:

1. The temporary Agent Task owns both immutable Agent State and the Workspace Handle.
2. Agent has one synchronous computation; RunServer serializes independent lifecycle messages.
3. The link prevents orphaning on RunServer death; the monitor reports Agent termination.
4. Their components already own transport and operation cleanup semantics.
5. The message wakes active work; the cell remains observable after message consumption.
6. Completion must not be visible while an owned mutation or direct command remains.
7. Failed `run_worker_crashed`, interrupted `run_worker_crashed`, and failed `tool_ambiguous`.
8. Await timeout is caller receive policy, not run cancellation or terminal evidence.
9. Provider owns Provider inactivity; Workspace owns process inactivity and timeout.
10. Restart could replay visible output or an uncertain side effect.
11. Durable run/event storage, stable sequence identity, restart recovery, and the
    multi-run persistent daemon tree; the higher API already supplies bounded
    process-lifetime reconnect/replay.
