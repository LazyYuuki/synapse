# Synapse Minimal MVP Architecture Plan

## Goal

Build the smallest version of Synapse that can receive one local prompt through a
frontend-agnostic local API, use Tokamak as its model provider, execute basic
coding tools inside a workspace, and continue until the model returns a final
answer.

The MVP has one concrete demonstration:

```text
TOKAMAK_API_KEY="..." SYNAPSE_MODEL="..." mix synapse.server

Web, TUI, or desktop client
  -> ws://127.0.0.1:4848/v1/socket
  -> run.start(prompt, cwd, optional model and conversation)
  -> ordered run events
  -> one structured run terminal
```

To complete that demonstration, Synapse needs exactly six main components:

1. Provider
2. Workspace
3. Tool System
4. Agent Loop
5. Runtime
6. Local WebSocket API

Everything else is either a shared data contract or a post-MVP feature.

## Architecture At A Glance

```text
+-------------------------+
| 6. Local WebSocket API  |
+------------+------------+
             |
             v
+-------------------------+
| 5. Runtime              |
| supervises one run      |
+------------+------------+
             |
             v
+-------------------------+
| 4. Agent Loop           |
+------+------------------+
       |                  |
       v                  v
+--------------+   +----------------+
| 1. Provider  |   | 3. Tool System |
+--------------+   +--------+-------+
                         |
                         v
                  +--------------+
                  | 2. Workspace |
                  +--------------+
```

Runtime starts and monitors the Agent Loop. It passes cancellation references, deadlines, and supervised resources into the run. Provider, Tool System, and Workspace never call back into Runtime.

## Component Dependency Graph

```text
Web / TUI / Desktop clients
             |
             v
      Local WebSocket API
             |
             v
          Runtime
             |
             v
         Agent Loop
         |        |
         v        v
    Provider   Tool Executor
                  |
                  v
             Built-in Tools
                  |
                  v
              Workspace
```

All components share a small set of contracts:

```text
Run Request
Run Event
Provider Request
Provider Event
Tool Call
Tool Result
Budget
```

Raw Tokamak JSON must not cross the Provider boundary. Raw model tool arguments must not cross the Tool Executor boundary without validation. Raw filesystem paths must not cross the Workspace boundary without canonicalization.

## Request Lifecycle

```text
1. Client sends a versioned `run.start` WebSocket command
2. API validates the wire message and reserves a server-assigned run ID
3. API starts one temporary RunSession; that process creates the Run Request
4. RunSession starts and owns the Runtime handle and owner-only await right
5. Runtime starts the supervised run
6. Agent Loop creates Provider Request
7. Provider streams normalized events
8. Agent Loop treats the successful terminal Provider Response as the authority
   for final text, complete tool calls, and source order
9. Agent preflights every call; one-call Executor validates one admitted Call
10. Built-in Tool prepares one typed Workspace request without a Handle
11. Static Dispatcher calls the exact Workspace operation under reduced Access
12. Workspace returns a bounded Workspace result or error
13. Built-in Presentation creates one paired bounded Tool Result
14. Agent Loop appends paired tool output to conversation
15. Agent Loop requests the next model turn
16. As Runtime emits progress, API assigns ephemeral sequence numbers, updates
    its bounded projection, and emits versioned JSON messages
17. Loop ends on final text or terminal failure
18. API confirms and emits one ordinary terminal after Runtime cleanup and await;
    `runtime_lost` is the explicit exception where settlement cannot be proven
19. A disconnected client may resubscribe while the server process remains alive;
    disconnect never cancels the run
```

## Component Summary

| Component | Primary responsibility | Depends on |
| --- | --- | --- |
| Provider | Convert Synapse requests to Tokamak HTTP and Tokamak SSE to normalized events | Req, shared contracts |
| Workspace | Own safe access to files and local processes inside one project root | OTP, MuonTrap, shared contracts |
| Tool System | Expose model-facing tool schemas and dispatch validated calls | Workspace, shared contracts |
| Agent Loop | Own conversation state and coordinate model-tool turns | Provider, Tool System, shared contracts |
| Runtime | Supervise run lifetime; own Workspace lifecycle and cancellation; wire time-limit policy | Agent Loop, Workspace, OTP, shared contracts |
| Local WebSocket API | Validate local wire commands, own Runtime sessions, and expose bounded run projections and events | Runtime, Plug/Bandit/WebSock, shared contracts |

## Shared Contracts

Shared contracts are not a seventh subsystem. They are small structs and types used to keep component boundaries explicit.

### Run Request

```elixir
%Synapse.Run.Request{
  id: run_id,
  prompt: prompt,
  cwd: validated_absolute_workspace_input,
  model: model,
  capabilities: capabilities,
  budget: budget
}
```

### Run Event

```text
run_started
turn_started
text_delta
tool_started
tool_completed
turn_completed
run_completed
run_failed
run_interrupted
```

### Provider Event

```text
MessageStarted
TextDelta
ToolCallStarted
ToolCallDelta
ToolCallCompleted
MessageCompleted
Diagnostic
```

Failure and interruption are terminal `Provider.Error` return values rather than
progress events.

### Tool Call

```elixir
%Synapse.Tool.Call{
  call_id: call_id,
  name: tool_name,
  arguments: decoded_arguments
}
```

### Tool Result

```elixir
%Synapse.Tool.Result{
  call_id: call_id,
  status: :ok | :error | :ambiguous,
  content: model_visible_content,
  metadata: sanitized_metadata
}
```

