# Workspace Files And Bounded Processes

This guide explains the Phase 1 contracts, Phase 2 canonical root/path boundary,
Phase 3 bounded revisioned reads, Phase 4 MutationServer ownership, and Phase 5
revision-checked atomic whole-file writes, plus Phase 6 exact edits. The real
backend opens and validates an APFS root, reads bounded UTF-8 regular files, and
creates, replaces, or exactly edits complete files. Phases 7 and 8 add bounded
project commands with separated argv, a minimal environment, streaming output,
cancellation, inactivity, absolute deadlines, and operation ownership. Phase 9
adds the deterministic scripted Fake Workspace used by side-effect-free Tool tests. A fixed
MuonTrap-contained `/bin/df -t apfs` support probe is the only Phase 2 child
process; it has a cleared environment, timeout, TERM-to-KILL grace, and an output
sink that retains no bytes.

## Trusted Configuration And Operation Input

`Synapse.Workspace.OpenRequest` is trusted application configuration. Runtime or a
trusted direct application/test caller supplies the root, owner PID, limits, and
maximum access. Model output must never choose or expand those values.

`ReadRequest`, `WriteRequest`, `EditRequest`, and `ProcessSpec` are operation
inputs. Tool may derive them from validated model arguments, but it cannot raise
the handle's trusted limits or access. `OperationContext` separately carries the
trusted operation ID, reduced access, cancellation reference, deadline, and
activity sink.

Constructors reject unknown fields, malformed UTF-8, unsafe lexical paths, and
values above the Workspace ceilings. The facade validates constructed structs
again because an Elixir struct can be assembled directly.

## Canonical Root

The initial supported environment is Darwin arm64 with Darwin 24.6 or later and
an APFS root. Linux, Intel macOS, older Darwin, and non-APFS roots fail closed.
The APFS probe is a fixed platform check, not a model-selected command.

Runtime or another trusted caller may provide a root containing symlinks. Workspace follows
root symlinks in OS component order, including `.` and `..` after symlink
expansion, for at most 40 links. It then requires an existing readable directory
and stores its canonical pathname plus device, inode, and type identity in the
private MutationServer process. Changing the original root-link pathname has no effect
after opening. Renaming or replacing the canonical target pathname makes the
handle unavailable because its retained identity no longer matches.

MutationServer also retains the owner monitor, token, access, limits, and a random
32-byte revision key. The public Handle contains only the MutationServer PID, an
unguessable reference token, access, limits, and backend identity, all hidden by
opaque inspection. Owner death closes the workspace. An acknowledged close stops
the live MutationServer; repeated close after confirmed process death is idempotent.
Live close authenticates the token, limits, and Access together, just like an
operation, so an altered same-token Handle copy cannot close the original.

## Path Resolution

Model-derived operation paths are UTF-8 relative paths. They reject absolute
paths, control bytes, invalid UTF-8, overlong paths, empty components, `.`, and `..`.
The single path `.` is accepted only as a process working directory.

```text
trusted root input
  -> follow root links in OS component order (maximum 40)
  -> require readable APFS directory
  -> retain canonical root device/inode/type

relative operation path
  -> validate UTF-8, byte ceiling, and lexical components
  -> recheck canonical root identity
  -> lstat each component from the root without following descendant links
  -> require intermediate directories on the root device
  -> require final regular file, one link, and root device
     or permit only a missing final name for creation
  -> lstat observed parents and final again, outermost first
  -> recheck canonical root identity
  -> use the normalized relative path and private absolute observation immediately
```

Every descendant symlink is rejected, whether it points outside the root, points
back inside, is broken, or forms a loop. Workspace does not follow it to classify
its target. Directories, sockets, FIFOs, and devices are invalid file targets.
Regular files with multiple hard links are rejected. A device change below the
root is rejected as a mount crossing. Process working directories are the one
exception to the final regular-file rule: they must be real directories under the
same root device, and descendant symlinks remain forbidden.

Creation may observe a missing final component only after every parent exists and
passes the directory, device, and no-symlink rules. The write protocol repeats
mutable-parent and destination checks immediately before commit; the first path
validation is not a reservation.

### Traversal And Symlink Walkthroughs

For a root `/project`, the model path `../project-other/secret` is rejected when
the `..` component is parsed. Workspace never joins it and never relies on the
string prefix `/project`, which would incorrectly classify `/project-other` as a
child of `/project`.

For `/project/dependency -> /outside`, the path `dependency/config` stops when
`lstat` identifies `dependency` as a symlink. It does not matter whether the link
target is outside, inside, missing, or looping: the descendant-link policy is
always fail closed.

Checking only the final component with a no-follow operation would be
insufficient. An intermediate component can be a symlink, so the OS could follow
it before reaching an apparently regular final file. Workspace therefore checks
every component and rechecks observed identities from outermost to innermost.

### Cooperative Race Guarantee

