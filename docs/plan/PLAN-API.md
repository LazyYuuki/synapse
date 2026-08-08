# Local WebSocket API Implementation Checklist

## Purpose

This document is the implementation checklist for the Local WebSocket API
defined in [`PLAN.md`](PLAN.md).

It turns the completed Runtime ownership contract in
[`PLAN-RUNTIME.md`](PLAN-RUNTIME.md) into a bounded, versioned local protocol for
independent web, TUI, and desktop clients. It records the protocol, process
ownership, supervision, replay, security, testing, documentation, and acceptance
decisions required to implement Step 6 without moving frontend concerns into the
core application.

The checklist is intentionally limited to the API adapter. It does not change
Provider, Agent, Tool, Workspace, or Runtime semantics; implement a frontend;
serve static assets; add durable storage; recover runs across application restart;
or expose Synapse beyond the local machine.

## API Outcome

The API is complete when an external local protocol client can start one bounded
run, receive ordered progress, disconnect without cancelling it, resubscribe from
a retained cursor or reset snapshot, request cancellation, and observe one
structured terminal.

```text
mix synapse.server
  -> GET http://127.0.0.1:4848/health
  -> WS  ws://127.0.0.1:4848/v1/socket
  -> run.start
  -> run.accepted
  -> ordered run.event messages
  -> run.terminal
```

The deterministic proof uses the real API, Runtime, Agent, Tool, and Workspace
boundaries with Fake Provider and Fake Workspace dependencies supplied only by
trusted test configuration. The final live proof uses Tokamak and a temporary
real workspace.

## Checklist Rules

- Check implementation items only after focused tests, public documentation, and
  relevant learning notes are complete. A Phase 0 decision confirmation may be
  checked from current package docs and resolved source, with focused executable
  tests for critical integration assumptions.
- Do not use a live Tokamak request where deterministic tests can prove behavior.
- Preserve Runtime's owner-only `await/2` contract; a socket must never own a
  Runtime run.
- Never let disconnect imply cancellation.
- Never accept modules, callbacks, capabilities, credentials, supervisors,
  Runtime options, or opaque handles from JSON.
- Never generically JSON-encode a struct.
- Keep decoded external keys as strings and never create atoms from wire input.
- Bound every frame, identifier, collection, replay window, subscriber set, and
  retained run collection before accepting input.
- Keep replay explicitly in-memory and process-lifetime only.
- Use temporary workspaces for process and live tests; never target a user
  checkout.
- Avoid scheduler sleeps in deterministic tests. Use monitors, barriers,
  explicit messages, and bounded receives.
- If a public wire shape or ownership rule changes, update this plan and
  `PLAN.md` before continuing.

## Progress Summary

| Phase | Deliverable                                                         | Status   |
| ----- | ------------------------------------------------------------------- | -------- |
| 0     | Confirm dependencies, protocol, ownership, limits, and trust policy | Complete |
| 1     | API configuration and internal contracts                            | Complete |
| 2     | Strict protocol decoder and explicit wire encoder                   | Complete |
| 3     | Bounded RunManager projections, replay, and subscriptions           | Complete |
| 4     | RunSession Runtime ownership and settlement                         | Complete |
| 5     | WebSocket lifecycle and bounded delivery                            | Complete |
| 6     | Router, supervision, and `mix synapse.server`                       | Complete |
| 7     | Deterministic end-to-end acceptance                                 | Complete |
| 8     | Reliability and security hardening                                  | Complete |
| 9     | Live Tokamak acceptance                                             | Complete |
| 10    | ExDoc and comprehension review                                      | Complete |

Update this table only when a phase passes its completion gate.

## Architectural Position

```text
Web / TUI / Desktop client
             |
             v
     +-------------------+
     | API Router/Socket |
     +---------+---------+
               |
               v
     +-------------------+
     | API RunManager    |
     | bounded state     |
     +----+---------+----+
          |         |
          v         v
   RunSession    subscriptions
          |
          v
   Synapse.Runtime
          |
          v
   Agent / Tool / Workspace / Provider
```

The API is a trusted local adapter above Runtime. It may construct a validated
Run Request and trusted Runtime options from server policy, but it may not call
Agent, Tool, Workspace, or Provider directly.

## Dependency Direction

```text
Mix.Tasks.Synapse.Server
  -> Synapse application configuration and startup

Router
  -> Plug, Bandit, WebSockAdapter
  -> Origin and Host policy

Socket
  -> Protocol
  -> RunManager
  -> Wire

RunManager
  -> SessionSupervisor
  -> Runtime.cancel/1
  -> bounded API-owned projection data

RunSession
  -> Run Request and Budget
  -> Runtime.start_run/3
  -> Runtime.await/2

API
  -X-> Provider transport or credentials
  -X-> Agent Runner or conversation state
  -X-> Tool schemas or dispatch
  -X-> Workspace Handles or direct host operations
  -X-> frontend frameworks or static assets
```

## API Boundary

### API Owns

- Loopback HTTP and WebSocket transport.
- Protocol versioning and strict JSON validation.
- Server-assigned run IDs and request correlation.
- Construction of trusted Run Requests from validated wire data and server
  policy.
- One temporary Runtime-owning RunSession per active run.
- One bounded in-memory run projection and replay window.
- Process-lifetime run lookup, subscriptions, and cancellation routing.
- Explicit allowlisted conversion from Run Events and terminals to JSON.
- Local Host, Origin, query, header, and WebSocket-subprotocol policy.
- The `mix synapse.server` startup adapter.

### API Does Not Own

- Model conversation, Tool order, retries, budgets, or terminal semantics.
- Provider selection from client input, Provider HTTP, or credentials.
- Tool capability construction from client booleans.
- Workspace path containment, revisions, processes, or cleanup.
- Runtime worker supervision or owner-only await semantics.
- Frontend rendering, assets, sessions, or UI state.
- Durable event identity, persistence, application-restart recovery, or crash
  replay.
- Remote authentication, authorization, TLS, network sandboxing, or multi-user
  isolation.

## Architectural Invariants

- `Synapse.API.RunSession` is the process that calls both
  `Runtime.start_run/3` and `Runtime.await/2`.
- `RunManager` may retain the opaque Runtime Run only to call non-owner
  `Runtime.cancel/1`; it never awaits or serializes it.
- Socket processes never receive a Runtime Run, Workspace Handle, callback,
  Provider response, capability struct, or cancellation reference.
- Socket retains a validated authority-free Policy projection rather than trusted
  Config; Provider, capability, Runtime option, and callback fields do not exist in
  that projection.
- RunSession and Runtime continue when every socket disconnects.
- The initiating socket's subscription capacity is checked before reservation,
  then that socket is subscribed before RunSession can emit observable progress.
- At most one active API run exists. A reservation occurs before starting
  RunSession so concurrent starts cannot race through Runtime.
- API acceptance means the run was reserved and RunSession was admitted. A later
  Runtime startup or Workspace-open failure becomes that run's terminal.
- Every exposed progress event and terminal receives one monotonically increasing
  per-run sequence number starting at 1.
- API sequence numbers are ephemeral. They are not Runtime event identities and
  are not stable across RunManager restart.
- Runtime terminal Run Events are validated and reduced to a bounded pending
  terminal projection until RunSession confirms the result from `await/2`. The
  projection omits `final_response` and retains exactly the fields compared and
  exposed by the API. If RunSession dies after Manager accepted a cleanup-gated
  terminal, that projection is independently authoritative. Clients receive one
  `run.terminal`, not a terminal `run.event` plus a duplicate terminal.
- A Runtime loss that cannot emit a terminal Run Event is converted from the
  typed `Runtime.Error` returned by `await/2`. This is the sole exposed terminal
  for which current Runtime cannot prove Workspace settlement because the outer
  RunServer and its cleanup state were lost.
- Replay contains only already exposed wire projections. It never replays Runtime,
  Agent, Provider, or Tool work.
- A stale retained cursor produces an explicit authoritative reset snapshot. A
  future cursor is rejected.
- Subscriber notifications are coalesced. A run creates at most one outstanding
  change notification per subscribed socket.
- Sockets pull bounded batches by cursor; RunManager never sends one mailbox
  message per event to every socket.
- Within API-owned retained state, prompts and workspace paths exist only in the
  validating Socket command and RunSession. The resulting trusted Run Request and
  lower Agent/Runtime execution necessarily retain them for the run; RunManager
  projections, errors, logs, and ordinary inspection do not.
- Every external enum is matched as a string against a fixed allowlist. No wire
  value reaches `String.to_atom/1` or equivalent.
- Client Budget values can only lower server policy. Omission uses server policy;
  a value above policy is rejected rather than silently granting more authority.
- Provider implementation, model allowlist, capabilities, Runtime options,
  instructions, Workspace limits, Tool limits, and credentials remain trusted
  server configuration.

## Internal Modules

| Module                          | Purpose                                                              |
| ------------------------------- | -------------------------------------------------------------------- |
| `Synapse.API.Config`            | Validated startup policy and all API hard limits                     |
| `Synapse.API.Supervisor`        | API manager, session owner, and listener lifecycle                   |
| `Synapse.API.SessionSupervisor` | Temporary RunSession children, maximum one active                    |
| `Synapse.API.RunManager`        | Run reservation, handles, projections, replay, subscribers, eviction |
| `Synapse.API.RunSession`        | Run Request construction and Runtime start/await ownership           |
| `Synapse.API.Protocol`          | Pure strict client-envelope and payload decoding                     |
| `Synapse.API.Wire`              | Pure explicit server-envelope, event, and terminal encoding          |
| `Synapse.API.Socket`            | WebSock connection state, commands, cursors, and bounded pulls       |
| `Synapse.API.Router`            | Health route, upgrade route, and local request policy                |
| `Mix.Tasks.Synapse.Server`      | Explicit server startup and foreground lifetime                      |

Do not generate empty modules. Add each module in its implementation phase.

## Confirmed MVP Decision Record

