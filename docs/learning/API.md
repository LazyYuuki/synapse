# Local API Maintenance Guide

These notes record implementation evidence behind the local WebSocket API in
[`PLAN-API.md`](../plan/PLAN-API.md). They describe framework and ownership
decisions plus the implemented configuration, protocol, Manager, RunSession,
Socket, loopback server boundary, and deterministic end-to-end acceptance.

## Selected Stack

Synapse targets Elixir `~> 1.20` and is verified with Elixir 1.20.2 on OTP 28.
The resolved Phase 0 stack is Bandit 1.12.4, Plug 1.20.3, Thousand Island 1.5.0,
WebSock 0.5.3, WebSockAdapter 0.6.0, and test-only Gun 2.5.0. All six are direct
dependencies because Synapse compiles against their public modules; it does not
rely on Bandit or Req to expose transitive packages accidentally.

Gun accepts arbitrary upgrade headers, including Origin; sends text and binary
frames; and reports remote close codes while allowing custom local close frames.
It can connect to the assigned loopback port returned for a port-0 Bandit listener.
MintWebSocket 1.0.5, WebSockex 0.5.1, and HTTP WebSocket 0.11.0 were evaluated but
rejected because stale bitstring matches in those Elixir stacks emit compiler
warnings on Elixir 1.20.

## Confirmed Framework Interfaces

Bandit is the supervised listener child. It returns the underlying Thousand
Island supervisor PID, and `ThousandIsland.listener_info/1` returns the assigned
address and port. `WebSockAdapter.upgrade/4` only marks a Plug connection for a
WebSocket upgrade; WebSockAdapter is not a supervised child.

The production listener uses HTTP/1 only. Bandit's HTTP/1 controls bound the
8,192-byte request line, 32 request headers, and each combined header name/value
to 1,024 bytes. The latter two limits provide a 32,768-byte aggregate upper bound.
Thousand Island expresses connection capacity per acceptor, so one acceptor with
`num_connections: 128` is required for the API's global connection cap. Its
`read_timeout` supplies the 60-second inbound-inactivity timeout. Server pushes do
not reset it, so a connected client must send a command or control frame within
that interval; protocol `ping` exists for that purpose.

Bandit exposes separate WebSocket limits for one wire frame and for a message
assembled from continuation-frame payloads. A frame's declared length is rejected
from its header before Bandit assembles the payload; fragmented-message size is
checked as fragments arrive. Set the wire-frame limit to 2,097,166 bytes so a
2,097,152-byte payload plus the largest 14-byte masked header fits. Set the
fragmented payload limit to 2,097,152 bytes, retain global text-frame UTF-8
validation, and disable compression globally and on each upgrade.

WebSock calls `init/1` after upgrade and permits an initial push, so `server.hello`
can be the first message. `handle_in/2` receives a complete text or binary message,
and `handle_info/2` can push one or many frames for coalesced subscription delivery.
Explicit close codes use the stop return forms. Plug retains request headers as a
list and `get_req_header/2` returns every value, so duplicate Origin headers remain
observable and rejectable.

## JSON Behavior

Elixir's standard `JSON` decoder returns object keys as binaries and creates no
atoms. It rejects malformed UTF-8. It collapses duplicate object keys; on the
selected Elixir release the first textual occurrence wins, but protocol v1 does
not make that ordering a compatibility promise.

The decoder accepts integers above signed 64-bit range and does not impose the
API's depth, collection, or aggregate-node limits. Protocol validation must enforce
those bounds after decoding and before command construction. Encoding escapes
control bytes, quotes, and backslashes while preserving valid non-ASCII UTF-8, so
all outgoing limits are measured on final encoded iodata rather than source text.

## Ownership

A WebSocket process cannot safely call owner-only `Runtime.await/2`: disconnect
would destroy the sole await owner, and reconnect would move the call to a process
that Runtime correctly rejects as `:not_owner`. One temporary RunSession therefore
calls both `Runtime.start_run/3` and repeated `Runtime.await/2` calls.

Disconnect and cancellation are separate operations because a transport is only
one observer of API-owned lifecycle state. RunManager may retain the opaque Run as
the one trusted cancellation delegate and call non-owner `Runtime.cancel/1`, but it
never awaits or serializes the handle.

Replay belongs above Runtime because it stores only bounded, already exposed wire
projections. It neither replays Agent work nor changes Runtime event identity or
ownership. Losing RunManager intentionally loses replay and restarts sessions and
the listener under `:rest_for_one`.

## Local Trust

Loopback binding prevents accidental LAN exposure, and strict local Origin checks
prevent an ordinary remote web page from opening the socket through a browser.
Neither is authentication or sandboxing. Any process running as the local user can
connect directly, omit Origin, and request all authority permitted by trusted server
policy. The MVP therefore remains a single-user local adapter and offers no remote
bind switch, credentials, TLS, or multi-user isolation.

Production policy permits read, write, and `process.exec`. The last runs commands
as the same OS user with ambient host authority; neither the API, a BEAM process,
nor Workspace is a filesystem, network, credential, process, CPU, or descendant
sandbox. Healthy cleanup confirms the owned direct child, but daemonized or
reparented descendants may escape. Do not expose this listener to untrusted local
processes. Protocol v1 accepts no credentials, capability grants, Provider modules,
callbacks, handles, or Runtime options.

