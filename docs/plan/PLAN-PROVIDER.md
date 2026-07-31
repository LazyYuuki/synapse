# Provider Implementation Checklist

## Purpose

This document is the implementation checklist for the Provider component defined in [`PLAN.md`](PLAN.md).

It turns the provider research in [`../PROVIDERS.md`](../PROVIDERS.md) and the comprehension requirements in [`../../README.md`](../../README.md) into an ordered set of coding, testing, documentation, and learning tasks.

The checklist is intentionally limited to the Provider component. It does not implement the Agent Loop, Workspace, built-in tools, Runtime retry orchestration, or CLI rendering.

## Provider Outcome

The Provider is complete when Synapse can send a normalized request to Tokamak's Codex pool proxy and emit normalized text, function-call, completion, and failure events without exposing Tokamak HTTP or JSON details to the caller.

The first live proof is:

```text
Provider Request
  -> Tokamak POST /v1/agent-pool/codex-proxy/responses
  -> streamed Responses SSE
  -> normalized Provider Events
  -> Provider Response or Provider Error
```

The Agent Loop should be able to use the same Provider behaviour with either the real Tokamak implementation or a deterministic Fake provider.

## Checklist Rules

- Check an item only after its implementation, focused tests, public documentation, and relevant guide updates are complete.
- Do not check a phase merely because code exists.
- Do not use a live Tokamak request where a deterministic unit or contract test can prove the behavior.
- Never place a real API key in a fixture, command argument, source file, exception, event, or test output.
- Keep each phase small enough to review and understand independently.
- If a public contract changes, update this plan and the parent architecture before continuing.

## Progress Summary

| Phase | Deliverable | Status |
| --- | --- | --- |
| 0 | Confirm prerequisites and decisions | Complete |
| 1 | Provider contracts and behaviour | Complete |
| 2 | Incremental SSE framer | Complete |
| 3 | Responses request encoder | Complete |
| 4 | Responses stream reducer | Complete |
| 5 | Credential boundary | Complete |
| 6 | Tokamak HTTP transport | Complete |
| 7 | Deterministic Fake provider | Complete |
| 8 | Reliability and security hardening | Complete |
| 9 | Live Tokamak acceptance | Complete |
| 10 | ExDoc and comprehension review | Complete |

Update this table when a phase passes its completion gate.

## Architectural Position

```text
                         outside Provider
                               |
                               v
                    +----------------------+
                    | Synapse.Provider     |
                    | behaviour            |
                    +----------+-----------+
                               |
                 +-------------+-------------+
                 |                           |
                 v                           v
      +----------------------+     +----------------------+
      | Provider.Tokamak     |     | Provider.Fake        |
      | real implementation  |     | deterministic tests  |
      +----------+-----------+     +----------------------+
                 |
        +--------+---------+
        |                  |
        v                  v
+----------------+  +----------------------+
| Credentials    |  | ResponsesCodec       |
| API key lookup |  | request encoding     |
+----------------+  +----------+-----------+
                              |
                              v
                     +------------------+
                     | Req HTTP stream  |
                     +--------+---------+
                              |
                              v
                     +------------------+
                     | SSEDecoder       |
                     | bytes -> frames  |
                     +--------+---------+
                              |
                              v
                     +------------------+
                     | ResponsesStream  |
                     | frames -> events |
                     +--------+---------+
                              |
                              v
                   normalized Provider Events
```

## Dependency Direction

```text
Provider behaviour
  <- Tokamak implementation
  <- Fake implementation

Tokamak implementation
  -> Credentials
  -> ResponsesCodec
  -> SSEDecoder
  -> ResponsesStream
  -> Req
```

No Provider module imports or calls Agent, Tool, Workspace, CLI, or Runtime.

Runtime may pass an operation context containing cancellation and deadline information into Provider. Provider consumes that context but does not call Runtime.

## Provider Boundary

### Provider Owns

- Provider behaviour and contracts.
- Tokamak endpoint and request policy.
- Responses request encoding.
- HTTP stream ownership for one request attempt.
- SSE framing.
- Responses event decoding and accumulation.
- Normalized Provider Events.
- Provider terminal response and error classification.
- Environment-based Tokamak credential lookup for the MVP.
- Fake provider behavior used by Agent tests.

### Provider Does Not Own

- Conversation continuation policy.
- Tool execution.
- Filesystem or subprocess access.
- Run-level retry decisions.
- User-facing rendering.
- Session persistence.
- Worktrees.
- Capability delegation.
- Direct Codex OAuth.
- Generic OpenAI-compatible endpoints in the first MVP.

## Architectural Invariants