| Concern             | MVP decision                                                 | Reason                                                        |
| ------------------- | ------------------------------------------------------------ | ------------------------------------------------------------- |
| Server command      | `mix synapse.server`                                         | Keeps API startup explicit                                    |
| Bind address        | `127.0.0.1` only                                             | No accidental LAN exposure                                    |
| Default port        | `4848`                                                       | Stable endpoint for separate clients                          |
| Health route        | `GET /health`                                                | Minimal readiness without run data                            |
| WebSocket route     | `/v1/socket`                                                 | Major protocol version is visible before upgrade              |
| HTTP stack          | Bandit and Plug                                              | Small native Elixir server boundary                           |
| WebSocket stack     | WebSock and WebSockAdapter                                   | Framework-neutral socket callbacks and Plug upgrade           |
| JSON implementation | Elixir `JSON`                                                | No extra JSON dependency on the supported toolchain           |
| Messages            | Text JSON only; compression disabled                         | One bounded inspectable language-neutral protocol             |
| Active runs         | One                                                          | Matches Runtime's one-active-run MVP contract                 |
| Run IDs             | Server-assigned random URL-safe IDs                          | Clients cannot choose or collide with run authority           |
| Await owner         | One temporary RunSession                                     | Preserves Runtime mailbox ownership exactly                   |
| Cancellation holder | RunManager                                                   | Any connected local client can request cancellation by run ID |
| Disconnect          | Run continues                                                | Socket lifetime is not run lifetime                           |
| Replay              | Bounded RunManager memory only                               | Supports reconnect without claiming durability                |
| Slow clients        | Coalesced notification plus bounded pull                     | Avoids unbounded socket mailboxes                             |
| Origin              | Strict local-host validation; absent accepted                | Supports local browsers and native clients on loopback        |
| Authentication      | None in MVP                                                  | Trusted local-host reachability only, documented honestly     |
| Model selection     | Configured allowlist only                                    | A string cannot choose a module or unknown billing resource   |
| Capabilities        | Fixed-shape server policy, all enabled by production default | Client JSON never grants host authority                       |
| Budgets             | Optional lowering only                                       | Clients may request less work but not enlarge policy          |
| Frontend assets     | Never served                                                 | API remains frontend-agnostic                                 |

Phase 0 selected compatible dependency constraints from current Hex metadata and
resolved them in `mix.lock`; the exact record follows.

### Phase 0 Dependency Record

The project was verified with Elixir 1.20.2 and OTP 28. The selected packages,
constraints, and resolved versions are:

| Dependency      | Constraint  | Resolved | Scope and reason                                   |
| --------------- | ----------- | -------- | -------------------------------------------------- |
| Bandit          | `~> 1.12.4` | 1.12.4   | Runtime listener and WebSocket transport           |
| Plug            | `~> 1.20.3` | 1.20.3   | Direct Router and connection API                   |
| Thousand Island | `~> 1.5.0`  | 1.5.0    | Direct listener discovery and transport policy API |
| WebSock         | `~> 0.5.3`  | 0.5.3    | Direct Socket behavior contract                    |
| WebSockAdapter  | `~> 0.6.0`  | 0.6.0    | Direct Plug-to-WebSock upgrade API                 |
| Gun             | `~> 2.5`    | 2.5.0    | Test-only loopback WebSocket client                |

Bandit transitively depends on Plug, Thousand Island, and WebSock, and
WebSockAdapter depends on Plug and WebSock, but Synapse declares every package
whose public modules it compiles against.
Gun resolves Cowlib 2.19.0 and supports custom upgrade headers, text and binary
frames, and close frames/codes. MintWebSocket 1.0.5, WebSockex 0.5.1, and HTTP
WebSocket 0.11.0 were rejected because their Elixir frame parsers emit compiler
warnings on Elixir 1.20.

### Phase 0 Framework Record

- Bandit is the listener child. It returns its Thousand Island supervisor PID;
  `ThousandIsland.listener_info/1` returns the assigned address and port for
  trusted port-0 tests.
- The listener uses literal `ip: {127, 0, 0, 1}`, HTTP/1 only, and disables
  HTTP/2. `max_request_line_length: 8_192`, `max_header_count: 32`, and
  `max_header_length: 1_024` provide the recorded request and aggregate header
  ceilings.
- Thousand Island connection capacity is per acceptor. The global 128-connection
  limit therefore uses `num_acceptors: 1` and `num_connections: 128`; its
  `read_timeout` is 60,000 ms. This is inbound inactivity, not all traffic: server
  pushes do not reset it, so clients use protocol `ping` or another command within
  the interval. Listener shutdown drains for at most 5,000 ms; the Bandit child
  spec uses a 6,000 ms shutdown and the root gives API Supervisor an infinite
  supervisor shutdown like the other infrastructure owners.
- Bandit receives `max_frame_size: 2_097_166`,
  `max_fragmented_message_size: 2_097_152`, `validate_text_frames: true`, and
  `compress: false`. The upgrade repeats `timeout: 60_000`, `compress: false`,
  and `max_frame_size: 2_097_166`. Bandit's frame limit includes the largest
  14-byte masked wire header, while the protocol message and fragmented-message
  limits count the 2,097,152-byte payload.
- Bandit rejects an oversized single frame from its declared header length before
  assembling its payload and closes with 1009. It accounts fragmented-message
  payload incrementally and closes with 1009 before exceeding the configured
  retained bound.
- `WebSockAdapter.upgrade/4` marks one Plug connection for upgrade and performs
  early validation. It is not a child process; Bandit's child spec owns the
  listener lifecycle.
- WebSock permits initial and callback pushes, multiple outbound frames, process
  messages through `handle_info/2`, and explicit close details through
  `{:stop, reason, code, ...}` returns.
- Plug keeps request headers as a list and `get_req_header/2` returns every value,
  so duplicate Origin headers remain observable before upgrade.

### Phase 0 JSON Record

Elixir `JSON.decode/1` returns string keys, rejects malformed UTF-8, accepts
arbitrary-size integers, and has no API-specific nesting or collection limit.
Duplicate keys collapse; Elixir 1.20.2 currently retains the first textual value,
but protocol v1 deliberately promises only collapse, not which duplicate wins.
Protocol validation must enforce signed ranges and structural limits after decode.
`JSON.encode_to_iodata!/1` escapes controls, quotes, and backslashes while retaining
valid non-ASCII UTF-8, so outgoing limits are measured on final encoded iodata.

### Phase 0 Architecture And Policy Record

- Existing Runtime contracts prove that only the starter may await and any trusted
  holder may cancel. RunSession is therefore the sole start/await owner; Manager is
  the sole cancellation delegate; sockets receive neither role nor handle.
- `run.start` reserves and subscribes before RunSession starts asynchronously.
  Cancellation before handle registration remains pending and is applied on
  registration. Terminal Run Events remain pending until RunSession settlement.
- The API child order is Manager, SessionSupervisor, listener under
  `:rest_for_one`. `test/api_phase0_test.exs` proves the intended restart sets
  without introducing empty production modules; Phase 6 repeats this against the
  real API supervisor.
- Protocol v1 message shapes and hard limits in this plan are confirmed. Run IDs
  are `run_` plus 22 characters of unpadded URL-safe Base64 from 16 random bytes,
  with collision checking before reservation.
- A browser client must call `new WebSocket(url)` without a protocols argument and
  run from an allowed explicit-port local HTTP(S) origin. Browser Origin is not
  caller-controlled; native clients may omit it. Missing Origin remains an
  explicit local-process trust tradeoff, not authentication.
- Step 6 adds no frontend assets, remote bind option, credentials, TLS, durable
  state, or sandbox boundary.

Ownership and trust explanations are recorded in
[`docs/learning/API.md`](../learning/API.md).

## Endpoint And Startup Configuration

Production defaults are:

```text
enabled: false unless `mix synapse.server` enables it
ip:      127.0.0.1
port:    4848
model:   SYNAPSE_MODEL
```

`SYNAPSE_API_PORT` may override the port with an integer in `1..65_535` for
local conflicts. Trusted injected test configuration may use port `0` and must
read the assigned listener port from its supervised child; the environment
variable never accepts `0`. There is no bind-address environment variable or
remote-listening option in the MVP. `SYNAPSE_MODEL` must be one bounded model
identifier; trusted application configuration may provide a larger model
allowlist for tests or deployments.

`Mix.Tasks.Synapse.Server` uses `app.config` rather than starting the application
before it can enable API configuration. It validates server configuration, sets
the API enabled flag, starts the application, reports the fixed local endpoints,
and remains in the foreground. It accepts no prompt, model, workspace, API key,
capability, or Runtime option as a command argument.

Ordinary application startup leaves the completed Workspace, Task, and Runtime
tree unchanged and does not open a network listener.

## Hard Limits

| Resource                                             |                                   MVP limit |
| ---------------------------------------------------- | ------------------------------------------: |
| Incoming assembled WebSocket text message            |                     2,097,152 encoded bytes |
| Individual incoming frame payload                    |                             2,097,152 bytes |
| Outgoing WebSocket text message                      |                     3,276,800 encoded bytes |
| API prompt                                           |                         262,144 UTF-8 bytes |
| Request ID                                           |                   128 printable UTF-8 bytes |
| Run ID                                               |                    64 printable ASCII bytes |
| Origin header                                        |                                   512 bytes |
| JSON nesting depth                                   |                                          16 |
| JSON object keys                                     |                               32 per object |
| JSON array elements                                  |                               128 per array |
| Aggregate decoded JSON nodes                         |                                       4,096 |
| HTTP/1 request line                                  |                            8,192 wire bytes |
| HTTP header count                                    |                                          32 |
| Aggregate HTTP/1 header name/value upper bound       |                           32,768 wire bytes |
| Connection inbound-inactivity timeout                |                                   60,000 ms |
| Protocol violations per connection                   |                                           8 |
| Concurrent socket connections                        |                                         128 |
| Subscriptions per socket                             |                                          16 |
| Subscribers per run                                  |                                         128 |
| Replay messages retained per run, including terminal |                                       2,048 |
| Accounted replay bytes retained per run              |                                   4,194,304 |
| Projection text                                      |                         524,288 UTF-8 bytes |
| Events returned per pull                             |                                          64 |
| Encoded bytes returned per pull                      |                                   3,276,800 |
| Completed runs retained                              |                                          16 |
| Active run accounted state                           | 8,388,608 bytes, including terminal reserve |
| Aggregate retained API state                         |                  16,777,216 accounted bytes |

