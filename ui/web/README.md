# Synapse Web

Synapse Web is the standalone browser client for Synapse's local protocol-v1 API.
It is a static Svelte 5 application built by Vite under `ui/web`; the Elixir
application neither builds nor serves these files.

The implemented client is a responsive multi-turn chat console with
deterministic scripted acceptance, real Synapse integration, browser hardening,
and explicit opt-in live Tokamak acceptance.
It still opens no WebSocket on mount: Connect, Start, Cancel, Disconnect, Reconnect,
and New Run are explicit user actions over the protocol, connection, and run
controllers completed in Phases 2 through 4.

## Prerequisites

- Node 24 LTS (`>=24.0.0 <25`); development started on 24.14.0.
- npm 11 (`>=11.0.0 <12`); the lockfile was generated with 11.9.0.
- Chromium installed through Playwright for browser tests.
- Elixir is required for the real-boundary Playwright gate. Check, lint, unit, build,
  and security scans remain frontend-local.

Install exact locked dependencies from the repository root:

```sh
npm --prefix ui/web ci
npm --prefix ui/web exec playwright install chromium
```

Use `npm install` instead of `npm ci` only when intentionally changing package
dependencies and regenerating `package-lock.json`.

## Development

Start the client on its fixed local development origin:

```sh
npm --prefix ui/web run dev
```

Open <http://127.0.0.1:5173>. Vite is configured with no proxy. The client
connects directly to `ws://127.0.0.1:4848/v1/socket`, allowing the
browser and API to exercise the real Host and Origin boundary.

The Synapse server remains a separate process:

```sh
TOKAMAK_API_KEY="..." SYNAPSE_MODEL="..." mix synapse.server
```

Do not put `TOKAMAK_API_KEY`, Provider credentials, or any other secret in
`ui/web/.env`, a `VITE_*` variable, browser storage, a browser URL, or frontend
source. The browser protocol contains no credential field.

## Verification

Run the deterministic frontend gates:

```sh
npm --prefix ui/web run check
npm --prefix ui/web run lint
npm --prefix ui/web run test
npm --prefix ui/web run build
npm --prefix ui/web run test:security
npm --prefix ui/web run test:e2e
```

`npm --prefix ui/web run verify` combines all six commands above. `test:e2e`
compiles the real Elixir fixture, builds, and starts Vite preview. Browser tests verify
desktop/mobile layout, intermediate-width control containment, the expanded Budget,
required semantics, keyboard disclosure, focus visibility, reduced motion, and Axe
accessibility checks.

Preview a production build manually with:

```sh
npm --prefix ui/web run build
npm --prefix ui/web run preview
```

Live Tokamak acceptance is intentionally absent from every default command. Supply
the key only to the credential-owning live runner:

```sh
SYNAPSE_LIVE=1 TOKAMAK_API_KEY="..." SYNAPSE_MODEL="..." \
  npm --prefix ui/web run test:e2e:live
```

The owner strips the key and model before spawning Vite, Playwright, and Chromium,
passes them only to `mix synapse.server`, scans captured output and artifacts for
the exact key, and deletes live artifacts after the run.

## Architecture Boundary

- Plain Svelte 5 and strict TypeScript are used without SvelteKit, SSR, routing,
  server data loading, or a backend-for-frontend.
- Shared reactive controllers use Svelte 5 runes in `.svelte.ts` files.
- The browser uses `server.hello`, not cross-origin `GET /health`, as its
  readiness signal.
- The exact hello includes the bounded directory from which `mix synapse.server`
  started. The UI uses it as the editable, memory-only initial Workspace path.
- The browser calls `new WebSocket(url)` without a protocols argument.
- Only `ws://127.0.0.1:<port>/v1/socket` and
  `ws://localhost:<port>/v1/socket` are accepted client targets.
- Browser cursors must be safe non-negative JavaScript integers. Protocol values
  above `Number.MAX_SAFE_INTEGER` fail closed even though the API accepts the
  larger signed-64-bit range.
- Disconnect, page unload, component cleanup, and reconnect never imply
  `run.cancel`.
- Loopback and local Origin checks are not authentication. `process.exec` runs as
  the same operating-system user and is not sandboxed.
- Model and server content is rendered as escaped plain text, never `{@html}`.

The authoritative implementation checklist is
[`docs/plan/PLAN-UI.md`](../../docs/plan/PLAN-UI.md). The wire and trust contracts
are documented in [`PLAN-API.md`](../../docs/plan/PLAN-API.md) and
[`API.md`](../../docs/learning/API.md). Maintainer architecture, end-to-end traces,
recovery, security, and troubleshooting are in
[`UI.md`](../../docs/learning/UI.md).

## Protocol Layer

Phase 2 implements a framework-free protocol boundary in `src/lib/protocol`:

- `types.ts` is the closed compile-time command, server-message, event, projection,
  result, and terminal union. These types are developer guidance, not evidence that
  parsed input is safe.
- `encode.ts` exposes one encoder for each of the four protocol-v1 commands. Each
  encoder constructs a fresh allowlisted object, omits blank optional values,
  validates UTF-8 byte limits, and never spreads form state onto the wire.
- `decode.ts` bounds a complete text message before parsing, rejects duplicate keys
  and malformed Unicode, preserves JSON number token shape, validates exact nested
  keys and cross-field rules, and returns only freshly constructed typed values.
- `validation.ts` owns shared UTF-8, identifier, canonical run-ID, and exact-object
  checks. `constants.ts` records protocol maxima and fixed wire enums/prose.

JavaScript cannot represent the API's complete signed-64-bit cursor range exactly.
The browser decoder therefore accepts only integer tokens through
`Number.MAX_SAFE_INTEGER` and fails closed above that value. It also rejects decimal
and exponent spellings such as `1.0` or `1e0` for integer fields, because ordinary
`JSON.parse` would erase that distinction. Trusted server configuration may lower
message, input, model, or Budget policy below these browser maxima. Hello advertises
the effective `max_output_bytes` ceiling; all other lower server policy and every
server rejection remain authoritative.

## Connection Layer

Phase 3 implements transport ownership in `src/lib/client/connection.svelte.ts` and
bounded direct-response correlation in `pending.ts`.

- The Svelte-rune controller owns exactly one current socket generation. Replaced
  listeners and queued callbacks are ignored by generation, and every timer and
  pending correlation is cleared when that generation ends.
- `open` enters `awaiting_hello`; only an exact decoded `server.hello` enters
  `ready`. A socket has ten seconds to open and send hello before bounded reconnect
  begins.
- On first readiness, the launch `cwd` fills an empty Workspace field. Later hello
  values update a still-automatic field, preserve a manual override, and refill a
  manually cleared field only on the next ready socket generation.
- Each hello also advertises `max_output_bytes` in `1..524288`. The UI replaces the
  lowering-only displayed maximum per ready generation, preserves an entered draft
  across reconnect, and never stores or silently clamps either value.
- Commands use fresh `crypto.randomUUID()` IDs and at most 32 pending entries. An
  eight-second warning marks a command delayed without dropping correlation. A
  late matching response remains valid.
- Cancel and subscribe responses must match both request ID and requested run ID.
  A lost or delayed start remains ambiguous and is never resent automatically.
- While visible and ready, one application `ping` is sent every 25 seconds. Only a
  matching `pong` settles it. Keepalive and reconnect timers pause while hidden;
  visibility return resumes one existing or scheduled attempt without duplication.
- Ordinary network, going-away, restart, and retry-later closes use delays of 250
  ms, 500 ms, 1 second, 2 seconds, then 5 seconds through ten attempts. Validated
  hello resets the outage count. Protocol, policy, size, UTF-8, internal, and normal
  closes require explicit reconnect.
- Local protocol faults use private close code 4000. Close reasons and browser
  exceptions never enter ordinary notices.
- Manual disconnect, replacement, page hide, BFCache transitions, and component
  cleanup only close transport. None sends `run.cancel`.
- The browser factory guards `sessionStorage`, retains only a validated API URL and
  server-issued current run ID, and owns visibility, `pagehide`, `pageshow`, and
  destruction listeners. Persisted BFCache pages disconnect and resume without
  destroying the controllers.

## Run State And Replay

Phase 4 implements authoritative run observation in `run.svelte.ts`, pure
projection in `run-reducer.ts`, view-only contracts in `run-types.ts`, and sanitized
diagnostics in `protocol-timeline.svelte.ts`.

- A run ID is installed only from correlated `run.accepted`, starts at cursor zero,
  and is the only run value retained in `sessionStorage`. Prompt, path, model,
  output, events, terminal, cursor, and diagnostics remain memory-only.
- The exact sent Start command, exact successfully applied Run events, and terminal
  are retained in bounded memory for chat projection. A settled run moves into a
  64-run session archive only when the next message is sent.
- One pure reducer handles initial live delivery, retained replay, and resumed live
  delivery. It applies only the exact next sequence and validates turn, Tool,
  owner-loss cleanup, UTF-8 text, and safe aggregate transitions before one atomic
  state replacement.
- Nonterminal status precedence matches the API: owner loss remains above
  cancellation, and cancellation remains above ordinary progress. A successful
  terminal replaces text and aggregate counters from Result; failed and interrupted
  terminals preserve committed progress.
- Reconnect with an in-memory projection subscribes from the applied cursor. Reload
  restoration has only a run ID and therefore subscribes without a cursor. Replay
  never applies before its direct acknowledgement, and baseline catch-up is bounded
  by a ten-second watchdog.
