# Learning The Tool System

## Current Scope

Tool System Phase 0 fixed and live-verified the four MVP schemas. Phase 1 added
the pure contracts that later phases use: Tool behavior, Call, Result, Spec,
CapabilitySet, Context, and Limits. Phase 2 added the exact specification-bearing
Read, Write, Edit, and Bash modules plus the static Registry. Phase 3 added the
one-call Executor, capability authorization, internal DispatchContext, static
Workspace Dispatcher, pairing, and callback hardening. Phase 4 added ordered bounded
presentation and Workspace failure mapping. Phase 5 made Read the first complete
built-in adapter. Phase 6 added revision-checked Write creation and replacement.
Phase 7 added revision-checked exact-one literal Edit. Phase 8 added bounded
unknown-footprint Bash execution. Phase 9 added deterministic Provider-to-Tool
integration, continuation projection, and live four-schema acceptance. Phase 10
completed the limits, failure-injection, retained-state, security, inspection,
ExDoc, architecture, fixture, and comprehension review.

All four MVP built-ins implement `prepare/2` and `present/3` and execute through
the complete Executor-to-Workspace boundary.

The detailed implementation checklist is
[`PLAN-TOOL-SYSTEM.md`](../plan/PLAN-TOOL-SYSTEM.md). Provider and Workspace
contracts are explained in [`PROVIDER.md`](PROVIDER.md) and
[`WORKSPACE.md`](WORKSPACE.md).

## Boundary

```text
successful Provider Response
  -> Agent retains Provider output item
  -> Tool.Call.from_provider/2
  -> static Registry and Executor
  -> built-in prepare callback (all four built-ins are available; no Handle)
  -> static Dispatcher selects exact Workspace facade function
  -> built-in present callback (retained outcome, no Handle)
  -> Tool.Result
  -> Agent creates function_call_output
```

Tool does not parse SSE, decide whether a Provider turn succeeded, mutate
conversation history, emit Run Events, print terminal output, or access files and
processes directly. Agent owns response selection and source-order iteration.
Workspace owns host operations. Executor owns static lookup, authorization,
operation selection, callback crash classification, and pairing validation.

## Why Explicit Contracts

Model output and trusted runtime authority must not share an unstructured map.
Phase 1 separates them:

| Contract | Producer | Important contents |
| --- | --- | --- |
| `Tool.Call` | Agent from complete Provider output | Model call ID, string name, decoded arguments |
| `Tool.Spec` | Trusted built-in module | Schema, capability, side-effect class |
| `Tool.CapabilitySet` | Agent or Runtime policy | Fixed read, write, process booleans |
| `Tool.Context` | Agent or Runtime | Handle, authority, operation lifetime, limits |
| `Tool.Result` | Built-in or Executor fallback | Paired status, model JSON, local metadata |
| `Tool.Limits` | Trusted configuration | Hard or lowered resource ceilings |

Every constructor rejects unknown fields. This catches accidental boundary drift,
including attempts to attach Provider item identity, arbitrary module names,
credentials, or transport options to a Tool contract.

## Three Different IDs

```text
Provider item id
  identifies an assistant output item retained by Agent

function call_id
  pairs Tool.Call and Tool.Result with function_call_output

Workspace operation_id
  correlates cancellation, activity, Workspace events, and Workspace errors
```

`Call.from_provider/2` validates the Provider item ID and then discards it. The
Call stores only `call_id`, name, and arguments. Context carries a separate
operation ID because Provider identifiers may be 512 bytes while Workspace
operation IDs are limited to 256 bytes.

A bare FunctionCall cannot prove that its parent Provider Response completed
successfully. Agent must enforce that precondition before conversion. This keeps
incomplete or ultimately failed model turns from becoming executable calls.

## Bounded JSON

Call arguments and Result metadata use string-keyed JSON objects. The internal
validator checks, in bounded order:

1. Container entry count before enumerating broad maps or lists.
2. Container depth before entering nested values.
3. Binary byte lower bounds before UTF-8 scans.
4. Supported JSON value types and signed 64-bit integers.
5. Exact encoded bytes, including quotes, separators, and escaping.

The byte counter is incremental. It does not first allocate a complete encoded
copy of an oversized model value. Tests compare its result with Elixir's standard
JSON encoder for empty containers, nested maps/lists, booleans, null, integers,
floats, escaped controls, key escaping, and multibyte UTF-8.

Call permits generic bounded JSON so unknown names remain pairable. Each current
built-in adapter then enforces its exact fields, path rules, revisions, non-empty
edit text, command NUL rejection, and timeout policy before dispatch.

## Call

```elixir
{:ok, call} =
  Synapse.Tool.Call.new(
    call_id: "call-1",
    name: "read",
    arguments: %{
      "path" => "mix.exs",
      "offset" => nil,
      "limit" => nil
    }
  )
```

Unknown names remain valid generic Calls. The static Registry rejects them
without creating atoms or dynamically selecting modules. Call inspection redacts
the model-controlled name, call ID, and complete argument object. Custom inspection
is least-disclosure convenience; trusted direct field access and
`inspect(value, structs: false)` can bypass protocol redaction and must not be used
for ordinary logging.

## Result

Once a bounded Call is admitted, Executor returns one paired Result directly rather
than using tuple shape for terminal policy. A value that cannot form a trustworthy
Call returns `{:error, :invalid_call}` before admission because no safe pairing ID
exists:

```text
:ok         known successful Tool outcome
:error      known ordinary failure or known completed non-zero Bash exit
:ambiguous  Tool cannot prove whether a side effect happened
```

```elixir
content = ~s({"status":"error","error":{"reason":"not_found","outcome":"not_applied"}})

{:ok, result} =
  Synapse.Tool.Result.error(
    call_id: "call-1",
    content: content,
    metadata: %{"tool" => "read", "outcome" => "not_applied"}
  )
```

`content` must be one valid UTF-8 JSON object whose top-level status agrees with
the struct. Duplicate object keys are rejected, including escape-equivalent keys.
Outcome values at top level, in the nested error, and in metadata must agree:

| Result status | Valid explicit outcomes |
| --- | --- |
| `:ok` | `"completed"` |
| `:error` | `"completed"`, `"not_applicable"`, `"not_applied"` |
| `:ambiguous` | exactly `"unknown"`, required |

Absent ordinary outcomes are permitted because not every successful envelope
needs one. Explicit JSON null is not absence and is rejected. Shared Presentation
implements deterministic key ordering, escaping, structural truncation, and
bounded outcome-preserving fallback.

Only Result `content` becomes the next Provider `function_call_output`. Metadata
is local data. Its recursive keys reject credential-, content-, command-, host-,
exception-, and backend-shaped names. This is defense in depth, not proof that an
arbitrary safe-keyed value contains no secret. Later producers must use fixed
allowlisted metadata.

## Strict Specs

A Spec stores only model-relevant schema data plus trusted policy:

```elixir
{:ok, spec} =
  Synapse.Tool.Spec.new(
    name: "read",
    description: "Read one bounded project file.",
    parameters: %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Relative path."}
      },
      "required" => ["path"],
      "additionalProperties" => false
    },
    capability: :fs_read,
    effect: :read_only
  )
```

The model-visible outer `type: function` and `strict: true` values are fixed
projection policy, not mutable fields. Capability and effect never enter the
Provider schema. Accepted parameter schemas match the subset live-verified in
Phase 0. Required names exactly equal property names, nullable integers use the
exact `["integer", "null"]` form, and present numeric bounds must be signed
64-bit integers in order.

Schema depth is a fixed reviewed property of this closed format. Lowering the
separate model-argument depth limit does not invalidate a trusted Spec.

## Static Built-In Specifications

Each built-in module owns one constructor-validated immutable Spec:

| Module | Name | Capability | Effect | Exact required fields |
| --- | --- | --- | --- | --- |
| `Tool.Read` | `read` | `fs_read` | `read_only` | `path`, `offset`, `limit` |
| `Tool.Write` | `write` | `fs_write` | `mutation` | `path`, `content`, `expected_revision` |
| `Tool.Edit` | `edit` | `fs_write` | `mutation` | `path`, `old_text`, `new_text`, `expected_revision` |
| `Tool.Bash` | `bash` | `process_exec` | `unknown` | `command`, `timeout_ms` |

Read `offset` and `limit`, plus Bash `timeout_ms`, are required nullable fields.
Null selects the trusted default. This matches the strict schema subset accepted
by Tokamak; omission is not the canonical shape.

The field table is the reviewed runtime-validator contract. Current Read, Write,
Edit, and Bash adapters use the same exact key sets and reject additions before
Workspace dispatch. Specification and adapter tests prove schema/runtime parity.

`Spec.to_provider/2` revalidates even a forged Spec struct before projecting:

```text
Spec fields
  -> constructor validation
  -> type=function
  -> strict=true
  -> name + description + parameters
  -> no capability, effect, or module identity
```

## Static Registry

```text
model string name
  -> bounded string lookup in one compiled literal map
     read  -> Synapse.Tool.Read
     write -> Synapse.Tool.Write
     edit  -> Synapse.Tool.Edit
     bash  -> Synapse.Tool.Bash
  -> unknown string returns :error
  -> no atom/module/function construction
```

```elixir
tools = Synapse.Tool.Registry.specifications()
{:ok, request} = Synapse.Provider.Request.new(model: "configured-model", tools: tools)
```

`Synapse.Tool.Registry.specifications/0` returns exact Provider maps in stable Read, Write,
Edit, Bash order. These maps match the reviewed Provider fixtures exactly.
Provider remains a broad transport validator; built-in canonical strictness is
proved by Spec and Registry rather than by tightening generic Provider behavior.

Lookup accepts only exact bounded strings:

```elixir
{:ok, Synapse.Tool.Read} = Synapse.Tool.Registry.fetch("read")
:error = Synapse.Tool.Registry.fetch("unknown")
:error = Synapse.Tool.Registry.fetch(:read)
```

The literal table is checked when Registry compiles. It verifies exact count,
unique names and modules, module/specification equality, expected capability and
effect, per-tool encoded bytes, and aggregate list bytes. Fixtures are test
expectations and are never read by production code.

No name is converted into an atom or module. Registry performs a fixed map lookup
and does not use module discovery, dynamic registration, processes, ETS,
persistent term, or extension hooks. Thousands of unique unknown binary names do
not increase the VM atom count.

The static count and schema limits use `Tool.Limits.default/0` at compilation.
Lower values carried by one Context cannot mutate global Registry contents. A
future Agent turn may enforce a lower schema budget while assembling a request,
but Phase 2 does not add filtering or progressive disclosure.