The exact best-effort trust point is after the second component-identity pass and
the final root-identity check. Under the cooperative same-user threat model, the
private absolute observation is trusted only for the immediate host operation.
Portable Elixir APIs do not pin those components. A same-user process can swap a
directory after validation and redirect a later pathname access; the persistent
test suite demonstrates this limitation. Hostile-race resistance requires proven
fd-relative `openat`/`O_NOFOLLOW` primitives or OS isolation and is not claimed.

Errors retain only the normalized relative operation path. Absolute roots are
private backend state and add no useful recovery information for Tool or the
model, so exposing them would expand diagnostics without improving control flow.

## Bounded Reads

A successful read observes the complete file but returns only the requested line
window. These limits protect different resources:

| Limit | Purpose |
| --- | --- |
| `max_file_bytes` | Bounds descriptor reads, complete-file SHA-256 hashing, UTF-8 validation, and revision work |
| `line_count` | Bounds numbered physical lines returned to Tool and the model |
| `max_bytes` | Bounds copied line text and charges source terminator bytes for complete returned lines independently of file size |

The default window is 100 lines and 32 KiB. A request may lower it. The hard
window ceiling is 1,000 lines and 64 KiB, while the complete file ceiling is 8
MiB. Changing text outside the returned window still changes the revision because
Workspace hashes the complete file.

Line numbers are one-based. LF and CRLF terminators are excluded from `text` and
recorded as `:lf` or `:crlf`; a final unterminated line uses `:none`. A file ending
in a terminator does not gain a synthetic extra line. Empty files return no lines.

Full lines count their text and source terminator against `max_bytes`. If one
physical line crosses the remaining byte window, Workspace copies the largest
valid UTF-8 text prefix, marks that line `truncated: true`, and counts only copied
text. The ending remains metadata rather than returned source bytes. Truncation
therefore means some source bytes did not fit; for an empty CRLF line, those bytes
may be only the terminator and no text suffix is missing. Any omitted text suffix
is intentionally unavailable. `next_line` advances to the next physical line, or
is `nil` at EOF; it never continues a line by byte offset. A later request starts
at that physical line.

Returned line text is copied out of the complete-file binary, so a small window
does not retain the full file in the result. Workspace checks cancellation and an
absolute millisecond monotonic deadline while hashing and scanning. If an
activity sink is configured, exactly one synchronous notification occurs only
after path confirmation, revision creation, result validation, and a final
interruption check succeed. The trusted sink is terminal for that read; Workspace
does not perform another cancellation check after it returns.

### Read Observation

```text
resolve and revalidate normalized relative path
  -> open bounded raw descriptor
  -> compare descriptor metadata with resolved path metadata
  -> read at most max_file_bytes + 1 while hashing SHA-256
  -> compare descriptor metadata before and after the read
  -> require complete content to be UTF-8
  -> build copied numbered line window
  -> MutationServer re-resolves the relative path
  -> compare current path metadata with the descriptor observation
  -> HMAC the versioned path/metadata/content payload with the private handle key
  -> validate ReadResult and emit final activity
```

The pre/post descriptor checks detect observed size, identity, mode, timestamp,
type, and link changes. The final MutationServer check detects pathname replacement
between opening and revision creation. These remain best-effort under the same
cooperative race model: a same-user writer can change the file immediately after
the final check.

## Revisions

`wsr1` is an opaque unpadded base64url HMAC-SHA-256. MutationServer creates its random
32-byte key internally and redacts both state inspection and OTP status output.
The versioned canonical payload covers the normalized relative path, device,
inode, type, link count, size, mode, OTP mtime/ctime values, and SHA-256 digest of
the complete content.

Consequences:

- Unchanged observations through one handle and path produce the same revision.
- Content or selected metadata changes produce a different revision.
- The same bytes at another path produce a different revision.
- Another handle uses another key and therefore produces a different revision.
- Malformed, cross-handle, and wrong-path revisions fail verification.

SHA-256 is deterministic across VM processes and resistant to accidental digest
collisions; a VM hash is neither a durable representation nor suitable for a
stale-write guard. The HMAC also keeps payload details opaque and scopes the value
to one opened handle.

A revision proves only that Workspace observed and authenticated one path/file
state with its handle-local symmetric key. It is not an independently verifiable
digital signature, lock, sequence number, durable history, or filesystem
compare-and-swap.
After admission, the dedicated file-mutation handler re-resolves the path and
recomputes the current revision before staging and commit. An external writer can
still race after that portable check under the cooperative MVP model.

Tool can encode the opaque value in a model-facing read result and parse it back
without learning its payload:

```elixir
encoded = Synapse.Workspace.Revision.encode(read_result.revision)
{:ok, expected_revision} = Synapse.Workspace.Revision.parse(encoded)

{:ok, write_request} =
  Synapse.Workspace.WriteRequest.new(
    path: read_result.path,
    content: proposed_complete_content,
    expected_revision: expected_revision
  )
```

Parsing checks only canonical `wsr1` syntax. The mutation operation checks that
the revision belongs to this handle and path and still matches the file.

## Atomic Write And Create

