# Agent Loop Implementation Checklist

## Purpose

This document is the implementation checklist for the Agent Loop component
defined in [`PLAN.md`](PLAN.md).

It turns the conversation, turn, budget, retry, Tool continuation,
Agent-Computer Interface, and comprehension requirements in
[`../../README.md`](../../README.md) and
[`../CLAUDE-HARNESS.md`](../CLAUDE-HARNESS.md) into an ordered set of coding,
testing, documentation, and learning tasks.

The checklist is intentionally limited to the Agent Loop and the shared Run
contracts it needs. It does not implement Runtime supervision, Workspace opening,
CLI parsing or rendering, persistence, verification workflows, context
compaction, worktrees, subagents, extensions, or a persistent daemon.

## Agent Loop Outcome

The Agent Loop is complete when a trusted caller can start one bounded run with a
normalized Run Request and Agent Context, stream one or more Provider turns,
execute complete Tool calls sequentially through Executor, append exact paired
Tool outputs, and receive one structured terminal result.

The first deterministic proof is:

```text
Run Request + Agent Context
  -> immutable Provider Request
  -> Fake Provider complete FunctionCall response
  -> preflight every call before side effects
  -> sequential Tool Executor calls through Fake Workspace
  -> exact function_call + function_call_output continuation
  -> Fake Provider final text response
  -> completed Agent Result and ordered Run Events
```

The first live proof uses the same Runner with `Synapse.Provider.Tokamak` and a
temporary Real Workspace. A live test must never target a user checkout.

Agent completion means only that the model returned final text without pending
Tool calls. It does not mean that a coding task is verified, accepted, committed,
or safe to merge. Those are later workflow and Runtime responsibilities.

## Checklist Rules

- Check an item only after implementation, focused tests, public documentation,
  and the relevant learning guide are complete.
- Do not check a phase merely because code exists.
- Use `Synapse.Provider.Fake` and `Synapse.Workspace.Fake` for ordinary Agent tests.
- Use temporary roots only for the smaller Real Workspace integration suite.
- Treat a successful terminal `Provider.Response` as the only authority for
  assistant output and executable function calls. Streaming events are progress.
- Preflight every function call in one response before executing the first call.
- Never execute a call from a failed, interrupted, malformed, or incomplete
  Provider turn.
- Never retry a Provider attempt after any output started.
- Never automatically retry a Tool call.
- Stop admitting later calls after one ambiguous Tool Result.
- Keep provider output-item IDs, function call IDs, run IDs, and operation IDs
  distinct.
- Never create atoms, modules, functions, capabilities, or operation authority
  from model-provided values.
- Never place prompts, file content, commands, process output, credentials,
  absolute paths, Workspace Handles, or arbitrary exceptions in Agent-generated
  metadata, logs, or ordinary inspection output.
- Model-visible text and Tool Result content remain untrusted and may contain
  sensitive data obtained independently by the run.
- Avoid wall-clock sleeps in deterministic tests.
- Keep each phase small enough to review and understand independently.
- If a public contract changes, update this plan and the parent architecture
  before continuing.

## Progress Summary

| Phase | Deliverable | Status |
| --- | --- | --- |
| 0 | Confirm boundaries, identities, termination, and retry decisions | Complete |
| 1 | Run, Budget, Agent Context, Result, Error, and State contracts | Complete |
| 2 | Conversation projection and immutable turn requests | Complete |
| 3 | Provider event adaptation and one text-only turn | Complete |
| 4 | Complete function-call admission and batch preflight | Complete |
| 5 | Sequential Tool execution and Run Events | Complete |
| 6 | Tool-result continuation and multi-turn loop | Complete |
| 7 | Budget, deadline, and output accounting | Complete |
| 8 | Provider retry, interruption, and cancellation policy | Complete |
| 9 | Deterministic integration and live Tokamak acceptance | Complete |
| 10 | Reliability, security, and ExDoc comprehension review | Complete |

Update this table only when a phase passes its completion gate.

## Architectural Position

```text
                         outside Agent Loop
                                |
                                v
                    +-------------------------+
                    | Synapse.Agent.Runner    |
                    | one bounded run         |
                    +------------+------------+
                                 |
                      immutable  |  ordered
                      state      |  Run Events
                                 v
                    +-------------------------+
                    | turn request / response |
                    | projection and policy   |
                    +------+-------------+----+
                           |             |
                           v             v
                 +----------------+  +----------------+
                 | Provider       |  | Tool.Executor  |
                 | Tokamak/Fake   |  | one Call       |
                 +----------------+  +-------+--------+
                                             |
                                             v
                                     +---------------+
                                     | Workspace     |
                                     | Handle        |
                                     +---------------+
```

Runtime will later start Runner in a supervised temporary Task, open and close the
Workspace Handle, route cancellation, and convert worker exits. Runner itself is
a synchronous function for the MVP and does not require a GenServer.

## Dependency Direction

```text
Runtime or deterministic test harness
  -> Run Request + Agent Context
  -> Agent Runner
  -> Provider behaviour implementation
  -> Tool Registry specifications
  -> Tool Call conversion
  -> Tool Executor
  -> Workspace through Tool only

Agent Loop
  -X-> Req, Finch, SSE, Tokamak JSON, or credentials
  -X-> File, System, Port, MuonTrap, or direct Workspace operations
  -X-> Runtime modules or supervision APIs
  -X-> CLI or terminal rendering
  -X-> persistence, Git, worktrees, verification, or extensions
```

Agent depends on Provider and Tool contracts. Provider, Tool, and Workspace never
import or call Agent.

## Agent Loop Boundary

### Agent Loop Owns

- Validation of shared Run Request and Budget contracts.
- Trusted Agent Context validation.
- One run's immutable in-memory State.
- Ordered normalized conversation input items.
- Initial user-message projection.
- One immutable Provider Request per logical turn.
- Provider implementation selection from trusted Context.
- Mapping Provider progress to Run Events.
- Successful terminal Provider Response interpretation.
- Complete function-call batch preflight.
- Sequential source-order Tool execution.
- Distinct Provider and Tool operation identities.
- Paired function-call output projection.
- Turn, Tool call, wall-time, retry, and output accounting.
- Safe Provider retry decisions before output only.
- Final text, failure, interruption, ambiguity, and budget termination.
- One structured terminal Result or Error.

### Agent Loop Does Not Own

- HTTP requests, SSE parsing, response-wire accumulation, or credentials.
- Model-facing Tool schema definitions or Tool argument validation details.
- Workspace roots, path containment, revisions, file mutation, or subprocesses.
- Workspace Handle creation or closure.
- Task supervision, worker restart policy, or crash conversion.
- Durable event sequence numbers, timestamps, storage, or replay.
- Terminal rendering or CLI exit codes.
- Task verification, evidence collection, acceptance, or commits.
- Context compaction, summaries, persistence, or cross-session memory.
- Worktrees, fresh-attempt retry, follow-up queues, or steering messages.
- Parallel Tools, subagents, extension generations, MCP, or dynamic Tool search.

## Architectural Invariants

- Runner receives provider implementation, Workspace Handle, capabilities, limits,
  sinks, and cancellation controls only through trusted Agent Context.
- Run Request contains user intent and trusted local configuration, not modules,
  callbacks, credentials, Handles, transport options, or terminal state.
- Every logical turn builds one immutable Provider Request snapshot. A retry reuses
  that exact request value.
- Provider progress callbacks are process-independent. They never rely on `self/0`,
  process dictionary state, or mutation of Runner-local State.
- Streaming events may be rendered but never authorize Tool execution.
- Only a successful terminal Provider Response supplies final messages,
  executable calls, and authoritative source order.
- Every FunctionCall in a successful response is converted with
  `Tool.Call.from_provider/2` before the first call executes.
- If any call cannot be admitted or the whole batch exceeds the remaining Tool
  budget, none of that response's calls execute.
- Provider output-item `id` remains in conversation projection. Provider
  `call_id` pairs Tool Call and Tool Result. Agent-generated `operation_id`
  controls one external operation. These identities are never substituted.
- Tool calls execute synchronously and sequentially in Provider source order.
- An ordinary Tool `:error` is paired, appended, and made available to the model
  for correction.
- A Tool `:ambiguous` result is paired locally, prevents every later call in the
  batch, prevents another Provider request, and terminates the run.
- Agent never parses `Tool.Result.content` to make policy decisions. It uses the
  typed `status` and trusted local fields.
- Every executed Tool Call has exactly one Result with the same `call_id`.
- Every retained FunctionCall sent on continuation has exactly one immediately
  following `function_call_output` unless the run terminated before continuation.
