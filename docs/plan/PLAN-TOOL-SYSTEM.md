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
| 0 | Confirm boundaries, schemas, limits, and failure decisions | In progress |
| 1 | Tool contracts, limits, and behavior | Not started |
| 2 | Canonical specifications and static registry | Not started |
| 3 | Capabilities, context, and Executor | Not started |
| 4 | Bounded result presentation and failure mapping | Not started |
| 5 | Read tool | Not started |
| 6 | Write tool | Not started |
| 7 | Edit tool | Not started |
| 8 | Bash tool | Not started |
| 9 | Deterministic integration and live schema acceptance | Not started |
| 10 | Reliability, security, and ExDoc review | Not started |

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
                 | validate and adapt one operation |
                 +----------------+-----------------+
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
  -> one built-in Tool
  -> Workspace public facade

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
- Tool capability checks occur before built-in dispatch; Workspace Access is
  still reduced and checked again as defense in depth.
- All file and process access goes through the public Workspace facade.
- Read is read-only, Write and Edit are mutations, and Bash has unknown mutation
  footprint.
- Bash always maps to `/bin/bash`, `-lc`, workspace cwd `.`, and
  `mutation: :unknown`. The model cannot select executable, argv structure, cwd,
  environment, mutation class, or secrets.
- No Tool or Executor automatically retries a Workspace operation.
- Workspace `outcome: :unknown` always becomes Tool `status: :ambiguous`.
- A malformed return, exception, throw, or exit after dispatch to Write, Edit, or
  Bash is conservatively ambiguous unless a trustworthy Workspace terminal result
  was already retained and deterministic presentation can complete.
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
access for the selected Tool; a Tool Context never raises the Workspace handle's
access ceiling.

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
| Error message bytes | 512 | Fixed model-visible diagnostic text |
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
- The 64,000-byte argument limit includes keys, punctuation, quotes, and escaped
  string representation, not only decoded string bytes.
- Tool does not advertise Workspace's 8 MiB file ceiling as model-call capacity.
  A larger content transfer mechanism is post-MVP.
- Result size is measured after status, keys, revisions, messages, line numbers,
  truncation markers, UTF-8 replacement, and JSON escaping.
- Presentation builds bounded valid JSON incrementally. It never byte-slices a
  completed JSON string into invalid syntax.
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
    {"number": 1, "text": "defmodule Example do", "ending": "lf", "truncated": false}
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
`status: "error"`.

An ordinary error contains:

```json
{
  "status": "error",
  "tool": "edit",
  "error": {
    "kind": "workspace",
    "reason": "stale_revision",
    "message": "Workspace file changed after it was read",
    "outcome": "not_applied",
    "path": "lib/example.ex"
  }
}
```

An uncertain side effect uses `status: "ambiguous"` and
`outcome: "unknown"`. The message tells the model and caller to inspect current
workspace state and never retry blindly. Errors expose only stable Tool or
Workspace classifications, bounded fixed messages, normalized relative paths,
and allowlisted numeric details. They never expose raw exception text.

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
| Write/Edit/Bash callback crash or malformed return after dispatch can begin | `:ambiguous` | Tool cannot prove side-effect outcome |
| Read callback crash or malformed return | `:error` | Read has no Tool-owned mutation |
| Result presentation failure after a retained known Workspace result | Preserve known outcome using bounded fallback | Do not invent uncertainty if the terminal result is trustworthy |

Tuple shape does not carry terminal meaning. `Executor.execute/2` always returns a
validated `Tool.Result`; callers inspect `status`. Ambiguity terminates the MVP run
at Agent level and is never automatically replayed.

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
| Tool presentation helper | Bounded deterministic model-visible JSON |
| `Synapse.Tool.Read` | Read argument validation and Workspace adapter |
| `Synapse.Tool.Write` | Write argument validation and Workspace adapter |
| `Synapse.Tool.Edit` | Edit argument validation and Workspace adapter |
| `Synapse.Tool.Bash` | Fixed Bash ProcessSpec adapter |

Closely related contracts may share a source file while they remain readable. Do
not create empty modules ahead of their phase. Presentation and validation helpers
should remain internal unless another implemented component has a real reuse case.

## Proposed Public Boundary

```elixir
@callback specification() :: Synapse.Tool.Spec.t()

@callback execute(
  Synapse.Tool.Call.t(),
  Synapse.Tool.Context.t()
) :: Synapse.Tool.Result.t()

Synapse.Tool.Registry.specifications()
Synapse.Tool.Registry.fetch(tool_name)
Synapse.Tool.Call.from_provider(function_call)
Synapse.Tool.Executor.execute(tool_call, tool_context)
```

The proposed registry lookup returns only a module present in the compiled static
table.
Built-in callbacks are invoked through Executor in production. Executor validates
the call and Context, checks the Spec capability, invokes the known implementation,
then validates the returned Result and its call pairing before returning it.

No public bang API, dynamic registration API, batch execution API, or arbitrary
module execution API is part of the MVP.

## Phase 0: Confirm Decisions And Prerequisites

### Architecture