Whole-file writes never modify the destination in place. An in-place crash could
leave a prefix of the requested content at the live path, so Workspace first
builds a complete stage beside the destination. Keeping the stage in the same
directory keeps it on the same filesystem and makes the final APFS rename or hard
link operation atomic.

```text
caller                    MutationServer / worker                    APFS
  | write(request, context)          |                                  |
  |-- cancel/deadline admission ---->|                                  |
  |<-- lease accepted ---------------|                                  |
  |                                  |-- revalidate request and path --->|
  |                                  |-- verify :missing or Revision --->|
  |                                  |-- create restrictive stage ------>|
  |                                  |-- write, chmod, verify, sync ---->|
  |                                  |-- recheck destination state ----->|
  |                                  |                                  |
  |                                  |-- File.rename(stage, target) ---->| replacement
  |                                  |             COMMIT POINT          |
  |                                  |                                  |
  |                                  |-- File.ln(stage, target) -------->| creation
  |                                  |             COMMIT POINT          |
  |                                  |-- remove creation stage --------->|
  |                                  |-- confirm complete content ------>|
  |<-- old/new revisions + diff -----|                                  |
```

Creation requires `expected_revision: :missing`. Successful `File.ln/2` is its
commit point and cannot overwrite a destination that appears in the commit
window. Replacement requires the current `Revision`; successful `File.rename/2`
is its commit point. A same-user external writer can still replace the destination
after the final check and before `rename`. Workspace may overwrite that external
write, which is an explicit consequence of the cooperative race model rather than
a filesystem compare-and-swap claim.

The empty stage is made owner-only before any content is written, receives
complete validated UTF-8 content, then receives the destination's permission bits
for replacement or the process-umask mode for creation. Ownership, ACL, and
extended-attribute preservation are deferred. An independent guard monitors the
linked mutation worker and owns cleanup on normal completion, worker death, or
MutationServer shutdown. Every normal and injected pre-commit path closes the
descriptor and retries stage
removal. If the host filesystem itself refuses unlink, cleanup is best effort;
hostile permission changes are outside the cooperative guarantee.

Atomic visibility and crash durability are separate:

- Readers see the old file or the complete new file, never an in-place prefix.
- The staged file is synced before publication.
- The portable MVP does not sync the parent directory, so survival across a host
  crash or sudden power loss is not promised.
- An ordinary protocol failure returned before successful `File.ln/2` or
  `File.rename/2` is `not_applied`.
- A confirmation failure is `outcome: :unknown`, even when inspection later
  shows the requested bytes.
- MutationServer death during any accepted file mutation is conservatively unknown
  because the caller cannot prove where the server stopped relative to commit.

For example, a stale revision and an existing destination for a `:missing` create
are conflicts with `outcome: :not_applied`; the original remains authoritative.
A post-commit confirmation failure is ambiguous. The caller must read the path
again before deciding what to do. Blind retry is unsafe because the first attempt
may have committed and another actor may have changed the file afterward.

The write lease also explains the cancellation boundary. Cancellation and an
elapsed deadline win before admission. Once MutationServer accepts a bounded file
mutation, they are ignored until the protocol reaches a known success,
`not_applied`, or conservative ambiguous result. Abandoning the caller halfway
through commit would turn a manageable interruption into an unclassified side
effect. A same-content replacement is a no-op: it retains the existing revision,
writes zero bytes, and creates no stage.

## Exact Edit And Validation

An edit carries the revision from a prior read plus non-empty `old_text` and
bounded `new_text`. MutationServer validates the revision before examining match
state, so a stale caller receives `stale_revision` rather than information about
the newer file's matches. The linked mutation worker then searches exact bytes and
stops once it can classify zero, exactly one, or multiple occurrences. Overlapping
occurrences count: editing `aa` in `aaa` is rejected as multiple rather than
silently choosing the first location.

```elixir
{:ok, read_request} =
  Synapse.Workspace.ReadRequest.new(path: "lib/example.ex")

{:ok, read_result} =
  Synapse.Workspace.read(handle, read_request, read_context)

{:ok, edit_request} =
  Synapse.Workspace.EditRequest.new(
    path: read_result.path,
    old_text: "def old_name",
    new_text: "def new_name",
    expected_revision: read_result.revision
  )

{:ok, %Synapse.Workspace.MutationResult{} = mutation} =
  Synapse.Workspace.edit(handle, edit_request, edit_context)

mutation.previous_revision == read_result.revision
```

Exactly-one matching is safer than first-match replacement because repeated model
context is common in source files. Picking the first occurrence can produce valid
UTF-8 in the wrong function while still appearing successful. Workspace does not
use regexes, fuzzy context, or language-aware merge rules. A zero match means the
proposal does not describe the observed file; multiple matches mean it does not
identify one location. Even `old_text == new_text` must prove exactly one match
before returning a no-op.