Run Request retains its lower-component ceilings for workspace path, model, and
identifiers. The API intentionally lowers prompt input from the Run Request's 1
MiB ceiling so a valid escaped JSON command fits the message limit. Server Budget
defaults remain `Synapse.Budget.default/0`, including 524,288 aggregate output
bytes. `SYNAPSE_MAX_OUTPUT_BYTES` may lower that API policy to a canonical integer
in `1..524288`, and hello advertises the effective value.

Encoded replay accounting includes event payload bytes and fixed per-entry
overhead. Replay is a sliding window: old progress entries are evicted before a
new valid entry can exceed its count or byte bound. Projection text is bounded by
the 524,288-byte API ceiling even when one run requests a lower Budget. A completed
snapshot replaces its duplicated wire projection text with `""`, so one maximum
content-bearing value under sixfold JSON escaping plus 131,072 envelope bytes fits
the 3,276,800-byte message and terminal reserve.
Aggregate accounting includes replay, projection, terminal data, identifiers, and
fixed per-run overhead. Evict oldest completed runs before aggregate overflow.
If appending an event would exceed established wire, projection, or sequence
bounds, Manager first stores a bounded `sink_rejected` marker and cancellation
intent, then rejects that synchronous sink call without retaining a partial replay
entry. Runtime follows its existing `event_sink_failed` terminal path, which fits
the reserved terminal space. Manager continues accepting a matching terminal
event. If terminal sink delivery also fails, cleanup-gated await settlement may
expose the validated `event_sink_failed` Agent Error because the marker explains
why no pending terminal event exists.

## Protocol Version 1

The pure Phase 2 boundary has explicit internal return contracts:

```text
Protocol.decode(message, config)
  -> {:ok, {request_id, typed_command}}
  -> {:error, stable_code, validated_request_id_or_nil}
  -> {:close, :message_too_big}

Wire.<message>(..., config)
  -> {:ok, encoded_json_iodata}
  -> {:error, :invalid_message | :message_too_large}
```

Socket maps `:message_too_big` to close code 1009 and never turns it into a
`server.error`. Protocol validation precedence is encoded bytes, JSON decoding,
whole-tree resource bounds, exact envelope, integer version, request ID, command
type, object payload, then command-specific payload. Error correlation is derived
independently from a bounded valid request ID, so an envelope error can still be
correlated without retaining the rest of the envelope.

Decoded-tree depth counts the root as depth 1 and every child value as one deeper.
Every map, list, and scalar is one aggregate node; object keys do not add nodes.
Object-key and array-element limits apply independently to each collection after
the standard decoder has collapsed duplicate keys. Exact fixtures compare decoded
JSON structure because object key order is not compatibility. On the selected
Elixir version the first duplicate textual key wins; version 1 does not promise
that ordering. Direct malformed UTF-8 decoding is `invalid_json`; the later
WebSocket stack may reject an invalid text frame before Protocol receives it.

All API run IDs use canonical unpadded URL-safe Base64: decoding to 16 bytes is
not enough unless re-encoding produces the exact original 22-byte token.

### Client Envelope

Every client text message is exactly:

```json
{
  "version": 1,
  "type": "run.start",
  "request_id": "request-1",
  "payload": {}
}
```

All four keys are required. Unknown keys, missing keys, non-integer version,
unsupported version, unknown type, invalid request ID, and non-object payload are
protocol errors. `request_id` correlates one synchronous command response and is
never used as a run ID. Commands are processed serially, retain no in-flight ID
set, and may reuse an ID after its response.

### Server Envelope

Every server text message is exactly:

```json
{
  "version": 1,
  "type": "server.hello",
  "request_id": null,
  "payload": {}
}
```

Direct command responses repeat the command `request_id`. `server.error` repeats
it only after the request ID itself has passed validation; malformed JSON,
envelopes without a valid ID, and invalid IDs use `null`. Asynchronous progress,
terminal, and subscription wakeup output use `null` unless they are the immediate
`run.subscribe` response.

### Client Commands

#### `run.start`

```json
{
  "prompt": "Inspect the project and verify the requested change.",
  "cwd": "/absolute/path/to/project",
  "model": "configured-model",
  "budget": {
    "max_turns": 10,
    "max_tool_calls": 20,
    "max_wall_time_ms": 600000,
    "provider_inactivity_ms": 90000,
    "tool_inactivity_ms": 120000,
    "max_output_bytes": 524288,
    "max_provider_retries": 1
  }
}
```

`prompt` and absolute `cwd` are required. `model` and `budget` are optional.
Budget may contain any subset of the seven exact fields. Every supplied value
must be an integer in the Budget contract and less than or equal to server
policy. Unknown fields are rejected. The payload cannot contain `run_id`,
capabilities, credentials, Provider selection, instructions, Tool limits,
Workspace limits, callbacks, or Runtime options.

Success returns:

```json
{
  "version": 1,
  "type": "run.accepted",
  "request_id": "request-1",
  "payload": { "run_id": "run_qwerty", "status": "starting" }
}
```

The initiating socket's 16-subscription capacity is checked before reserving the
run, then it is subscribed from sequence 0 before this response. A full socket
returns `subscription_limit` without starting a run. A second active start returns
`server.error` with code `run_busy`.

#### `run.cancel`

```json
{ "run_id": "run_qwerty" }
```

Success returns `run.cancel_requested` with exact `run_id` and status
`cancel_requested`. Cancellation is idempotent. A completed run returns the same
acknowledgement with status `already_terminal`; an unknown or evicted run returns
`run_not_found`.

#### `run.subscribe`

```json
{ "run_id": "run_qwerty", "after_seq": 42 }
```

`after_seq` is optional and must be a non-negative signed 64-bit integer. Omission
requests an authoritative current snapshot. A retained cursor requests replay
after that sequence. A cursor older than retained history receives a reset
snapshot. A cursor greater than current `last_seq` returns `invalid_cursor`.

#### `ping`

The payload must be `{}`. Success is `pong` with `{}`. Arbitrary echo payloads are
not accepted.

### Server Messages

The fixed server message types are:

```text
server.hello
server.error
run.accepted
run.cancel_requested
run.snapshot
run.event
run.terminal
pong
```

`server.hello` is the first WebSocket message. Its payload is exactly
`{"protocol":1,"replay":"memory","max_active_runs":1,"cwd":"/absolute/launch/path","max_output_bytes":524288}`.
The bounded absolute `cwd` is captured once from the directory in which
`mix synapse.server` starts and is the browser's editable initial Workspace path.
It exposes no other environment, credentials, models, capabilities, process
identities, or Runtime state.

`server.error` payload is exactly:

```json
{
  "code": "invalid_payload",
  "message": "Command payload is invalid",
  "retryable": false
}
```

Messages are fixed by code and never include raw decoder errors, offending
values, stacktraces, exceptions, process reasons, prompts, paths, or headers.

Initial error codes are:

```text
invalid_json
invalid_envelope
unsupported_version
unknown_type
invalid_request_id
invalid_payload
run_busy
run_not_found
invalid_cursor
subscription_limit
runtime_unavailable
internal_error
```

Codes have fixed response policy:

| Code                  | Message                                 | Retryable |
| --------------------- | --------------------------------------- | --------- |
| `invalid_json`        | `Message is not valid JSON`             | `false`   |
| `invalid_envelope`    | `Command envelope is invalid`           | `false`   |
| `unsupported_version` | `Protocol version is not supported`     | `false`   |
| `unknown_type`        | `Command type is not supported`         | `false`   |
| `invalid_request_id`  | `Request ID is invalid`                 | `false`   |
| `invalid_payload`     | `Command payload is invalid`            | `false`   |
| `run_busy`            | `A run is already active`               | `true`    |
| `run_not_found`       | `Run was not found`                     | `false`   |
| `invalid_cursor`      | `Run cursor is invalid`                 | `false`   |
| `subscription_limit`  | `Connection subscription limit reached` | `false`   |
| `runtime_unavailable` | `Runtime is unavailable`                | `true`    |
| `internal_error`      | `Internal API failure`                  | `false`   |

Malformed JSON and ordinary validation errors return `server.error` and leave the
connection open. Binary messages close with RFC 6455 code 1003. Oversized
assembled messages or fragments close with 1009. On the ninth protocol violation,
the server sends no additional error and closes with 1008. Internal errors are
sanitized and may close with 1011 when connection state is no longer safe.

`runtime_unavailable` is a command error only when reservation or RunSession
admission fails before `run.accepted`. A typed Runtime start error after acceptance
is exposed as that run's terminal.

## Snapshot And Replay Contract

`run.snapshot` has two modes.

An authoritative snapshot is returned when `after_seq` is omitted or stale:

```json
{
  "version": 1,
  "type": "run.snapshot",
  "request_id": "request-2",
  "payload": {
    "mode": "snapshot",
    "reset": true,
    "run_id": "run_qwerty",
    "first_available_seq": 17,
    "last_seq": 75,
    "projection": {
      "status": "running",
      "model": "configured-model",
      "turn": 2,
      "text": "bounded accumulated assistant text",
      "active_tool": null,
      "provider_attempts": 2,
      "tool_calls": 1,
      "output_bytes": 2048
    },
    "terminal": null
  }
}
```

`reset` is `false` when no cursor was supplied and `true` when the requested
cursor predates retained history. Applying a snapshot replaces all client state
for the run and advances its cursor to `last_seq`.

Projection fields are exact:

| Field               | Shape and meaning                                                                                    |
| ------------------- | ---------------------------------------------------------------------------------------------------- |
| `status`            | `starting`, `running`, `cancel_requested`, `owner_lost`, `completed`, `failed`, or `interrupted`     |
| `model`             | configured model string after `run.started`, otherwise `null`                                        |
| `turn`              | current or most recently completed turn, initially `0`                                               |
| `text`              | accumulated `text.delta` content; exactly `""` in a completed snapshot, whose terminal Result carries final text |
| `active_tool`       | `null` or exact object with `turn`, `operation_id`, `call_id`, `name`, and `ordinal`                 |
| `provider_attempts` | sum of per-turn values from accepted `turn.completed` events                                         |
| `tool_calls`        | sum of per-turn values from accepted `turn.completed` events                                         |
| `output_bytes`      | sum of per-turn values from accepted `turn.completed` events, initially `0`                          |

Tool progress does not increment aggregate counters. A `tool.started` only sets
`active_tool`, and matching `tool.completed` only clears it. This avoids double
counting because `TurnCompleted` is the first Run Event carrying authoritative
per-turn attempt, Tool, and output accounting. Manager adds each accepted turn
exactly once. A successful terminal replaces aggregates with Agent Result values.
Failed/interrupted terminals retain the latest committed sums.

Snapshot `terminal` is either `null` or exactly the payload of the previously
exposed `run.terminal`, including its sequence. It is not a nested server envelope.
For a successful completed snapshot, `projection.text` is an empty sentinel and
`terminal.result.text` is the single authoritative wire copy. Active, failed, and
interrupted snapshots retain committed projection text. A client reconstructs the
completed projection from the Result without mutating the decoded wire object.

Version 1 sends a snapshot as one complete message. Output policies above 524,288
bytes are deferred until a successor protocol defines bounded chunk ordering,
reassembly, cancellation, and generation/cursor validation.

A retained cursor first receives an acknowledgement with mode `replay`:

```json
{
  "version": 1,
  "type": "run.snapshot",
  "request_id": "request-2",
  "payload": {
    "mode": "replay",
    "reset": false,
    "run_id": "run_qwerty",
    "first_available_seq": 17,
    "last_seq": 75,
    "projection": null,
    "terminal": null
  }
}
```

RunManager then returns bounded `run.event` and `run.terminal` messages with
sequences greater than `after_seq`, followed by live delivery. Replay and live
delivery share one cursor and cannot interleave out of order. If no later message
exists, the replay acknowledgement still confirms the subscription.

A completed snapshot includes the exact exposed terminal in `terminal`; it does
not send a duplicate `run.terminal`. A completed replay includes `run.terminal`
only when its terminal sequence is greater than the requested cursor.

`first_available_seq` is the first retained replay entry. It is `last_seq + 1`
when no replay entry remains. A cursor equal to `first_available_seq - 1` is still
replayable. The highest two signed 64-bit values are reserved for owner-loss and
terminal settlement. Before ordinary Runtime progress would consume
`9_223_372_036_854_775_806`, Manager stores `sink_rejected`, requests cancellation,
and rejects that progress sink call. A later `run.owner_lost` may consume the
penultimate value, and the cleanup-gated terminal consumes the next value no
greater than `9_223_372_036_854_775_807`, never wrapping.

## Run Event Wire Mapping

`run.event` payload is exactly:

```json
{
  "run_id": "run_qwerty",
  "seq": 12,
  "event": { "type": "turn.started", "turn": 2, "operation_id": "provider-..." }
}
```

The explicit mapping is:

| Run Event                                    | Wire event and fields                                                                         |
| -------------------------------------------- | --------------------------------------------------------------------------------------------- |
| `RunStarted`                                 | `run.started`: `model`                                                                        |
| `TurnStarted`                                | `turn.started`: `turn`, `operation_id`                                                        |
| `TextDelta`                                  | `text.delta`: `turn`, `operation_id`, `item_id`, `content_index`, `delta`                     |
| `ToolStarted`                                | `tool.started`: `turn`, `operation_id`, `call_id`, `name`, `ordinal`                          |
| `ToolCompleted`                              | `tool.completed`: previous Tool fields plus string `status` and allowlisted `metadata`        |
| `TurnCompleted`                              | `turn.completed`: `turn`, string `outcome`, `provider_attempts`, `tool_calls`, `output_bytes` |
| `RunCompleted`                               | retained as pending terminal, not encoded as `run.event`                                      |
| `RunFailed`                                  | retained as pending terminal, not encoded as `run.event`                                      |
| `RunInterrupted`                             | retained as pending terminal, not encoded as `run.event`                                      |
| API RunSession DOWN without pending terminal | `run.owner_lost`: no additional fields                                                        |

`tool.completed.metadata` is a new object built from at most two existing
Agent-allowlisted keys. `tool` is copied only when it exactly equals the event's
registered `name`. `outcome` is copied only when it is one of `completed`,
`not_applied`, `not_applicable`, or `unknown`. Every other key or value is omitted;
the API never forwards arbitrary Tool Result metadata.

Wire uses dotted lowercase strings and never atom names generated dynamically.
Each encoder clause matches one concrete struct and constructs one new
string-keyed map. Unknown structs return an internal encoding error.

The projection applies the same ordered events:

- `run.started` sets model and status `running` unless cancellation was requested.
- `turn.started` updates only the current turn.
- `text.delta` appends bounded text in order.
- `tool.started` sets one active Tool summary without arguments.
- `tool.completed` clears the matching active Tool without changing aggregate
  counters.
- `turn.completed` adds authoritative per-turn attempt, Tool, and output counters
  to committed sums and clears stale active operation data.
- `run.owner_lost` sets status `owner_lost`, clears active Tool state, and retains
  the active reservation until a cleanup-gated terminal arrives.
- A confirmed terminal sets one terminal status and clears active Tool state.

Once cancellation is requested, `cancel_requested` takes precedence over later
Runtime progress statuses. Progress may still update model, turn, text, active
Tool, and counters. Only API `run.owner_lost` or a terminal may replace the
status.

Projection never stores prompt, `cwd`, Tool arguments, Tool Result content,
Provider response, Workspace path, callbacks, or opaque authority.

## Terminal Wire Mapping

Successful `run.terminal` payload is:

```json
{
  "run_id": "run_qwerty",
  "seq": 76,
  "status": "completed",
  "result": {
    "text": "The requested change was verified.",
    "turns": 2,
    "tool_calls": 1,
    "provider_retries": 0,
    "output_bytes": 2048
  },
  "error": null
}
```

`final_response` is deliberately omitted even though trusted Agent Result retains
it.

Failed or interrupted terminal payload is:

```json
{
  "run_id": "run_qwerty",
  "seq": 76,
  "status": "failed",
  "result": null,
  "error": {
    "source": "agent",
    "kind": "provider",
    "reason": "provider_failed",
    "message": "Provider request failed",
    "turn": 2,
    "operation_id": "provider-...",
    "details": {}
  }
}
```

Agent Error copies only its already validated fields and allowlisted details.
Runtime Error uses source `runtime` and exact fields `reason` and `message`; it
does not invent Agent kind, turn, operation, or details. API-owned terminal
failure uses source `api` with fixed reason `internal_contract_failed` and fixed
prose `Run settlement contract failed` only after cleanup-gated await settlement
proves Runtime is no longer active.

Wire status preserves the terminal contract rather than reclassifying reasons:

| Terminal source                                       | Wire status   |
| ----------------------------------------------------- | ------------- |
| `RunCompleted` / Agent Result                         | `completed`   |
| `RunFailed` / Agent Error                             | `failed`      |
| `RunInterrupted` / Agent Error                        | `interrupted` |
| Runtime start Error after API acceptance              | `failed`      |
| Runtime `runtime_lost` without Run Event              | `interrupted` |
| API `internal_contract_failed` after await settlement | `interrupted` |

Tool ambiguity remains `failed` because Runtime exposes it through `RunFailed`.
`runtime_lost` honestly reports lost coordination; Agent links and Workspace owner
monitoring still drive cleanup, but the API must not claim settlement was observed.

RunManager compares a bounded pending terminal projection with the typed result
returned by RunSession. A valid match is exposed once. If no Run Event can exist because
Runtime returned `runtime_lost`, expose the Runtime Error once. If Manager stored
`sink_rejected` and cleanup-gated await returns Agent `event_sink_failed`, expose
that validated Agent Error even when terminal sink delivery was unavailable. Any
other mismatch is an internal contract failure: log only stable classifications,
request cancellation, and expose one bounded API terminal without serializing
either raw value.

## Runtime Ownership And Session Lifecycle

```text
Socket run.start
  -> RunManager validates availability and assigns run ID
  -> RunManager records initiating subscriber at cursor 0
  -> RunManager starts temporary RunSession
  -> RunSession constructs CapabilitySet, lowered Budget, and Run Request
  -> RunSession calls Runtime.start_run/3
  -> Runtime event sink synchronously calls RunManager.record_event/2
  -> RunSession registers opaque Runtime Run with RunManager
  -> RunSession repeatedly calls owner-only Runtime.await/2
  -> RunManager may call Runtime.cancel/1 from any local cancel command
  -> RunSession reports typed await settlement
  -> RunManager exposes exactly one terminal and releases active reservation
```

RunSession `init/1` must return before Runtime startup so
`DynamicSupervisor.start_child/2` cannot block RunManager on Workspace opening.
The process starts Runtime from `handle_continue/2` or a self-message.

Phase 4 uses an isolated DynamicSupervisor to prove temporary-child behavior.
`RunSession.session_starter/3` closes over trusted Config and the Runtime boundary;
Phase 6 supplies the named one-child SessionSupervisor and production tree wiring.

After startup, RunSession polls `Runtime.await/2` with a one-second receive timeout
and returns to its GenServer loop between waits. Await timeout does not cancel and
preserves the owner right. Returning to the loop lets OTP shutdown and manager
monitor messages be handled without moving await to another process.

RunSession monitors RunManager. Manager loss requests Runtime cancellation. Its
`terminate/2` callback also calls idempotent `Runtime.cancel/1` when a valid handle
exists. It does not block shutdown indefinitely waiting for settlement.

