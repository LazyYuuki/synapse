# Workspace Implementation Checklist

## Purpose

This document is the implementation checklist for the Workspace component defined in [`PLAN.md`](PLAN.md).

It turns the filesystem, mutation, process, capability, and comprehension requirements in [`../../README.md`](../../README.md) into an ordered set of coding, testing, documentation, and learning tasks.

The checklist is intentionally limited to Workspace. It does not implement model-facing Tool schemas, the Agent Loop, Provider behavior, Runtime supervision policy, worktree creation, Git integration, or CLI rendering.

## Workspace Outcome

Workspace is complete when a trusted caller can open one project root and perform bounded, structured host operations without bypassing path containment, revision checks, mutation ownership, process limits, or secret-free environment policy.

The first end-to-end proof is:

```text
Open trusted project root
  -> bounded numbered read and opaque revision
  -> revision-checked exact edit
  -> staged validation and atomic replacement
  -> bounded command in the workspace cwd
  -> cancellation and cleanup
  -> structured Workspace result or error
```

The Tool System uses the same public Workspace facade with either a real temporary workspace or a deterministic Fake handle. Tool code does not call `File`, `System`, or `Port` directly.

## Checklist Rules

- Check an item only after its implementation, focused tests, public documentation, and relevant guide updates are complete.
- Do not check a phase merely because code exists.
- Use temporary directories and synthetic environment values in tests; never point mutation tests at a user checkout.
- Never place provider credentials, absolute user paths, file contents, process environments, or unbounded command output in errors, logs, fixtures, or examples.
- Keep each phase small enough to review and understand independently.
- Do not claim that subprocess execution is sandboxed.
- Do not claim hostile-filesystem race resistance unless the required OS primitives are implemented and tested.
- If a public contract changes, update this plan and the parent architecture before continuing.

## Progress Summary

| Phase | Deliverable | Status |
| --- | --- | --- |
| 0 | Confirm boundaries, limits, and platform decisions | Complete |
| 1 | Workspace contracts and facade | Complete |
| 2 | Canonical root and path boundary | Complete |
| 3 | Opaque revisions and bounded reads | Complete |
| 4 | MutationServer ownership and serialization | Complete |
| 5 | Revision-checked atomic write and create | Complete |
| 6 | Exact edit and staged validation | Complete |
| 7 | Bounded ProcessRunner | Complete |
| 8 | Process cancellation and operation ownership | Complete |
| 9 | Deterministic Fake Workspace | Complete |
| 10 | Reliability, security, and ExDoc review | Complete |

Update this table only when a phase passes its completion gate.

## Architectural Position

```text
                    outside Workspace
                           |
                           v
                +---------------------+
                | Synapse.Workspace   |
                | public facade       |
                +----------+----------+
                           |
              +------------+-------------+
              |                          |
              v                          v
   +----------------------+    +----------------------+
   | Workspace real       |    | Workspace.Fake       |
   | filesystem/processes |    | deterministic tests  |
   +----------+-----------+    +----------------------+
              |
      +-------+--------+----------------+
      |                |                |
      v                v                v
+-------------+ +---------------+ +---------------+
| Path        | | MutationServer| | ProcessRunner |
| containment | | single writer | | MuonTrap cmd  |
+------+------+ +-------+-------+ +-------+-------+
       |                |                 |
       +----------------+-----------------+
                        |
                        v
               operating system boundary
```

## Dependency Direction

```text
Tool or another trusted caller
  -> Workspace public contracts
  -> Path / Revision / MutationServer / ProcessRunner
  -> OTP File and Port primitives

Workspace
  -X-> Tool
  -X-> Agent
  -X-> Provider
  -X-> Runtime
  -X-> CLI
```

Runtime may later create an operation context containing authority, cancellation, deadline, and activity information. Workspace consumes that context without importing Runtime, following the dependency-inverted pattern established by `Synapse.Provider.StreamContext`.

## Workspace Boundary

### Workspace Owns

- One trusted canonical project root per opened handle.
- Relative-path validation and containment.
- Symlink and special-file policy for Workspace file APIs.
- Bounded text reads and line numbering.
- Opaque file revisions.
- Revision comparison for writes and edits.
- Whole-workspace mutation serialization for the MVP.
- Staging, structural validation, and atomic file replacement.
- Process cwd validation.
- Child environment construction.
- Bounded process output, inactivity, timeout, and cancellation.
- Structured Workspace results and errors.
- Fake Workspace behavior used by higher-component tests.

### Workspace Does Not Own

- Model-visible tool schemas or tool argument decoding.
- Decisions about which operation the model intended.
- Provider requests, events, credentials, or retries.
- Conversation state or Agent Loop continuation.
- Runtime operation supervision policy.
- User-facing rendering.
- Git branches, commits, worktree creation, or repository integration.
- Language-specific validation policy unless supplied as trusted application configuration.
- Host-wide filesystem or network sandboxing.
- Arbitrary secret injection into subprocesses.
- Automatic replay of side-effecting operations.

## Architectural Invariants

- Raw model tool arguments never reach Workspace without Tool-level validation.
- Every file operation uses a validated relative path under one opened root.
- Path containment uses path-component semantics, never string-prefix checks.
- Absolute model paths, `..` traversal, NUL bytes, and outside-root targets are rejected.
- Workspace file APIs operate only on supported regular text files.
- A read returns bounded content and an opaque revision from the same observed file state.
- Replacing an existing file requires its current revision.
- Creating a file requires the explicit expectation `:missing`.
- A stale revision from another Workspace-coordinated mutation fails before commit; external writers remain subject to the documented final-check race.
- Workspace never silently merges stale model output.
- Failed pre-commit validation leaves the original file unchanged.
- Successful replacement never exposes partially written content.
- Post-commit uncertainty is reported as ambiguous rather than ordinary failure or success.
- The MVP MutationServer serializes Workspace file mutations and commands declared with unknown mutation footprint.
- Commands run only in a validated cwd under the root.
- Child processes receive an explicit environment rather than the full BEAM environment.
- Provider secrets are absent from ordinary child environments.
- Process time, inactivity, arguments, event frames, and retained output are bounded.
- Non-zero command exit is structured process data, not a Workspace transport error.
- Cancellation stops the owned direct process or Port; descendant limitations are explicit.
- Workspace performs no hidden retry of a file mutation or process execution.
- Errors contain normalized relative paths and allowlisted metadata, never absolute roots or raw content.

## MVP Threat Model

Workspace protects trusted callers from accidental escape, stale writes, partial replacement, unbounded output, and leaked inherited environment values. It coordinates all mutations that pass through the same handle.

The initial implementation does not claim to resist malicious same-user processes that race path components, mutate files outside Workspace, inspect process state, deliberately daemonize, or access the network and arbitrary absolute paths. Pure portable Elixir filesystem APIs do not provide a general `openat`/`O_NOFOLLOW` compare-and-swap boundary. Phase 0 explicitly accepted this cooperative threat model for the MVP; stronger platform-specific primitives require a later plan and proof rather than a silent fallback.

## Confirmed MVP Decisions

Phase 0 confirmed these values on July 30, 2026. Later phases may lower limits or fail closed when a platform cannot provide the recorded behavior, but they must not silently weaken these guarantees.

