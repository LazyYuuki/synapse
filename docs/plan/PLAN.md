# Synapse Minimal MVP Architecture Plan

## Goal

Build the smallest version of Synapse that can receive one local prompt, use Tokamak as its model provider, execute basic coding tools inside a workspace, and continue until the model returns a final answer.

The MVP has one concrete demonstration:

```bash
TOKAMAK_API_KEY="..." \
SYNAPSE_MODEL="..." \
mix synapse.run --cwd /path/to/project \
  "Read the project, create hello.txt, and verify its contents."
```

To complete that demonstration, Synapse needs exactly six main components:

1. Provider
2. Workspace
3. Tool System
4. Agent Loop
5. Runtime
6. CLI and Event Renderer

Everything else is either a shared data contract or a post-MVP feature.

## Architecture At A Glance

```text
+-------------------------+
| 6. CLI and Renderer     |
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
CLI
 |
 v
Runtime
 |
 v
Agent Loop
 |       |
 v       v
Provider Tool Executor
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
1. CLI creates Run Request
2. Runtime starts supervised run
3. Agent Loop creates Provider Request
4. Provider streams normalized events
5. Agent Loop treats the successful terminal Provider Response as the authority
   for final text, complete tool calls, and source order
6. Agent preflights every call; one-call Executor validates one admitted Call
7. Built-in Tool prepares one typed Workspace request without a Handle
8. Static Dispatcher calls the exact Workspace operation under reduced Access
9. Workspace returns a bounded Workspace result or error
10. Built-in Presentation creates one paired bounded Tool Result
11. Agent Loop appends paired tool output to conversation
12. Agent Loop requests the next model turn
13. Loop ends on final text or terminal failure
14. CLI renders result and chooses exit status
```

## Component Summary

| Component | Primary responsibility | Depends on |
| --- | --- | --- |
| Provider | Convert Synapse requests to Tokamak HTTP and Tokamak SSE to normalized events | Req, shared contracts |
| Workspace | Own safe access to files and local processes inside one project root | OTP, MuonTrap, shared contracts |
| Tool System | Expose model-facing tool schemas and dispatch validated calls | Workspace, shared contracts |
| Agent Loop | Own conversation state and coordinate model-tool turns | Provider, Tool System, shared contracts |
| Runtime | Supervise runs and operations; enforce cancellation and time limits | Agent Loop, Workspace, OTP, shared contracts |
| CLI and Renderer | Convert local user input into a run and run events into terminal output | Runtime, shared contracts |

## Shared Contracts

Shared contracts are not a seventh subsystem. They are small structs and types used to keep component boundaries explicit.

### Run Request

```elixir
%Synapse.Run.Request{
  id: run_id,
  prompt: prompt,
  cwd: canonical_workspace,
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

### Budget

```elixir
%Synapse.Budget{
  max_turns: 20,
  max_tool_calls: 50,
  max_wall_time_ms: 900_000,
  provider_inactivity_ms: 120_000,
  tool_inactivity_ms: 180_000,
  max_output_bytes: 64_000,
  max_provider_retries: 2
}
```

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

The model is supplied through `--model` or `SYNAPSE_MODEL`. Do not silently depend on an upstream default that can change.

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

- Accepted as a CLI argument.
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
`-- Synapse.Budget
```

For the MVP, one supervised Task can execute the loop. A dedicated GenServer is not required until Synapse needs a persistent daemon, reconnectable clients, or concurrent run control.

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
  -> provider error: evaluate retryable and output_started independently
  -> output_started: stop without transparent replay
  -> retryable and no output: apply higher-layer safe retry policy
  -> non-retryable and no output: fail with the classified error
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

### Budget Rules

- Maximum turns.
- Maximum total tool calls.
- Maximum wall time.
- Maximum provider output.
- Maximum tool output.
- Maximum safe provider retries before any output.

Budget exhaustion is a structured terminal state, not an exception or an invitation to loop again.

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
- Agent code imports no Req, File, System, or terminal-rendering modules.
- ExDoc explains state ownership, turn boundaries, context projection, and termination.

## 5. Runtime

### Purpose

The Runtime hosts the Agent Loop inside OTP. It owns supervised process lifetime, cancellation, operation timeout, and the minimal services shared by Provider and Workspace.

### Supervision Tree

```text
Synapse.Application
`-- Synapse.Supervisor
    |-- Synapse.TaskSupervisor
    `-- Synapse.Workspace.Supervisor
        `-- Synapse.Workspace.MutationServer [temporary per opened handle]
```