### Run Accounting

Turns, Tool calls, Provider retries, and model-visible bytes are accounting
counters, not run ceilings. Every complete Provider request is admitted against
the 272,000-token context limit. After each 20 completed turns, the next Provider
request receives a transient instruction to assess progress, stop and ask for
specific help when stuck, or continue with a concrete next step. Bash duration,
inactivity, and output remain bounded by Tool and Workspace policy.

Every shared contract must have a documented purpose, constructor or validation path, type definition, and clear ownership.

## 1. Provider

Detailed implementation checklist: [`PLAN-PROVIDER.md`](PLAN-PROVIDER.md).

### Purpose

The Provider is the only component that understands Tokamak HTTP endpoints, authorization headers, OpenAI Responses request encoding, or SSE event payloads.

The rest of Synapse sees only normalized Provider Requests, Provider Events, and Provider Errors.

### Internal Structure

```text
Synapse.Provider
|-- Contracts: Request, Response, Event, Error, OutputItem
|-- Synapse.Provider.StreamContext
|-- Synapse.Provider.Tokamak
|-- Synapse.Provider.ResponsesCodec
|-- Synapse.Provider.ResponsesStream
|-- Synapse.Provider.SSEDecoder
|-- Synapse.Provider.Fake
`-- Synapse.Provider.Credentials
```

### Responsibilities

- Define the provider behaviour.
- Build canonical Responses requests.
- Add Tokamak endpoint policy and authorization.
- Open and cancel the Req streaming request.
- Decode SSE across arbitrary HTTP chunks.
- Accumulate function-call argument fragments by item ID and call ID.
- Emit normalized Provider Events.
- Classify authentication, availability, timeout, malformed-stream, interruption, and upstream errors.
- Record whether any output was emitted before failure.
- Keep the Tokamak API key out of logs, events, exceptions, and model context.

### Must Not

- Execute tools.
- Read or modify project files.
- Decide whether the agent loop should continue.
- Render terminal output.
- Store conversation history.
- Expose raw response maps outside the provider.

### Public Boundary

```elixir
@callback stream(
  Synapse.Provider.Request.t(),
  Synapse.Provider.event_sink(),
  Synapse.Provider.StreamContext.t()
) :: {:ok, Synapse.Provider.Response.t()} | {:error, Synapse.Provider.Error.t()}
```

The callback is a normalized request in, ordered synchronous events out, and exactly one structured terminal response or error. `StreamContext` carries operation lifetime without introducing a Provider dependency on Runtime.

### Tokamak Configuration

```text
base URL: https://api.tokamak.sh/v1/agent-pool/codex-proxy
path:     /responses
auth:     Authorization: Bearer <TOKAMAK_API_KEY>
wire:     OpenAI Responses
tools:    canonical flat Responses function tools
```

The model is supplied through `run.start` from the server allowlist or defaults to
`SYNAPSE_MODEL`. Do not silently depend on an upstream default that can change.

### Request Encoding

```json
{
  "model": "configured-model",
  "instructions": "You are the Synapse coding agent.",
  "input": [],
  "tools": [],
  "stream": true,
  "store": false
}
```

Tool output is returned as:

```json
{
  "type": "function_call_output",
  "call_id": "call_123",
  "output": "bounded tool result"
}
```

### SSE Mapping

| Tokamak Responses event | Provider Event |
| --- | --- |
| `response.created` | `MessageStarted` |
| `response.output_text.delta` | `TextDelta` |
| `response.output_item.added` with function call | `ToolCallStarted` |
| `response.function_call_arguments.delta` | `ToolCallDelta` |
| `response.function_call_arguments.done` | `ToolCallCompleted` |
| `response.completed` | `MessageCompleted` and successful terminal return |
| `response.failed` | terminal `Provider.Error` return |

### Credentials

For the MVP, `Synapse.Provider.Credentials` resolves `TOKAMAK_API_KEY` from the environment only when a request is created.

The key must never be:

- Accepted in an API payload, command argument, or WebSocket header.
- Added to a general run struct.
- Included in an inspectable request representation.
- Inherited by `bash` subprocesses.
- Persisted to files or events.

This module is the future seam for a keychain-backed credential broker.

### Tests

- SSE split at every byte boundary.
- LF and CRLF streams.
- Unknown events and comments.
- Multiple interleaved function calls.
- Incomplete function arguments.
- Oversized lines and events.
- Cancellation and inactivity timeout.
- Sanitized 401, 403, 429, 5xx, and malformed-body errors.
- Req-stubbed text and tool responses.
- Scripted Fake provider sequences without network access.

### Complete When

- A live Tokamak text response streams successfully.
- A live Tokamak function call is normalized correctly.
- Provider tests run without a real API key.
- No Tokamak wire data escapes the Provider boundary.
- ExDoc explains endpoint choice, streaming ownership, event mapping, and failure semantics.

## 2. Workspace

Detailed implementation checklist: [`PLAN-WORKSPACE.md`](PLAN-WORKSPACE.md).

### Purpose

The Workspace is the only component allowed to interact with project files or start project processes.

Tools describe an operation. The Workspace determines whether that operation is inside the configured project root and performs it safely.

### Internal Structure

```text
Synapse.Workspace
|-- Synapse.Workspace.Handle
|-- ReadRequest / WriteRequest / EditRequest / ProcessSpec
|-- ReadResult / MutationResult / ProcessEvent / ProcessResult / Error
|-- Synapse.Workspace.Path
|-- Synapse.Workspace.Revision
|-- Synapse.Workspace.MutationServer
|-- Synapse.Workspace.ProcessRunner
`-- Synapse.Workspace.Fake
```

