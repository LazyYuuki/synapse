# Basic Web UI Implementation Checklist

## Purpose

This document is the implementation checklist for the first interactive Synapse
client described in [`PLAN.md`](PLAN.md).

It turns the completed local WebSocket protocol in
[`PLAN-API.md`](PLAN-API.md) and the browser-facing trust guidance in
[`../learning/API.md`](../learning/API.md) into a small Svelte 5 application under
`ui/web`.

The checklist is intentionally limited to one standalone web client plus the
pre-release protocol-v1 hello extension that advertises the server launch `cwd`.
It does not change Provider, Workspace, Tool, Agent, or Runtime behavior; serve
frontend assets from the Elixir application; add a backend-for-frontend; add
durable run storage; or define future TUI and desktop clients.

## Web UI Outcome

The UI is complete when a local user can start the existing Synapse server, open a
browser application, submit one prompt and workspace path, watch ordered text and
Tool activity, disconnect and reconnect without cancelling the run, request
cancellation explicitly, and inspect one structured terminal result.

The defining interactive flow is:

```text
Terminal 1
TOKAMAK_API_KEY="..." SYNAPSE_MODEL="..." mix synapse.server

Terminal 2
npm --prefix ui/web ci
npm --prefix ui/web run dev

Browser
http://127.0.0.1:5173
  -> ws://127.0.0.1:4848/v1/socket
  -> server.hello
  -> run.start(prompt, cwd, optional model and Budget lowering)
  -> run.accepted
  -> ordered run.event messages
  -> optional run.cancel
  -> run.terminal or authoritative completed snapshot
```

The UI is a protocol client only. It must never import Synapse Elixir modules,
reconstruct trusted Runtime options, or receive the Tokamak API key.

## Checklist Rules

- Check an item only after implementation, focused tests, documentation, and the
  relevant browser proof are complete.
- Keep all application source, package metadata, tests, and generated frontend
  configuration under `ui/web`.
- Use Svelte 5 runes and TypeScript. Do not introduce compatibility code for
  Svelte 4 component patterns.
- Keep the client a static Vite SPA. Do not add SvelteKit, SSR, server routes, a
  proxy, or a Node production server without a demonstrated need.
- Connect from the browser directly to the loopback WebSocket API. Synapse must not
  serve or bundle the UI.
- Treat protocol TypeScript types as compile-time help only. Validate every parsed
  server message at runtime before changing UI state.
- Never send credentials, capability flags, Provider selection, callbacks, handles,
  Runtime options, or arbitrary JSON through the UI.
- Never interpret disconnect, page unload, or component destruction as run
  cancellation.
- Apply replay strictly by sequence and replace state completely on an
  authoritative snapshot or reset.
- Keep deterministic tests independent of Tokamak credentials and the user's
  checkout.
- Keep browser-retained protocol state bounded and avoid persisting prompt, path,
  assistant text, Tool activity, or terminal details by default.
- If protocol v1 changes, update `PLAN-API.md`, this plan, fixtures, runtime
  validators, reducers, and browser acceptance together.

## Progress Summary

| Phase | Deliverable                                                            | Status      |
| ----- | ---------------------------------------------------------------------- | ----------- |
| 0     | Confirm Svelte, browser, protocol, trust, and test decisions           | In progress |
| 1     | Scaffold the standalone Svelte 5 application and quality gates         | Complete    |
| 2     | Implement exact protocol types, command encoding, and message decoding | Complete    |
| 3     | Implement bounded WebSocket connection and keepalive lifecycle         | Complete    |
| 4     | Implement run projection, sequencing, replay, reset, and restoration   | Complete    |
| 5     | Implement start, cancel, reconnect, and new-run controls               | Complete    |
| 6     | Implement streamed output, Tool activity, terminal, and protocol views | Complete    |
| 7     | Add deterministic unit and scripted-browser acceptance                 | Complete    |
| 8     | Add real Synapse API integration and reliability/security hardening    | Complete    |
| 9     | Complete opt-in live interactive Tokamak acceptance                    | In progress |
| 10    | Complete documentation and maintainer comprehension review             | In progress |

Update this table only when a phase passes its completion gate.

## Architectural Position

```text
ui/web                                      Elixir application

+----------------------+                    +----------------------+
| Svelte 5 SPA         |                    | Synapse.API.Router   |
| browser state only   |                    | /v1/socket           |
+----------+-----------+                    +----------+-----------+
           | direct browser WebSocket                  |
           +------------------------------------------>|
                                                       v
                                            +----------------------+
                                            | API RunManager       |
                                            | process-lifetime     |
                                            | projection/replay    |
                                            +----------+-----------+
                                                       |
                                                       v
                                            Runtime -> Agent/Tools
```

The web app is replaceable. A future TUI or desktop client must be able to use the
same protocol without importing or sharing Svelte code.

## Dependency Direction

```text
Svelte components
  -> UI controllers and derived view state
  -> protocol reducer
  -> validated protocol message union

WebSocket client
  -> command encoder
  -> runtime message decoder
  -> browser WebSocket
  -> Synapse local API

Synapse API
  -X-> ui/web source
  -X-> Svelte, Vite, npm, browser state, or DOM concepts
```

The UI may depend on the public protocol documentation and fixtures. The backend
must never depend on frontend source, package output, or client state.

## Fixed Product Scope

### UI Owns

- One browser WebSocket connection and its connection state.
- One bounded set of pending command correlations.
- One current server-issued run ID.
- The last sequence actually applied to the visible run.
- One local run projection derived from validated events or replaced by a snapshot.
- One bounded diagnostic protocol timeline for local debugging.
- Form state for API URL, prompt, absolute workspace path, optional model, and
  optional Budget lowering.
- Explicit start, cancel, reconnect, disconnect, clear, and new-run actions.
- Browser-only presentation, accessibility, responsive layout, and focus behavior.

### UI Does Not Own

- Run IDs before `run.accepted`.
- Tool capabilities or host authorization.
- Provider modules, credentials, instructions, callbacks, or Runtime options.
- Workspace path authorization, canonicalization, revisions, or process cleanup.
- Agent conversation, Tool order, retry policy, terminal classification, or run
  settlement.
- Durable event history, application-restart recovery, or multi-run coordination.
- A shell terminal, file browser, editor, diff application, approval queue, or
  interactive stdin.
- Serving itself from Bandit or modifying the API router to expose static assets.

## Technology Decisions

| Decision           | MVP choice                                | Reason                                                                    |
| ------------------ | ----------------------------------------- | ------------------------------------------------------------------------- |
| Framework          | Svelte 5                                  | Requested UI framework; runes give explicit local reactive state          |
| Language           | TypeScript in strict mode                 | Keeps protocol unions and component contracts visible to LSP              |
| Build tool         | Vite with `@sveltejs/vite-plugin-svelte`  | Small static SPA with fast local development                              |
| Application model  | Client-only SPA                           | No routing, SSR, server data loading, or backend-for-frontend is required |
| Package manager    | npm with committed `package-lock.json`    | Ubiquitous local workflow and reproducible dependency resolution          |
| Styling            | Component CSS plus one global token sheet | Avoids a UI kit and keeps the first client inspectable                    |
| Unit tests         | Vitest plus Testing Library               | Fast protocol, reducer, controller, and component verification            |
| Browser tests      | Playwright Chromium                       | Real browser WebSocket, Origin, focus, responsive, and reconnect behavior |
| Scripted transport | Test-only local WebSocket server          | Deterministic browser acceptance without Tokamak or Elixir internals      |
| Real integration   | Test-only external Synapse fixture        | Proves browser-to-real-API compatibility without a production test seam   |

