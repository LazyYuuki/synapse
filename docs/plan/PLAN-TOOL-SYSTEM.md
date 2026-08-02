# Tool System Implementation Checklist

## Purpose

This document is the implementation checklist for the Tool System component
defined in [`PLAN.md`](PLAN.md).

It turns the model-facing tool, capability, output, failure, Agent-Computer
Interface, and comprehension requirements in [`../../README.md`](../../README.md)
and [`../CLAUDE-HARNESS.md`](../CLAUDE-HARNESS.md) into an ordered set of coding,
testing, documentation, and learning tasks.

The checklist is intentionally limited to Tool System. It does not implement the
Agent Loop, Runtime supervision, Run Events, CLI rendering, persistence,
worktrees, extensions, MCP, search tools, or a host security sandbox.

## Tool System Outcome

Tool System is complete when a trusted caller can expose the four canonical MVP
function schemas, convert one complete Provider function call into one validated
Tool Call, enforce its trusted capability, delegate host access only through an
opened Workspace, and receive one bounded paired Tool Result.

The first deterministic proof is:

```text
successful Provider FunctionCall
  -> validated Tool Call
  -> static string registry lookup
  -> capability decision
  -> exact built-in argument validation
  -> bounded Workspace operation through a Fake handle
  -> bounded model-visible Tool Result with the same call_id
```

The first live proof is that Tokamak accepts one Provider Request containing the
exact four Tool System schemas. Live schema acceptance does not execute host
operations and does not replace deterministic adapter tests.

## Checklist Rules

- Check an item only after implementation, focused tests, public documentation,
  and the relevant learning guide are complete.
- Do not check a phase merely because code exists.
- Keep model-derived names and JSON keys as strings. Never create an atom or
  module name from model input.
- Never use a real workspace where a scripted Fake can prove Tool behavior.
- Use temporary roots for the smaller Real Workspace integration suite.
- Never place real credentials, absolute user paths, file contents, commands, or
  process output in logs, exceptions, fixtures, or examples.
- Read and process output are intentionally model-visible. They remain untrusted
  and may contain sensitive data obtained independently from the Tool System.
- Do not claim that Bash or an in-VM capability value is a security sandbox.
- Do not add hidden retries around file mutation or process execution.
- Keep each phase small enough to review and understand independently.
- If a public contract changes, update this plan and the parent architecture
  before continuing.

## Progress Summary

| Phase | Deliverable | Status |
| --- | --- | --- |
| 0 | Confirm boundaries, schemas, limits, and failure decisions | Complete |
| 1 | Tool contracts, limits, and behavior | Complete |
| 2 | Canonical specifications and static registry | Complete |
| 3 | Capabilities, context, and Executor | Complete |
| 4 | Bounded result presentation and failure mapping | Complete |
| 5 | Read tool | Complete |
| 6 | Write tool | Complete |
| 7 | Edit tool | Complete |
| 8 | Bash tool | Complete |
| 9 | Deterministic integration and live schema acceptance | Complete |
| 10 | Reliability, security, and ExDoc review | Complete |

Update this table only when a phase passes its completion gate.

## Architectural Position

```text
                         outside Tool System
                                  |
                                  v
                       +----------------------+
                       | Tool.Executor        |
                       | one complete call    |
                       +----------+-----------+
                                  |
                 +----------------+----------------+
                 |                                 |
                 v                                 v
        +------------------+              +------------------+
        | static Registry  |              | capability check |
        | name -> module   |              | trusted Context  |
        +--------+---------+              +---------+--------+
                 |                                  |
                 +----------------+-----------------+
                                  |
                                  v
                 +----------------------------------+
                 | Read | Write | Edit | Bash       |
                 | prepare request / present result |
                 +----------------+-----------------+
                                   |
                                   v
                       +----------------------+
                       | static Dispatcher    |
                       | exact operation only |
                       +----------+-----------+
                                  |
                                  v
                       +----------------------+
                       | Synapse.Workspace    |
                       | Real or Fake handle  |
                       +----------------------+
```

## Dependency Direction

```text
Agent or another trusted caller
  -> Tool Call + Tool Context
  -> Tool Executor
  -> static Registry
  -> one built-in prepares typed request
  -> static Dispatcher
  -> Workspace public facade
  -> built-in presents retained outcome

Tool System
  -X-> Provider transport or SSE modules
  -X-> Agent conversation state
  -X-> Runtime supervision policy
  -X-> CLI or terminal rendering
  -X-> File, System, Port, Req, or MuonTrap
```

Tool contracts may convert a completed normalized Provider output item, but Tool
does not parse Provider events or wire data. Workspace is the only component in
this dependency chain that may touch project files or local processes.

## Tool System Boundary

### Tool System Owns

- Tool Call, Result, Spec, Context, CapabilitySet, and Limits contracts.
- The Tool behavior used by built-in implementations.
- Canonical model-visible Responses function specifications.
- A fixed string-keyed registry for the four MVP tools.
- Exact model-argument validation after complete Provider success.
- Tool capability checks before host dispatch.
- Reduction of trusted Tool authority into Workspace Access.
- Conversion from Tool operations to Workspace requests and results.
- Bounded deterministic model-visible result presentation.
- Mapping Workspace failure and uncertainty into Tool status.
- Exact pairing of every submitted valid Tool Call with one Tool Result.

### Tool System Does Not Own

- Provider streaming, SSE parsing, or deciding whether a response completed.
- Retaining Provider output-item IDs for conversation replay.
- Iterating multiple calls in model order. The Agent owns source-order iteration.
- Run Events. The Agent emits tool start and completion around Executor calls.
- Conversation mutation or `function_call_output` insertion.
- Run-level retry, budget, cancellation, or terminal-state policy.
- Workspace root opening, path containment, revisions, atomicity, or processes.
- Terminal rendering, persistence, telemetry, or artifact storage.
- Dynamic tools, extensions, MCP, search, glob, grep, or tool search.
- Host filesystem, process, network, or secret isolation.

## Architectural Invariants

- Tool execution begins only from a complete FunctionCall in a successful
  terminal Provider Response. A `ToolCallCompleted` progress event alone is not
  executable.
- Provider output-item `id`, function `call_id`, and Workspace `operation_id` are
  distinct values with distinct owners.
- `Tool.Call.call_id` always means Provider function `call_id`; it never means the
  Provider output-item ID.
- Every valid call submitted to Executor returns exactly one Result with the same
  `call_id`, including unknown, invalid, denied, cancelled, failed, and ambiguous
  calls.
- An invalid value that cannot form a bounded `Tool.Call` is an Agent input
  contract failure, not an unpaired Tool execution.
- Registry lookup is static and string keyed. No model name becomes an atom,
  alias, module, function, or executable.
- Tool schema is usability guidance and Provider input validation. Runtime Tool
  validation and capability checks remain authoritative.
- Capabilities are trusted caller data and never come from model arguments.
- Tool capability checks occur before built-in preparation. The authenticated
  Workspace Handle and exact OperationContext remain inside Executor and its
  static Dispatcher; built-in callbacks cannot reconstruct broader authority.
- Workspace Access is still reduced and checked again as defense in depth.
- All file and process access goes through the public Workspace facade.
- Read is read-only, Write and Edit are mutations, and Bash has unknown mutation
  footprint.
- Bash always maps to `/bin/bash`, `-lc`, workspace cwd `.`, and
  `mutation: :unknown`. The model cannot select executable, argv structure, cwd,
  environment, mutation class, or secrets.
- No Tool or Executor automatically retries a Workspace operation.
- Workspace `outcome: :unknown` always becomes Tool `status: :ambiguous`.
- A preparation failure occurs before Workspace dispatch and is an ordinary Tool
  error for every effect class. A central dispatch failure after Write, Edit, or
  Bash may have begun is conservatively ambiguous. Presentation failure after a
  trustworthy Workspace terminal result preserves that known outcome.
- Natural non-zero Bash exit is a known Tool error, not a Workspace transport
  error and not an ambiguous outcome.
- Model-visible output is valid UTF-8, deterministic, and bounded after all
  formatting and JSON escaping overhead.
- Raw process output is counted before UTF-8 replacement or presentation
  escaping. It is never logged by Tool.
- Ordinary inspection of content-bearing Tool contracts is redacted.

## Confirmed MVP Contract Decisions

These choices define the target implementation. Phase 0 must prove the schema
and limit assumptions before code depends on them.