### Responsibilities

- Canonicalize the workspace root once when a run begins.
- Resolve every requested path against that root.
- Reject all caller-supplied absolute paths, traversal, and symlink escape.
- Read bounded file windows with line numbers.
- Calculate opaque file revisions.
- Serialize file mutations.
- Reject stale mutation revisions.
- Validate staged content before replacement.
- Replace files atomically where the filesystem supports it.
- Run bounded commands with the workspace as `cwd`.
- Strip provider secrets from child environments.
- Enforce process time and output limits.
- Enforce matching cancellation, inactivity, and absolute deadlines.
- Enforce the handle's access ceiling and per-operation access reduction.
- Provide a deterministic scripted Fake through the same facade.

### Must Not

- Know model tool schemas.
- Know Tokamak or provider events.
- Decide what tool the model intended.
- Continue the agent loop.
- Print directly to the terminal.

### Public Boundary

```elixir
Workspace.open(open_request)
Workspace.close(workspace)
Workspace.read(workspace, read_request, operation_context)
Workspace.write(workspace, write_request, operation_context)
Workspace.edit(workspace, edit_request, operation_context)
Workspace.run(workspace, process_spec, event_sink, operation_context)
```

Each operation returns a structured result. No operation should require callers to parse terminal text to understand success or failure.

### Revision Rules

- `read` returns the file revision.
- `write` requires the current revision when replacing an existing file.
- `write` uses an explicit `missing` expectation when creating a new file.
- `edit` requires the revision returned by a prior read.
- A revision made stale by an earlier Workspace-coordinated mutation fails before commit; external writers remain subject to the documented cooperative race.
- A failed validation leaves the original file unchanged.

The MVP uses one MutationServer per active workspace. Monitored admission messages, ordered cancellation/deadline withdrawal, and one active whole-workspace mutation lease provide the initial single-writer boundary.

### Process Rules

- Commands run with the workspace as `cwd`.
- `TOKAMAK_API_KEY` and other provider secrets are removed from the child environment.
- Output is bounded.
- Timeout and cancellation stop the owned port or process.
- Completed or declared read-only commands return exit code, elapsed time, timeout state, and truncation state as data; forced stop of an unknown-footprint command is ambiguous.
- Initial descendant process-tree limitations are documented rather than hidden.

Current Workspace is not a sandbox. Its portable path checks assume cooperative
same-user filesystem behavior after validation. Atomic replacement proves visible
old-or-complete-new content, not parent-directory crash durability. Commands retain
the OS user's ambient filesystem and network authority. Healthy-VM cleanup proves
the MuonTrap helper and owned direct command; daemonized descendants may escape.

### Tests

- Canonical root handling.
- Traversal and symlink escape rejection.
- Bounded numbered reads.
- New file creation.
- Stale write and edit rejection.
- Zero-match and multiple-match edit rejection.
- Atomic replacement behavior.
- Mutation serialization.
- Bash `cwd`, exit status, output, timeout, cancellation, and environment stripping.

### Complete When

- All file and process tests pass in temporary workspaces.
- No tool implementation uses `File` or `System` directly.
- Failed mutations cannot leave partially written content.
- ExDoc explains path trust, revisions, mutation ownership, and process limitations.

## 3. Tool System

Detailed implementation checklist: [`PLAN-TOOL-SYSTEM.md`](PLAN-TOOL-SYSTEM.md).

### Purpose

The Tool System is the model-facing capability layer. It tells the model which operations exist, validates requested arguments, checks capabilities, dispatches to a known tool, and returns a paired Tool Result.

### Internal Structure

```text
Synapse.Tool
|-- Synapse.Tool.Registry
|-- Synapse.Tool.Executor
|-- Synapse.Tool.Dispatcher
|-- Synapse.Tool.Presentation
|-- Synapse.Tool.Read
|-- Synapse.Tool.Write
|-- Synapse.Tool.Edit
`-- Synapse.Tool.Bash
```

### Responsibilities

- Define the tool behaviour.
- Provide canonical Responses function schemas.
- Maintain a static registry from string names to known modules.
- Validate decoded arguments for each tool.
- Reject unknown or unavailable tools.
- Enforce the run's capability set.
- Execute exactly one submitted tool call synchronously; Agent owns model-order
  iteration across multiple calls.
- Return one paired Tool Result for every valid Tool Call submitted to Executor.
- Bound all model-visible output.
- Leave tool start and completion Run Events to Agent around the synchronous
  Executor boundary.

### Must Not

- Parse provider SSE.
- Call Tokamak directly.
- Access files or processes except through Workspace.
- Mutate conversation history.
- Create atoms from model-provided names.

### Public Boundary

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
```

```elixir
Tool.Executor.execute(tool_call, tool_context)
```

Executor retains the authenticated Workspace Handle and exact OperationContext.
Built-in callbacks prepare typed requests and present retained outcomes without
receiving host authority; the static Dispatcher alone selects the matching
Workspace facade function.

`call_id` is the Provider function-call pairing ID. It is distinct from the
Provider output-item ID retained by Agent and the bounded Workspace operation ID
supplied through Tool Context.

### Built-In Tools

#### Read

```text
arguments: path, required nullable offset, required nullable limit
capability: fs.read:<workspace>
workspace operation: Workspace.read
returns: numbered lines, revision, continuation information
```