Phase 0 must record the exact Node, npm, Svelte, Vite, TypeScript, Vitest,
Testing Library, Playwright, ESLint, and Prettier versions selected at implementation
time. Use the current supported Node LTS release and commit the lockfile. Do not
copy version guesses from this planning document.

### Phase 0 Selection Record

Phase 0 was confirmed on 2026-08-07 with installed Node 24.14.0 and npm 11.9.0.
Node 24 is the selected LTS line, and `package.json` constrains development to Node
24 and npm 11. npm metadata and peer constraints selected these exact locked
versions:

| Package                        | Selected version |
| ------------------------------ | ---------------: |
| Svelte                         |           5.56.8 |
| Vite                           |            8.2.1 |
| `@sveltejs/vite-plugin-svelte` |            7.2.0 |
| TypeScript                     |            6.0.3 |
| `svelte-check`                 |            4.7.4 |
| Vitest                         |           4.1.10 |
| Testing Library for Svelte     |            5.4.2 |
| jsdom                          |           29.1.1 |
| Playwright                     |           1.62.1 |
| `ws` (test only)               |           8.21.2 |
| ESLint                         |           10.8.0 |
| Prettier                       |            3.9.6 |

The selected architecture remains plain Svelte 5 with Vite, one client-only screen,
direct browser WebSocket transport, runtime protocol validation, and no backend
frontend dependency. Unit tests use jsdom and an injected WebSocket boundary;
browser tests use Chromium with test-only loopback WebSocket and real Fake-backed
API fixtures. Live Tokamak scenarios remain explicit opt-in. The browser
safe-integer restriction, local-host trust, same-user execution, direct Origin
boundary, plain-text rendering, and disconnect-without-cancellation rules are
recorded in `ui/web/README.md`.

## Browser And API Boundary

The browser connects directly to:

```text
ws://127.0.0.1:4848/v1/socket
```

The connection URL control may accept only:

- Scheme `ws`.
- Host `127.0.0.1` or `localhost`.
- Explicit port from 1 through 65,535.
- Exact path `/v1/socket`.
- No username, password, query, or fragment.

Do not expose `wss`, arbitrary hosts, remote bind, subprotocols, cookies,
authorization headers, or credential fields as configurable MVP options. The
server supports no such contract.

The Vite application should run on `http://127.0.0.1:5173` by default. Its browser
Origin is accepted by the API's strict local Origin policy. Do not add a Vite
WebSocket proxy: direct connection is the product boundary being tested, and a
proxy can hide Host/Origin errors or create a second security surface.

The browser must not use `GET /health` as its readiness mechanism. That endpoint is
not a cross-origin browser API and supplies no CORS contract. A validated
`server.hello` received as the first WebSocket frame is the UI readiness signal.
Its exact payload includes protocol `1`, replay `memory`, one active run, and the
bounded absolute directory in which `mix synapse.server` started. The UI uses that
`cwd` as an editable, memory-only Workspace default and redacts it from diagnostics.

## Protocol V1 Client Contract

### Client Envelope

Every command encoder constructs exactly:

```ts
type ClientEnvelope<TType extends string, TPayload> = {
  version: 1;
  type: TType;
  request_id: string;
  payload: TPayload;
};
```

The fixed commands are:

```ts
type StartCommand = ClientEnvelope<
  "run.start",
  {
    prompt: string;
    cwd: string;
    model?: string;
    budget?: Partial<Budget>;
  }
>;

type CancelCommand = ClientEnvelope<"run.cancel", { run_id: string }>;

type SubscribeCommand = ClientEnvelope<
  "run.subscribe",
  { run_id: string; after_seq?: number }
>;

type PingCommand = ClientEnvelope<"ping", Record<string, never>>;
```

`request_id` should use `crypto.randomUUID()`. It is command correlation, not a
run ID or authority token. Keep at most 32 pending correlations and remove each
entry on its direct response or when that socket generation ends. A local response
timeout may mark a command delayed, but it must retain correlation for a late direct
response and must not make an ambiguously admitted `run.start` safe to resend.

The encoder must construct fresh objects from allowlisted form fields. Do not send
`undefined` values, arbitrary form objects, spread unknown properties, or use a
generic command function that permits unsupported `type` strings.

### Server Envelope

Runtime decoding must produce a closed discriminated union for:

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

Every decoder branch must verify:

- Parsed value is a plain object.
- Exact envelope keys are `version`, `type`, `request_id`, and `payload`.
- Version is integer `1`.
- Type is one supported literal.
- Request correlation is string or `null` as required by that message.
- Payload has its exact required and optional keys.
- Strings, counters, statuses, arrays, and nested objects have the documented
  runtime shape.
- Sequence and cursor values are safe non-negative JavaScript integers.
- No extra object keys are accepted silently.

The exact `server.hello` payload is
`{ protocol: 1, replay: "memory", max_active_runs: 1, cwd: string, max_output_bytes: number }`. `cwd` must
pass the same 4,096-byte absolute-path validation as the start composer. First
readiness fills an empty Workspace field. Reconnect updates an automatic value,
preserves a manual override, and restores a cleared field only on the next ready
generation. `max_output_bytes` must be an integer in `1..524288`; each ready
generation replaces the displayed lowering ceiling without clamping or rewriting
the operator's memory-only Budget draft.

Do not use `JSON.parse(data) as ServerMessage`, generated `any`, or a compile-time
type assertion as runtime validation. A malformed server frame is a protocol fault:
record a bounded local diagnostic, close the socket, and require reconnect or an
authoritative snapshot rather than partially applying it.

### Client Resource Bounds

Use explicit client ceilings even though the server is bounded:

| Resource                         |                                         Client ceiling | Behavior at limit                     |
| -------------------------------- | -----------------------------------------------------: | ------------------------------------- |
| One complete server text message |                                3,276,800 encoded bytes | reject and close as protocol fault    |
| One client command               |                                2,097,152 encoded bytes | reject locally before send            |
| Prompt                           |                                    262,144 UTF-8 bytes | reject locally                        |
| Workspace path                   |                                      4,096 UTF-8 bytes | reject locally                        |
| Model                            |                                        256 UTF-8 bytes | reject locally                        |
| Request ID                       |                                        128 UTF-8 bytes | generated values remain below limit   |
| Canonical run ID                 |                                 exactly 26 ASCII bytes | reject locally                        |
| Decoded JSON                     | depth 16, 32 keys/object, 128 array items, 4,096 nodes | reject and close as protocol fault    |
| Pending correlations             |                                                     32 | disable new command until one settles |
| Protocol timeline entries        |                                                    500 | discard oldest entries                |
| Protocol timeline encoded bytes  |                                              1,048,576 | discard oldest entries                |
| Reconnect attempts               |                                          10 per outage | stop and expose manual reconnect      |