## Protocol V1 Reference

Start the foreground server with `mix synapse.server`. It binds only IPv4 loopback
and serves no frontend assets:

```text
GET http://127.0.0.1:4848/health
WS  ws://127.0.0.1:4848/v1/socket
```

Trusted configuration or `SYNAPSE_API_PORT` may change the port. Every WebSocket
application message is UTF-8 text JSON with this exact envelope:

```json
{"version":1,"type":"ping","request_id":"request-1","payload":{}}
```

Version 1 requires exactly the four envelope keys. Unknown fields, non-integer
versions, unknown message types, and malformed payloads are rejected; future work
must extend v1 deliberately or introduce a new version rather than reinterpret an
existing shape. Object-key order is irrelevant, and duplicate-key ordering is not
a compatibility promise.

Client commands are:

| Type | Payload | Purpose |
| --- | --- | --- |
| `run.start` | required `prompt`, absolute `cwd`; optional allowlisted `model`, lowering-only `budget` | reserve and start the one active run |
| `run.cancel` | server-issued `run_id` | record idempotent cancellation intent |
| `run.subscribe` | `run_id`; optional non-negative signed-64-bit `after_seq` | obtain snapshot, reset, or retained replay |
| `ping` | exact empty object | keep an idle connection active and receive `pong` |

Server messages are:

| Type | Correlation | Purpose |
| --- | --- | --- |
| `server.hello` | `request_id: null` | announce protocol 1, memory replay, and one active run |
| `server.error` | command ID when safely known | report a pre-admission command/protocol failure |
| `run.accepted` | start request ID | return the server-issued run ID before progress |
| `run.cancel_requested` | cancel request ID | acknowledge intent or an already-terminal run |
| `run.snapshot` | subscribe ID, or `null` for asynchronous reset | return authoritative projection or replay acknowledgement |
| `run.event` | `request_id: null` | deliver one sequenced non-terminal event |
| `run.terminal` | `request_id: null` | deliver one sequenced confirmed terminal |
| `pong` | ping request ID | answer the application keepalive |

Stable `server.error` codes are:

| Code | Retryable | Meaning |
| --- | --- | --- |
| `invalid_json` | no | message is not valid JSON |
| `invalid_envelope` | no | envelope or decoded tree is invalid |
| `unsupported_version` | no | version is not 1 |
| `unknown_type` | no | command type is unsupported |
| `invalid_request_id` | no | request ID is invalid or too large |
| `invalid_payload` | no | command payload violates its closed contract |
| `run_busy` | yes | one active run is already reserved |
| `run_not_found` | no | run lookup is absent or was evicted |
| `invalid_cursor` | no | cursor is ahead, malformed, or not owned by this subscriber |
| `subscription_limit` | no | per-socket or per-run subscription capacity is full |
| `runtime_unavailable` | yes | admission could not start a RunSession |
| `internal_error` | no | sanitized internal API failure |