- Text accompanying Tool calls is retained but does not finish the run. A
  successful response with no calls and at least one non-empty assistant message
  finishes the run.
- A completed response with no calls and no non-empty assistant text is an Agent
  protocol failure, not success and not an invitation to loop.
- Provider retry is allowed only when `retryable: true`, `output_started: false`,
  cancellation is not set, the run deadline remains, and retry budget remains.
- Provider attempts after output, every Tool operation, and every ambiguous
  outcome are never replayed automatically.
- Cancellation is observable independently of Tool Result presentation. Agent
  never parses model-visible JSON to discover whether a run was cancelled.
- Budget exhaustion is a structured terminal Error and cannot start another
  operation.
- Run Events are synchronous, ordered observations. They carry no credentials,
  prompts, raw Tool output, absolute root, or Workspace Handle.
- No core Agent module prints, logs model content, or performs host access.

## Confirmed MVP Decisions

These decisions resolve ambiguities between the minimal plan and the broader
target architecture in `README.md`.

| Concern | MVP decision | Reason |
| --- | --- | --- |
| Execution process | One synchronous Runner inside a future supervised temporary Task | No persistent coordinator is needed for the first loop |
| Provider selection | Trusted Agent Context carries a concrete Provider behaviour module | Run/model input cannot select arbitrary modules |
| Workspace ownership | Runtime opens and closes one Handle; Agent only receives it | Keeps host lifecycle outside conversation policy |
| Terminal authority | `Provider.Response.output_items` only | Progress event order is not execution authority |
| Logical turn | One immutable request plus safe pre-output attempts and resulting Tool batch | Retries do not consume extra model turns |
| Final response | No calls and at least one non-empty assistant Message | Prevents empty-success loops |
| Mixed text and calls | Retain text, execute calls, continue | Tool presence means the model still requires observations |
| Call admission | Preflight all calls before first execution | A malformed later call cannot follow earlier side effects |
| Multiple calls | Sequential Provider source order | Matches the one-call Executor boundary |
| Ordinary Tool error | Pair, append, execute later admitted calls, then continue | The model can repair invalid or stale operations |
| Ambiguous Tool result | Pair locally, stop later calls, terminate without continuation | Missing outputs and uncertain side effects make replay unsafe |
| Tool exposure | Advertise all four static MVP schemas every turn | CLI MVP grants the fixed local capability set; filtering is deferred |
| Capability enforcement | Executor remains authoritative | Schema visibility is usability, not authorization |
| Provider retry owner | Agent owns semantic retry policy; Runtime later owns process lifetime | Agent knows response visibility, conversation, and retry budget |
| Safe retry limit | At most two retries across one run, before output only | Bounded recovery without hidden replay |
| Retry request | Reuse the exact immutable Provider Request with a new operation ID | Prevents context drift between attempts |
| Retry delay | Small bounded policy with a zero-delay deterministic test seam | Avoids hammering upstream without sleeping in unit tests |
| Cancellation | Out-of-band cancellation probe plus operation cancel reference | Lower layers may consume the mailbox message |
| Conversation | Full projected history in memory | Persistence and compaction are post-MVP |
| Function continuation | Retain each FunctionCall and place its output immediately after it | Preserves item identity and obvious pairing |
| Run Events | Small synchronous MVP vocabulary without durable sequence/timestamp | Durable canonical events belong to Runtime/persistence work |
| Completion meaning | Model settled, not task accepted | Verification remains a separate workflow gate |

## Internal Modules

| Module | Purpose |
| --- | --- |
| `Synapse.Budget` | Validated run-level turn, call, time, retry, and output ceilings |
| `Synapse.Run.Request` | Trusted local run identity, prompt, workspace, model, capabilities, and Budget |
| `Synapse.Run.Event` | Closed union of synchronous MVP lifecycle observations |
| `Synapse.Agent` | Public Agent boundary and shared types |
| `Synapse.Agent.Context` | Trusted Provider, Workspace, authority, sinks, deadline, and cancellation dependencies |
| `Synapse.Agent.State` | Immutable conversation, counters, deadline, and terminal status for one run |
| `Synapse.Agent.Result` | Successful final text and bounded run accounting |
| `Synapse.Agent.Error` | Sanitized structured failure, interruption, ambiguity, or budget terminal |
| `Synapse.Agent.Runner` | Synchronous turn and Tool continuation loop |
| `Synapse.Agent.Projection` | Pure Provider input-item conversion and request assembly |
| `Synapse.Agent.Admission` | Pure authoritative FunctionCall batch preflight and output accounting |
| Agent operation-ID helper | Bounded distinct Provider-attempt and Tool-operation IDs |

Do not create every proposed helper before its phase. Keep projection and budget
logic private in Runner until an independently testable invariant justifies a
module. Closely related Run Event structs may share one source file, following the
current Provider event pattern.

## Public Contracts

### Budget

```elixir
%Synapse.Budget{
  max_turns: 20,
  max_tool_calls: 50,
  max_wall_time_ms: 900_000,
  provider_inactivity_ms: 120_000,
  tool_inactivity_ms: 180_000,
  max_output_bytes: 64_000,
  max_provider_retries: 2
}
```

Budget is trusted local policy. It is validated once before a run and copied into
immutable State. `max_output_bytes` bounds aggregate model-visible bytes newly
added during the run: completed assistant message text, canonical FunctionCall
arguments, and Tool Result content. Existing user prompt bytes are bounded by the
Run Request contract separately.

Provider and Tool retain their own lower-level hard ceilings. Agent Budget may
lower effective inactivity or output policy but cannot enlarge those component
limits.

Initial hard Budget ceilings:

| Field | Valid range | Hard ceiling rationale |
| --- | ---: | --- |
| `max_turns` | 1..100 | Bounds recursive model continuation |
| `max_tool_calls` | 1..500 | Bounds side effects and conversation growth |
| `max_wall_time_ms` | 1..3,600,000 | One hour maximum run lifetime |
| `provider_inactivity_ms` | 1..900,000 | Matches Provider StreamContext ceiling |
| `tool_inactivity_ms` | 1..900,000 | Matches Tool/Workspace process ceiling |
| `max_output_bytes` | 1..4,194,304 | Leaves headroom below Provider's 8 MiB encoded request ceiling |
| `max_provider_retries` | 0..5 | Allows retry disablement and prevents infrastructure loops |

### Run Request

```elixir
%Synapse.Run.Request{
  id: "run-123",
  prompt: "Read the project and verify the change.",
  cwd: "/trusted/canonical/workspace",
  model: "configured-model",
  capabilities: capability_set,
  budget: budget
}
```

The CLI or another trusted adapter creates the Request. Runtime validates and
opens `cwd` before Agent starts. Agent uses `id`, `prompt`, `model`, capabilities,
and Budget; it does not call filesystem APIs for `cwd`.

Initial hard contract ceilings:

| Field | Ceiling | Notes |
| --- | ---: | --- |
| Run ID | 256 UTF-8 bytes | Correlation only; never reused directly as an operation ID |
| Prompt | 1 MiB UTF-8 bytes | Trusted local input but still bounded |
| Workspace path | 4,096 UTF-8 bytes | Runtime and Workspace remain authoritative |
| Model ID | 256 UTF-8 bytes | Explicit provider model identifier |
| Capabilities | One valid fixed `Tool.CapabilitySet` | Never derived from model text |
| Budget | One valid `Synapse.Budget` | No arbitrary map after construction |

Ordinary inspection must redact prompt and absolute `cwd` while retaining useful
identity, model, capability, and budget summaries.

### Agent Context

```elixir
%Synapse.Agent.Context{
  provider: Synapse.Provider.Tokamak,
  workspace: workspace_handle,
  instructions: "You are the Synapse coding agent.",
  event_sink: event_sink,
  cancel_ref: cancel_ref,
  cancelled?: cancellation_probe,
  deadline: runtime_deadline,
  provider_activity_sink: provider_activity_sink,
  tool_activity_sink: tool_activity_sink,
  tool_limits: tool_limits,
  retry_delay: retry_delay
}
```

Context is trusted runtime dependency data. The model cannot provide or alter it.
The MVP uses the exact fields shown above. Changing callback fields to wrapper
structs or another lifetime abstraction requires updating this plan before Phase
1. The required semantics are:

- A concrete module exporting `stream/3` under the Provider behaviour.
- One authenticated Workspace Handle already opened for the Run Request.
- Fixed top-level instructions bounded to 64 KiB.
- A synchronous Run Event sink.
- An operation cancellation reference.
- An out-of-band cancellation probe that remains true after a lower layer consumes
  a matching mailbox message.