- [ ] Confirm Tool remains between Agent and Workspace with no reverse dependency.
- [ ] Confirm Agent owns successful Provider-response selection, multi-call source
  order, Run Events, and conversation continuation.
- [ ] Confirm Executor owns exactly one synchronous call and one paired result.
- [ ] Confirm no Runtime process or GenServer is required for Tool System itself.
- [ ] Confirm built-in host access can use only the Workspace public facade.
- [ ] Confirm search, dynamic registration, parallel tools, and extensions remain
  outside this MVP.

### Contracts

- [ ] Confirm `call_id`, Provider item ID, and Workspace operation ID remain
  separate.
- [ ] Confirm the one-Result algebra and `:ok | :error | :ambiguous` statuses.
- [ ] Confirm Agent sends only `Result.content` as function-call output.
- [ ] Confirm string-keyed model arguments and metadata.
- [ ] Confirm exact result JSON envelopes and deterministic key order.
- [ ] Confirm ordinary invalid arguments are pairable Tool errors.
- [ ] Confirm an unconstructable Call is an Agent input-contract failure.

### Schemas

- [ ] Update the Provider all-tools fixture to the exact schemas in this plan.
- [ ] Verify strict nullable optional fields through Provider Request and
  ResponsesCodec tests.
- [ ] Run an opt-in live request exposing all four exact schemas.
- [ ] Record whether Tokamak accepts nullable type arrays, integer bounds, strict,
  and `additionalProperties: false`.
- [ ] Resolve any unsupported schema keyword before implementation begins.
- [ ] Confirm runtime validators accept exactly the model-visible field set.

### Capabilities And Operations

- [ ] Confirm the fixed three-field CapabilitySet and one-workspace scope.
- [ ] Confirm the exact Spec capability and Workspace Access mapping.
- [ ] Confirm Context carries the trusted Workspace operation ID and lifetime data.
- [ ] Confirm `process_exec` is same-user ambient authority, not root confinement.
- [ ] Confirm generic Bash receives no credential-broker injection.

### Limits And Failure

- [ ] Confirm every initial Tool limit and accounting rule in this plan.
- [ ] Confirm Provider's 64,000-byte argument/output limits against current code.
- [ ] Confirm Workspace ceilings used by each adapter.
- [ ] Confirm presentation clipping versus Workspace output-limit termination.
- [ ] Confirm natural non-zero Bash exit is Tool error with known process evidence.
- [ ] Confirm forced unknown-footprint process stop remains ambiguous.
- [ ] Confirm conservative post-dispatch callback-crash classification.
- [ ] Confirm no hidden Tool retry under any terminal status.

### Documentation And Learning

- [ ] Add this plan to ExDoc extras and Plans navigation.
- [ ] Cross-link this plan from the Tool System section in `PLAN.md`.
- [ ] Record all accepted limitations before implementation begins.
- [ ] Explain why schemas do not replace runtime validation.
- [ ] Explain why capability omission from a turn does not replace enforcement.
- [ ] Explain why Tool and Workspace enforce different layers of authority.
- [ ] Explain why Bash output-limit termination can be ambiguous.

### Phase Complete When

- [ ] No unresolved decision can change Call, Result, Spec, Context,
  CapabilitySet, Limits, the four schemas, or Agent-facing terminal semantics.
- [ ] Tokamak accepts the selected schema subset in an opt-in live test.
- [ ] Parent architecture, Provider fixtures, Workspace contracts, and this plan
  agree.
- [ ] Exact limits and resource rationale are recorded.

## Phase 1: Tool Contracts, Limits, And Behavior

### Call

- [ ] Implement `Tool.Call` with `call_id`, `name`, and string-keyed `arguments`.
- [ ] Validate bounded non-empty UTF-8 call ID and name.
- [ ] Validate argument entry count, depth, JSON types, UTF-8, and encoded bytes.
- [ ] Reject unknown fields, atom keys, improper lists, tuples, PIDs, references,
  functions, and non-JSON terms.
- [ ] Implement conversion from complete Provider FunctionCall output items.
- [ ] Do not retain Provider item ID in Call.
- [ ] Redact arguments under ordinary inspection.

### Result

- [ ] Implement paired call ID, status, content, and metadata.
- [ ] Validate status and exact model-visible content byte ceiling.
- [ ] Validate metadata entry, depth, key, value, and encoded-byte ceilings.
- [ ] Require valid UTF-8 content containing one JSON object.
- [ ] Reject secret-shaped or content-bearing metadata keys where practical.
- [ ] Redact content and metadata under ordinary inspection.
- [ ] Provide constructors for successful, ordinary-error, and ambiguous results
  without allowing inconsistent status/outcome combinations.

### Spec And Behavior

- [ ] Implement Spec fields for name, description, parameters, capability, and
  effect.
- [ ] Use only fixed capability values `:fs_read`, `:fs_write`, and
  `:process_exec` created by application code.
- [ ] Use only fixed effect values `:read_only`, `:mutation`, and `:unknown`.
- [ ] Validate complete flat Responses schema shape and bytes.
- [ ] Define Tool callbacks with documented pairing, validation, side-effect,
  exception, and retry semantics.