| Concern | MVP decision | Reason |
| --- | --- | --- |
| Tool names | Exact strings `read`, `write`, `edit`, `bash` | Stable model API without dynamic dispatch |
| Execution API | Executor accepts one Call and returns one Result synchronously | Agent already owns model-order iteration and Run Events |
| Result algebra | One Result with `status: :ok | :error | :ambiguous` | Every submitted call has one paired terminal contract |
| Pairing ID | Preserve Provider `call_id` | Required by Responses `function_call_output` |
| Operation ID | Trusted separate Context value, maximum 256 bytes | Provider IDs may exceed Workspace's operation-ID limit |
| Provider item ID | Retained by Agent, absent from Tool Call | It is conversation replay identity, not execution identity |
| Argument keys | String keys only | Prevents atom creation from external input |
| Read indexing | Model `offset` is zero based; Workspace `start_line = offset + 1` | Retains existing schema vocabulary while matching Workspace |
| Read continuation | Return `next_offset = next_line - 1` or `null` | Lets the next call reuse the model schema directly |
| Creation sentinel | Exact string `"missing"` maps to Workspace `:missing` | JSON cannot carry the trusted atom and blind overwrite is forbidden |
| Existing revision | Exact canonical `wsr1.*` string parsed by Revision | Keeps revisions opaque and Workspace scoped |
| Optional schema fields | Strict schemas require nullable `offset`, `limit`, and `timeout_ms` fields | Matches strict Responses schema rules without fake defaults |
| Capability form | Trusted fixed-field CapabilitySet for one Context workspace | Narrow MVP seam before source-scoped capability tokens |
| Tool events | Agent emits Run Events around synchronous Executor calls | Avoids duplicate event ownership before Run contracts exist |
| Multiple calls | Agent invokes Executor sequentially in Provider source order | Tool System remains a one-call capability boundary |
| Later calls after ambiguity | Not executed; the run terminates before another Provider request | No continuation requires outputs for calls never admitted |
| Model output | Deterministic bounded JSON object stored in Result `content` | Unambiguous fields, escaping, and continuation projection |
| Mandatory envelope pressure | Preserve identity fields when they fit; otherwise use an outcome-preserving fixed fallback | Never silently clip paths or revisions |
| Workspace error kind | Emit `kind: "workspace"` plus `workspace_kind` | Separates error source from stable Workspace category |
| Local metadata | Bounded string-keyed safe JSON; never sent automatically to Provider | Supports local policy without duplicating raw content |
| Bash exit zero | Tool `:ok` | Command completed successfully |
| Bash non-zero exit | Tool `:error` with exit code and bounded output | Known command failure is useful model feedback |
| Bash forced stop | Tool `:ambiguous` after process start | Unknown filesystem footprint cannot be rolled back or proven |
| Retry | None inside Tool | Prevents duplicate side effects and preserves policy ownership |

### Tool Call

```elixir
%Synapse.Tool.Call{
  call_id: "call_123",
  name: "read",
  arguments: %{"path" => "mix.exs", "offset" => nil, "limit" => nil}
}
```

`Call.from_provider/1` accepts only a complete
`Synapse.Provider.OutputItem.FunctionCall` from a successful Response. It copies
`call_id`, `name`, and decoded string-keyed arguments. It deliberately drops the
Provider item ID; Agent retains the original output item for later replay.

### Tool Result

```elixir
%Synapse.Tool.Result{
  call_id: "call_123",
  status: :ok,
  content: "{\"status\":\"ok\",\"tool\":\"read\",...}",
  metadata: %{"tool" => "read", "outcome" => "completed"}
}
```

Only `content` becomes the Provider `function_call_output.output` string. Agent
uses `call_id` for pairing and may use `status` for continuation or termination.
Metadata is bounded local data for later events and policy; it must not contain
raw file content, command text, process output, absolute paths, handles,
references, exceptions, environments, or credentials.

### Tool Context

```elixir
%Synapse.Tool.Context{
  workspace: workspace_handle,
  capabilities: capability_set,
  operation_id: "tool-operation-123",
  cancel_ref: cancel_ref,
  deadline: absolute_monotonic_deadline,
  activity_sink: activity_sink,
  limits: tool_limits
}
```

Context is trusted per-operation data assembled by Agent or Runtime. The model
cannot provide or alter it. Executor derives the exact Workspace OperationContext
access for the selected Tool and retains it with the authenticated Handle in an
internal DispatchContext. Tool callbacks receive neither value; a Tool Context
never raises the Workspace handle's access ceiling.

### Capability Set

```elixir
%Synapse.Tool.CapabilitySet{
  fs_read: true,
  fs_write: true,
  process_exec: false
}
```

The fixed MVP fields correspond to the target vocabulary
`fs.read:<workspace>`, `fs.write:<workspace>`, and
`process.exec:<workspace>`. The one workspace is the opaque Handle in Context.
This struct is trusted operational policy, not an unforgeable token or protection
from malicious code already executing in the BEAM.

## Canonical Tool Schemas

All schemas are flat Responses function definitions with string keys,
`"strict": true`, and `"additionalProperties": false`. Under strict mode every
property is listed in `required`; runtime-optional values use a nullable type and
`null` selects the trusted default.

Phase 0 must verify this strict nullable subset against the Tokamak Codex pool.
If the endpoint rejects it, record the observed supported subset and update this
section, Provider fixtures, and runtime validators before Phase 1.

Phase 0 verified the exact four schemas against the Tokamak Codex pool on July
31, 2026. The endpoint accepted nullable type arrays, integer minimum/maximum
bounds, `strict: true`, and `additionalProperties: false` in one request. The
model returned one normalized Read call containing the required path and null
optional values. The Provider-only acceptance test did not execute the call or
open a Workspace.

### Read Schema

```json
{
  "type": "function",
  "name": "read",
  "description": "Read a bounded window of numbered lines from one workspace text file. Use the returned revision for write or edit.",
  "parameters": {
    "type": "object",
    "properties": {
      "path": {"type": "string", "description": "Relative workspace file path."},
      "offset": {"type": ["integer", "null"], "minimum": 0, "description": "Zero-based line offset, or null for 0."},
      "limit": {"type": ["integer", "null"], "minimum": 1, "maximum": 1000, "description": "Maximum lines, or null for the trusted default."}
    },
    "required": ["path", "offset", "limit"],
    "additionalProperties": false
  },
  "strict": true
}
```

### Write Schema

```json
{
  "type": "function",
  "name": "write",
  "description": "Create a missing workspace text file or replace one exact revision. Blind overwrite is not supported.",
  "parameters": {
    "type": "object",
    "properties": {
      "path": {"type": "string", "description": "Relative workspace file path."},
      "content": {"type": "string", "description": "Complete UTF-8 file content."},
      "expected_revision": {"type": "string", "description": "Use missing for creation or the exact wsr1 revision returned by read."}
    },
    "required": ["path", "content", "expected_revision"],
    "additionalProperties": false
  },
  "strict": true
}
```

### Edit Schema

```json
{
  "type": "function",
  "name": "edit",
  "description": "Replace exactly one literal text occurrence in one revision of a workspace file.",
  "parameters": {
    "type": "object",
    "properties": {
      "path": {"type": "string", "description": "Relative workspace file path."},
      "old_text": {"type": "string", "description": "Non-empty literal text that must occur exactly once."},
      "new_text": {"type": "string", "description": "Literal replacement text; it may be empty."},
      "expected_revision": {"type": "string", "description": "Exact wsr1 revision returned by read."}
    },
    "required": ["path", "old_text", "new_text", "expected_revision"],
    "additionalProperties": false
  },
  "strict": true
}
```

### Bash Schema

```json
{
  "type": "function",
  "name": "bash",
  "description": "Run one bounded Bash command from the workspace root. This is same-user execution, not a sandbox.",
  "parameters": {
    "type": "object",
    "properties": {
      "command": {"type": "string", "description": "Bash source passed to /bin/bash -lc."},
      "timeout_ms": {"type": ["integer", "null"], "minimum": 1, "maximum": 900000, "description": "Lower total timeout, or null for the trusted default."}
    },
    "required": ["command", "timeout_ms"],
    "additionalProperties": false
  },
  "strict": true
}
```

## Limits And Accounting

Tool Limits are trusted configuration validated when Context is built. A caller
may lower them but cannot exceed the compiled hard ceilings or the opened
Workspace ceilings.