#### Write

```text
arguments: path, content, expected_revision
capability: fs.write:<workspace>
workspace operation: Workspace.write
returns: new revision, bytes written, bounded diff summary
```

#### Edit

```text
arguments: path, old_text, new_text, expected_revision
capability: fs.write:<workspace>
workspace operation: Workspace.edit
returns: new revision and bounded unified diff
```

The old text must match exactly once.

#### Bash

```text
arguments: command, required nullable timeout_ms
capability: process.exec:<workspace>
workspace operation: Workspace.run
returns: exit code, output, elapsed time, and truncation on known completion; forced stop is ambiguous because Bash has unknown mutation footprint
```

### Failure Rules

- Unknown tool produces an error Tool Result.
- Invalid arguments produce an error Tool Result.
- Denied capability produces an error Tool Result.
- Ordinary read, validation, and command failures return error Tool Results to the model.
- An uncertain mutation returns `ambiguous` and terminates the MVP run.
- Calls from a truncated or interrupted provider response are never sent to the Tool Executor.

### Tests

- Registry lookup by string.
- Unknown tool rejection.
- Required argument validation.
- Capability rejection.
- Correct Workspace delegation.
- Paired call and result IDs.
- Output bounding.
- Agent-owned integration harness preserves source order across multiple calls.

### Complete When

- All four schemas are accepted by the Tokamak Codex pool.
- Every tool can be exercised through Fake Workspace without host side effects.
- Every tool delegates host access to Workspace.
- Every valid call submitted to Executor receives a paired result.
- LSP hover explains each tool's purpose, correct usage, side effects, and failure behavior.

## 4. Agent Loop

Detailed implementation checklist: [`PLAN-AGENT-LOOP.md`](PLAN-AGENT-LOOP.md).

### Purpose

The Agent Loop is the central orchestrator. It owns the in-memory conversation and decides when to call the Provider, when to execute complete tool calls, and when the run is finished.

It does not know how Tokamak streams data or how a file is edited.

### Internal Structure

```text
Synapse.Agent
|-- Synapse.Agent.Runner
|-- Synapse.Agent.State
|-- Synapse.Agent.Context
|-- Synapse.Agent.Result
|-- Synapse.Agent.Error
|-- Synapse.Agent.Projection
|-- Synapse.Agent.Admission
|-- Synapse.Agent.OperationId
`-- Synapse.Budget
```

For the MVP, one supervised Task can execute the loop. API reconnect and run
lookup are projections above Runtime; they do not require Agent to become a
GenServer or to surrender conversation ownership.

### Responsibilities

- Initialize run state from a Run Request.
- Own the ordered conversation items.
- Build an immutable Provider Request for each turn.
- Pass current tool specifications to the Provider.
- Collect normalized Provider Events.
- Preserve final assistant output items.
- Reject incomplete tool calls.
- Execute complete tool calls through Tool Executor.
- Append paired function-call outputs to conversation context.
- Repeat until final text, interruption, failure, cancellation, or budget exhaustion.
- Emit normalized Run Events.

### Must Not

- Build HTTP requests or parse SSE.
- Read files or run commands directly.
- Render terminal output.
- Resolve API keys.
- Automatically replay partial provider output.

### State

```elixir
%Synapse.Agent.State{
  run: run_request,
  input_items: input_items,
  turn: 0,
  tool_calls: 0,
  provider_retries: 0,
  output_bytes: 0,
  started_at: started_at,
  deadline: deadline,
  status: :running
}
```

### Loop Algorithm

```text
build immutable turn request
  -> Provider.stream
  -> collect message output
  -> provider error: classify transient versus permanent failure
  -> transient and fewer than ten retries: replay the immutable request
  -> transient at retry limit: fail with provider_retry_exhausted
  -> permanent failure: fail with the classified error
  -> final text and no tools: complete
  -> incomplete tool calls: fail without execution
  -> complete tool calls: execute sequentially
  -> append every paired tool result
  -> enforce budgets
  -> next turn
```

### Context Rules

- The full MVP conversation remains in memory.
- The user prompt becomes the first input message.
- Assistant function-call output items are retained.
- Tool results use `function_call_output` with the matching call ID.
- The next request sends projected conversation input rather than relying on Tokamak account-specific server state.
- Context compaction is not part of the MVP.

### Continuation Rules

- Admit every complete Provider request against the 272,000-token context limit.
- Count turns, Tool calls, output bytes, and safe retries without aggregate ceilings.
- Add a transient progress assessment after every 20 completed turns.
- Keep Bash timeout, inactivity, and output bounds in Tool and Workspace policy.
- Honor cancellation and any explicit Runtime deadline before later work.

### Tests

Use only the Fake provider for deterministic loop tests:

- Final text on first turn.
- One read round trip.
- Read, edit, bash, final response.
- Multiple sequential tool calls.
- Unknown tool.
- Invalid arguments.
- Tool failure followed by model correction.
- Provider failure before output.
- Provider interruption after output.
- Incomplete tool arguments.
- Turn and tool-call budget exhaustion.
- Cancellation.

### Complete When

- The full coding loop passes deterministically without network access.
- The same loop completes one real Tokamak coding task.
- Agent code imports no Req, File, System, API-wire, or frontend-rendering modules.
- ExDoc explains state ownership, turn boundaries, context projection, and termination.

## 5. Runtime

Detailed implementation checklist: [`PLAN-RUNTIME.md`](PLAN-RUNTIME.md).

### Purpose

The Runtime hosts the Agent Loop inside OTP. It owns the outer supervised run
lifetime, Workspace open/close, persistent cancellation, terminal cleanup, and
the trusted time-limit policy passed through Agent to Provider and Workspace.

### Base Supervision Tree

```text
Synapse.Application
`-- Synapse.Supervisor
    |-- Synapse.Workspace.Supervisor
    |   `-- Synapse.Workspace.MutationServer [temporary per opened handle]
    |-- Synapse.TaskSupervisor
    |   `-- Agent Runner Task [temporary per accepted run]
    `-- Synapse.Runtime.Supervisor [one active run maximum]
        `-- Synapse.Runtime.RunServer [temporary per accepted run]
```