- Raw Tokamak response maps never leave Provider.
- HTTP chunks never go directly to Agent.
- SSEDecoder has no knowledge of JSON or OpenAI Responses.
- ResponsesStream has no knowledge of Req or credentials.
- Credentials has no knowledge of prompts or conversation items.
- Provider performs one request attempt and does not hide automatic retries.
- A function call is not complete until its `arguments.done` event has been processed successfully.
- Incomplete or malformed function arguments are never emitted as executable calls.
- Unknown future Responses events do not crash the stream.
- External JSON keys remain strings.
- No model or provider input is converted into a new atom.
- Cancellation closes the owned HTTP operation.
- A failure records whether any model output was emitted.
- A partial stream is never represented as an ordinary successful completion.
- Provider emits no terminal text directly.
- Provider events contain no credentials or authorization headers.

## Internal Modules

| Module | Purpose |
| --- | --- |
| `Synapse.Provider` | Behaviour and public provider contract |
| `Synapse.Provider.Request` | Normalized provider request |
| `Synapse.Provider.Response` | Completed normalized provider response |
| `Synapse.Provider.Error` | Sanitized provider failure classification |
| `Synapse.Provider.Event` | Typed event definitions |
| `Synapse.Provider.OutputItem` | Normalized message and function-call output items |
| `Synapse.Provider.StreamContext` | Cancellation, deadline, and activity context supplied by Runtime |
| `Synapse.Provider.SSEDecoder` | Incremental byte-to-SSE-frame parser |
| `Synapse.Provider.SSEEvent` | Protocol-neutral SSE frame |
| `Synapse.Provider.ResponsesCodec` | Normalized request-to-Responses JSON encoding |
| `Synapse.Provider.ResponsesStream` | Responses SSE frame reduction and event normalization |
| `Synapse.Provider.Tokamak` | Req transport and Tokamak endpoint policy |
| `Synapse.Provider.Credentials` | MVP environment credential boundary |
| `Synapse.Provider.Fake` | Scripted deterministic provider |

Do not create all modules before their phase. The table defines ownership, not an instruction to generate empty files.

## Public Contracts

### Provider Behaviour

```elixir
@type event_sink :: (Synapse.Provider.Event.t() -> :ok)

@callback stream(
  Synapse.Provider.Request.t(),
  event_sink(),
  Synapse.Provider.StreamContext.t()
) ::
  {:ok, Synapse.Provider.Response.t()}
  | {:error, Synapse.Provider.Error.t()}
```

The event sink is synchronous for the MVP. This creates natural backpressure and keeps event ordering deterministic. If this proves too restrictive, change it only with evidence from a working stream.

### Provider Request

```elixir
%Synapse.Provider.Request{
  model: model,
  instructions: instructions,
  input_items: input_items,
  tools: tool_specs,
  metadata: sanitized_metadata
}
```

The request does not contain:

- API keys.
- Req options.
- Tokamak endpoint paths.
- Retry policy.
- Terminal-rendering state.
- Workspace handles.

### Stream Context

```elixir
%Synapse.Provider.StreamContext{
  operation_id: operation_id,
  cancel_ref: cancel_ref,
  inactivity_ms: inactivity_ms,
  deadline: deadline,
  activity_sink: activity_sink
}
```

Cancellation uses `{:cancel, cancel_ref}` sent to the process blocked in `stream/3`. That coordinator kills its monitored request worker, which closes the owned Finch request. Runtime can therefore stop an operation without Provider importing Runtime.

### Provider Response

```elixir
%Synapse.Provider.Response{
  id: response_id,
  model: model,
  output_items: output_items,
  usage: usage,
  status: :completed
}
```

### Output Items

```elixir
%Synapse.Provider.OutputItem.Message{
  id: item_id,
  role: :assistant,
  content: content
}
```

```elixir
%Synapse.Provider.OutputItem.FunctionCall{
  id: item_id,
  call_id: call_id,
  name: name,
  arguments: arguments
}
```

Function-call arguments use string-keyed maps after complete JSON decoding.

### Provider Error

```elixir
%Synapse.Provider.Error{
  kind: kind,
  message: sanitized_message,
  status: http_status,
  retryable: retryable?,
  output_started: output_started?,
  operation_id: operation_id,
  details: sanitized_details
}
```

Initial error kinds:

```text
configuration
authentication
authorization
rate_limited
unavailable
timeout
transport
protocol
interrupted
upstream
```

Provider classifies retryability. Agent or Runtime decides whether another attempt is permitted.

### Provider Events

The implementation may place these structs in one source file initially, but each must have a documented type and meaning.

```text
MessageStarted
TextDelta
ToolCallStarted
ToolCallDelta
ToolCallCompleted
MessageCompleted
Diagnostic
```

`Diagnostic` is for sanitized, non-terminal compatibility information such as an ignored unknown wire event. It must not become a dumping ground for raw bodies.

## Tokamak MVP Contract

```text
base URL: https://api.tokamak.sh/v1/agent-pool/codex-proxy
method:   POST
path:     /responses
wire:     OpenAI Responses
stream:   true
store:    false
auth:     Authorization: Bearer <TOKAMAK_API_KEY>
```

The provider should construct top-level `instructions` directly and omit `max_output_tokens` for this endpoint. Tools use canonical flat Responses function definitions.