| Concern | Confirmed MVP decision | Reason |
| --- | --- | --- |
| Supported platforms | Initial MVP: macOS 15.7+ arm64 on APFS; Linux remains a portability target | Only the current macOS/APFS environment has passed Phase 0 spikes |
| Filesystem implementation | OTP `File` and `:file` with component-by-component `lstat` checks | The verified Elixir toolchain has no built-in realpath convenience; cooperative-race limitations remain explicit |
| Root | Trusted application input; resolve root symlinks once, then require the canonical target to exist and be a directory | Roots never come from model input; descendant symlinks remain forbidden |
| Requested paths | UTF-8 relative paths only | Removes ambiguous absolute-path policy |
| Symlinks | Reject every descendant symlink for reads, writes, edits, and process cwd | Simplest portable fail-closed policy under the cooperative threat model |
| File types | Regular files only | Excludes devices, sockets, FIFOs, and directories |
| Links and mounts | Reject files with link count other than one and reject device changes below the root | Avoids hard-link mutation surprises and mount-boundary policy ambiguity |
| Revision | Versioned SHA-256 content digest plus relative path and selected stat metadata | Stable, opaque, and conservative against metadata changes |
| Read window | 100 lines and 32 KiB default; 1,000 lines and 64 KiB hard window ceiling | Useful model context with independent line and byte bounds |
| File size | 8 MiB hard ceiling for read, write, edit, and revision hashing | Prevents unbounded whole-file operations |
| Mutation ownership | One MutationServer and one whole-workspace mutation lease | Simple deterministic MVP; per-path parallelism is deferred |
| Validation | UTF-8, file size, and exact edit match | Language and project validators are deferred until a bounded process policy can own them |
| Atomic creation | Sync a complete same-directory stage, publish with `File.ln/2`, then unlink the stage | APFS spike proves no overwrite and complete visibility |
| Atomic replacement | Sync a complete same-directory stage, preserve confirmed mode, then `File.rename/2`; no in-place fallback | APFS spike proves complete replacement visibility |
| Crash durability | Sync staged content; parent-directory crash durability is not promised by the portable MVP | Atomic visibility and crash durability are different guarantees |
| Process command | Absolute executable plus separate argument list | Avoids implicit shell parsing |
| Bash mapping | Tool explicitly selects `/bin/bash` and `-lc` | Shell risk remains visible at the Tool boundary |
| Process output | Combined ordered arbitrary-binary stream, 64 KiB default, 1 MiB hard ceiling | MuonTrap provides flow control without inventing stdout/stderr ordering |
| Process timeout | 300 seconds default, 900 seconds hard ceiling | Supports project verification while remaining bounded |
| Inactivity | 180 seconds default, 900 seconds hard ceiling | Process output, not mere existence, proves activity |
| Process arguments | 256 arguments and 64 KiB total UTF-8 argument bytes | Bounds command construction and diagnostics |
| Operation identity | 256 UTF-8 bytes | Bounds event and error correlation data |
| Event chunk | 16 KiB | Bounds synchronous sink calls before acknowledgement |
| Diagnostics | 4 KiB, 32 entries, depth 4 | Prevents errors from becoming content or environment dumps |
| Environment | Minimal allowlist with trusted startup `PATH`, isolated `HOME`/`TMPDIR`, locale, and `TERM=dumb` | Stronger than trying to enumerate every secret name |
| Process containment | MuonTrap 1.8.0 around an absolute executable and argv | Raw Port closure and owner death failed to terminate a direct child; MuonTrap passed both owner-death and timeout spikes |
| Cancellation | Terminate through MuonTrap with a 1-second TERM-to-KILL grace; document descendant escape without Linux cgroups | Direct-child cleanup is proven on macOS; process-tree sandboxing is not |
| Fake | Scripted handle behind the same facade | Lets Tool and Agent tests avoid host side effects |

### Phase 0 Feasibility Record

| Item | Verified result |
| --- | --- |
| Host | Darwin 24.6.0, macOS 15.7.7, arm64 |
| Temporary filesystem | APFS data volume |
| Toolchain | Elixir 1.20.2 and Erlang/OTP 28.5.0.3 |
| Digest | OTP `:crypto` supports SHA-256 |
| File primitives | `File.open/2`, `File.lstat/1`, `File.stat/1`, `File.ln/2`, `File.rename/2`, and `:file.sync/1` are available |
| Canonical-path helper | The verified Elixir toolchain has no built-in realpath convenience; Phase 2 owns explicit component resolution |
| Atomic replacement | A concurrent observer saw only old or complete new content; replacement preserved mode on APFS |
| No-overwrite creation | Hard-link publication preserved mode and link-count evidence, then returned `:eexist` without overwrite when present |
| Root rename | Renaming the root invalidates its old canonical pathname; an opened path-based handle must fail unavailable rather than follow the rename |
| Symlink and stat observation | `File.lstat/1` identifies live and broken descendant symlinks; `File.Stat` exposes device and link-count fields |
| Environment clearing | Port environment options can unset every inherited name and expose exactly one allowlisted synthetic value |
| Raw Port cleanup | Port close and Port-owner death leave `/bin/sleep` running on this host |
| MuonTrap cleanup | MuonTrap 1.8.0 kills the direct child on owner death and timeout |
| MuonTrap streaming | `into:` delivers binary chunks through a Collectable; version 1.8.0 documents a bounded stdio window |
| Private runtime dirs | Owner-only `HOME` and `TMPDIR` directories can be created and removed deterministically |

The feasibility tests remain in `test/workspace_phase0_test.exs` so future OTP, macOS, filesystem, or dependency changes cannot silently invalidate these assumptions. Linux, non-APFS filesystems, descendant process groups, and hostile path-swap resistance remain explicit later gates.

## Internal Modules

| Module | Purpose |
| --- | --- |
| `Synapse.Workspace` | Public facade for real and Fake handles |
| `Synapse.Workspace.OpenRequest` | Trusted root, owner, limits, and maximum access configuration |
| `Synapse.Workspace.Handle` | Opaque root-scoped backend handle |
| `Synapse.Workspace.Access` | Read, write, and process-execution authority ceiling |
| `Synapse.Workspace.Limits` | Validated file, read, mutation, and process ceilings |
| `Synapse.Workspace.OperationContext` | Authority, operation ID, cancellation, deadline, and activity data |
| Workspace path helper | Pure relative-path validation and containment helpers |
| `Synapse.Workspace.Revision` | Opaque versioned file-state identity |
| `Synapse.Workspace.ReadRequest` | Bounded read-window request |
| `Synapse.Workspace.ReadLine` | Numbered text and line-ending metadata |
| `Synapse.Workspace.ReadResult` | Numbered lines, continuation, and revision |
| `Synapse.Workspace.WriteRequest` | Revision-checked create or replacement request |
| `Synapse.Workspace.EditRequest` | Revision-checked exact replacement request |
| `Synapse.Workspace.MutationResult` | Old/new revision and bounded change metadata |
| `Synapse.Workspace.Error` | Sanitized Workspace failure taxonomy |
| Workspace mutation server | One-workspace mutation owner and lease coordinator |
| `Synapse.Workspace.ProcessSpec` | Trusted executable, argv, cwd, and lowered limits |
| `Synapse.Workspace.ProcessEvent` | Ordered bounded process lifecycle/output events |
| `Synapse.Workspace.ProcessResult` | Structured exit, cancellation, timeout, and truncation data |
| Internal ProcessRunner | Temporary owned MuonTrap command operation |
| `Synapse.Workspace.Fake` | Scripted deterministic backend |

Do not create all modules before their phase. Closely related contracts may share a source file initially, as Provider events and output items do.

## Proposed Public Boundary

```elixir
@type event_sink :: (ProcessEvent.t() -> :ok)

@spec open(OpenRequest.t()) :: {:ok, Handle.t()} | {:error, Error.t()}
@spec close(Handle.t()) :: :ok | {:error, Error.t()}

@spec read(Handle.t(), ReadRequest.t(), OperationContext.t()) ::
        {:ok, ReadResult.t()} | {:error, Error.t()}

@spec write(Handle.t(), WriteRequest.t(), OperationContext.t()) ::
        {:ok, MutationResult.t()} | {:error, Error.t()}

@spec edit(Handle.t(), EditRequest.t(), OperationContext.t()) ::
        {:ok, MutationResult.t()} | {:error, Error.t()}

@spec run(Handle.t(), ProcessSpec.t(), event_sink(), OperationContext.t()) ::
        {:ok, ProcessResult.t()} | {:error, Error.t()}
```

Every operation returns tagged structured data. No bang variants are part of the public MVP, and no caller parses terminal prose to determine success.