- [ ] Keep tool implementation module identity out of model-visible Spec data.

### Context, Capabilities, And Limits

- [ ] Implement fixed boolean CapabilitySet fields.
- [ ] Implement trusted Context with Handle, CapabilitySet, operation ID,
  cancellation, deadline, activity sink, and Limits.
- [ ] Revalidate the opaque Workspace Handle structurally without exposing state.
- [ ] Validate cancellation references, monotonic deadlines, and sink arity.
- [ ] Implement all Tool limits with defaults and hard ceilings.
- [ ] Allow trusted callers to lower but never raise hard ceilings.
- [ ] Redact Handle, operation ID, references, sinks, and limits under Context
  inspection.

### Tests

- [ ] Constructor success for every contract.
- [ ] Unknown fields and missing required fields.
- [ ] Every boundary at minimum, maximum, and one beyond maximum.
- [ ] Canonical argument encoding includes escaping overhead.
- [ ] Invalid UTF-8, NUL where forbidden, deep maps, broad maps, and improper data.
- [ ] Provider FunctionCall conversion preserves call ID and arguments.
- [ ] Provider item ID never appears in Call or Result.
- [ ] Content-bearing contract inspection is redacted.
- [ ] Constructors and doctests contain no real paths, commands, or credentials.

### Documentation And Learning

- [ ] Add `@moduledoc`, `@doc`, `@spec`, `@typedoc`, and `t()` for every public
  contract and callback.
- [ ] Explain who creates and consumes every field.
- [ ] Explain trusted Context versus model-derived Call.
- [ ] Explain why Result status is data rather than tuple shape.
- [ ] Explain why Call cannot use Provider output-item ID as operation ID.

### Phase Complete When

- [ ] Contracts compile with warnings as errors.
- [ ] Contract tests and doctests pass.
- [ ] No registry or Workspace execution exists yet.
- [ ] LSP hover explains ownership, bounds, redaction, and valid fields.

## Phase 2: Canonical Specifications And Static Registry

### Specifications

- [ ] Implement exact Read, Write, Edit, and Bash Specs from this plan.
- [ ] Keep registry order deterministic: Read, Write, Edit, Bash.
- [ ] Use concise descriptions that state side effects, revision requirements,
  continuation, and Bash sandbox limitations.
- [ ] Require strict mode and reject additional properties.
- [ ] Keep runtime validator fields and schema properties in one reviewed parity
  table or mechanically shared source without making schemas dynamic.
- [ ] Validate aggregate schema count and bytes before Provider use.

### Registry

- [ ] Implement one immutable compiled table from exact string names to modules.
- [ ] Implement deterministic `specifications/0` and string `fetch/1`.
- [ ] Reject duplicate names and mismatched module specifications at compile or
  test time.
- [ ] Return unknown for all non-string and unregistered input.
- [ ] Never call `String.to_atom/1`, `Module.concat/1`, `binary_to_atom`, or dynamic
  `apply` using a model-derived module/function value.
- [ ] Do not add runtime registration, process state, ETS, persistent term, or an
  extension hook.

### Tests

- [ ] Exact specification fixture for every tool.
- [ ] Aggregate all-tools fixture equality and deterministic order.
- [ ] ResponsesCodec accepts and encodes every specification unchanged.
- [ ] Required/property parity and nullable optional-field parity.
- [ ] Additional properties rejected by every runtime validator.
- [ ] Unknown string, empty string, invalid UTF-8, overlong name, and non-string
  lookup.
- [ ] Atom-count regression using many unique unknown names.
- [ ] Static source audit for dynamic atom/module creation.

### Documentation And Learning

- [ ] Explain why a registry is safer than module dispatch from a string.
- [ ] Explain schema guidance versus authoritative runtime validation.
- [ ] Document deterministic ordering and why dynamic tools are deferred.
- [ ] Add an ExDoc example obtaining Provider-ready specifications.

### Phase Complete When

- [ ] The four generated schemas match reviewed fixtures exactly.
- [ ] Provider encoding tests pass without network access.
- [ ] No model string can select an arbitrary module or create an atom.
- [ ] Registry has no mutable process or global state.

## Phase 3: Capabilities, Context, And Executor

### Authorization

- [ ] Map Read to `fs_read`, Write/Edit to `fs_write`, and Bash to
  `process_exec`.
- [ ] Reject a denied call before invoking the built-in module.
- [ ] Derive exact reduced Workspace Access for the selected operation.
- [ ] Build Workspace OperationContext from trusted Tool Context lifetime fields.
- [ ] Preserve operation ID, cancellation reference, deadline, and activity sink.
- [ ] Never read a capability from Call arguments, Spec JSON, or model content.

### Dispatch

- [ ] Revalidate Call and Context at Executor entry.
- [ ] Look up only through the static Registry.
- [ ] Invoke one known module synchronously.
- [ ] Validate returned Result shape, status, bounds, and matching call ID.
- [ ] Return unknown, denied, malformed-return, and callback-failure Results with
  fixed bounded diagnostics.