## Capability And Context

CapabilitySet has exactly three booleans:

```text
fs_read
fs_write
process_exec
```

```elixir
{:ok, capabilities} =
  Synapse.Tool.CapabilitySet.new(
    fs_read: true,
    fs_write: false,
    process_exec: false
  )
```

They correspond to one opaque Context workspace. These booleans are trusted
in-VM operational policy, not final source-scoped capability tokens and not a
security boundary against arbitrary BEAM code.

Context structurally validates its Workspace Handle fields, nested Workspace
limits, and Access value. It intentionally does not invoke or authenticate the
backend. A structurally valid forged Handle can therefore form a Context, but the
Workspace facade will reject it before execution. This preserves dependency
direction and avoids hidden host calls during pure contract construction.

Tool limits for paths, operation IDs, reads, Bash output, inactivity, and timeout
must fit the Handle's Workspace ceilings. Capabilities need not duplicate Handle
Access during construction. Effective authority is the intersection:

```text
Tool capability check
  -> exact reduced Workspace Access
  -> Executor-private DispatchContext
  -> exact module/request pair in static Dispatcher
  -> Workspace Handle ceiling check
  -> Workspace operation check
```

The authenticated Handle and exact Workspace OperationContext never enter a Tool
callback. This is essential. Passing the broad Handle beside reduced Access would
let a faulty adapter construct a broader OperationContext and call another
Workspace function. Copying the Handle with changed Access is not attenuation:
Real and Fake authenticate the token, limits, and Access together, so the changed
copy is invalid. Accepting changed fields under the same token would let the
recipient restore the broader values.

Instead, callbacks are split around trusted dispatch:

```text
Executor
  -> Registry.fetch(call.name)
  -> check Spec capability
  -> Context.authorize/2
       root Handle + exact OperationContext stay private
  -> module.prepare(call, limits)
       returns only the expected typed request
  -> Dispatcher validates module/request pairing and lowered limits
  -> exactly one Workspace.read/write/edit/run call
  -> retain terminal Workspace outcome
  -> module.present(call, outcome, limits)
  -> validate paired bounded Result
```

A faulty Read preparation that returns a WriteRequest is rejected before
Workspace. Preparation exceptions are ordinary pre-dispatch failures. A central
dispatch crash is ordinary for Read and conservative ambiguity for Write, Edit,
or Bash. Once Workspace returns a trustworthy terminal outcome, a presentation
exception or malformed Result uses a bounded fallback with the retained status;
it does not invent uncertainty.

Schema omission remains a usability decision, not authorization. Executor checks
the trusted CapabilitySet even for a directly constructed Call, and Workspace
checks the reduced Access again. This second check protects against Handle ceilings
that deny an operation despite broader Tool policy.

Execution is synchronous. Cancellation messages therefore target the same process
that entered Executor, callback order is explicit, and no hidden Task can continue
after the caller receives a Result. Executor handles one Call only; Agent remains
responsible for invoking multiple calls in Provider source order.

`process_exec` remains same-user process authority. It is not filesystem root
confinement, write denial, network isolation, or a sandbox.

## Bounded Presentation

`Synapse.Tool.Presentation` is the shared boundary between retained Workspace
outcomes and model-visible Result content. Current adapters call one of
`read/3`, `write/3`, `edit/3`, or `bash/3`; they do not implement their own JSON
or Workspace error mapping.

Every envelope has explicit key order. Presentation writes fixed fields first,
reserves the required suffix, and lets only evidence fields consume the remaining
budget:

```text
Read mutation identity/process outcome fields
  -> reserve path, revisions, continuation, counts, and closing JSON
  -> admit complete line objects or escaped evidence prefixes
  -> set presentation_truncated
  -> construct Result through the final validator
```

It never slices completed JSON. If caller-lowered limits cannot fit mandatory path
and revision fields, Presentation returns the fixed outcome-preserving fallback
rather than clipping identity.

Result pairing is also non-negotiable. After Executor has validated a Call under
the hard ceiling, it retains that exact `call_id` even if a direct caller supplied
a lower operation-level call-ID admission limit; otherwise the promised terminal
Result could not be paired.

Read line objects distinguish the two truncation layers:

```json
{
  "number": 1,
  "text": "defmodule Example do",
  "ending": "lf",
  "truncated": false,
  "presentation_truncated": false
}
```

`truncated` belongs to Workspace source collection. The per-line and top-level
`presentation_truncated` fields belong to Tool JSON budgeting. If trailing lines
are omitted, `next_offset` identifies the first omitted physical line. If one line
is clipped, its unavailable suffix is not resumable and continuation advances to
the next physical line.

Mutation results similarly keep `diff_truncated` separate from
`presentation_truncated`. Bash keeps raw `output_bytes` and Workspace `truncated`
separate from escaped model-visible output and Tool clipping.

### Process Bytes

Process output is arbitrary binary. Presentation applies deterministic invalid
UTF-8 replacement before JSON escaping. Quotes, backslashes, C0 controls, and DEL
are encoded as data; no terminal control byte is interpreted. `output_bytes`
continues to count the original Workspace bytes, not replacement or JSON bytes.

A natural non-zero exit is a known Tool error with `outcome: "completed"`. Clipping
its retained output does not change that outcome. By contrast, stopping a running
unknown-footprint Bash command at Workspace's raw output ceiling produces a
Workspace `outcome: :unknown`, so Tool returns ambiguity and never treats it as
ordinary presentation clipping.