### Open Request And Handle

```elixir
%Synapse.Workspace.OpenRequest{
  root: trusted_root,
  owner: self(),
  limits: %Synapse.Workspace.Limits{},
  access: %Synapse.Workspace.Access{read: true, write: true, exec: true}
}
```

`root`, `limits`, and the maximum access ceiling are trusted application configuration, not model input. The returned handle is opaque and contains only backend identity required by the facade. Ordinary inspection must not reveal the absolute root, server state, references, environment, or open resources.

The opening owner is monitored. `close/1` is idempotent after confirmed backend
death. A live close authenticates the exact token, limits, and Access retained by
the backend, so an altered same-token Handle cannot close the original. Owner death
closes the workspace, releases mutation ownership, and cancels an active process
operation. Runtime may later supervise the same lifecycle without changing
operation contracts.

### Limits

```elixir
%Synapse.Workspace.Limits{
  max_path_bytes: 4_096,
  max_operation_id_bytes: 256,
  max_file_bytes: 8_388_608,
  default_read_lines: 100,
  max_read_lines: 1_000,
  default_read_bytes: 32_768,
  max_read_bytes: 65_536,
  max_diff_bytes: 32_768,
  max_process_arguments: 256,
  max_process_argument_bytes: 65_536,
  max_process_event_bytes: 16_384,
  max_process_events: 4_096,
  default_process_output_bytes: 65_536,
  max_process_output_bytes: 1_048_576,
  default_process_inactivity_ms: 180_000,
  max_process_inactivity_ms: 900_000,
  default_process_timeout_ms: 300_000,
  max_process_timeout_ms: 900_000,
  kill_grace_ms: 1_000,
  max_environment_entries: 512,
  max_environment_name_bytes: 256,
  max_environment_value_bytes: 32_768,
  max_diagnostic_bytes: 4_096,
  max_diagnostic_entries: 32,
  max_diagnostic_depth: 4,
  max_concurrent_operations: 64,
  max_fake_script_entries: 1_024
}
```

Limits are validated at open time. A request may lower its read or process limits but cannot exceed the handle's maximums.

| Limits | Protected resource and accounting |
| --- | --- |
| Path and operation ID | Bound component traversal, retained correlation data, events, and errors by UTF-8 bytes |
| File size | Bounds whole-file read, hashing, staging, edit, and diff input memory |
| Read lines and bytes | Independently protect model attention and retained window memory |
| Diff bytes | Bounds mutation-result memory and later model-visible change context |
| Argument count and bytes | Bounds command construction, Port options, and error diagnostics before spawn |
| Event count and output bytes | Bounds scripted event lists, each synchronous sink call, MuonTrap collection, retained result, and mailbox pressure |
| Inactivity and timeout | Bounds silent and total external-process lifetime independently |
| Environment entries and names | Count every inherited `{name, nil}` unsetting entry plus each allowlisted addition; inherited values are never copied into the child option list |
| Environment values | Bounds only trusted allowlisted values such as `PATH`, locale, `HOME`, and `TMPDIR` |
| Diagnostics | Bounds recursively retained safe metadata; file content, process output, environment values, and exceptions remain forbidden |
| Concurrent operations | Bounds retained shared permits, process coordinators, and Fake operation leases |
| Fake script entries | Bounds source-ordered test expectations retained by one Fake handle |

The 512-entry environment ceiling applies to the complete option list passed to the command wrapper. A host environment above that ceiling fails process start closed rather than inheriting undeclared values.

### Operation Context And Access

```elixir
%Synapse.Workspace.OperationContext{
  operation_id: "operation-123",
  cancel_ref: cancel_ref,
  deadline: absolute_monotonic_deadline,
  activity_sink: activity_sink,
  access: %Synapse.Workspace.Access{read: true, write: false, exec: false}
}
```

The context can only reduce the access ceiling established when the handle was opened. `read` and `write` govern Workspace file APIs only. MVP `exec` grants a same-user child ambient host authority and cannot preserve OS-level `write: false`; callers must not issue `exec` when filesystem write denial is required. Workspace checks access even when called directly, but this in-VM data is an operational policy boundary rather than protection from malicious BEAM code. The future shared capability system may replace `Access` without changing path, mutation, or process semantics.

Cancellation uses `{:cancel, cancel_ref}` sent to the process executing a read or process operation. Deadlines use `System.monotonic_time(:millisecond)` or `:infinity`. Accepted write and edit operations are bounded, execute to a known result inside MutationServer, and are not cancellable after admission in the MVP. The activity sink has type `(OperationContext.t() -> :ok)` and is synchronous. Process activity follows acceptance of a process event; read activity is reported once after the bounded read has successfully advanced or completed; mutation activity is reported only after a known terminal mutation result. Sink returns other than `:ok`, exceptions, or throws stop a read or active process safely.

### Read Request And Result

```elixir
%Synapse.Workspace.ReadRequest{
  path: "lib/synapse.ex",
  start_line: 1,
  line_count: 100,
  max_bytes: 32_768
}
```

`start_line` is one-based. A successful result is:

```elixir
%Synapse.Workspace.ReadResult{
  path: "lib/synapse.ex",
  revision: revision,
  lines: [
    %Synapse.Workspace.ReadLine{
      number: 1,
      text: "defmodule Synapse do",
      ending: :lf,
      truncated: false
    }
  ],
  next_line: 101,
  file_bytes: 4_200
}
```

Line text excludes the terminator; `ending` is `:lf`, `:crlf`, or `:none`. `next_line` is `nil` at EOF. One oversized line is clipped only on a valid UTF-8 boundary and marked truncated. The clipped suffix is intentionally unavailable in the MVP, and `next_line` advances to the next physical line rather than continuing by byte offset. The result contains a normalized relative path, never the absolute root.

The implementation records identity and selected metadata before reading, hashes the complete bounded file, and rechecks identity and metadata afterward. A detected concurrent change returns conflict instead of a mixed read result. This is best-effort under the cooperative race model. Files exceeding `max_file_bytes`, invalid UTF-8 files, and unsupported file types return structured errors.

### Revision

```text
wsr1.<opaque-versioned-value>
```

A revision represents one observed state of one relative file in one opened workspace. The confirmed `wsr1` representation is unpadded base64url of an HMAC-SHA-256 produced with a random 32-byte per-handle key. Its versioned canonical payload includes:

- Revision version and normalized relative path.
- `major_device`, `minor_device`, `inode`, `type`, and `links` from `File.Stat`.
- File `size`, permission `mode`, `mtime`, and `ctime` at the precision returned by OTP.
- SHA-256 digest of complete file content.

Revisions are opaque, redacted under inspection, and compared only through `Synapse.Workspace.Revision`. They are stale-write guards, not durable history, globally monotonic versions, or proof against a malicious external race.

### Write Request

```elixir
%Synapse.Workspace.WriteRequest{
  path: "lib/example.ex",
  content: "defmodule Example do\nend\n",
  expected_revision: :missing
}
```

`expected_revision` is either `:missing` or an opaque `Revision` from a prior read:

- `:missing` creates only when the destination remains absent.
- A revision replaces only the matching existing regular file.
- Blind replacement is unsupported.
- Parent directories must already exist.
- Content must be valid UTF-8 and within `max_file_bytes`.
- Existing replacements preserve permission bits. A staged new file uses OTP's `0o666` creation mode filtered by the trusted process umask; hard-link publication preserves that resulting mode. Ownership, ACLs, and extended attributes are deferred.

### Edit Request

```elixir
%Synapse.Workspace.EditRequest{
  path: "lib/example.ex",
  old_text: "def old",
  new_text: "def new",
  expected_revision: revision
}
```

`old_text` must be non-empty and occur exactly once after revision validation. Zero matches and multiple matches are conflicts. Matching, replacement, validation, and staging happen inside the mutation owner so another Workspace mutation cannot interleave.

### Mutation Result