Measure UTF-8 and encoded JSON through `TextEncoder`, not JavaScript string length.
The protocol timeline stores validated/sanitized messages, not browser exceptions,
raw binary, credentials, or unlimited source frames.

## Connection Lifecycle

The controller state is explicit:

```text
idle
  -> connecting
  -> awaiting_hello
  -> ready
  -> reconnecting
  -> ready

any non-terminal state
  -> protocol_fault | unavailable | manually_disconnected
```

Rules:

- Only one current WebSocket generation may update state.
- `open` is not readiness; the first validated message must be `server.hello`.
- Validate hello payload as protocol `1`, replay `memory`, and maximum active runs
  `1` before enabling start.
- Start an application `ping` every 25 seconds while ready. Browsers cannot send
  RFC control ping frames directly.
- Correlate every `pong`; do not use arbitrary echo payloads.
- Clear timers, listeners, and pending command timeouts when replacing a socket.
- Ignore late callbacks from an older socket generation.
- Never send `run.cancel` from `beforeunload`, component cleanup, socket close, or
  reconnect code.
- Treat close 1008, 1009, and 1011 as visible protocol/policy failures rather than
  an infinite reconnect loop.
- Retry ordinary listener/network loss with bounded delays of 250 ms, 500 ms,
  1 s, 2 s, then 5 s, capped at ten attempts.
- Browser timer throttling may let the server inactivity timeout close a hidden tab;
  reconnect and subscribe instead of treating that as run failure.

## Run Projection And Sequence Rules

The UI keeps one current run:

```ts
type RunView = {
  runId: string;
  status:
    | "starting"
    | "running"
    | "cancel_requested"
    | "owner_lost"
    | "completed"
    | "failed"
    | "interrupted";
  model: string | null;
  turn: number;
  text: string;
  activeTool: ActiveTool | null;
  providerAttempts: number;
  toolCalls: number;
  outputBytes: number;
  lastAppliedSeq: number;
  terminal: Terminal | null;
};
```

Live events apply only when `seq == lastAppliedSeq + 1`:

- `run.started` sets model and running status unless cancellation is pending.
- `turn.started` updates the current turn.
- `text.delta` appends exact text.
- `tool.started` sets one active Tool summary.
- Matching `tool.completed` clears active Tool and records one bounded timeline item.
- `turn.completed` updates authoritative aggregate counters and clears stale active
  operation state.
- `run.owner_lost` sets owner-lost status and clears active Tool state.
- `run.terminal` applies one terminal status/result/error and clears active Tool.

A duplicate, reversed, or skipped sequence must not be guessed through. Pause live
application and request an authoritative snapshot without `after_seq`. If that
recovery fails, expose a protocol fault and keep the last validated view visible.

### Reconnect With In-Memory State

After a new hello, if the mounted app still has a run projection:

```text
run.subscribe(run_id, after_seq = lastAppliedSeq)
  -> replay acknowledgement
  -> exact contiguous retained messages
  -> live messages
```

A replay acknowledgement has no projection or terminal and does not advance the
cursor by itself.

### Authoritative Snapshot And Reset

For `mode: snapshot`:

- Replace the complete local projection.
- Replace terminal with the snapshot terminal, including `null`.
- Set `lastAppliedSeq` directly to `last_seq`.
- Clear stale event-derived Tool and counter state.
- Do not expect a duplicate terminal after a completed snapshot.
- Show a small reset indicator when `reset: true`; do not claim omitted event
  history was recovered.

For `mode: replay`, retain current projection and cursor while waiting for replay.

### Page Reload Restoration

The app may keep only these values in `sessionStorage`:

```text
validated API WebSocket URL
current server-issued run ID
```

Do not persist `lastAppliedSeq` without its projection, and do not persist prompt,
workspace path, model output, Tool activity, raw frames, terminal details, or
credentials. After a page reload, reconnect and subscribe without `after_seq` to
obtain an authoritative snapshot. Clear stale restoration state on `run_not_found`
or explicit user action.

The run ID is not authentication. Session storage is only a same-tab usability aid.

## Screen Structure

The first screen is an operator console, not a chat clone:

```text
+------------------------------------------------------------------+
| SYNAPSE  Local API                       Ready  ws://127...  [..] |
+--------------------------+---------------------------------------+
| Run Setup                | Current Run                           |
| workspace path           | status / model / turn / sequence     |
| optional model           |                                       |
| prompt                   | streamed assistant text               |
| advanced Budget          |                                       |
| [Start Run] [Cancel]     | active Tool card / terminal card      |
+--------------------------+---------------------------------------+
| Activity timeline                                  [Protocol >]  |
+------------------------------------------------------------------+
```

At narrow widths, Run Setup becomes the first stacked panel, followed by Current
Run and Activity. The primary action remains reachable without horizontal scroll.

### Visual Language

- Use a restrained local-operator aesthetic with warm neutral surfaces, one strong
  signal color, and status colors that also include text/icon labels.
- Use a readable sans-serif for controls and a monospace face for run IDs,
  sequences, Tool names, and protocol data.
- Preserve assistant whitespace with `white-space: pre-wrap`; render plain text.
- Do not render model or server content with `{@html}`.
- Keep the protocol inspector collapsed by default and visually distinct from the
  user-facing run output.
- Avoid decorative dashboards, fake metrics, gradients, excessive cards, and
  animation that obscures lifecycle state.
- Respect `prefers-reduced-motion` and do not animate streamed text character by
  character.

### Components

Target components are:

```text
App.svelte
|-- ConnectionBar.svelte
|-- LocalTrustNotice.svelte
|-- RunComposer.svelte
|   |-- WorkspaceField.svelte
|   `-- BudgetFields.svelte
|-- RunHeader.svelte
|-- AssistantOutput.svelte
|-- ActiveTool.svelte
|-- ActivityTimeline.svelte
|-- TerminalResult.svelte
|-- ProtocolInspector.svelte
`-- StatusNotice.svelte
```

Split a component only when it owns a meaningful interaction, accessibility
contract, or reusable presentation. Do not create one component per text label.

### Accessibility

- Every field has a visible label and associated description/error.
- Connection and run status use an `aria-live="polite"` region without announcing
  every text delta.
- Terminal failures use an assertive announcement once.
- Start and cancel have clear disabled reasons.
- Focus moves to the run heading after acceptance and to the terminal heading on
  settlement, unless the user is typing elsewhere.
- Tool and protocol timelines use semantic lists.
- Keyboard operation reaches every control and disclosure.
- Color is never the sole status indicator.
- Desktop and mobile layouts pass automated accessibility checks and manual
  keyboard review.

## Target Source Layout