The implementation does not call `tokamak launch`, does not call `launch-auth` for every request, and does not receive pooled OpenAI credentials.

## Phase 0: Confirm Prerequisites

### Setup Decision Record

| Decision | Current value | Reason |
| --- | --- | --- |
| Supported Elixir | `~> 1.20` | Starts Synapse on the latest available Elixir language series |
| Verified runtime | Elixir 1.20.2, Erlang/OTP 28.5.0.3, Mix 1.20.2 | Toolchain installed through `nix profile install nixpkgs#beam28Packages.elixir_1_20` |
| HTTP dependency | Req 0.7.1 | Current stable Req release selected for Tokamak streaming |
| Documentation dependency | ExDoc 0.40.3 | Current stable ExDoc release selected for the learning and API documentation contract |
| Tokamak base URL | `https://api.tokamak.sh/v1/agent-pool/codex-proxy` | Public gateway path to the server-side Codex credential pool |
| Credential input | `TOKAMAK_API_KEY` environment variable | Keeps the key out of CLI arguments, source, and normalized Provider contracts |
| Live-test policy | `:live_tokamak`, excluded by default | Keeps ordinary tests deterministic and credential-free |
| First model identifier | `gpt-5.6-sol` | Confirmed by a successful live text request through the Tokamak Codex pool on July 30, 2026 |
| Cancellation primitive | `{:cancel, cancel_ref}` to the operation coordinator | The coordinator kills its monitored request worker; worker death closes the owned Finch request |

### Architecture

- [x] Confirm `PLAN.md` still defines Provider as a lower component called by Agent.
- [x] Confirm Provider has no dependency on Agent, Tool, Workspace, CLI, or Runtime modules.
- [x] Confirm the MVP endpoint is the Tokamak Codex pool proxy, not generic `/v1/responses`.
- [x] Confirm the first model identifier available to the supplied Tokamak API key.
- [x] Confirm the production Tokamak gateway base URL.
- [x] Confirm the minimum Elixir and OTP versions.
- [x] Confirm Req and ExDoc are available in the Mix project.
- [x] Confirm live tests will use an explicit tag and remain disabled by default.

### Security

- [x] Confirm the API key will be supplied only through `TOKAMAK_API_KEY`.
- [x] Confirm no real key exists in repository files or shell command examples.
- [x] Confirm provider debug output is disabled or sanitized before the first live request.

### Learning Gate

- [x] Explain why Tokamak pool access is an HTTP provider boundary rather than a CLI subprocess integration.
- [x] Explain why the Provider must not own tool execution or conversation continuation.
- [x] Record unresolved decisions in this document before writing code.

### Phase Complete When

- [x] All required versions, endpoint values, model value, and live-test policy are recorded.
- [x] No implementation uncertainty remains that would change the Provider boundary.

## Phase 1: Implement Provider Contracts

### Code

- [x] Create `Synapse.Provider` behaviour.
- [x] Create `Synapse.Provider.Request`.
- [x] Create `Synapse.Provider.Response`.
- [x] Create `Synapse.Provider.Error`.
- [x] Create provider output item types.
- [x] Create provider event types.
- [x] Create `Synapse.Provider.StreamContext`.
- [x] Add constructors or validation functions for externally assembled contracts.
- [x] Keep all decoded external keys as strings.
- [x] Add custom `Inspect` implementations only where they prevent accidental disclosure or unreadable output.

### Tests

- [x] Construct a valid Provider Request.
- [x] Reject a request without a model.
- [x] Reject malformed input item and tool definitions.
- [x] Construct each event and output item type.
- [x] Verify Provider Error never requires raw response bodies.
- [x] Verify contract inspection cannot expose a secret because contracts contain no secret.

### Documentation

- [x] Add `@moduledoc` to every public contract module.
- [x] Explain which component creates and consumes each contract.
- [x] Add `@type t()` and complete `@spec` declarations.
- [x] Document the difference between Provider Event, Provider Response, and Provider Error.
- [x] Add one ExDoc example showing a normalized text-only request.

### Learning Gate

- [x] Explain why explicit structs are used instead of unrelated maps.
- [x] Explain why Provider Error carries `output_started` and `retryable` separately.
- [x] Trace one Request from Agent to Provider without mentioning Tokamak JSON.

### Phase Complete When

- [x] Contracts compile with warnings as errors.
- [x] Contract tests pass.
- [x] LSP hover explains every field's purpose and ownership.
- [x] No transport code exists yet.

## Phase 2: Implement Incremental SSEDecoder

### Boundary

`SSEDecoder` accepts arbitrary binary chunks and emits protocol-neutral `SSEEvent` values. It does not decode JSON and does not know OpenAI event names.

### API

```elixir
SSEDecoder.new(options)
SSEDecoder.feed(state, chunk)
SSEDecoder.finish(state)
```

### Code