Before allocating generated content, Workspace computes the resulting byte size
and rejects a value above `max_file_bytes`. It then constructs and validates the
complete UTF-8 result before any commit, stages it through the same synced atomic
replacement protocol as `write`, and returns old/new revisions plus a separately
bounded diff. Request/source UTF-8, generated size, complete UTF-8, and exact match
cardinality are structural Workspace invariants. Elixir syntax, formatting,
project tests, and other language policy belong to Tool or a later bounded project
validator; Workspace does not pretend text validity proves program validity.

```text
current Revision fails
  -> stale_revision
  -> no matching or staging work is accepted

current Revision succeeds
  -> zero match: no_match, original unchanged
  -> multiple/overlapping: multiple_matches, original unchanged
  -> one match but generated file too large: file_too_large, original unchanged
  -> one valid result: stage, recheck Revision, atomic rename
```

A stale caller recovers by rereading, rebuilding the proposal against the new
content, and submitting the new revision. Workspace never automatically merges
stale model output. That policy keeps semantic decisions with the caller and
prevents a mechanically plausible merge from hiding intervening work.

## Bounded Project Processes

`ProcessSpec` accepts an absolute executable and a separate argument list. It does
not accept one implicit shell string, so spaces, semicolons, dollar signs, and
other shell syntax inside ordinary arguments remain literal bytes.

```elixir
{:ok, spec} =
  Synapse.Workspace.ProcessSpec.new(
    executable: "/usr/bin/printf",
    arguments: ["%s=%s", "key with space", "$(literal)"],
    cwd: ".",
    max_output_bytes: 65_536,
    timeout_ms: 300_000,
    mutation: :read_only
  )

{:ok, result} =
  Synapse.Workspace.run(handle, spec, event_sink, operation_context)
```

Bash remains useful when shell syntax is the requested feature, but the caller
must select it explicitly and declare an unknown mutation footprint:

```elixir
{:ok, bash_spec} =
  Synapse.Workspace.ProcessSpec.new(
    executable: "/bin/bash",
    arguments: ["-lc", "mix test"],
    cwd: ".",
    mutation: :unknown
  )
```

The fixed internal launcher is not a model-selected shell command. It receives
the executable and argv as positional parameters, redirects target stdin from
`/dev/null`, and `exec`s `"$@"`. `/usr/bin/env -i` builds the target environment
from this exact allowlist:

| Name | Value and purpose |
| --- | --- |
| `PATH` | Trusted path captured when the handle opens |
| `HOME` | Private per-handle `0700` home directory |
| `TMPDIR` | Separate private per-handle `0700` temporary directory |
| `LANG` | Fixed `C.UTF-8` locale |
| `TERM` | `dumb`, preventing terminal-control assumptions |
| `GIT_CONFIG_GLOBAL` | `/dev/null` |
| `GIT_CONFIG_NOSYSTEM` | `1` |
| `SHLVL` | Fixed launcher bookkeeping value `0` |

Workspace also enumerates every inherited environment name and passes explicit
unsets to the MuonTrap helper. The target's `env -i` boundary is what guarantees
the exact key set even if another BEAM process changes the VM environment between
enumeration and spawn. Provider keys, cloud credentials, GitHub tokens, SSH agent
sockets, cookies, and arbitrary secret/password variables are absent.

The trusted parent VM environment API materializes its host-owned map. Workspace
checks its count before sorting names or building Port options; inherited values
are never copied into the child option list. The configured ceiling therefore
bounds Workspace-retained environment metadata, not the host runtime's own map.

```text
Workspace.run caller
  -> MutationServer grants :read_only_process or :unknown_process permit
  -> ready/start barrier rechecks matching cancellation and absolute deadline
  -> linked process-operation worker (lifetime arbitration and terminal reply)
  -> monitored runner worker (raw output state)
  -> independent Port guard (MuonTrap Port, helper PID, cleanup confirmation)
  -> monitored event-sink worker (one synchronous callback)
  -> MuonTrap helper -> fixed launcher -> absolute target executable
```

`Started` is accepted before any `Output`. Output payloads are arbitrary binary,
not assumed UTF-8, and may be sensitive because a command can print project data.
Each event is bounded and sequences are contiguous. The coordinator records the
same accepted bytes used in `ProcessResult.output`; only then does the Port worker
acknowledge MuonTrap and reopen its native stdio window. Crossing the retained
output allowance emits only the remaining prefix, discards later bytes, and lets
the command run to natural exit. The Result reports `truncated: true`.

Natural zero, non-zero, and signal exits are successful `ProcessResult`
observations. A Workspace Error instead means start, sink, containment, access, or
coordination failed. Forced stop of a trusted `:read_only` command can return a
known timed-out result. Forced stop of `mutation: :unknown` is ambiguous because
the command may already have changed files.

Read-only process permits can coexist with reads and file mutation leases. They
are reserved for trusted fixed commands because read-only behavior is not
OS-enforced. Unknown commands hold the exclusive whole-workspace permit and block
reads and mutations until the MuonTrap helper PID has completed direct-child
cleanup. Matching cancellation, output inactivity, and a post-admission
`OperationContext.deadline` are enforced independently. Accepted Output resets the
inactivity clock; process existence and an accepted Started event do not. The
earliest total timeout or context deadline remains the absolute bound.

