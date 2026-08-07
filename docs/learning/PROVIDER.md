# Provider Component Learning Guide

## Purpose

This guide walks through the Provider component in the same order in which it
was built. It explains what each phase added, where the code lives, which module
owns each responsibility, and why the boundaries matter.

Use this guide together with:

- [`PLAN-PROVIDER.md`](../plan/PLAN-PROVIDER.md) for the detailed acceptance checklist.
- [`PROVIDERS.md`](../PROVIDERS.md) for protocol research, limits, and architecture decisions.
- The generated ExDoc API pages for exact function and type documentation.
- The focused tests under `test/` for executable examples.

The Provider component is complete through Phases 0 to 10. Workspace, Tool, Agent,
Runtime, and the local API are now implemented above it. Agent depends directly on
Provider contracts; Runtime and API preserve that boundary and do not call Provider
directly.

## The Core Idea

Provider is an adapter between Synapse and a model service.

```text
Agent Loop
  -> normalized Provider Request
  -> Provider implementation
  -> ordered normalized Events
  -> completed Provider Response or Provider Error
```

The Agent Loop should not know about:

- Tokamak URLs.
- Req or Finch.
- Authorization headers.
- HTTP chunks.
- SSE framing.
- Raw Responses JSON maps.

Provider should not know about:

- Filesystem access.
- Tool execution.
- Conversation continuation policy.
- Run-level retry policy.
- Terminal rendering.
- Workspace or Runtime modules.

This separation lets the Agent use either the real Tokamak implementation or a
deterministic Fake without changing Agent code.

## Component Map

```text
lib/synapse/provider.ex
  Provider behaviour and shared JSON types

lib/synapse/provider/
  request.ex            Agent -> Provider request contract
  response.ex           successful terminal result
  error.ex              sanitized terminal failure
  event.ex              ordered streaming progress
  output_item.ex        complete text and function-call output
  stream_context.ex     cancellation, deadline, and activity controls

  responses_codec.ex    normalized Request -> Responses API map
  sse_decoder.ex        arbitrary bytes -> complete SSE frames
  sse_event.ex          protocol-neutral complete SSE frame
  responses_stream.ex   Responses frames -> Events and Response

  credentials.ex        request-time API-key boundary
  tokamak.ex            real Req/Finch HTTP implementation
  fake.ex               deterministic scripted implementation
  json.ex               internal JSON-shape validation helper
```

The corresponding test map is:

```text
test/provider_contract_test.exs   contracts, validation, and doctests
test/responses_codec_test.exs     request encoding
test/sse_decoder_test.exs         byte and SSE framing
test/responses_stream_test.exs    Responses event reduction
test/credentials_test.exs         credential lifetime and redaction
test/tokamak_test.exs             deterministic transport behavior
test/fake_test.exs                scripted Provider behavior
test/live_tokamak_test.exs        opt-in live acceptance
```

## End-To-End Data Flow

Before studying individual phases, follow one text response through the system:

```text
Request struct
  -> ResponsesCodec.encode/1
  -> JSON request body
  -> Tokamak.stream/3
  -> Req/Finch HTTP request
  -> arbitrary HTTP body chunk
  -> SSEDecoder.feed/2
  -> complete SSEEvent
  -> ResponsesStream.push/2
  -> TextDelta event
  -> synchronous event sink
  -> response.completed
  -> MessageCompleted event
  -> {:ok, Response}
```

Every arrow is an ownership boundary. A module receives one representation and
returns another. Raw HTTP and provider maps stop inside Provider.

## Phase 0: Prerequisites And Decisions

### Goal

Choose concrete dependencies and policies before writing Provider code.

### Decisions

| Decision | Selected value |
| --- | --- |
| Elixir | 1.20 series |
| OTP | 28 series |
| HTTP client | Req 0.7.1 with Finch |
| Documentation | ExDoc 0.40.3 |
| Production endpoint | Tokamak Codex pool `/responses` proxy |
| Credential input | `TOKAMAK_API_KEY` at request time |
| First live model | `gpt-5.6-sol` |
| Live-test tag | `:live_tokamak`, excluded by default |

### Why this phase matters

Dependencies and endpoint behavior affect architecture. For example, Req's
stream callback allows one worker to process each chunk synchronously, which
makes backpressure possible. The Tokamak Codex pool uses Responses SSE, so the
component needs an SSE framer and a Responses reducer rather than a generic
line-oriented parser.

### What to inspect