```elixir
%Synapse.Workspace.MutationResult{
  operation_id: "operation-123",
  path: "lib/example.ex",
  previous_revision: old_revision,
  revision: new_revision,
  bytes_written: 43,
  changed: true,
  diff: bounded_unified_diff,
  diff_truncated: false
}
```

Creation uses `previous_revision: :missing`. A no-op replacement reports `changed: false` and zero bytes written. Diff data is bounded separately; truncation is explicit. The future durable mutation journal remains outside the MVP.

### Process Spec, Events, And Result

```elixir
%Synapse.Workspace.ProcessSpec{
  executable: "/bin/bash",
  arguments: ["-lc", "mix test"],
  cwd: ".",
  inactivity_ms: 180_000,
  timeout_ms: 300_000,
  max_output_bytes: 65_536,
  mutation: :unknown
}
```

Rules:

- `executable` is an absolute trusted application value, not a model-selected arbitrary path.
- Arguments are passed separately with no implicit shell parsing.
- NUL bytes and unreasonable argument counts or bytes are rejected.
- `cwd` is a validated relative directory under the workspace root.
- `cwd: "."` is the sole root-directory sentinel; `.` remains invalid in file paths and other cwd components.
- Stdin is closed in the MVP.
- The child environment is constructed from an allowlist.
- A request cannot raise limits above the opened handle's ceilings.
- `mutation` is `:read_only` or `:unknown`; unknown commands hold the whole-workspace mutation lease. Model-facing Bash always maps to `:unknown`. `:read_only` is reserved for trusted fixed application commands and is not OS-enforced.
- Read-only is a coordination declaration, not an OS-enforced sandbox in the MVP.

Process events are ordered synchronous observations:

```elixir
%Synapse.Workspace.ProcessEvent.Started{operation_id: "operation-124"}

%Synapse.Workspace.ProcessEvent.Output{
  operation_id: "operation-124",
  sequence: 1,
  data: "Compiling 12 files\n"
}
```

The terminal result is:

```elixir
%Synapse.Workspace.ProcessResult{
  operation_id: "operation-124",
  termination: :exited,
  exit_code: 0,
  output: "...",
  output_bytes: 120,
  truncated: false,
  elapsed_ms: 820
}
```

Event `data` and result `output` are arbitrary untrusted binaries that may contain secrets, project content, or absolute host paths. Limits count raw bytes before truncation; Workspace does not sanitize them, and Tool owns any UTF-8 replacement, escaping, redaction, persistence, or model-safe rendering. A chunk crossing the ceiling is clipped to the remaining raw-byte budget, the process is terminated, and no later output event is emitted.

`termination` is `:exited`, `:cancelled`, `:timed_out`, or `:output_limit`. Non-zero exits remain successful observations in `ProcessResult`. A Workspace error means the request or runner itself could not produce a trustworthy process result.

Cancellation and timeout do not roll back subprocess filesystem effects. Every forced stop after a `mutation: :unknown` process starts, including cancellation, timeout, output limit, sink failure, coordinator death, or runner failure, therefore returns an ambiguous Workspace error even after the direct child stops. Read-only commands may return ordinary cancelled, timed-out, or output-limit ProcessResults.

## Workspace Error Taxonomy

```elixir
%Synapse.Workspace.Error{
  kind: :conflict,
  reason: :stale_revision,
  operation: :edit,
  message: "Workspace file changed after it was read",
  operation_id: "operation-123",
  path: "lib/example.ex",
  outcome: :not_applied,
  details: %{}
}
```

| Kind | Meaning |
| --- | --- |
| `:invalid` | Invalid contract, path, encoding, command, or limit |
| `:not_found` | Root, file, parent, cwd, or executable was absent |
| `:denied` | Outside-root, traversal, symlink, permission, access, or file-type rejection |
| `:conflict` | Stale revision, wrong existence expectation, edit match conflict, or busy mutation owner |
| `:limit` | File, read, diff, argument, output, timeout, or diagnostic ceiling exceeded |
| `:cancelled` | A cancellable operation stopped before a known commit |
| `:unsupported` | Unsupported platform, filesystem behavior, or operation |
| `:io` | Classified local filesystem or process I/O failure |
| `:unavailable` | Closed handle, crashed owner, or failed runner protocol |
| `:ambiguous` | Workspace cannot prove whether a side effect committed |

`outcome` is `:not_applicable`, `:not_applied`, or `:unknown`. Errors contain only bounded messages, normalized relative paths, allowlisted reason atoms, numeric limits, and safe operation metadata. They never contain absolute roots, raw file content, staged content, child environment values, unbounded output, arbitrary exceptions, or Port messages.

## Path And Symlink Policy

The path boundary has two layers:

```text
untrusted relative path
  -> pure lexical validation
  -> join to trusted canonical root
  -> component-by-component filesystem inspection
  -> final containment recheck
  -> supported regular file or directory operation
```

Pure validation rejects:

- Empty or invalid UTF-8 paths.
- NUL bytes.
- Absolute paths.
- Empty, `.`, and `..` components.
- Paths above the configured byte ceiling.

Filesystem validation rejects outside-root resolution, symlink escape, broken links, loops, and unsupported final file types. Mutations revalidate the parent and destination inside MutationServer immediately before staging and before commit.

String-prefix containment is forbidden because `/project-other` is not inside `/project`. Path checks compare complete canonical components.

The MVP uses the selected cooperative TOCTOU model: an unrelated same-user process can potentially swap path components between portable validation and open/rename. Hostile-race resistance remains deferred until proven fd-relative platform primitives or OS isolation are adopted.

## Revision And Mutation Protocol

### Read To Mutation

```text
read securely resolved file
  -> calculate opaque revision
  -> caller proposes write or exact edit
  -> MutationServer acquires whole-workspace lease
  -> re-resolve and re-calculate current revision
  -> mismatch: reject stale without staging
  -> match: build staged content
  -> validate UTF-8 and limits
  -> write same-directory temporary file
  -> sync and recheck destination expectation
  -> atomic commit
  -> calculate committed revision
  -> release lease
```

Guarantees:

- Workspace-coordinated mutations do not interleave.
- A stale expected revision caused by an earlier Workspace-coordinated mutation never commits through Workspace.
- Failure before the commit point leaves the original unchanged.
- Successful rename exposes old or complete new content, not partial content.
- Workspace never falls back to in-place writing.
- Creation does not knowingly overwrite an existing path.
- Failure after the commit point but before confirmation is ambiguous.
- External programs bypass the lease; an external write in the final recheck-to-rename window can be overwritten under the cooperative MVP threat model.

Phase 0 selected same-directory hard-link commit as the verified portable no-overwrite creation primitive on supported APFS.

## Process Ownership

```text
operation coordinator calling Workspace.run/4
  -> temporary monitored ProcessRunner worker
  -> independent monitored Port guard
  -> MuonTrap helper and direct OS process
  -> bounded output events
  -> one ProcessResult or Workspace.Error
```

MutationServer owns the permit and starts a linked temporary process-operation
worker without blocking callbacks. `ProcessRunner` coordinates total timeout and
accepted output while an independent monitored guard owns the MuonTrap Port. Event
sinks run in monitored temporary workers, so total timeout can stop a blocked
sink. The Port worker acknowledges MuonTrap output only after the coordinator has
accepted the corresponding event and retained-output state. Side-effecting workers
are temporary and are never automatically restarted.

Phase 0 proved that raw Port close and Port-owner death do not terminate the direct child on the verified host. MuonTrap 1.8.0 is therefore required and proved direct-child cleanup for owner death and timeout. Without Linux cgroups, grandchildren and deliberately daemonized processes may still escape. Full process-tree containment requires a later platform-specific policy and remains deferred.

## Secret-Free Child Environment

Workspace constructs a new environment rather than copying `System.get_env/0` and deleting known keys.

Exact allowlist:

```text
PATH=<trusted startup path>
HOME=<private workspace runtime directory>
TMPDIR=<private workspace runtime directory>
LANG=<validated locale or C.UTF-8>
TERM=dumb
GIT_CONFIG_GLOBAL=/dev/null
GIT_CONFIG_NOSYSTEM=1
SHLVL=0
```

Everything else is absent by default, including `TOKAMAK_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, cloud credentials, GitHub tokens, SSH agent sockets, cookies, and arbitrary `*_TOKEN`, `*_SECRET`, and `*_PASSWORD` values.

At open time, Workspace creates one randomly named private runtime directory under the system temporary directory, with `home` and `tmp` children. All three are mode `0700`; their paths become child `HOME` and `TMPDIR`. A fixed `/usr/bin/env -i` launcher constructs the exact target environment. Its fixed `/bin/sh` script redirects stdin from `/dev/null` and `exec`s the absolute executable from positional argv; model text is never parsed as shell source. `SHLVL=0` is the only launcher bookkeeping entry. Workspace removes the tree after active command cleanup with bounded idempotent attempts, never as process replay.

OTP Port environment options modify an inherited environment rather than replacing it automatically. ProcessRunner enumerates every inherited variable name and passes `{name, nil}` before adding the allowlisted values. Tests assert the complete child key set, not only selected secret names.

This reduces accidental inheritance; it is not host isolation. A child running as the same OS user may read accessible files, inspect permissive same-user processes, use the network, or invoke credential helpers by absolute path. Workspace MVP does not inject secrets into generic commands.

## Phase 0: Confirm Decisions And Prerequisites

### Boundary

- [x] Confirm Workspace remains lower than Tool and has no Tool, Agent, Provider, Runtime, or CLI dependency.
- [x] Confirm all file and process operations receive a Workspace-specific operation context.
- [x] Confirm the handle access ceiling and per-operation access reduction model.
- [x] Confirm Workspace is an operational host boundary, not protection from malicious BEAM code.

### Platform And Filesystem

- [x] Record initial macOS/APFS support and defer Linux portability until it passes the same acceptance suite.
- [x] Decide whether the MVP accepts a cooperative filesystem threat model or requires fd-relative native primitives.
- [x] Confirm root existence, directory, symlink, rename, and permission rules.
- [x] Confirm the exact descendant symlink policy for reads and mutations.
- [x] Confirm hard-link, mount crossing, special-file, and broken-link behavior.
- [x] Confirm the APFS atomic no-overwrite creation strategy.
- [x] Confirm same-directory replacement atomicity on the supported filesystem.
- [x] Separate atomic visibility from crash durability in the recorded guarantee.

### Contracts And Limits

- [x] Confirm the public function arities and request/result structs.
- [x] Confirm the Workspace error kinds, outcomes, and ambiguity rules.
- [x] Confirm revision version, digest algorithm, metadata, root scope, and inspection policy.
- [x] Confirm default and maximum file, read, diff, path, process, timeout, and diagnostic limits.
- [x] Confirm operation-ID, argument-count, argument-byte, event-chunk, and environment entry/value accounting.
- [x] Confirm UTF-8-only MVP behavior and oversized-line handling.
- [x] Confirm structural validation for the MVP and defer project validators.

### Process Ownership

- [x] Confirm absolute executable plus separated argv as the Workspace command contract.
- [x] Confirm Bash is an explicit Tool mapping rather than implicit Workspace parsing.
- [x] Confirm arbitrary-binary combined output semantics, raw-byte accounting, and output-limit termination behavior.
- [x] Confirm the minimal environment allowlist and private `HOME`/`TMPDIR` lifecycle.
- [x] Spike raw Port and MuonTrap timeout, cancellation, caller death, and direct-child cleanup.
- [x] Adopt MuonTrap 1.8.0 and record descendant-process limitations without Linux cgroups.
- [x] Confirm no temporary side-effecting worker is automatically restarted.

### Tests And Documentation

- [x] Add `docs/plan/PLAN-WORKSPACE.md` to ExDoc extras.
- [x] Record the temporary-directory test policy.
- [x] Record the initial macOS platform gate and later Linux portability gate.
- [x] Document every accepted limitation before implementation starts.

### Learning Gate

- [x] Explain why path expansion is not the same as race-safe filesystem access.
- [x] Explain why a revision is not a lock or durable version history.
- [x] Explain atomic visibility versus crash durability.
- [x] Explain why an allowlist is stronger than deleting known secret names.
- [x] Explain the difference between a BEAM process, Port, OS process, and descendant process tree.

### Phase Complete When

- [x] No unresolved decision would change a public Workspace contract.
- [x] Every platform primitive needed by the chosen threat model has a focused spike.
- [x] Exact limits and their resource rationale are recorded.
- [x] Parent architecture and this checklist agree.

## Phase 1: Workspace Contracts And Facade

### Boundary

- [x] Define the public Workspace facade without filesystem or Port implementation.
- [x] Define real and Fake backend dispatch behind opaque handles.
- [x] Keep trusted configuration separate from model-derived operation requests.

### Code

- [x] Implement `OpenRequest`, `Handle`, `Access`, `Limits`, and `OperationContext`.
- [x] Implement read, write, edit, mutation, process, event, result, and error contracts.
- [x] Implement versioned opaque `Revision` validation and redacted inspection.
- [x] Reject unknown fields and invalid UTF-8.
- [x] Bound every contract binary, list, map, integer, timeout, and diagnostic.
- [x] Add `@moduledoc`, `@doc`, `@spec`, `@typedoc`, and `t()` for every public contract.

### Tests

- [x] Constructor success and every validation failure.
- [x] Unknown fields.
- [x] Limit ceiling rejection.
- [x] Handle and revision inspection redaction.
- [x] Error diagnostic bounding.
- [x] Contract structs contain no root, content, environment, Port, or backend state fields unless explicitly required.

### Documentation

- [x] Explain trusted open configuration versus operation input.
- [x] Explain who creates and consumes every request, result, event, and error.
- [x] Document outcome semantics for not-applied versus ambiguous mutations.
- [x] Add a text-read request example without using File APIs.

### Learning Gate

- [x] Trace a read request using only Workspace contracts.
- [x] Explain why Handle and Revision are opaque.
- [x] Distinguish ProcessResult from Workspace.Error.
- [x] Explain why the MVP provides no bang APIs.

### Phase Complete When

- [x] Contracts compile with warnings as errors.
- [x] Contract tests and doctests pass.
- [x] No filesystem or process implementation exists in the contract layer.
- [x] LSP hover makes ownership and valid fields clear.

## Phase 2: Canonical Root And Path Boundary

### Root

- [x] Open and validate the trusted root once.
- [x] Require an existing readable directory.
- [x] Record canonical root identity in private backend state.
- [x] Monitor the opening owner and make close idempotent.

### Path

- [x] Implement pure relative-path validation.
- [x] Reject absolute paths, NUL, invalid UTF-8, empty components, `.`, `..`, and overlong paths.
- [x] Resolve components under the canonical root using the Phase 0 policy.
- [x] Reject outside-root targets, prefix-confusion paths, broken links, loops, and unsupported file types.
- [x] Return normalized relative paths only.
- [x] Revalidate mutable parent components at the operation boundary.

### Tests

- [x] Canonical root success and invalid roots.
- [x] Root path rename behavior.
- [x] Absolute, traversal, prefix-confusion, NUL, invalid UTF-8, and long paths.
- [x] Intermediate and final symlinks.
- [x] Outside-root and root-contained symlink cases according to policy.
- [x] Broken links and loops.
- [x] Directory, socket, FIFO, device, and hard-link policy.
- [x] Swap-race test that demonstrates the documented guarantee and limitation.

### Documentation

- [x] Add a path-resolution diagram.
- [x] Document every symlink and file-type rule.
- [x] Explain the cooperative or hostile-race threat model honestly.
- [x] Document why paths in errors remain relative.

### Learning Gate

- [x] Walk through one traversal and one symlink escape.
- [x] Explain why string-prefix checks fail.
- [x] Explain why final-component no-follow checks may be insufficient.
- [x] Identify the exact point at which an OS path becomes trusted for the chosen MVP guarantee.

### Phase Complete When

- [x] No temporary-workspace test can access an outside sentinel through Workspace file APIs.
- [x] Path parsing and retained state are bounded.
- [x] Unsupported path behavior fails closed.
- [x] Workspace makes no stronger race-resistance claim than tests prove.

## Phase 3: Opaque Revisions And Bounded Reads

### Revisions

- [x] Implement the versioned SHA-256 revision algorithm confirmed in Phase 0.
- [x] Scope revisions to workspace and normalized relative path.
- [x] Include selected file identity and metadata conservatively.
- [x] Calculate content and revision from one opened/observed file state.
- [x] Reject malformed, cross-workspace, and wrong-path revisions.

### Reads

- [x] Implement one-based line windows.
- [x] Preserve LF, CRLF, and no-final-newline metadata.
- [x] Enforce file, line-count, and returned-byte limits independently.
- [x] Clip one long line only on a valid UTF-8 boundary.
- [x] Return continuation with `next_line` or `nil` at EOF.
- [x] Record pre/post identity and metadata and reject detected concurrent changes.
- [x] Return only normalized relative paths.
- [x] Check cancellation and deadline during bounded work where practical.

### Tests

- [x] Empty and one-line files.
- [x] LF, CRLF, mixed endings, and no final newline.
- [x] Default, lowered, and maximum windows.
- [x] Long-line clipping and valid UTF-8 boundaries.
- [x] Document and test that a clipped suffix is unavailable and continuation advances to the next physical line.
- [x] File too large, invalid UTF-8, and non-regular file.
- [x] Revision changes after content, metadata, or inode replacement according to policy.
- [x] Same content at different path and cross-handle revision rejection.
- [x] Read activity, cancellation, deadline, and closed handle.

### Documentation

- [x] Document line numbering and continuation semantics.
- [x] Add a bounded read example with a revision.
- [x] Explain the revision fields without exposing representation details.
- [x] State what a revision proves and does not prove.

### Learning Gate

- [x] Explain the interaction between file, line, and byte limits.
- [x] Trace a revision from read result to later mutation request.
- [x] Explain why a cryptographic digest is used instead of a VM hash.
- [x] Explain why revision comparison is not filesystem compare-and-swap.

### Phase Complete When

- [x] Every successful read is bounded, numbered, and revisioned.
- [x] No read result exposes the absolute root.
- [x] Revision behavior is deterministic and documented.
- [x] Temporary-workspace read tests pass on supported platforms.

## Phase 4: MutationServer Ownership And Serialization

### Ownership

- [x] Start one MutationServer for each real opened handle.
- [x] Give the opening owner explicit lifecycle responsibility.
- [x] Use temporary restart semantics; never replay after a server crash.
- [x] Keep root identity, revision scope, lease state, and mutation metadata private.
- [x] Reject invalid and closed handles structurally.

### Serialization

- [x] Serialize writes, edits, and unknown-footprint process leases.
- [x] Avoid arbitrary callback APIs that could bypass mutation invariants.
- [x] Keep no Workspace-owned waiter queue; rely on the sequential Tool Executor for normal admission and document concurrent mailbox flooding as outside the in-VM threat model.
- [x] Monitor lease holders and release ownership on caller death.
- [x] Define read behavior while an unknown mutation lease is active.

### Tests

- [x] One server per handle.
- [x] Non-overlap and serialization of concurrent mutation requests without assuming cross-sender arrival order.
- [x] Caller death before acquisition and while holding a lease.
- [x] Server close with queued callers.
- [x] Server crash has no automatic restart or mutation replay.
- [x] Invalid handle token and cross-handle calls.
- [x] Busy behavior for concurrent direct callers.

### Documentation

- [x] Add an ownership and process-lifecycle diagram.
- [x] Explain why GenServer owns mutations but pure validation remains outside it.
- [x] Document whole-workspace serialization as an MVP simplification.
- [x] Explain future per-path leases without implementing them.

### Learning Gate

- [x] Identify which process owns every mutable Workspace field.
- [x] Explain why a temporary side-effecting child must not restart.
- [x] Trace caller death to lease cleanup.
- [x] Explain why server serialization cannot coordinate external editors.

### Phase Complete When

- [x] No abandoned Workspace lease remains after caller or server termination.
- [x] Concurrent Workspace mutations never overlap; committed order follows server receipt order.
- [x] No side-effecting request is automatically replayed.
- [x] Runtime can later supervise the same server contract without Workspace importing Runtime.

## Phase 5: Revision-Checked Atomic Write And Create

### Mutation Protocol

- [x] Require `:missing` for creation and Revision for replacement.
- [x] Re-resolve the destination and calculate current state inside MutationServer.
- [x] Reject stale and wrong-existence expectations before commit.
- [x] Validate UTF-8 and total file size.
- [x] Stage in the destination directory using a unique bounded name.
- [x] Write complete content and verify bytes.
- [x] Apply confirmed permission policy.
- [x] Sync the staged file where supported.
- [x] Recheck destination expectation immediately before commit.
- [x] Commit with the confirmed atomic replace or no-overwrite primitive.
- [x] Calculate and return the committed revision.
- [x] Clean stage files on every pre-commit path.
- [x] Return ambiguous after uncertain post-commit failure.
- [x] Check cancellation before mutation admission; once accepted, run the bounded file mutation to a known result.

### Tests

- [x] Create missing file.
- [x] Reject create when destination exists.
- [x] Replace with current revision.
- [x] Reject stale, wrong-path, cross-handle, and malformed revisions.
- [x] No-op replacement.
- [x] File and diff size limits.
- [x] Permission behavior.
- [x] Inject failure before stage, during write, validation, sync, commit, and confirmation.
- [x] Old-or-complete-new observer test; never partial content.
- [x] Stage cleanup.
- [x] External mutation race classified according to the documented guarantee.
- [x] Cancellation before admission and ignored-after-admission file mutation semantics.

### Documentation

- [x] Add an atomic mutation sequence diagram.
- [x] Mark the exact commit point.
- [x] Document atomic visibility and durability separately.
- [x] Document stale, not-applied, and ambiguous outcomes with examples.
- [x] Document why accepted file mutations are non-cancellable in the MVP.

### Learning Gate

- [x] Explain why in-place writing is forbidden.
- [x] Explain why a stage belongs in the destination directory.
- [x] Identify failures that are safely not applied versus ambiguous.
- [x] Explain why blind mutation retry is unsafe.

### Phase Complete When

- [x] Successful mutation returns old/new revisions and bounded diff data.
- [x] Every pre-commit failure preserves the original.
- [x] Creation never knowingly overwrites an existing file.
- [x] No handled failure leaves a stage file.
- [x] Uncertain commit state is never reported as ordinary success or failure.

## Phase 6: Exact Edit And Staged Validation

### Edit

- [x] Require a current revision and non-empty `old_text`.
- [x] Count exact byte-sequence matches inside MutationServer.
- [x] Reject zero and multiple matches distinctly.
- [x] Replace exactly one match without regex or fuzzy semantics.
- [x] Detect no-op replacement explicitly.
- [x] Generate bounded change metadata and unified diff.

### Validation

- [x] Always validate UTF-8 and file-size invariants.
- [x] Ensure validation happens before the commit point.
- [x] Keep the original unchanged on validation failure.

### Tests

- [x] One exact match.
- [x] Zero matches.
- [x] Multiple and overlapping matches.
- [x] Empty old text.
- [x] Replacement with empty new text.
- [x] Invalid UTF-8 request/source rejection and generated-size failure.
- [x] Stale revision before matching.
- [x] Diff bounds and truncation.
- [x] Original unchanged on every rejected edit.

### Documentation

- [x] Add a complete read-edit example.
- [x] Explain exact matching and why fuzzy merge is absent.
- [x] Explain structural versus language-specific validation.
- [x] Document how stale callers recover by rereading.

### Learning Gate

- [x] Explain why exact-once matching is safer than first-match replacement.
- [x] Explain why stale model output is not automatically merged.
- [x] Identify which validation belongs to Workspace versus Tool or project policy.
- [x] Trace failed structural validation to unchanged original content.

### Phase Complete When

- [x] Edit behavior is deterministic and revision-checked.
- [x] Zero, multiple, stale, and validation failures are distinct structured errors.
- [x] No failed edit exposes partial content.
- [x] Tool can later format the bounded diff without reading raw filesystem state.

## Phase 7: Bounded ProcessRunner

### Contract And Start

- [x] Validate executable, argv, cwd, limits, and mutation declaration.
- [x] Resolve cwd inside the workspace root.
- [x] Start an absolute executable with separated arguments.
- [x] Close stdin.
- [x] Construct the explicit environment allowlist.
- [x] Enumerate and unset every inherited environment name before adding allowlisted values.
- [x] Use a temporary monitored worker; do not block MutationServer callbacks.
- [x] Acquire the whole-workspace lease for `mutation: :unknown`.

### Streaming And Result

- [x] Emit Started before output.
- [x] Emit bounded Output chunks in observed order.
- [x] Apply synchronous event-sink backpressure.
- [x] Bound retained and emitted output under one accounting policy.
- [x] Terminate on hard output limit rather than ignoring an unlimited producer.
- [x] Return exit code, output bytes, elapsed time, termination, and truncation.
- [x] Treat non-zero exit as structured process result.
- [x] Release mutation lease after terminal result and direct-child cleanup.

### Tests

- [x] Correct cwd.
- [x] Executable and argument boundaries without shell splitting.
- [x] Explicit Bash mapping in test caller.
- [x] Empty, normal, non-zero, and signal exit.
- [x] Small chunks, UTF-8 splits, invalid output bytes, and output ceiling.
- [x] Event ordering, sink rejection, sink exception, and slow-sink backpressure.
- [x] Minimal environment snapshot.
- [x] Exact child environment key-set assertion.
- [x] Synthetic Tokamak, OpenAI, cloud, GitHub, and SSH secrets are absent.
- [x] Private HOME and TMPDIR behavior.
- [x] Read-only versus unknown mutation lease behavior.

### Documentation

- [x] Add argv and explicit Bash examples.
- [x] Add an environment allowlist table and limitations.
- [x] Document process output as bounded but untrusted and potentially sensitive.
- [x] Explain Port ownership and output accounting.
- [x] State clearly that arbitrary commands are not sandboxed.

### Learning Gate

- [x] Explain why Workspace accepts argv rather than a shell string.
- [x] Explain why Bash remains useful but explicitly higher risk.
- [x] Explain why an allowlisted environment cannot stop file or network access.
- [x] Distinguish process exit from Workspace failure.

### Phase Complete When

- [x] Process time and output cannot grow without bounds.
- [x] Child environment contains no synthetic provider secret.
- [x] Commands run in the validated workspace cwd.
- [x] No `System.cmd/3` call hides streaming or cancellation ownership.
- [x] Process workers never automatically restart.

## Phase 8: Process Cancellation And Operation Ownership

### Lifetime

- [x] Enforce absolute deadline and output inactivity independently.
- [x] Treat accepted output as activity; process existence alone is not activity.
- [x] Honor only the matching cancellation reference.
- [x] Stop the owned MuonTrap command on cancellation, timeout, output limit, sink failure, or coordinator death.
- [x] Apply a bounded graceful-stop period where the selected primitive supports it.
- [x] Escalate termination according to the Phase 0 process policy.
- [x] Return exactly one terminal ProcessResult or Workspace.Error.
- [x] Emit no event after terminal return.
- [x] Release the mutation lease on every terminal path.

### Ambiguity

- [x] Return ordinary cancelled/timed-out/output-limit ProcessResult for declared read-only commands.
- [x] Treat interrupted unknown-footprint commands as potentially ambiguous mutations.
- [x] Treat sink failure, coordinator death, runner failure, and output limit after unknown process start as ambiguous.
- [x] Never replay a cancelled or timed-out process automatically.
- [x] Document direct-child, grandchild, daemon, VM-kill, and platform limitations.

### Tests

- [x] Cancellation before start, during output, and after process exit race.
- [x] Inactivity and absolute timeout.
- [x] Output limit termination.
- [x] Event sink rejection and exception.
- [x] Operation coordinator death.
- [x] Worker and Port exit normalization.
- [x] Mutation lease release on every path.
- [x] No owned direct process remains in a healthy VM.
- [x] Descendant behavior test that proves or documents the selected limitation.
- [x] At most one terminal result and no post-terminal event.

### Documentation

- [x] Add a cancellation and terminal sequence diagram.
- [x] Explain operation coordinator, worker, Port, and OS process ownership.
- [x] Add failure, cancellation, timeout, and ambiguity examples.
- [x] Document what Runtime will later own without implying it exists now.

### Learning Gate

- [x] Trace a cancellation message to terminal cleanup.
- [x] Explain inactivity versus absolute deadline.
- [x] Explain why closing a Port may not kill descendants.
- [x] Explain why interrupted unknown mutation is ambiguous.

### Phase Complete When

- [x] Healthy-VM cancellation leaves no owned direct operation running.
- [x] No terminal race duplicates results or leaks leases.
- [x] Every timeout and cancellation reports actual mutation uncertainty.
- [x] Process limitations are stated rather than hidden.

## Phase 9: Deterministic Fake Workspace

### Script Contract

- [x] Define expected read, write, edit, and run entries with normalized structs.
- [x] Return an opaque Fake handle through the same Workspace facade.
- [x] Consume script entries once in source order.
- [x] Compare exact normalized requests and operation contexts where relevant.
- [x] Emit process events synchronously in source order.
- [x] Return scripted results and errors.

### Failure Cases

- [x] Unexpected operation.
- [x] Exhausted script.
- [x] Scripted stale, denied, timeout, and ambiguous errors.
- [x] Cancellation during event emission without sleeping.
- [x] Event-sink rejection.
- [x] Remaining-operation assertion.

### Tests

- [x] Facade behavior with real and Fake handles.
- [x] Deterministic operation order.
- [x] Exact request expectation.
- [x] Multi-operation read-edit-run script.
- [x] Cross-process use by operation ID or owned handle.
- [x] Cancellation and deadline.
- [x] Exhausted script.
- [x] Fake contains no File, System, Port, or environment access.

### Documentation

- [x] Explain why Fake belongs inside Workspace.
- [x] Add complete read-edit-run and failure examples.
- [x] Explain what Fake cannot prove about paths, filesystems, and processes.
- [x] Keep scripts readable enough to specify Tool behavior.

### Learning Gate

- [x] Write a complete Fake script without native implementation knowledge.
- [x] Explain why real temporary-workspace tests remain necessary.
- [x] Explain the difference between a Fake Workspace and a fake Port adapter.

### Phase Complete When

- [x] Tool can be tested without filesystem or process side effects.
- [x] Fake and real operations use the same public request/result contracts.
- [x] Fake tests run deterministically under `async: true`.
- [x] ExDoc and test names make script behavior understandable.

## Phase 10: Reliability, Security, And ExDoc Review

### Limits And Failure Injection

- [x] Bound every path, file, line, diff, argument, environment, event, output, diagnostic, and timeout.
- [x] Confirm Workspace owns no waiter queue and document that malicious in-VM mailbox flooding is outside the MVP threat model.
- [x] Reject integer overflow and unreasonable configured limits.
- [x] Inject filesystem failure at every mutation stage.
- [x] Inject worker, server, and Port exit at every ownership stage.
- [x] Stress concurrent stale writers and lease cleanup.
- [x] Stress symlink swaps within the documented threat model.
- [x] Confirm temporary directories, staged files, processes, workers, and leases are cleaned.

### Security Review

- [x] Search all Workspace structs for absolute roots, content, environment, and raw Port fields.
- [x] Search all logging and inspection paths for file content, output, commands, and environment values.
- [x] Test with recognizable synthetic provider and cloud secrets.
- [x] Confirm errors and examples contain relative synthetic paths only.
- [x] Confirm no Tool, Agent, Provider, Runtime, or CLI import exists.
- [x] Confirm unsupported security behavior fails closed.
- [x] State explicitly that subprocesses are not sandboxed.

### Documentation

- [x] Every public module has `@moduledoc`.
- [x] Every public function has purpose-oriented `@doc` and `@spec`.
- [x] Every public struct has `t()` and documented fields.
- [x] Opaque handles and revisions explain lifecycle and inspection.
- [x] Add error taxonomy and limits tables.
- [x] Add root/path, mutation, ownership, and cancellation diagrams.
- [x] Add examples for open, read, create, replace, edit, process, cancellation, and Fake.
- [x] Add Workspace modules to ExDoc groups.
- [x] Keep `PLAN.md`, README safety guidance, and implementation docs consistent.
- [x] Document all race, durability, descendant, and sandbox limitations.

### Comprehension Gate

- [x] Can the owner identify which process owns each mutable state field?
- [x] Can the owner explain where every path becomes trusted?
- [x] Can the owner trace a read into an opaque revision?
- [x] Can the owner identify the mutation commit point?
- [x] Can the owner distinguish stale, not-applied, and ambiguous?
- [x] Can the owner explain atomic visibility versus crash durability?
- [x] Can the owner trace cancellation through worker and Port cleanup?
- [x] Can the owner explain why process execution is not sandboxed?
- [x] Can the owner test Tool behavior without a real workspace?
- [x] Can the owner list all deferred Workspace capabilities?

### Phase Complete When

- [x] Reliability and security tests pass on supported platforms.
- [x] No unbounded Workspace-owned parser, retained accumulator, waiter structure, file operation, or process operation remains.
- [x] No Workspace-generated metadata, log, inspection, error, fixture, or example exposes secrets or absolute host paths.
- [x] Document process output as untrusted data that may itself contain sensitive content or host paths.
- [x] `mix docs` succeeds without Workspace warnings.
- [x] All examples and doctests pass.
- [x] Workspace can be maintained without the original design conversation.

## Test Matrix

| Layer | Primary proof | Host side effects |
| --- | --- | --- |
| Contracts | Unit tests and doctests | None |
| Path validation | Pure unit tests plus temporary roots | Temporary filesystem |
| Revisions | Deterministic file fixtures | Temporary filesystem |
| Reads | Window, encoding, and continuation tests | Temporary filesystem |
| MutationServer | Concurrent ExUnit process tests | None or temporary filesystem |
| Writes and edits | Failure injection and observer tests | Temporary filesystem |
| ProcessRunner contract | Fake adapter tests | None |
| ProcessRunner integration | Short controlled executables | Temporary processes |
| Environment safety | Synthetic secret snapshot | Temporary process |
| Cancellation | Controlled long-running process | Temporary process |
| Fake Workspace | Script contract tests | None |
| ExDoc | Documentation build and doctests | None |
| Platform acceptance | Verified macOS job; future Linux portability job | Temporary filesystem/processes |

## Original Suggested Test Layout

This historical proposal records planning intent; the current `test/` tree and
ExDoc configuration are authoritative.

```text
test/
  workspace_contract_test.exs
  workspace_path_test.exs
  workspace_revision_test.exs
  workspace_read_test.exs
  workspace_mutation_server_test.exs
  workspace_write_test.exs
  workspace_edit_test.exs
  workspace_process_runner_test.exs
  workspace_cancellation_test.exs
  workspace_fake_test.exs
  support/workspace_case.ex
  fixtures/workspace/
    text_lf.txt
    text_crlf.txt
    text_no_final_newline.txt