### Workspace Errors

Known Workspace outcomes become Tool errors; only `outcome: :unknown` becomes Tool
ambiguity. Diagnostics use this shape:

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

Ambiguity uses the same shape with `status: "ambiguous"`, `outcome: "unknown"`,
and inspect-before-retry guidance. Presentation never copies Workspace messages,
operation IDs, arbitrary details, exceptions, backend state, or inspection output.
Only fixed Tool-owned messages and allowlisted non-negative numeric details may be
included.

This diagnostic filtering is not secret removal from intended evidence. File text,
diffs, and process output are deliberately model-visible and may contain secrets
obtained independently from Tool System. Presentation bounds and escapes them; it
does not claim to identify or redact their meaning.

## Read Adapter

Read requires exactly `path`, `offset`, and `limit`. Nullable values select trusted
defaults:

```json
{"path":"lib/example.ex","offset":null,"limit":null}
```

The model-facing offset is zero-based so a returned `next_offset` can be reused
directly. Workspace lines are one-based:

```text
offset 0  -> Workspace start_line 1
offset 7  -> Workspace start_line 8
```

Preparation checks overflow before adding one, applies the trusted line/source
byte limits, and returns only a `Workspace.ReadRequest`. Dispatcher supplies the
authenticated Handle and exact read-only OperationContext.

The default window is 100 lines. That is large enough to expose a useful code
region while keeping line numbers, revision, continuation, and nearby context
within model attention. Trusted callers can lower it; the hard model limit is
1,000 lines.

A first result may look like:

```json
{
  "status":"ok",
  "tool":"read",
  "path":"lib/example.ex",
  "revision":"wsr1.example",
  "lines":[{"number":1,"text":"defmodule Example do","ending":"lf","truncated":false,"presentation_truncated":false}],
  "next_offset":1,
  "file_bytes":120,
  "presentation_truncated":false
}
```

Continue by passing the returned offset unchanged:

```json
{"path":"lib/example.ex","offset":1,"limit":100}
```

At EOF, `next_offset` is `null`:

```json
{"status":"ok","tool":"read","path":"empty.txt","revision":"wsr1.example","lines":[],"next_offset":null,"file_bytes":0,"presentation_truncated":false}
```

A Workspace-clipped long line sets `truncated`; Tool clipping independently sets
`presentation_truncated`:

```json
{
  "number":4,
  "text":"bounded visible prefix",
  "ending":"lf",
  "truncated":true,
  "presentation_truncated":true
}
```

If Tool omits trailing lines, continuation points to the first omitted physical
line.

Every Write and Edit must use the canonical revision returned by Read. The
revision is opaque and handle/path scoped; it is evidence for stale-write checking,
not a lock or permission to overwrite blindly.

## Write Adapter

Write requires exactly `path`, `content`, and `expected_revision`. It revalidates
the complete canonical argument envelope before retaining content. There are only
two admitted operations.

Create a file that must not already exist:

```json
{"path":"lib/new.ex","content":"defmodule New do\nend\n","expected_revision":"missing"}
```

`"missing"` is a file-state expectation, not overwrite permission. If the path
already exists, Workspace returns `expected_missing` and leaves it unchanged.
Write never creates missing parent directories.

Replace a file only at the exact revision returned by Read:

```json
{"path":"lib/example.ex","content":"defmodule Example do\n  :ok\nend\n","expected_revision":"wsr1.example"}
```

A successful creation or replacement returns committed evidence:

```json
{
  "status":"ok",
  "tool":"write",
  "path":"lib/example.ex",
  "previous_revision":"wsr1.example",
  "revision":"wsr1.new",
  "changed":true,
  "bytes_written":38,
  "diff":"bounded diff evidence",
  "diff_truncated":false,
  "presentation_truncated":false
}
```

Creation uses `previous_revision: "missing"`. A same-content replacement is still
revision-checked and returns successful `changed: false` with equal previous/new
revisions and no diff.

Malformed revisions fail before Workspace and do not claim stale state. A valid
but stale, cross-handle, or wrong-path revision reaches Workspace and returns
`stale_revision` with `outcome: "not_applied"`; the model must reread and construct
a new replacement. A known validation, expected-existing, limit, or I/O failure is
also an ordinary not-applied error. An unknown mutation outcome is ambiguous and
requires inspecting current state before any retry.

Tool never retries Write automatically. Replaying after a lost or ambiguous result
could duplicate a creation or overwrite a newer accepted revision. Executor invokes
central dispatch once and preserves uncertainty mechanically.

## Edit Adapter

Edit requires exactly `path`, `old_text`, `new_text`, and `expected_revision`.
`old_text` must be non-empty; `new_text` may be empty to delete the matched text.
Unlike Write, Edit never accepts `"missing"`. It needs the exact canonical revision
returned by Read:

```json
{"path":"lib/example.ex","offset":null,"limit":null}
```

After Read returns `"revision":"wsr1.observed"`, replace one literal occurrence:

```json
{"path":"lib/example.ex","old_text":"def old","new_text":"def current","expected_revision":"wsr1.observed"}
```

Workspace first verifies that the revision still names the current file state.
Only then does it count literal occurrences. This stale-before-match order avoids
disclosing match information from a version the caller did not observe and ensures
the caller cannot diagnose or edit newer content using old evidence.