- An optional earlier Runtime absolute deadline.
- Provider and Workspace activity sinks with their existing exact callback shapes.
- Valid Tool Limits that fit the Workspace Handle ceilings.
- A `retry_delay` function receiving the one-based retry ordinal and returning a
  non-negative delay no greater than 10,000 ms. Production defaults are 250 ms
  for the first retry and 1,000 ms for every later retry; deterministic tests can
  return zero.

Context inspection must not expose the Workspace Handle, callbacks, instructions,
or cancellation reference.

### Agent State

```elixir
%Synapse.Agent.State{
  run: run_request,
  input_items: input_items,
  turn: 0,
  tool_calls: 0,
  provider_retries: 0,
  output_bytes: 0,
  started_at: monotonic_ms,
  deadline: absolute_monotonic_deadline,
  status: :running
}
```

State is immutable data owned by the process executing Runner. Provider event
callbacks may emit Run Events but must not mutate or act as the authoritative
State accumulator. State changes only at explicit Runner boundaries after a
terminal Provider result or Tool Result.

The valid status progression is:

```text
running
  -> completed
  -> failed
  -> interrupted
```

No transition leaves a terminal status.

### Agent Result

```elixir
%Synapse.Agent.Result{
  run_id: "run-123",
  text: "The requested change was verified.",
  final_response: provider_response,
  turns: 3,
  tool_calls: 4,
  provider_retries: 0,
  output_bytes: 12_345
}
```

`text` is the non-empty assistant Message content from the final response, joined
in source order with a single newline between separate message items.
`final_response` retains normalized Provider output for trusted callers. Ordinary
inspection redacts text and output items.

### Agent Error

```elixir
%Synapse.Agent.Error{
  kind: :provider | :tool | :budget | :protocol | :cancelled | :internal,
  reason: stable_reason,
  message: sanitized_message,
  run_id: "run-123",
  turn: 2,
  operation_id: "provider-...",
  details: sanitized_details
}
```

The Error normalizes enough data for Runtime and the future CLI to classify the
terminal without parsing prose or Tool Result content. Provider error kind,
HTTP status, retryability, and output-started state may be copied into allowlisted
details. Tool ambiguity records call ID, registered name, operation ID, and
status, but not Tool content, arguments, command, path, or process output.

Agent Error messages are limited to 512 UTF-8 bytes. Error details and Run Event
metadata use string-keyed safe JSON bounded to 4,096 encoded bytes, 32 entries per
collection, and depth 4. ToolCompleted metadata must also fit the caller's Tool
Limits and cannot copy arbitrary Tool Result metadata without an Agent-owned
allowlist.

Initial stable reasons include:

```text
invalid_run_request
invalid_agent_context
provider_failed
provider_interrupted_after_output
provider_retry_exhausted
empty_provider_response
invalid_function_call_batch
tool_admission_failed
tool_ambiguous
turn_budget_exhausted
tool_call_budget_exhausted
wall_time_budget_exhausted
output_budget_exhausted
run_cancelled
event_sink_failed
tool_executor_contract_failed
```

### Runner Boundary

```elixir
@spec run(Synapse.Run.Request.t(), Synapse.Agent.Context.t()) ::
        {:ok, Synapse.Agent.Result.t()}
        | {:error, Synapse.Agent.Error.t()}
```

Runner returns exactly one terminal tuple. It emits Run Events synchronously
before returning where the sink remains available. Expected failures are data;
invalid direct calls do not raise. Programmer bugs may still crash the Runner
Task and are converted by the future Runtime.

## Run Event Contract

The MVP event union is:

```text
RunStarted
TurnStarted
TextDelta
ToolStarted
ToolCompleted
TurnCompleted
RunCompleted
RunFailed
RunInterrupted
```

Initial event fields:

| Event | Fields beyond `run_id` |
| --- | --- |
| RunStarted | `model` |
| TurnStarted | `turn`, first `operation_id` |
| TextDelta | `turn`, `operation_id`, `item_id`, `content_index`, `delta` |
| ToolStarted | `turn`, `operation_id`, `call_id`, `name`, `ordinal` |
| ToolCompleted | `turn`, `operation_id`, `call_id`, `name`, `ordinal`, `status`, safe `metadata` |
| TurnCompleted | `turn`, `outcome`, `provider_attempts`, `tool_calls`, `output_bytes` |
| RunCompleted | validated Agent `result` |
| RunFailed | validated Agent `error` |
| RunInterrupted | validated Agent `error` |

`TurnCompleted.outcome` is one of `:continued`, `:completed`, `:failed`, or
`:interrupted`. A retry does not emit another TurnStarted; TextDelta identifies
the distinct Provider attempt through its operation ID.

Common event rules:

- Every event carries `run_id`.
- Turn-scoped events carry a positive `turn`.
- Operation-scoped events carry the Agent-generated `operation_id`.
- Tool events carry `call_id`, exact registered/model name, and source ordinal.
- TextDelta may carry Provider item ID and content index for correlation.
- ToolCompleted carries typed status and safe bounded metadata, never full Result
  content.
- RunCompleted carries the Agent Result.
- RunFailed and RunInterrupted carry the Agent Error.
- Events carry no wall-clock timestamp or durable sequence in this phase.
- The synchronous sink defines observed order and backpressure.

Recommended event order for a successful two-turn run:

```text
RunStarted
TurnStarted turn=1
TextDelta ... optional
ToolStarted ordinal=1
ToolCompleted ordinal=1
TurnCompleted outcome=continued
TurnStarted turn=2
TextDelta ...
TurnCompleted outcome=completed
RunCompleted
```

Provider ToolCall progress is not mapped to ToolStarted. ToolStarted is emitted
only after terminal response success, full-batch preflight, budget admission, and
immediately before Executor invocation.

If the event sink rejects or raises, Agent stops starting new operations. The
terminal return is `event_sink_failed`; Agent cannot guarantee delivery of a
terminal Run Event through the sink that already failed.

## Conversation Projection

### Initial Input

The user prompt becomes exactly one normalized input message:

```elixir
%{
  "type" => "message",
  "role" => "user",
  "content" => [
    %{"type" => "input_text", "text" => prompt}
  ]
}
```

Agent does not automatically inject `README.md`, this plan, repository files,
environment variables, or previous external chat. The model retrieves project
information through bounded Tools. Progressive disclosure is a Tool and workflow
property, not an excuse to fill every request with repository prose.

### Assistant Message

```elixir
%{
  "type" => "message",
  "role" => "assistant",
  "content" => [
    %{"type" => "output_text", "text" => message.content}
  ]
}
```

### Function Call

```elixir
%{
  "type" => "function_call",
  "id" => function_call.id,
  "call_id" => function_call.call_id,
  "name" => function_call.name,
  "arguments" => function_call.arguments
}
```

### Function Call Output

```elixir
%{
  "type" => "function_call_output",
  "call_id" => result.call_id,
  "output" => result.content
}
```

Only `Result.content` enters Provider input. Result status and metadata remain
local policy/event data.

For a successful response containing multiple calls, continuation preserves each
Provider output item in source order and places the matching output immediately
after each FunctionCall:

```text
assistant Message, if any
FunctionCall A
function_call_output A
FunctionCall B
function_call_output B
assistant Message, if any
```

This projection is deterministic and validated by `Provider.Request.new/1` before
the next attempt begins.

## Turn Algorithm

```text
validate Request and Context
  -> create initial user input and State
  -> emit RunStarted
  -> check cancellation and budgets
  -> increment logical turn
  -> build immutable Provider Request snapshot
  -> emit TurnStarted
  -> call provider.stream with one attempt operation ID
  -> map TextDelta progress to Run Events
  -> Provider Error:
       cancelled/interrupted? terminate interrupted
       output started? terminate without retry
       retryable and safe budget remains? retry exact request
       otherwise terminate failed
  -> successful terminal Response:
       validate authoritative response
       account complete normalized output
       extract and preflight every FunctionCall
       no calls + non-empty text? complete
       no calls + no non-empty text? protocol failure
       calls exceed batch budget? execute none and fail budget
       execute calls sequentially
       ordinary Result error? append and continue batch
       ambiguous Result? stop batch and terminate
       append retained output items and paired outputs
       emit TurnCompleted outcome=continued
       next logical turn
```

## Termination Matrix