This is the API-disabled base infrastructure tree. Step 6 conditionally adds one
API Supervisor sibling after Runtime; that subtree is documented below and in
`PLAN-API.md`.

### Responsibilities

- Start the application supervision tree.
- Start one temporary RunServer and one linked supervised Agent Task.
- Open and close one Workspace owned by the Agent Task.
- Let RunServer monitor the Agent Task while Provider and Workspace retain their
  private workers, ports, watchdogs, and cleanup.
- Propagate persistent cancellation through existing Agent contexts.
- Pass one effective absolute deadline and configured inactivity policy to the
  lower operation owners without creating competing timers.
- Publish the terminal Run Event only after Workspace cleanup.
- Convert unexpected worker exits into structured Run Events.
- Ensure temporary workers are not automatically restarted after side effects.

### Must Not

- Own conversation semantics.
- Parse Tokamak events.
- Define model tool schemas.
- Render user-facing text.
- Persist sessions in the MVP.

### Run Lifecycle

```text
start_run
  -> start temporary RunServer
  -> start linked temporary Agent Task
  -> open Workspace under Agent Task ownership
  -> execute synchronous Agent Runner once
  -> observe Workspace settlement
  -> publish one terminal Run Event
  -> await returns Agent Result or Agent Error
```

Provider inactivity starts near two minutes and Tool inactivity starts near three
minutes. Provider and Workspace enforce those operation-specific timers from the
contexts Agent constructs. RunServer owns cancellation, task monitoring, event
tracking, and the cleanup gate rather than duplicating lower watchdogs.

### Retry Rules

Agent applies semantic Provider retry policy from
[`PLAN-AGENT-LOOP.md`](PLAN-AGENT-LOOP.md). RunServer owns the supervised outer
run lifetime, cancellation source, and earlier deadline policy; it must preserve
these replay constraints rather than independently retrying Runner or a request.

- Connect, TLS, 429, retryable 5xx, timeout, and interrupted streams may retry.
- Each immutable Provider Request allows at most ten additional attempts.
- Partial Provider progress can be replayed, but only a complete Response may authorize Tools.
- A mutating tool is not automatically retried.
- An ambiguous mutation terminates the run.
- Fresh worktree attempt retries are post-MVP.

### Tests

- Application start and stop.
- Supervised run completion.
- Worker crash conversion.
- Provider inactivity timeout.
- Tool inactivity timeout.
- Cancellation propagation.
- No automatic restart of temporary side-effecting workers.

### Complete When

- Programmatic cancellation and application shutdown stop the active owned operation.
- A hung provider or command cannot hang the VM indefinitely.
- Worker crashes become understandable terminal results.
- ExDoc explains every supervised child's purpose and restart policy.

## 6. Local WebSocket API

Detailed implementation checklist: [`PLAN-API.md`](PLAN-API.md).

### Purpose

The API is the first user-facing adapter. It converts bounded, versioned local
WebSocket commands into trusted Run Requests and converts typed Run Events and
terminals into allowlisted JSON. It lets independently implemented web, TUI, and
desktop clients share one backend contract.

The API is an adapter above Runtime, not a new owner of Agent, Tool, Workspace,
or Provider semantics.

### Endpoint And Command

```text
command:    mix synapse.server
health:     GET http://127.0.0.1:4848/health
websocket:  ws://127.0.0.1:4848/v1/socket
```

The MVP binds only to IPv4 loopback. It serves no frontend assets and exposes no
remote-listening switch. Browser connections must pass strict local-host Origin
validation; native clients without `Origin` are accepted only through the
loopback listener.

API startup is explicit. Ordinary library and test application startup retains the
completed Runtime tree; `mix synapse.server` enables one conditional API child
before starting the application.

### Internal Structure

```text
Synapse.API
|-- Config
|-- Supervisor
|-- SessionSupervisor
|-- RunManager
|-- RunSession
|-- Router
|-- Socket
|-- Protocol
`-- Wire

Mix.Tasks.Synapse.Server
```

```text
Synapse.Supervisor                         :one_for_one
|-- completed Workspace/Task/Runtime infrastructure
`-- Synapse.API.Supervisor [conditional]  :rest_for_one
    |-- Synapse.API.RunManager
    |-- Synapse.API.SessionSupervisor
    |   `-- RunSession [temporary, at most one active]
    `-- Bandit loopback listener
```

RunManager starts before SessionSupervisor so loss of manager state restarts the
ephemeral API run-owner layer and listener together. The listener stops first on
shutdown; Runtime and Workspace infrastructure remain available while RunSession
requests cancellation and lower owners perform bounded cleanup. Terminal delivery
is not guaranteed during application shutdown.

### Responsibilities