Exactly one occurrence is required. Matching is byte-for-byte literal, not regex
or fuzzy search, and occurrences overlap: `"aa"` appears twice in `"aaa"` at byte
offsets 0 and 1, so that edit returns `multiple_matches` and changes nothing. Zero
occurrences returns `no_match`; multiple occurrences returns `multiple_matches`.
Both are known conflict outcomes. Equal old/new text still requires exactly one
match and a fresh revision, then returns successful `changed: false`.

A successful Edit returns the same bounded mutation evidence as Write, including
previous and committed revisions, changed state, byte count, and bounded diff. Its
returned revision can drive a later Edit after another Read confirms the intended
state. Stale, match, and generated-size conflicts leave the file unchanged.

Fuzzy edit and automatic stale merge are deferred deliberately. Either would add
policy that can select unintended text or combine changes without model review.
After `stale_revision`, the model must reread and construct a new exact operation.
After ambiguity, it must inspect current state before deciding whether another
mutation is safe. Executor never rereads, merges, rebases, or retries Edit.

```text
Read(path)
  -> Workspace returns text + opaque path/handle-scoped wsr1 revision
  -> Tool presents revision to model
  -> model returns complete Write content or exact Edit old/new text
  -> adapter parses the same revision into WriteRequest/EditRequest
  -> Workspace checks revision before replacement or match disclosure
     current -> commit once -> new revision
     stale   -> known not_applied -> reread before constructing another call
```

Every mutation follows one authority-preserving sequence:

```text
Call
  -> pure prepare (invalid means not_applied; no Handle)
  -> static Dispatcher invokes Workspace once
     known conflict/failure -> not_applied
     committed result       -> completed
     lost terminal evidence -> unknown / ambiguous
  -> pure present of retained outcome
  -> paired bounded Result
  -> never automatic retry
```

## Bash Adapter

Bash requires exactly `command` and `timeout_ms`. The command must be non-empty
bounded UTF-8 without NUL. A null timeout selects the trusted default; an integer
may only lower that default. Model arguments cannot select executable, argv, cwd,
environment, stdin, inactivity/output policy, mutation class, secrets, or
background execution controls:

```json
{"command":"mix test","timeout_ms":null}
```

The adapter always prepares this policy:

```text
executable        /bin/bash
arguments         ["-lc", command]
cwd               .
inactivity        trusted Tool default
raw output limit  trusted Tool default
mutation          unknown
```

Workspace normally accepts an absolute executable and separated argv without
shell parsing. Model-facing Bash intentionally chooses a shell because its product
contract is shell source. This is an explicit adapter decision, not implicit
Workspace behavior or a model-selected executable.

A natural zero exit is Tool success:

```json
{"status":"ok","tool":"bash","exit_code":0,"termination":"exited","elapsed_ms":42,"output":"ok\n","output_bytes":3,"truncated":false,"presentation_truncated":false}
```

A natural non-zero exit is a completed Tool error, not ambiguity:

```json
{"status":"error","tool":"bash","outcome":"completed","exit_code":7,"termination":"exited","elapsed_ms":42,"output":"failed\n","output_bytes":7,"truncated":false,"presentation_truncated":false}
```

Cancellation or deadline before start is known not applied:

```json
{"status":"error","tool":"bash","error":{"kind":"workspace","workspace_kind":"cancelled","reason":"cancelled","message":"Workspace operation was cancelled","outcome":"not_applied","path":"."}}
```

After Started, the same cancellation is ambiguous because shell source may already
have changed files:

```json
{"status":"ambiguous","tool":"bash","error":{"kind":"workspace","workspace_kind":"ambiguous","reason":"cancelled","message":"Workspace outcome is unknown; inspect current workspace state and do not retry blindly","outcome":"unknown","path":"."}}
```

```text
Bash admitted
  -> not started + cancel/deadline/start failure -> known not_applied error
  -> Started
     natural exit 0       -> known success
     natural exit nonzero -> known completed error
     forced stop/failure  -> unknown mutation outcome -> ambiguous
```

Every generic Bash command declares `mutation: :unknown`; shell text cannot be
proved read-only. It therefore holds the exclusive Workspace mutation permit.
Cancellation, timeout, inactivity, output limit, sink failure, runner failure, or
owner death after start remains ambiguous. Executor never retries Bash.

This is same-user execution, not a sandbox. A command may read any host file the
user can read, write outside the Workspace, use the network, inspect processes, or
invoke absolute credential helpers. Workspace waits for confirmed cleanup of its
owned direct command before return, but a descendant that daemonizes, reparents, or
creates a new session may escape on the supported macOS platform.

The child receives a fixed secret-minimizing environment with private HOME/TMPDIR
and no provider keys, cloud credentials, GitHub token, SSH agent socket, or generic
secret injection. That reduces accidental inheritance; it cannot stop shell source
from deliberately reading same-user files or invoking another credential source.

Workspace bounds raw accepted output before Tool sees it. `output_bytes` counts raw
bytes and `truncated` reports Workspace output-limit clipping. Tool then repairs
invalid UTF-8, JSON-escapes controls, and clips the model-visible prefix to its
result budget; `presentation_truncated` reports this second layer. Repair and
escaping can expand bytes, so the visible prefix can be shorter even when Workspace
did not truncate raw output. Neither layer logs event payloads.