| Condition | Later Tool calls | Next Provider request | Terminal class |
| --- | --- | --- | --- |
| Final non-empty text, no calls | None | No | Completed |
| Text plus calls | Sequential after preflight | Yes after all known Results | Continue |
| Empty completed response | None | No | Protocol failure |
| Any unconstructable call in batch | None | No | Protocol failure |
| Whole batch exceeds Tool-call budget | None | No | Budget failure |
| Tool `:ok` | Continue | Yes after batch | Continue |
| Tool ordinary `:error` | Continue | Yes after batch | Continue |
| Tool `:ambiguous` | Stop immediately | No | Tool ambiguity failure |
| Provider retryable before output | None | Retry same turn if allowed | Continue attempt |
| Provider failure after output | None | No | Interrupted |
| Provider permanent failure before output | None | No | Provider failure |
| Run cancellation | Stop starting operations | No | Interrupted |
| Wall/output budget exhaustion | Stop starting operations | No | Budget failure |
| Event sink failure before Tool start | None | No | Internal failure |
| Event sink failure after known Tool result | Stop later calls | No | Internal failure with known Tool outcome |

## Budget And Accounting Rules

| Resource | Default | Accounting point |
| --- | ---: | --- |
| Logical turns | 20 | Increment once before first attempt of an immutable turn request |
| Tool calls | 50 | Admit the whole response batch before first execution; increment per execution |
| Wall time | 900,000 ms | Effective absolute deadline is the earlier of Budget and Runtime deadline |
| Provider inactivity | 120,000 ms | Passed to each Provider StreamContext |
| Tool inactivity | 180,000 ms | Lowers effective Tool/Workspace process policy where applicable |
| Added output | 64,000 bytes | Completed assistant text, canonical call arguments, and Tool Result content |
| Provider retries | 2 | Increment only for an additional attempt, not the initial attempt |

Rules:

- Use monotonic time for elapsed and deadline calculations.
- Check cancellation, wall time, and remaining budget before every Provider
  attempt, retry wait, and Tool execution.
- Turn budget is charged once per logical request, not once per safe retry.
- Tool-call budget preflights the complete batch. Do not execute a prefix when the
  remaining budget cannot pair the entire batch.
- Output accounting uses complete normalized terminal values, not streaming-event
  fragment sizes. Provider retains its own per-stream hard output limit.
- Count FunctionCall arguments using canonical JSON bytes including keys,
  punctuation, escaping, and values.
- Count Tool Result content exactly as the UTF-8 bytes inserted into conversation.
- If a known Tool operation completes and its Result crosses the remaining output
  budget, retain the known local outcome, emit no later Tool call, and make no next
  Provider request.
- Checked arithmetic fails closed on overflow.
- Budget failure records the exhausted dimension and observed/maximum counts but
  no prompt or model-visible content.
- A caller may lower defaults within hard ceilings. It may not configure zero or
  an unreasonably large value merely to disable a guard.

## Operation Identity

Agent generates a distinct bounded ID for each Provider attempt and Tool
execution. IDs are deterministic within one run and do not expose prompt, model,
workspace path, Tool arguments, or Provider identifiers.

The MVP operation-ID shape is:

```text
provider-<sha256-run-id>-t0001-a0001
tool-<sha256-run-id>-t0001-c0001
```

`sha256-run-id` is the lowercase 64-character hexadecimal SHA-256 digest of the
validated Run ID bytes. Turn, attempt, and call ordinals are zero-padded to four
digits. The configured hard ceilings keep each ordinal below 10,000, and the
resulting IDs fit the stricter 256-byte Tool/Workspace ceiling without truncation.

Required proofs:

- A retry receives a new Provider operation ID but the same Provider Request.
- Every Tool execution receives a new Workspace operation ID.
- Provider item ID and `call_id` never become an operation ID.
- IDs fit Provider's 512-byte and Tool/Workspace's 256-byte ceilings.
- No generated ID contains a prompt, path, command, model output, credential, or
  arbitrary model name.
- Tests can calculate expected IDs without randomness or wall time.

Fake Provider now accepts one operation ID for compatibility or up to 128 unique
declared IDs of at most 512 bytes each. Small owner-linked aliases resolve those
IDs to one ordered script. Agent tests can therefore preserve a fresh production
operation ID per attempt without adding Fake configuration to Provider Request.

## Phase 0: Confirm Boundaries And Decisions

### Evidence Record

Phase 0 was confirmed on August 2, 2026 against the implemented Provider,
Workspace, and Tool System Phases 0-10.

| Decision | Confirmed evidence |
| --- | --- |
| Provider injection | `Synapse.Provider` remains a `stream/3` behaviour; no transport facade selects modules from model data |
| Terminal authority | Provider Event docs and Tool integration tests require successful `Response.output_items` before execution |
| Call admission | `Tool.Call.from_provider/2` validates complete bounded calls and deliberately drops Provider item ID |
| One-call execution | `Tool.Executor.execute/2` is synchronous and owns no process, queue, event, retry, or multi-call order |
| Tool schemas | Registry returns exact Read, Write, Edit, Bash Provider maps; codec fixtures and July 31 live acceptance prove compatibility |
| Tool Result policy | Typed `status` is local authority, `content` is model-visible continuation, and safe `metadata` remains local |
| Workspace lifecycle | Handle docs assign open/close to the trusted opening owner; Agent receives but never opens or closes it |
| Retry ownership | Provider classifies retryability, Agent decides semantic replay, and Runtime later supervises attempt lifetime |
| Fake attempt identity | Fake tests consume one ordered script through distinct declared operation IDs from another process |
| Fake compatibility | Existing one-ID `start_link/2` and `with_script/3` callers remain valid; normalized Request is unchanged |
| Context boundary | Exact trusted fields, callback shapes, instruction limit, deadline, Tool Limits, and retry-delay output ceiling are recorded above |
| Identity boundary | Exact SHA-256 run digest and ordinal formats fit Provider and Tool/Workspace operation-ID ceilings |
| Diagnostic safety | Error message, details, event metadata, inspection, and allowlist requirements are recorded before constructors exist |
| Harness scope | Final model text means settled Agent output, never verification, acceptance, commit, or merge readiness |

### Contract Audit

- [x] Confirm `Synapse.Provider` remains a behaviour and Agent receives a trusted
  concrete implementation module.
- [x] Confirm `Provider.Response.output_items` is the sole terminal authority.
- [x] Confirm `ToolCallCompleted` progress alone can never execute a Tool.
- [x] Confirm `Tool.Call.from_provider/2` is the call-admission boundary.
- [x] Confirm `Tool.Executor.execute/2` accepts one Call synchronously.
- [x] Confirm Registry specifications are Provider-ready maps in stable order.
- [x] Confirm Tool Result status, content, and metadata have distinct policy roles.
- [x] Confirm Runtime, not Agent, will open and close the Workspace Handle.
- [x] Confirm the Runner boundary forbids transport, host, Runtime, and terminal
  module imports.

### Behavioral Decisions

- [x] Record exact final-text, mixed-output, and empty-response semantics.
- [x] Record whole-batch call preflight before side effects.
- [x] Record ordinary Tool error continuation and ambiguous Tool termination.
- [x] Record full-history in-memory projection and no compaction.
- [x] Record Agent as semantic Provider retry owner.
- [x] Record at most two safe retries across one run before output only.
- [x] Record run cancellation as out-of-band state, not parsed Tool JSON.
- [x] Record model completion as distinct from verification and acceptance.
- [x] Record durable event sequencing, persistence, and `RunSettled` as deferred.

### Cross-Component Prerequisites

- [x] Resolve Fake Provider multi-turn script lookup with distinct operation IDs.
- [x] Add a deterministic Fake test proving one script is consumed through those
  distinct IDs in source order.
- [x] Preserve existing Fake APIs where there is a concrete current consumer, but
  do not add generalized provider configuration to normalized Request.
- [x] Update Provider docs if Fake script ownership semantics change.
- [x] Confirm all four Tool schemas fit every immutable Provider Request.

### Limits And Security

- [x] Confirm Budget defaults and hard ceilings.
- [x] Confirm Run Request prompt, ID, path, and model ceilings.
- [x] Confirm Agent instructions, error details, event metadata, and operation-ID
  ceilings.
- [x] Confirm ordinary inspection redacts prompt, cwd, instructions, Handles,
  callbacks, and normalized output content.
- [x] Confirm no Agent-generated metadata copies arbitrary Provider diagnostic or
  Tool content.

### Learning Gate

- [x] Explain why one synchronous Task is sufficient for the MVP Runner.
- [x] Explain why Provider events are progress while Response is authority.
- [x] Explain why all-call preflight must happen before the first side effect.
- [x] Explain why completion is not verification.
- [x] Trace each identity from Provider output through Tool execution without
  conflating item ID, call ID, operation ID, or run ID.

### Phase Complete When

- [x] Every decision that changes Agent state, execution, retry, or terminal
  behavior is recorded in this document.
- [x] The Fake Provider operation-ID prerequisite has a reviewed solution.
- [x] No unresolved decision requires changing the Agent boundary after Phase 1.
- [x] Parent architecture and completed component plans remain consistent.