The tree should stay this small until a real ownership requirement appears.

### Responsibilities

- Start the application supervision tree.
- Start one supervised run Task.
- Start supervised provider and process operations where required.
- Monitor owned Tasks and ports.
- Propagate cancellation.
- Enforce operation inactivity and absolute deadlines.
- Convert unexpected worker exits into structured Run Events.
- Ensure temporary workers are not automatically restarted after side effects.

### Must Not

- Own conversation semantics.
- Parse Tokamak events.
- Define model tool schemas.
- Render user-facing text.
- Persist sessions in the MVP.

### Operation Lifecycle

```text
operation_started
  -> activity events update last_activity_at
  -> operation_completed
  -> operation_failed
  -> operation_timed_out
  -> operation_cancelled
```

Provider inactivity starts near two minutes. Tool inactivity starts near three minutes. Exact values remain configuration and must be documented.

### Retry Rules

Agent applies semantic Provider retry policy from
[`PLAN-AGENT-LOOP.md`](PLAN-AGENT-LOOP.md). Runtime owns supervised attempt
lifetime, cancellation, and deadline enforcement; it must preserve these replay
constraints rather than independently retrying a request.

- Connect, TLS, 429, and retryable 5xx failures may retry only before provider output.
- The MVP allows at most two safe provider retries.
- A partial provider stream is not replayed transparently.
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

- Ctrl-C and programmatic cancellation stop the active owned operation.
- A hung provider or command cannot hang the VM indefinitely.
- Worker crashes become understandable terminal results.
- ExDoc explains every supervised child's purpose and restart policy.

## 6. CLI And Event Renderer

### Purpose

The CLI is the first user interface. It converts trusted local arguments into a Run Request and converts Run Events into readable terminal output.

The CLI is an adapter, not the application architecture.

### Internal Structure

```text
Mix.Tasks.Synapse.Run
Synapse.CLI.Options
Synapse.TerminalRenderer
```

### Command

```text
mix synapse.run --cwd PATH --model MODEL "PROMPT"
```

### Responsibilities

- Parse `--cwd`, `--model`, and the prompt.
- Validate the workspace before starting a run.
- Create the fixed trusted-local capability set.
- Start the run through Runtime.
- Subscribe to or receive Run Events.
- Render text deltas and concise tool progress.
- Print structured failures without secrets.
- Map the terminal result to an exit code.
- Forward Ctrl-C cancellation.

### Must Not

- Call Tokamak directly.
- Execute tools.
- Read or edit project files.
- Own conversation history.
- Contain agent-loop policy.
- Accept the API key as a command-line argument.

### Local Capability Set

```text
fs.read:<workspace>
fs.write:<workspace>
process.exec:<workspace>
provider.use:tokamak-codex
secret.use:TOKAMAK_API_KEY
```

This is the target local capability vocabulary, not merely prompt instruction.
Tool Executor will validate it, and Workspace's temporary Access contract will
enforce its file/process ceiling. The current MVP Provider receives trusted local
configuration but does not yet consume capability tokens; provider and secret
capability enforcement remains a deferred credential-broker seam.

Workspace `fs.read` and `fs.write` checks govern its file APIs. MVP
`process.exec` starts a same-user process and is not an OS filesystem sandbox;
do not grant it when host-level write denial is required.

### Exit Codes

| Code | Meaning |
| --- | --- |
| `0` | Run completed with final output |
| `1` | Invalid local input or configuration |
| `2` | Provider authentication or availability failure |
| `3` | Interrupted or timed out |
| `4` | Tool or workspace failure prevented completion |
| `5` | Run budget exhausted |