| Limit | Initial value | Protected resource and accounting |
| --- | ---: | --- |
| Call ID bytes | 512 | Provider correlation retained in Call and Result |
| Tool name bytes | 64 | Lookup and error correlation; actual names are fixed and shorter |
| Canonical argument JSON bytes | 64,000 | Decoded model arguments re-encoded with all JSON escaping overhead |
| Argument object entries | 16 | Prevents broad direct callers despite four small schemas |
| Argument nesting depth | 4 | Bounds recursive validation |
| Schema bytes per tool | 16,384 | Bounds registry and Provider request data |
| Registered tools | 32 hard ceiling, exactly 4 in MVP | Bounds immutable registry and turn schema list |
| Model-visible Result content bytes | 64,000 | Final UTF-8 JSON string after escaping and envelope overhead |
| Result metadata bytes | 4,096 | Local string-keyed JSON including escaping overhead |
| Result metadata entries | 32 | Bounds local event/policy data |
| Result metadata depth | 4 | Bounds recursive validation |
| Error message bytes | 512 maximum, 128 minimum | Fixed model-visible diagnostic text must retain complete retry guidance |
| Capability fields | Exactly 3 | Prevents dynamic model-selected authority vocabulary |
| Path bytes | Workspace maximum 4,096 | Tool validates before Workspace repeats containment validation |
| Read lines | 100 default, 1,000 maximum | Protects model attention and line collection |
| Read source bytes | Workspace default 32,768, maximum 65,536 | Bounds Workspace read before presentation |
| Write/edit argument bytes | Included in 64,000 argument envelope | Provider call capacity is lower than Workspace's 8 MiB file ceiling |
| Bash command bytes | Included in 64,000 argument envelope | Bounds shell source and ProcessSpec argv |
| Bash raw output bytes | 65,536 default, Workspace maximum 1,048,576 | Counted by Workspace before UTF-8 conversion |
| Bash timeout | 300,000 ms default, 900,000 ms maximum | Bounds total child lifetime |
| Bash inactivity | 180,000 ms default, 900,000 ms maximum | Bounds silence between accepted output events |

Rules:

- Tool validates aggregate argument JSON bytes even when Provider already bounded
  the function call. Direct callers receive the same protection.
- Once Executor validates a Call under the compiled hard ceiling, its exact
  `call_id` remains pairable even if a direct caller supplied a lower per-operation
  call-ID admission limit. Other lowered Call limits remain authoritative.
- The 64,000-byte argument limit includes keys, punctuation, quotes, and escaped
  string representation, not only decoded string bytes.
- Tool does not advertise Workspace's 8 MiB file ceiling as model-call capacity.
  A larger content transfer mechanism is post-MVP.
- Result size is measured after status, keys, revisions, messages, line numbers,
  truncation markers, UTF-8 replacement, and JSON escaping.
- Presentation builds bounded valid JSON incrementally. It never byte-slices a
  completed JSON string into invalid syntax.
- Caller-lowered result limits may be too small for mandatory path and revision
  fields. Presentation never clips those fields; it returns the fixed
  outcome-preserving presentation fallback instead.
- Read presentation may omit trailing complete lines to fit. It sets
  `presentation_truncated: true` and sets `next_offset` to the first omitted line.
- If one rendered line cannot fit, its text is clipped on a UTF-8 boundary and
  marked truncated. Its unavailable suffix cannot be resumed; continuation moves
  to the next physical line, matching Workspace semantics.
- Bash presentation may clip retained output after a natural known exit without
  changing command outcome. `presentation_truncated` records that model-visible
  clipping.
- If raw Bash output crosses the Workspace ProcessSpec ceiling, Workspace stops
  the unknown-footprint command and Tool returns ambiguous. That is different
  from post-completion presentation clipping.
- Arithmetic uses checked non-negative integer accounting and fails closed before
  allocation when a configured or computed bound is unreasonable.

## Result Presentation Contract

Every `Result.content` is one deterministic JSON object. The key order is fixed by
the presentation module so tests and model context remain stable.

Successful Read content contains:

```json
{
  "status": "ok",
  "tool": "read",
  "path": "lib/example.ex",
  "revision": "wsr1.example",
  "lines": [
    {"number": 1, "text": "defmodule Example do", "ending": "lf", "truncated": false, "presentation_truncated": false}
  ],
  "next_offset": 1,
  "file_bytes": 120,
  "presentation_truncated": false
}
```

Successful Write and Edit content contains relative path, previous revision
(`"missing"` for creation), new revision, changed, bytes written, bounded diff,
Workspace diff truncation, and Tool presentation truncation.

Successful Bash content contains exit code, termination, elapsed milliseconds,
UTF-8 output, raw output bytes, Workspace truncation, and Tool presentation
truncation. Natural non-zero exit uses the same evidence fields under
`status: "error"` with `outcome: "completed"`.

An ordinary error contains:

```json
{
  "status": "error",
  "tool": "edit",
  "error": {
    "kind": "workspace",
    "workspace_kind": "conflict",
    "reason": "stale_revision",
    "message": "Workspace file changed after it was read; reread before retrying",
    "outcome": "not_applied",
    "path": "lib/example.ex"
  }
}
```

An uncertain side effect uses `status: "ambiguous"` and
`outcome: "unknown"`. The message tells the model and caller to inspect current
workspace state and never retry blindly. Errors expose only stable Tool or
Workspace classifications, bounded Tool-owned fixed messages, normalized relative
paths, and allowlisted numeric details. `kind` identifies Workspace as the source;
`workspace_kind` preserves its stable category. They never expose raw Workspace
messages or exception text.

Arbitrary process bytes are converted to valid UTF-8 using replacement for
invalid sequences. JSON escaping makes C0 control bytes, DEL, escape sequences,
and line boundaries non-terminal data. Presentation does not claim to remove
secrets or all deceptive Unicode. The output is model-visible untrusted evidence,
not safe log metadata.

## Failure Taxonomy

| Tool failure | Status | Side-effect meaning |
| --- | --- | --- |
| Unknown static name | `:error` | No built-in dispatched |
| Invalid arguments | `:error` | No Workspace operation dispatched |
| Missing capability | `:error` | No Workspace operation dispatched |
| Workspace denied, conflict, limit, not found, cancelled, or I/O error with known outcome | `:error` | Use Workspace outcome |
| Natural Bash exit code non-zero | `:error` | Process completed; its filesystem effects remain |
| Workspace `outcome: :unknown` | `:ambiguous` | Side effect may have happened |
| Prepare callback crash or malformed request | `:error` | Central Workspace dispatch has not begun |
| Read central-dispatch crash | `:error` | Read has no Tool-owned mutation |
| Write/Edit/Bash central-dispatch crash | `:ambiguous` | Executor cannot prove side-effect outcome |
| Present callback crash or malformed Result | Preserve retained Workspace outcome | Callback has no host authority and terminal evidence is retained |
| Result presentation failure after a retained known Workspace result | Preserve known outcome using bounded fallback | Do not invent uncertainty if the terminal result is trustworthy |

Tuple shape does not carry admitted terminal meaning. Once a bounded Call is
admitted, `Executor.execute/2` returns a validated paired `Tool.Result`; callers
inspect `status`. An unconstructable Call returns `{:error, :invalid_call}` before
admission because no trustworthy pairing ID exists. Ambiguity terminates the MVP
run at Agent level and is never automatically replayed.

## Internal Modules

| Module | Purpose |
| --- | --- |
| `Synapse.Tool` | Behavior and closed built-in execution contract |
| `Synapse.Tool.Call` | Complete bounded model-requested call |
| `Synapse.Tool.Result` | Paired bounded model-visible terminal result |
| `Synapse.Tool.Spec` | Canonical function schema and execution policy |
| `Synapse.Tool.Context` | Trusted workspace, authority, lifetime, and limits |
| `Synapse.Tool.CapabilitySet` | Fixed MVP read, write, and process authority |
| `Synapse.Tool.Limits` | Tool argument, schema, result, and metadata ceilings |
| `Synapse.Tool.Registry` | Static string name to known module mapping |
| `Synapse.Tool.Executor` | Lookup, authorization, dispatch, pairing, and hardening |
| Internal DispatchContext | Handle and exact OperationContext retained only by Executor |
| Static Dispatcher | Typed request validation and exact Workspace facade selection |
| `Synapse.Tool.Presentation` | Ordered bounded JSON, structural clipping, UTF-8 repair, and Workspace failure mapping |
| `Synapse.Tool.Read` | Exact Read preparation and bounded revisioned presentation |
| `Synapse.Tool.Write` | Bounded revision-checked create/replace preparation and presentation |
| `Synapse.Tool.Edit` | Edit argument validation and Workspace adapter |
| `Synapse.Tool.Bash` | Fixed Bash ProcessSpec adapter |