```text
ui/
  web/
    README.md
    package.json
    package-lock.json
    tsconfig.json
    vite.config.ts
    vitest.config.ts
    playwright.config.ts
    eslint.config.js
    .prettierrc
    .gitignore
    index.html

    src/
      app.css
      main.ts
      App.svelte

      lib/
        protocol/
          constants.ts
          types.ts
          encode.ts
          decode.ts
          reducer.ts
          projection.ts
        client/
          connection.svelte.ts
          run.svelte.ts
          pending.ts
          restore.ts
        format/
          errors.ts
          events.ts

        components/
          ConnectionBar.svelte
          LocalTrustNotice.svelte
          RunComposer.svelte
          WorkspaceField.svelte
          BudgetFields.svelte
          RunHeader.svelte
          AssistantOutput.svelte
          ActiveTool.svelte
          ActivityTimeline.svelte
          TerminalResult.svelte
          ProtocolInspector.svelte
          StatusNotice.svelte

    tests/
      fixtures/
        messages.ts
        synapse_server.exs
      support/
        scripted-server.ts
      unit/
        encode.test.ts
        decode.test.ts
        reducer.test.ts
        connection.test.ts
        restore.test.ts
      component/
        composer.test.ts
        run-view.test.ts
        terminal.test.ts
      e2e/
        scripted.spec.ts
        synapse-api.spec.ts
        live-tokamak.spec.ts
```

This layout is a target, not an instruction to create empty files. Keep related
logic together until a split has a tested ownership benefit.

## Phase 0: Confirm Prerequisites And Decisions

### Toolchain

- [x] Confirm the current supported Node LTS and npm versions.
- [x] Confirm the latest compatible Svelte 5, Vite, TypeScript, and plugin versions.
- [x] Confirm Vitest, Testing Library, Playwright, ESLint, and Prettier versions.
- [ ] Record exact versions and commit `package-lock.json` after scaffolding.
- [x] Confirm `npm --prefix ui/web ...` works without changing the Mix project.

### Architecture

- [x] Confirm plain Svelte 5 plus Vite is sufficient; do not add SvelteKit.
- [x] Confirm the app is a static client-only SPA with one screen and no router.
- [x] Confirm all frontend files live under `ui/web`.
- [x] Confirm Synapse continues serving no frontend assets.
- [x] Confirm direct browser WebSocket connection needs no Vite proxy.
- [x] Confirm `server.hello`, not cross-origin `/health`, is browser readiness.
- [x] Confirm the UI imports no Elixir source or generated internal API module.

### Protocol

- [x] Confirm all four commands and eight server message types against protocol v1.
- [x] Confirm exact snapshot, replay, reset, terminal, error, and close semantics.
- [x] Confirm browser-origin `http://127.0.0.1:<port>` passes API Origin policy.
- [x] Confirm browser WebSocket messages arrive as text strings for server frames.
- [x] Confirm JavaScript safe integers cover the API's signed-64-bit cursor range
      only up to `Number.MAX_SAFE_INTEGER`; fail closed above it rather than rounding.
- [x] Record this browser numeric limitation explicitly in UI documentation.

### Trust And Security

- [x] Confirm the UI is for a cooperative trusted-local-host environment only.
- [x] Confirm the UI offers no credential, authorization, cookie, subprotocol, or
      remote-host input.
- [x] Confirm `process.exec` runs as the server OS user and is not sandboxed.
- [x] Confirm model/server text is rendered only as escaped plain text.
- [x] Confirm unload and disconnect never send cancellation.

### Testing

- [x] Confirm unit tests use an injected/fake browser WebSocket boundary.
- [x] Confirm browser tests use a real test-only loopback WebSocket server.
- [x] Confirm one browser test reaches the real Synapse API with Fake dependencies.
- [x] Confirm live Tokamak browser tests are explicit opt-in and excluded by default.

### Phase Complete When

- [x] Versions, package policy, browser target, protocol scope, and trust decisions
      are recorded with no unresolved architectural choice.
- [x] No source or package files have been scaffolded before those decisions pass.

## Phase 1: Scaffold Svelte 5 And Quality Gates

### Application

- [x] Create `ui/web` as a Svelte 5 TypeScript Vite application.
- [x] Enable strict TypeScript and Svelte compiler checks.
- [x] Use Svelte 5 runes for shared reactive controllers in `.svelte.ts` files.
- [x] Keep browser globals out of module initialization; connect from mounted UI
      lifecycle only.
- [x] Add one root `App.svelte` with static placeholder regions for connection,
      composer, run output, activity, and protocol diagnostics.
- [x] Add global design tokens and a responsive base layout.
- [x] Add UI-local `.gitignore` entries for `node_modules`, `dist`, coverage,
      Playwright output, and local environment files.

### Dependencies

- [x] Keep `svelte` as the only runtime framework dependency unless evidence
      requires another.
- [x] Add Vite, Svelte plugin, TypeScript, and `svelte-check` as development tools.
- [x] Add Vitest, Testing Library, jsdom, Playwright, ESLint, and Prettier as
      development tools.
- [x] Add a test-only WebSocket server package only if Node's selected runtime does
      not provide the required deterministic server API.
- [x] Audit the resolved dependency tree before commit.

### Scripts

Define at least:

```json
{
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "preview": "vite preview",
    "check": "svelte-check --tsconfig ./tsconfig.json",
    "lint": "eslint . && prettier --check .",
    "format": "prettier --write .",
    "test": "vitest run",
    "test:e2e": "playwright test",
    "verify": "npm run check && npm run lint && npm run test && npm run build"
  }
}
```

Exact commands may follow current official package conventions, but each gate must
remain non-interactive and reproducible from `ui/web`.

### Tests

- [x] Render the root component in jsdom.
- [x] Verify no connection starts before mount.
- [x] Verify unmount cleans any controller resources.
- [x] Verify desktop and narrow layout roots have stable semantic landmarks.

### Documentation

- [x] Add `ui/web/README.md` with prerequisites, install, dev, build, and verification
      commands.
- [x] State that the app is an independent protocol client and not served by Mix.
- [x] State that no `.env` file may contain `TOKAMAK_API_KEY` in `ui/web`.

### Phase Complete When

- [x] `npm run check`, `npm run lint`, `npm run test`, and `npm run build` pass.
- [x] The static placeholder app loads on desktop and mobile widths.
- [x] No protocol or WebSocket implementation exists yet.

## Phase 2: Implement Protocol Contracts

Phase 2 uses a bounded parser rather than asserting a `JSON.parse` result. It rejects
duplicate keys, malformed Unicode, excess JSON structure, non-integer numeric token
forms in integer fields, and values above `Number.MAX_SAFE_INTEGER` before building
fresh typed messages. Client encoders mirror Elixir's Unicode-trim behavior, exact
canonical run-ID form, NUL-free absolute path rule, and per-field Budget minima and
maxima. Trusted server policy may still lower these browser maxima. Protocol v1
advertises only effective `max_output_bytes` in `server.hello`; all other lower
server policy remains authoritative.

### Types

- [x] Define exact TypeScript types for all four client commands.
- [x] Define exact types for all eight server envelopes.
- [x] Define each concrete `run.event` variant.
- [x] Define projection, Active Tool, Agent Result, Agent/Runtime/API error, and
      terminal unions.
- [x] Define the seven Budget fields without accepting arbitrary keys.
- [x] Keep wire types separate from rendered view models.

### Encoding