## Phase 1: Implement Shared Run And Agent Contracts

### Budget

- [x] Create `Synapse.Budget` with the seven MVP fields.
- [x] Validate each recorded range, including zero only for Provider retries.
- [x] Reject unknown fields and malformed keyword input.
- [x] Provide `default/0`, `new/1`, `valid?/1`, types, and field documentation.
- [x] Use checked signed 64-bit arithmetic for initial deadline accounting.

### Run Request

- [x] Create `Synapse.Run.Request` with exact required fields.
- [x] Validate bounded non-empty run ID, prompt, cwd, and model.
- [x] Validate fixed Tool CapabilitySet and Budget values.
- [x] Reject unknown fields, callbacks, modules, credentials, transport options,
  and Workspace Handles.
- [x] Add safe ordinary inspection that redacts prompt and cwd.

### Run Events

- [x] Create the closed Run Event union and event structs.
- [x] Define exact fields and types for every event.
- [x] Keep terminal Result/Error structs out of progress events until their own
  validation succeeds.
- [x] Validate safe bounded Tool event metadata.
- [x] Document synchronous ordering and sink-failure behavior.

### Agent Contracts

- [x] Create `Synapse.Agent.Context` with trusted dependencies only.
- [x] Validate Provider module shape without calling it.
- [x] Validate Workspace Handle, Tool Limits, instructions, event/activity sinks,
  cancellation controls, Runtime deadline, and retry-delay policy.
- [x] Create immutable `Synapse.Agent.State` and its initial constructor.
- [x] Compute the effective absolute deadline without sleeping or starting timers.
- [x] Create `Synapse.Agent.Result` and `Synapse.Agent.Error`.
- [x] Add safe ordinary inspection for content- or authority-bearing contracts.
- [x] Define the public `Synapse.Agent.Runner.run/2` specification without loop
  implementation yet.

### Tests

- [x] Construct defaults and lowered Budget values.
- [x] Reject negative, overflow, and above-ceiling Budget values; reject zero for
  every field except `max_provider_retries`.
- [x] Construct valid Run Request and reject every malformed field.
- [x] Verify Run Request inspection omits recognizable prompt and absolute path.
- [x] Construct each Run Event with valid safe fields.
- [x] Reject unsafe Tool event metadata.
- [x] Construct valid Agent Context with Fake Provider and Fake Workspace.
- [x] Reject arbitrary Provider modules, invalid Handles, malformed callbacks, and
  Tool Limits that exceed Workspace ceilings.
- [x] Construct initial State with one user input item and zero counters.
- [x] Construct every Agent Error kind and a successful Result.
- [x] Verify Agent contract inspection contains no synthetic secret or content.

### Documentation And Learning

- [x] Add `@moduledoc`, `@doc`, `@spec`, `@type`, and field ownership to every
  public contract.
- [x] Explain trusted Run Request data versus trusted Agent Context authority.
- [x] Explain why State is immutable data rather than a GenServer.
- [x] Explain why Runtime deadline and Budget wall time are combined.
- [x] Add ExDoc examples for one Request, Context, Event, Result, and Error.

### Phase Complete When

- [x] Contracts compile with warnings as errors.
- [x] Every external constructor rejects unknown fields.
- [x] Inspection tests prove content and authority redaction.
- [x] No Provider call or Tool execution exists yet.
- [x] LSP hover explains who creates and consumes every field.

## Phase 2: Implement Conversation Projection And Turn Requests

### Initial Projection

- [x] Convert the user prompt into exactly one normalized Provider message.
- [x] Preserve prompt bytes exactly without trimming or interpolation.
- [x] Keep instructions in top-level Provider Request, not as a forged user item.
- [x] Use all four static Registry specifications in stable order.
- [x] Add only allowlisted local correlation metadata.

### Output Projection

- [x] Convert assistant Message output to normalized assistant input.
- [x] Convert FunctionCall output while retaining item ID, call ID, name, and
  decoded string-keyed arguments.
- [x] Convert Tool Result to exact `function_call_output` using only call ID and
  Result content.
- [x] Insert each output immediately after its matching FunctionCall.
- [x] Preserve mixed Provider output-item source order.
- [x] Reject unsupported or malformed output items before conversation mutation.

### Immutable Turn Snapshot

- [x] Build `Provider.Request` from model, instructions, current input items, Tool
  specifications, and safe metadata.
- [x] Return a new value without mutating prior State.
- [x] Reuse the same Request value for safe retries.
- [x] Validate the completed Request through `Provider.Request.new/1`.
- [x] Keep credentials, endpoint policy, retry count, Workspace Handle, and event
  sink out of Provider Request.

### Tests

- [x] Exact first request fixture with one user message and four Tools.
- [x] Exact assistant Message projection.
- [x] Exact single FunctionCall and output projection.
- [x] Multiple calls with immediate paired outputs in source order.
- [x] Mixed text and calls.
- [x] Empty assistant text retained for continuation but not accepted as final.
- [x] Matching call IDs and retained Provider item IDs.
- [x] Result status and metadata absent from Provider input.
- [x] Prior State and Request remain unchanged after later projection.
- [x] Provider Request inspection contains no Handle, callbacks, or secret.

### Documentation And Learning

- [x] Explain full-history projection versus `previous_response_id`.
- [x] Explain why the repository is not dumped into initial context.
- [x] Explain why Result content, not metadata, is model-visible.
- [x] Add a diagram from first user item through one Tool continuation.

### Phase Complete When

- [x] Every supported conversation item round-trips through Provider Request and
  ResponsesCodec tests.
- [x] Projection is pure, deterministic, and source-order preserving.
- [x] No Provider transport or Tool execution occurs in projection code.
- [x] Exact continuation data can be understood from ExDoc alone.

## Phase 3: Implement Provider Events And One Text Turn

### Runner Skeleton

- [x] Validate Request and Context before emitting RunStarted.
- [x] Initialize State and effective deadline.
- [x] Emit RunStarted and TurnStarted synchronously.
- [x] Build the first immutable Provider Request.
- [x] Generate a bounded Provider attempt operation ID.
- [x] Construct exact Provider StreamContext with inactivity, deadline,
  cancellation, and activity data.
- [x] Call the trusted Provider module through `stream/3`.

### Event Adaptation

- [x] Map Provider TextDelta to Run TextDelta without reconstruction.
- [x] Treat Provider MessageStarted as internal progress correlation.
- [x] Ignore ToolCall progress for execution and ToolStarted events.
- [x] Keep bounded Provider Diagnostic progress out of Agent metadata unless a
  documented safe Run Event mapping is added.
- [x] Make every callback process-independent.
- [x] Stop the Provider operation if the Run Event sink rejects progress.

### Text Terminal

- [x] Revalidate the successful terminal Provider Response.
- [x] Use complete Message output items as final authority.
- [x] Complete only when no calls exist and final joined text is non-empty.
- [x] Treat no calls plus only empty/no Message output as protocol failure.
- [x] Emit TurnCompleted before RunCompleted.
- [x] Return one Agent Result with exact counts and final response.

### Tests With Fake Provider

- [x] Final text on the first turn.
- [x] Multiple Message items joined deterministically.
- [x] TextDelta event order and fields.
- [x] Event sink backpressure and rejection.
- [x] Callback works when invoked from a process other than Runner.
- [x] Final Response remains authoritative when progress is incomplete.
- [x] Progress-only ToolCall executes nothing.
- [x] Empty completed response fails without looping.
- [x] Fake script is exhausted exactly once.

### Documentation And Learning

- [x] Explain logical turn versus Provider attempt.
- [x] Explain why Runner does not reconstruct terminal output from deltas.
- [x] Explain synchronous event backpressure and callback process independence.
- [x] Add one text-only Runner example using Fake.

### Phase Complete When

- [x] A deterministic text-only Run emits exact events and returns final text.
- [x] No Tool operation exists in this phase.
- [x] Empty success cannot create an unproductive loop.
- [x] Agent imports no Req, SSE, Tokamak transport, or terminal modules.

## Phase 4: Implement Function-Call Admission

### Authoritative Extraction

- [x] Read FunctionCalls only from a successful terminal Response.
- [x] Preserve complete Response output-item source order.
- [x] Retain each original FunctionCall for conversation projection.
- [x] Convert every FunctionCall through `Tool.Call.from_provider/2` under the
  effective Tool Limits.
- [x] Never convert model names to atoms or modules.

### Whole-Batch Preflight

- [x] Preflight every call before creating the first Tool Context.
- [x] Reject the whole batch if any call is unconstructable.
- [x] Reject the whole batch if its count exceeds remaining Tool-call budget.
- [x] Detect duplicate call IDs defensively even though Response validation already
  rejects them.