Closely related contracts may share a source file while they remain readable. Do
not create empty modules ahead of their phase. Presentation and validation helpers
should remain internal unless another implemented component has a real reuse case.

## Proposed Public Boundary

```elixir
@callback specification() :: Synapse.Tool.Spec.t()

@callback prepare(
  Synapse.Tool.Call.t(),
  Synapse.Tool.Limits.t()
) :: {:ok, workspace_request()} | {:error, :invalid_arguments}

@callback present(
  Synapse.Tool.Call.t(),
  workspace_outcome(),
  Synapse.Tool.Limits.t()
) :: Synapse.Tool.Result.t()

Synapse.Tool.Registry.specifications()
Synapse.Tool.Registry.fetch(tool_name)
Synapse.Tool.Call.from_provider(function_call)
Synapse.Tool.Executor.execute(tool_call, tool_context)
```

The proposed registry lookup returns only a module present in the compiled static
table.
Built-in callbacks are invoked through Executor in production. Executor validates
the call and Context, checks the Spec capability, asks the known implementation to
prepare one typed request, selects the exact Workspace facade function itself, and
asks the implementation to present the retained outcome. Neither callback receives
the Workspace Handle or OperationContext. Executor validates the returned Result
and its call pairing before returning it.

No public bang API, dynamic registration API, batch execution API, or arbitrary
module execution API is part of the MVP.

## Phase 0: Confirm Decisions And Prerequisites

### Architecture

- [x] Confirm Tool remains between Agent and Workspace with no reverse dependency.
- [x] Confirm Agent owns successful Provider-response selection, multi-call source
  order, Run Events, and conversation continuation.
- [x] Confirm Executor owns exactly one synchronous call and one paired result.
- [x] Confirm no Runtime process or GenServer is required for Tool System itself.
- [x] Confirm built-in host access can use only the Workspace public facade.
- [x] Confirm search, dynamic registration, parallel tools, and extensions remain
  outside this MVP.

### Contracts

- [x] Confirm `call_id`, Provider item ID, and Workspace operation ID remain
  separate.
- [x] Confirm the one-Result algebra and `:ok | :error | :ambiguous` statuses.
- [x] Confirm Agent sends only `Result.content` as function-call output.
- [x] Confirm string-keyed model arguments and metadata.
- [x] Confirm exact result JSON envelopes and deterministic key order.
- [x] Confirm ordinary invalid arguments are pairable Tool errors.
- [x] Confirm an unconstructable Call is an Agent input-contract failure.

### Schemas

- [x] Update the Provider all-tools fixture to the exact schemas in this plan.
- [x] Verify strict nullable optional fields through Provider Request and
  ResponsesCodec tests.
- [x] Run an opt-in live request exposing all four exact schemas.
- [x] Record whether Tokamak accepts nullable type arrays, integer bounds, strict,
  and `additionalProperties: false`.
- [x] Resolve any unsupported schema keyword before implementation begins.
- [x] Record that runtime validators must accept exactly the model-visible field
  set established by the fixtures.

### Capabilities And Operations

- [x] Confirm the fixed three-field CapabilitySet and one-workspace scope.
- [x] Confirm the exact Spec capability and Workspace Access mapping.
- [x] Confirm Context carries the trusted Workspace operation ID and lifetime data.
- [x] Confirm `process_exec` is same-user ambient authority, not root confinement.
- [x] Confirm generic Bash receives no credential-broker injection.

### Limits And Failure

- [x] Confirm every initial Tool limit and accounting rule in this plan.
- [x] Confirm Provider's 64,000-byte argument/output limits against current code.
- [x] Confirm Workspace ceilings used by each adapter.
- [x] Confirm presentation clipping versus Workspace output-limit termination.
- [x] Confirm natural non-zero Bash exit is Tool error with known process evidence.
- [x] Confirm forced unknown-footprint process stop remains ambiguous.
- [x] Confirm conservative post-dispatch callback-crash classification.
- [x] Confirm no hidden Tool retry under any terminal status.

### Documentation And Learning

- [x] Add this plan to ExDoc extras and Plans navigation.
- [x] Cross-link this plan from the Tool System section in `PLAN.md`.
- [x] Record all accepted limitations before implementation begins.
- [x] Explain why schemas do not replace runtime validation.
- [x] Explain why capability omission from a turn does not replace enforcement.
- [x] Explain why Tool and Workspace enforce different layers of authority.
- [x] Explain why Bash output-limit termination can be ambiguous.

### Phase Complete When

- [x] No unresolved decision can change Call, Result, Spec, Context,
  CapabilitySet, Limits, the four schemas, or Agent-facing terminal semantics.
- [x] Tokamak accepts the selected schema subset in an opt-in live test.
- [x] Parent architecture, Provider fixtures, Workspace contracts, and this plan
  agree.
- [x] Exact limits and resource rationale are recorded.

## Phase 1: Tool Contracts, Limits, And Behavior

### Call

- [x] Implement `Tool.Call` with `call_id`, `name`, and string-keyed `arguments`.
- [x] Validate bounded non-empty UTF-8 call ID and name.
- [x] Validate argument entry count, depth, JSON types, UTF-8, and encoded bytes.
- [x] Reject unknown fields, atom keys, improper lists, tuples, PIDs, references,
  functions, and non-JSON terms.
- [x] Implement conversion from complete Provider FunctionCall output items.
- [x] Do not retain Provider item ID in Call.
- [x] Redact arguments under ordinary inspection.

### Result

- [x] Implement paired call ID, status, content, and metadata.
- [x] Validate status and exact model-visible content byte ceiling.
- [x] Validate metadata entry, depth, key, value, and encoded-byte ceilings.
- [x] Require valid UTF-8 content containing one JSON object.
- [x] Reject secret-shaped or content-bearing metadata keys where practical.
- [x] Redact content and metadata under ordinary inspection.
- [x] Provide constructors for successful, ordinary-error, and ambiguous results
  without allowing inconsistent status/outcome combinations.

### Spec And Behavior

- [x] Implement Spec fields for name, description, parameters, capability, and
  effect.
- [x] Use only fixed capability values `:fs_read`, `:fs_write`, and
  `:process_exec` created by application code.
- [x] Use only fixed effect values `:read_only`, `:mutation`, and `:unknown`.
- [x] Validate complete flat Responses schema shape and bytes.
- [x] Define pure prepare/present Tool callbacks with documented pairing,
  validation, side-effect, exception, and retry semantics.
- [x] Keep tool implementation module identity out of model-visible Spec data.

### Context, Capabilities, And Limits

- [x] Implement fixed boolean CapabilitySet fields.
- [x] Implement trusted Context with Handle, CapabilitySet, operation ID,
  cancellation, deadline, activity sink, and Limits.
- [x] Revalidate the opaque Workspace Handle structurally without exposing state.
- [x] Validate cancellation references, monotonic deadlines, and sink arity.
- [x] Implement all Tool limits with defaults and hard ceilings.
- [x] Allow trusted callers to lower but never raise hard ceilings.
- [x] Redact Handle, operation ID, references, sinks, and limits under Context
  inspection.

### Tests

- [x] Constructor success for every contract.
- [x] Unknown fields and missing required fields.
- [x] Every boundary at minimum, maximum, and one beyond maximum.
- [x] Canonical argument encoding includes escaping overhead.
- [x] Invalid UTF-8, NUL where forbidden, deep maps, broad maps, and improper data.
- [x] Provider FunctionCall conversion preserves call ID and arguments.
- [x] Provider item ID never appears in Call or Result.
- [x] Content-bearing contract inspection is redacted.
- [x] Constructors and doctests contain no real paths, commands, or credentials.

### Documentation And Learning

- [x] Add `@moduledoc`, `@doc`, `@spec`, `@typedoc`, and `t()` for every public
  contract and callback.