- [x] Define decoder state explicitly.
- [x] Buffer incomplete lines across chunks.
- [x] Support LF and CRLF line endings.
- [x] Parse `event`, `data`, `id`, and `retry` fields.
- [x] Join multiple `data` lines according to SSE rules.
- [x] Ignore comment lines while allowing them to count as transport activity.
- [x] Emit an event only at a blank-line boundary.
- [x] Handle an event with no explicit `event` name.
- [x] Preserve UTF-8 bytes split across HTTP chunks.
- [x] Set a maximum line size.
- [x] Set a maximum event data size.
- [x] Return a structured protocol error when a limit is exceeded.
- [x] Define EOF behavior for complete and incomplete buffered events.
- [x] Avoid repeated full-buffer concatenation for large streams.

### Tests

- [x] Parse one complete SSE event.
- [x] Split the fixture at every possible byte boundary.
- [x] Feed one byte at a time.
- [x] Parse LF and CRLF fixtures.
- [x] Parse multiple events in one chunk.
- [x] Parse one event across many chunks.
- [x] Parse multiple `data` lines.
- [x] Ignore comments.
- [x] Preserve unknown fields safely.
- [x] Handle blank data.
- [x] Reject an oversized line.
- [x] Reject oversized accumulated event data.
- [x] Test incomplete EOF behavior.
- [x] Test UTF-8 split boundaries.

### Documentation

- [x] Explain that HTTP chunks are not SSE event boundaries.
- [x] Document decoder state and why it is pure data rather than a process.
- [x] Document every configured size limit.
- [x] Add an ExDoc example feeding one event in three chunks.
- [x] Link to the ResponsesStream module as the JSON-aware consumer.

### Learning Gate

- [x] Explain the difference between TCP or HTTP chunks, lines, SSE frames, JSON objects, and provider events.
- [x] Explain why SSEDecoder should remain a pure state machine.
- [x] Walk through the state after each chunk in one test fixture.

### Phase Complete When

- [x] Every chunk-boundary test passes.
- [x] No JSON library is imported by SSEDecoder.
- [x] The decoder can be understood independently through ExDoc.

## Phase 3: Implement ResponsesCodec

### Boundary

`ResponsesCodec` converts normalized Provider Request data into canonical OpenAI Responses JSON-ready maps. It does not perform HTTP and does not resolve credentials.

### Code

- [x] Encode the model.
- [x] Encode top-level instructions.
- [x] Encode user and assistant input messages.
- [x] Encode assistant function-call output items for conversation replay.
- [x] Encode `function_call_output` items with matching call IDs.
- [x] Encode canonical flat function tool definitions.
- [x] Set `stream` to true.
- [x] Set `store` to false.
- [x] Omit `previous_response_id` for the MVP.
- [x] Omit `max_output_tokens` for the Tokamak Codex pool profile.
- [x] Omit absent optional fields rather than encoding arbitrary nulls.
- [x] Reject unsupported input item variants before HTTP.
- [x] Reject malformed tool schemas before HTTP.
- [x] Ensure encoded maps contain no credentials or Req options.

### Contract Fixtures

- [x] Text-only request.
- [x] Request with one function tool.
- [x] Request with all four future built-in tool schemas.
- [x] Conversation containing an assistant function call.
- [x] Conversation containing matching function-call output.
- [x] Multiple function calls and outputs in source order.

### Tests

- [x] Compare each encoded request with a readable fixture.
- [x] Assert tools use flat Responses fields rather than nested Chat Completions fields.
- [x] Assert instructions are top-level.
- [x] Assert `stream: true` and `store: false`.
- [x] Assert `max_output_tokens` is absent.
- [x] Assert no secret-shaped field is accepted.
- [x] Assert function-call output preserves the original call ID.

### Documentation

- [x] Explain why normalized Provider Request is separate from wire encoding.
- [x] Document every supported input item.
- [x] Document the Tokamak-specific omission of `max_output_tokens`.
- [x] Add an example showing a tool continuation request.

### Learning Gate

- [x] Explain why Provider sends full projected conversation input rather than relying on pool account state.
- [x] Explain the difference between Responses flat tools and generic Tokamak nested tools.
- [x] Trace a Tool Result into its encoded `function_call_output` item.

### Phase Complete When

- [x] All request fixtures pass.
- [x] The encoder contains no HTTP code.
- [x] The supported wire surface is fully visible in ExDoc.

## Phase 4: Implement ResponsesStream

### Boundary

`ResponsesStream` accepts framed SSE events, decodes Responses JSON, maintains one response's accumulation state, and emits normalized Provider Events.

### State

```text
response ID
model
response status
text content by output item
function calls by item ID and call ID
function name
function argument fragments
output item order
usage
whether model output started
whether a terminal event was observed
```

### Code

