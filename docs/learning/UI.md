# Web UI

This guide explains how to operate and maintain the standalone Svelte 5 client in
`ui/web`. The client is a post-MVP adapter for Synapse WebSocket protocol v1. It is
not part of the Mix application, and Synapse neither builds nor serves its assets.

The exact wire contract remains authoritative in [API.md](API.md). The completed
implementation checklist and test matrix are in
[PLAN-UI.md](../plan/PLAN-UI.md).

## Run The Client

From the repository root, install the locked frontend dependencies and Chromium:

```sh
npm --prefix ui/web ci
npm --prefix ui/web exec playwright install chromium
```

Start the trusted local API and Vite in separate terminals:

```sh
TOKAMAK_API_KEY="..." SYNAPSE_MODEL="..." mix synapse.server
npm --prefix ui/web run dev
```

Open <http://127.0.0.1:5173>, connect to
`ws://127.0.0.1:4848/v1/socket`, and wait for `server.hello` before starting a
run. Vite has no API proxy. The browser opens the WebSocket directly so production
Host and Origin enforcement remains in the exercised path.

The directory in which `mix synapse.server` starts is captured once and advertised
by hello. Connecting prefills that absolute path in the Workspace field, so the
normal flow requires only a Prompt. The field remains editable for an intentional
override. This sets the initial Workspace and Bash working directory; it does not
sandbox Bash or prevent same-user traversal elsewhere.

Use `npm --prefix ui/web run build` and
`npm --prefix ui/web run preview` to inspect the production bundle locally. The
preview server is still only a static asset server; `mix synapse.server` must run
separately.

## Ownership Tree

The browser, static server, and BEAM are sibling processes. No frontend process is
supervised by Synapse:

```text
developer shell
|-- Vite dev or preview server
|   `-- serves ui/web source or ui/web/dist only
|-- browser
|   `-- one Synapse Web page
|       |-- App.svelte presentation and form state
|       |-- Client controllers and in-memory run projection
|       `-- direct WebSocket to 127.0.0.1:4848/v1/socket
`-- mix synapse.server
    `-- Synapse.Supervisor
        |-- Synapse.Workspace.Supervisor
        |-- Synapse.TaskSupervisor
        |-- Synapse.Runtime.Supervisor
        `-- Synapse.API.Supervisor
            |-- Synapse.API.RunManager
            |-- Synapse.API.SessionSupervisor
            |   `-- temporary Synapse.API.RunSession
            `-- Bandit loopback listener
```

An accepted run belongs to `RunSession` and Runtime, not to the socket or browser.
Closing the tab, disconnecting, replacing the socket, or losing Vite cannot cancel
it. Only an explicit `run.cancel` command expresses cancellation intent.

The three browser layers remain separate because they fail and recover differently:

| Layer        | Owner                                 | Reason for the boundary                                                                                                        |
| ------------ | ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Transport    | `connection.svelte.ts`                | Socket generations, hello, correlations, keepalive, reconnect, and close policy can reset without mutating accepted run state. |
| Projection   | `run.svelte.ts` plus `run-reducer.ts` | Sequence and snapshot validation decides what server state is authoritative independently of transport timing.                 |
| Presentation | `App.svelte` plus components          | DOM, focus, layout, and accessibility consume validated view data and never parse wire input or own run lifetime.              |

## Source Map

All application implementation is under `ui/web`; test fixtures are not imported by
production code.

### Protocol modules

| Source                           | Responsibility                                                                       |
| -------------------------------- | ------------------------------------------------------------------------------------ |
| `src/lib/protocol/constants.ts`  | Protocol version, closed enums, and browser limits.                                  |
| `src/lib/protocol/types.ts`      | Compile-time command, message, event, projection, Result, and terminal unions.       |
| `src/lib/protocol/validation.ts` | Shared exact-object, UTF-8, identifier, run-ID, and safe-integer checks.             |
| `src/lib/protocol/encode.ts`     | Fresh allowlisted JSON for `run.start`, `run.cancel`, `run.subscribe`, and `ping`.   |
| `src/lib/protocol/decode.ts`     | Bounded duplicate-aware JSON parsing and runtime validation of every server message. |

### Client modules

