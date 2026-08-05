# Agent Loop Maintenance Guide

This guide explains the implemented synchronous Agent Loop. It is the maintenance
companion to [`PLAN-AGENT-LOOP.md`](../plan/PLAN-AGENT-LOOP.md), not a proposal for
Runtime, CLI, persistence, or workflow features.

## Scope And Ownership

`Synapse.Agent.Runner.run/2` is one synchronous bounded function run inside a
temporary Runtime-supervised Task. It is not a GenServer because the MVP
has one caller, one immutable State lineage, one terminal return, and no justified
long-lived mailbox, registry, subscription, or query API.

```text
trusted caller or future CLI
  -> Runtime Task supervision and operation routing
    -> Agent Runner: turns, projection, retry, cancellation policy, budgets
      -> Provider: HTTP/SSE normalization
      -> Tool Executor: one validated call and paired Result
        -> Workspace: bounded host file/process effect
```

The process calling Runner owns State and invokes Provider synchronously. A
Provider implementation may invoke its event callback from another process, so
the callback captures immutable run, turn, operation, and Context values rather
than relying on callback `self/0` or process-local State.

Runtime, not Runner, converts unexpected Runner Task exits, routes cancellation
to the active operation, and close the Workspace Handle. Provider exceptions,
throws, and exits intentionally remain process failures rather than being confused
with typed Provider terminals.

## Trusted And Model-Derived Data

Trusted application data includes the Provider module, Workspace Handle, fixed
instructions, capabilities, Tool limits, event/activity sinks, cancellation
reference and persistent probe, Runtime deadline, retry-delay policy, and generated
operation IDs. The model cannot enlarge or replace that authority.

Model-derived data includes assistant text, Provider item and call IDs, Tool names,
Tool arguments, and all Tool Result content. Tool names stay strings through
Provider, Admission, Registry lookup, Events, and continuation; no dynamic atom or
module construction is allowed.

### Identity Table

| Identity | Producer | Purpose |
| --- | --- | --- |
| Run ID | trusted Run Request creator | Correlates the complete run; hashed inside operation IDs |
| Provider item ID | Provider/model protocol | Identifies one output item; never authorizes execution |
| Call ID | Provider/model protocol | Pairs one FunctionCall with exactly one Tool Result |
| Operation ID | Agent OperationId | Distinguishes Provider attempts and Tool executions |

A retry keeps the same run ID, turn, Provider Request, item/call history, and call
semantics while receiving a fresh Provider operation ID.

## First Request And Continuation

The first Provider Request contains fixed instructions, the Run model, canonical
Tool schemas, metadata with run ID and turn, and one user message containing the
prompt. The local `cwd`, Workspace Handle, capabilities, callbacks, deadlines, and
credentials are not model-visible.

```text
Run Request.prompt
  -> user input message
  -> immutable State.input_items
  -> Provider Request turn 1
```

Only a completed terminal Provider Response authorizes final text or Tool calls.
TextDelta and Tool-call stream events are progress observations and may be partial.
Runner never reconstructs authority from them.

For each completed FunctionCall, projection retains the original call immediately
followed by its paired output:

```text
previous input
  + assistant message, when present
  + function_call {item ID, call ID, name, arguments}
  + function_call_output {same call ID, Result content}
  -> exact full-history Request for the next turn
```

The call/output pair is indivisible. Missing, extra, duplicate, malformed, or
ambiguous Results prevent continuation.

### Model Visibility

| Data | Provider/model visible | Local only |
| --- | --- | --- |
| Fixed instructions, model, Tool schemas | Yes | Also retained in trusted contracts |
| Prompt | Yes, as first user message | Also retained in Run Request and State |
| Assistant text and FunctionCalls | Yes | Also retained in State/Result |
| Tool Result content | Yes, on continuation | Also retained in State |
| Run metadata | Provider-visible metadata | Not model authority |
| `cwd`, Workspace Handle, capabilities | No | Yes |
| Deadlines, limits, callbacks, cancel reference | No | Yes |
| Provider credential and HTTP headers | No Agent contract contains them | Provider transport worker only |

Model-visible Tool output is untrusted. It may contain sensitive data independently
read from a file or process even though Agent itself has no credential field.

## One Logical Turn

```text
check cancellation and deadline
  -> project immutable Provider Request
  -> charge logical turn
  -> emit TurnStarted
  -> Provider attempt(s)
  -> normalize completed Response
  -> final text: charge output and complete
  -> calls: whole-batch preflight, then sequential execution
  -> append known call/Result pairs
  -> emit TurnCompleted
  -> next turn
```