- [x] Explain who creates and consumes every field.
- [x] Explain trusted Context versus model-derived Call.
- [x] Explain why Result status is data rather than tuple shape.
- [x] Explain why Call cannot use Provider output-item ID as operation ID.
- [x] Add the Phase 1 maintenance and comprehension guide to ExDoc.

### Phase Complete When

- [x] Contracts compile with warnings as errors.
- [x] Contract tests and doctests pass.
- [x] No registry or Workspace execution exists yet.
- [x] LSP hover explains ownership, bounds, redaction, and valid fields.

## Phase 2: Canonical Specifications And Static Registry

### Specifications

- [x] Implement exact Read, Write, Edit, and Bash Specs from this plan.
- [x] Keep registry order deterministic: Read, Write, Edit, Bash.
- [x] Preserve the exact Phase 0 descriptions covering bounds, revisions,
  mutation expectations, and Bash sandbox limitations.
- [x] Require strict mode and reject additional properties.
- [x] Record the exact schema/runtime field parity table; built-in phases own the
  later runtime validator implementation and rejection tests.
- [x] Validate aggregate schema count and bytes before Provider use.

### Registry

- [x] Implement one immutable compiled table from exact string names to modules.
- [x] Implement deterministic `specifications/0` and string `fetch/1`.
- [x] Reject duplicate names and mismatched module specifications at compile or
  test time.
- [x] Return unknown for all non-string and unregistered input.
- [x] Never call `String.to_atom/1`, `Module.concat/1`, `binary_to_atom`, or dynamic
  `apply` using a model-derived module/function value.
- [x] Do not add runtime registration, process state, ETS, persistent term, or an
  extension hook.

### Tests

- [x] Exact specification fixture for every tool.
- [x] Aggregate all-tools fixture equality and deterministic order.
- [x] ResponsesCodec accepts and encodes every specification unchanged.
- [x] Required/property parity and nullable optional-field parity.
- [x] Additional properties are forbidden by every strict schema; runtime
  validator rejection remains gated in the built-in adapter phases.
- [x] Unknown string, empty string, invalid UTF-8, overlong name, and non-string
  lookup.
- [x] Atom-count regression using many unique unknown names.
- [x] Static source audit for dynamic atom/module creation.

### Documentation And Learning

- [x] Explain why a registry is safer than module dispatch from a string.
- [x] Explain schema guidance versus authoritative runtime validation.
- [x] Document deterministic ordering and why dynamic tools are deferred.
- [x] Add an ExDoc example obtaining Provider-ready specifications.

### Phase Complete When

- [x] The four generated schemas match reviewed fixtures exactly.
- [x] Provider encoding tests pass without network access.
- [x] No model string can select an arbitrary module or create an atom.
- [x] Registry has no mutable process or global state.

## Phase 3: Capabilities, Context, And Executor

### Authorization

- [x] Map Read to `fs_read`, Write/Edit to `fs_write`, and Bash to
  `process_exec`.
- [x] Reject a denied call before invoking the built-in module.
- [x] Derive exact reduced Workspace Access for the selected operation and retain
  the authenticated Handle only inside Executor.
- [x] Build Workspace OperationContext from trusted Tool Context lifetime fields.
- [x] Preserve operation ID, cancellation reference, deadline, and activity sink.
- [x] Never read a capability from Call arguments, Spec JSON, or model content.

### Dispatch

- [x] Revalidate Call and Context at Executor entry.
- [x] Look up only through the static Registry.
- [x] Invoke known prepare/present callbacks synchronously when an adapter exists.
- [x] Let only the static Dispatcher select the exact Workspace facade function;
  never pass Handle or OperationContext to a built-in callback.
- [x] Validate returned Result shape, status, bounds, and matching call ID.
- [x] Return unknown, denied, malformed-return, and callback-failure Results with
  fixed bounded diagnostics.
- [x] Track the selected Spec effect for conservative central-dispatch crash
  classification.
- [x] Perform no retry and start no unowned Task.
- [x] Expose no batch or parallel dispatch path.

### Pairing And Failure

- [x] Preserve exact call ID for successful and failed calls, including a Call that
  exceeds caller-lowered operation limits after its pairing ID is trusted.
- [x] Unknown name returns paired `unknown_tool` error.
- [x] Denied capability returns paired `capability_denied` error.
- [x] Invalid built-in arguments return paired `invalid_arguments` error.
- [x] Prepare callback crash returns internal error before dispatch for every
  effect class.
- [x] Read central-dispatch crash returns internal error; Write, Edit, or Bash
  central-dispatch crash is ambiguous because dispatch may have begun.
- [x] Present callback failure or malformed Result preserves the retained terminal
  Workspace outcome using a bounded fallback.
- [x] Sink failure and Workspace ambiguity retain the Workspace uncertainty.

### Tests

- [x] Known typed request dispatch and exact registered module selection.
- [x] Unknown and known-unavailable tools.
- [x] Missing Tool capability.
- [x] Workspace Handle access denial as defense in depth.
- [x] Exact operation access reduction for every tool.
- [x] Matching operation ID and cancellation/deadline propagation.
- [x] Result call-ID mismatch and malformed result rejection.
- [x] Prepare, dispatch, and present exception, throw, exit, and invalid return.
- [x] Faulty Read preparation cannot substitute Write or broaden operation access.
- [x] Altered same-token Handle copies cannot authenticate operations or close.
- [x] No Fake Workspace entry consumed by unknown, invalid, or denied calls.
- [x] No hidden retry after any failure.
- [x] Concurrent direct calls share no Executor state.

### Documentation And Learning

- [x] Add registry, authorization, and dispatch sequence diagrams.
- [x] Explain why omission from model schemas is usability, not authorization.
- [x] Explain why adapters never receive the authenticated Handle.
- [x] Explain why Workspace repeats access enforcement.
- [x] Explain why synchronous execution simplifies ordering and cancellation.
- [x] Explain why Agent, not Executor, owns multiple-call source order.

### Phase Complete When

- [x] Every submitted valid Call receives one paired bounded Result.
- [x] Pre-dispatch rejections cannot reach Workspace.
- [x] Authority can only decrease from Context through Executor-private Workspace
  operation access; adapters cannot reconstruct or invoke broader authority.
- [x] Unexpected mutating failures are never reported as known not-applied without
  proof.

## Phase 4: Bounded Presentation And Failure Mapping

### Presentation

- [x] Implement deterministic key-ordered JSON output.
- [x] Account for all JSON quotes, separators, escaping, replacement characters,
  and fixed envelope bytes.
- [x] Keep every completed content string valid UTF-8 and valid JSON.
- [x] Build under a byte budget rather than encoding unbounded evidence then slicing
  a completed JSON document.
- [x] Implement structural truncation for line lists, line text, diffs, and process
  output.
- [x] Distinguish Workspace truncation from Tool presentation truncation, including
  a separate per-line presentation flag.
- [x] Preserve required revisions and continuation fields even when optional
  evidence is clipped.
- [x] Use an outcome-preserving bounded fallback when mandatory identity fields
  cannot fit a caller-lowered result limit.
- [x] Add a bounded fallback for unexpected presentation failure without exposing
  exceptions.

### Workspace Errors

- [x] Map `outcome: :unknown` only to Tool `:ambiguous`.
- [x] Map all known Workspace outcomes to ordinary Tool error.
- [x] Preserve stable kind, reason, fixed message, normalized relative path, and
  allowlisted safe details.
- [x] Emit `kind: "workspace"` and a separate stable `workspace_kind` category.
- [x] Copy only non-negative allowlisted numeric details in fixed key order.
- [x] Do not copy Workspace operation ID into model-visible output.
- [x] Do not copy arbitrary details, Workspace messages, exception messages,
  backend state, or raw
  inspection output.
- [x] Preserve stale revision, expected missing, no match, multiple matches,
  access denial, cancellation, deadline, and output-limit distinctions.

### Process Output

- [x] Replace invalid UTF-8 sequences deterministically.
- [x] Escape C0 controls, quotes, backslashes, and DEL through model-visible JSON.
- [x] Retain raw byte count separately from presented UTF-8 bytes.
- [x] Never log raw or converted process output.
- [x] Document that Tool does not and cannot guarantee secret removal from output.

### Tests

- [x] Empty, exact-limit, and one-byte-over content.
- [x] Worst-case JSON escaping with quotes, slashes, controls, DEL, and multibyte
  UTF-8.