- [x] Implement one encoder per command type.
- [x] Omit optional model and Budget fields when blank.
- [x] Accept only integer Budget fields, require each exact field minimum, and reject
      negative, unsafe, or above-protocol values.
- [x] Validate prompt, path, model, request ID, run ID, and cursor bounds before send.
- [x] Measure final encoded bytes with `TextEncoder`.
- [x] Build exact string-keyed JSON without spreading form state.

### Decoding

- [x] Parse only text messages within the client message ceiling.
- [x] Reject Blob, ArrayBuffer, and unexpected browser message data.
- [x] Validate exact envelope keys and correlation policy.
- [x] Validate hello before any other message.
- [x] Validate every protocol error code and retryable flag.
- [x] Validate snapshot modes, reset combinations, projection fields, and optional
      nested terminal.
- [x] Validate event types and exact event-specific fields.
- [x] Validate terminal source-specific Result/Error shapes.
- [x] Reject extra nested fields instead of silently discarding them.
- [x] Return a closed local decode error with fixed prose and no raw frame content.

### Tests

- [x] Decode one valid fixture for every server message and event variant.
- [x] Reject missing and extra envelope fields.
- [x] Reject unknown version and type.
- [x] Reject malformed snapshot mode/reset combinations.
- [x] Reject malformed terminal source variants.
- [x] Reject unsafe integers and values above `Number.MAX_SAFE_INTEGER`.
- [x] Reject oversized encoded incoming and outgoing messages.
- [x] Verify optional start fields are omitted rather than encoded as `null`.
- [x] Verify command JSON contains no credential or authority field names.
- [x] Verify decode failures never include the raw offending frame in user-visible
      errors.

### Documentation

- [x] Link each protocol source file to `PLAN-API.md` as the authority.
- [x] Explain why TypeScript does not replace runtime validation.
- [x] Document the browser safe-integer restriction relative to signed-64-bit API
      cursors.

### Phase Complete When

- [x] Every protocol fixture passes without a running server.
- [x] No unchecked parsed object can reach UI state.
- [x] Command encoding can produce only the four protocol-v1 command types.

## Phase 3: Implement WebSocket Lifecycle

Phase 3 uses one injected Svelte-rune controller and one pure pending-correlation
owner. The selected local policy is a ten-second readiness timeout, eight-second
response warning, one in-flight 25-second keepalive, private close code 4000 for
local protocol faults, and deterministic reconnect delays with no jitter. Reconnect
pauses while hidden, resumes once visible, and resets its ten-attempt outage budget
only after validated hello. The browser adapter owns visibility, pagehide, pageshow,
BFCache, storage, and component cleanup without ever sending cancellation.

### Controller

- [x] Create one Svelte 5 rune-based connection controller.
- [x] Inject the WebSocket constructor, clock, timers, and session storage for tests.
- [x] Track explicit lifecycle, validated URL, socket generation, hello, reconnect
      attempt, and last close classification.
- [x] Permit only one active socket generation.
- [x] Reject invalid local URLs before constructing WebSocket.
- [x] Validate `server.hello` as the first message.
- [x] Expose readable derived booleans for connect, start, cancel, and reconnect
      controls rather than duplicating conditions in components.

### Commands And Correlation

- [x] Maintain a bounded map from generated request ID to expected response kind.
- [x] Set a bounded local response-warning timeout without dropping correlation,
      claiming rejection/cancellation, or permitting an ambiguous start to be resent.
- [x] Route direct responses to the matching pending command.
- [x] Route asynchronous snapshot, event, and terminal messages to the
      generation-scoped run-state callback.
- [x] Treat mismatched correlation, target run ID, or response type as a protocol
      fault.
- [x] Clear pending timers when the socket closes.

### Keepalive And Reconnect

- [x] Send application `ping` every 25 seconds while ready.
- [x] Validate correlated `pong` and track last server activity.
- [x] Clear keepalive when hidden, closed, replaced, or unmounted as required by
      the selected timer policy.
- [x] Add bounded reconnect delays and attempt count.
- [x] Stop automatic reconnect after policy/internal close codes or ten failures.
- [x] Never resend `run.start` automatically.
- [x] After reconnect hello, delegate run restoration to the run controller callback.
- [x] Add a manual disconnect action that does not cancel the run.

### Tests

- [x] Connect transitions through awaiting hello to ready.
- [x] A non-hello first message fails closed.
- [x] Old socket callbacks cannot alter a newer generation.
- [x] Ping/pong timers start and stop exactly once.
- [x] Pending command capacity and timeout are bounded.
- [x] Ordinary network close schedules bounded reconnect.
- [x] Policy/internal close stops automatic reconnect.
- [x] Unmount closes transport and sends no cancellation command.
- [x] Page lifecycle cleanup sends no cancellation command.

### Phase Complete When

- [x] A scripted socket can connect, validate hello, ping, close, and reconnect.
- [x] Transport ownership and cleanup are understandable from controller source and
      tests.
- [x] No run projection logic is hidden inside Svelte presentation components.

## Phase 4: Implement Run State, Replay, And Reset

Phase 4 separates authoritative run state from both form draft and presentation.
One pure reducer handles initiating-connection events, retained replay, and resumed
live delivery. The rune controller owns correlation-aware synchronization, a
ten-second baseline replay watchdog, no-cursor snapshot recovery, and same-tab run
ID restoration. Activity and protocol diagnostics retain summaries rather than raw
frames and are independently bounded to 500 entries and one encoded MiB.

### Run Controller

- [x] Create one rune-based controller for the current run.
- [x] Keep form draft separate from accepted run state.
- [x] Install run ID only from validated `run.accepted`.
- [x] Initialize cursor zero for the initiating connection.
- [x] Apply each concrete event through one pure reducer.
- [x] Apply terminal through one pure terminal reducer.
- [x] Reject sequence gaps, duplicates, and reversals without partial mutation.
- [x] Request an authoritative snapshot after a sequence fault.

### Projection

- [x] Match API projection status precedence, including `cancel_requested` and
      `owner_lost`.
- [x] Append text exactly and preserve whitespace.
- [x] Track current turn and configured model.
- [x] Track one Active Tool summary without arguments.
- [x] Update aggregate counters only from `turn.completed` or successful terminal.
- [x] Keep terminal Result/Error separate from progress events.
- [x] Prevent duplicate terminal application.

### Subscription

- [x] Subscribe after reconnect with `after_seq` when an in-memory projection exists.
- [x] Apply replay only after the replay acknowledgement.
- [x] Require strict contiguous replay and live sequence.
- [x] Replace all run state on snapshot mode.
- [x] Surface `reset: true` as lost history, not run failure.
- [x] Do not expect a duplicate terminal after a completed snapshot.
- [x] Clear a stale run on `run_not_found` only after showing a bounded explanation.

### Restoration

- [x] Persist only validated API URL and current run ID in `sessionStorage`.
- [x] Restore through subscribe without cursor after page reload.
- [x] Never persist prompt, path, output, events, terminal, or protocol timeline.
- [x] Clear restoration on explicit clear/new-run action.
- [x] Handle unavailable process-lifetime run state honestly after server restart.

### Bounds