One logical turn may contain multiple Provider attempts. Retries do not create a
new turn or rebuild the Request.

## Admission And Sequential Execution

Admission validates the complete FunctionCall batch before the first side effect.
It checks item and call identity, JSON argument bounds, duplicate identities,
aggregate Provider-output bytes, and remaining Tool-call capacity. Unknown Tool
names remain valid strings so Executor can return ordinary paired feedback.

```text
completed Response
  -> validate every call and aggregate capacity
  -> any structural failure: execute zero calls
  -> admitted batch: execute calls once in Provider source order
```

Immediately before each call, Runner checks cancellation/deadline, charges one
Tool call, emits ToolStarted, constructs reduced Tool Context, and invokes
`Synapse.Tool.Executor.execute/2`. It then emits ToolCompleted without copying
Result content.

An ordinary `:error` Result has a known side-effect outcome such as `not_applied`
or `completed`; it remains paired model feedback and later calls may run. An
`:ambiguous` Result means the side effect may have occurred. Runner starts no later
Tool or Provider operation and returns a Tool ambiguity terminal. If cancellation
is simultaneously observable, the run is interrupted while retaining ambiguity
identity and `outcome: unknown` evidence.

## Retry

Transparent Provider retry requires every condition below:

1. The normalized Provider Error has `retryable: true`.
2. The Error has `output_started: false`.
3. Its kind is one of `rate_limited`, `unavailable`, `timeout`, `transport`, or `upstream`.
4. Aggregate `max_provider_retries` capacity remains.
5. The persistent cancellation probe is false.
6. The bounded delay callback returns an integer from 0 through 10,000 milliseconds.
7. The delay and next attempt remain strictly before the effective deadline.

Configuration, authentication, authorization, protocol, and explicit interruption
errors are never retried. Any visible text or Tool progress blocks replay.

```text
retryable pre-output Error
  -> charge retry
  -> validate bounded delay
  -> wait for delay or matching cancel message
  -> recheck persistent cancellation and deadline
  -> fresh operation ID, exact same Request, same logical turn
```

Semantic retry is distinct from Runtime process supervision. It handles expected
Provider terminals; it does not restart crashed Runner or Provider processes.

## Cancellation

The matching `cancel_ref` lets Provider and Tool lower layers consume one active
operation message. The zero-arity `cancelled?` callback is persistent Agent-level
state and must remain true after that message is consumed. Runner checks it before
and after every lower operation, before continuation, and during retry waits.

```text
Runtime cancellation state = true
  + {:cancel, active_cancel_ref}
  -> lower operation may consume message
  -> Runner rechecks persistent probe
  -> emit RunInterrupted and start no later operation
```

A crashing cancellation probe fails closed as cancellation. Actual active-operation
tracking and message routing remain Runtime work.

## Budgets And Deadlines

Budget charges happen at structural boundaries:

| Counter | Charge point |
| --- | --- |
| Logical turns | Immediately before the initial Provider attempt for a turn |
| Provider retries | Before each additional safe attempt |
| Tool calls | Immediately before ToolStarted and Executor invocation |
| Provider output | After complete terminal Response normalization |
| Tool output | After each known paired Result, before later work |
| Wall time | Checked before each operation, retry, and continuation |

The effective absolute monotonic deadline is the earlier of `started_at +
max_wall_time_ms` and Runtime's supplied deadline. Provider and Tool contexts
receive that same value. Wall-clock time, timezone, and sleeps are not accounting
inputs.

Worked boundary example:

```text
Before turn 2: turns=1, retries=1, tool_calls=2, output_bytes=900
Admit turn 2:  turns=2
Provider emits 100 complete bytes: output_bytes=1000
Admit one Tool: tool_calls=3
Known Result is 80 bytes: output_bytes=1080
Continuation is allowed only if all maxima are at least those exact values and
the supplied monotonic timestamp is before the effective deadline.
```

Reaching an exact limit may complete. Starting one operation beyond a limit fails
before that operation. Whole-batch Tool capacity failure executes zero calls.

## Terminal Outcomes And Events

```text
running State lineage
  -> Agent Result + RunCompleted
  -> Agent Error + RunFailed
  -> Agent Error + RunInterrupted
```

Runner's internal State values remain immutable running snapshots; terminal
authority is the returned Result or Error plus one terminal Run Event. Reserved
terminal State status sentinels are rejected by every transition and projection,
so a terminal snapshot cannot be continued.

Run Events are synchronous, ordered, bounded, and UI-independent. They are not
durable records. TextDelta and RunCompleted are content-bearing; default inspection
is redacted, but direct field access by the trusted sink exposes their content.
ToolCompleted contains status and bounded identity/outcome metadata, never Result
content or arguments. Event-sink rejection or callback failure structurally stops
the run.