- Duplicate, reversed, skipped, contradictory, or stalled delivery keeps the last
  validated view and requests a no-cursor authoritative snapshot. Snapshot mode
  replaces projection, terminal, cursor, and event-derived activity together.
  `reset: true` reports lost history without inventing run failure.
- Successful completed snapshots use `projection.text: ""` and carry final text once
  in `terminal.result.text`; the reducer reconstructs the displayed projection.
  Snapshots remain one bounded message in v1. Multi-megabyte output requires a
  future chunked snapshot protocol and bounded reassembly.
- A lost cancellation response also requires snapshot recovery because cancellation
  does not consume sequence. A correlated `run_not_found` explains process-lifetime
  loss, removes stale restoration, and never synthesizes a terminal or resends start.
- Exact chat events are bounded to 8,192 entries and eight encoded MiB per run;
  oldest trace entries are evicted without changing projection or cursor. Activity
  and sanitized protocol summaries remain independently bounded to 500 entries and
  one encoded MiB. Raw frame strings and unvalidated browser exceptions are never
  retained.

## Interactive Controls

Phase 5 exposes the composed client in `App.svelte` and keeps validation and error
mapping outside presentation in `composer.ts` and `server-errors.svelte.ts`.

- Connect accepts only the explicit local protocol-v1 URL forms and displays hello
  protocol and replay mode before enabling Start. Disconnect never sends Cancel;
  Reconnect restores an accepted run from its applied cursor.
- Prompt and absolute Workspace path are required. Hello prefills the path from the
  server launch directory, and the operator may edit it before Start. Model is
  optional and omitted when blank. The collapsed Budget contains all seven optional
  protocol fields and accepts only safe whole numbers in browser maxima; configured
  server policy remains authoritative.
- Draft values are memory-only. Pre-admission errors preserve every field. After
  correlated acceptance, Prompt is cleared while Workspace path, Model, and Budget
  remain in memory. Submitted fields are locked while admission is pending so a late
  response cannot erase replacement text.
- Start is blocked by an active or restored run and is never automatically retried
  after ambiguity. A settled run permits a follow-up without clearing the visible
  session. Accepted cancellation is idempotent in both action and UI state;
  command send, intent acknowledgement, and terminal settlement are displayed as
  separate states.
- A follow-up archives the settled run, starts an independent Runtime run, and sends
  newest complete successful user/assistant pairs in optional `conversation`.
  History is bounded to 128 messages and 1,572,864 UTF-8 content bytes. Failed and
  interrupted runs remain visible but are not projected into model history.
- Every stable `server.error`, including `token_limit_exceeded`, maps to fixed local
  guidance. Its validated envelope is available only through the explicit bubble
  trace disclosure; browser exceptions and raw frames remain excluded.

`App.svelte` mounts the composed controllers to establish lifecycle ownership, but
the initial page remains disconnected until the user activates Connect.

## Run Presentation

The chat timeline renders validated commands, events, and terminals through focused components under
`src/lib/components`.

- Assistant text uses escaped, whitespace-preserving plain text. Contiguous deltas
  share one node and Tool boundaries create chronological answer segments. No
  Markdown, syntax highlighting, `{@html}`, or hidden reasoning is used.
- Provider, Tool call, Tool Result, answer, settlement, and error bubbles remain in
  source order. The status buffer distinguishes Provider activity, Tool execution,
  completion, failure, interruption, cancellation, and owner loss.
- Tool bubbles expose the exact decoded arguments and exact model-visible Result
  content supplied by protocol v1. They do not infer filesystem changes or success
  beyond validated wire fields.
- Terminal bubbles distinguish successful Result, Agent, Runtime, and API settlement.
  `runtime_lost` explicitly states that final cleanup settlement was not observed;
  other terminals state confirmed settlement. One concise status or alert announces
  terminal arrival without reading the complete Result or stealing focus.
- Every bubble has an accessible API trace disclosure containing its exact retained
  validated command, event, or terminal JSON. This intentionally includes prompts,
  Workspace paths, assistant text, Tool data, and stable error details, but excludes
  credentials, authority objects, raw frames, and opaque browser internals.
- The separate protocol inspector presents sanitized envelopes in source order with direction,
  command-response/asynchronous role, and replay/snapshot/reset markers. Prompt,
  advertised or submitted Workspace path, assistant and Result text, error-detail
  values, and raw frames are replaced by bounded summaries before display or
  explicit copy.
- Run ID and diagnostics clipboard writes require explicit actions. Clearing the
  memory-only session returns keyboard focus to the retained Workspace field.

## Deterministic Browser Acceptance

Phase 7 runs the built client against `tests/fixtures/scripted-websocket-server.ts`,
not an in-page WebSocket replacement.

- Every test receives an isolated `ws` server bound to `127.0.0.1` on port zero.
  The upgrade accepts exactly one expected local Origin and the `/v1/socket` path.