- [x] Cap activity and protocol timelines by count and encoded bytes.
- [x] Evict oldest diagnostic entries without altering authoritative run projection.
- [x] Keep assistant text within the server-advertised/protocol ceiling.
- [x] Avoid retaining raw frame strings after validation.

### Tests

- [x] Reduce every event variant in sequence.
- [x] Preserve cancellation status through later progress.
- [x] Apply owner loss and later terminal correctly.
- [x] Reject duplicate, skipped, reversed, and unsafe sequences.
- [x] Apply replay acknowledgement without replacing projection.
- [x] Replace projection and terminal on ordinary snapshot.
- [x] Replace projection and expose lost-history status on reset snapshot.
- [x] Restore from session run ID through no-cursor snapshot.
- [x] Prove timeline eviction does not change projection or cursor.

### Phase Complete When

- [x] The same reducer handles initial live events, retained replay, and resumed live
      delivery.
- [x] Reset never leaves stale local fields mixed with server projection.
- [x] Reload restoration retains no user or model content in browser storage.

## Phase 5: Implement Interactive Controls

Phase 5 exposes the composed controllers without changing their authority boundary.
The selected post-acceptance draft rule clears only Prompt after correlated
`run.accepted`; Workspace path, Model, and Budget remain in memory for a later run.
No draft field is persisted. While start is pending, the submitted draft is locked.
New Run is terminal-or-confirmed-stale only and replaces a ready socket so completed
run subscriptions cannot accumulate against the per-connection limit.

### Connection Controls

- [x] Show validated API URL with connect, disconnect, and reconnect actions.
- [x] Default to `ws://127.0.0.1:4848/v1/socket`.
- [x] Explain that the server must be started separately.
- [x] Show hello protocol and replay mode after readiness.
- [x] Show a clear local-trust warning before the first run.

### Run Composer

- [x] Add required prompt and absolute workspace path fields.
- [x] Add optional model field that is omitted when blank.
- [x] Add a collapsed advanced Budget section with all seven optional fields.
- [x] Validate UTF-8 byte ceilings and basic absolute POSIX path shape locally.
- [x] Let server policy remain authoritative for model allowlist, Budget lowering,
      Workspace support, and capabilities.
- [x] Disable start until hello is valid and no active run is reserved.
- [x] Preserve form input on pre-admission `server.error`.
- [x] Clear or retain form input after acceptance according to one documented rule;
      never persist it automatically.

### Run Actions

- [x] Send one `run.start` from explicit user action only.
- [x] Move focus to current run after `run.accepted`.
- [x] Show cancel only for non-terminal accepted runs.
- [x] Send `run.cancel` only from explicit user action.
- [x] Treat `run.cancel_requested` as intent acknowledgement, not terminal cleanup.
- [x] Disable duplicate cancellation while intent is pending.
- [x] Support manual transport disconnect without cancellation.
- [x] Support clear/new run only after terminal or confirmed stale run removal.

### Errors

- [x] Map every stable `server.error` code to concise fixed UI guidance.
- [x] Distinguish retryable admission failure from protocol validation failure.
- [x] Distinguish connection loss from run failure.
- [x] Distinguish reset/lost history from run failure.
- [x] Never render raw browser exceptions, stacktraces, rejected values, or full
      frames in ordinary notices.
- [x] Keep detailed sanitized protocol diagnostics in the explicit inspector.

### Tests

- [x] Start encodes exact required fields.
- [x] Blank model and Budget are omitted.
- [x] Invalid path, prompt, URL, and Budget are rejected before send.
- [x] Pre-admission error preserves composer state.
- [x] Accepted start installs only the server run ID.
- [x] Cancel is explicit, idempotent in UI state, and separate from disconnect.
- [x] New run cannot overlap an active run.

### Phase Complete When

- [x] A user can connect, start, cancel, disconnect, reconnect, clear, and start a
      later run without opening browser developer tools.
- [x] No control can create a wire field outside protocol v1.

## Phase 6: Implement Run Presentation

### Connection And Run Header

- [x] Show connection state with text, icon, and color.
- [x] Show run ID, status, model, turn, sequence, and reset/replay indicators.
- [x] Copy run ID only through explicit user action.
- [x] Keep long identifiers clipped visually but available to accessible text/copy.

### Assistant Output

- [x] Render accumulated assistant text as escaped plain text.
- [x] Preserve whitespace and long-line wrapping.
- [x] Avoid per-token DOM nodes; render one bounded text value.
- [x] Do not add Markdown or syntax highlighting in the MVP.
- [x] Keep the user's scroll position when reading earlier output; auto-follow only
      when already near the bottom.

### Tool Activity

- [x] Show one active Tool card with name, ordinal, turn, and status.
- [x] Never show Tool arguments because the API does not expose them.
- [x] Show completed Tool activity from bounded events with public status/outcome.
- [x] Do not infer file changes, command output, or success beyond wire fields.

### Terminal

- [x] Render successful Result text and counters.
- [x] Render Agent, Runtime, and API error variants with source-aware fixed layout.
- [x] Label `runtime_lost`, `owner_lost`, cancellation, failure, and interruption
      distinctly.
- [x] Explain that terminal cleanup is authoritative except documented
      settlement-unproven `runtime_lost`.
- [x] Announce terminal once and expose new-run action.

### Protocol Inspector

- [x] Show bounded validated inbound and outbound envelopes in source order.
- [x] Mark replay, snapshot, reset, command response, and asynchronous frames.
- [x] Pretty-print from validated values, never raw frame text.
- [x] Omit or summarize assistant text by default to avoid duplicating content.
- [x] Provide clear/copy actions with an explicit disclosure warning.
- [x] Never include credentials, browser storage internals, callbacks, or raw errors.

### Responsive And Accessible UI

- [x] Verify wide two-column and narrow stacked layouts.
- [x] Keep composer and run controls usable at 320 CSS pixels.
- [x] Verify keyboard-only start, cancel, disclosures, inspector, and new run.
- [x] Verify focus order and live-region behavior during streaming.
- [x] Verify reduced motion and sufficient contrast.
- [x] Run automated accessibility checks in Playwright.

### Phase Complete When

- [x] Text, Tool activity, cancellation, reset, success, failure, and interruption
      are understandable without raw JSON.
- [x] The protocol inspector remains available for interactive backend testing.
- [x] Desktop and mobile layouts load without horizontal overflow or inaccessible
      controls.

## Phase 7: Deterministic Browser Acceptance

### Scripted WebSocket Server

- [x] Start a test-only loopback WebSocket server on port zero.
- [x] Validate the browser Origin is local.
- [x] Send exact `server.hello` first.
- [x] Validate exact commands sent by the UI.
- [x] Script snapshots, replay, all event classes, terminals, errors, and close codes.
- [x] Keep scripts bounded and deterministic with no wall-clock sleeps.
- [x] Use explicit messages/barriers to release reconnect and event steps.

### Defining Browser Scenario

- [x] Load the built/served Svelte application in Playwright.
- [x] Connect to the assigned scripted server.
- [x] Enter workspace path and prompt.
- [x] Start one run and verify exact outbound JSON omits authority and credentials.
- [x] Receive starting, text, Tool start/completion, turn completion, and terminal.
- [x] Verify assistant text, Tool activity, counters, and terminal presentation.
- [x] Verify protocol inspector ordering and bounded content.