- [ ] Track the selected Spec effect for conservative crash classification.
- [ ] Perform no retry and start no unowned Task.
- [ ] Expose no batch or parallel dispatch path.

### Pairing And Failure

- [ ] Preserve exact call ID for successful and failed calls.
- [ ] Unknown name returns paired `unknown_tool` error.
- [ ] Denied capability returns paired `capability_denied` error.
- [ ] Invalid built-in arguments return paired `invalid_arguments` error.
- [ ] Read callback crash returns internal error.
- [ ] Write, Edit, or Bash callback crash after dispatch can begin returns
  ambiguous unless a known terminal result was retained.
- [ ] A malformed mutating callback Result cannot be downgraded to ordinary error.
- [ ] Sink failure and Workspace ambiguity retain the Workspace uncertainty.

### Tests

- [ ] Known tool dispatch and exact module selection.
- [ ] Unknown and disabled tools.
- [ ] Missing Tool capability.
- [ ] Workspace Handle access denial as defense in depth.
- [ ] Exact operation access reduction for every tool.
- [ ] Matching operation ID and cancellation/deadline propagation.
- [ ] Result call-ID mismatch and malformed result rejection.
- [ ] Callback exception, throw, exit, and invalid return by effect class.
- [ ] No Fake Workspace entry consumed by unknown, invalid, or denied calls.
- [ ] No hidden retry after any failure.
- [ ] Concurrent direct calls share no Executor state.

### Documentation And Learning

- [ ] Add registry, authorization, and dispatch sequence diagrams.
- [ ] Explain why omission from model schemas is usability, not authorization.
- [ ] Explain why Workspace repeats access enforcement.
- [ ] Explain why synchronous execution simplifies ordering and cancellation.
- [ ] Explain why Agent, not Executor, owns multiple-call source order.

### Phase Complete When

- [ ] Every submitted valid Call receives one paired bounded Result.
- [ ] Pre-dispatch rejections cannot reach Workspace.
- [ ] Authority can only decrease from Context through Workspace operation access.
- [ ] Unexpected mutating failures are never reported as known not-applied without
  proof.

## Phase 4: Bounded Presentation And Failure Mapping

### Presentation

- [ ] Implement deterministic key-ordered JSON output.
- [ ] Account for all JSON quotes, separators, escaping, replacement characters,
  and fixed envelope bytes.
- [ ] Keep every completed content string valid UTF-8 and valid JSON.
- [ ] Build under a byte budget rather than encoding unbounded data then slicing.
- [ ] Implement structural truncation for line lists, line text, diffs, and process
  output.
- [ ] Distinguish Workspace truncation from Tool presentation truncation.
- [ ] Preserve required revisions and continuation fields even when optional
  evidence is clipped.
- [ ] Add a bounded fallback for unexpected presentation failure without exposing
  exceptions.

### Workspace Errors

- [ ] Map `outcome: :unknown` only to Tool `:ambiguous`.
- [ ] Map all known Workspace outcomes to ordinary Tool error.
- [ ] Preserve stable kind, reason, fixed message, normalized relative path, and
  allowlisted safe details.
- [ ] Do not copy Workspace operation ID into model-visible output.
- [ ] Do not copy arbitrary details, exception messages, backend state, or raw
  inspection output.
- [ ] Preserve stale revision, expected missing, no match, multiple matches,
  access denial, cancellation, deadline, and output-limit distinctions.

### Process Output

- [ ] Replace invalid UTF-8 sequences deterministically.
- [ ] Escape terminal control data through model-visible JSON.
- [ ] Retain raw byte count separately from presented UTF-8 bytes.
- [ ] Never log raw or converted process output.
- [ ] Document that Tool does not and cannot guarantee secret removal from output.

### Tests

- [ ] Empty, exact-limit, and one-byte-over content.
- [ ] Worst-case JSON escaping with quotes, slashes, controls, and multibyte UTF-8.
- [ ] Invalid process UTF-8 split at every replacement boundary.
- [ ] Broad lines, one huge line, many tiny lines, large diff, and large output.
- [ ] Valid JSON under every truncation path.
- [ ] Required identity and revision fields survive presentation pressure.
- [ ] Every Workspace error kind/reason/outcome mapping used by built-ins.
- [ ] Synthetic exception text absent from Results and Logger output.
- [ ] Recognizable synthetic credentials absent unless intentionally supplied as
  Workspace read/process result content.

### Documentation And Learning

- [ ] Add result envelope examples for success, error, and ambiguity.
- [ ] Explain raw bytes, valid UTF-8, JSON escaping, and model-visible bytes.
- [ ] Explain why presentation clipping after natural exit differs from stopping a
  running Bash command at its output ceiling.
- [ ] Explain what redaction can and cannot guarantee.

### Phase Complete When

- [ ] No model-visible Tool output can exceed the configured final byte ceiling.
- [ ] No truncation path produces malformed UTF-8 or JSON.
- [ ] Workspace uncertainty is preserved mechanically.
- [ ] No raw exception, environment, Handle, absolute root, or backend state can
  enter generated diagnostics.