```text
caller               MutationServer       ProcessRunner       MuonTrap / target
  | run request             |                    |                    |
  |------------------------>| create worker      |                    |
  |<------------------------| ready              |                    |
  | recheck cancel/deadline |                    |                    |
  |------------------------>| start              | open/own Port ---->|
  |                         |                    |<------ output ------|
  |                         |                    | sink accepts        |
  |                         |                    | reset inactivity    |
  | cancel(ref)             |                    |                    |
  |------------------------>| stop ------------->| TERM, grace, KILL ->|
  |                         |                    | confirm helper DOWN |
  |<------------------------| one terminal reply |                    |
  | release permit          |                    |                    |
```

Only `{:cancel, cancel_ref}` matching the operation context can win. A cancellation
or deadline observed at the ready barrier prevents Port start; an unknown command
then reports `outcome: :not_applied`. Once started, read-only cancellation returns a
`:cancelled` ProcessResult and deadline or inactivity returns `:timed_out`. The same
interruptions are ambiguous for an unknown-footprint command. Sink failure, output
limit, runner failure, and coordinator death are likewise ambiguous after an
unknown command starts. Interrupted commands are never replayed automatically.

This is containment and accidental-secret reduction, not a sandbox. The target
runs as the same OS user and may read accessible files, write outside the
workspace, use the network, invoke absolute credential helpers, inspect other
processes, or deliberately daemonize descendants. macOS has no cgroup containment;
escaped grandchildren remain an explicit limitation.

In a healthy supported VM, terminal return waits until MuonTrap's owned helper and
direct target are down. Closing a raw Port alone would not prove that, which is why
Workspace polls the helper PID after TERM and the configured KILL escalation.
Ordinary grandchildren may receive the process-group signals, but Workspace does
not claim that guarantee: a descendant that creates a new session, daemonizes, or
is reparented may escape. An uncatchable BEAM VM or host kill also prevents cleanup
code from running. These guarantees are tested only on the supported Darwin arm64
and APFS profile; there is no macOS cgroup equivalent.

## Mutation Ownership

Each real Handle points to exactly one MutationServer. That temporary GenServer
owns every mutable Workspace field for the handle:

| Mutable field | Owner |
| --- | --- |
| Canonical root identity and normalized path scope | MutationServer |
| Random revision HMAC key | MutationServer |
| Trusted token, limits, and access ceiling | MutationServer |
| One active write, edit, or unknown-process lease | MutationServer |
| Active shared read permits | MutationServer |
| Holder monitors and active operation IDs | MutationServer |
| One linked and monitored atomic file-mutation worker | MutationServer |
| Linked bounded process coordinators and their permit references | MutationServer |
| Monitored runner workers and independent Port cleanup guards | ProcessRunner |
| Private process HOME/TMPDIR and cleanup guard | MutationServer |

Contract construction and pure lexical path validation remain outside the server
because they mutate no Workspace state. Root-dependent resolution, revision
confirmation, admission state, and dedicated write/edit messages go through the
server. Accepted file work runs in one linked worker so MutationServer can answer
reads, handle checks, and contention while retaining the exclusive lease.
MutationServer does not accept an arbitrary callback that could bypass revision,
staging, or commit invariants.

```text
opening owner
  -> Workspace.open
  -> temporary MutationServer (one per handle, never automatically restarted)
       |-- canonical root and revision key
       |-- zero or one mutation lease
       |-- zero to max_concurrent_operations shared read/read-only-process permits
       `-- temporary linked file and process workers

operation coordinator
  -> monitored admission request(operation_id, kind)
     caller owns matching cancel_ref; ProcessRunner owns accepted lifetime
  -> MutationServer receives request
       |-- malformed / wrong token: reject
       |-- conflicting owner / duplicate active ID: workspace_busy
       `-- free: monitor holder and grant opaque lease
  -> write/edit: linked worker reaches one terminal filesystem result
       while MutationServer remains responsive to reads and admission
  -> process: ready/start handshake, one terminal arbitration, helper cleanup
  -> holder releases lease

idle holder death -> monitor DOWN -> MutationServer releases ownership
accepted file holder death -> worker finishes -> MutationServer releases ownership
accepted process holder death -> stop runner -> confirm cleanup -> release ownership
normal close during active work -> reject new admission -> wait -> stop
server crash -> no restart or replay -> lease server monitors go DOWN
```

Write, edit, and `mutation: :unknown` process admissions share one
whole-workspace lease. This is deliberately simpler than per-path concurrency and
prevents Workspace-coordinated side effects from overlapping. A future design may
introduce ordered per-path leases, but the MVP has no path lock graph, waiter
ordering, or multi-file deadlock policy.

Reads use shared permits. They may overlap a file-mutation lease because the read
path performs identity/race checks and file commits are atomic. They do not
overlap an unknown-process lease: an arbitrary command may mutate files in place,
so a direct read receives `workspace_busy`. An unknown lease is also rejected
while any read permit remains active.