### Reconnect Scenario

- [x] Close the first connection while the run is active.
- [x] Verify no cancellation command is sent.
- [x] Accept the reconnect and validate subscribe uses last applied sequence.
- [x] Deliver retained replay and then live events without a duplicate/gap.
- [x] Repeat with a stale cursor and authoritative reset.
- [x] Verify completed snapshot does not duplicate terminal presentation.

### Error And Cancellation Scenarios

- [x] Show each stable server error safely.
- [x] Show protocol fault for malformed server frame without raw frame disclosure.
- [x] Stop reconnect after policy/internal close.
- [x] Request cancellation and verify acknowledgement is not terminal.
- [x] Deliver interrupted terminal and verify one terminal presentation.

### Accessibility And Responsive Tests

- [x] Run desktop and mobile Chromium viewports.
- [x] Verify no horizontal overflow.
- [x] Verify labels, landmarks, live regions, and keyboard focus.
- [x] Capture screenshots only for stable major states, not every streamed delta.

### Phase Complete When

- [x] Browser acceptance passes without Elixir, Tokamak, API key, or user checkout.
- [x] Reconnect, replay, reset, cancellation, and terminal behavior are proven through
      visible UI and exact protocol assertions.

## Phase 8: Real Synapse Integration And Hardening

### Test-Only Synapse Fixture

- [x] Add an external Elixir fixture under `ui/web/tests/fixtures` that starts the
      real API on port zero with trusted test configuration.
- [x] Use real Router, Socket, RunManager, RunSession, Runtime, Agent, Tool, and API
      wire boundaries.
- [x] Use Fake Provider and controlled Fake Workspace for deterministic effects.
- [x] Print only a bounded ready URL for Playwright discovery.
- [x] Keep the browser client protocol-only; no test API or imported Elixir value may
      enter frontend source.
- [x] Stop and monitor the external fixture and all owned children after the test.

### Real API Browser Scenario

- [x] Start the Vite preview or dev server on local loopback.
- [x] Start the external Synapse fixture on port zero.
- [x] Connect through the browser with the real Origin and Host behavior.
- [x] Complete one deterministic read/write/Bash/final-text scenario.
- [x] Verify streamed text, Tool names, sequence, terminal, and cleanup.
- [x] Disconnect/reconnect once while work is active and prove no cancellation.
- [x] Verify the UI never calls `/health` or uses a proxy.

### Reliability

- [x] Fuzz runtime decoder input with fixed-seed JSON-compatible values.
- [x] Test maximum incoming frame, text, identifier, timeline, and output boundaries.
- [x] Test rapid pongs, command responses, events, and reconnect callbacks.
- [x] Test hidden-tab inactivity close and later reconnect.
- [x] Test page reload restoration by no-cursor snapshot.
- [x] Test server restart returns `run_not_found` and clears stale process-lifetime
      state honestly.
- [x] Test storage unavailable/throwing without losing current in-memory interaction.
- [x] Test repeated mount/unmount leaves no sockets, timers, or listeners.

### Security

- [x] Search frontend source and built assets for credential field names and test
      sentinels.
- [x] Confirm no `TOKAMAK_API_KEY` or Provider credential is read by Vite.
- [x] Confirm no `VITE_*` secret is required.
- [x] Confirm URL validation prevents remote host, userinfo, query, and fragment.
- [x] Confirm prompt, path, output, and terminal are absent from persistent and
      local storage.
- [x] Confirm `sessionStorage` contains only API URL and run ID.
- [x] Confirm model/server text cannot create HTML, script, URL, style, or event
      handler nodes.
- [x] Confirm copied diagnostics carry a visible content-disclosure warning.
- [x] Confirm production build contains no test fixtures, callbacks, or internal
      Synapse authority.

### Performance

- [x] Keep one text node/value for accumulated assistant output.
- [x] Bound timeline DOM nodes and stored diagnostics.
- [x] Measure a maximum-output run for input responsiveness and layout stability.
- [x] Confirm reconnect does not duplicate retained output in memory or DOM.
- [x] Confirm no unbounded Svelte effect or derived-state loop exists.

### Phase Complete When

- [x] One deterministic Playwright run reaches the real Synapse API boundary.
- [x] Browser and external fixture processes terminate cleanly.
- [x] Resource, storage, XSS, disclosure, and reconnect hardening tests pass.

## Phase 9: Live Interactive Tokamak Acceptance

### Policy

- [x] Keep live tests excluded from default unit, browser, and integration commands.
- [x] Require `TOKAMAK_API_KEY` and `SYNAPSE_MODEL` only in the external Synapse
      server environment.
- [x] Never expose `TOKAMAK_API_KEY` through Vite environment variables, browser
      storage, URL, command, frame, screenshot, trace, or Playwright report.
- [x] Treat `SYNAPSE_MODEL` as public protocol/UI metadata after server-only
      configuration; omit it from browser commands and client environment variables.
- [x] Use a temporary supported workspace, never the repository checkout.
- [x] Keep generated prompts and assertions free of private project content.

### Manual Interactive Acceptance

- [ ] Start literal `mix synapse.server` with production Provider/Workspace policy.
- [ ] Start literal `npm --prefix ui/web run dev -- --host 127.0.0.1`.
- [ ] Connect from the visible browser UI.
- [ ] Start one text-only run and observe non-empty streamed output plus completed
      terminal.
- [ ] Start one harmless temporary-workspace coding run that uses read, write, and
      Bash.
- [ ] Disconnect transport while the run is active and observe reconnect/replay.
- [ ] Independently inspect the temporary file and command result after terminal.
- [ ] Request cancellation on one long-running temporary command and observe an
      interrupted terminal plus process cleanup.

### Optional Automated Live Browser Test

- [x] Tag the Playwright live project explicitly and exclude it by default.
- [x] Launch the literal external server rather than importing backend modules.
- [x] Use the same built client and protocol path as manual acceptance.
- [x] Check all captured frames, browser console, traces, screenshots, and logs for
      the real key before an assertion can print them.
- [x] Retain no live report artifact unless it has been reviewed for disclosure.

### Acceptance

- [x] The UI remains responsive during live text and Tool activity.
- [x] Disconnect never sends cancellation.
- [x] Reconnect restores complete retained state or explicit reset.
- [x] Terminal matches independent workspace evidence.
- [x] Browser console contains no unexpected error or secret.
- [x] Synapse and owned workspace/process state are clean after each run.

### Phase Complete When

- [ ] A human can use the UI for the complete defining Synapse interaction without
      browser developer tools.
- [x] Default frontend and backend verification still requires no live key.
- [x] No credential or opaque authority entered browser-visible state.

## Phase 10: Documentation And Comprehension Review

### UI Documentation