## Phase 5: Read Tool

### Arguments And Mapping

- [ ] Require exact fields `path`, `offset`, and `limit`.
- [ ] Require relative UTF-8 path and reject invalid values before Workspace.
- [ ] Normalize `offset: null` to zero and `limit: null` to the trusted default.
- [ ] Reject negative offset, zero limit, overflow in `offset + 1`, and limits above
  Tool or Workspace ceilings.
- [ ] Map `start_line = offset + 1` and `line_count = limit`.
- [ ] Select a trusted `max_bytes` no higher than Workspace or Tool limits.
- [ ] Derive read-only Workspace Access.
- [ ] Call only `Workspace.read/3`.

### Result

- [ ] Return normalized relative path and canonical encoded revision.
- [ ] Return explicit line number, text, ending, and source truncation per line.
- [ ] Return `next_offset` or null at EOF.
- [ ] Return complete file byte count and presentation truncation state.
- [ ] Preserve direct line numbers to reduce model arithmetic and cognitive load.
- [ ] Never expose absolute root or internal revision representation.

### Tests With Fake Workspace

- [ ] Exact default request and read-only Context.
- [ ] Zero and non-zero offsets.
- [ ] Lowered and maximum line limits.
- [ ] Empty file, EOF, LF, CRLF, mixed ending, and no final newline.
- [ ] Workspace-clipped long line and Tool presentation-clipped line.
- [ ] Dropped trailing lines update continuation to the first omitted line.
- [ ] Revision encoding and later parse compatibility.
- [ ] Invalid path, denied capability, Workspace denial, cancellation, and deadline.
- [ ] No Workspace entry consumed for invalid arguments or missing capability.

### Real Workspace Integration

- [ ] Read a synthetic temporary text file through Tool Executor.
- [ ] Confirm numbered lines, revision, continuation, and bounded content.
- [ ] Confirm traversal, symlink, non-regular, invalid UTF-8, and oversized-file
  failures remain structured Tool errors.
- [ ] Confirm Tool source calls no File API directly.

### Documentation And Learning

- [ ] Explain zero-based Tool offset versus one-based Workspace lines.
- [ ] Add examples for first window, continuation, EOF, and clipped line.
- [ ] Explain why 100 lines is the default ACI window.
- [ ] Explain why every mutation must use the returned revision.

### Phase Complete When

- [ ] Every Read call is bounded, numbered, revisioned, and directly continuable.
- [ ] Fake proves exact Workspace delegation without host access.
- [ ] Real temporary-root tests prove the complete adapter boundary.
- [ ] Model-visible output contains no absolute root.

## Phase 6: Write Tool

### Arguments And Mapping

- [ ] Require exact fields `path`, `content`, and `expected_revision`.
- [ ] Validate aggregate argument bytes before retaining or dispatching content.
- [ ] Map exact `"missing"` to Workspace `:missing`.
- [ ] Parse all other expectations through `Workspace.Revision.parse/1`.
- [ ] Reject malformed revisions before Workspace without claiming stale state.
- [ ] Build a WriteRequest with complete UTF-8 content.
- [ ] Derive write-only Workspace Access.
- [ ] Call only `Workspace.write/3`.
- [ ] Provide no blind-overwrite, append, directory creation, or automatic retry.

### Result

- [ ] Return relative path, previous revision, new revision, changed, bytes written,
  diff, Workspace diff truncation, and Tool presentation truncation.
- [ ] Encode creation previous revision as `"missing"`.
- [ ] Preserve no-op replacement as successful `changed: false`.
- [ ] Preserve stale, expected-existing, denied, limit, I/O, and ambiguity reasons.
- [ ] Tell the model to reread after stale conflict rather than retry old content.

### Tests With Fake Workspace

- [ ] Missing-file creation exact request and result.
- [ ] Existing-file replacement with parsed revision.
- [ ] Malformed, stale, cross-handle, and wrong-path revision behavior.
- [ ] Existing destination under `"missing"` expectation.
- [ ] Empty content, maximum argument envelope, and one byte beyond.
- [ ] No-op replacement.
- [ ] Workspace diff truncation and Tool presentation truncation.
- [ ] Denied capability and defense-in-depth Workspace access denial.
- [ ] Known not-applied error and ambiguous error.
- [ ] Callback crash/malformed return conservative ambiguity.
- [ ] No hidden replay under any failure.

### Real Workspace Integration

- [ ] Create a synthetic missing file through Tool Executor.
- [ ] Read its revision and replace it through Tool Executor.
- [ ] Verify stale replacement does not alter the file.
- [ ] Verify failed validation leaves original content unchanged.
- [ ] Verify successful output carries the committed revision.
- [ ] Confirm Tool source calls no File API directly.

### Documentation And Learning

- [ ] Add create and revision-checked replace examples.
- [ ] Explain why `"missing"` is an expectation, not overwrite permission.
- [ ] Explain stale, not-applied, committed, and ambiguous outcomes.
- [ ] Explain why Tool never retries a Write automatically.