| Source                                       | Responsibility                                                                                            |
| -------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `src/lib/client/connection.svelte.ts`        | One socket generation, hello readiness, request correlation, keepalive, reconnect, and cleanup.           |
| `src/lib/client/pending.ts`                  | Bounded direct-response correlations and delayed-command warnings.                                        |
| `src/lib/client/run.svelte.ts`               | Accepted run identity, subscription strategy, replay/snapshot installation, recovery, and run-ID storage. |
| `src/lib/client/run-reducer.ts`              | Pure contiguous event and terminal reduction with transition and aggregate limits.                        |
| `src/lib/client/run-types.ts`                | Presentation-only run state, activity, and reduction result contracts.                                    |
| `src/lib/client/timeline.ts`                 | Generic entry-count and encoded-byte bounded timeline append.                                             |
| `src/lib/client/protocol-timeline.svelte.ts` | Sanitized bounded inbound/outbound inspector projection.                                                  |
| `src/lib/client/server-errors.svelte.ts`     | Stable server error code to fixed local operator guidance.                                                |
| `src/lib/client/composer.ts`                 | Prompt, path, model, and lowering-only Budget form validation.                                            |
| `src/lib/client/client.svelte.ts`            | Composition root joining connection callbacks to run, diagnostics, and error controllers.                 |

### Presentation modules

| Source                                        | Responsibility                                                                 |
| --------------------------------------------- | ------------------------------------------------------------------------------ |
| `index.html`                                  | Static document shell, viewport policy, and module entrypoint.                 |
| `src/main.ts`                                 | Browser bootstrap that mounts the single Svelte application.                   |
| `src/app.css`                                 | Global tokens, responsive layout, focus, reduced-motion, and print rules.      |
| `src/App.svelte`                              | Single-screen controls, draft state, notices, focus, and controller lifecycle. |
| `src/lib/components/AssistantOutput.svelte`   | One escaped plain-text output node and reader-controlled follow behavior.      |
| `src/lib/components/RunActivity.svelte`       | Bounded Tool and lifecycle activity without arguments or command output.       |
| `src/lib/components/TerminalResult.svelte`    | Source-aware completed, interrupted, Agent, Runtime, and API settlement.       |
| `src/lib/components/ProtocolInspector.svelte` | Explicit disclosure and copy of sanitized protocol summaries.                  |

## Start Trace

Submitting the form follows this path:

```text
App.svelte start
  -> composer.ts validateComposerDraft
  -> client.svelte.ts startRun
  -> connection.svelte.ts startRun
  -> crypto.randomUUID
  -> encode.ts encodeStartCommand
  -> WebSocket.send
```

For prompt `Inspect this workspace`, hello-prefilled path `/tmp/example`, omitted
model, and omitted Budget, the complete command is:

```json
{
  "version": 1,
  "type": "run.start",
  "request_id": "<browser UUID>",
  "payload": { "prompt": "Inspect this workspace", "cwd": "/tmp/example" }
}
```

Optional model and nonblank Budget fields are added only after local validation.
The encoder creates a fresh allowlisted object and never spreads form state. A model
name is public configuration metadata, not a credential and not Provider authority.

`connection.svelte.ts` correlates the returned `request_id` with the pending start.
Only that exact decoded `run.accepted` reaches `run.svelte.ts::handleAccepted`, which
installs the server-issued run ID through `initialRunState`, sets
`lastAppliedSeq` to zero, and stores the run ID. Acceptance means reservation and
RunSession admission; it does not prove Runtime startup or successful completion.

A connection lost before `run.accepted` is ambiguous. The client never resends the
start because work may already be active. Protocol v1 cannot discover that run ID;
the operator must inspect the workspace and, if the server remains busy and the run
cannot be identified, restart the API/application only after deciding that stopping
the active work is safe.

## Event-To-DOM Trace

One `text.delta` travels through this path:

```text
WebSocket message
  -> decode.ts bounds, parses, and validates the complete frame
  -> connection.svelte.ts verifies generation and response shape
  -> client.svelte.ts dispatches the typed message
  -> run.svelte.ts verifies active run and synchronization mode
  -> run-reducer.ts requires seq == lastAppliedSeq + 1
  -> run-reducer.ts validates turn/operation and bounded aggregate text
  -> one atomic RunState replacement
  -> App.svelte passes projection.text to AssistantOutput.svelte
  -> one escaped whitespace-preserving text node
```

TypeScript types alone do not validate network input. No server message may mutate
state before `decode.ts` constructs a validated value. Assistant text is never
rendered as HTML, Markdown, or one DOM node per delta.