- [x] Preserve unknown Tool names as valid Calls for Executor to pair as errors.
- [x] Preserve exact decoded string-keyed arguments without reinterpretation.
- [x] Leave built-in argument validation and capability checks to Executor.

### Mixed Output

- [x] Retain assistant Messages that occur before, between, or after calls.
- [x] Do not classify mixed text as final while calls remain.
- [x] Account all admitted terminal output before executing side effects.
- [x] Fail output budget before Tool execution when the Provider response itself
  already exceeds the remaining budget.

### Tests

- [x] One complete Read call.
- [x] All four complete built-in call shapes.
- [x] Multiple calls preserve Response source order even when progress-completion
  events arrived in another order.
- [x] Unknown name remains admissible for paired Executor rejection.
- [x] Oversized call ID, name, arguments, entry count, and depth reject the batch.
- [x] A valid first call plus malformed later call executes neither.
- [x] Batch over remaining Tool-call budget executes none.
- [x] Failed and interrupted Provider terminals execute none.
- [x] Bare FunctionCall and ToolCallCompleted inputs execute none.
- [x] Mixed assistant text is retained but does not finish the run.

### Documentation And Learning

- [x] Explain structural admission versus built-in argument validation.
- [x] Explain why unknown names remain pairable Calls.
- [x] Explain why batch preflight is a side-effect safety boundary.
- [x] Add a source-order diagram contrasting progress events and terminal output.

### Phase Complete When

- [x] No malformed call batch can partially execute.
- [x] Provider item IDs remain outside Tool Call.
- [x] Every admitted Call has complete bounded string-keyed arguments.
- [x] Admission remains pure and performs no host operation.

## Phase 5: Implement Sequential Tool Execution

### Tool Context Construction

- [x] Generate one distinct bounded operation ID per admitted call.
- [x] Build Tool Context from Runtime-owned Workspace Handle, Run capabilities,
  Tool Limits, cancellation, effective deadline, and Tool activity sink.
- [x] Do not pass Provider item ID or call ID as Workspace operation ID.
- [x] Do not lower or enlarge capabilities from model arguments.
- [x] Validate Context before ToolStarted so invalid trusted context starts no Tool.

### Event And Execution Order

- [x] Emit ToolStarted immediately before Executor invocation.
- [x] Call `Tool.Executor.execute/2` synchronously once.
- [x] Require a typed paired Result for every preflighted Call.
- [x] Treat unexpected `{:error, :invalid_call}` after successful preflight as an
  Agent internal contract failure.
- [x] Emit ToolCompleted after retaining the Result.
- [x] Include only status and safe local metadata in ToolCompleted.
- [x] Continue later admitted calls after `:ok` and ordinary `:error`.
- [x] Stop later calls immediately after `:ambiguous`.

### Ambiguity

- [x] Retain the ambiguous call/result pair in terminal local State or Error
  correlation.
- [x] Do not append an incomplete batch to a next Provider Request.
- [x] Do not synthesize outputs for calls never executed.
- [x] Do not retry, inspect, reconcile, or roll back automatically.
- [x] Return `tool_ambiguous` with no model-visible Result content in Agent details.

### Tests With Fake Workspace

- [x] One successful Read.
- [x] Read, Write, Edit, and Bash in one response source order.
- [x] Unknown, invalid, denied, stale, and natural Bash failure remain paired and
  do not stop later calls.
- [x] Exact ToolStarted/ToolCompleted order and operation IDs.
- [x] ToolCompleted excludes Result content and arguments.
- [x] Invalid trusted Tool Context executes no Workspace operation.
- [x] Executor admission mismatch terminates defensively.
- [x] Ambiguous Write stops later Bash.
- [x] Ambiguous Bash stops later Read.
- [x] Event sink failure before ToolStarted executes nothing.
- [x] Event sink failure after a known Result starts no later Tool.
- [x] Fake Workspace reports exact remaining operations after every stop case.

### Documentation And Learning

- [x] Explain Agent-owned source-order iteration versus one-call Executor.
- [x] Explain why ordinary errors are model feedback but ambiguity is terminal.
- [x] Explain exact Tool Context authority flow into Workspace.
- [x] Add a call/result/event sequence diagram.

### Phase Complete When

- [x] Every admitted non-ambiguous call receives one paired Result in order.
- [x] No later call begins after ambiguity or event-sink failure.
- [x] Agent calls no Workspace facade directly.
- [x] Tool policy depends on typed status, never parsed Result JSON.

## Phase 6: Implement Continuation And Multi-Turn Loop

### Conversation Mutation

- [x] Project every successful terminal Response output item.
- [x] Insert each executed Result immediately after its matching FunctionCall.
- [x] Preserve assistant Messages around function calls.
- [x] Append the complete projected turn atomically to new State.
- [x] Never mutate prior input item lists in place.
- [x] Validate the complete next input through Provider Request construction.

### Loop Continuation

- [x] Emit TurnCompleted with `outcome: :continued` after a complete known Tool
  batch is appended.
- [x] Check cancellation and all budgets before the next turn.
- [x] Increment logical turn exactly once.
- [x] Build the next immutable Request from full projected history.
- [x] Repeat until final text or terminal Error.
- [x] Leave follow-up messages and steering queues deferred.

### Decisive Fake Integration

- [x] Assert the exact first Fake Provider Request.
- [x] Return one complete FunctionCall response.
- [x] Execute through Tool Executor and Fake Workspace.
- [x] Assert the exact second Fake Provider Request with retained FunctionCall and
  paired Result content.
- [x] Return final text and assert Agent Result.
- [x] Assert both Provider and Workspace scripts are exhausted.

### Scenarios

- [x] One Read round trip then final text.
- [x] Read, Write, Bash, then final text.
- [x] Read, Edit, Bash, then final text.
- [x] Multiple calls in one response then final text.
- [x] Unknown Tool Result followed by model correction.
- [x] Invalid arguments followed by corrected call.
- [x] Stale revision followed by reread and corrected mutation.
- [x] Natural non-zero Bash followed by model diagnosis.
- [x] Mixed assistant text and Tool calls across turns.
- [x] Final text after the maximum permitted logical turn.

### Documentation And Learning

- [x] Explain why full conversation is projected rather than relying on provider
  account state.
- [x] Explain why conversation append occurs only after a complete known batch.
- [x] Explain why context compaction cannot split call/result pairs.
- [x] Add the full Fake Provider-to-Tool-to-final sequence as an ExDoc example.

### Phase Complete When

- [x] Fake Provider completes `read -> write -> bash -> final text`
  deterministically.
- [x] Exact second-turn Request proves correct continuation pairing.
- [x] Ordinary Tool failures can be corrected by a later model turn.
- [x] No test requires network credentials, wall-clock sleep, or user files.

## Phase 7: Implement Budgets And Deadlines

### Accounting

- [x] Count logical turns at turn admission.
- [x] Count Provider retries separately from turns.
- [x] Count Tool calls at execution admission.
- [x] Count complete normalized Provider output after terminal success.
- [x] Count Result content after every known Tool completion.
- [x] Use checked non-negative integer arithmetic.
- [x] Retain counters in immutable State and terminal Result/Error.

### Wall Time

- [x] Record monotonic `started_at` once.
- [x] Calculate Budget deadline with overflow-safe arithmetic.
- [x] Use the earlier of Budget and Runtime deadlines.
- [x] Pass the same effective absolute deadline to Provider and Tool contexts.
- [x] Check deadline before every operation and continuation.
- [x] Never treat wall-clock time or system timezone as run lifetime.

### Exhaustion Policy

- [x] Complete successfully when final text arrives at the exact limit.
- [x] Fail before starting a turn beyond `max_turns`.
- [x] Fail an over-budget Tool batch before executing its first call.
- [x] Stop later work when known Result content crosses output budget.
- [x] Return one structured dimension-specific budget Error.
- [x] Emit TurnCompleted and RunFailed where the event sink remains usable.
- [x] Never ask the model to decide whether a Budget may be exceeded.

### Tests

- [x] Exact turn limit and one beyond.
- [x] Exact Tool-call limit and an over-limit batch with zero execution.
- [x] Exact output limit and one byte beyond for provider text.
- [x] Exact output limit and one byte beyond after Tool Result.
- [x] Effective earlier Runtime deadline.
- [x] Already elapsed deadline starts no Provider attempt.
- [x] Deadline between turns starts no next turn.
- [x] Deadline between Tool calls starts no later call.
- [x] Checked arithmetic overflow fails closed.
- [x] Deterministic pure deadline/accounting tests use supplied timestamps rather
  than sleeps.