## Provider-To-Tool Integration

Phase 9 joins existing contracts in a deterministic test harness; it does not add
an Agent Loop module. A successful sequence is:

```text
Provider stream
  -> ToolCallStarted / ToolCallDelta / ToolCallCompleted progress is staged only
  -> Provider returns {:ok, completed Response}
  -> validate completed status and unique output-item/call identities
  -> preflight every FunctionCall through Tool.Call.from_provider/2
  -> preserve original FunctionCall in Agent-owned conversation state
       provider item id remains here
  -> execute admitted Tool Calls sequentially in Response source order
       Tool Call keeps call_id, name, arguments; discards provider item id
       Agent or Runtime supplies an independent bounded Workspace operation_id
  -> Tool Result keeps the exact call_id and bounded JSON content
  -> Agent appends original function_call then matching function_call_output
       function_call keeps provider item id + call_id
       function_call_output keeps call_id + Result.content
  -> next Provider Request replays the complete alternating sequence
```

Every call is converted before any execution begins. This prevents a valid early
mutation followed by an over-limit later FunctionCall from partially executing an
inadmissible turn. Response construction also rejects duplicate output-item IDs,
duplicate function call IDs, and any supplied non-completed status.

`ToolCallCompleted` means one streamed argument object decoded successfully. It is
still progress, not terminal provenance. The stream may later fail, interrupt, or
report an unsuccessful terminal. Only `{:ok, %Response{status: :completed}}` makes
its complete FunctionCall items eligible for preflight; failed/error tuples,
progress events, bare FunctionCalls, forged failed Responses, and incomplete items
execute nothing.

The deterministic harness proves:

* all four built-ins execute through exact Fake Workspace requests and contexts;
* `read -> write -> bash` and `read -> edit -> bash` preserve source order;
* unknown, invalid, denied, and known failed calls remain paired;
* ambiguity emits its paired output and prevents later admission in the harness;
* Provider item ID, function call ID, and Workspace operation ID remain separate;
* continuation replay preserves original assistant calls and matching outputs.

An abbreviated side-effect-free Fake setup is shown below; the complete executable
flow is the first test in `test/tool_integration_test.exs`:

```elixir
{:ok, request} =
  Synapse.Workspace.ReadRequest.new(
    path: "mix.exs",
    start_line: 1,
    line_count: 100,
    max_bytes: 32_768
  )

{:ok, operation_context} =
  Synapse.Workspace.OperationContext.new(
    operation_id: "workspace-read-1",
    access: %Synapse.Workspace.Access{read: true, write: false, exec: false}
  )

# Tests construct a bounded ReadResult, script Fake.expect_read/3, create trusted
# Tool Context, then call Executor.execute/2. Fake.assert_finished/1 proves exact
# request, Context, and source order without touching a host file.
```

The ambiguity stop is explicit test-harness policy, not a hidden queue or claimed
Agent Loop. The future Agent Loop must still own durable conversation state,
per-call trusted Context and operation IDs, turn sequencing, user-visible events,
retry policy, interruption, and admission of later calls after any terminal class.

The opt-in `live_tool_schema_test.exs` sends all four exact Registry schemas to the
Tokamak Codex pool and asks for one harmless Read call. It verifies successful
terminal Response, static name lookup, bounded Call construction, and event/item ID
correlation, then stops without opening or invoking Workspace. Passing proves the
remote pool accepts the wire schemas. It does not prove argument intent, capability
policy, filesystem safety, process containment, mutation correctness, or safe
execution; deterministic Fake and supported-platform Real tests own those claims.

## Deferred Capabilities