- `mix.exs`
- `.env.example`
- `docs/PROVIDERS.md`
- Phase 0 in `docs/plan/PLAN-PROVIDER.md`

### Checkpoint

You should be able to explain why Provider calls Tokamak over HTTP instead of
starting the Tokamak CLI: Tokamak already exposes the required JSON/SSE gateway,
and a CLI subprocess would add process, output, and credential complexity.

## Phase 1: Contracts And Behaviour

### Goal

Define what enters and leaves Provider before implementing transport details.

### Files

- `lib/synapse/provider.ex`
- `lib/synapse/provider/request.ex`
- `lib/synapse/provider/response.ex`
- `lib/synapse/provider/error.ex`
- `lib/synapse/provider/event.ex`
- `lib/synapse/provider/output_item.ex`
- `lib/synapse/provider/stream_context.ex`
- `test/provider_contract_test.exs`

### Provider behaviour

The central callback is conceptually:

```elixir
stream(request, event_sink, context)
```

It returns exactly one terminal result:

```elixir
{:ok, %Synapse.Provider.Response{}}
{:error, %Synapse.Provider.Error{}}
```

Before returning, it may synchronously pass ordered events to `event_sink`.
The sink must return `:ok`. Any other result means the consumer rejected the
event and the stream stops.

### Request

`Synapse.Provider.Request` contains model-facing data:

```elixir
{:ok, request} =
  Synapse.Provider.Request.new(
    model: "configured-model",
    instructions: "Help with this project.",
    input_items: [],
    tools: []
  )
```

It deliberately cannot contain credentials, endpoint URLs, Req options,
Workspace handles, or retry policy. Unknown fields are rejected.

### Events versus terminal results

Events are progress:

- `MessageStarted`
- `TextDelta`
- `ToolCallStarted`
- `ToolCallDelta`
- `ToolCallCompleted`
- `MessageCompleted`
- `Diagnostic`

Events are not authoritative terminal results. Even after receiving
`ToolCallCompleted`, the Agent must wait for `{:ok, Response}` before executing
the tool. A later stream failure would invalidate the turn.

### Error

`Synapse.Provider.Error` separates three questions:

- `kind`: what type of failure happened?
- `retryable`: may higher-level policy consider another attempt?
- `output_started`: could replay duplicate output already observed by a caller?

These fields are independent. Cancellation can happen before output, producing
an interruption with `output_started: false`. A normally retryable transport
class after output cannot be replayed transparently.

### StreamContext

`StreamContext` is supplied by an operation owner:

```elixir
{:ok, context} =
  Synapse.Provider.StreamContext.new(
    operation_id: "operation-1",
    cancel_ref: make_ref(),
    inactivity_ms: 120_000,
    deadline: :infinity
  )
```

It lets Provider enforce lifetime without importing Runtime.

### Try it

```bash
mix test test/provider_contract_test.exs
```

### Checkpoint

You should be able to identify the direction of every contract:

```text
Request:       Agent -> Provider
StreamContext: operation owner -> Provider
Event:         Provider -> synchronous consumer
Response:      Provider -> Agent after success
Error:         Provider -> Agent/Runtime after failure
```

## Phase 2: Incremental SSE Framing

### Goal

Turn arbitrary HTTP bytes into complete Server-Sent Events frames without
knowing anything about Responses JSON.

### Files

- `lib/synapse/provider/sse_decoder.ex`
- `lib/synapse/provider/sse_event.ex`
- `test/sse_decoder_test.exs`

### The important misconception

An HTTP chunk is not an SSE event. One chunk may contain:

- Half of one line.
- Several complete lines.
- Several complete events.
- A UTF-8 sequence split between chunks.

Therefore this is unsafe:

```text
HTTP chunk -> JSON.decode
```

The correct flow is:

```text
HTTP chunks
  -> complete SSE lines
  -> blank-line-delimited SSE frames
  -> SSEEvent values
```

### Why the decoder is pure

`SSEDecoder` state is immutable data. `feed/2` returns a new state:

```elixir
decoder = Synapse.Provider.SSEDecoder.new()
{:ok, decoder, []} = Synapse.Provider.SSEDecoder.feed(decoder, "data: {")
{:ok, decoder, [event]} = Synapse.Provider.SSEDecoder.feed(decoder, "}\n\n")
```

It does not need a GenServer because it owns no independent lifetime or shared
mutable resource. The HTTP worker already owns the decoder state.

### EOF behavior

`finish/1` rejects an incomplete line or unterminated event. It never guesses
that truncated bytes form a complete frame.