The internal decoder may also classify invalid trusted policy as `internal_error`;
Socket treats that as close 1011 instead of sending a client validation response.
The complete resource ceilings are listed under [Phase 1 Configuration](#phase-1-configuration).

Close behavior is:

| Condition | Code owner/result |
| --- | --- |
| complete binary application message | Socket 1003 |
| ninth ordinary protocol violation | Socket 1008 |
| oversized text message, frame, or fragmented message | Socket/Bandit 1009 |
| invalid UTF-8 text | Bandit 1007 |
| malformed WebSocket framing | transport-owned RFC 6455 close |
| unsafe callback, Manager, cursor, or trusted-policy state | Socket 1011 |

## Process And Authority Map

```text
Bandit connection process running Socket
  | command calls / bounded replay pulls
  v
RunManager: reservation, run IDs, projection, sequence, replay, subscriptions,
            cancellation handle, terminal confirmation
  | admits and monitors                       ^ Event sink / settlement
  v                                            |
RunSession: Runtime start + owner-only await --+
  |
  v
Runtime RunServer -> Agent Task -> Provider / Tool -> Workspace
```

The three API roles are separate for correctness:

- Socket is a transient transport observer. Combining it with RunSession would let
  disconnect destroy Runtime's sole await owner and make reconnect impossible.
- RunSession is the stable Runtime owner. Combining it with Manager would block API
  admission/state calls during synchronous Workspace opening and conflate one run's
  owner-only await with observation by multiple connections.
- RunManager is the serialization point for shared bounded state. It sends only a
  coalesced wakeup; Socket pulls frames, so a slow transport never executes inside
  Runtime's synchronous event-sink call.

RunSession alone calls `Runtime.start_run/3` and `Runtime.await/2`. RunManager alone
retains the opaque Run for non-owner client cancellation. Socket receives an
authority-free policy projection and never receives Config capabilities, Provider,
Runtime callbacks/options, credentials, or opaque handles. A WebSock `Socket` is a
callback running in Bandit's connection process, not a separately supervised worker.

## Start And Admission Trace

`run.start` becomes a Runtime Request through these bounded transitions:

1. Router validates Host, route, query, forbidden headers, Origin, upgrade shape,
   and key, then passes Socket only an authority-free policy.
2. Protocol bounds encoded bytes and the decoded JSON tree, requires the exact v1
   envelope, validates prompt, absolute `cwd`, allowlisted model, and lowering-only
   Budget, and constructs an internal `Command.Start`.
3. Manager assigns the random server run ID, atomically reserves the one active run,
   subscribes the calling Socket at cursor zero, and starts a temporary RunSession.
4. Socket sends `run.accepted` before any continuation can deliver progress.
5. RunSession reconstructs a fresh trusted CapabilitySet and Runtime Options from
   Config, lowers Budget again, and constructs `Synapse.Run.Request` with the server
   run ID before calling Runtime.

Prompt and `cwd` are client content, not opaque authority. `cwd` chooses an absolute
root under the cooperative same-user policy; only trusted Config decides whether
read, write, or process execution is permitted. A failure before reservation returns
`server.error`. After `run.accepted`, startup and lifecycle failures produce exactly
one sequenced `run.terminal`, never a second command error.

## Event And Terminal Trace

For an ordinary Runtime `TextDelta`:

1. Runtime invokes the sink created by RunSession; the actual caller is the Runtime
   RunServer/Agent path, so Manager authenticates the exact active run identity and
   closed Event contract rather than the caller PID.
2. Manager validates event order, appends the delta to bounded projection text,
   increments the signed-64-bit sequence, creates the exact `run.event` map, encodes
   it, and appends the encoded bytes to bounded replay in one GenServer transition.
3. Manager sends one coalesced `{:synapse_run_changed, run_id}` wakeup per subscriber.
4. Socket pulls after its acknowledged cursor. It decodes retained frames only to
   validate exact keys, run ID, UTF-8, and contiguous sequence, then forwards the
   original encoded bytes without transformation.

Terminal Run Events are intentionally different. Manager first retains a compact
unsequenced `PendingTerminal` that is invisible to subscribers. RunSession's
owner-only await must return the matching cleanup-gated Result/Error before Manager
allocates the final sequence and exposes `run.terminal`. `runtime_lost` is the only
explicit settlement-unproven terminal. Owner loss without that typed await result is
`run.owner_lost`, not a false cleanup-confirmed terminal.

## Cancellation And Cursor Races

Before Runtime handle registration, Manager records `cancel_requested` and returns
the acknowledgement without claiming settlement. It cannot interrupt synchronous
Workspace opening; once RunSession receives and registers the handle, Manager
immediately invokes idempotent `Runtime.cancel/1`. After registration, Manager calls
cancel immediately. Cancellation consumes no sequence and sends no subscriber
wakeup. RunSession separately cancels only for lifecycle cleanup such as Manager
loss, invalid await behavior, or process shutdown.

For reconnect, clients persist the last sequence actually applied:

- If `after_seq >= first_available_seq - 1`, `run.snapshot` uses `mode: replay`,
  has no projection/terminal, preserves the cursor, and subsequent pulls deliver
  exact contiguous retained frames.
- If `after_seq < first_available_seq - 1`, `run.snapshot` uses `mode: snapshot`
  and `reset: true`; its complete current projection and optional terminal replace
  client state and advance directly to `last_seq`.
- A cursor may become stale between subscribe and pull, producing the same reset
  asynchronously with `request_id: null`.
- Subscription without a cursor returns an authoritative snapshot with
  `reset: false`; it is not a stale reset.

A reset restores current projection, not omitted event history. It prevents silent
projection gaps but is not an audit log. Replay and reset are both process-lifetime
views of Manager memory, never durable recovery.

## Replay And Failure Consequences

| Event or failure | State and restart consequence |
| --- | --- |
| old replay prefix exceeds count/bytes | oldest frames are lost; projection remains and stale cursors reset |
| completed-run count/aggregate eviction | the complete run lookup, snapshot, terminal, and replay are lost |
| Socket exits | its subscriptions disappear; run, session, Runtime work, and replay survive; no cancellation |
| Bandit/listener exits | connections die and only Bandit restarts; Manager, SessionSupervisor, RunSession, and replay survive |
| RunSession exits | temporary child is not restarted; Manager cancels a registered handle and exposes pending cleanup terminal or `run.owner_lost`; without a later terminal the active reservation can remain until Manager/application restart |
| SessionSupervisor exits | active RunSession is lost as above; Manager survives; SessionSupervisor and Bandit restart; no replacement run starts |
| RunManager exits | every run ID, projection, sequence, replay entry, terminal, and subscription is lost; Manager, SessionSupervisor, and Bandit restart; old sessions are cancelled, never replayed |
| Runtime RunServer exits | owner-only await returns `runtime_lost`; API exposes one interrupted settlement-unproven terminal; Runtime work is not replayed |
| normal application shutdown | Bandit stops first, sessions request cancellation while Manager and lower cleanup infrastructure remain; terminal delivery is not guaranteed |
| application/VM loss or fresh start | all API memory and sequence identity are lost; no in-tree recovery or durable replay exists |

RunSession loss alone does not erase Manager replay. Manager loss, application stop
or restart, VM/host loss, completed-run eviction, and sliding prefix eviction are
the conditions that lose some or all replay. Listener loss is explicitly not one.

## Wire Content And Authority Boundary

| Direction | Allowed content | Authority that must not cross |
| --- | --- | --- |
| client to server | request ID, prompt, absolute `cwd`, optional allowlisted model, lowering-only seven-field Budget, server-issued run ID, replay cursor, empty ping payload | credentials, capability booleans/sets, Provider modules, instructions, callbacks, sinks, openers, Runtime Options, Workspace/Tool limits, handles, PIDs, references, functions |
| server to client | protocol/replay mode, run ID/status, configured model, run/turn/tool/Provider identifiers, text deltas, bounded projection/counters, public Tool status/metadata, five-field Result, closed sanitized Agent/Runtime/API errors | Provider `final_response`, Runtime Run, Workspace Handle, Config, callbacks, raw exceptions/stacktraces/process reasons, decoder internals, credentials or authorization material |

Prompt and `cwd` are not echoed in ordinary frames. Model output may appear only at
`payload.event.delta`, `payload.projection.text`, `payload.result.text`, and
`payload.terminal.result.text`. Agent error message/details are also explicit
bounded wire content. Tool process output is not a raw API event field. Fresh
string-keyed maps, never generic struct serialization, enforce this allowlist.

The run ID is a lookup and cancellation identifier, not authentication. Any same-user
process able to connect and learn it may act under trusted server policy.

## Deterministic Verification Map

| Behavior | Deterministic evidence without Tokamak |
| --- | --- |
| Config, Protocol, Wire, limits, atom safety | pure contract, boundary, fixed-seed JSON, and exact-map tests |
| Manager projection, sequence, replay, cancellation, eviction | isolated GenServer tests with injected session starter and cancellation callback |
| RunSession ownership and races | injected RuntimeBoundary process tests proving one PID starts/awaits and cancellation registration order |
| Socket ordering, cursors, violations, mailbox bounds | direct WebSock callback tests with controlled Manager replies |
| Host, Origin, framing, close codes, capacity | real loopback Bandit/Gun tests on port zero |
| complete Agent/Tool lifecycle | external Gun/JSON client plus Fake Provider and controlled Fake Workspace |
| real process cancellation and cleanup | Fake Provider plus temporary Real Workspace; no network model dependency |
| restart and shutdown consequences | explicit process kills and an external application-shutdown BEAM fixture |
| disclosure | distinct content, credential, callback, Provider-response, and opaque-authority sentinels across wire, logs, inspection, and status |

Every receive is bounded, scheduler races use monitors/messages/barriers instead of
finite sleeps, and the shared acceptance client imports only Gun and JSON. The two
real Tokamak scenarios are separately tagged `:live_tokamak`, excluded from normal
`mix test`, credential-gated, and evidence beyond the deterministic acceptance bar.

## Phase 1 Configuration

`Synapse.API.Config` is the only public Phase 1 API module. `new/1` validates
trusted atom-keyed application policy without reading environment or starting a
resource. `load/2` additionally reads only `SYNAPSE_API_PORT` and `SYNAPSE_MODEL`
through an injected reader. Environment port zero is forbidden; trusted test
configuration may use it. An enabled API requires an explicit default model from
trusted configuration or `SYNAPSE_MODEL`; allowlist order never selects a model.

Production capabilities enable read, write, and same-user process execution.
They cannot be supplied to `lower_budget/2`, which accepts only the seven known
Budget atoms and rejects values above server policy. Runtime Provider, fixed
instructions, Workspace/Tool limits, callbacks, and opener remain inside a
validated, inspect-redacted `Synapse.Runtime.Options`.

The hard-limit fields and protected resources are:

| Config field | Default | Protected resource |
| --- | ---: | --- |
| `max_incoming_message_bytes` | 2,097,152 | assembled client JSON allocation |
| `max_incoming_frame_payload_bytes` | 2,097,152 | one incoming frame payload |
| `max_outgoing_message_bytes` | 1,048,576 | one encoded frame, including a completed snapshot |
| `max_prompt_bytes` | 262,144 | retained user input and escaped start command |
| `max_request_id_bytes` | 128 | per-command correlation state |
| `max_run_id_bytes` | 64 | run lookup keys |
| `max_origin_bytes` | 512 | Origin parsing work |
| `max_json_depth` | 16 | decoder traversal and stack work |
| `max_json_object_keys` | 32 | one decoded object |
| `max_json_array_elements` | 128 | one decoded array |
| `max_json_nodes` | 4,096 | aggregate decoded tree |
| `max_http_request_line_bytes` | 8,192 | HTTP request-line allocation |
| `max_http_headers` | 32 | HTTP header collection |
| `max_http_header_line_bytes` | 1,024 | one HTTP header line |
| `max_http_header_bytes` | 32,768 | aggregate header names and values |
| `connection_inactivity_ms` | 60,000 | inbound-idle socket lifetime |
| `max_protocol_violations` | 8 | repeated invalid-command work |
| `max_connections` | 128 | concurrent socket processes |
| `max_subscriptions_per_socket` | 16 | per-client cursor state |
| `max_subscribers_per_run` | 128 | run fanout state |
| `max_replay_events` | 2,048 | retained replay entries, including terminal |
| `max_replay_bytes` | 4,194,304 | encoded replay plus fixed entry overhead |
| `max_projection_text_bytes` | 64,000 | accumulated assistant text |
| `max_pull_events` | 64 | one replay pull batch |
| `max_pull_bytes` | 1,048,576 | one encoded pull response batch |
| `max_completed_runs` | 16 | process-lifetime completed lookup |
| `max_active_state_bytes` | 6,291,456 | one active run plus terminal/snapshot reserve |
| `max_aggregate_state_bytes` | 16,777,216 | all retained API run state |

Config validates cross-resource relationships. Worst-case JSON escaping for both
projection text and duplicated successful terminal text must fit one completed
snapshot. Projection capacity must cover the server output Budget, pull capacity
equals one outgoing message, replay fits one maximum frame plus entry overhead,
HTTP per-line/count limits must fit aggregate headers,
and replay/projection/snapshot reserves plus worst-case identifiers, subscribers,
and fixed run overhead must fit active and aggregate state.

## Phase 1 Internal Contracts

Internal command constructors validate request and run IDs, prompt/path/model,
lowered Budget, and signed-64-bit cursors without creating atoms from strings.
Internal state constructors validate active Tool summaries, projection text and
counters, subscriber cursors, encoded and accounted replay byte counts, and
pre-confirmation run state.
Run records reserve one maximum completed snapshot and carry explicit accounted
bytes for later Manager transitions. Replay and subscriber accounting includes
fixed overhead. Terminal Run Events are reduced after validation to compact
pending projections containing only API result/error fields; Provider
`final_response` is not retained by RunManager.

Phase 1 initially limited run records to active statuses. Phase 2 defined the
exact confirmed-terminal union, and Phase 3 introduced it into RunManager
transitions without allowing generic maps or Provider values into retained state.

All internal `Inspect` implementations are allowlisted and return an
invalid-redacted fallback for malformed structs. They never inspect prompts,
paths, model values, encoded output, terminals, PIDs, references, callbacks, or
Runtime handles. There is no API GenServer in Phase 1, so no API process state can
yet implement `format_status/1`; RunManager and RunSession add and test that
process-level redaction in their implementation phases.

## Phase 2 Protocol And Wire

`Synapse.API.Protocol.decode/2` is pure. It checks encoded bytes before decoding,
bounds the decoded tree, validates the exact four-key envelope, and translates
only fixed string literals into known internal command fields. It returns a typed
command, a stable sanitized error with a validated request ID or `nil`, or the
close-only `:message_too_big` classification. The root is depth 1; maps, lists,
and scalar values count as aggregate nodes while object keys do not. The selected
JSON decoder keeps binary keys and creates no atoms. Duplicate object keys are
collapsed before these limits run; current Elixir keeps the first occurrence, but
protocol compatibility does not promise duplicate ordering.

`Synapse.API.Wire` constructs fresh string-keyed maps for each server message and
each concrete non-terminal Run Event. It never generically encodes a struct. Tool
completion metadata is reduced to matching `tool` and one of four public
`outcome` values. Agent, Runtime, and API terminal errors have separate exact
shapes. `Synapse.API.ConfirmedTerminal` strips Provider `final_response`, validates
one source variant, and uses fixed API prose for settlement mismatch. Every final
JSON iodata value is measured against `max_outgoing_message_bytes`.

`server.error` is a command/protocol response and never settles an accepted run.
After `run.accepted`, startup or lifecycle failure is represented by exactly one
`run.terminal`. Wire fixtures compare decoded structure rather than object key
order; compatibility is the explicit field mapping, not Elixir struct layout.

## Phase 3 RunManager

`Synapse.API.RunManager` is an ephemeral GenServer projection above Runtime, not
the Runtime owner. It serializes one active reservation, event order, sequence,
projection, pending/confirmed terminal, replay, subscriptions, and completed
eviction. A trusted injected session starter lets Phase 3 prove admission and
rollback before RunSession exists; Phase 4 supplies the real temporary child.

Run records store last exposed sequence, initially zero. Ordinary progress stops
before the final two signed-64-bit values; owner loss may consume the penultimate
slot and terminal settlement the final slot without wrap. Explicit order state
prevents duplicate turns and mismatched Tool completion. Runtime cleanup progress
may continue after owner loss while status remains `owner_lost`, and a validated
cleanup-gated terminal may override earlier progress classification.

Replay stores already encoded frames and fixed entry overhead. It evicts only the
minimum prefix on strict count or byte overflow. Pull capacity equals the outgoing
frame ceiling, so one retained frame can always make progress. Subscribe returns
snapshot, reset, or replay semantics from `first_available_seq`; pull can return an
asynchronous reset if a slow subscriber becomes stale. One outstanding
`{:synapse_run_changed, run_id}` is coalesced per subscriber until pull catches up.

Cancellation records intent without sequence. Handle registration immediately
applies earlier intent. Pending terminals consume no sequence or notification;
matching settlement exposes one terminal. Runtime-only failures, sink-rejected
`event_sink_failed`, owner loss, and mismatch each have explicit bounded paths.
Completed records and their subscriber monitors are evicted oldest-first for both
count and aggregate accounting. Manager loss intentionally loses lookup and replay;
no API state is durable in the MVP.

## Phase 4 RunSession

`Synapse.API.RunSession` is one temporary GenServer per admitted API run. Its
`init/1` validates only bounded trusted arguments, monitors Manager, and returns
before Runtime startup. `handle_continue/2` constructs a fresh CapabilitySet,
lowers the command Budget against Config again, validates the server-ID Request and
trusted Runtime Options, then calls `Runtime.start_run/3` directly. This keeps
synchronous Workspace opening out of Manager while preserving the exact process
identity required by owner-only `Runtime.await/2`.

After handle registration, RunSession polls await with a one-second receive window.
It returns to the GenServer loop after timeouts so Manager loss and OTP system
messages can run, but it must not consume Runtime's owner-terminal message between
polls. Matching internal terminal messages are requeued and handed immediately to
await; unrelated mailbox traffic reschedules the next poll. Deterministic tests
exercise both races and assert that start plus every await execute in the admitted
RunSession PID.

Manager remains the sole delegate for client cancellation. Cancellation requested
while Workspace opening is blocked is stored without claiming completion and is
applied when RunSession registers the handle. RunSession calls cancellation only
for lifecycle cleanup: Manager loss, an invalid await contract, or catchable child
shutdown. It never waits for cleanup during `terminate/2`, and its temporary child
spec prevents replay after any exit.

Only validated Agent Result, Agent Error, or Runtime Error settlement crosses back
to Manager. Startup failures become fixed Runtime terminals after admission;
malformed boundary returns become `runtime_unavailable`. Successful settlement
clears the handle before normal stop. State, startup arguments, Runtime callbacks,
handles, process status, and logs are tested with prompt, path, callback, and secret
sentinels and expose only a redacted lifecycle phase.

Phase 4 proved the child under an isolated DynamicSupervisor. Phase 6 provides the
named, maximum-one-child SessionSupervisor and installs the production starter
closure in the application supervision tree.

## Phase 5 Socket

`Synapse.API.Socket` is a WebSock callback module, not a Runtime or run-lifecycle
owner. Each connection retains one authority-free Policy projection, a Manager
reference, at most 16 run cursors, at most 16 unique pending pulls, one continuation
flag, and a cumulative violation counter. Policy copies only model/Budget and
protocol, wire, Tool-identifier, cursor, and message ceilings. It has no Provider,
CapabilitySet, Runtime Options, instructions, callbacks, opener, credential, or
opaque handle fields. Socket arguments and state use redacted inspection.

`init/1` pushes exact `server.hello` before any input callback. Text messages pass
only through Protocol and dispatch only typed Start, Cancel, Subscribe, or Ping
values. Start, Cancel, Subscribe, pull, and unsubscribe use RunManager. Application
Ping is answered locally because it has no run state. Request IDs exist only for
the duration of one callback and may be reused after a response.

One callback's direct response is returned before a self-scheduled continuation
from that command can run. In particular, `run.accepted` precedes progress emitted
behind its synchronous Manager admission, and a subscribe snapshot precedes its
replay pull. This is serial callback ordering, not global priority over a Manager
message that Bandit's connection process selected before a later network frame.
Asynchronous replay, live events, terminals, and stale resets always use
`request_id: null`.

Manager pull is bounded by both event count and encoded bytes. Socket independently
checks exact pull keys, contiguous sequence advancement, cursor equality, progress,
UTF-8, and the closed event/terminal envelope before forwarding the original bytes.
At most one local continuation is scheduled across all runs. Pending runs rotate
fairly, and Manager's one outstanding notification per subscriber bounds slow-client
mailboxes. A malformed Manager response or unsafe cursor state closes 1011 rather
than guessing state or exposing the term.

Close policy is:

| Condition | Code | Additional message |
| --- | ---: | --- |
| Complete binary application message | 1003 | none |
| Ninth ordinary protocol violation | 1008 | none |
| Oversized assembled text message | 1009 | none |
| Unsafe internal callback, Manager, or cursor state | 1011 | none |
| Invalid UTF-8 text | Bandit-owned 1007 | none |
| Malformed framing | Bandit-owned RFC 6455 code | none |
| Oversized frame or fragmented message | Bandit-owned 1009 | none |

Violations one through eight receive one fixed `server.error`; successful commands
and valid-command domain errors do not reset or increment the count. Bandit rejects
invalid UTF-8 and fragmented/frame transport violations before Socket sees a
complete application message. Phase 6 configures and tests those real transport
paths, including assembled fragmented-message overflow.

Clients should persist the last sequence they actually applied, not a sequence the
server may have queued for writing. Replay frames must be applied strictly in
increasing order. A replay acknowledgement keeps the supplied cursor and is
followed by later frames. An authoritative snapshot replaces the complete local
projection and terminal for that run and advances directly to `last_seq`; no nested
terminal should then be applied again. On reconnect, clients send their last
applied sequence. If it is stale, the reset snapshot replaces local state instead
of silently skipping a gap.

Termination sends a bounded asynchronous unsubscribe request and never calls
cancellation. Manager's subscriber monitor is the fallback for abrupt or
uncatchable connection death. A real Runtime integration test kills the initiating
Socket after handle registration and proves RunSession, Provider execution,
Workspace cleanup, and successful settlement continue without a cancellation call.

## Phase 6 Router And Supervision

Ordinary application startup is API-disabled and ignores `SYNAPSE_API_PORT` and
`SYNAPSE_MODEL`; it preserves the exact Workspace, Task, and Runtime three-child
tree. Trusted application configuration with `enabled: true` opts into environment
loading. `mix synapse.server` uses `app.config`, rejects every argument, forces and
validates enabled policy once, stores that exact Config for Application startup,
and remains in the foreground. Startup failure restores prior application
configuration and emits one fixed Mix error.

The task reads only:

```text
SYNAPSE_MODEL       required unless trusted enabled config supplies a model
SYNAPSE_API_PORT    optional canonical decimal port, default 4848
```

`TOKAMAK_API_KEY` is not a server-startup requirement and remains request-time
Provider configuration. The listener is always the literal IPv4 loopback tuple;
there is no bind argument or remote-listening environment variable. On readiness
the task prints:

```text
Health: http://127.0.0.1:<port>/health
WebSocket: ws://127.0.0.1:<port>/v1/socket
```

Router stores redacted Socket arguments and scalar transport limits, never Config.
It validates actual socket address/port plus canonical `localhost:<port>` or
`127.0.0.1:<port>` Host before exact route matching. Socket upgrade then validates
empty query, forbidden-header absence, one bounded local Origin, WebSocket request
shape, and one canonical 16-byte key. Extension headers are removed before upgrade;
HTTP and WebSocket compression, HTTP/2, subprotocols, and protocol-error logging are
disabled.

Fixed Router responses are JSON/no-store: health 200, forbidden 403, unknown 404,
method-not-allowed 405 with `Allow: GET`, and upgrade-required 426 with
`Upgrade: websocket`. Bandit owns syntactically invalid/missing/duplicate Host,
request-line/header limits, invalid UTF-8, framing errors, and frame/fragment 1009
before Router or Socket callbacks. Real tests cover canonical and rejected Host and
Origin matrices, raw malformed keys and extension offers, binary 1003, UTF-8 1007,
single-frame 1009, and assembled-fragment 1009 without disclosure.

The enabled tree is:

```text
Synapse.Supervisor                         :one_for_one
|-- Workspace.Supervisor                   permanent
|-- TaskSupervisor                         permanent
|-- Runtime.Supervisor                     permanent
`-- API.Supervisor                         permanent, :rest_for_one
    |-- API.RunManager                     permanent
    |-- API.SessionSupervisor              permanent, max_children: 1
    |   `-- API.RunSession                 temporary
    `-- Bandit                             permanent, shutdown 6000 ms
```

Listener loss restarts only Bandit and preserves active sessions and retained replay.
SessionSupervisor loss cancels its active temporary session, retains Manager state,
and restarts the listener; no replacement run starts. Manager loss discards
process-lifetime lookup/replay and restarts the complete API suffix; idempotent
RunSession cleanup is requested and no replacement run starts.
Normal reverse shutdown stops Bandit first, then sessions while Manager and lower
Runtime/Task/Workspace infrastructure remain alive, then Manager, Runtime, tasks,
and Workspace. Terminal delivery is not guaranteed during application shutdown.

## Phase 7 Deterministic Acceptance

The acceptance client uses only Gun and protocol v1 after discovering an isolated
port-0 listener. It validates `server.hello`, sends the defining `run.start`, and
uses the server-assigned run ID to derive the Fake Provider and Tool operation IDs.
Workspace opening is held behind a trusted test callback while those scripts are
constructed. This keeps random production-format run IDs in the proof and avoids a
production ID-generator seam.

One controlled Fake Workspace scenario executes read, write, and Bash contracts
with no host effects. It pauses after `tool.started` so the initiating connection
can close after sequence 3. The run remains active without cancellation. A new
connection subscribes at sequence 3 and receives sequences 4 and 5 from retained
replay; another subscribes at stale sequence 0 and receives an authoritative reset
whose projection identifies the active write. The retained connection then receives
live sequences through one cleanup-confirmed completed terminal at sequence 13.
The terminal exposes only the five public Result fields and contains neither the
Provider final response nor Provider response identity.

A separate Real Workspace scenario starts a long mutation-unknown Bash command,
waits for observed `ready` output, and cancels from another WebSocket. Manager, not
either socket, invokes non-owner Runtime cancellation. The defining client receives
one interrupted Agent terminal; the shell PID, MutationServer, process-environment
guard, Runtime server/task, and RunSession are all confirmed down before teardown.

Two failure cases complete the lifecycle matrix. A rejected Workspace opener is
accepted first and then emits one fixed `workspace_open_failed` Runtime terminal at
sequence 1 without its sentinel path or reason. Killing a registered Runtime
RunServer while Fake read is blocked emits progress sequences 1 through 3 followed
by one `runtime_lost` interrupted terminal at sequence 4. Each scenario closes and
monitors Gun and subscribed server sockets, asserts the core dynamic supervisors
are empty, then stops and monitors the isolated API tree.

## Phase 8 Reliability And Security Hardening

Protocol hardening uses a fixed-seed recursive JSON generator with a disjoint
never-warmed corpus. Generated keys, values, arrays, maps, and depths plus malformed
byte mutations produce only documented decode results and do not increase the atom
table. Separate monitored decodes take valid JSON nesting far beyond policy depth
without killing the caller or affecting the next command. Maximum escaped prompt,
model, request ID, `cwd`, event identifiers, metadata, delta, terminal text, exact
single-frame payload, and exact fragmented-message payload all pass at equality;
the next byte is rejected at the owning boundary.

Real transport tests split valid JSON inside escapes and multibyte UTF-8, pipeline
64 pings with one reused request ID, close a ninth protocol violation with 1008,
and parse raw server close frames to confirm 1009 for frame and assembled-message
overflow. One configured connection is admitted while the next waits until capacity
is released. Expanded Host and Origin matrices cover suffixes, rebinding-style
names, alternate numeric loopback forms, duplicate values, malformed authority,
non-local schemes, and explicit port boundaries without reflection.

Failure injection now reaches the real stack. The acceptance run kills a
Bandit-owned Socket and later Bandit itself while Provider and Tool work is blocked,
then discovers the replacement port, reconnects from sequence 5, and completes
without consuming either script twice. Existing active SessionSupervisor,
RunSession, Manager, and Runtime-loss tests are strengthened by explicit old-run
lookup loss, cancellation, and no-restart assertions. Manager tests force a valid
projection that Wire policy rejects, replay count and byte pressure, signed-64-bit
sequence exhaustion, subscriber death, and terminal mismatch with a registered
Runtime handle.

Application shutdown is tested in an external BEAM so the actual named root can be
stopped safely. A Real Workspace Bash process publishes `ready` and ignores TERM;
stopping `:synapse` still confirms the RunSession, Runtime coordinator, Agent task,
MutationServer, process guard, and shell PID all terminate and the temporary process
environment disappears.

Disclosure evidence uses distinct credential, prompt, path, model-output, Tool,
Provider-response, callback, and opaque-authority sentinels. Successful, replayed,
reset, terminal, dependency-crash, HTTP, inspection, and status surfaces exclude
all forbidden values. The model-output sentinel appears only in
`payload.event.delta`, `payload.projection.text`, `payload.result.text`, and the
nested completed-snapshot terminal result. Successful-run and injected-failure logs
contain none of those content values. The Real API command also proceeds only after
confirming `TOKAMAK_API_KEY` is absent from its reconstructed child environment.

Resource tests measure RunManager process memory and referenced binaries before and
after replay-count, replay-byte, completed-count, and aggregate eviction. These
measurements complement logical accounted bytes; they do not claim the two are
identical. A parked real Socket callback process retains exactly one coalesced
Manager notification and then one continuation. A static AST test keeps every API
test receive bounded and rejects finite scheduler sleeps.

## Phase 9 Live Tokamak Acceptance

Live API tests remain tagged `:live_tokamak`, excluded by default, and skipped
unless both `TOKAMAK_API_KEY` and `SYNAPSE_MODEL` are non-empty on a supported Real
Workspace platform. The deterministic and live suites now share
`Synapse.API.TestClient`, a Gun/JSON-only protocol client loaded from test support;
it imports no Synapse production module and sends only protocol-v1 maps.

The live text case launches the literal `mix synapse.server` task in an external
BEAM with production Tokamak and Real Workspace policy. The client validates hello,
omits model and all trusted authority from `run.start`, receives non-empty
`text.delta` progress, and confirms one completed marker terminal with no Tool
calls. Fixed-port bind attempts are bounded and retried only before readiness.

The live coding case starts an isolated port-zero API subtree over the application's
production Runtime, Task, and Workspace supervisors. It creates only a temporary
`README.md`, starts the run, receives sequence 1, proves the RunSession and Manager
reservation are still active, disconnects, reconnects with cursor 1, and consumes
gap-free replay plus live events. The observed Tool names include read, write, and
Bash. The exact Bash verification writes a command marker and emits a verification
marker; after terminal the test independently checks `hello.txt`, that marker file,
and the verification command's exit status and output.

After the coding terminal, a completed authoritative snapshot carries the same
terminal without duplication. The RunSession exits normally and the production
Runtime, Task, and Workspace supervisors are empty before the emergency cleanup net
runs. Both temporary roots are explicitly removed and checked absent.

Every live handshake header, hello, event, snapshot, terminal, pong, command, and
captured startup/run/shutdown log is checked for the raw and trimmed real API key
before any assertion could print that surface. Additional checks reject
authorization material, Provider Response inspection, Runtime/Workspace authority,
PIDs, references, functions, and named production callbacks. Model markers remain
allowed only in documented content-bearing frames and are absent from logs.

## Phase 10 ExDoc And Comprehension Review

The public documentation now separates supported API pages from hidden command,
policy, state, Socket-argument, Runtime-boundary, and terminal-error modules. Public
types have typedocs, supported functions have docs/specs, and each API module links
to this guide. ExDoc groups the ten API modules and `mix synapse.server` under
`Local WebSocket API`; the API plan and this guide remain grouped as Plans and
Learning extras.

The current-behavior chapters above consolidate protocol v1, ownership, admission,
event/terminal, cancellation, cursor, replay-loss, failure, wire-authority, and
deterministic-test traces. README and lower component guides now describe the API
as a higher process-lifetime adapter without moving Provider, Workspace, Tool,
Agent, or Runtime ownership downward. Relative Markdown links are checked by
`api_phase10_test.exs`, and generated HTML review confirmed the sidebar group,
extras, guide anchors, module cross-links, source links, and rendered examples.

Final verification passed with 794 deterministic tests, including 34 doctests,
while seven opt-in tests remained excluded. The separately invoked live API suite
passed both Tokamak scenarios. Compile-with-warnings, formatting, warning-free
ExDoc generation, and diff whitespace checks also passed. Suite-load races found
during this final pass were removed by honoring the injected await timeout, allowing
the valid `:noproc` monitor race, and keeping non-boundary timing tests away from
their deadline edges; no production behavior changed.