- [x] Decode each `data` payload as JSON only after SSE framing is complete.
- [x] Recognize `response.created`.
- [x] Recognize text item start and text deltas.
- [x] Recognize function-call item start.
- [x] Accumulate function-call arguments across arbitrary event boundaries.
- [x] Key calls by item ID and call ID rather than only array index.
- [x] Support multiple interleaved function calls.
- [x] Decode arguments into a string-keyed map only after `arguments.done`.
- [x] Emit `ToolCallCompleted` only after successful complete argument decoding.
- [x] Recognize `response.completed`.
- [x] Extract response ID, model, output items, and usage where present.
- [x] Recognize `response.failed`.
- [x] Recognize `[DONE]` where present without requiring it.
- [x] Ignore unknown future events while emitting a bounded sanitized Diagnostic.
- [x] Reject malformed JSON with a protocol error.
- [x] Reject malformed completed function arguments.
- [x] Reject completion when a function call remains incomplete.
- [x] Reject EOF without a terminal Responses event.
- [x] Preserve output item source order.

### Tests

- [x] Text-only response stream.
- [x] Text split across many deltas.
- [x] Single function call.
- [x] Function arguments split across many deltas.
- [x] Multiple interleaved function calls.
- [x] Function calls and text in one response where supported.
- [x] Empty function arguments object.
- [x] Malformed function arguments.
- [x] Missing `arguments.done`.
- [x] Unknown event between known events.
- [x] `response.failed` before output.
- [x] `response.failed` after output.
- [x] EOF before completion.
- [x] Completion with usage.
- [x] Completion without usage.
- [x] Stream with and without `[DONE]`.

### Documentation

- [x] Explain why ResponsesStream is separate from SSEDecoder and Tokamak transport.
- [x] Document the response accumulation state.
- [x] Document when a tool call becomes executable.
- [x] Document unknown-event compatibility policy.
- [x] Add a diagram showing one function call from delta to completed output item.

### Learning Gate

- [x] Explain why stream parsing is a reducer over immutable state.
- [x] Explain how interleaved tool calls remain deterministic.
- [x] Explain why malformed completed arguments are a provider protocol failure rather than a tool execution failure.

### Phase Complete When

- [x] All text, tool, failure, and interruption fixtures pass.
- [x] Raw response maps remain internal.
- [x] No incomplete tool call can be emitted as complete.
- [x] ExDoc explains the full Responses event lifecycle.

## Phase 5: Implement Credentials Boundary

### Boundary

`Credentials` resolves the Tokamak key immediately before request construction. No other Provider contract stores or transports the key.

### Code

- [x] Read `TOKAMAK_API_KEY` from the process environment.
- [x] Reject a missing value.
- [x] Reject an empty or whitespace-only value.
- [x] Return a dedicated configuration error with no secret content.
- [x] Keep the resolved value in the narrowest practical function scope.
- [x] Prevent default inspection from printing a wrapped secret if a wrapper struct is used.
- [x] Provide a test credential source without modifying the global environment.
- [x] Avoid reading credentials during module compile or application startup.
- [x] Avoid logging whether two supplied keys are equal or exposing suffixes by default.

### Tests

- [x] Missing key.
- [x] Empty key.
- [x] Valid test key.
- [x] Inspect output redaction if a secret wrapper exists.
- [x] Provider Request inspection contains no key.
- [x] Provider Event and Error inspection contains no key.
- [x] Captured Logger output contains no test key.

### Documentation

- [x] Explain why environment lookup is an MVP adapter rather than the final credential broker.
- [x] Document when the key enters and leaves Provider execution.
- [x] Document why the key is not accepted as a CLI argument.
- [x] Document the future replacement boundary for keychain storage.

### Learning Gate

- [x] Trace the key from environment lookup to the HTTP header and identify every object that can observe it.
- [x] Explain why redaction is defense in depth rather than proof of non-disclosure.
- [x] Explain why credential lookup happens at request time.

### Phase Complete When

- [x] Credential tests pass without changing the developer's environment.
- [x] No shared Provider contract contains a credential field.
- [x] Documentation clearly states the MVP security limitations.

## Phase 6: Implement Tokamak Transport

### Boundary

`Synapse.Provider.Tokamak` owns one Req request attempt. It encodes the request, resolves credentials, streams response chunks through SSEDecoder and ResponsesStream, emits normalized events, and returns one terminal result.

### Configuration

- [x] Default base URL is `https://api.tokamak.sh/v1/agent-pool/codex-proxy`.
- [x] Path is `/responses`.
- [x] Model is required from configuration.
- [x] Production origin is fixed or explicitly trusted.
- [x] Tests can inject a local Req adapter or endpoint without exposing a production override to model input.
- [x] User-Agent identifies Synapse without leaking host details.

### Request

- [x] Use HTTP POST.
- [x] Set `Authorization: Bearer <key>`.
- [x] Set `Content-Type: application/json`.
- [x] Set `Accept: text/event-stream`.
- [x] Encode the body through ResponsesCodec.
- [x] Enforce a request-size limit below Tokamak's upstream limit.
- [x] Disable hidden automatic request retries.
- [x] Reject redirects that would forward authorization to another origin.

### Streaming Ownership