- [x] Invalid process UTF-8 split at every replacement boundary.
- [x] Broad lines, one huge line, many tiny lines, large diff, and large output.
- [x] Valid JSON under every truncation and mandatory-field fallback path.
- [x] Required identity and revision fields survive presentation pressure whenever
  the mandatory envelope fits; otherwise the fixed fallback is explicit.
- [x] Every Workspace error kind/reason/outcome mapping used by built-ins.
- [x] Synthetic exception and Workspace message text absent from Results and
  Logger output.
- [x] Recognizable synthetic credentials absent unless intentionally supplied as
  Workspace read/process result content.

### Documentation And Learning

- [x] Add result envelope examples for success, error, and ambiguity.
- [x] Explain raw bytes, valid UTF-8, JSON escaping, and model-visible bytes.
- [x] Explain why presentation clipping after natural exit differs from stopping a
  running Bash command at its output ceiling.
- [x] Explain what redaction can and cannot guarantee.

### Phase Complete When

- [x] No model-visible Tool output can exceed the configured final byte ceiling.
- [x] No truncation path produces malformed UTF-8 or JSON.
- [x] Workspace uncertainty is preserved mechanically.
- [x] No raw exception, environment, Handle, absolute root, or backend state can
  enter generated diagnostics.

## Phase 5: Read Tool

### Arguments And Mapping

- [x] Require exact fields `path`, `offset`, and `limit`.
- [x] Require relative UTF-8 path and reject invalid values before Workspace.
- [x] Normalize `offset: null` to zero and `limit: null` to the trusted default.
- [x] Reject negative offset, zero limit, overflow in `offset + 1`, and limits above
  Tool or Workspace ceilings.
- [x] Map `start_line = offset + 1` and `line_count = limit`.
- [x] Select a trusted `max_bytes` no higher than Workspace or Tool limits.
- [x] Derive read-only Workspace Access.
- [x] Let only the static Dispatcher call `Workspace.read/3` for a ReadRequest.

### Result

- [x] Return normalized relative path and canonical encoded revision.
- [x] Return explicit line number, text, ending, and source truncation per line.
- [x] Return `next_offset` or null at EOF.
- [x] Return complete file byte count and presentation truncation state.
- [x] Preserve direct line numbers to reduce model arithmetic and cognitive load.
- [x] Never expose absolute root or internal revision representation.

### Tests With Fake Workspace

- [x] Exact default request and read-only Context.
- [x] Zero and non-zero offsets, including the largest non-overflowing offset.
- [x] Lowered and maximum line limits.
- [x] Empty file, EOF, LF, CRLF, mixed ending, and no final newline.
- [x] Workspace-clipped long line and Tool presentation-clipped line independently.
- [x] Dropped trailing lines update continuation to the first omitted line.
- [x] Revision encoding and later parse compatibility.
- [x] Invalid path, denied capability, Workspace denial, cancellation, and deadline.
- [x] No Workspace entry consumed for invalid arguments or missing capability.

### Real Workspace Integration

- [x] Read a synthetic temporary text file through Tool Executor.
- [x] Confirm numbered lines, revision, continuation, and bounded content.
- [x] Confirm traversal, symlink, non-regular, invalid UTF-8, and oversized-file
  failures remain structured Tool errors.
- [x] Confirm Tool production source calls no host File, System, Port, `:file`, or
  MuonTrap API directly, and only static Dispatcher calls Workspace operations.

### Documentation And Learning

- [x] Explain zero-based Tool offset versus one-based Workspace lines.
- [x] Add examples for first window, continuation, EOF, and clipped line.
- [x] Explain why 100 lines is the default ACI window.
- [x] Explain why every mutation must use the returned revision.

### Phase Complete When

- [x] Every Read call is bounded, numbered, revisioned, and directly continuable.
- [x] Fake proves exact Workspace delegation without host access.
- [x] Real temporary-root tests prove the complete adapter boundary.
- [x] Model-visible output contains no absolute root.

## Phase 6: Write Tool

### Arguments And Mapping

- [x] Require exact fields `path`, `content`, and `expected_revision`.
- [x] Validate aggregate argument bytes before retaining or dispatching content.
- [x] Map exact `"missing"` to Workspace `:missing`.
- [x] Parse all other expectations through `Workspace.Revision.parse/1`.
- [x] Reject malformed revisions before Workspace without claiming stale state.
- [x] Build a WriteRequest with complete UTF-8 content.
- [x] Derive write-only Workspace Access.
- [x] Let only the static Dispatcher call `Workspace.write/3` for a WriteRequest.
- [x] Map a typed request above an opened Workspace file ceiling to paired
  `invalid_arguments` before backend dispatch, not `internal_error`.
- [x] Provide no blind-overwrite, append, directory creation, or automatic retry.

### Result

- [x] Return relative path, previous revision, new revision, changed, bytes written,
  diff, Workspace diff truncation, and Tool presentation truncation.
- [x] Encode creation previous revision as `"missing"`.
- [x] Preserve no-op replacement as successful `changed: false`.
- [x] Preserve stale, expected-existing, denied, limit, I/O, and ambiguity reasons.
- [x] Tell the model to reread after stale conflict rather than retry old content.

### Tests With Fake Workspace

- [x] Missing-file creation exact request and result.
- [x] Existing-file replacement with parsed revision.
- [x] Malformed, stale, cross-handle, and wrong-path revision behavior through Fake
  classifications and Real semantic checks.
- [x] Existing destination under `"missing"` expectation.
- [x] Empty content, maximum argument envelope, and one byte beyond.
- [x] No-op replacement.
- [x] Workspace diff truncation and Tool presentation truncation.
- [x] Denied capability and defense-in-depth Workspace access denial.
- [x] Known not-applied, Workspace limit, I/O, and ambiguous errors.
- [x] Prepare failure is pre-dispatch; dispatch failure is conservative ambiguity;
  presentation failure preserves the retained mutation outcome.
- [x] Crashing and malformed backend dispatch is invoked once and returns ambiguity
  with inspect-before-retry guidance.
- [x] No hidden replay under any failure.

### Real Workspace Integration

- [x] Create a synthetic missing file through Tool Executor.
- [x] Read its revision and replace it through Tool Executor.
- [x] Verify stale, cross-handle, and wrong-path replacement does not alter files.
- [x] Verify failed validation and expected-missing conflict leave original content
  unchanged.
- [x] Verify successful output carries the committed revision.
- [x] Verify creation beneath a missing parent creates neither directory nor file.
- [x] Confirm Tool source calls no File API directly.

### Documentation And Learning

- [x] Add create and revision-checked replace examples.
- [x] Explain why `"missing"` is an expectation, not overwrite permission.
- [x] Explain stale, not-applied, committed, and ambiguous outcomes.
- [x] Explain why Tool never retries a Write automatically.

### Phase Complete When

- [x] Write supports only explicit create or current-revision replacement.
- [x] Every successful result exposes the new revision and bounded diff evidence.
- [x] Every uncertain outcome remains ambiguous.
- [x] Fake and Real adapter tests pass.

## Phase 7: Edit Tool

### Arguments And Mapping

- [x] Require exact fields `path`, `old_text`, `new_text`, and
  `expected_revision`.
- [x] Require non-empty old text and permit empty new text.
- [x] Validate aggregate argument bytes and UTF-8.
- [x] Parse only canonical `wsr1` revisions; `"missing"` is invalid for Edit.
- [x] Build one exact EditRequest without regex, fuzzy matching, or patch parsing.
- [x] Derive write-only Workspace Access.
- [x] Let only the static Dispatcher call `Workspace.edit/3` for an EditRequest.

### Result And Failure

- [x] Return the same mutation evidence shape as Write.
- [x] Preserve exactly-one-match semantics including overlapping matches.
- [x] Preserve Workspace revision validation before match disclosure.
- [x] Distinguish zero match, multiple matches, stale revision, and size failure.
- [x] Preserve equal old/new exact-one match as successful no-op.
- [x] Preserve post-dispatch uncertainty as ambiguous.
- [x] Do not automatically reread, merge, rebase, or retry.

### Tests With Fake Workspace

- [x] Exactly one match and changed result.
- [x] Zero matches.
- [x] Multiple and overlapping matches.
- [x] Empty old text and empty new text.
- [x] Equal old/new no-op.
- [x] Malformed and stale revision.
- [x] Generated content too large.
- [x] Bounded diff and both truncation layers.
- [x] Denied capability and Workspace access denial.
- [x] Known not-applied versus ambiguous error.
- [x] Prepare failure is pre-dispatch; dispatch failure is conservative ambiguity;
  presentation failure preserves the retained mutation outcome.