### Limits

The decoder bounds transport chunks, individual lines, and accumulated event
fields before parsing can retain unbounded data.

### Try it

```bash
mix test test/sse_decoder_test.exs
```

Pay particular attention to the tests that split one fixture at every byte
boundary. Those tests prove that network chunk boundaries do not change meaning.

### Checkpoint

`SSEDecoder` knows SSE syntax, but it does not know `response.created`, JSON, tool
calls, Tokamak, credentials, or Agent events.

## Phase 3: Responses Request Encoding

### Goal

Convert a credential-free normalized Request into canonical Responses API data.

### Files

- `lib/synapse/provider/responses_codec.ex`
- `test/responses_codec_test.exs`
- `test/fixtures/responses/*_request.fixture`

### Why encoding is separate from HTTP

Encoding is a pure data transformation:

```text
Provider.Request -> string-keyed Responses map
```

It should be testable without a URL, API key, Req process, or network. Tokamak
transport adds endpoint and authorization policy later.

### Flat Responses tool shape

Responses tools use flat fields:

```json
{
  "type": "function",
  "name": "read",
  "description": "Read one project file",
  "parameters": {
    "type": "object",
    "properties": {
      "path": {"type": "string"}
    }
  }
}
```

They are not nested under a second `function` object. That nested shape belongs
to Chat Completions-style APIs.

### Tool continuation

After a tool executes in a future Agent turn, conversation projection contains
both the original call and its paired output:

```text
function_call(call_id)
function_call_output(same call_id)
```

The codec preserves ordering and call identity.

### Tokamak policy

The codec always sets:

```text
stream: true
store: false
```

It omits unsupported or endpoint-managed fields such as `max_output_tokens` and
does not send local metadata upstream.

### Try it

```bash
mix test test/responses_codec_test.exs
```

### Checkpoint

If a new endpoint needs a different request shape, keep canonical request
semantics here or add an explicit endpoint policy. Do not let arbitrary model
input rewrite transport options.

## Phase 4: Responses Stream Reduction

### Goal

Interpret complete SSE frames as Responses events and reduce them into normalized
Provider events and one completed Response.

### Files

- `lib/synapse/provider/responses_stream.ex`
- `test/responses_stream_test.exs`
- `test/fixtures/responses/*_stream.fixture`

### Layer boundary

```text
SSEDecoder
  produces complete SSEEvent
ResponsesStream
  decodes complete JSON data
  validates known event shapes
  accumulates output
  emits normalized Events
```

`ResponsesStream` does not know Req, HTTP status, credentials, or cancellation.

### Text accumulation

Text deltas are associated with an output `item_id` and `content_index`. They are
stored in source order and joined only when building the completed message.

### Function-call lifecycle

```text
response.output_item.added(function_call)
  -> ToolCallStarted

response.function_call_arguments.delta
  -> append fragment by item ID and call ID
  -> ToolCallDelta

response.function_call_arguments.done
  -> compare complete and accumulated JSON
  -> decode string-keyed argument object
  -> ToolCallCompleted

response.completed
  -> verify no call remains incomplete
  -> build FunctionCall output item
  -> MessageCompleted
  -> completed Response
```

### Why `ToolCallCompleted` still does not execute

Argument completion only proves that JSON was structurally complete. The stream
could still fail before `response.completed`. Provider therefore emits the event
for progress, but the Agent stages it until the terminal Response confirms the
whole turn succeeded.

### Multiple and interleaved calls

Fragments are keyed by stable item and call IDs, not arrival position. Two tool
calls may interleave safely:

```text
read delta 1
bash delta 1
read delta 2
bash delta 2
```

Completed output is returned by `output_index`, preserving provider source order.

### Unknown versus malformed events

An unknown event type may represent a future additive protocol feature. It emits
a bounded `Diagnostic` and processing continues.

A malformed known event fails. Ignoring malformed known data could associate
text with the wrong item or execute incorrect tool arguments.

### Try it

```bash
mix test test/responses_stream_test.exs
```

### Checkpoint

To support a new known Responses event, change `ResponsesStream`, its normalized
event contract if needed, and focused fixtures/tests. Tokamak transport should
not change because it owns bytes, not Responses semantics.

## Phase 5: Credential Boundary

### Goal

Resolve the Tokamak key only where one request needs it, without putting the key
in shared Provider contracts.

### Files

- `lib/synapse/provider/credentials.ex`
- `test/credentials_test.exs`

### Credential lifetime