### Phase Complete When

- [ ] Write supports only explicit create or current-revision replacement.
- [ ] Every successful result exposes the new revision and bounded diff evidence.
- [ ] Every uncertain outcome remains ambiguous.
- [ ] Fake and Real adapter tests pass.

## Phase 7: Edit Tool

### Arguments And Mapping

- [ ] Require exact fields `path`, `old_text`, `new_text`, and
  `expected_revision`.
- [ ] Require non-empty old text and permit empty new text.
- [ ] Validate aggregate argument bytes and UTF-8.
- [ ] Parse only canonical `wsr1` revisions; `"missing"` is invalid for Edit.
- [ ] Build one exact EditRequest without regex, fuzzy matching, or patch parsing.
- [ ] Derive write-only Workspace Access.
- [ ] Call only `Workspace.edit/3`.

### Result And Failure

- [ ] Return the same mutation evidence shape as Write.
- [ ] Preserve exactly-one-match semantics including overlapping matches.
- [ ] Preserve Workspace revision validation before match disclosure.
- [ ] Distinguish zero match, multiple matches, stale revision, and size failure.
- [ ] Preserve equal old/new exact-one match as successful no-op.
- [ ] Preserve post-dispatch uncertainty as ambiguous.
- [ ] Do not automatically reread, merge, rebase, or retry.

### Tests With Fake Workspace

- [ ] Exactly one match and changed result.
- [ ] Zero matches.
- [ ] Multiple and overlapping matches.
- [ ] Empty old text and empty new text.
- [ ] Equal old/new no-op.
- [ ] Malformed and stale revision.
- [ ] Generated content too large.
- [ ] Bounded diff and both truncation layers.
- [ ] Denied capability and Workspace access denial.
- [ ] Known not-applied versus ambiguous error.
- [ ] Callback crash/malformed return conservative ambiguity.

### Real Workspace Integration

- [ ] Read then edit one exact synthetic occurrence.
- [ ] Verify zero and multiple matches leave original unchanged.
- [ ] Verify stale edit leaves newer content unchanged.
- [ ] Verify successful output revision can drive a later edit.
- [ ] Confirm Tool source calls no File API directly.

### Documentation And Learning

- [ ] Add read-to-edit revision round-trip example.
- [ ] Explain literal exact matching and overlapping occurrence behavior.
- [ ] Explain why stale conflict is checked before match count.
- [ ] Explain why fuzzy edit and automatic stale merge are deferred.

### Phase Complete When

- [ ] Edit performs exactly one revision-checked literal replacement or none.
- [ ] No conflict path silently changes a file.
- [ ] Every known and uncertain outcome is mapped correctly.
- [ ] Fake and Real adapter tests pass.

## Phase 8: Bash Tool

### Arguments And Mapping

- [ ] Require exact fields `command` and `timeout_ms`.
- [ ] Require non-empty bounded UTF-8 command without NUL.
- [ ] Normalize `timeout_ms: null` to trusted default.
- [ ] Permit only a lower positive timeout within Tool and Workspace ceilings.
- [ ] Build exact executable `/bin/bash` and arguments `["-lc", command]`.
- [ ] Set cwd to `.`, trusted inactivity/output limits, and `mutation: :unknown`.
- [ ] Derive exec-only Workspace Access.
- [ ] Pass a synchronous sink that accepts bounded events without logging payloads.
- [ ] Call only `Workspace.run/4`.
- [ ] Do not expose executable, argv, cwd, environment, stdin, mutation class,
  secret injection, or background-process controls to model arguments.

### Result And Failure

- [ ] Map natural exit zero to Tool success.
- [ ] Map natural non-zero exit to Tool error with known process evidence.
- [ ] Preserve exit code, elapsed time, raw output bytes, Workspace truncation, and
  Tool presentation truncation.
- [ ] Map pre-start cancellation/deadline/start failure according to Workspace
  known outcome.
- [ ] Map every forced stop after unknown-footprint start to ambiguous.
- [ ] Preserve inactivity, timeout, output limit, sink failure, runner failure,
  owner death, and backend failure classifications where safely available.
- [ ] Never retry Bash automatically.

### Tests With Fake Workspace

- [ ] Exact ProcessSpec including `/bin/bash`, `-lc`, `.`, and `:unknown`.
- [ ] Default, lowered, maximum, and invalid timeout.
- [ ] Empty, NUL-containing, exact-limit, and oversized command.
- [ ] Started/output event acceptance without content logging.
- [ ] Exit zero and natural non-zero exit.
- [ ] Empty, multiline, binary-invalid, control-containing, and large output.
- [ ] Pre-start cancellation and deadline.
- [ ] Post-start cancellation, timeout, inactivity, output limit, sink failure, and
  runner failure as ambiguous.
- [ ] Result/event operation identity correlation through Workspace facade.
- [ ] Denied capability and Workspace exec denial.
- [ ] Callback crash/malformed return conservative ambiguity.
- [ ] No Fake script replay.

### Real Workspace Integration