## Security Boundary

Agent, BEAM process isolation, Workspace containment, and Bash execution are not
security sandboxes. Code already executing in the VM can forge ordinary structs,
read direct fields, invoke callbacks, or bypass public boundaries. Workspace and
Bash run with the current OS user's authority, subject to their explicit policy and
containment checks rather than kernel isolation.

Custom Inspect implementations reduce accidental disclosure only. They do not
protect direct field access, `Map.from_struct/1`, custom formatters, or a trusted
sink that explicitly logs content. Agent produces no logs. Provider error prose is
replaced with Agent-owned text; typed Provider classification is retained without
raw bodies, credentials, prompts, commands, paths, or output.

## Examples And Test Entry Points

The executable text-completion and ordinary unknown-Tool correction examples are
in `Synapse.Agent` moduledoc.

| Behavior | Deterministic example |
| --- | --- |
| Text completion | `test/agent_text_turn_test.exs` |
| Tool continuation | `test/agent_continuation_test.exs` |
| Ordinary unknown/invalid/denied correction | `test/agent_continuation_test.exs` |
| Safe retry and exact Request reuse | `test/agent_retry_cancellation_test.exs` |
| Cancellation before/during operations | `test/agent_retry_cancellation_test.exs` |
| Ambiguous Tool terminal | `test/agent_tool_execution_test.exs` |
| Exact and exhausted Budget boundaries | `test/agent_budget_test.exs` |
| Full Fake loop | `test/agent_continuation_test.exs` |
| Temporary Real Workspace | `test/agent_real_workspace_test.exs` |
| Opt-in live Tokamak loop | `test/live_agent_loop_test.exs` |
| Adversarial and hard-limit review | `test/agent_phase10_test.exs` |

Fake tests prove exact state, requests, events, pairing, and policy without network
or host effects. Temporary Real tests prove local adapters, not model behavior.
Live tests prove one real Provider path but remain nondeterministic and must never
run for untrusted pull requests. Independent file content and command exit evidence
is stronger than a model's textual claim that work succeeded.

## Deferred Work

Runtime still owns Task supervision, worker-exit conversion, active-operation
routing, Workspace lifetime, durable event sequencing, timestamps, subscriptions,
and cancellation delivery.

Persistence and long-running harness work remains deferred: sessions, append-only
history, reconnectable clients, context compaction, summaries, artifacts, follow-up
queues, steering, approvals, verification workflows, acceptance, commits, work-item
state, worktrees, rollback, and merge integration.

Tool and orchestration breadth remains deferred: parallel/dependency-aware Tool
scheduling, automatic Tool replay, dynamic Tools, MCP, web/remote Tools, subagents,
planner/verifier roles, multi-provider routing, fallback, telemetry, cost accounting,
durable operation journals, and crash recovery.

Security hardening beyond the MVP remains deferred: unforgeable scoped capability
tokens, credential brokers and secret leases, exact-value output redaction, and
OS-user/container/VM/filesystem/network/syscall/resource sandboxing.

## Maintainer Comprehension Checklist

A maintainer should be able to answer all of these from this guide and linked API
documentation:

1. Runner is synchronous because one temporary Task owns one bounded immutable lineage.
2. The Runner process owns State; Provider implementations may invoke callbacks elsewhere.
3. Progress events observe streaming; only terminal Response/Error authorizes policy.
4. The prompt becomes one user input item in the first immutable Provider Request.
5. Each FunctionCall is followed by one same-call-ID function output in continuation.
6. Run, item, call, and operation IDs have distinct producers and purposes.
7. Whole-batch preflight prevents a malformed later call from following an earlier side effect.
8. Ordinary errors have known outcomes; ambiguity means a side effect may have occurred.
9. Retry requires retryable, pre-output, allowlisted kind, budget, delay, deadline, and no cancellation.
10. Persistent cancellation remains visible after a lower layer consumes its message.
11. Every Budget counter is charged at the explicit boundaries in the table above.
12. The model-visible matrix identifies every projected field and every local authority.
13. Fake Provider and Workspace scripts test the full loop without network or host effects.
14. Agent completion is model settlement, not verification, workflow acceptance, or commit readiness.
15. Deferred Runtime, persistence, workflow, Tool, orchestration, telemetry, and sandbox work is listed above.

When changing a public contract, update its moduledoc/spec, this guide, the detailed
plan, deterministic fixtures, redaction tests, and generated ExDoc in the same change.