### Tests

- Option parsing.
- Missing prompt, cwd, model, and API key behavior.
- Event rendering.
- Secret redaction.
- Exit-code mapping.
- Cancellation forwarding.

### Complete When

- The acceptance command can run without calling internal modules manually.
- Output clearly distinguishes model text, tool activity, and failure.
- CLI modules remain thin and fully documented.

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

### Components To CLI

```text
Agent emits Run Events
CLI Renderer consumes Run Events
```

No core component prints directly to the terminal.

## Target Source Layout

This is a future-oriented component map, not the current filesystem. Implemented
public facades currently live at `synapse/provider.ex`, `synapse/workspace.ex`, and
`synapse/tool.ex`; Tool Call and Result live under `synapse/tool/`.

```text
lib/
  mix/tasks/synapse.run.ex
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
    operation.ex

  synapse/cli/
    options.ex
    terminal_renderer.ex
```

Do not create this entire tree before implementation. Add each file only when its component step requires it.

## Build Order

The implementation order follows the dependency graph rather than feature breadth.

### Step 0: Application And Contracts

- [x] Create the supervised Mix application.
- [x] Pin Elixir and OTP versions.
- [x] Add Req and ExDoc.
- [x] Define Provider Event, Tool Call, and Tool Result.
- [ ] Define Run Request, Run Event, and Budget.
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

- [ ] Implement State and Context.
- [ ] Implement one model turn.
- [ ] Implement sequential tool execution.
- [ ] Implement tool-result continuation.
- [ ] Implement loop termination and budgets.
- [ ] Implement provider retry and interruption rules.

Proof: Fake provider completes `read -> write -> bash -> final text` deterministically.

### Step 5: Runtime

- [ ] Run Agent Loop under TaskSupervisor.
- [ ] Add operation lifecycle and monitoring.
- [ ] Add inactivity and absolute deadlines.
- [ ] Add cancellation propagation.
- [ ] Convert worker exits to Run Events.

Proof: cancellation, timeout, and worker-crash tests leave no owned operation running.

### Step 6: CLI And Acceptance

- [ ] Implement Mix task and option parsing.
- [ ] Implement terminal renderer.
- [ ] Implement exit-code mapping.
- [ ] Add deterministic fixture project.
- [ ] Add opt-in live Tokamak acceptance test.
- [ ] Complete ExDoc architecture and lifecycle guides.

Proof: the defining MVP command completes against Tokamak and all local verification passes.

## Final Acceptance Scenario

```bash
tmpdir="$(mktemp -d)"
printf '# Fixture\n' > "$tmpdir/README.md"

TOKAMAK_API_KEY="..." \
SYNAPSE_MODEL="..." \
mix synapse.run --cwd "$tmpdir" \
  "Read README.md, create hello.txt containing hello from Synapse, then run a command that verifies the file contains that exact text."
```

The MVP passes when:

- Tokamak streams a valid response.
- The model calls at least one built-in tool.
- `hello.txt` contains the expected content.
- Bash verification exits successfully.
- The model reports the actual verification result.
- The API key is never supplied to model context or child environments and never enters Synapse-generated metadata or logs; process-output event payloads are bounded but untrusted and may contain sensitive data obtained independently by the child.
- The run terminates without an owned worker remaining.
- `mix compile --warnings-as-errors` succeeds.
- `mix format --check-formatted` succeeds.
- `mix test` succeeds.
- `mix docs` succeeds.

## MVP Non-Goals

- Persistent daemon and Unix socket.
- TUI.
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

Build outward from the stable Agent Loop in this order:

1. Append-only run persistence.
2. Persistent daemon and reconnectable client.
3. SQLite sessions.
4. Autonomous worktrees and fresh-attempt retries.
5. Source-scoped capability policies.
6. Keychain-backed credential broker.
7. OpenAI-compatible providers.
8. Context compaction.
9. Hot extension generations.
10. Full-screen TUI.

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