<!-- prettier-ignore -->
- [x] Complete `ui/web/README.md` with install, development, build, preview, test, troubleshooting, and live-use instructions.
- [x] Add `docs/learning/UI.md` as the maintainer guide.
- [x] Add the UI guide to ExDoc extras under Learning.
- [x] Document the exact process/browser tree and source ownership.
- [x] Document every Svelte controller, protocol module, and meaningful component.
- [x] Document connection, hello, keepalive, reconnect, and cleanup behavior.
- [x] Document sequence, replay, snapshot, reset, and restoration behavior.
- [x] Document local trust, Origin, same-user process execution, storage, and XSS limitations.
- [x] Document why the client does not fetch `/health`, use a proxy, or use SvelteKit.
- [x] Document the JavaScript safe-integer cursor limitation.

### Consistency Review

<!-- prettier-ignore -->
- [x] Ensure `PLAN.md`, `PLAN-API.md`, README, this plan, and UI docs agree that the UI is an independent post-MVP protocol client.
- [x] Ensure no backend document claims Synapse serves frontend assets.
- [x] Ensure no UI document claims replay survives Manager/application restart.
- [x] Ensure no UI document describes run ID as authentication.
- [x] Ensure no UI document claims Workspace or `process.exec` is sandboxed.
- [x] Ensure future TUI and desktop clients remain independent protocol clients.
- [x] Verify every relative documentation link.

### Comprehension Gate

<!-- prettier-ignore -->
- [x] Explain why connection state, run projection, and Svelte presentation are separate modules.
- [x] Trace one form submission to exact `run.start` JSON.
- [x] Trace `run.accepted` to server run ID installation and cursor zero.
- [x] Trace one `text.delta` from validated frame through sequence reducer to DOM.
- [x] Trace reconnect through hello, replay acknowledgement, retained events, and live continuation.
- [x] Explain why reset replaces projection and is not durable history.
- [x] Explain why disconnect/unload cannot cancel a run.
- [x] Explain page reload restoration and exactly what enters `sessionStorage`.
- [x] Explain how malformed frames, sequence gaps, close codes, and server restart appear to the user.
- [x] Explain how all mandatory UI behavior is tested without Tokamak.

### Final Verification

- [x] `npm --prefix ui/web ci`
- [x] `npm --prefix ui/web run check`
- [x] `npm --prefix ui/web run lint`
- [x] `npm --prefix ui/web run test`
- [x] `npm --prefix ui/web run build`
- [x] `npm --prefix ui/web run test:e2e`
- [x] `mix compile --warnings-as-errors`
- [x] `mix format --check-formatted`
- [x] `mix test`
- [x] `mix docs`
- [x] Review built assets for source maps, secrets, test code, and unexpected remote
      requests.
- [x] Review generated ExDoc navigation and UI guide links.
- [x] Review desktop, mobile, keyboard, reduced-motion, and accessibility behavior.

### Phase Complete When

- [x] The web UI can be understood and maintained from Svelte source, TypeScript
      LSP, tests, `ui/web/README.md`, `docs/learning/UI.md`, and this plan without the
      original AI conversation.
- [x] All deterministic verification passes and live browser tests remain explicit
      opt-in.
- [ ] Every checklist phase and the Web UI definition of done are satisfied.

## Test Matrix

| Layer                  | Primary proof                                        | Synapse required | Tokamak required |
| ---------------------- | ---------------------------------------------------- | ---------------- | ---------------- |
| Command encoder        | Vitest exact JSON tests                              | No               | No               |
| Message decoder        | Vitest valid/adversarial fixtures                    | No               | No               |
| Run reducer            | Vitest sequence/replay/reset tests                   | No               | No               |
| Connection controller  | Injected WebSocket/timer tests                       | No               | No               |
| Svelte components      | Testing Library interaction/a11y tests               | No               | No               |
| Browser protocol flow  | Playwright plus scripted loopback server             | No               | No               |
| Real API compatibility | Playwright plus external Fake-backed Synapse fixture | Yes              | No               |
| Live interaction       | Manual/opt-in Playwright plus production server      | Yes              | Yes              |
| Build disclosure       | Static asset and storage inspection                  | No               | No               |

## Suggested Commit Sequence

1. `Plan basic Svelte web UI`
2. `Scaffold Svelte 5 web client`
3. `Add protocol v1 browser contracts`
4. `Add WebSocket connection lifecycle`
5. `Add run replay and projection state`
6. `Add interactive run controls`
7. `Render run progress and terminals`
8. `Add deterministic browser acceptance`
9. `Verify real Synapse browser integration`
10. `Document and live-verify web UI`

Each commit must keep existing backend verification green and pass the focused
frontend gates introduced by that commit.

## Web UI Definition Of Done

- [ ] Phases 0 through 10 are complete.
- [x] All frontend implementation lives under `ui/web`.
- [x] The app uses Svelte 5 runes, strict TypeScript, and Vite without SvelteKit.
- [x] Synapse serves no frontend assets and imports no frontend dependency.
- [x] Browser connects directly to the validated loopback protocol-v1 endpoint.
- [x] A user can start one run with prompt and absolute workspace path.
- [x] Optional model and Budget values can only narrow existing server policy.
- [x] Streamed text, Tool activity, counters, cancellation, and terminal are visible.
- [x] Disconnect and page unload never cancel the run.
- [x] Reconnect produces contiguous retained replay or authoritative reset.
- [x] Page reload can restore a retained run through no-cursor snapshot without
      persisting content.
- [x] Every parsed server message is runtime validated before state mutation.
- [x] Sequence gaps never silently alter projection.
- [x] Browser state, timelines, DOM, command correlations, retries, and timers are
      bounded.
- [x] No credential, opaque authority, raw exception, or unescaped HTML crosses the
      browser boundary.
- [x] Deterministic UI verification requires no Tokamak key or user checkout.
- [x] One browser test reaches the real Fake-backed Synapse API.
- [x] One opt-in live interaction completes through production Tokamak and temporary
      Real Workspace policy.
- [x] Desktop, mobile, keyboard, reduced-motion, and accessibility checks pass.
- [x] Frontend and backend compile, format, test, build, browser, and docs gates pass.

## Deferred Web UI Work

Do not add these to the basic web client:

- Multiple concurrent runs, run lists, tabs, queues, or project dashboards.
- Durable history, SQLite sessions, cross-browser resume, or replay after server
  restart.
- Follow-up prompts, steering, approvals, select/confirm/input requests, or
  interactive stdin.
- File tree, editor, patch/diff application, terminal emulator, PTY, or artifact
  browser.
- Markdown rendering, syntax highlighting, rich media, reasoning traces, or hosted
  Tool widgets.
- Provider selection, capability controls, Tool configuration, credentials, secret
  broker UI, or Runtime options.
- Authentication, remote hosts, TLS, reverse proxy, multi-user isolation, or
  network deployment.
- SvelteKit, SSR, service worker, offline mode, PWA install, or push notifications.
- Telemetry, analytics, billing, token/cost estimation, or performance export.
- Theme marketplace, plugin API, extension loading, or shared component package.
- TUI, desktop shell, Electron, Tauri, or mobile application code.

Because protocol-v1 objects and enums are closed, a wire-shape or semantic change
requires a new protocol version unless compatibility is proved for every existing
client. Future work must not infer unavailable authority, reinterpret current
messages, or turn process-lifetime replay into a durability claim.