- Start a loopback Bandit listener through `mix synapse.server`.
- Upgrade only `/v1/socket` through WebSockAdapter.
- Decode bounded text JSON frames with string keys.
- Validate protocol version, message type, request ID, and exact payload shape.
- Assign run IDs at the server; never trust client-supplied run authority.
- Reserve at most one active run before starting a temporary RunSession.
- Make RunSession the `Runtime.start_run/3` caller and owner-only awaiter.
- Let RunManager retain the opaque Runtime handle only for non-owner cancellation.
- Keep runs alive when every WebSocket disconnects.
- Assign monotonically increasing, per-run, in-memory event sequence numbers.
- Retain bounded run projections and replay windows for process-lifetime reconnect.
- Serialize Run Events, Agent terminals, and Runtime errors through explicit
  allowlists rather than generic struct conversion.
- Coalesce subscriber wakeups and pull bounded replay batches so a slow socket
  cannot create an unbounded live-event mailbox.
- Expose one minimal health response without configuration or run content.

### Must Not

- Accept Provider modules, callbacks, Runtime options, Tool capabilities,
  supervisors, credentials, cancellation handles, or opaque Runtime values over
  the wire.
- Define or consume `TOKAMAK_API_KEY` through a frame, URL, cookie, authorization
  header, WebSocket subprotocol, or any other API credential field.
- Serialize `Runtime.Run`, Workspace Handles, Provider final responses, prompts,
  paths in errors, stacktraces, process reasons, or arbitrary structs.
- Call Provider, Tool, Agent, or Workspace directly.
- Cancel a run merely because one client disconnects.
- Claim durable replay, restart recovery, authentication, or network isolation.
- Serve or build files from `ui/web`, `ui/tui`, or `ui/desktop`.

### Wire Commands

Client message types:

```text
run.start
run.cancel
run.subscribe
ping
```

Server message types:

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

Every command uses a bounded `request_id`. The `/v1/socket` path and the envelope
both identify protocol version 1. Unknown fields and message types are rejected;
external strings are never converted to atoms.

### Runtime Ownership

```text
Socket command
  -> RunManager reserves run and starts RunSession
  -> RunSession calls Runtime.start_run/3
  -> RunSession owns Runtime.await/2 for the run lifetime
  -> RunManager retains opaque handle for Runtime.cancel/1
  -> Runtime event sink synchronously records one event in RunManager
  -> RunManager updates bounded projection and wakes subscribers
  -> RunSession confirms the terminal returned by await
```

The event sink runs in Runtime's RunServer and must return promptly. It records
through one bounded RunManager call; it never writes directly to a socket. A
RunSession remains alive without clients, so WebSocket ownership cannot orphan or
cancel a run.

### Local Capability Policy

The API constructs one fixed-shape, server-configured trusted-local Tool
capability set. Production defaults enable:

```text
fs.read:<workspace>
fs.write:<workspace>
process.exec:<workspace>
```

Capability booleans are server startup policy and are never client payload. A
client may provide prompt, absolute workspace input, an optional bounded model
selection, and optional Budget values that only lower server policy. Provider and
credential selection remain trusted server configuration.

Workspace `fs.read` and `fs.write` checks govern its file APIs. MVP
`process.exec` starts a same-user process and is not an OS filesystem sandbox;
loopback binding and Origin checks do not change that threat model.

### Replay Scope

Replay is bounded and memory-only. It survives WebSocket disconnect but not API
manager restart, application restart, host failure, or completed-run eviction.
When a requested cursor predates retained events, the server sends an
authoritative reset snapshot rather than pretending the replay is complete.

### Tests

- Configuration, loopback binding, and Origin policy.
- HTTP health, 404, method, and WebSocket upgrade behavior.
- Envelope and exact payload validation, malformed JSON, binary frames, and size
  limits.
- Explicit JSON mapping for every Run Event and terminal shape.
- RunSession ownership of `start_run/3` and `await/2`.
- Non-owner cancellation through RunManager.
- Run continuation after socket disconnect.
- Ordered sequences, reconnect replay, reset snapshots, and completed-run
  eviction.
- Slow-subscriber wakeup coalescing and bounded replay batches.
- Secret and opaque-authority exclusion from frames, errors, logs, and inspection.
- Deterministic WebSocket-to-Fake-Runtime integration and opt-in live Tokamak
  acceptance.

### Complete When

- `mix synapse.server` exposes health and the versioned loopback WebSocket.
- A protocol client can start, observe, disconnect, reconnect, cancel, and receive
  one terminal for a run without calling internal modules.
- Disconnect does not cancel the active run.
- Replay and all connection/run buffers have tested hard bounds.
- No API frame or log contains a credential or opaque host authority.
- The API can be understood and implemented from `PLAN-API.md`, LSP, and ExDoc.

## Component Connections

### Provider To Agent

```text
Agent sends: Provider Request
Provider emits: Provider Events
Provider returns: success or structured Provider Error
```

The Agent never receives Req responses or Tokamak maps.

### Agent To Tool System

```text
Agent sends: complete Tool Call + Tool Context
Tool Executor returns: paired Tool Result
```

The Agent never dispatches modules from arbitrary model strings.

### Tool System To Workspace

```text
Built-in prepares: typed request without Handle
Static Dispatcher sends: exact validated Workspace operation
Workspace returns: structured operation result
Built-in presents: paired bounded Tool Result
```

Tools never call `File`, `System`, or `Port` directly.

### Runtime To Agent

```text
Runtime starts: supervised Agent run
Runtime provides: cancellation reference, deadline, operation resources
Agent emits: Run Events and terminal result
```