Admission is grant-or-busy. MutationServer retains no application waiter queue;
normal multi-call sequencing belongs to the Agent Loop, while Tool Executor
handles exactly one admitted call. Concurrent direct callers
receive an immediate conflict. The GenServer mailbox can still be flooded by
arbitrary code in the same BEAM node, which is outside the in-VM threat model.
Committed order follows server receipt/admission order, not send
order across different processes.

Normal close retains at most one bounded acknowledgment waiter. A concurrent close
caller monitors the already-closing server instead of joining a retained queue.

### Cancellation And Lifecycle

Before admission, the caller sends a monitored lease request and waits for either
the reply, matching cancellation, absolute deadline, or server DOWN. Cancellation
or deadline expiry sends an ordered withdrawal to MutationServer and does not
return until the server acknowledges that no grant remains. This prevents a late
mailbox reply from creating an orphaned lease.

After write or edit admission, matching cancellation is intentionally ignored and
the bounded mutation must reach a known result. This avoids abandoning an atomic
commit protocol halfway through. A ProcessRunner owns its permit through terminal
result and direct-child cleanup. Process admission uses a ready/start barrier so a
matching cancellation or elapsed deadline can prevent Port start. After start, the
caller forwards only matching cancellation; ProcessRunner independently arbitrates
accepted-output inactivity, total timeout, context deadline, natural exit, output
limit, and sink failure.

The opening owner is responsible for Handle lifetime. Its death stops
MutationServer and its linked file/process workers. Lease holders are monitored; idle
holder death releases a lease immediately, while an already accepted bounded file
mutation retains ownership until its worker reaches a terminal result. A normal
close similarly waits for accepted file work before its acknowledgment barrier.
An accepted process holder death requests process stop and retains the permit until
the direct child is confirmed down. Runtime owns the Agent caller process and sends
cancellation; Workspace does not implement Runtime supervision policy.
MutationServer's child specification is `restart: :temporary`: a crash is terminal
for that handle and never replays an accepted side effect. External editors and
commands that bypass Workspace do not participate in this GenServer protocol and
remain governed only by the documented cooperative filesystem checks.

## Deterministic Fake Workspace

`Synapse.Workspace.Fake` belongs inside Workspace because it implements the same
opaque Handle and facade boundary as Real. A Tool test supplies normalized
requests, contexts, events, results, and errors; it does not emulate path
resolution, file storage, or a process adapter. The facade still revalidates
access, lowered limits, event order, result correlation, and error identity.

The complete script is validated when it opens. Every entry is consumed once in
source order. An exact request/context mismatch consumes the expected entry and
returns `:unexpected_operation`; calling after the final entry returns
`:script_exhausted`. `assert_finished/1` catches tests that forgot to exercise a
planned operation.

```elixir
alias Synapse.Workspace
alias Synapse.Workspace.{
  Access, EditRequest, Fake, MutationResult, OperationContext,
  ProcessEvent, ProcessResult, ProcessSpec, ReadLine, ReadRequest,
  ReadResult, Revision
}

{:ok, access} = Access.new(read: true, write: true, exec: true)

context = fn operation_id ->
  {:ok, value} = OperationContext.new(operation_id: operation_id, access: access)
  value
end

{:ok, old_revision} = Revision.from_mac(:binary.copy(<<1>>, 32))
{:ok, new_revision} = Revision.from_mac(:binary.copy(<<2>>, 32))

read_context = context.("tool-read")
edit_context = context.("tool-edit")
run_context = context.("tool-run")

{:ok, read_request} = ReadRequest.new(path: "lib/example.ex")
{:ok, line} = ReadLine.new(number: 1, text: "old", ending: :none, truncated: false)

{:ok, read_result} =
  ReadResult.new(
    path: read_request.path,
    revision: old_revision,
    lines: [line],
    next_line: nil,
    file_bytes: 3
  )

{:ok, edit_request} =
  EditRequest.new(
    path: read_request.path,
    old_text: "old",
    new_text: "new",
    expected_revision: old_revision
  )

{:ok, edit_result} =
  MutationResult.new(
    operation_id: edit_context.operation_id,
    path: edit_request.path,
    previous_revision: old_revision,
    revision: new_revision,
    bytes_written: 3,
    changed: true,
    diff: "-old\n+new",
    diff_truncated: false
  )

{:ok, process_spec} =
  ProcessSpec.new(
    executable: "/usr/bin/true",
    mutation: :read_only
  )

started = %ProcessEvent.Started{operation_id: run_context.operation_id}
output = %ProcessEvent.Output{operation_id: run_context.operation_id, sequence: 1, data: "ok"}

{:ok, process_result} =
  ProcessResult.new(
    operation_id: run_context.operation_id,
    termination: :exited,
    exit_code: 0,
    output: "ok",
    output_bytes: 2,
    truncated: false,
    elapsed_ms: 0
  )

script = [
  Fake.expect_read(read_request, read_context, {:ok, read_result}),
  Fake.expect_edit(edit_request, edit_context, {:ok, edit_result}),
  Fake.expect_run(
    process_spec,
    run_context,
    [started, output],
    {:ok, process_result}
  )
]

{:ok, handle} = Fake.open(script)
{:ok, ^read_result} = Workspace.read(handle, read_request, read_context)
{:ok, ^edit_result} = Workspace.edit(handle, edit_request, edit_context)
{:ok, ^process_result} = Workspace.run(handle, process_spec, fn _event -> :ok end, run_context)
:ok = Fake.assert_finished(handle)
:ok = Workspace.close(handle)
```