JavaScript cannot exactly represent the API's full signed-64-bit cursor range. The
decoder therefore accepts only non-negative integer tokens through
`Number.MAX_SAFE_INTEGER`. Larger, decimal, or exponent cursor spellings fail
closed rather than silently changing replay position.

## Connection And Recovery

Opening a socket enters `awaiting_hello`. Only an exact protocol-v1 `server.hello`
makes it ready. A visible ready page sends one application `ping` after 25 seconds
and requires its correlated `pong`; timers pause while hidden. Ordinary network,
going-away, restart, and retry-later closes reconnect with bounded backoff. Protocol,
policy, size, UTF-8, internal, and normal closes require an explicit Reconnect.

Hello contains the bounded absolute server launch `cwd`. An empty Workspace field
adopts it. A field still owned by the automatic default follows a changed launch
path on reconnect, while a manual override survives. Clearing a manual value does
not refill it immediately; the next validated hello restores the default. The path
remains memory-only and is redacted from the protocol timeline and copied
diagnostics.

Hello also advertises `max_output_bytes` in `1..524288`. The Advanced Budget form
uses that value as the current lowering-only maximum while ready, retains the last
validated maximum through an outage, and replaces it on the next hello. It never
clamps or rewrites a draft; a value made excessive by reconnect remains visible and
fails on explicit Start. The numeric policy is safe to include in diagnostics and
is never stored in `sessionStorage`.

After reconnect, an in-memory run subscribes with its last applied cursor. The
server first acknowledges replay with `run.snapshot` in replay mode, including the
retained range and target `last_seq`. Retained `run.event` or `run.terminal` frames
then pass through the same reducer as initial live delivery. Once the target cursor
is reached, later frames continue live without a second projection path.

If the cursor predates retained history, or the client detects a duplicate, gap,
reversal, contradictory transition, or stalled catch-up, it requests a no-cursor
snapshot. Snapshot mode atomically replaces projection, terminal, cursor, and
event-derived activity. `reset: true` means earlier process-memory history was
evicted; it does not invent a run failure and is not durable history.

Completed snapshots carry `projection.text: ""` and the successful final text only
in `terminal.result.text`. The reducer reconstructs the view projection from the
Result, so reconnect presents the same output as live terminal delivery without
retaining two full wire copies. Protocol v1 snapshots remain single messages;
multi-megabyte output is deferred to a chunked snapshot protocol with bounded
reassembly.

A page reload has no in-memory projection. It restores only a validated run ID and
API URL, connects, and requests a no-cursor snapshot. Exactly these keys may enter
`sessionStorage`:

```text
synapse.api_url
synapse.run_id
```

Prompt, workspace path, model, Budget, output, terminal, cursor, activity, and
diagnostics stay memory-only. RunManager/application restart or completed-run
eviction returns `run_not_found`; replay never survives that boundary.

## Failure Presentation

Malformed frames close locally as a protocol fault and retain the last validated
view. Sequence faults retain that view while requesting an authoritative snapshot.
Stable `server.error` codes map to fixed local guidance; raw server prose, browser
exceptions, and frame strings are not rendered. Close codes are classified into
automatic-retry, explicit-reconnect, protocol, policy, or internal notices without
showing raw close reasons.

`run_not_found` clears stale restoration and states that the process-lifetime run is
gone. It does not synthesize a terminal. `runtime_lost` says cleanup settlement was
not observed. An acknowledged cancel remains distinct from terminal interruption.

## Trust And Storage

Loopback limits network reachability to the local host, and browser Origin checks
block ordinary cross-site browser access. Neither authenticates an OS user. A local
process that can reach the listener may omit Origin, and protocol v1 contains no
credentials. Do not run the server on a host with untrusted local processes.

Production policy permits filesystem reads, writes, and `process.exec` as the
Synapse server's OS user. Workspace path checks and BEAM process isolation are not
a filesystem, network, credential, process, CPU, or descendant sandbox. A run ID is
only a lookup/cancellation identifier, never authentication.

The browser receives no credentials, Provider modules, capability grants, Runtime
handles, callbacks, or opaque authority. Never place `TOKAMAK_API_KEY` in a frontend
`.env`, `VITE_*` variable, URL, storage, source, log, screenshot, or report. Model
text and server strings are untrusted content and remain escaped plain text.