- Tests explicitly release exact `server.hello`, capture browser-generated UUIDs,
  and compare each complete command string against canonical protocol-v1 JSON. Extra
  fields, alternate ordering, authority, and credential fields fail the test.
- Bounded FIFO barriers retain early connections and commands without polling or
  sleeps. Reconnect delays use Playwright virtual time. Socket, queue, listener, and
  server cleanup is test-scoped and runs after failures.
- The defining scenario covers starting, every event class except owner loss,
  successful terminal settlement, counters, escaped output, Tool activity, ordered
  diagnostics, 500-entry eviction, responsive containment, landmarks, focus, live
  regions, and Axe. The cancellation scenario supplies the owner-loss event.
- Recovery scenarios prove disconnect sends no cancellation, subscribe carries the
  exact applied cursor, acknowledged replay joins live delivery without duplication,
  stale history installs reset state before later live delivery, and reload restores
  one completed snapshot without duplicating terminal UI.
- Error scenarios exercise every stable `server.error`, malformed-frame fail-closed
  behavior, policy and internal stop-only closes, and cancellation acknowledgement
  before one interrupted terminal. Raw server text is not rendered.
- All scripted acceptance scenarios run in desktop and mobile Chromium without Elixir,
  Tokamak, Provider credentials, API keys, or a user workspace checkout. No streamed
  delta screenshots are captured; only stable completed and cancelled states are
  saved as per-test Playwright artifacts.

## Real Synapse And Hardening

Phase 8 adds an external Elixir fixture without changing the protocol-only frontend.

- `synapse_server.exs` starts the real Router, Socket, RunManager, RunSession,
  Runtime, Agent, Tool, and API boundaries on port zero. A scripted Provider and
  controlled Fake Workspace gate read, write, Bash, and final-text progress over
  bounded stdin commands; stdout contains one bounded READY URL.
- The process owner uses an allowlisted environment, an isolated temporary HOME and
  workspace, bounded diagnostics, monitored clean exit, and TERM/KILL process-group
  fallbacks. Provider turns, Workspace operations, and closure are independently
  persisted as bounded evidence before teardown.
- Playwright proves real Host/Origin handling, active-run socket loss and replay,
  visible streamed text before terminal, thirteen source-ordered frames, three Tool
  calls, terminal cleanup, no cancellation, no API HTTP requests or Vite proxy, and
  an actual API-tree restart returning `run_not_found`.
- Reliability gates include fixed-seed decoder fuzzing, exact frame and identifier
  limits, rapid correlated callbacks, hidden-tab recovery, reload restoration,
  throwing storage, and repeated active mount/unmount resource accounting.
- Security gates enumerate browser storage, exercise malicious model/Tool/error/text
  values as inert text, and scan frontend source plus production assets for secret
  environment access, credential fields, fixture authority, callbacks, `/health`,
  and proxy configuration.
- The maximum-output browser run streams 128 deltas to 524,288 bytes, measures input
  latency and layout shift during accumulation, verifies one output text node,
  bounded diagnostics, and post-terminal render quiescence.

## Troubleshooting

- If Connect never becomes ready, confirm the API process and direct loopback URL;
  readiness is `server.hello`, not `/health`.
- If Origin is rejected, use <http://127.0.0.1:5173> and the configured direct
  WebSocket URL. Do not add a Vite proxy.
- If Start becomes delayed or the socket drops before `run.accepted`, do not resend.
  The run may exist without a browser-known ID; inspect server logs and workspace
  effects before restarting the API.
- `run_not_found` means RunManager/application restart or completed-run eviction;
  protocol v1 cannot restore that run.
- A replay reset means retained events were evicted. The replacement snapshot is
  current process-memory state, not durable history.
- Default Playwright failures retain stable-state artifacts under
  `ui/web/test-results`. Live artifacts are scanned and deleted deliberately.

See [`UI.md`](../../docs/learning/UI.md) for the full failure table and safe
maintenance workflow.

## Selected Toolchain

The Phase 0 selection was resolved from npm metadata on 2026-08-07 and is pinned
exactly in `package.json` and `package-lock.json`.

| Tool                       | Version |
| -------------------------- | ------: |
| Svelte                     |  5.56.8 |
| Vite                       |   8.2.1 |
| Svelte Vite plugin         |   7.2.0 |
| TypeScript                 |   6.0.3 |
| svelte-check               |   4.7.4 |
| Vitest                     |  4.1.10 |
| Testing Library for Svelte |   5.4.2 |
| jsdom                      |  29.1.1 |
| Playwright                 |  1.62.1 |
| Axe Playwright integration |  4.12.1 |
| ws (test only)             |  8.21.2 |
| ESLint                     |  10.8.0 |
| Prettier                   |   3.9.6 |