- [x] Run the request in the process designated by StreamContext.
- [x] Use controlled streaming callbacks rather than an unbounded mailbox firehose.
- [x] Feed every body chunk into SSEDecoder.
- [x] Feed every SSE frame into ResponsesStream.
- [x] Emit normalized Provider Events synchronously in order.
- [x] Notify the activity sink for meaningful stream progress.
- [x] Retain the underlying request cancellation handle.
- [x] Cancel the HTTP request when cancellation is requested.
- [x] Stop processing immediately after a terminal response or error.
- [x] Finalize both decoder states at EOF.

### HTTP Status Classification

- [x] Map 401 to authentication.
- [x] Map 403 to authorization.
- [x] Map 408 to timeout or retryable upstream failure.
- [x] Map 429 to rate limited.
- [x] Map retryable 5xx responses to unavailable or upstream.
- [x] Map transport errors to transport.
- [x] Map malformed successful bodies to protocol.
- [x] Preserve status code and safe request identifiers.
- [x] Bound and sanitize provider error bodies.
- [x] Set `output_started` from ResponsesStream state.
- [x] Classify retryability without performing the retry.

### Tests

- [x] Successful text stream through Req test adapter.
- [x] Successful function-call stream.
- [x] Request headers and body.
- [x] Request-size rejection.
- [x] Redirect rejection.
- [x] 401, 403, 408, 429, and 5xx mappings.
- [x] Transport disconnect before output.
- [x] Transport disconnect after output.
- [x] Inactivity timeout.
- [x] Absolute deadline.
- [x] Explicit cancellation.
- [x] Slow event sink backpressure.
- [x] Secret absent from errors and captured logs.
- [x] Exactly one terminal result.

### Documentation

- [x] Explain which process owns the Req stream.
- [x] Explain how cancellation reaches the request.
- [x] Explain why Tokamak transport performs one attempt only.
- [x] Document every HTTP timeout and size limit.
- [x] Document endpoint and redirect trust.
- [x] Link to the detailed Tokamak findings in `docs/PROVIDERS.md`.

### Learning Gate

- [x] Explain Req and Finch ownership in the running process tree.
- [x] Explain how synchronous event emission supplies backpressure.
- [x] Explain how one partial HTTP stream becomes an interrupted Provider Error.
- [x] Explain why retry classification and retry execution belong to different components.

### Phase Complete When

- [x] All adapter-backed transport tests pass.
- [x] Cancellation stops the owned request.
- [x] Provider emits only normalized data.
- [x] No automatic retry can replay partial output.
- [x] LSP and ExDoc explain the complete transport lifecycle.

## Phase 7: Implement Fake Provider

### Boundary

`Fake` implements the same Provider behaviour using a deterministic per-turn script. It has no network, environment, Req, or Tokamak dependency.

### Script Model

```elixir
[
  {:turn, [events], {:ok, response}},
  {:turn, [events], {:error, error}}
]
```

The exact representation may use structs, but scripts must remain readable in Agent Loop tests.

### Code

- [x] Implement Provider behaviour.
- [x] Emit scripted events in source order.
- [x] Return scripted terminal response or error.
- [x] Validate that the Agent sends the expected request for each turn.
- [x] Support text-only completion.
- [x] Support one and multiple function calls.
- [x] Support failure before output.
- [x] Support interruption after output.
- [x] Support malformed or incomplete event sequences for defensive tests.
- [x] Support cancellation during scripted execution.
- [x] Avoid sleeping in ordinary tests.

### Tests

- [x] Behaviour conformance.
- [x] Deterministic event order.
- [x] Expected request assertion.
- [x] Multi-turn script consumption.
- [x] Exhausted script error.
- [x] Cancellation.

### Documentation

- [x] Explain why Fake belongs inside the Provider component.
- [x] Document script syntax with a text example and a tool-call example.
- [x] Explain which failure cases Fake is intended to reproduce.
- [x] Ensure examples are readable enough to serve as Agent Loop specifications.

### Learning Gate

- [x] Explain why a mock Req response is insufficient for testing the Agent Loop.
- [x] Explain the difference between transport contract tests and Provider behaviour tests.
- [x] Write one Fake script without consulting implementation internals.

### Phase Complete When

- [x] Fake passes behaviour tests.
- [x] Another component can test a multi-turn interaction without network access.
- [x] Fake scripts are understandable through ExDoc and test names.

## Phase 8: Reliability And Security Hardening

### Limits

- [x] Bound request bytes.
- [x] Bound HTTP error body bytes.
- [x] Bound SSE line bytes.
- [x] Bound SSE event bytes.
- [x] Bound accumulated function arguments.
- [x] Bound total provider output.
- [x] Bound diagnostics.
- [x] Reject integer overflow or unreasonable configured limits.

### Cancellation And Failure