Provider and Workspace receive operation resources through request context. They do not import or call Runtime. Runtime does not interpret model or tool meaning.

### Runtime To API

```text
API RunSession creates: validated Run Request + trusted Runtime policy
Runtime returns: opaque Run handle to RunSession
Runtime emits: ordered typed Run Events to RunManager
API exposes: bounded JSON projection, replay, cancellation, and terminal
```

Runtime never sees sockets or JSON. RunSession owns the Runtime await right;
RunManager may cancel using the retained opaque handle but never serializes it.

### API To Frontends

```text
Web / TUI / Desktop sends: versioned bounded commands
API sends: versioned snapshots, events, terminals, and protocol errors
```

No core component renders a frontend or depends on a UI framework. Frontends live
outside the Elixir backend under `ui/` and connect through the same protocol.

## Target Source Layout

This is a future-oriented component map, not the current filesystem. Implemented
public facades currently live at `synapse/provider.ex`, `synapse/workspace.ex`, and
`synapse/tool.ex`; Tool Call and Result live under `synapse/tool/`.

```text
lib/
  mix/tasks/synapse.server.ex
  synapse.ex
  synapse/application.ex

  synapse/contracts/
    budget.ex
    run_request.ex
    run_event.ex
    tool_call.ex
    tool_result.ex

  synapse/provider/
    provider.ex
    request.ex
    response.ex
    event.ex
    error.ex
    output_item.ex
    stream_context.ex
    tokamak.ex
    responses_codec.ex
    responses_stream.ex
    sse_decoder.ex
    fake.ex
    credentials.ex

  synapse/workspace/
    workspace.ex
    path.ex
    revision.ex
    mutation_server.ex
    process_runner.ex

  synapse/tool/
    tool.ex
    spec.ex
    context.ex
    registry.ex
    executor.ex
    read.ex
    write.ex
    edit.ex
    bash.ex

  synapse/agent/
    runner.ex
    state.ex
    context.ex

  synapse/runtime/
    runtime.ex
    run.ex
    run_server.ex
    error.ex

  synapse/api/
    config.ex
    supervisor.ex
    session_supervisor.ex
    run_manager.ex
    run_session.ex
    router.ex
    socket.ex
    protocol.ex
    wire.ex

ui/
  web/
  tui/
  desktop/
```

The `ui/` directories are separate clients, not Mix application source and not
part of Step 6 implementation. Do not create this entire tree before
implementation. Add each file only when its component step requires it.

## Build Order

The implementation order follows the dependency graph rather than feature breadth.

### Step 0: Application And Contracts

- [x] Create the supervised Mix application.
- [x] Pin Elixir and OTP versions.
- [x] Add Req and ExDoc.
- [x] Define Provider Event, Tool Call, and Tool Result.
- [x] Define Run Request, Run Event, and Budget.
- [x] Configure formatting, tests, ExDoc, and warnings-as-errors.

Proof: the application starts, contracts compile, tests and docs pass.

### Step 1: Provider

- [x] Implement SSEDecoder with deterministic fixtures.
- [x] Implement ResponsesCodec.
- [x] Implement environment credential lookup.
- [x] Implement Tokamak text streaming.
- [x] Implement normalized function-call events.
- [x] Implement Fake provider.

Proof: live Tokamak text works, function-call fixtures normalize, and provider tests need no key.

### Step 2: Workspace

- [x] Implement canonical workspace roots and path enforcement.
- [x] Implement bounded reads and revisions.
- [x] Implement MutationServer.
- [x] Implement revision-checked write and create.
- [x] Implement revision-checked exact edit.
- [x] Implement bounded process runner.
- [x] Implement cancellation and operation ownership.
- [x] Implement deterministic Fake Workspace.
- [x] Complete reliability, security, and ExDoc review.

Proof: temporary-workspace and Fake tests cover the supported operations and the
documented cooperative boundary; Workspace is complete only when
`PLAN-WORKSPACE.md` Phase 10 closes.

### Step 3: Tool System

Detailed phase gates: [`PLAN-TOOL-SYSTEM.md`](PLAN-TOOL-SYSTEM.md).

- [x] Complete Tool System Phase 0 decisions and live schema acceptance.
- [x] Implement Tool contracts, limits, and behaviour.
- [x] Implement canonical Tool specifications and static registry.
- [x] Implement Tool executor and capability dispatch.
- [x] Implement bounded deterministic result presentation and failure mapping.
- [x] Implement Read schema and adapter.
- [x] Implement Write schema and adapter.
- [x] Implement Edit schema and adapter.
- [x] Implement Bash schema and adapter.
- [x] Enforce local capabilities and paired results.
- [x] Complete deterministic Provider-to-Tool integration and live schema acceptance.
- [x] Complete Tool reliability, security, ExDoc, and comprehension review.

Proof: every tool runs through Fake calls and delegates only to Workspace.

### Step 4: Agent Loop

Detailed phase gates: [`PLAN-AGENT-LOOP.md`](PLAN-AGENT-LOOP.md).

- [x] Complete Agent Loop Phase 0 decisions and distinct Fake Provider attempt IDs.
- [x] Implement Run and Agent contracts, State, Context, and Runner boundary.
- [x] Implement full-history projection and immutable Provider turn requests.
- [x] Implement one text-only model turn.
- [x] Implement whole-batch function-call admission and output preflight.
- [x] Implement sequential tool execution.
- [x] Implement tool-result continuation.
- [x] Implement loop termination and budgets.
- [x] Implement provider retry and interruption rules.
- [x] Prove deterministic and opt-in live Agent Loop acceptance.
- [x] Complete Agent Loop reliability, security, and ExDoc comprehension review.