- [ ] Run a harmless command in a synthetic temporary root.
- [ ] Verify cwd without exposing the absolute path in generated metadata.
- [ ] Verify exit zero, non-zero, output, and elapsed evidence.
- [ ] Verify synthetic provider/cloud/GitHub/SSH environment values are absent.
- [ ] Verify cancellation and timeout clean the owned direct command on the
  supported platform.
- [ ] Verify unknown-footprint forced stop returns ambiguous.
- [ ] Confirm Tool source calls no System, Port, MuonTrap, or File API directly.

### Documentation And Learning

- [ ] Add success, non-zero, cancellation, and ambiguity examples.
- [ ] Explain why Bash explicitly uses a shell while Workspace uses separated argv.
- [ ] Explain why model-facing Bash always declares unknown mutation footprint.
- [ ] Explain same-user filesystem/network authority and descendant limitations.
- [ ] Explain raw-output and model-visible presentation bounds.
- [ ] Explain why generic Bash receives no secrets.

### Phase Complete When

- [ ] Model input cannot alter trusted process policy outside command and lowered
  timeout.
- [ ] Known exits and uncertain forced stops are never conflated.
- [ ] Child output and environment are bounded and never logged by Tool.
- [ ] Fake and supported-platform Real adapter tests pass.

## Phase 9: Deterministic Integration And Live Schema Acceptance

### Provider To Tool Integration

- [ ] Build one successful Provider Response containing each FunctionCall shape.
- [ ] Convert complete FunctionCall output items to Tool Calls.
- [ ] Prove Provider output-item ID remains in Agent-side fixture data only.
- [ ] Execute each Tool Call through Executor and Fake Workspace.
- [ ] Project each Result content into a matching `function_call_output` fixture.
- [ ] Preserve exact call IDs through Provider call, Tool Result, and continuation.
- [ ] Never execute calls from a failed, interrupted, or incomplete Provider turn.

### Multi-Operation Scenario

- [ ] Script `read -> write -> bash` through Fake Workspace.
- [ ] Script `read -> edit -> bash` through Fake Workspace.
- [ ] Invoke Executor sequentially in source order from a test harness.
- [ ] Assert exact request/context/result order and Fake script exhaustion.
- [ ] Assert unknown, invalid, denied, and ordinary failed calls remain pairable.
- [ ] Assert ambiguity prevents admission of later operations in the integration
  harness without pretending a complete Agent Loop exists.

### Live Tokamak Schema Test

- [ ] Mark the test `:live_tokamak` and exclude it by default.
- [ ] Require runtime `TOKAMAK_API_KEY` and `SYNAPSE_MODEL`.
- [ ] Send one request exposing all four exact registry specifications.
- [ ] Ask for one harmless function call but do not execute it against a real root.
- [ ] Receive a successful terminal Provider Response.
- [ ] Confirm the returned name is statically registered and arguments form a
  bounded string-keyed map.
- [ ] Store no live body, identifier, prompt output, or credential in fixtures.
- [ ] Keep ordinary Tool tests network- and credential-free.

### Boundary Audits

- [ ] Static search confirms Tool modules call no File, System, Port, MuonTrap, Req,
  Agent, Runtime, or CLI APIs.
- [ ] Every host operation in adapter tests appears as one expected Fake Workspace
  entry.
- [ ] Real tests use only synthetic temporary roots and commands.
- [ ] No test depends on call order across concurrent senders or wall-clock sleeps.

### Documentation And Learning

- [ ] Add complete Provider-call-to-continuation sequence diagram.
- [ ] Explain what this integration proves and what remains for Agent Loop.
- [ ] Explain why successful ToolCallCompleted progress is still insufficient until
  Provider returns a successful terminal Response.
- [ ] Explain why live schema acceptance does not prove Workspace safety.

### Phase Complete When

- [ ] Every built-in executes deterministically through a Fake Workspace.
- [ ] Every submitted call has a matching Result and continuation call ID.
- [ ] All four exact schemas are accepted by the Tokamak Codex pool.
- [ ] No incomplete or failed Provider call is executable.
- [ ] Tool System has no direct host-access bypass.

## Phase 10: Reliability, Security, And ExDoc Review

### Limits And Failure Injection

- [ ] Bound every Call, argument, schema, registry, Context, Result, metadata,
  diagnostic, line list, diff, command, process output, and timeout.
- [ ] Reject integer overflow and unreasonable trusted limits.
- [ ] Inject unknown name, denied capability, validator failure, Workspace error,
  callback exception/throw/exit, malformed Result, and presentation failure.
- [ ] Inject failures before dispatch, during Workspace operation, and after a
  trustworthy terminal result.
- [ ] Prove not-applied versus ambiguous classification for every mutating stage.
- [ ] Stress many unique unknown names without atom growth.
- [ ] Stress repeated large calls and Results without retained state growth.
- [ ] Confirm Executor starts no process, queue, ETS table, or global registry.

### Security Review

- [ ] Search Tool structs for raw roots, environments, Ports, backend state, and
  credentials.
- [ ] Search logging and inspection paths for arguments, file content, command,
  output, Handle, operation ID, metadata, and exception text.