- [x] Guarantee at most one terminal Provider result.
- [x] Guarantee events stop after terminal result.
- [x] Guarantee partial stream errors set `output_started` correctly.
- [x] Guarantee malformed function calls are never completed.
- [x] Guarantee decoder errors cancel the HTTP operation.
- [x] Guarantee event-sink failures stop the stream safely.
- [x] Guarantee caller termination does not leave an owned request running.

### Secret Safety

- [x] Search all Provider structs for credential fields.
- [x] Search all logging calls for headers, body dumps, and credential values.
- [x] Test redaction with a recognizable synthetic key.
- [x] Confirm fixtures contain no real endpoint tokens or account data.
- [x] Confirm doctests and examples use placeholders only.
- [x] Confirm crash reports use sanitized errors.

### Compatibility

- [x] Preserve unknown Responses events as bounded diagnostics.
- [x] Do not require `[DONE]` after `response.completed`.
- [x] Preserve source order for multiple output items.
- [x] Keep Tokamak endpoint rewrites isolated in Tokamak or ResponsesCodec policy.
- [x] Record the fixture source and compatibility date without storing secrets.

### Documentation

- [x] Add a provider error taxonomy table.
- [x] Add a limits table with defaults and rationale.
- [x] Add a cancellation sequence diagram.
- [x] Add a security section listing what redaction cannot guarantee.
- [x] Add a compatibility section describing private Codex backend risk.

### Learning Gate

- [x] Explain every size and time limit and what resource it protects.
- [x] Explain the difference between failure, interruption, and cancellation.
- [x] Explain why an unknown event can be ignored but malformed known data cannot.
- [x] Trace a synthetic secret through a failing request and prove where redaction occurs.

### Phase Complete When

- [x] Reliability and security tests pass.
- [x] No unbounded parser or accumulator remains.
- [x] No known log or inspection path exposes credentials.
- [x] Documentation states real limitations rather than claiming perfect secrecy.

## Phase 9: Live Tokamak Acceptance

### Test Policy

- [x] Mark live tests with `@tag :live_tokamak`.
- [x] Exclude live tests by default.
- [x] Require `TOKAMAK_API_KEY` and `SYNAPSE_MODEL` at runtime.
- [x] Skip with a clear message when live credentials are absent.
- [x] Never run live tests from untrusted pull requests.
- [x] Never record unsanitized live response bodies.

### Text Smoke Test

- [x] Send a minimal text-only request.
- [x] Observe `MessageStarted`.
- [x] Observe at least one non-empty `TextDelta`.
- [x] Observe `MessageCompleted`.
- [x] Receive a completed Provider Response.
- [x] Confirm response model and ID are represented safely.

### Function-Call Smoke Test

- [x] Expose one harmless synthetic function schema.
- [x] Ask the model explicitly to call the function.
- [x] Observe function-call start.
- [x] Observe argument accumulation.
- [x] Observe exactly one completed normalized function call.
- [x] Confirm string-keyed decoded arguments.
- [x] Do not execute the function in this Provider test.

### Failure Smoke Tests

- [x] Test a deliberately invalid Tokamak key manually or through a controlled fixture, never CI secrets.
- [x] Confirm the error is authentication with no key disclosure.
- [x] Confirm cancellation interrupts a live text request.
- [x] Confirm live output is not automatically retried after cancellation.

### Sanitized Fixtures

- [x] Save only the minimal sanitized event shapes needed for contract regression tests.
- [x] Remove IDs, account metadata, prompts, generated private content, and headers not required by the parser.
- [x] Document Tokamak and Codex compatibility date.
- [x] Review fixture diff manually before commit.

### Phase Complete When

- [x] Text and function-call smoke tests pass with the supplied API key.
- [x] Default test suite still runs without network or credentials.
- [x] Sanitized fixtures reproduce the observed wire behavior.
- [x] No live secret or identifying metadata entered the repository.

## Phase 10: ExDoc And Comprehension Review

### Module Documentation

- [x] Every public Provider module has `@moduledoc`.
- [x] Every public function and callback has purpose-oriented `@doc`.
- [x] Every public function and callback has `@spec`.
- [x] Every public struct has `t()` and documented fields.
- [x] Every public error and event explains who creates and consumes it.
- [x] `@moduledoc false` and `@doc false` are absent unless explicitly justified.

### Required Explanations

- [x] Why Provider is separate from Agent.
- [x] Why Tokamak is a direct HTTP integration rather than a CLI subprocess.
- [x] Why SSEDecoder is separate from ResponsesStream.
- [x] Why ResponsesCodec is separate from Tokamak transport.
- [x] Why Fake is a first-class Provider implementation.
- [x] Why credentials enter only at the transport boundary.
- [x] Why Provider classifies retries but does not execute them.
- [x] Why partial output cannot be transparently replayed.

### Required Diagrams

- [x] Provider internal component diagram.
- [x] HTTP chunk to Provider Event pipeline.
- [x] Function-call accumulation sequence.
- [x] Cancellation and terminal failure sequence.

### Examples

- [x] Build a text-only Provider Request.
- [x] Encode a request with one function tool.
- [x] Feed SSEDecoder incrementally.
- [x] Interpret a ToolCallCompleted event.
- [x] Configure a Fake provider script.