RunManager monitors RunSession. Unexpected session loss calls
`Runtime.cancel/1` when the handle is registered. If Runtime already published a
pending terminal after cleanup, that validated terminal is authoritative and
Manager exposes it exactly once. Otherwise Manager records one bounded API-owned
`run.owner_lost` progress event, sets status `owner_lost`, and keeps the active
reservation while waiting for a cleanup-gated Runtime terminal event. No current
Runtime API lets Manager prove settlement after the sole await owner dies. If no
terminal event arrives because RunServer was also lost, the run remains explicitly
stuck until API/application restart rather than exposing a false terminal or
admitting another API run. RunSession and Manager inspection and `format_status/1`
redact prompt, path, options, callbacks, handles, and terminal content.

Cancellation may arrive while status is `starting`, before RunSession registers a
Runtime Run. RunManager records `cancel_requested: true`; registration immediately
calls `Runtime.cancel/1`. Current Runtime Workspace opening is synchronous and not
cancellable before a handle exists, so cancellation during that narrow phase is
pending rather than falsely claimed complete.

```text
Socket             RunManager             RunSession               Runtime
  | run.start          |                       |                       |
  |------------------->| reserve + start child |                       |
  |                    |---------------------->| init returns          |
  | run.accepted       |                       | start_run             |
  |<-------------------|                       |---------------------->|
  | run.cancel         |                       | Workspace opening     |
  |------------------->| remember intent       |                       |
  | cancel accepted    |                       |<------ Run handle ----|
  |<-------------------| register handle       |                       |
  |                    |<----------------------|                       |
  |                    | cancel(handle)        | await poll            |
  |                    |---------------------------------------------->|
  |                    |                       |---------------------->|
  |                    | pending terminal      |<-- typed settlement --|
  |                    |<------ event sink ----|                       |
  |                    |<--------- settle -----|                       |
  | run.terminal       | release reservation   | stop normally         |
  |<-------------------|                       |                       |
```

## RunManager State And Delivery

One run record contains only bounded API state:

```text
run ID
status and cancellation flag
RunSession PID and monitor
opaque Runtime Run, redacted and never encoded
last exposed sequence
projection
pending or confirmed terminal
bounded replay queue and encoded byte count
bounded subscriber map
created and completed monotonic ordinals for eviction
```

Phase 1 defines and validates the pre-confirmation form of this record: active
statuses, an optional compact pending terminal, and no confirmed terminal. Phase
2 defines the exact confirmed-terminal wire union before Phase 3 adds terminal
RunManager transitions. This prevents an unbounded or generic placeholder map
from becoming an accidental internal protocol.

RunManager is the single serialization point for reservation, event sequence,
projection updates, terminal confirmation, cursor validation, subscriber
registration, and completed-run eviction. Runtime's synchronous event sink makes
one bounded `GenServer.call` with `:infinity`, matching Runtime's trusted callback
contract. It has no independent call timeout that could report sink failure while
the same event is later recorded. Bounded Manager work and supervision, rather
than ambiguous timeout recovery, keep the call prompt. It never calls a socket or
waits for a client.

Phase 3 exposes pure-domain Manager calls rather than request IDs or JSON:

```text
start_run(manager, Start) -> {:ok, run_id} | command error
cancel(manager, run_id) -> cancel_requested | already_terminal | not_found
subscribe(manager, run_id, after_seq) -> snapshot/replay acknowledgement
pull(manager, run_id, cursor) -> bounded frames | authoritative reset
register_runtime_run(manager, run_id, opaque_run) -> ok | closed
record_event(manager, RunEvent) -> ok | closed
settle(manager, run_id, typed_terminal) -> ok | closed
unsubscribe / unsubscribe_all -> ok
```

Caller PID is authority for subscriptions. The admitted RunSession PID is
authority for handle registration and settlement. `record_event/2` authenticates
through the exact active run identity and closed Run Event contract because the
Runtime RunServer, not RunSession, invokes the synchronous sink. Phase 3 uses a
trusted injected three-argument session starter; Phase 4 replaces it with real
temporary-child admission without changing Manager calls. Run-ID generation has
eight bounded collision attempts.

Run records store `last_seq`, initially zero, so a terminal at signed-64-bit MAX
needs no unrepresentable next-value sentinel. They also retain bounded event-order
state: whether the run started, the open turn and Provider operation, the last
completed turn/outcome, and Tool ordinal. A new turn follows only no prior outcome
or `continued`; text cannot arrive while a Tool is active; Tool completion must
match admitted identity. Cleanup-gated terminal events remain authoritative and
may override earlier progress classification, including Workspace-close failure.

Every retained replay frame must fit pull. Config therefore requires
`max_pull_bytes == max_outgoing_message_bytes` and requires `max_replay_bytes` to
fit one maximum frame plus replay-entry overhead. Replay count includes a terminal;
terminal append may evict one progress entry. Equality at every count/byte bound
is accepted and only strict overflow evicts a minimum prefix.

A slow subscriber that falls behind replay receives an authoritative snapshot
reset from pull with `request_id: null`; `Wire.async_snapshot/2` is the only
constructor for that asynchronous shape. Cancellation changes projection status
without consuming sequence or notifying other subscribers; the direct command
acknowledgement reports it, and later snapshots observe it. Re-subscription reuses
one monitor and preserves an outstanding wakeup until pull acknowledges it.

Successful terminal projection replaces text and result counters, sets turn to
`result.turns`, and computes Provider attempts as `turns + provider_retries`.
Failed/interrupted terminals retain committed progress counters. Duplicate or
malformed events are synchronous sink rejection with no partial sequence/replay;
cleanup-authoritative terminal events after owner loss remain accepted. Aggregate
and completed-count pressure evict oldest completed records, never the active or
currently protected target.

Each subscriber record contains PID, monitor, acknowledged cursor, and whether a
change notification is outstanding. Recording an event sends
`{:synapse_run_changed, run_id}` only when no notification is outstanding.

Socket requests a pull with its cursor. RunManager returns at most 64 messages
and 3,276,800 encoded bytes, advances that subscriber's acknowledged cursor only
for the returned batch, and reports whether more retained data exists. Socket
pushes that batch, then schedules one local continuation when `more?` is true.
When caught up, Manager clears the outstanding flag atomically; a concurrently
recorded event then creates exactly one new notification.

Subscriber DOWN removes it without affecting the run. Explicit unsubscribe is
optional because a socket supports at most 16 run subscriptions and process
monitoring provides cleanup.

## HTTP And WebSocket Security Policy

The listener binds the literal IPv4 tuple for `127.0.0.1`. Configuration rejects
other addresses; it does not resolve a hostname for binding.

Accepted requests must have a valid local `Host` for `127.0.0.1` or `localhost`
and the actual listener port. Upgrade requests must have an empty query string and
must not carry `Authorization`, `Cookie`, or `Sec-WebSocket-Protocol`. The API
does not negotiate subprotocols and does not inspect or log rejected header
values. It defines, consumes, and reflects no other credential-bearing header;
it does not claim to detect a secret hidden in an arbitrary unused header.

For a browser-supplied `Origin`, accept only a parsed origin with:

- scheme `http` or `https`;
- exact host `localhost`, `127.0.0.1`, or `::1`;
- an explicit valid port;
- no userinfo, path other than `/`, query, or fragment.

Reject duplicate Origin headers, malformed values, wildcard hosts, suffix matches,
opaque `null`, file origins, and non-local hosts. A missing Origin is accepted for
native clients because the TCP peer is loopback. This is not authentication: any
local native process able to reach the listener can omit Origin and use the API.

WebSocket compression extensions are disabled. Transport configuration enforces
both fragment and assembled-message bounds, HTTP/1 request-line, per-header and
header-count bounds, the connection cap, and the idle timeout from the hard-limit
table. HTTP/2 is disabled so a second set of weaker header semantics cannot bypass
those limits.

Only `GET /health` succeeds over ordinary HTTP. It returns status 200,
`application/json`, `Cache-Control: no-store`, and exactly
`{"status":"ok","protocol":1}`. Other methods on `/health` return 405. Unknown
paths return 404. `/v1/socket` without a valid upgrade returns 426; failed Host,
Origin, query, or forbidden-header policy returns a fixed 403 without reflecting
input.

All Router-owned HTTP responses use `Content-Type: application/json` and
`Cache-Control: no-store`, with no trailing newline:

| Result | Additional header    | Exact body                       |
| ------ | -------------------- | -------------------------------- |
| 200    | none                 | `{"status":"ok","protocol":1}`   |
| 403    | none                 | `{"error":"forbidden"}`          |
| 404    | none                 | `{"error":"not_found"}`          |
| 405    | `Allow: GET`         | `{"error":"method_not_allowed"}` |
| 426    | `Upgrade: websocket` | `{"error":"upgrade_required"}`   |

Policy precedence is Host first, then exact route, then socket query/header/Origin
policy, then non-raising WebSocket upgrade validation. Syntactically valid Host
values that reach Router but fail canonical loopback authority receive fixed 403.
Missing, duplicate, or parser-invalid Host and over-limit request lines/headers are
rejected earlier by Bandit with transport-owned 400/414/431 behavior. Bandit also
normalizes a terminal empty query marker, so `/v1/socket?` is indistinguishable
from `/v1/socket`; every non-empty query is fixed 403.

Routes match exact request-path bytes. Trailing or repeated-slash forms such as
`/health/`, `//health`, `/v1//socket`, and `/v1/socket/` are unknown and return 404.
Origin requires anchored `http` or `https`, exact local host spelling, an explicit
canonical decimal port in `1..65535`, and no userinfo, non-root path, query, or
fragment. Origin port is frontend authority and need not equal the API port.

Before upgrade, Router requires exactly one canonical Base64 key decoding to 16
bytes and strips every extension offer without inspecting its value. Compression
and subprotocol negotiation remain disabled. Malformed extension offers therefore
cannot enter Bandit's extension parser.

API-generated and client-triggered logs may include stable route, error code, run
ID, and bounded counters. They must not include frames, prompt, model output,
terminal text, `cwd`, headers, query, cookies, credentials, Tool data, Runtime
handles, process reasons, exceptions, or stacktraces at ordinary levels. Explicit
in-VM failure injection can cause OTP or dependency crash reports containing
framework stacktraces and supervision topology; those reports are not triggerable
by a protocol client and must still contain no API content or authority sentinel.

## Supervision And Shutdown