### Documentation And Learning

- [x] Document every Budget field, unit, default, and protected resource.
- [x] Explain logical-turn counting across Provider retries.
- [x] Explain why whole-batch Tool budget admission is atomic.
- [x] Explain lower-level hard limits versus Agent aggregate Budget.

### Phase Complete When

- [x] Every loop dimension has one tested terminal boundary.
- [x] Budget exhaustion starts no later operation.
- [x] Wall-time tests are deterministic and sleep-free.
- [x] Errors identify limits without exposing content.

## Phase 8: Implement Retry, Interruption, And Cancellation

### Safe Provider Retry

- [x] Evaluate `retryable` and `output_started` independently.
- [x] Retry only when retryable is true and output_started is false.
- [x] Reuse the exact immutable Provider Request.
- [x] Allocate a new Provider operation ID for every attempt.
- [x] Retain one logical turn number across attempts.
- [x] Apply bounded retry delay without exceeding effective deadline.
- [x] Check out-of-band cancellation before and during retry wait.
- [x] Stop at `max_provider_retries` and return provider retry exhaustion.
- [x] Never retry configuration, authentication, authorization, protocol, or
  explicit cancellation failures unless a future documented policy says so.

### Partial Output And Interruption

- [x] Treat every Provider Error with output_started true as terminal.
- [x] Emit no second Provider attempt after streamed text or Tool progress.
- [x] Execute no call staged by an interrupted response.
- [x] Return RunInterrupted for cancellation, timeout, and partial-stream
  interruption classifications.
- [x] Preserve safe Provider classification in Agent Error details.
- [x] Do not pretend partial text is a completed Agent Result.

### Run Cancellation

- [x] Check the persistent cancellation probe before every operation.
- [x] Pass the matching operation cancel reference to Provider and Tool contexts.
- [x] Recheck the persistent probe after lower operations return.
- [x] Do not infer cancellation by parsing Tool Result content.
- [x] If a cancelled Tool returns ambiguous, preserve ambiguity as the stronger
  side-effect outcome while classifying the run as interrupted with ambiguity
  evidence.
- [x] Start no later Tool or Provider operation after cancellation.
- [x] Keep actual message routing and active-operation tracking for Runtime Phase 5.

### Tests With Fake Provider And Workspace

- [x] Retryable transport failure before output then final text.
- [x] Two safe failures then success at exact retry limit.
- [x] Retry exhaustion.
- [x] Retry Request equality with distinct operation IDs.
- [x] Retry does not increment logical turn.
- [x] Retry delay policy receives expected attempt ordinal.
- [x] Cancellation during retry wait.
- [x] Non-retryable failure before output.
- [x] Retryable failure after TextDelta does not retry.
- [x] Interrupted ToolCall progress executes nothing and does not retry.
- [x] Cancellation before first turn.
- [x] Cancellation during Provider operation.
- [x] Cancellation during known-not-applied Tool operation.
- [x] Cancellation producing ambiguous Tool outcome.
- [x] Persistent cancellation remains observable after lower layer consumes the
  mailbox message.

### Documentation And Learning

- [x] Explain semantic retry policy versus Runtime process supervision.
- [x] Explain why exact Request reuse is required.
- [x] Explain why output visibility blocks transparent replay.
- [x] Add retry and cancellation sequence diagrams.
- [x] Document the MVP cancellation seam and what Runtime still must implement.

### Phase Complete When

- [x] Every safe retry is bounded, pre-output, and exact-request.
- [x] No partial Provider output or Tool operation is replayed.
- [x] Cancellation starts no later operation.
- [x] Interruption and ordinary failure remain distinguishable.

## Phase 9: Deterministic Integration And Live Acceptance

### Full Deterministic Scenario

- [x] Open one scripted Fake Workspace Handle under full local MVP access.
- [x] Configure one multi-turn Fake Provider script with exact Requests.
- [x] Run `read -> write -> bash -> final text` through public Runner.
- [x] Assert exact Run Event order and terminal Result counts.
- [x] Assert every Provider attempt and Tool operation ID is distinct.
- [x] Assert exact call/result pairing and continuation item order.
- [x] Assert Provider and Workspace scripts are exhausted.
- [x] Assert no direct host or network side effect occurred.

### Failure Matrix Integration

- [x] Provider permanent failure before output.
- [x] Provider safe retry then success.
- [x] Provider interruption after output.
- [x] Malformed later call with zero batch execution.
- [x] Unknown/invalid/denied Tool correction.
- [x] Stale revision correction.
- [x] Tool ambiguity with later call not admitted.
- [x] Turn, call, output, wall-time, and retry exhaustion.
- [x] Cancellation at every safe boundary.
- [x] Run Event sink failure before and after a known operation.

### Temporary Real Workspace Integration

- [x] Open a synthetic temporary project root through Workspace.
- [x] Use Fake Provider to request a bounded Read, revision-checked Write or Edit,
  and harmless Bash verification.
- [x] Run through public Agent Runner and real Tool Executor.
- [x] Verify resulting file content and Bash exit evidence independently.
- [x] Close the Handle in the test harness even when Runner fails.
- [x] Confirm Agent code itself uses no File or System API.

### Live Tokamak Acceptance

- [x] Mark live tests `:live_tokamak` and exclude them by default.
- [x] Require runtime `TOKAMAK_API_KEY` and `SYNAPSE_MODEL`.
- [x] Use a new synthetic temporary Workspace only.
- [x] Ask Tokamak to read a fixture, create a small file, and verify it with Bash.
- [x] Complete through public Agent Runner without internal manual calls.
- [x] Assert at least one Tool was called and final text is non-empty.
- [x] Verify the expected file and command result independently of model text.
- [x] Record no live prompt, output, response ID, absolute path, account metadata,
  or credential in fixtures.
- [x] Never run the live test from untrusted pull requests.

### Boundary Audits

- [x] Static search confirms Agent modules call no Req, Finch, File, System, Port,
  MuonTrap, Runtime, CLI, or terminal APIs.
- [x] Agent calls Workspace only indirectly through Tool Executor.
- [x] Every deterministic external operation appears in a Fake script.
- [x] No deterministic test depends on wall-clock sleep or concurrent sender order.
- [x] Live and Real tests clean temporary resources on every terminal path.

### Documentation And Learning

- [x] Explain what deterministic Fake, temporary Real, and live Tokamak tests each
  prove and do not prove.
- [x] Add complete Run Request-to-Agent Result sequence diagram.
- [x] Explain why independent file/command verification is stronger than model
  claims.
- [x] Explain why this phase still does not implement workflow acceptance.

### Phase Complete When

- [x] The full coding loop passes deterministically without network access.
- [x] The same Runner completes one opt-in live Tokamak coding task.
- [x] Independent evidence verifies live side effects.
- [x] No user checkout, live secret, or identifying transcript enters tests.

## Phase 10: Reliability, Security, And ExDoc Review

### Failure Injection

- [x] Inject invalid Request, Context, Budget, Provider module, Handle, sink, and
  cancellation dependencies.
- [x] Inject Provider exception/throw/exit through a dedicated test implementation
  only where Runner is responsible rather than future Runtime.
- [x] Inject malformed successful Response and unsupported output item.
- [x] Inject every call-admission failure before side effects.
- [x] Inject admission mismatch and malformed lower returns at the one-call Executor
  boundary; retain Runner's defensive Result postcondition.
- [x] Inject event-sink failure at every event boundary.
- [x] Inject arithmetic overflow and every exhausted Budget dimension.
- [x] Confirm every expected terminal path returns one Result or Error.
- [x] Leave unexpected Runner process exits for Runtime crash-conversion tests.

### State And Resource Reliability

- [x] Prove one Runner owns one immutable State lineage.
- [x] Prove Provider callbacks retain no unbounded per-delta Agent state.
- [x] Prove no Agent process, Task, timer, ETS table, registry, or mailbox queue is
  created without an explicit lifecycle requirement.
- [x] Stress maximum turns and Tool calls with bounded small fixtures.
- [x] Stress repeated unknown Tool names without atom growth.
- [x] Confirm completed Runs retain no Fake script owner or Workspace operation.
- [x] Confirm terminal State cannot continue.

### Security Review

- [x] Search Agent structs for credentials, headers, raw roots, Handles, callbacks,
  prompts, arbitrary model content, commands, and Tool arguments.
- [x] Search logs, errors, events, and inspection paths for content disclosure.
- [x] Test with recognizable synthetic credentials, paths, prompts, commands, and
  process output.
- [x] Confirm model-derived names remain strings through Provider and Tool.
- [x] Confirm Provider module, capabilities, Handle, instructions, limits, sinks,
  and operation IDs are trusted application data.