```

Prefer small readable fixtures and programmatically generated boundary data. Never store machine-specific absolute paths, captured environments, credentials, or opaque binary process transcripts.

## Suggested Commit Sequence

1. `Define Workspace contracts and limits`
2. `Add canonical Workspace path boundary`
3. `Implement revisioned bounded reads`
4. `Add Workspace mutation ownership`
5. `Implement revision-checked atomic writes`
6. `Add exact revision-checked edits`
7. `Run bounded workspace processes`
8. `Harden process cancellation and cleanup`
9. `Add deterministic Fake Workspace`
10. `Document and verify Workspace safety`

Each commit must compile, pass focused tests, and include documentation for its public behavior and limitations.

## Final Workspace Verification

```bash
mix compile --warnings-as-errors
mix format --check-formatted
mix test --warnings-as-errors
mix docs
mix hex.outdated
```

Platform-specific process and filesystem tests must pass on the verified macOS target. The same suite must pass on Linux before Synapse claims Linux Workspace portability.

## Workspace Definition Of Done

- [x] Phases 0 through 10 are complete.
- [x] Workspace boundary matches `PLAN.md`.
- [x] Workspace imports no Tool, Agent, Provider, Runtime, or CLI module.
- [x] Every Workspace file-API target is a validated relative path under the opened root.
- [x] Traversal, outside-root, symlink, and unsupported file-type cases follow the documented fail-closed policy.
- [x] Reads are bounded, numbered, UTF-8 validated, and revisioned.
- [x] Existing mutations require a current opaque revision.
- [x] New files require `:missing`.
- [x] Stale model output rejected by Workspace coordination is never silently merged or committed; the documented external-writer race remains.
- [x] Successful writes are atomically visible.
- [x] Pre-commit failures preserve original content.
- [x] Post-commit uncertainty is reported as ambiguous.
- [x] Commands use explicit executable and argument arrays.
- [x] Commands receive an allowlisted secret-free environment.
- [x] Process output, inactivity, absolute time, and diagnostics are bounded.
- [x] Cancellation stops the owned direct operation in a healthy VM.
- [x] No side-effecting operation is automatically replayed.
- [x] Fake and temporary-workspace tests are deterministic.
- [x] No tool implementation accesses files or processes outside Workspace.
- [x] ExDoc explains path trust, revisions, mutation ownership, process ownership, errors, limits, and security limitations.
- [x] The owner can maintain Workspace without the original design conversation.

## Deferred Workspace Work

Do not add these before the Workspace MVP is complete:

- Hostile same-user TOCTOU resistance through native fd-relative primitives or OS isolation.
- Linux support until the full path, atomicity, MuonTrap, and cancellation suite passes in Linux CI.
- Windows support.
- Autonomous worktree creation, integration, cleanup, or Git policy.
- Concurrent runs sharing one canonical root.
- Per-path parallel leases and ordered multi-file leases.
- Multi-file transactions.
- Delete, rename, copy, move, append, chmod, or directory mutation APIs.
- Binary-file reading or editing.
- Search, glob, grep, directory listing, or tree APIs.
- Stateful read cursors or byte-offset continuation inside oversized lines.
- Fuzzy edits, patch application, or automatic stale merge.
- Durable SQLite mutation journal and post-crash operation recovery.
- Automatic rollback of user checkout changes.
- ACL, ownership, extended attribute, resource fork, or hard-link preservation.
- Crash-durable cross-platform directory syncing beyond the confirmed MVP guarantee.
- Language-server or project-specific validation built into Workspace.
- PTY, interactive stdin, terminal emulation, or background process APIs.
- Separate stdout/stderr causal ordering if the selected portable runner cannot prove it.
- Full descendant process-tree cleanup, daemon reaping, cgroups, job objects, or external reaper service.
- Filesystem, network, syscall, CPU, memory, process-count, or container sandboxing.
- Credential-broker secret injection into generic commands.
- Artifact spill for process output above model-visible limits.
- Repository diff scans and mutation attribution after shell commands.
- Final shared capability-token implementation; the MVP Access contract is a temporary enforcement seam.

These features should reuse the path, revision, mutation, process, result, error, and ownership contracts established by this checklist rather than bypassing Workspace.