Failures are scripted with the same `Workspace.Error` contract. Configuration
mistakes are also explicit:

```text
different request/context than next entry -> unexpected_operation; entry consumed
operation after script is empty           -> script_exhausted
assert_finished with two entries left     -> {:error, {:remaining_operations, 2}}
```

Matching cancellation or an elapsed deadline before admission leaves the entry
unconsumed. During process events, cancellation is checked between synchronous
callbacks without sleeping. Normal close rejects new operations and waits for
active entries; opening-owner death invalidates them. Scripts are owned per handle,
so async tests do not share a global operation registry.

Fake cannot prove canonical path identity, APFS behavior, symlink or hard-link
races, atomic visibility, crash durability, environment stripping, MuonTrap
termination, or descendant behavior. Those properties remain covered by Real
temporary-workspace and supported-platform tests. A fake Port adapter would test
only ProcessRunner's transport mechanics; Fake Workspace instead tests a caller's
component-level use of the complete Workspace contract.

## Contract Ownership

| Contract | Producer | Consumer |
| --- | --- | --- |
| `OpenRequest` | Runtime or trusted direct caller | Workspace real backend |
| `Handle` | Workspace real or Fake backend | Workspace facade caller |
| `OperationContext` | Runtime | Workspace backend and operation owner |
| `ReadRequest` | Tool or trusted caller | Workspace reader |
| `ReadLine`, `ReadResult` | Workspace reader | Tool or trusted caller |
| `WriteRequest`, `EditRequest` | Tool or trusted caller | MutationServer |
| `MutationResult` | MutationServer | Tool or trusted caller |
| `ProcessSpec` | Tool or trusted caller | ProcessRunner |
| `ProcessEvent.Started`, `ProcessEvent.Output` | ProcessRunner | Synchronous event sink |
| `ProcessResult` | ProcessRunner | Tool or trusted caller |
| `Error` | Workspace facade or backend | Tool, Runtime, or trusted direct caller |

## Facade Examples

Trusted application code opens a real handle with an explicit authority ceiling:

```elixir
{:ok, limits} = Synapse.Workspace.Limits.new()
{:ok, access} = Synapse.Workspace.Access.new(read: true, write: true, exec: true)

{:ok, open_request} =
  Synapse.Workspace.OpenRequest.new(
    root: trusted_absolute_project_root,
    owner: self(),
    limits: limits,
    access: access
  )

{:ok, handle} = Synapse.Workspace.open(open_request)
```

Creation is explicit; `:missing` never means blind overwrite:

```elixir
{:ok, context} =
  Synapse.Workspace.OperationContext.new(
    operation_id: "create-example",
    access: access
  )

{:ok, request} =
  Synapse.Workspace.WriteRequest.new(
    path: "lib/generated.ex",
    content: "defmodule Generated do\nend\n",
    expected_revision: :missing
  )

{:ok, mutation} = Synapse.Workspace.write(handle, request, context)
```

Replacement first reads the current handle/path-scoped revision:

```elixir
{:ok, read_request} = Synapse.Workspace.ReadRequest.new(path: "lib/generated.ex")
{:ok, current} = Synapse.Workspace.read(handle, read_request, context)

{:ok, replace_request} =
  Synapse.Workspace.WriteRequest.new(
    path: "lib/generated.ex",
    content: "defmodule Generated do\n  def value, do: 1\nend\n",
    expected_revision: current.revision
  )

{:ok, replacement} = Synapse.Workspace.write(handle, replace_request, context)
```

The process executing `Workspace.run/4` receives matching cancellation:

```elixir
cancel_ref = make_ref()

{:ok, run_context} =
  Synapse.Workspace.OperationContext.new(
    operation_id: "cancel-example",
    access: access,
    cancel_ref: cancel_ref
  )

{:ok, spec} =
  Synapse.Workspace.ProcessSpec.new(
    executable: "/bin/sh",
    arguments: ["-c", "sleep 30"],
    mutation: :read_only
  )

caller = self()

task =
  Task.async(fn ->
    Synapse.Workspace.run(
      handle,
      spec,
      fn
        %Synapse.Workspace.ProcessEvent.Started{} -> send(caller, :process_started); :ok
        _event -> :ok
      end,
      run_context
    )
  end)

receive do
  :process_started -> :ok
end
send(task.pid, {:cancel, cancel_ref})
result = Task.await(task)
```

If natural exit wins the race, `result` is the exited ProcessResult; if matching
cancellation wins after start, it is the cancelled ProcessResult. Unknown-footprint
commands return ambiguity instead. Always close the handle when its owner is done.