```text
process environment
  -> Credentials.resolve
  -> redacted Secret handle
  -> Credentials.with_value callback
  -> authorization option inside Tokamak worker
  -> request finishes
```

The key is not present in Request, Event, Response, Error, StreamContext, Fake,
or fixtures.

### Why use a Secret wrapper

The wrapper has custom inspection:

```text
#Synapse.Provider.Credentials.Secret<redacted>
```

This prevents common accidental IEx and Logger inspection. It is not encrypted
memory and cannot stop deliberate code from extracting or retaining the closure
environment. The real protection is the narrow lifetime and small code path.

### Future replacement

The environment lookup is an adapter. A future keychain or credential broker can
replace the source function without changing Requests, Events, or Agent code.

### Try it

```bash
mix test test/credentials_test.exs
```

### Checkpoint

Provider credentials belong to transport authorization, not model context. A
tool subprocess must not inherit `TOKAMAK_API_KEY`; Workspace will enforce that
separately.

## Phase 6: Tokamak HTTP Transport

### Goal

Own one real streaming HTTP attempt and connect all pure Provider layers.

### File

- `lib/synapse/provider/tokamak.ex`
- `test/tokamak_test.exs`

### Process ownership

```text
operation coordinator calls Tokamak.stream/3
  -> spawns and monitors one request worker
  -> worker starts coordinator watchdog
  -> worker resolves credential
  -> worker owns Req.request/1 and stream callback
  -> coordinator waits for progress, cancellation, timeout, or result
```

Req and Finch own shared connection-pool processes. The temporary worker owns one
request attempt and its parser/reducer state.

### Why not `into: :self`

A mailbox firehose could let network messages arrive faster than parsing or the
consumer can process them. The function-based Req callback handles one chunk at
a time:

```text
chunk
  -> SSEDecoder
  -> one frame at a time through ResponsesStream
  -> synchronous event sink
  -> ask Finch for more data
```

This creates backpressure across the whole path.

### Cancellation

`Tokamak.cancel(operation_pid, cancel_ref)` sends a matching cancellation
message to the process blocked in `stream/3`. The coordinator kills its monitored
worker. Worker death closes the owned Finch request.

A watchdog also monitors the coordinator. If the caller dies, the watchdog kills
the request worker so an HTTP operation is not orphaned.

### One-attempt policy

Req retries and redirects are disabled. Provider classifies errors but never
silently repeats the request. A higher Agent or Runtime layer may later decide to
start a fresh attempt only when policy and `output_started` permit it.

### Error normalization

Transport keeps raw bodies, headers, Req structs, and exception messages inside
the worker. Returned errors contain allowlisted bounded details such as status,
safe request ID, and exception class.

### Try it

```bash
mix test test/tokamak_test.exs
```

Useful tests to read include cancellation, backpressure, caller termination,
event-sink failure, redirect rejection, and credential reflection.

### Checkpoint

The coordinator owns request lifetime. The worker owns HTTP and parser state.
Pure modules own transformations but no process lifetime.

## Phase 7: Deterministic Fake Provider

### Goal

Let Agent and Runtime tests exercise Provider behavior without HTTP, SSE, timing,
credentials, or a real model.

### Files

- `lib/synapse/provider/fake.ex`
- `test/fake_test.exs`

### Why Fake is a Provider implementation

A Req mock tests Tokamak transport internals. Agent should not depend on those
internals. Fake implements the normalized `Synapse.Provider` behaviour, so upper
components test against the same Request/Event/Response/Error boundary used in
production.

### Script shape

```elixir
script = [
  {:turn, expected_request, ordered_events, {:ok, response}},
  {:turn, continuation_request, more_events, {:ok, final_response}}
]
```

The expected request is optional. Turns are consumed once in order.

### Script ownership

An Elixir `Agent` process stores the remaining turns. `with_script/3` accepts one
operation ID for compatibility or a declared list of distinct Provider-attempt
IDs. Small globally registered alias processes resolve every declared ID to the
same script owner. This lets each attempt preserve its production operation
identity while one script is consumed in source order from another process:

```elixir
Fake.with_script(["provider-turn-1", "provider-turn-2"], script, fn ->
  Fake.stream(first_request, sink, first_context)
  Fake.stream(second_request, sink, second_context)
end)
```

`first_context` and `second_context` carry their matching distinct IDs. The list
is bounded to 128 unique IDs of at most 512 bytes each. The aliases monitor the
script owner and terminate when it stops. `with_script/3` starts the owner, runs
the test callback, and stops the owner in an `after` block.