The MVP intentionally has no dynamic registration, search/glob/grep, file delete
or rename, patch/multi-file mutation, parallel/dependency scheduling, Run Events,
approval prompts, delegated subagent authority, credential injection, command
templates, PTY/stdin/background jobs, sandboxing, artifact spill, secret filtering,
automatic retry, durable Tool persistence, or provider-specific schema variants.
The canonical complete list is in
[`PLAN-TOOL-SYSTEM.md`](../plan/PLAN-TOOL-SYSTEM.md#deferred-tool-system-work).

## State And Processes

Tool contracts, Registry, Executor, and Dispatcher own no process, mailbox, Task,
timer, ETS table, queue, or retained operation state. Cancellation references and
deadlines are data until the synchronous Workspace operation consumes them.

## Inspection

Ordinary inspection follows least disclosure:

```text
Call     name, call ID, and arguments redacted
Result   status visible; call ID, content, metadata redacted
Spec     name/capability/effect visible; parameters redacted
Context  fully redacted
```

CapabilitySet and Limits contain only trusted booleans and numbers and retain
ordinary structural inspection.

## Source Map

```text
lib/synapse/tool.ex                  Tool behavior and JSON types
lib/synapse/tool/validation.ex       internal bounded validation
lib/synapse/tool/limits.ex           hard and lowered ceilings
lib/synapse/tool/call.ex             complete model-derived call
lib/synapse/tool/result.ex           paired terminal result
lib/synapse/tool/spec.ex             strict schema and execution policy
lib/synapse/tool/capability_set.ex   trusted fixed authority
lib/synapse/tool/context.ex          workspace and operation lifetime
lib/synapse/tool/inspect.ex          disclosure-safe inspection
lib/synapse/tool/read.ex             Read specification, preparation, and presentation
lib/synapse/tool/write.ex            Write create/replace preparation and presentation
lib/synapse/tool/edit.ex             exact-one Edit preparation and presentation
lib/synapse/tool/bash.ex             fixed-policy Bash preparation and presentation
lib/synapse/tool/registry.ex         static string lookup and Provider schemas
lib/synapse/tool/dispatch_context.ex internal retained Workspace authority
lib/synapse/tool/dispatcher.ex       exact module/request to Workspace dispatch
lib/synapse/tool/invocation.ex       callback and terminal-result hardening
lib/synapse/tool/fixed_result.ex     bounded paired fallback diagnostics
lib/synapse/tool/executor.ex         one-call authorization and orchestration
lib/synapse/tool/presentation.ex     ordered bounded result and error presentation
```

Focused tests live in `test/tool_limits_test.exs`,
`test/tool_contracts_test.exs`, `test/tool_specifications_test.exs`,
`test/tool_registry_test.exs`, and `test/tool_executor_test.exs`.
Phase 4 presentation tests live in `test/tool_presentation_test.exs`.
Read adapter tests live in `test/tool_read_test.exs`.
Write adapter tests live in `test/tool_write_test.exs`.
Edit adapter tests live in `test/tool_edit_test.exs`.
Bash adapter tests live in `test/tool_bash_test.exs`.
Provider-to-Tool integration tests live in `test/tool_integration_test.exs`.
Final reliability and security tests live in `test/tool_phase10_test.exs`.
The credential-gated schema check lives in `test/live_tool_schema_test.exs`.

## Verification

```bash
mix test test/tool_limits_test.exs test/tool_contracts_test.exs --warnings-as-errors
mix test test/tool_specifications_test.exs test/tool_registry_test.exs --warnings-as-errors
mix test test/tool_executor_test.exs --warnings-as-errors
mix test test/tool_presentation_test.exs --warnings-as-errors
mix test test/tool_read_test.exs --warnings-as-errors
mix test test/tool_write_test.exs --warnings-as-errors
mix test test/tool_edit_test.exs --warnings-as-errors
mix test test/tool_bash_test.exs --warnings-as-errors
mix test test/tool_integration_test.exs --warnings-as-errors
mix test test/tool_phase10_test.exs --warnings-as-errors
mix test test/live_tool_schema_test.exs --include live_tokamak --warnings-as-errors
mix format --check-formatted
mix compile --warnings-as-errors
mix test --warnings-as-errors
mix docs
```

## Comprehension Check

1. Why can a complete FunctionCall item still be ineligible for execution?
2. Which ID is copied into Tool Call, and which ID is discarded?
3. Why are Call names strings rather than atoms?
4. What makes Result ambiguity different from ordinary error?
5. Why does metadata key filtering not guarantee secret-free values?
6. Why does Context perform only structural Handle validation?
7. Why are Tool capabilities checked again through Workspace Access later?
8. Which mutable process owns current Tool contract or Registry state?
9. Why does Spec have no `strict` or implementation-module field?
10. Why can no built-in callback receive a Workspace Handle?
11. Why can Bash execute without its adapter receiving process authority?
12. Why does Presentation never slice completed JSON?
13. Which truncation flag owns a clipped Workspace line versus clipped Tool JSON?
14. Why can a non-zero Bash exit be clipped without becoming ambiguous?
15. Which Workspace error data is deliberately not copied to the model?
16. How does Read map model offset to Workspace lines and back?
17. Why is 100 lines the default Read window?
18. What must Write or Edit do with the Read revision?
19. Why is `"missing"` not blind overwrite permission?
20. What must happen after `stale_revision` or an ambiguous mutation?
21. Why does Tool never retry mutations automatically?
22. Why does editing `"aa"` in `"aaa"` fail with multiple matches?
23. Why does Workspace check staleness before counting Edit matches?
24. Why are fuzzy Edit and automatic stale merge deferred?
25. Why does Bash use `/bin/bash -lc` while generic Workspace run uses separated argv?
26. Why is every model-facing Bash command `mutation: :unknown`?
27. Why is natural exit 7 an error but not ambiguous?
28. Which fields distinguish Workspace output clipping from Tool presentation clipping?
29. Which same-user and descendant powers remain outside Workspace containment?
30. Why does generic Bash receive no injected provider or credential secrets?
31. Why is `ToolCallCompleted` insufficient to authorize execution?
32. Why must every FunctionCall be preflighted before the first one executes?
33. Where do provider item ID, function call ID, and Workspace operation ID live?
34. What does the deterministic integration harness leave for Agent Loop?
35. Why does live schema acceptance not prove Workspace safety?
36. Where does generic Call validity end and exact built-in validity begin?
37. How is schema/runtime-validator parity proved?
38. Exactly which Tool data enters the next Provider request?
39. Which major capabilities remain deferred after the MVP Tool System?

## Answer Guide

1. Agent must also know the parent Provider Response completed successfully; the
   item alone has no parent terminal status.
2. Function `call_id` is copied for result pairing. Provider output-item `id` is
   validated and discarded from Tool Call while Agent retains the original item.
3. Names are external model data. Atom creation is global and not garbage
   collected, and dynamic atoms could also enable unsafe dispatch patterns.
4. Error means a known terminal outcome. Ambiguous means a side effect may have
   happened and must not be replayed blindly.
5. A safe-looking key can still carry an arbitrary secret value. Producers must
   use allowlisted fields and avoid content-bearing values.
6. Construction must stay pure and cannot authenticate arbitrary backends.
   Workspace remains the authoritative operation boundary.
7. Schema visibility and Tool policy are not host authorization. Effective
   authority can only decrease through both layers.
8. None. Contracts, specifications, and Registry are immutable data and pure
   functions.
9. Strict function shape is fixed projection policy; implementation identity is a
   private static Registry concern.
10. A broad authenticated Handle beside reduced Access would let a faulty adapter
    reconstruct broader authority. Executor therefore retains Handle and
    OperationContext and exposes only prepare/request and present/outcome seams.
11. The adapter only builds a ProcessSpec and presents a retained outcome. Executor
    retains the Handle, derives exec-only Access, and lets only static Dispatcher
    call Workspace with a synchronous payload-discarding sink.
12. A byte slice can split UTF-8, an escape sequence, or JSON structure.
    Presentation budgets fixed structure first and clips only evidence prefixes.
13. `truncated` records Workspace source clipping. `presentation_truncated` records
    Tool evidence clipping or omission.
14. Natural exit is already a trustworthy terminal ProcessResult. Output clipping
    changes visible evidence size, not whether the command completed.
15. Workspace messages, operation IDs, arbitrary details, exceptions, backend
    state, and inspection output are omitted. Tool emits fixed messages and only
    allowlisted numeric details.
16. `start_line = offset + 1`; returned `next_line` becomes
    `next_offset = next_line - 1`, so continuation reuses the schema directly.
17. It balances a useful code region against model attention and presentation
    overhead while remaining caller-lowerable.
18. Pass the exact opaque revision as `expected_revision`; stale or cross-path
    revisions cannot authorize a blind replacement.
19. It requires the destination to be absent; an existing destination produces a
    known conflict and remains unchanged.
20. Stale requires rereading and preparing new content. Ambiguity requires
    inspecting current state before deciding whether any new mutation is safe.
21. A retry can duplicate creation or overwrite state after an operation whose
    terminal result was lost. Retry policy must have current-state evidence.
22. Literal occurrences overlap. They begin at offsets 0 and 1, so exact-one
    matching rejects the operation without changing the file.
23. The revision proves which state the caller observed. Checking it first avoids
    disclosing match information from newer content and prevents decisions based on
    stale evidence.
24. Fuzzy selection can target unintended text, while automatic merge can combine
    changes without model review. The current contract requires reread and a new
    explicit exact operation.
25. Generic Workspace avoids implicit shell interpretation. Bash explicitly
    promises shell source, so its trusted adapter fixes the shell and argv rather
    than exposing those policy fields to the model.
26. Arbitrary shell text can mutate files or external state and cannot be proved
    read-only. Unknown commands therefore hold exclusive mutation ownership and
    forced stops after start remain ambiguous.
27. A natural exit is a trustworthy completed ProcessResult. Exit 7 says the
    command failed, but its terminal process outcome is known.
28. `truncated` records raw Workspace output clipping; `presentation_truncated`
    records repaired/escaped model-visible prefix clipping. `output_bytes` remains
    the raw count.
29. The command runs as the same user and may access host files, network, helpers,
    and processes. Direct-child cleanup is confirmed, but daemonized, reparented,
    or new-session descendants may escape.
30. Generic shell execution has no task-specific need for credentials. A fixed
    minimal environment prevents accidental provider/cloud/GitHub/SSH inheritance,
    though same-user code can still seek credentials deliberately.
31. It proves only that one streamed call decoded. A later failed or interrupted
    terminal invalidates execution eligibility; the Provider must return a
    successful completed Response containing that call.
32. A later over-limit or malformed call must invalidate admission before an
    earlier mutation can create a partial turn whose Results are then discarded.
33. Provider item ID remains on the Agent-owned assistant call. Function call ID
    pairs Tool Call, Result, and function output. Agent or Runtime independently
    supplies a bounded Workspace operation ID through Context.
34. Durable conversation and attempt state, Context creation, event emission,
    turn lifecycle, interruption, retry, and policy after terminal Tool outcomes.
35. It proves remote wire compatibility and bounded call construction only. The
    call is not executed; Workspace authority, path, mutation, and process safety
    require deterministic Fake and supported-platform Real tests.
36. Call validates bounded identity and generic string-keyed JSON. After static
    lookup and authorization, the registered adapter validates its exact key set,
    types, path/revision/text/command rules, and contextual lower limits.
37. Registry tests compare exact Provider schemas, adapter tests exercise exact
    fields and boundaries, Dispatcher revalidates typed requests, and the live test
    confirms the remote pool accepts the same four schemas.
38. Agent replays the original assistant `function_call` item and adds only
    `function_call_output` with the exact `call_id` and `Result.content`. Result
    metadata, Context, capability, Workspace Handle, operation ID, and backend data
    remain local.
39. Dynamic/search/file-management tools, parallel scheduling, Run Events,
    approvals/delegation, credentials, interactive/background process features,
    sandboxing, artifacts, secret filtering, retries, durable persistence, and
    schema negotiation remain deferred; the linked plan contains the full list.

## Completion

Tool System Phases 0-10 are complete. The next project step is the Agent Loop,
which must reuse these one-call contracts rather than moving sequencing, durable
state, or policy into Executor or adapters.