- [ ] Test redaction with recognizable synthetic credentials and paths.
- [ ] Confirm output intentionally returned by Workspace remains model-visible and
  is not falsely described as secret-free.
- [ ] Confirm no model input creates atoms, modules, functions, executable paths,
  capability values, or Workspace authority.
- [ ] Confirm Bash is documented as same-user ambient authority, not a sandbox.
- [ ] Confirm unsupported dynamic or security behavior fails closed.
- [ ] Confirm generic Bash has no credential-injection path.

### Documentation

- [ ] Every public Tool module has `@moduledoc`.
- [ ] Every public function and callback has purpose-oriented `@doc` and `@spec`.
- [ ] Every public struct has `t()` and documented ownership of each field.
- [ ] Add Tool modules to ExDoc groups.
- [ ] Add `docs/learning/TOOL-SYSTEM.md` as a complete maintenance guide.
- [ ] Add boundary, registry, capability, read-revision, mutation, Bash ambiguity,
  and continuation diagrams.
- [ ] Add examples for all schemas, Calls, Results, capabilities, every built-in,
  errors, ambiguity, cancellation, and Fake integration.
- [ ] Update `README.md`, `PLAN.md`, Provider fixtures, and status documentation.
- [ ] Correct stale namespace or architecture text discovered by the final audit.
- [ ] Document all capability, output, shell, host-authority, and deferred-feature
  limitations.

### Comprehension Gate

- [ ] Can the owner explain why Provider progress events do not execute tools?
- [ ] Can the owner distinguish Provider item ID, call ID, and operation ID?
- [ ] Can the owner identify where model arguments first become valid Tool input?
- [ ] Can the owner prove schema and runtime-validator parity?
- [ ] Can the owner explain why schema omission is not capability enforcement?
- [ ] Can the owner trace capability reduction into Workspace Access?
- [ ] Can the owner trace Read offset to Workspace line and back to next offset?
- [ ] Can the owner trace a revision from Read into Write or Edit?
- [ ] Can the owner distinguish invalid, denied, failed, and ambiguous calls?
- [ ] Can the owner explain natural Bash failure versus forced-stop ambiguity?
- [ ] Can the owner identify exactly which Tool data enters the next Provider
  request?
- [ ] Can the owner test every tool without network or host side effects?
- [ ] Can the owner list all deferred Tool capabilities?

### Phase Complete When

- [ ] Reliability and security tests pass.
- [ ] No unbounded Tool parser, encoder, accumulator, registry, queue, or retained
  operation state remains.
- [ ] No Tool-generated log, inspection, error, fixture, or example exposes a
  credential, absolute host path, raw content, command, or process output.
- [ ] Model-visible content is bounded, valid UTF-8 JSON and explicitly treated as
  untrusted evidence.
- [ ] `mix docs` succeeds without Tool documentation warnings.
- [ ] All examples and doctests pass.
- [ ] Tool System can be maintained without the original design conversation.

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

## Suggested Test Layout

```text
test/
  tool_contract_test.exs
  tool_spec_test.exs
  tool_registry_test.exs
  tool_executor_test.exs
  tool_presentation_test.exs
  tool_read_test.exs
  tool_write_test.exs
  tool_edit_test.exs
  tool_bash_test.exs
  tool_integration_test.exs
  live_tool_schema_test.exs
  support/tool_case.ex
  fixtures/tool/
    read_result.fixture
    write_result.fixture
    edit_result.fixture
    bash_result.fixture
    error_result.fixture
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

- [ ] Phases 0 through 10 are complete.
- [ ] Tool System boundary matches `PLAN.md`.
- [ ] Agent owns successful-response selection, source-order iteration, Run Events,
  and conversation continuation.
- [ ] Executor accepts one complete Call and returns one paired Result.
- [ ] Provider item ID, call ID, and Workspace operation ID remain distinct.
- [ ] Registry contains exactly Read, Write, Edit, and Bash in stable order.
- [ ] Unknown model names cannot create atoms or dispatch arbitrary modules.
- [ ] Exact schemas are accepted by Tokamak and match runtime validators.
- [ ] Every capability is trusted application data and checked before dispatch.
- [ ] Workspace receives an exact reduced Access value for every operation.
- [ ] All host access delegates only through Workspace.
- [ ] Read returns bounded numbered lines, revision, and continuation.
- [ ] Write supports explicit missing creation or current-revision replacement only.
- [ ] Edit supports exactly one literal current-revision replacement only.
- [ ] Bash uses fixed shell policy and is documented as same-user execution.
- [ ] Every model-visible Result is bounded valid UTF-8 JSON.
- [ ] Natural failures, known not-applied outcomes, and ambiguity remain distinct.
- [ ] No mutating or unknown-footprint operation is automatically replayed.
- [ ] Deterministic tests require no live key or real host side effects.
- [ ] ExDoc explains schemas, registry, capabilities, validation, adapters, output,
  cancellation, failures, ambiguity, security, and deferred work.
- [ ] The owner can maintain Tool System without the original AI conversation.

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