This is test configuration only. No script key, Provider module, or operation-ID
list enters normalized `Provider.Request` or Tokamak input.

### Failures Fake can reproduce

- Failure before output.
- Interruption after output.
- Cancellation during event emission.
- Sink rejection or exception.
- Exhausted script.
- Unexpected request.
- Intentionally incomplete or malformed event order.
- Multiple and multi-turn function calls.

### Try it

```bash
mix test test/fake_test.exs
```

### Checkpoint

Use Fake for Agent behavior. Use an injected Req adapter for Tokamak transport
behavior. Those tests answer different questions.

## Phase 8: Reliability And Security Hardening

### Goal

Make every parser, accumulator, process lifetime, error, and credential path
explicitly bounded and failure-safe.

### Main bounds

| Resource | Default |
| --- | ---: |
| Encoded request body | 8 MiB |
| Retained HTTP error body | 4 KiB |
| Transport chunk | 2 MiB |
| SSE line | 64 KiB |
| SSE event | 1 MiB |
| Total model output | 64,000 bytes |
| Function arguments | 64,000 bytes |
| Output items | 128 |
| Content parts per message | 32 |
| Responses events | 10,000 |
| Compatibility diagnostics | 32 |
| Inactivity timeout | 120 seconds |

Hard configuration ceilings prevent a mistaken trusted option from setting a
limit to an unreasonable BEAM integer.

### Why counts matter as well as bytes

Byte limits do not stop a stream from sending millions of empty deltas. Event,
item, content-part, and diagnostic counts bound structures that can grow without
increasing text bytes.

### Frame-by-frame emission

The transport reduces and emits one SSE frame at a time. If an event sink rejects
or raises on an event, later frames from the same HTTP chunk are not interpreted.
This keeps `output_started` accurate and stops events after terminal failure.

### Security limitation

Sanitization reduces accidental disclosure but is not perfect secrecy. Provider
cannot prevent a model from repeating a secret already placed in a prompt, a
downstream event consumer from logging normalized text, or a compromised BEAM
node from inspecting process memory.

### Try it

```bash
mix test test/sse_decoder_test.exs
mix test test/responses_stream_test.exs
mix test test/tokamak_test.exs
```

### Checkpoint

For every retained list or map, ask what bounds its byte size or entry count. For
every process, ask who monitors it and what happens when its owner dies.

## Phase 9: Live Tokamak Acceptance

### Goal

Prove that deterministic contracts match the real Tokamak gateway without
making ordinary tests depend on network or credentials.

### File

- `test/live_tokamak_test.exs`

### Test policy

Live tests are tagged `:live_tokamak` and excluded by default. Ordinary tests
remain offline:

```bash
mix test
```

An explicit trusted local run loads the ignored environment file:

```bash
set -a && source .env && set +a
mix test --only live_tokamak test/live_tokamak_test.exs
```

The suite checks:

- Text start, non-empty deltas, completion, and terminal Response.
- One synthetic function call with accumulated string-keyed arguments.
- Cancellation after output with no completion or replay.

The synthetic function is not executed. This is a Provider test, and Provider's
job ends after returning a validated complete call. The Tool System can execute an
Agent-admitted call; the implemented Agent Loop owns whole-batch admission and
sequential execution. See [`AGENT-LOOP.md`](AGENT-LOOP.md).

### Fixture policy

Live bodies and identifiers are never recorded. Readable fixtures use synthetic
IDs and minimal event shapes. This avoids committing account data, prompts,
generated private content, headers, or credentials.

### Checkpoint

A live test proves compatibility, while deterministic fixtures prove behavior.
Both are needed because a private gateway can change independently of local code.

## Phase 10: ExDoc And Comprehension Review

### Goal

Make the Provider maintainable without relying on the original implementation
conversation.

### What was reviewed

- Every public module has a purpose-oriented `@moduledoc`.
- Every public function and callback has `@doc` and `@spec`.
- Every public struct or opaque state has a documented type.
- Events and errors identify their producers and consumers.
- Executable examples are wired into doctests.
- ExDoc groups contracts, events, output, wire modules, and implementations.
- Architecture guides agree with implemented callback and event names.
- Retry, cancellation, ownership, limits, and security tradeoffs are explicit.

### Executable documentation examples

Doctests cover:

- Building a text Request.
- Encoding one flat function tool.
- Feeding SSE bytes incrementally.
- Interpreting `ToolCallCompleted`.
- Configuring and running Fake.