### Real Workspace Integration

- [x] Read then edit one exact synthetic occurrence.
- [x] Verify zero and multiple matches leave original unchanged.
- [x] Verify stale edit leaves newer content unchanged.
- [x] Verify successful output revision can drive a later edit.
- [x] Confirm Tool source calls no File API directly.

### Documentation And Learning

- [x] Add read-to-edit revision round-trip example.
- [x] Explain literal exact matching and overlapping occurrence behavior.
- [x] Explain why stale conflict is checked before match count.
- [x] Explain why fuzzy edit and automatic stale merge are deferred.

### Phase Complete When

- [x] Edit performs exactly one revision-checked literal replacement or none.
- [x] No conflict path silently changes a file.
- [x] Every known and uncertain outcome is mapped correctly.
- [x] Fake and Real adapter tests pass.

## Phase 8: Bash Tool

### Arguments And Mapping

- [x] Require exact fields `command` and `timeout_ms`.
- [x] Require non-empty bounded UTF-8 command without NUL.
- [x] Normalize `timeout_ms: null` to trusted default.
- [x] Permit only a lower positive timeout within Tool and Workspace ceilings.
- [x] Build exact executable `/bin/bash` and arguments `["-lc", command]`.
- [x] Set cwd to `.`, trusted inactivity/output limits, and `mutation: :unknown`.
- [x] Derive exec-only Workspace Access.
- [x] Pass a synchronous sink that accepts bounded events without logging payloads.
- [x] Let only the static Dispatcher call `Workspace.run/4` for a fixed ProcessSpec.
- [x] Do not expose executable, argv, cwd, environment, stdin, mutation class,
  secret injection, or background-process controls to model arguments.

### Result And Failure

- [x] Map natural exit zero to Tool success.
- [x] Map natural non-zero exit to Tool error with known process evidence.
- [x] Preserve exit code, elapsed time, raw output bytes, Workspace truncation, and
  Tool presentation truncation.
- [x] Map pre-start cancellation/deadline/start failure according to Workspace
  known outcome.
- [x] Map every forced stop after unknown-footprint start to ambiguous.
- [x] Preserve inactivity, timeout, output limit, sink failure, runner failure,
  owner death, and backend failure classifications where safely available.
- [x] Never retry Bash automatically.

### Tests With Fake Workspace

- [x] Exact ProcessSpec including `/bin/bash`, `-lc`, `.`, and `:unknown`.
- [x] Default, lowered, maximum, and invalid timeout.
- [x] Empty, NUL-containing, exact-limit, and oversized command.
- [x] Started/output event acceptance without content logging.
- [x] Exit zero and natural non-zero exit.
- [x] Empty, multiline, binary-invalid, control-containing, and large output.
- [x] Pre-start cancellation and deadline.
- [x] Post-start cancellation, timeout, inactivity, output limit, sink failure, and
  runner failure as ambiguous.
- [x] Result/event operation identity correlation through Workspace facade.
- [x] Denied capability and Workspace exec denial.
- [x] Prepare failure is pre-dispatch; dispatch failure is conservative ambiguity;
  presentation failure preserves the retained process outcome.
- [x] No Fake script replay.

### Real Workspace Integration

- [x] Run a harmless command in a synthetic temporary root.
- [x] Verify cwd without exposing the absolute path in generated metadata.
- [x] Verify exit zero, non-zero, output, and elapsed evidence.
- [x] Verify synthetic provider/cloud/GitHub/SSH environment values are absent.
- [x] Verify cancellation and timeout clean the owned direct command on the
  supported platform.
- [x] Verify unknown-footprint forced stop returns ambiguous.
- [x] Confirm Tool source calls no System, Port, MuonTrap, or File API directly.

### Documentation And Learning

- [x] Add success, non-zero, cancellation, and ambiguity examples.
- [x] Explain why Bash explicitly uses a shell while Workspace uses separated argv.
- [x] Explain why model-facing Bash always declares unknown mutation footprint.
- [x] Explain same-user filesystem/network authority and descendant limitations.
- [x] Explain raw-output and model-visible presentation bounds.
- [x] Explain why generic Bash receives no secrets.

### Phase Complete When

- [x] Model input cannot alter trusted process policy outside command and lowered
  timeout.
- [x] Known exits and uncertain forced stops are never conflated.
- [x] Child output and environment are bounded and never logged by Tool.
- [x] Fake and supported-platform Real adapter tests pass.

## Phase 9: Deterministic Integration And Live Schema Acceptance

### Provider To Tool Integration

- [x] Build one successful Provider Response containing each FunctionCall shape.
- [x] Convert complete FunctionCall output items to Tool Calls.
- [x] Prove Provider output-item ID remains in Agent-side fixture data only.
- [x] Execute each Tool Call through Executor and Fake Workspace.
- [x] Project each Result content into a matching `function_call_output` fixture.
- [x] Preserve exact call IDs through Provider call, Tool Result, and continuation.
- [x] Never execute calls from a failed, interrupted, or incomplete Provider turn.

### Multi-Operation Scenario

- [x] Script `read -> write -> bash` through Fake Workspace.
- [x] Script `read -> edit -> bash` through Fake Workspace.
- [x] Invoke Executor sequentially in source order from a test harness.
- [x] Assert exact request/context/result order and Fake script exhaustion.
- [x] Assert unknown, invalid, denied, and ordinary failed calls remain pairable.
- [x] Assert ambiguity prevents admission of later operations in the integration
  harness without pretending a complete Agent Loop exists.

### Live Tokamak Schema Test

- [x] Mark the test `:live_tokamak` and exclude it by default.
- [x] Require runtime `TOKAMAK_API_KEY` and `SYNAPSE_MODEL`.
- [x] Send one request exposing all four exact registry specifications.
- [x] Ask for one harmless function call but do not execute it against a real root.
- [x] Receive a successful terminal Provider Response.
- [x] Confirm the returned name is statically registered and arguments form a
  bounded string-keyed map.
- [x] Store no live body, identifier, prompt output, or credential in fixtures.
- [x] Keep ordinary Tool tests network- and credential-free.

### Boundary Audits

- [x] Static search confirms Tool modules call no File, System, Port, MuonTrap, Req,
  Agent, Runtime, or CLI APIs.
- [x] Every deterministic adapter operation appears as one expected Fake Workspace
  entry.
- [x] Real tests use only synthetic temporary roots and commands.
- [x] No deterministic integration test depends on concurrent-sender order or
  wall-clock sleeps; lifecycle Real tests poll bounded observable conditions.

### Documentation And Learning

- [x] Add complete Provider-call-to-continuation sequence diagram.
- [x] Explain what this integration proves and what remains for Agent Loop.
- [x] Explain why successful ToolCallCompleted progress is still insufficient until
  Provider returns a successful terminal Response.
- [x] Explain why live schema acceptance does not prove Workspace safety.

### Phase Complete When

- [x] Every built-in executes deterministically through a Fake Workspace.
- [x] Every submitted call has a matching Result and continuation call ID.
- [x] All four exact schemas are accepted by the Tokamak Codex pool.
- [x] No incomplete or failed Provider call is executable.
- [x] Tool System has no direct host-access bypass.

## Phase 10: Reliability, Security, And ExDoc Review

### Limits And Failure Injection

- [x] Bound every Call, argument, schema, registry, Context, Result, metadata,
  diagnostic, line list, diff, command, process output, and timeout.
- [x] Reject integer overflow and unreasonable trusted limits.
- [x] Inject unknown name, denied capability, validator failure, Workspace error,
  callback exception/throw/exit, malformed Result, and presentation failure.
- [x] Inject failures before dispatch, during Workspace operation, and after a
  trustworthy terminal result.
- [x] Prove not-applied versus ambiguous classification for every mutating stage.
- [x] Stress many unique unknown names without atom growth.
- [x] Stress repeated large calls and Results without retained state growth.
- [x] Confirm Executor starts no process, queue, ETS table, or global registry.

### Security Review

- [x] Search Tool structs for raw roots, environments, Ports, backend state, and
  credentials.
- [x] Search logging and inspection paths for arguments, file content, command,
  output, Handle, operation ID, metadata, and exception text.