## Trace A Read

The caller creates contracts without using a host file API:

```elixir
{:ok, access} =
  Synapse.Workspace.Access.new(read: true, write: false, exec: false)

{:ok, context} =
  Synapse.Workspace.OperationContext.new(
    operation_id: "tool-call-42",
    access: access,
    cancel_ref: make_ref()
  )

{:ok, request} =
  Synapse.Workspace.ReadRequest.new(
    path: "lib/synapse.ex",
    start_line: 1,
    line_count: 50,
    max_bytes: 16_384
  )

# Real supplies revisioned reads; Fake supplies scripted results through the same facade.
{:ok, %Synapse.Workspace.ReadResult{revision: revision} = result} =
  Synapse.Workspace.read(handle, request, context)
```

The facade revalidates the context and request against authoritative MutationServer
access and limits, checks read access, and dispatches to its marked backend. A
successful call returns a bounded `ReadResult` containing copied numbered
`ReadLine` values and a `Revision`; the facade validates path and lowered-window
correlation before returning it.

## Opaque Values

`Handle` hides backend identity, process/reference state, limits, access, and a
token. This prevents accidental coupling to backend state inside the trusted BEAM
node; it is not protection against arbitrary code execution in that node. Ordinary
inspection redacts content-bearing contracts and backend state to reduce accidental
logging. Explicit field access and same-node memory introspection remain trusted.

`Revision` hides a canonical `wsr1` HMAC. It proves only that one Workspace
observed a particular file state. It is neither a lock nor durable history. Tool
may encode it into model-facing data and parse it back for a later checked write
or edit. The mutation backend still verifies ownership and freshness.

## Limits And Error Decisions

`Limits` bounds paths, operation IDs, complete files, read windows, diffs, argv,
process events/output/time, environment construction, diagnostic JSON, concurrent
operations, and Fake script length. Requests may lower read/process limits but
never raise the handle ceilings. The canonical defaults and accounting table live
in [PLAN-WORKSPACE.md](../plan/PLAN-WORKSPACE.md#limits).

| Error outcome | Caller action |
| --- | --- |
| `:not_applicable` | No requested mutation was relevant; handle as an ordinary operation failure |
| `:not_applied` | Workspace proves the requested mutation did not commit; correct input/state before retry |
| `:unknown` | Reconcile workspace/process effects before any retry; never replay automatically |

Kinds classify invalid input, denial, conflict, limits, cancellation, unsupported
behavior, I/O, unavailability, and ambiguity. Reasons provide stable machine data;
messages are bounded producer text, not a parsing interface. Diagnostic details
use allowlisted keys and escaped-JSON byte accounting. Ordinary Error inspection
omits message, details, path, and operation ID to reduce accidental disclosure.

## Results And Errors

`ProcessResult` is a known terminal observation. A non-zero exit is still a
successful observation. Read-only cancellation, timeout, and output-limit stops
can also be known results with bounded retained output.

`Error` means the requested Workspace operation did not produce its normal
result. `outcome: :not_applied` guarantees no requested mutation committed.
`outcome: :unknown` appears only with `kind: :ambiguous`; callers must reconcile
before retrying because the mutation or unknown-footprint command may have taken
effect. Error diagnostics use allowlisted keys, bounded JSON-compatible values,
relative paths, and fixed producer messages.

Process event `data` and ProcessResult `output` are raw untrusted child data. They
may independently contain secrets, project content, or absolute host paths.
Workspace bounds them but does not sanitize, redact, persist, or render them.

```text
read_only + matching cancel after start -> ProcessResult termination: :cancelled
read_only + inactivity/deadline         -> ProcessResult termination: :timed_out
unknown + matching cancel after start   -> Error cancelled, outcome: :unknown
unknown + inactivity after start        -> Error inactivity_timeout, outcome: :unknown
unknown + sink/runner/output failure     -> Error reason, outcome: :unknown
cancel/deadline before unknown start     -> Error reason, outcome: :not_applied
```

## Why There Are No Bang APIs

Invalid requests, missing files, stale revisions, access denial, limits,
cancellation, process failures, and ambiguous mutation outcomes are expected at
an agent boundary. They return `{:error, %Synapse.Workspace.Error{}}` so Tool and
Runtime can handle them explicitly. Exceptions are reserved for implementation
bugs and are normalized at backend dispatch rather than exposed as public control
flow.

## Deferred Capabilities

The canonical deferred list is
[PLAN-WORKSPACE.md](../plan/PLAN-WORKSPACE.md#deferred-workspace-work). It includes
hostile same-user fd-relative TOCTOU resistance, Linux/Windows portability,
worktree and Git policy, per-path/multi-file transactions, additional file APIs,
binary/search operations, fuzzy edits, durable journals, stronger metadata
preservation, PTYs, full descendant cleanup, OS sandboxing, credential injection,
artifact spill, and final shared capability tokens. New features must reuse the
existing path, revision, ownership, process, result, and error boundaries.