### Try it

```bash
mix test --warnings-as-errors
mix docs
```

Open `doc/index.html` after generation to browse the guide and API reference.

## Text And Tool Calling Compared

### Text turn

```text
response.created
  -> MessageStarted
response.output_item.added(message)
response.output_text.delta...
  -> TextDelta...
response.completed
  -> MessageCompleted
  -> {:ok, Response{output_items: [Message]}}
```

### Tool-call turn

```text
response.created
  -> MessageStarted
response.output_item.added(function_call)
  -> ToolCallStarted
response.function_call_arguments.delta...
  -> ToolCallDelta...
response.function_call_arguments.done
  -> ToolCallCompleted
response.completed
  -> MessageCompleted
  -> {:ok, Response{output_items: [FunctionCall]}}
```

The Provider never executes the function. The future sequence is:

```text
successful Provider Response
  -> Agent selects complete FunctionCall
  -> Tool System validates capability and schema
  -> Workspace performs bounded host operation
  -> Tool Result is paired with call_id
  -> Agent sends continuation Request
```

## Where Should A Change Go?

| Change | Module |
| --- | --- |
| Add a Provider-visible request field | `Request` and `ResponsesCodec` |
| Add a normalized event | `Event` and `ResponsesStream` |
| Support a new known Responses event | `ResponsesStream` |
| Change SSE field or framing behavior | `SSEDecoder` and `SSEEvent` |
| Change Tokamak endpoint/header policy | `Tokamak` |
| Change API-key source | `Credentials` or injected source |
| Test Agent behavior without network | `Fake` script |
| Test HTTP transport behavior | Tokamak injected adapter tests |
| Change retry execution policy | Future Agent or Runtime, not Provider |
| Execute a function call | Future Tool System, not Provider |

## Verification Commands

Run focused checks while learning:

```bash
mix test test/provider_contract_test.exs
mix test test/sse_decoder_test.exs
mix test test/responses_codec_test.exs
mix test test/responses_stream_test.exs
mix test test/credentials_test.exs
mix test test/tokamak_test.exs
mix test test/fake_test.exs
```

Run the complete offline gate:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test --warnings-as-errors
mix docs
mix hex.outdated
```

## Comprehension Check

Try answering these before reading the answer guide:

1. Why is an HTTP chunk not safe to decode directly as JSON?
2. Why are SSEDecoder and ResponsesStream separate modules?
3. Why does `ToolCallCompleted` not immediately execute a tool?
4. What is the difference between an Event and a terminal Response?
5. Who owns the Req request process?
6. What does `output_started` protect against?
7. Why does Provider classify retries but not perform them?
8. When should a test use Fake instead of a Req adapter?
9. Where does the API key first become a raw string?
10. Which component will actually read files or run commands?

## Answer Guide

1. Network chunks are arbitrary delivery boundaries and may contain partial or
   multiple SSE lines and events.
2. SSEDecoder owns byte framing; ResponsesStream owns provider JSON semantics.
   Keeping them separate makes both pure, focused, and independently testable.
3. The arguments may be complete while the overall response can still fail.
   Execution waits for successful terminal completion.
4. Events report ordered progress. `{:ok, Response}` or `{:error, Error}` is the
   single authoritative terminal result.
5. A temporary worker owns Req and parser state; the calling operation process
   coordinates and monitors that worker.
6. It prevents a higher layer from invisibly retrying and duplicating text or
   tool calls already observed by a consumer.
7. Provider knows failure details, but Agent/Runtime owns run policy, budgets,
   and whether a fresh attempt is appropriate.
8. Use Fake for upper-component Provider behavior. Use an injected Req adapter
   for HTTP request, streaming, timeout, cancellation, and status behavior.
9. Inside `Credentials.with_value/2` in the Tokamak request worker, immediately
   before constructing authorization.
10. Workspace performs bounded filesystem and subprocess operations after the
    Tool System requests them.

## Guide Pattern Used By Later Components

The later Workspace, Tool, Agent, Runtime, and API guides use the same pattern:

1. Explain the component boundary before implementation.
2. Add a chapter for each completed phase.
3. Identify files, process ownership, and pure transformations.
4. Point to focused tests and runnable commands.
5. End with comprehension questions and an answer guide.

Workspace owns project paths, bounded reads, revisions, serialized and
atomic mutations, subprocess execution, cancellation, output limits, and secret
removal from child environments. Provider will remain unchanged and will never
access project files directly.