- [x] Confirm ToolCompleted and Agent Error do not copy Result content.
- [x] Confirm RunCompleted Result is content-bearing and redacted under ordinary
  inspection.
- [x] State that model-visible Tool output remains untrusted and may contain
  independently obtained sensitive data.
- [x] State that Agent, BEAM processes, Workspace, and Bash are not security
  sandboxes.

### Documentation

- [x] Every public Run and Agent module has `@moduledoc`.
- [x] Every public function has purpose-oriented `@doc` and accurate `@spec`.
- [x] Every struct has `t()` and documented field ownership.
- [x] Add Agent modules to ExDoc groups.
- [x] Add `docs/learning/AGENT-LOOP.md` as the maintenance guide.
- [x] Add boundary, turn, continuation, retry, cancellation, budget, ambiguity,
  and terminal-state diagrams.
- [x] Add examples for text completion, Tool continuation, ordinary correction,
  safe retry, cancellation, ambiguity, and Budget failure.
- [x] Update `README.md`, `PLAN.md`, completed component cross-links, and status.
- [x] Correct stale target-versus-MVP architecture language discovered by audit.
- [x] Document every deferred long-running harness capability.

### Comprehension Gate

- [x] Can the owner explain why Runner is a function in a Task rather than a
  GenServer?
- [x] Can the owner identify which process owns State and which process may invoke
  Provider event callbacks?
- [x] Can the owner distinguish progress events from terminal authority?
- [x] Can the owner trace one user prompt into the first Provider Request?
- [x] Can the owner trace one FunctionCall and Result into the next Request?
- [x] Can the owner distinguish run ID, item ID, call ID, and operation ID?
- [x] Can the owner explain whole-batch preflight before side effects?
- [x] Can the owner distinguish ordinary Tool failure from ambiguity?
- [x] Can the owner list every condition required for Provider retry?
- [x] Can the owner explain why lower-layer cancellation message consumption needs
  a persistent Agent-level probe?
- [x] Can the owner calculate every Budget counter at one turn boundary?
- [x] Can the owner identify exactly which fields become model-visible?
- [x] Can the owner test the full loop without Tokamak or host side effects?
- [x] Can the owner explain why Agent completion is not task acceptance?
- [x] Can the owner list all deferred Agent and harness capabilities?

### Phase Complete When

- [x] Reliability and security tests pass.
- [x] No unbounded Agent accumulator, callback state, queue, retry, or loop remains.
- [x] No Agent-generated log, Error, fixture, example, or ordinary inspection
  exposes credential or arbitrary content; only the explicitly content-bearing
  TextDelta and RunCompleted fields expose content to the trusted event sink.
- [x] Every Tool side effect has a known paired Result or terminates as ambiguous.
- [x] `mix docs` succeeds without Agent documentation warnings.
- [x] All examples and doctests pass.
- [x] The Agent Loop can be maintained without the original design conversation.

## Test Matrix

| Layer | Primary proof | Network/host side effects |
| --- | --- | --- |
| Budget and Run contracts | Unit tests and doctests | None |
| Agent Context/State/Result/Error | Contract and inspection tests | None |
| Conversation projection | Exact Provider Request fixtures | None |
| Text turn and Run Events | Fake Provider | None |
| Call batch admission | Complete Provider Response fixtures | None |
| Sequential execution | Fake Workspace | None |
| Multi-turn continuation | Fake Provider + Fake Workspace | None |
| Retry/cancellation/budgets | Fake Provider + Fake Workspace | None |
| Real boundary | Fake Provider + temporary Real Workspace | Temporary only |
| Live coding loop | Tokamak + temporary Real Workspace | Opt-in HTTPS and temporary files/process |
| ExDoc | Documentation build and doctests | None |

## Suggested Test Layout

```text
test/
  budget_test.exs
  run_contracts_test.exs
  agent_contracts_test.exs
  agent_projection_test.exs
  agent_text_turn_test.exs
  agent_tool_admission_test.exs
  agent_tool_execution_test.exs
  agent_continuation_test.exs
  agent_budget_test.exs
  agent_retry_cancellation_test.exs
  agent_integration_test.exs
  agent_phase10_test.exs
  live_agent_loop_test.exs
```

Prefer readable builders over large stored transcripts. Reuse existing public
Provider and Workspace constructors. Fixtures must contain only synthetic IDs,
paths, prompts, revisions, output, and errors.

## Suggested Commit Sequence

1. `Define Run and Agent contracts`
2. `Project immutable Agent turns`
3. `Run one streamed text turn`
4. `Preflight complete Tool call batches`
5. `Execute Tool calls sequentially`
6. `Continue conversation with paired results`
7. `Enforce Agent budgets and deadlines`
8. `Handle Provider retry and cancellation`
9. `Verify the complete Agent loop`
10. `Document Agent lifecycle and policy`

Each commit must compile, pass focused tests, and include documentation for its
public behavior and limitations.

## Final Agent Loop Verification

```bash
mix format
mix format --check-formatted
mix compile --warnings-as-errors
mix test --warnings-as-errors
mix docs
mix deps.unlock --check-unused
mix hex.outdated
```

The opt-in live verification is:

```bash
TOKAMAK_API_KEY="..." \
SYNAPSE_MODEL="..." \
mix test --only live_tokamak test/live_agent_loop_test.exs
```

The live test must create and remove its own temporary Workspace. It must never
open, mutate, or execute commands in a user checkout.

## Agent Loop Definition Of Done

- [x] Phases 0 through 10 are complete.
- [x] Agent Loop boundary matches `PLAN.md`.
- [x] Shared Run Request, Run Event, and Budget contracts are implemented.
- [x] Runner executes as one synchronous bounded function suitable for a temporary
  supervised Task.
- [x] Every turn uses one immutable Provider Request snapshot.
- [x] Provider terminal Response is the sole execution authority.
- [x] Every call batch is fully preflighted before side effects.
- [x] Tool calls execute sequentially in Provider source order.
- [x] Every executed call receives one paired Result.
- [x] Ordinary Tool errors can drive model correction.
- [x] Ambiguous Tool outcome starts no later operation.
- [x] Exact function calls and outputs are retained in continuation context.
- [x] Provider retries are bounded, exact-request, and pre-output only.
- [x] Partial Provider output and Tool operations are never replayed.
- [x] Turn, Tool call, wall-time, output, and retry budgets terminate structurally.
- [x] Cancellation remains observable after a lower layer consumes its message.
- [x] Run Events are ordered, bounded, normalized, and UI-independent.
- [x] Agent imports no transport, host, Runtime, persistence, or terminal APIs.
- [x] Full deterministic tests require no live key or host side effects.
- [x] One opt-in live Tokamak coding loop passes in a temporary Workspace.
- [x] ExDoc explains ownership, projection, events, execution, retry, cancellation,
  budgets, termination, security, and deferred work.
- [x] The owner can maintain Agent Loop without the original AI conversation.

## Deferred Agent Loop Work

Do not add these before the MVP Agent Loop is complete:

- Dedicated Run GenServer, persistent coordinator, daemon, Registry, or local RPC.
- Runtime Task supervision, worker crash conversion, and active-operation routing.
- Durable event sequence numbers, timestamps, persistence, subscriptions, replay,
  snapshots, `RunFinished`, or `RunSettled`.
- SQLite sessions, append-only history, branching, or reconnectable clients.
- Context compaction, summaries, artifact spill, or server-side response state.
- Follow-up queues, steering messages, interactive approvals, or human input tools.
- Verification workflows, evidence, acceptance, commits, or work-item state.
- Git status, worktrees, fresh-attempt retries, rollback, or merge integration.
- Parallel, batched, dependency-aware, shared, or exclusive Tool scheduling beyond
  the current sequential Executor calls.
- Automatic retry of read-only Tools or any replay of mutating/unknown Tools.
- Dynamic Tool registration, capability-aware schema filtering, Tool search,
  extensions, generation adoption, MCP, web search, or remote Tools.
- Subagents, delegated capability subsets, planner/verifier roles, or orchestration.
- Multiple providers in one run, fallback, model routing, or provider failover.
- Usage cost accounting, telemetry, traces, billing, or model evaluation records.
- Durable operation journals and crash recovery of incomplete calls.
- Source/user/project/workflow-scoped unforgeable capability tokens.
- Credential broker, keychain storage, secret leases, or exact-value output
  redaction.
- OS-user, container, VM, filesystem, network, syscall, CPU, memory, or process
  sandboxing.

These features should reuse the immutable turn, conversation projection, call
pairing, typed terminal, budget, retry, event, and operation-identity contracts
established by this checklist rather than enlarging Runner prematurely.