- [x] Test redaction with recognizable synthetic credentials and paths.
- [x] Confirm output intentionally returned by Workspace remains model-visible and
  is not falsely described as secret-free.
- [x] Confirm no model input creates atoms, modules, dispatch functions, the fixed
  `ProcessSpec.executable`/argv structure, capability values, or Workspace
  authority. Bash shell source retains documented same-user ambient execution.
- [x] Confirm Bash is documented as same-user ambient authority, not a sandbox.
- [x] Confirm unsupported dynamic or security behavior fails closed.
- [x] Confirm generic Bash has no credential-injection path.

### Documentation

- [x] Every public Tool module has `@moduledoc`.
- [x] Every public function and callback has purpose-oriented `@doc` and `@spec`.
- [x] Every public struct has `t()` and documented ownership of each field.
- [x] Add Tool modules to ExDoc groups.
- [x] Add `docs/learning/TOOL-SYSTEM.md` as a complete maintenance guide.
- [x] Add boundary, registry, capability, read-revision, mutation, Bash ambiguity,
  and continuation diagrams.
- [x] Add examples for all schemas, Calls, Results, capabilities, every built-in,
  errors, ambiguity, cancellation, and Fake integration.
- [x] Update `README.md`, `PLAN.md`, Provider fixtures, and status documentation.
- [x] Correct stale namespace or architecture text discovered by the final audit.
- [x] Document all capability, output, shell, host-authority, and deferred-feature
  limitations.

### Comprehension Gate

- [x] Can the owner explain why Provider progress events do not execute tools?
- [x] Can the owner distinguish Provider item ID, call ID, and operation ID?
- [x] Can the owner identify where model arguments first become valid Tool input?
- [x] Can the owner prove schema and runtime-validator parity?
- [x] Can the owner explain why schema omission is not capability enforcement?
- [x] Can the owner trace capability reduction into Workspace Access?
- [x] Can the owner trace Read offset to Workspace line and back to next offset?
- [x] Can the owner trace a revision from Read into Write or Edit?
- [x] Can the owner distinguish invalid, denied, failed, and ambiguous calls?
- [x] Can the owner explain natural Bash failure versus forced-stop ambiguity?
- [x] Can the owner identify exactly which Tool data enters the next Provider
  request?
- [x] Can the owner test every tool without network or host side effects?
- [x] Can the owner list all deferred Tool capabilities?

### Phase Complete When

- [x] Reliability and security tests pass.
- [x] No unbounded Tool parser, encoder, accumulator, registry, queue, or retained
  operation state remains.
- [x] No Tool-generated log, inspection, error, fixture, or example exposes a
  credential, absolute host path, raw content, command, or process output.
- [x] Model-visible content is bounded, valid UTF-8 JSON and explicitly treated as
  untrusted evidence.
- [x] `mix docs` succeeds without Tool documentation warnings.
- [x] All examples and doctests pass.
- [x] Tool System can be maintained without the original design conversation.

## Test Matrix

| Layer | Primary proof | Host/network side effects |
| --- | --- | --- |
| Contracts and Limits | Unit tests and doctests | None |
| Specs and Registry | Exact fixtures and atom-safety tests | None |
| Executor and capability | Static modules and Fake Workspace | None |
| Presentation | Boundary/property-style tests | None |
| Read adapter | Fake Workspace | None |
| Write adapter | Fake Workspace | None |
| Edit adapter | Fake Workspace | None |
| Bash adapter | Fake Workspace | None |
| Real adapter boundary | Temporary Workspace roots/processes | Temporary only |
| Provider continuation | Provider fixtures/Fake and Workspace Fake | None |
| Tokamak schema acceptance | Opt-in live test | HTTPS, no tool execution |
| ExDoc | Documentation build and doctests | None |

## Current Test Layout

```text
test/
  tool_limits_test.exs
  tool_contracts_test.exs
  tool_specifications_test.exs
  tool_registry_test.exs
  tool_executor_test.exs
  tool_presentation_test.exs
  tool_read_test.exs
  tool_write_test.exs
  tool_edit_test.exs
  tool_bash_test.exs
  tool_integration_test.exs
  tool_phase10_test.exs
  live_tool_schema_test.exs
```

Prefer small readable fixtures and programmatically generated boundary data.
Result fixtures may use synthetic `wsr1` revisions created through public
constructors. Never store machine-specific paths, captured environments, live
response IDs, credentials, or opaque process transcripts.

## Suggested Commit Sequence

1. `Define Tool contracts and limits`
2. `Add canonical Tool specifications`
3. `Add static Tool registry and capabilities`
4. `Dispatch paired Tool calls`
5. `Bound Tool result presentation`
6. `Adapt bounded Workspace reads`
7. `Adapt revision-checked writes`
8. `Adapt exact revision-checked edits`
9. `Adapt bounded Bash commands`
10. `Verify and document Tool System`

Each commit must compile, pass focused tests, and include documentation for its
public behavior and limitations.

## Final Tool System Verification

```bash
mix format
mix format --check-formatted
mix compile --warnings-as-errors
mix test --warnings-as-errors
mix docs
mix deps.unlock --check-unused
mix hex.outdated
```

The opt-in live schema verification is:

```bash
TOKAMAK_API_KEY="..." \
SYNAPSE_MODEL="..." \
mix test --only live_tokamak test/live_tool_schema_test.exs
```

The live test must never execute a returned call against a user checkout.

## Tool System Definition Of Done

- [x] Phases 0 through 10 are complete.
- [x] Tool System boundary matches `PLAN.md`.
- [x] Agent owns successful-response selection, source-order iteration, Run Events,
  and conversation continuation.
- [x] Executor accepts one complete Call and returns one paired Result.
- [x] Provider item ID, call ID, and Workspace operation ID remain distinct.
- [x] Registry contains exactly Read, Write, Edit, and Bash in stable order.
- [x] Unknown model names cannot create atoms or dispatch arbitrary modules.
- [x] Exact schemas are accepted by Tokamak and match runtime validators.
- [x] Every capability is trusted application data and checked before dispatch.
- [x] Workspace receives an exact reduced Access value for every operation.
- [x] All host access delegates only through Workspace.
- [x] Read returns bounded numbered lines, revision, and continuation.
- [x] Write supports explicit missing creation or current-revision replacement only.
- [x] Edit supports exactly one literal current-revision replacement only.
- [x] Bash uses fixed shell policy and is documented as same-user execution.
- [x] Every model-visible Result is bounded valid UTF-8 JSON.
- [x] Natural failures, known not-applied outcomes, and ambiguity remain distinct.
- [x] No mutating or unknown-footprint operation is automatically replayed.
- [x] Deterministic tests require no live key or real host side effects.
- [x] ExDoc explains schemas, registry, capabilities, validation, adapters, output,
  cancellation, failures, ambiguity, security, and deferred work.
- [x] The owner can maintain Tool System without the original AI conversation.

## Deferred Tool System Work

Do not add these before the MVP Tool System is complete:

- Search, glob, grep, list, tree, delete, rename, copy, move, append, patch, or
  multi-file tools.
- Dynamic tool registration, extension generations, hot reload, MCP, remote tools,
  or external executable adapters.
- Tool search, activation, ranking, or progressive schema disclosure.
- Parallel, shared, exclusive, batched, or dependency-aware Tool execution.
- Run Events, event persistence, terminal rendering, telemetry, or billing.
- Final source/user/project/workflow-scoped unforgeable capability tokens.
- Approval prompts, interactive tools, delegated subagent capabilities, or policy
  escalation.
- Credential-broker secret injection into commands or tools.
- Command templates, executable allowlists, network-origin policy, or broker-owned
  HTTP tools.
- PTY, stdin, terminal emulation, background jobs, or daemon management.
- Filesystem, network, syscall, CPU, memory, process-count, container, VM, or OS-user
  sandboxing.
- Artifact spill for large output and durable artifact references.
- Secret-pattern filtering or exact-value redaction of returned read/process data.
- Repository diff scans and mutation attribution after Bash.
- Language-specific linting, formatting, syntax validation, or automatic edit
  rollback.
- Automatic retry of read-only tools or fresh-worktree attempt retries.
- Durable Tool call/result persistence and crash recovery.
- Tool aliases, schema versions, negotiation, deprecation, or provider-specific
  schema variants.

These features should reuse the Call, Result, Spec, Context, capability, registry,
presentation, Workspace adapter, and ambiguity contracts established by this
checklist rather than bypassing them.