### Comprehension Questions

- [x] Can the owner identify which module owns every byte from HTTP chunk to text delta?
- [x] Can the owner explain which state is immutable and which process owns stream lifetime?
- [x] Can the owner trace cancellation from StreamContext to Req shutdown?
- [x] Can the owner explain when a function call is safe to execute?
- [x] Can the owner distinguish Provider Error from tool failure?
- [x] Can the owner add a new known Responses event without changing Tokamak transport?
- [x] Can the owner test Agent behavior without a Tokamak key?
- [x] Can the owner find all credential-touching code from ExDoc and LSP?

### Phase Complete When

- [x] `mix docs` succeeds without provider documentation warnings.
- [x] All examples and doctests pass.
- [x] The Provider can be understood without the original AI conversation.
- [x] Known tradeoffs and deferred capabilities are explicit.

## Test Matrix

| Layer | Primary proof | Network required |
| --- | --- | --- |
| Contracts | Unit tests and types | No |
| SSEDecoder | Byte-boundary fixtures | No |
| ResponsesCodec | Request fixtures | No |
| ResponsesStream | Sanitized event fixtures | No |
| Credentials | Synthetic secret tests | No |
| Tokamak transport | Req adapter contract tests | No |
| Fake provider | Behaviour and script tests | No |
| Tokamak text | Live smoke test | Yes |
| Tokamak function call | Live smoke test | Yes |
| ExDoc | Documentation build and doctests | No |

## Suggested Test Layout

```text
test/
  fixtures/provider/
    responses_text.sse
    responses_tool_call.sse
    responses_multiple_tool_calls.sse
    responses_failed.sse
    responses_unknown_event.sse

  synapse/provider/
    contracts_test.exs
    sse_decoder_test.exs
    responses_codec_test.exs
    responses_stream_test.exs
    credentials_test.exs
    tokamak_test.exs
    fake_test.exs
    live_tokamak_test.exs
```

Fixtures should remain small and readable. Prefer assembling specialized events in test builders over storing large opaque provider transcripts.

## Suggested Commit Sequence

1. `Define normalized provider contracts`
2. `Add incremental SSE decoder`
3. `Encode canonical Responses requests`
4. `Normalize Responses stream events`
5. `Add Tokamak credential boundary`
6. `Stream text from Tokamak`
7. `Normalize Tokamak function calls`
8. `Add deterministic fake provider`
9. `Harden provider limits and cancellation`
10. `Document and verify live Tokamak provider`

Each commit must compile, pass focused tests, and include the documentation for its public behavior.

## Final Provider Verification

```bash
mix compile --warnings-as-errors
mix format --check-formatted
mix test
mix docs
```

The opt-in live verification is:

```bash
TOKAMAK_API_KEY="..." \
SYNAPSE_MODEL="..." \
mix test --only live_tokamak test/live_tokamak_test.exs
```

## Provider Definition Of Done

- [x] Phases 0 through 10 are complete.
- [x] Provider boundary matches `PLAN.md`.
- [x] Tokamak endpoint behavior matches `docs/PROVIDERS.md`.
- [x] Text and function-call streams work live.
- [x] Deterministic tests need no live key.
- [x] Cancellation stops the HTTP operation.
- [x] Partial output is never reported as ordinary completion.
- [x] Malformed function arguments are never emitted as executable calls.
- [x] Provider performs no hidden retry.
- [x] No raw Tokamak map leaves Provider.
- [x] No secret appears in Provider logs, events, errors, fixtures, examples, or returned contracts.
- [x] Every parser and accumulator is bounded.
- [x] LSP explains the purpose and intended use of every public API.
- [x] ExDoc explains architecture, ownership, event flow, errors, cancellation, limits, and security.
- [x] The owner can maintain the Provider without referring to the original AI conversation.

## Deferred Provider Work

Do not add these before the MVP Provider is complete:

- Direct OpenAI Codex OAuth.
- Direct ChatGPT Codex endpoint support.
- Generic Tokamak `/v1/responses`.
- OpenAI-compatible Responses profiles.
- OpenAI-compatible Chat Completions profiles.
- Dynamic provider registration.
- Provider fallback and model routing.
- Server-side response persistence.
- Keychain-backed credential broker.
- Provider marketplace or extension loading.
- Rich Responses content such as reasoning, images, refusals, annotations, and hosted tools.
- Non-streaming successful response bodies and structured-output profiles.
- Health checks, endpoint discovery, and provider telemetry.
- Capability-enforced credential leases and cooperative cancellation evaluation.
- Higher-layer conversation compaction for full-history request projection.
- SSE retry-hint policy; the MVP parses but deliberately ignores retry hints.
- Replacement of Fake's `:global` operation registry if distributed tests require it.

These features should reuse the Provider contracts, ResponsesCodec, SSEDecoder, and ResponsesStream established by this checklist.