Proof: Fake provider completes `read -> write -> bash -> final text` deterministically.

### Step 5: Runtime

Detailed phase gates: [`PLAN-RUNTIME.md`](PLAN-RUNTIME.md).

- [x] Complete Runtime Phase 0 ownership, API, supervision, and terminal decisions.
- [x] Implement Runtime options, Run/Error, lifecycle, control-cell, and failure contracts.
- [x] Run Agent Loop under TaskSupervisor from one temporary RunServer.
- [x] Supervise temporary RunServer, Agent, and Workspace owners without restart.
- [x] Add start, await, terminal cleanup, and Agent-task monitoring.
- [x] Wire lower inactivity and absolute deadline policy.
- [x] Add cancellation propagation.
- [x] Convert worker exits to Run Events.
- [x] Prove deterministic Fake and temporary Real Runtime acceptance.
- [x] Complete Runtime reliability and security hardening.
- [x] Complete Runtime ExDoc and comprehension review.

Proof: cancellation, timeout, and worker-crash tests leave no owned operation running.

### Step 6: Local WebSocket API And Acceptance

Detailed phase gates: [`PLAN-API.md`](PLAN-API.md).

- [x] Complete API Phase 0 protocol, ownership, limits, and local-trust decisions.
- [x] Add Bandit, Plug, Thousand Island, WebSock, WebSockAdapter, and test-client
  dependencies.
- [x] Implement API configuration, conditional startup, and supervision.
- [x] Implement strict versioned protocol decoding and explicit wire encoding.
- [x] Implement RunManager bounded state, sequences, projections, and replay.
- [x] Implement RunSession Runtime ownership, await, cancellation, and settlement.
- [x] Implement WebSocket connection lifecycle and bounded subscription delivery.
- [x] Implement loopback Router, health endpoint, and Origin enforcement.
- [x] Implement `mix synapse.server`.
- [x] Prove deterministic and opt-in live end-to-end API acceptance.
- [x] Complete API reliability, security, ExDoc, and comprehension review.

Proof: an external protocol client completes the defining coding run, can
disconnect and reconnect while it runs, and all local verification passes.

## Final Acceptance Scenario

```text
1. Create a temporary fixture containing README.md.
2. Start `mix synapse.server` with `TOKAMAK_API_KEY` and `SYNAPSE_MODEL`.
3. Connect a protocol client to `ws://127.0.0.1:4848/v1/socket`.
4. Send `run.start` with the fixture path and coding prompt.
5. Observe ordered progress, disconnect, and resubscribe with the last sequence.
6. Receive one `run.terminal` and inspect the fixture independently.
```

The MVP passes when:

- Tokamak streams a valid response.
- The API assigns the run ID and accepts no credential or capability authority
  from the client.
- The model calls at least one built-in tool.
- `hello.txt` contains the expected content.
- Bash verification exits successfully.
- The model reports the actual verification result.
- WebSocket disconnect does not cancel the run.
- Reconnect returns either a complete retained replay or an explicit reset
  snapshot, never a silent sequence gap.
- The API key is never supplied to model context or child environments and never enters Synapse-generated metadata or logs; process-output event payloads are bounded but untrusted and may contain sensitive data obtained independently by the child.
- The API key, opaque Runtime Run, Provider final response, Workspace Handle, and
  trusted callbacks never enter a wire frame.
- The run terminates without an owned worker remaining.
- `mix compile --warnings-as-errors` succeeds.
- `mix format --check-formatted` succeeds.
- `mix test` succeeds.
- `mix docs` succeeds.

## MVP Non-Goals

- Detached persistent daemon, Unix socket, and operating-system service manager.
- Durable reconnect or replay across API/application restart.
- Web, TUI, and desktop client implementation.
- Serving or bundling frontend assets from Synapse.
- Remote listening, TLS, multi-user authentication, or authorization.
- SQLite persistence.
- Worktrees and automatic fresh-attempt retries.
- Concurrent runs or parallel tools.
- Subagents.
- Extensions and hot reload.
- MCP and web search.
- Direct Codex OAuth.
- Generic OpenAI-compatible profiles.
- Context compaction.
- Keychain-backed secret storage.

## After The MVP

Build outward from the stable API and Agent Loop in this order:

Detailed basic web-client checklist: [`PLAN-UI.md`](PLAN-UI.md).

1. Implement independent clients under `ui/web`, `ui/tui`, and `ui/desktop`
   against protocol v1.
2. Add append-only run persistence and durable sequence numbers.
3. Add application-restart recovery and durable reconnect.
4. Add SQLite sessions.
5. Add autonomous worktrees and fresh-attempt retries.
6. Add source-scoped capability policies.
7. Add a keychain-backed credential broker and authenticated local sessions.
8. Add OpenAI-compatible providers.
9. Add context compaction.
10. Add hot extension generations.

## Comprehension Gate

Every component is complete only when the owner can answer from LSP and ExDoc:

1. Why does this component exist?
2. What does it own?
3. What may call it?
4. What may it call?
5. Which process owns its state?
6. How does cancellation reach it?
7. How does failure leave it?
8. How is it tested without Tokamak?
9. What is intentionally deferred?

If these answers require the original AI conversation, the architecture or documentation is incomplete.