Current persistence has three distinct boundaries:

| State                                   | Lifetime                                                                                                 |
| --------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| Browser URL and run ID                  | Current tab's `sessionStorage`.                                                                          |
| Browser projection and API replay       | Bounded memory; lost on page or RunManager/application restart respectively.                             |
| Workspace file and command side effects | Host filesystem/process effects under the selected `cwd`; inspect independently after ambiguous failure. |

The client does not fetch `/health` because that cross-origin HTTP endpoint is not
the WebSocket readiness contract. It uses no proxy so Host and Origin enforcement
remain real. It uses no SvelteKit because one static client-only screen needs no
SSR, routing, server loading, or backend-for-frontend.

## Verification

The default gates require neither Tokamak nor a user checkout:

```sh
npm --prefix ui/web run check
npm --prefix ui/web run lint
npm --prefix ui/web run test
npm --prefix ui/web run build
npm --prefix ui/web run test:security
npm --prefix ui/web run test:e2e
```

`test:e2e` includes desktop/mobile scripted protocol acceptance and one real API
boundary using the real Router, Socket, RunManager, RunSession, Runtime, Agent, and
Tool code with controlled Fake Provider/Workspace dependencies. Scripted browser
tests use an external port-zero WebSocket server, not an in-page replacement.

Live Tokamak acceptance is separate and explicit:

```sh
SYNAPSE_LIVE=1 TOKAMAK_API_KEY="..." SYNAPSE_MODEL="..." \
  npm --prefix ui/web run test:e2e:live
```

The live owner passes credentials only to the literal `mix synapse.server` child.
It removes them from Vite, Playwright, and Chromium environments, buffers output,
scans frames/logs/reports/artifacts for the exact key, and deletes live artifacts.
Default `test:e2e` cannot discover this project.

Backend live coverage is independently opt-in:

```sh
TOKAMAK_API_KEY="..." SYNAPSE_MODEL="..." mix test --only live_tokamak
```

## Troubleshooting

| Symptom                                | Check and action                                                                                                                                                   |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Connect never becomes ready            | Confirm `mix synapse.server` is running, the URL is loopback protocol v1, and `server.hello` can arrive within ten seconds. Do not substitute `/health` for hello. |
| Browser gets an Origin or policy close | Use the configured `127.0.0.1:5173` dev origin and direct socket URL; do not add a proxy or alternate host.                                                        |
| Start remains delayed                  | Do not resend. The response is ambiguous; inspect server logs and workspace effects.                                                                               |
| `run_busy` with no known run ID        | A prior ambiguous start may be active. Inspect the workspace and server process before choosing an application restart.                                            |
| Replay reports reset                   | Earlier retained events were evicted. Treat the installed snapshot as current process-memory state, not durable history.                                           |
| `run_not_found` after reconnect        | RunManager/application restarted or evicted the completed run. Inspect workspace effects; protocol v1 cannot restore it.                                           |
| Sequence or protocol fault             | Preserve the last validated UI view and inspect the sanitized protocol inspector. Reproduce with deterministic tests before changing reducers.                     |
| Provider live test fails               | Confirm the key/model in the server-only environment and inspect server logs; never expose the key through Vite variables.                                         |
| Playwright fails                       | Read the named project/spec output. Default stable-state artifacts are under `ui/web/test-results`; live artifacts are deliberately scanned and deleted.           |
| API remains stuck after owner loss     | A reservation can remain until API/application restart. First inspect command/workspace effects, then restart only when stopping retained work is acceptable.      |

## Safe Maintenance

Protocol objects are closed and reject unknown keys. Treat any command, response,
event, snapshot, terminal, enum, requiredness, limit, or semantic change as breaking
unless compatibility is proved for every existing client. The conservative default
is a new protocol version and endpoint; never silently reinterpret v1.

For a protocol change, update the API Protocol/Wire modules, this guide and API.md,
TypeScript types, encoder/decoder, reducer, scripted fixtures, real fixture,
backend acceptance, and browser acceptance together. Keep TUI and desktop work as
independent protocol clients; do not move frontend rendering or dependencies into
the Elixir application.

For a presentation-only change, keep validated projection contracts stable, add a
component test, and rerun desktop/mobile, keyboard, reduced-motion, Axe, and build
disclosure gates. For recovery changes, add pure reducer/controller coverage before
browser coverage so timing is not the only proof.