When API is enabled, the root tree is:

```text
Synapse.Supervisor                              :one_for_one
|-- Synapse.Workspace.Supervisor
|-- Synapse.TaskSupervisor
|-- Synapse.Runtime.Supervisor
`-- Synapse.API.Supervisor                      :rest_for_one
    |-- Synapse.API.RunManager
    |-- Synapse.API.SessionSupervisor           DynamicSupervisor, max_children: 1
    |   `-- Synapse.API.RunSession              temporary
    `-- Bandit                                  permanent loopback listener
```

The API child starts after Runtime infrastructure, so root shutdown stops API
first while Runtime, Agent Task, and Workspace supervisors remain available for
cancellation and cleanup.

Within API Supervisor, RunManager starts before SessionSupervisor and Bandit.
RunManager failure restarts the session owner and listener because all API replay
and lookup state was lost. SessionSupervisor failure restarts the listener;
RunManager monitors and cancels an affected active session. Listener failure
restarts only the listener. RunSession is temporary and is never replayed.

Bandit stops accepting clients first on normal reverse-order shutdown. Existing
sockets close, sessions request cancellation, and RunManager remains available
until SessionSupervisor has stopped. API shutdown is bounded and must not claim a
terminal can always be delivered while the application itself is terminating.

## Test Strategy

### Pure Contract Tests

- Config defaults, environment parsing, port range, model allowlist, and limit
  validation.
- Every valid and invalid envelope and command payload.
- Unknown fields, wrong scalar types, overlong strings, malformed UTF-8, deep
  JSON, oversized collections, and no atom creation.
- Every Run Event encoder clause and every terminal union clause.
- Snapshot, replay acknowledgement, error, and hello exact JSON fixtures.
- JSON encoded byte limits, including escaping expansion.

### Process Tests

- Atomic one-run reservation under concurrent starts.
- RunSession is the `start_run/3` and `await/2` process.
- Early cancellation before Runtime handle registration.
- Non-owner cancellation through Manager after registration.
- Socket DOWN does not call Runtime cancellation.
- RunSession and Manager DOWN handling.
- Terminal pending, await confirmation, Runtime loss, and mismatch handling.
- Sequence ordering and signed 64-bit overflow protection.
- Event count, byte, completed-run, aggregate-state, subscriber, and pull bounds.
- Coalesced notifications under a blocked or deliberately slow socket.
- Stale cursor reset, future cursor rejection, completed replay, and eviction.

### Router And Socket Tests

- Loopback bind and configured port.
- Exact health response, method rejection, 404, and upgrade-required behavior.
- Valid local Origin variants and all rejected Origin/Host/header/query cases.
- First `server.hello`, ping/pong, malformed command errors, and violation limit.
- Binary-frame, oversized-frame, policy, and internal close codes.
- Accepted start ordering before the first event.
- Disconnect, reconnect, replay, reset snapshot, cancellation, and terminal.

### Deterministic End-To-End Tests

Use a real loopback Bandit listener on port 0 under an isolated API supervision
tree. Use a test WebSocket client library selected in Phase 0 rather than adding a
hand-written partial RFC 6455 implementation. Supply Fake Provider and Fake
Workspace only through trusted API/Runtime test configuration.

The defining deterministic sequence is:

```text
connect -> hello
start -> accepted
observe read/write/bash progress
disconnect without cancellation
reconnect with retained cursor
receive replay and live messages in sequence
receive completed terminal
verify temporary fixture independently
confirm all temporary children settled
```

Ordinary `mix test` must need no network beyond loopback, API key, user files, or
fixed port.

## Phase 0: Confirm Prerequisites And Decisions

### Dependencies

- [x] Confirm current compatible Bandit, Plug, WebSock, and WebSockAdapter
      releases against Elixir `~> 1.20` and OTP 28.
- [x] Confirm direct Plug, Thousand Island, WebSock, and WebSockAdapter
      dependencies rather than relying on transitive dependency exposure.
- [x] Select a maintained test-only WebSocket client and confirm it supports
      loopback port-0 tests, custom Origin, close codes, and text/binary frames.
- [x] Add exact chosen constraints to `mix.exs`, resolve `mix.lock`, and record
      resolved versions in this decision record.
- [x] Confirm Elixir `JSON.decode/1` and `JSON.encode_to_iodata!/1` behavior for
      string keys, duplicate object keys, malformed UTF-8, integer range, nesting,
      and escaping expansion. Protocol v1 does not promise duplicate-key rejection
      when the selected standard decoder collapses duplicates.

### Framework Interfaces

- [x] Confirm Bandit's exact loopback, assigned port-0 discovery,
      connection-limit, fragment/message-limit, HTTP-limit, compression-disable,
      idle-timeout, and shutdown options from current docs and source.
- [x] Confirm Plug Router upgrade, WebSockAdapter upgrade, and Bandit child-spec
      integration.
- [x] Confirm WebSock callback return shapes for initial pushes, multiple frames,
      close frames, and process messages.
- [x] Confirm how the selected stack reports oversized frames before allocating
      payload copies.
- [x] Confirm duplicate request headers remain observable for strict Origin
      validation.

### Architecture

- [x] Confirm RunSession alone calls Runtime `start_run/3` and `await/2`.
- [x] Confirm Manager may call only Runtime `cancel/1` with the retained handle.
- [x] Confirm no socket owns or receives a Runtime handle.
- [x] Confirm acceptance-before-Runtime-start semantics and early cancellation.
- [x] Confirm terminal Run Events become bounded pending projections until await
      confirmation.
- [x] Confirm and document deliberate transfer of the opaque Run to one trusted
      cancellation delegate while owner-only await remains in RunSession.
- [x] Confirm API supervisor child order and `:rest_for_one` restart sets with a
      focused Phase 0 topology fixture; repeat against production modules in Phase 6.

### Protocol And Policy

- [x] Confirm every command and server message shape in this plan.
- [x] Confirm all hard limits and Budget lowering behavior.
- [x] Confirm run ID format: `run_` plus unpadded URL-safe Base64 from 16 random
      bytes.
- [x] Confirm local Host and Origin policy against browser behavior used by the
      future web client.
- [x] Confirm missing Origin remains accepted only as a documented native-client
      tradeoff.
- [x] Confirm no frontend assets or remote bind switch enter Step 6.

### Learning Gate

- [x] Explain why a socket cannot call owner-only `Runtime.await/2` safely.
- [x] Explain why disconnect and cancellation are separate operations.
- [x] Explain why replay belongs above Runtime without changing Agent ownership.
- [x] Explain why loopback plus Origin checks are not authentication or sandboxing.

### Phase Complete When

- [x] Dependency versions and exact framework interfaces are recorded.
- [x] Protocol, ownership, supervision, limits, and local trust decisions have no
      unresolved implementation ambiguity.
- [x] `PLAN.md` and this plan agree.

## Phase 1: Implement Configuration And Internal Contracts

### Code

- [x] Create `Synapse.API.Config` with validated enabled flag, fixed loopback IP,
      port, model allowlist/default, server Budget, capability policy, trusted Runtime
      options, and every hard limit.
- [x] Read `SYNAPSE_API_PORT` and `SYNAPSE_MODEL` without logging their raw values.
- [x] Reject non-loopback bind configuration and malformed model policy.
- [x] Define bounded internal command structs or tagged tuples for Start, Cancel,
      Subscribe, and Ping.
- [x] Define bounded projection, subscriber, replay entry, pending-terminal, and
      pre-confirmation run-record state. Define the exact confirmed-terminal union in
      Phase 2 with its wire representation.
- [x] Add redacted `Inspect` behavior for Phase 1 contracts. Add `format_status/1`
      when the state-owning RunManager and RunSession processes are introduced in
      Phases 3 and 4.
- [x] Keep production defaults centralized rather than duplicated across Socket,
      Manager, and Router.

### Tests

- [x] Test defaults, port override, malformed environment, and loopback-only bind.
- [x] Test model default and allowlist normalization.
- [x] Test every hard-limit range and incompatible limit combination.
- [x] Test server Budget and capability policy cannot be widened by client-shaped
      data.
- [x] Test inspection output contains no prompt, path, callback, handle, terminal
      text, or test secret. Test process status output in Phases 3 and 4.

### Documentation

- [x] Document trusted startup configuration separately from wire input.
- [x] Document each hard limit and the resource it protects.
- [x] Document why API prompt and output ceilings may be lower than core contract
      hard ceilings.

### Phase Complete When

- [x] Config and internal contracts compile with warnings as errors.
- [x] Focused tests prove every configuration and inspection bound.
- [x] No Router, socket, RunManager process, RunSession process, or Runtime start
      code exists yet.

## Phase 2: Implement Protocol And Wire Mapping

### Code

- [x] Create pure `Synapse.API.Protocol.decode/2` for one bounded text message.
- [x] Check assembled encoded message bytes before JSON decoding.
- [x] Validate exact envelope keys before command-specific payloads.
- [x] Validate all strings as bounded valid UTF-8 without atom conversion.
- [x] Reject decoded structures above depth, object-key, array-element, or
      aggregate-node limits before command construction.
- [x] Validate Start prompt, absolute `cwd`, configured model, and Budget lowering.
- [x] Validate Cancel, Subscribe, and Ping exact payloads.
- [x] Return stable protocol errors without retaining offending input.
- [x] Define the bounded confirmed-terminal internal union shared by Wire and
      RunManager.
- [x] Create pure `Synapse.API.Wire` constructors for every server message.
- [x] Add one explicit clause for every concrete Run Event.
- [x] Add separate Agent Result, Agent Error, Runtime Error, and API Error terminal
      encoders.
- [x] Omit `final_response` and every opaque or untrusted internal value.
- [x] Measure encoded outgoing size before returning a frame.

### Tests

- [x] Add readable exact JSON fixtures for all valid commands and server messages.
- [x] Reject malformed JSON, unknown fields, wrong types, deep objects, overlong
      input, and unsupported versions; fixture and document the selected decoder's
      duplicate-key behavior.
- [x] Test every Budget field omitted, lowered, equal to policy, and above policy.
- [x] Test every Run Event and terminal mapping field by field.
- [x] Test control characters and JSON escaping against outgoing frame bounds.
- [x] Search encoded fixtures for test credentials, prompt/path sentinels,
      `final_response`, PID/reference syntax, and struct names.
- [x] Prove decoding many unique external strings does not materially increase
      atom count.

### Documentation

- [x] Add module docs with one start, replay, and terminal example.
- [x] Document protocol errors versus run terminals.
- [x] Document that wire compatibility is the explicit mapping, not Elixir struct
      layout.

### Phase Complete When

- [x] Protocol and Wire are pure and need no process or network.
- [x] Every message has an exact fixture and hard byte bound.
- [x] No generic struct encoder or external atom creation exists.

## Phase 3: Implement RunManager

### Code

- [x] Start one named or injected RunManager with validated Config.
- [x] Reserve one active run atomically and generate a collision-checked run ID.
- [x] Register the initiating socket at cursor 0 before starting RunSession.
- [x] Roll back reservation and subscriber state if child admission fails.
- [x] Monitor RunSession and every subscribed socket.
- [x] Register one opaque Runtime Run without exposing it through return values or
      inspection.
- [x] Record cancellation requested before and after handle registration.
- [x] Record non-terminal Run Events synchronously, assign sequence, update
      projection, and append bounded encoded replay.
- [x] Preserve `cancel_requested` status across every later progress event.
- [x] Store `sink_rejected` before rejecting projection, wire, or sequence
      overflow, and reserve the final signed 64-bit sequence for a terminal.
- [x] Validate terminal Run Events and retain bounded pending projections without
      notifying clients or retaining Provider `final_response`.
- [x] Confirm settlement and expose exactly one terminal sequence.
- [x] Implement snapshot, retained replay, stale reset, future rejection, and
      completed terminal replay.
- [x] Implement bounded pull and notification acknowledgement.
- [x] Coalesce one outstanding notification per subscriber and run.
- [x] Enforce subscriber, per-run replay, completed-run, and aggregate byte limits.
- [x] Evict oldest completed runs by monotonic completion ordinal.
- [x] Remove socket and session state on DOWN without treating socket DOWN as
      cancellation.
- [x] On RunSession DOWN, expose a pending cleanup-gated terminal or record
      `run.owner_lost` and retain the active reservation until terminal/restart.
- [x] Implement redacted RunManager `format_status/1` output.

### Tests

- [x] Race many starts and prove exactly one reservation succeeds.
- [x] Prove events remain ordered under calls from multiple test processes.
- [x] Test every projection transition and invalid event ordering.
- [x] Test pending terminal is invisible until matching settlement.
- [x] Test Runtime loss, mismatch, duplicate terminal, and session DOWN.
- [x] Test projection-text overflow, sink rejection with and without terminal event
      delivery, terminal sequence reserve, and cancellation-status precedence.
- [x] Test cancellation before registration, after registration, repeated, and
      post-terminal.
- [x] Test count and byte eviction at exact boundaries and one unit over.
- [x] Test stale and future cursors around `first_available_seq` and `last_seq`.
- [x] Test 128 slow subscribers create at most 128 outstanding notifications, not
      one message per event.
- [x] Test subscriber DOWN cleanup and completed-run eviction.
- [x] Test owner loss never exposes a pre-cleanup terminal or admits another API
      run; a later cleanup-gated event completes the stuck record.
- [x] Test RunManager inspection and status output contain no terminal text,
      callback, handle, or test secret.

### Documentation

- [x] Document RunManager as an ephemeral projection, not Runtime ownership.
- [x] Document sequence, cursor, reset, and eviction semantics.
- [x] Document synchronous event-sink work and why it must remain bounded.

### Phase Complete When

- [x] Manager tests prove ordering, cancellation, replay, and every memory bound.
- [x] No socket or JSON decoder is required by Manager tests.
- [x] Manager loss is explicitly documented as loss of API lookup and replay.

## Phase 4: Implement RunSession

### Code

- [x] Start RunSession as a temporary DynamicSupervisor child with redacted state.
- [x] Return from `init/1` before starting Runtime.
- [x] Construct fixed CapabilitySet from Config.
- [x] Construct effective Budget only by lowering server policy.
- [x] Construct and validate Run Request with server run ID and allowed model.
- [x] Build Runtime event sink that calls only Manager `record_event` and returns
      promptly.
- [x] Call `Runtime.start_run/3` from RunSession with trusted server options.
- [x] Register the opaque handle and honor an already pending cancellation.
- [x] Poll owner-only `Runtime.await/2` with bounded timeout while returning to the
      GenServer loop between polls.
- [x] Report typed settlement once and stop normally.
- [x] Monitor Manager and cancel Runtime on manager loss.
- [x] Request idempotent cancellation from `terminate/2` when possible.
- [x] Convert pre-handle Request/Runtime start failure to one bounded run terminal.
- [x] Implement redacted RunSession `format_status/1` output.

### Tests

- [x] Instrument a Runtime-compatible test boundary and assert the same
      RunSession PID calls start and every await.
- [x] Test synchronous Workspace-open delay does not block Manager or sockets.
- [x] Test cancellation during startup and immediately after registration.
- [x] Test await timeout polling does not cancel or consume the await right.
- [x] Test Agent Result, Agent Error, Runtime Error, Manager DOWN, session shutdown,
      and unexpected session crash.
- [x] Capture logs and inspection with prompt, path, callback, handle, and secret
      sentinels.
- [x] Test RunSession status output contains none of those sentinels.

### Documentation

- [x] Document why RunSession is a process rather than a Task owned by Socket.
- [x] Document current non-cancellable Workspace-open limitation.
- [x] Add a start, early-cancel, and settlement sequence diagram.

### Phase Complete When

- [x] Owner-only await is proven by PID assertions.
- [x] Disconnect has no path to RunSession cancellation.
- [x] Every catchable session exit requests Runtime cleanup without replay.

## Phase 5: Implement WebSocket Lifecycle

### Code

- [x] Create `Synapse.API.Socket` using the confirmed WebSock callbacks.
- [x] Push `server.hello` first and initialize bounded connection state.
- [x] Reject binary and oversized assembled messages with exact close codes;
      oversized fragments remain a pre-callback Bandit 1009 path configured in Phase 6.
- [x] Decode each text message through Protocol and route only typed commands.
- [x] Track at most 16 run cursors; process commands serially without retaining a
      request-ID history.
- [x] Route run start, cancellation, and subscription only through Manager; answer
      typed application ping locally because it has no run state.
- [x] Push direct responses before handling queued run-change notifications.
- [x] Pull bounded replay/live batches and advance each local cursor exactly once.
- [x] Schedule only one local continuation while additional pull data remains.
- [x] Count protocol violations and close on the ninth violation.
- [x] Remove all Manager subscriptions on normal or abnormal socket termination.
- [x] Never cancel a run from socket termination.

### Tests

- [x] Test hello is first and exact.
- [x] Test each valid command and command-response request ID.
- [x] Test binary, oversized, malformed, unsupported, wrong-shape, and repeated
      invalid commands, plus request-ID reuse after a response.
- [x] Test subscription cap and cursor isolation across multiple runs retained in
      history.
- [x] Test accepted response appears before the first run event.
- [x] Test bounded multi-batch delivery with a deliberately slow client.
- [x] Kill the socket and prove Runtime continues and no cancel call occurs.

### Documentation

- [x] Document WebSock connection state and close-code policy.
- [x] Document command response ordering versus asynchronous messages.
- [x] Document how client cursors should be stored and applied.

### Phase Complete When

- [x] Direct Socket tests cover every callback and close path.
- [x] Socket mailboxes and local state remain bounded under slow delivery.
- [x] Socket code contains no Runtime, Provider, Workspace, or frontend calls.

## Phase 6: Implement Router, Supervision, And Server Task

### Code

- [x] Create Router with exact health, upgrade, 404, 405, 426, and fixed policy
      responses.
- [x] Validate Host, Origin, query, forbidden headers, and absent subprotocol before
      upgrade.
- [x] Configure Bandit with literal loopback IP, validated port, connection cap,
      frame cap, idle timeout, and bounded shutdown.
- [x] Create temporary `Synapse.API.SessionSupervisor` with maximum one child.
- [x] Create `Synapse.API.Supervisor` with Manager, SessionSupervisor, and Bandit in
      documented `:rest_for_one` order.
- [x] Add the API Supervisor conditionally after Runtime Supervisor in
      `Synapse.Supervisor.child_specs/1`.
- [x] Preserve the exact existing three-child tree when API is disabled.
- [x] Update Application and root Supervisor docs for conditional API startup and
      reverse shutdown order.
- [x] Create `Mix.Tasks.Synapse.Server` using `app.config`, configuration
      validation, application start, endpoint output, and foreground lifetime.
- [x] Accept no run or credential arguments in the Mix task.

### Tests

- [x] Test disabled application starts no listener and retains existing child
      order.
- [x] Test enabled child order, restart strategy, and reverse shutdown.
- [x] Test listener failure, SessionSupervisor failure, and Manager failure
      restart only the documented suffix.
- [x] Test API shutdown requests active-run cancellation while Runtime and
      Workspace infrastructure remain alive.
- [x] Test health and every fixed HTTP failure through real loopback HTTP.
- [x] Test all Host and Origin cases without logging rejected values.
- [x] Test port 0 isolation and configured fixed-port conflict failure.
- [x] Test Mix task configuration errors without a stacktrace or secret output.

### Documentation

- [x] Document explicit versus ordinary application startup.
- [x] Document every supervised child, restart type, shutdown order, and failure
      consequence.
- [x] Document local endpoint and environment variables.

### Phase Complete When

- [x] `mix synapse.server` starts only a loopback listener.
- [x] Health and valid WebSocket upgrade work through the real stack.
- [x] Supervision tests prove API failure cannot silently replay a run.

## Phase 7: Deterministic End-To-End Acceptance

### Fixture

- [x] Create a temporary project fixture containing a small `README.md`.
- [x] Script Fake Provider turns for read, write, bash verification, and final
      text.
- [x] Use Fake Workspace for pure API acceptance and a separate temporary Real
      Workspace case for process cleanup.
- [x] Start an isolated API tree on loopback port 0 with trusted test Runtime
      options.

### Scenarios

- [x] Connect and validate `server.hello`.
- [x] Start the defining run and validate server-assigned run ID.
- [x] Observe exact increasing sequences and projection changes.
- [x] Disconnect after at least one event and prove the run remains active.
- [x] Reconnect with retained cursor and receive gap-free replay plus live events.
- [x] Reconnect with an intentionally stale cursor and replace state from reset
      snapshot.
- [x] Receive one successful terminal without Provider final response.
- [x] Independently verify the temporary fixture and all Runtime children settled.
- [x] Run a second scenario that cancels through another socket and receives one
      interrupted terminal.
- [x] Run startup failure and Runtime-loss scenarios with sanitized terminals.

### Verification

- [x] `mix compile --warnings-as-errors`
- [x] `mix format --check-formatted`
- [x] `mix test`
- [x] `mix docs`

### Phase Complete When

- [x] The full protocol-to-core path passes without Tokamak or user files.
- [x] Disconnect/reconnect and cancellation semantics are proven over real
      WebSockets.
- [x] No temporary API, Runtime, Workspace, command, or test-client process leaks.

## Phase 8: Reliability And Security Hardening

### Adversarial Input

- [x] Fuzz bounded JSON values and malformed envelopes without crashes or atom
      growth.
- [x] Exercise maximum escaped prompt, model, IDs, metadata, deltas, terminal text,
      and frame sizes.
- [x] Send fragmented messages, rapid commands, reused request IDs, binary
      messages, and protocol-violation floods within test bounds.
- [x] Attempt capability, Provider, callback, Runtime option, credential, handle,
      and struct-shaped payload injection.
- [x] Attempt Host confusion, DNS-rebinding-style Host values, local-host suffixes,
      duplicate Origin, `null`, file, non-local, malformed, and oversized Origins.

### Failure Injection

- [x] Kill Socket, Bandit, SessionSupervisor, RunSession, RunManager, Runtime
      RunServer, and application in each meaningful phase.
- [x] Force event encoder failure, replay accounting limit, sequence exhaustion,
      subscriber DOWN, and terminal mismatch.
- [x] Prove no restart path replays Provider or Tool work.
- [x] Prove Manager loss clearly loses ephemeral lookup/replay and cancels the
      active owner layer.
- [x] Prove application shutdown leaves no owned direct operation in temporary
      Real Workspace tests.

### Disclosure Review

- [x] Use distinct sentinel values for credential, prompt, path, model output,
      Tool data, Provider response, callbacks, and opaque handles.
- [x] Search every frame, HTTP response, log capture, exception, inspect output,
      and status report for forbidden sentinels.
- [x] Confirm content-bearing `text.delta`, projection text, and final result text
      are the only intentional model-content wire surfaces.
- [x] Confirm logs never contain those intentional content-bearing surfaces.
- [x] Confirm subprocess environment still strips `TOKAMAK_API_KEY` through the
      existing Workspace contract.

### Resource Review

- [x] Measure Manager memory before and after event-count, replay-byte,
      completed-run, and aggregate eviction tests.
- [x] Measure socket mailbox length under slow-client tests.
- [x] Confirm connection, subscription, request, event, and retained-run caps are
      enforced at exact boundaries.
- [x] Confirm all tests use bounded receives and no fixed scheduler sleeps.

### Phase Complete When

- [x] Malformed local clients cannot crash the API tree or create unbounded state.
- [x] All failure paths are bounded, sanitized, and never replay side effects.
- [x] The documented local-user threat model matches observed behavior.

## Phase 9: Live Tokamak Acceptance

Live tests use `:live_tokamak`, remain excluded by default, require
`TOKAMAK_API_KEY` and `SYNAPSE_MODEL`, and operate only on a newly created
temporary workspace.

### Live Text Run

- [x] Start `mix synapse.server` with production Provider and Workspace policy.
- [x] Connect through the same external protocol client used for deterministic
      acceptance.
- [x] Start a text-only prompt and receive streamed text plus one completed
      terminal.

### Live Coding Run

- [x] Create temporary `README.md` fixture.
- [x] Ask the model to read it, create `hello.txt`, and run exact verification.
- [x] Observe at least one Tool event and increasing API sequences.
- [x] Disconnect and reconnect during the run when timing permits; otherwise run a
      separate deterministic delayed-provider reconnect proof.
- [x] Receive one terminal and independently verify file content and command
      result.
- [x] Confirm no owned Runtime or Workspace child remains.

### Security

- [x] Capture API logs and frames and confirm no API key, authorization header,
      Provider response, Runtime Run, Workspace Handle, or callback appears.
- [x] Confirm the client never sends the API key, Provider selection, capabilities,
      or Runtime options.
- [x] Remove the temporary fixture after inspection.

### Phase Complete When

- [x] One real text run and one real coding run complete through protocol v1.
- [x] Live proof uses no internal module calls from the client.
- [x] No credential or opaque authority crosses the API boundary.

## Phase 10: ExDoc And Comprehension Review

### Public Documentation

<!-- prettier-ignore -->
- [x] Add `@moduledoc`, `@typedoc`, and complete `@spec` declarations to public API modules and contracts.
- [x] Keep internal state modules private unless a public contract requires them.
- [x] Document protocol versioning, endpoint, commands, messages, limits, replay, close codes, and error codes.
- [x] Document Runtime owner/awaiter, cancellation holder, event sink, and terminal confirmation process ownership.
- [x] Document supervision, conditional startup, restart, and shutdown behavior.
- [x] Document loopback, Origin, missing-Origin, local-process access, and server-user process-exec limitations.
- [x] Document process-lifetime replay and every condition that loses it.
- [x] Add `PLAN-API.md` to ExDoc extras and the Plans group.
- [x] Add API modules to a dedicated ExDoc module group when they exist.
- [x] Add `docs/learning/API.md` with verified Phase 0 dependency, framework, ownership, and trust evidence.
- [x] Expand `docs/learning/API.md` with implementation experience from later phases.

### Consistency Review

<!-- prettier-ignore -->
- [x] Remove stale planned CLI, renderer, exit-code, and Ctrl-C ownership wording from active architecture docs while preserving historical CLI-subprocess comparisons where they remain relevant.
- [x] Ensure lower completed component plans describe the API as a higher adapter, not a dependency.
- [x] Ensure README future architecture does not contradict MVP one-run, process-lifetime replay, or local trust claims.
- [x] Verify every relative documentation link and ExDoc extra path.

### Comprehension Gate

<!-- prettier-ignore -->
- [x] Explain why RunSession, Manager, and Socket are three separate processes.
- [x] Trace `run.start` from JSON to validated Run Request without exposing trusted options.
- [x] Trace one Runtime event to sequence, projection, replay, and socket delivery.
- [x] Trace cancellation before and after Runtime handle registration.
- [x] Explain stale reset versus retained replay and why neither is durable.
- [x] Explain Manager, Session, listener, Runtime, and application failure consequences.
- [x] Explain exactly which content may cross the wire and which authority may not.
- [x] Explain how all behavior is tested without Tokamak.

### Final Verification

- [x] `mix compile --warnings-as-errors`
- [x] `mix format --check-formatted`
- [x] `mix test`
- [x] `mix docs`
- [x] Review generated ExDoc navigation and every API example.
- [x] Review final diff for accidental frontend, persistence, or remote-server
      scope.

### Phase Complete When

- [x] API behavior can be implemented and maintained from source, LSP, ExDoc, and
      this plan without the original AI conversation.
- [x] All deterministic verification passes and live tests remain explicit opt-in.
- [x] Every checklist phase and the definition of done are satisfied.

## API Definition Of Done

- [x] Phases 0 through 10 are complete.
- [x] `mix synapse.server` binds only `127.0.0.1` and serves no frontend assets.
- [x] Protocol v1 has exact bounded command, event, snapshot, terminal, and error
      shapes.
- [x] RunSession alone starts and awaits Runtime.
- [x] RunManager alone owns API run lookup, projections, replay, subscriptions, and
      non-owner cancellation.
- [x] Socket disconnect never cancels a run.
- [x] Reconnect produces complete retained replay or explicit reset, never a
      silent sequence gap.
- [x] Every connection, subscriber, event, replay, projection, terminal, and
      completed-run collection has a tested hard bound.
- [x] Slow clients cannot create unbounded socket or Manager mailboxes.
- [x] Ordinary terminals are exposed only after Runtime cleanup and await
      semantics are reconciled. `runtime_lost` is the sole explicit
      settlement-unproven terminal; RunSession loss without that typed await result
      remains `owner_lost` rather than a false terminal.
- [x] No message, response, log, exception, inspect output, or status report contains
      credentials or opaque host authority.
- [x] Deterministic end-to-end acceptance needs no Tokamak key or user checkout.
- [x] Opt-in live acceptance completes one real coding run through an external
      protocol client.
- [x] Compile, format, test, and docs verification pass.

## Deferred API Work

Do not add these to the MVP API:

- Detached daemonization, launch agent, systemd unit, or operating-system service
  management.
- Unix domain sockets, named pipes, remote bind, TLS, or reverse proxy support.
- Authentication, authorization, per-client capabilities, or secret-bearing
  sessions.
- Durable event log, database, restart recovery, or stable sequence numbers.
- Concurrent runs, queues, per-project coordination, or parallel Tool delivery.
- Client steering, follow-up prompts, approval requests, or interactive stdin.
- Frontend assets, web framework, TUI, desktop shell, or UI-specific rendering.
- Provider selection, Tool registration, extensions, MCP, or arbitrary runtime
  configuration over the wire.
- Compression, binary protocol, protocol negotiation, or generic RPC.
- Telemetry export, billing, analytics, or content-bearing logs.

Because protocol-v1 objects and enums are closed, any wire-shape or semantic change
requires a new version unless compatibility is proved for every existing client.
Future work must not reinterpret existing messages silently or turn ephemeral
sequence values into a false durability guarantee.
