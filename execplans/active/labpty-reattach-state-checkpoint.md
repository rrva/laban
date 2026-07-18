# labpty Reattach State Checkpoints

This ExecPlan is a living document maintained in accordance with `PLANS.md`
(at the repository root). Keep `Progress`, `Decision Log`, and `Validation and
Acceptance` current as work proceeds. A fresh contributor must be able to
resume from this file alone.

## Purpose / Big Picture

Laban's Background sessions mode keeps shells alive in the small `labpty`
daemon while the app is not running. The app owns the terminal parser, so a
new app process currently rebuilds a terminal by replaying the retained raw
output window. That replay is bounded by the byte ring: it can be slow, it
cannot recover parser state set before the retained window, and it can
regenerate replies to historical terminal queries.

After this plan, an attached app publishes a versioned checkpoint at
event-driven quiet and clean-detach boundaries. `labpty` remains byte-dumb: it
atomically owns and renames an opaque sidecar file, but it never interprets
cells, modes, escape sequences, or other terminal state. On reattach, the app
accepts a checkpoint only when its session-incarnation identity and byte offset
match the live byte ring. It resets a fresh viewer before importing the state,
replays only the tail after the checkpoint, and falls back to today's
retained-window replay on every validation or transport failure.

The daemon also records a tagged `answeredThrough` state atomically with each
successfully accepted parser-generated terminal response. When its provenance
is known, reattach suppresses regenerated replies at or below that offset and
forwards replies above it. When an older or competing client made provenance
unknown, reattach keeps today's coarse catch-up suppression. This distinguishes
queries already answered by the old app from detached-period queries without
treating a missing trailer as a valid zero watermark.

How to see it working: run the end-to-end test
`testReattachedLabptySessionRestoresCheckpointAndReplaysBoundedTail`. It starts
a real `labpty` session, establishes terminal state before the byte-ring
window, checkpoints, disconnects the app client, emits more output, and
reattaches. The test compares against an uninterrupted parse, verifies the
pre-window mode, and asserts that fewer than 64 KiB are re-parsed. The companion
`testReattachedLabptySessionRoutesResponsesAcrossAnsweredThroughWatermark`
shows a historical query suppressed and a query emitted while detached answered.

## Baseline Prerequisite

Commit `afb90fdf1f3aa83a810a05e3ee966f2261f73b7f` contains the coarse
response-suppression prerequisite:

- `Sources/LabanApp/AppSessionCoordinator.swift` gives `LabptyParserFeed` a
  `catchUpResponseSuppressionPending` flag. The first reattach read and any
  overflow replay drain but do not forward parser-generated responses.
- `Sources/LabanCore/Session.swift` documents the replay exception on
  `drainResponse()`.
- `Tests/LabanAppTests/LabanAppTests.swift` contains
  `testReattachedLabptySessionDoesNotReplayHistoricalQueryResponses`.

On 2026-07-18 the targeted baseline test passed immediately before the
prerequisite commit. Milestone 0 must diff from this recorded SHA when checking
that the exact-watermark work did not introduce a repeating timer.

## Progress

- [x] (2026-07-18) Baseline response-suppression implementation and regression
  test committed as `afb90fdf1f3aa83a810a05e3ee966f2261f73b7f`; the targeted
  test passed immediately before commit.
- [x] (2026-07-18) Plan review corrections define generation-safe publication,
  an explicit known/unknown response watermark, self-upgrade continuity,
  single-component sidecar names, failure-safe cleanup, and mechanical
  regressions for each issue. Implementation has not started.
- [x] Recorded baseline prerequisite:
  `BASELINE_SHA=afb90fdf1f3aa83a810a05e3ee966f2261f73b7f`.
- [ ] Milestone 0: prove lossless terminal-state export/import and finalize
  blob v1; stop this ExecPlan if equivalence cannot be demonstrated.
- [ ] Milestone 1: add the capability-gated, frame-bounded checkpoint
  transport, atomic sidecar ownership, incarnation cleanup, formal model, and
  protocol proofs/tests.
- [ ] Milestone 2: add app-side checkpoint capture/publish, atomic
  `answeredThrough` updates, dirty-state tracking, and bounded clean-detach
  coordination.
- [ ] Milestone 3: restore on reattach, replay the bounded tail with exact
  response routing, fall back safely, and pass end-to-end tests.
- [ ] Review Gate passed against a recorded commit SHA.

## Context and Orientation

Key terms for a reader new to this repository:

- **labpty** is the C daemon in `Sources/Labpty/`. It owns PTY masters, child
  process groups, and one raw-output byte ring per session. It deliberately
  does not parse terminal escape sequences.
- **Viewer session** is the app-side `Session` in
  `Sources/LabanCore/Session.swift`. In Background mode it is parser-only
  (`pty_fd == -1`): `LabptyParserFeed` reads raw bytes and calls
  `Session.feedOutput`, while `Session.drainResponse()` returns replies such as
  cursor-position or color-query responses that the feed must send to the
  child through `labpty`.
- **Byte ring** is the path-backed shared-memory circular buffer implemented by
  `Sources/Labpty/labpty_byte_ring.{c,h}` and read by
  `Sources/LabanCore/LabptyByteRingReader.swift`. Its monotonically increasing
  output offset counts all bytes ever written. The readable window is
  `reader.readableOutputWindow`, which is ring capacity minus the safety
  margin.
- **Checkpoint offset** is the byte-ring output offset after all bytes through
  that point have been applied to the exported viewer state.
- **Session incarnation** is the pair already present in the byte-ring header:
  `sessionIdHash` and `createdAtUnixNs`. A logical ID or numeric handle alone
  is insufficient because daemon restart resets handles and logical IDs may be
  deliberately reused.
- **answeredThrough** is the greatest byte-ring offset for which the daemon
  accepted parser-generated response bytes from an attached app that negotiated
  `answered-through/v1`. It is not an assumption that every preceding byte was
  a query; it is a conservative boundary below which any regenerated response
  is historical. The value always has an explicit validity state: `known(0)`
  means a capable sole attachment has not yet sent a response, while `unknown`
  means an older or competing parser may have answered bytes without a trailer.
- **Checkpoint epoch** is a daemon-owned monotonic counter for terminal state
  changes that cannot be reconstructed from raw output bytes. It starts at 1
  for each session incarnation and advances on every successful daemon resize.
  A prepared checkpoint can be installed only when its captured epoch and size
  still equal the live registry values, preventing a delayed publisher from
  reinstalling state captured before a resize, including an A-to-B-to-A resize.
- **Checkpoint sidecar** is a regular 0600 file under the daemon's private
  `--shm-dir`. The app writes a unique temporary file; the daemon validates its
  ownership, type, size, and session-incarnation metadata and atomically
  renames it to the session's canonical checkpoint path. Control frames carry
  only metadata and paths, never the multi-megabyte blob.
- **Catch-up** is replay from either a valid checkpoint offset or the oldest
  retained byte after reattach. With a known `answeredThrough`, catch-up bytes
  are split at its offset so historical replies are suppressed and previously
  unseen replies are forwarded. With an unknown watermark, every regenerated
  reply in the initial catch-up is suppressed.

The control frame is frozen at 128 KiB by
`docs/adr/0007-labpty-phase1-protocol-freeze.md` and
`LabptyFrameHeader.maxFrameBytes`. Checkpoint payloads therefore MUST NOT be
placed in `putCheckpoint` or `getCheckpoint` frames. New operations and fields
must be additive, capability-gated, trailer-tolerant, covered by golden and
negative protocol tests, and included in the existing CBMC proof discipline.

`labpty` has no crash persistence: when the daemon process dies, its PTY masters
and live sessions are gone. However,
`execplans/active/labpty-fd-handoff-self-upgrade.md` is an active, checked-in
plan for an exec-in-place self-upgrade that preserves those masters, rings, and
session incarnations while replacing daemon memory. This ExecPlan builds on
that plan by reference. A checkpoint and a known response watermark must either
survive that versioned handoff with the same live incarnation or be discarded
atomically into `no checkpoint` plus `answeredThrough = unknown`; they must
never silently reset to a valid-looking zero watermark. Ordinary daemon crash
recovery remains out of scope. Stale checkpoint and temporary files left by an
unclean daemon exit are deleted at the next fresh daemon startup or before a
reused handle is opened.

The architecture boundary comes from
`docs/adr/0006-three-tier-session-architecture.md`; the Phase 1 compatibility
rules come from ADR 0007; response writes remain governed by ADR 0008. Add
`docs/adr/0030-labpty-state-checkpoint-cache.md` in Milestone 1 to record the
new optional capability and storage lifetime.

## Design Invariants

1. A checkpoint is an optimization, never a correctness dependency. Missing,
   oversized, stale, future-offset, corrupt, foreign-version, wrong-size, or
   wrong-incarnation checkpoints fall back before any imported state becomes
   visible.
2. Checkpoint restoration is lossless for supported state. "Documented
   divergence" is not an acceptable promotion result because a semantically
   incomplete parser can corrupt future output without detecting the need to
   fall back.
3. Reset occurs before import. A new viewer is already reset; if an existing
   viewer object is reused, feed RIS (`ESC c`) before importing. Never feed RIS
   after import because RIS clears parser and render state.
4. The checkpoint blob never crosses the 128 KiB control socket. The initial
   sidecar payload cap is 4 MiB. If Milestone 0 shows a representative lossless
   blob cannot fit, record the measurements and stop rather than silently
   truncating terminal state.
5. The daemon may inspect checkpoint transport metadata but never terminal
   contents. It treats the blob bytes as opaque.
6. `answeredThrough` advances only in the same daemon operation that accepts
   the corresponding terminal-response bytes. Two independent RPCs would
   create a crash window that can neither prevent duplicate replies nor unblock
   an unanswered child. Its validity is never inferred from the numeric value:
   any attachment that did not negotiate `answered-through/v1`, any competing
   parser attachment, or any self-upgrade that cannot carry the watermark marks
   it `unknown` for the rest of that incarnation. Unknown catch-up uses the
   baseline coarse suppression path and never forwards replay-generated replies.
7. Checkpoint work is event-driven: publish after activity becomes quiet and
   during clean detach. Do not add a repeating checkpoint timer.
8. Dirty detection uses a terminal-state revision, not only the output offset.
   Milestone 0 must classify every inventoried field as (a) derived from ring
   bytes and therefore recoverable by tail replay, (b) guarded by the daemon's
   checkpoint epoch, or (c) excluded from the blob and deterministically
   reapplied from current host/UI state. The blob must not contain any field
   that can change without either a replayable ring byte or an epoch advance.
   `Session` advances its revision for every included mutation so quiet and
   clean-detach publication notice changes even when the output offset does not.
9. Catch-up uses the checkpoint's recorded terminal size and checkpoint epoch.
   Apply the current UI size only after import and tail replay. A checkpoint
   whose recorded size is inconsistent with its blob, whose epoch differs from
   the live registry, or which predates any successful daemon resize is stale.
   Every successful resize increments the epoch and unlinks the canonical
   checkpoint before a delayed publication can be considered.
10. Sidecars stay inside the exact run-scoped `--shm-dir` already associated
    with the session descriptor. Do not introduce a global checkpoint path or
    scan another worktree's directory. Tests use the unique directory returned
    by `startLabptyDaemon`.
11. Emit bounded structured `labpty.checkpoint` events for publish, restore,
    rejection/fallback, cleanup, and detach deadline. Include event outcome,
    reason code, session ID, offset, byte count, and duration, but never blob
    contents, terminal text, checksum material, or a sidecar path. Checkpoint
    files can contain private terminal state and must never be copied into a
    debug artifact.
12. A checkpoint has one writer. The daemon accepts publication only from a
    client currently attached to the session and only while that client is the
    sole attachment. Multi-attach sessions retain byte-ring/full-replay
    behavior and permanently mark the exact response watermark unknown until a
    future explicit parser-authority lease exists.

## Plan of Work

### Milestone 0 — Lossless state checkpoint feasibility

This is a go/no-go spike. Do not begin protocol or daemon work until its
promotion evidence and blob v1 definition have been written back into this
ExecPlan.

Inventory all mutable state that affects future parsing, rendering, response
generation, and input encoding. Start in `Sources/LabanTerminalCore/`,
including the libghostty terminal object, primary and alternate screens,
scrollback, cursor and saved cursor, margins, tab stops, character sets,
palette and OSC host state, hyperlinks, title, synchronized output, grapheme
mode, mouse/focus/bracketed-paste modes, kitty keyboard state, cursor style,
and viewport state. Identify which state is owned by Laban and which can be
read or set only through libghostty APIs. The non-goal is a raw memory dump of
libghostty internals, not faithful restoration of their observable state.

Add `LabptyCheckpointFeasibilityTests` under
`Tests/LabanTerminalCoreTests/` and a test-only export/import prototype:

1. Feed session A a prefix that exercises primary and alternate screens,
   scrollback overflow, DECSET/DECRST, saved cursor, custom tab stops, palette,
   title/hyperlinks, mouse/focus/bracketed paste, kitty keyboard, grapheme mode,
   and at least one resize. Distinguish terminal-origin palette overrides from
   host theme defaults: change the host theme between export and import and
   prove current host defaults are reapplied while terminal-origin overrides
   retain their uninterrupted-session semantics.
2. Export immutable state at offset N. Continue A with a tail and then a probe
   suffix that queries modes, moves relative to saved state and tab stops,
   encodes keys, switches screens, and generates terminal responses.
3. Create fresh session B at the checkpoint's recorded size. If the production
   API can reuse an existing session, prove that it performs RIS before import.
   Import the checkpoint, feed the same tail and probe suffix, then apply the
   same final resize.
4. Compare A and B for full visible and scrollback cells and attributes,
   cursor/saved-cursor behavior, palette/title/hyperlinks, every exported mode,
   `drainResponse()` bytes, and key-encoding results. Reapply fields classified
   as host/UI-owned, including viewport position and current theme defaults,
   through their normal app path before comparing those fields.
5. Mutate and truncate every blob section and prove import rejects it without
   partially changing B. Prove a wrong session incarnation, future offset,
   wrong checkpoint epoch, and mismatched terminal size are rejected.
6. Measure serialized size and export/import duration for the default
   scrollback limit and representative 24x80, 80x240, and scrollback-heavy
   sessions. Record the transcript in `Surprises & Discoveries`.

Promotion requires zero unexplained divergence after the probe suffix, a
complete mutation inventory, fail-closed import, and representative blobs at
or below 4 MiB. The inventory must include a table assigning every field to
ring-derived replay, checkpoint-epoch protection, or deterministic host/UI
reapplication. Viewport position and current host theme defaults should be
excluded and reapplied unless the spike proves a stronger epoch-protected owner;
terminal-origin palette overrides and parser modes remain ring-derived terminal
state. Finalize these production interfaces, the classification table, and the
exact blob v1 section table in `Interfaces and Dependencies` before marking
Milestone 0 complete:

    Session.exportLabptyCheckpoint(identity:offset:checkpointEpoch:) throws -> Data
    Session.importLabptyCheckpoint(
      _:expectedIdentity:expectedOffset:expectedCheckpointEpoch:) throws
    Session.checkpointStateRevision() -> UInt64

If any observable parser state cannot be restored, record the counterexample
and stop this ExecPlan. Do not weaken acceptance to final-screen-only equality.
The answered-through improvement may be proposed later as a separate plan.

### Milestone 1 — Frame-bounded transport, lifecycle, and proofs

Create `docs/adr/0030-labpty-state-checkpoint-cache.md` and add it to
`docs/adr/README.md`. Define `state-checkpoint/v1` and `answered-through/v1` as
optional capabilities: new clients advertise them, new daemons return them,
and a new client talking to an older daemon uses the baseline retained-window
replay without sending checkpoint operations. Cover the opposite direction as
well: a session opened or attached by a client that lacks
`answered-through/v1` permanently records `answeredThrough = unknown` for that
incarnation, even after a capable client attaches later.

Keep every control frame below the existing 128 KiB limit:

- Add `publishCheckpoint` with bounded metadata only: handle, session hash,
  ring creation timestamp, checkpoint offset, checkpoint epoch, recorded rows
  and columns, blob length, payload SHA-256, and a bounded temporary-file
  basename. The app has already written the blob under the private `--shm-dir`.
- Add `getReplayState(handle, incarnation)` returning the live checkpoint epoch
  and `answeredThrough` as the tagged state `unknown` or `known(offset)` even
  when there is no checkpoint, plus an optional checkpoint record containing
  canonical path, incarnation, checkpoint offset, checkpoint epoch, recorded
  terminal size, blob length, and payload SHA-256. Exact response routing is
  permitted only for the known state; unknown uses baseline coarse suppression.
  Encode the tag additively as `{ stateVersion: UInt8 = 1, known: UInt8,
  reserved: UInt16 = 0, offset: UInt64 }`; unknown encodes offset zero, and
  decoders reject nonzero reserved bytes or a tag other than 0/1.
- Extend the existing `writeInput` request with a capability-gated additive
  trailer used only for parser-generated responses:
  `{ trailerVersion: 1, answeredThrough: UInt64 }`. A session opened by a sole
  capable connection starts at `known(0)`; a session opened by a non-capable
  connection starts unknown, and any later second attachment makes a known
  watermark permanently unknown for that incarnation. Old daemons ignore the
  trailer. A new daemon interprets the trailer only from a connection that
  negotiated `answered-through/v1`. It still accepts response bytes under the
  existing ADR 0008 semantics when the watermark is unknown or attachments
  compete, so multi-attach does not block a live child's query; it merely leaves
  exact replay provenance unknown. The daemon advances a known watermark only
  while that connection is the session's sole attachment, only when the offset
  is monotonic and no greater than the current ring write offset, and only after
  the complete response payload has been accepted. Backpressure or rejection
  leaves it unchanged. Ordinary keyboard input sends no trailer. A non-capable
  or competing attachment marks the session watermark unknown rather than
  assigning a numeric sentinel.

Implement the metadata encoders/decoders in
`Sources/Labpty/labpty_protocol.{c,h}` and
`Sources/LabanCore/{LabptyProtocol.swift,LabptyFraming.swift}`. Implement Swift
client methods in `Sources/LabanCore/PTYLabClient.swift`:

    var supportsStateCheckpointV1: Bool { get }
    var supportsAnsweredThroughV1: Bool { get }
    func publishCheckpoint(_ metadata: LabptyCheckpointPublish) throws
    func getReplayState(handle: UInt64, identity: LabptySessionIncarnation)
      throws -> LabptyReplayState
    func writeTerminalResponse(
      handle: UInt64, bytes: [UInt8], answeredThrough: UInt64) throws

Add sidecar ownership under `Sources/Labpty/`:

- The app creates an unguessable, run-scoped 0600 temporary regular file in the
  private shm directory with
  `O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC`, then writes the complete blob. Its
  wire name is exactly one path component with grammar
  `lbcpt-tmp-<32 lowercase hexadecimal digits>`; reject any other length or
  character, including `/`, NUL, `.` and `..` forms.
- The daemon opens the directory once and uses `openat`/`fstatat`/`renameat`
  with no-follow checks and the validated single-component name. The canonical
  name is derived entirely by the daemon with the fixed grammar
  `lbcpt-<16 hex handle>-<16 hex session hash>-<16 hex creation time>.bin`;
  no client-supplied path participates in it. Accept only a regular file owned
  by the daemon user, mode 0600, link count 1, expected length, and length at or
  below 4 MiB.
- Validate handle, live session, exact session incarnation, and
  `checkpointOffset <= currentRingWriteOffset` before publication. Require the
  captured checkpoint epoch and rows/columns to equal the live registry epoch
  and size, including across an A-to-B-to-A resize. Require the publishing
  connection to be attached and to be the session's sole attached client.
  Atomically rename to a canonical per-incarnation path only after all
  validation passes.
- Store the published metadata, tagged `answeredThrough`, and checkpoint epoch
  in the live registry slot. A failed open, validation, or publication removes
  only the candidate temporary file and leaves the previous canonical
  checkpoint and metadata
  intact. Unlink the canonical file on successful replacement, terminate,
  natural exit, dead-slot reclaim, and fresh daemon shutdown. Purge only names
  matching the exact canonical/temporary grammar at fresh startup before handle
  1 can be reused.
- Invalidate and unlink the canonical checkpoint on every successful daemon
  resize after publication, and increment the checkpoint epoch even when the
  new rows and columns equal an earlier size. The raw byte ring contains output,
  not resize events, so replay cannot reconstruct an intervening geometry
  change and size equality alone cannot detect an A-to-B-to-A race.
- Integrate with `execplans/active/labpty-fd-handoff-self-upgrade.md`. Extend the
  versioned handoff catalog with checkpoint epoch, optional canonical metadata,
  and the tagged answered-through state. An older catalog lacking these fields
  adopts as `no checkpoint` plus `answeredThrough = unknown`; a complete newer
  catalog preserves them after revalidating the sidecar and ring incarnation.
  A daemon crash still does not preserve sessions or checkpoints.

Model publication, fetch, close, and handle reuse in
`specs/labpty/LabptyCheckpoint.tla`. Required properties are
`ReturnedCheckpointMatchesLiveIncarnation`,
`ClosedSessionHasNoPublishedCheckpoint`, and
`AnsweredThroughNeverDecreasesOrExceedsOutput`, plus
`PublishedCheckpointHasSingleWriter`, `PublishedCheckpointMatchesCurrentEpoch`,
and `UnknownAnsweredThroughNeverEnablesExactReplay`. Add negative-control
configs that omit cleanup during handle reuse and that accept a pre-resize
publication after the resize epoch advances; both must produce counterexamples.
Add runtime trace events and trace-conformance mapping for the new state
transitions.

Add golden and additive-trailer tests, property tests, daemon tests, CBMC
decoder proofs, and a negative proof control. Name the principal tests:

- `testCheckpointControlFramesStayBelowFrozenMaximum`
- `testCheckpointTransportPublishesFetchesAndReplacesAtomically`
- `testCheckpointFromPriorSessionIncarnationIsRejected`
- `testCheckpointFilesAreRemovedOnTerminateAndReuse`
- `testCheckpointSidecarsStayInsideDaemonShmDirectory`
- `testCheckpointPublishRejectedWithMultipleAttachedClients`
- `testWriteInputAnsweredThroughAdvancesOnlyAfterAcceptedResponse`
- `testOldClientOnNewDaemonLeavesAnsweredThroughUnknown`
- `testCompetingAttachmentMakesAnsweredThroughUnknown`
- `testCheckpointPublishCapturedBeforeResizeIsRejectedAfterResize`
- `testCheckpointPublishRejectsResizeABAEpoch`
- `testCheckpointTemporaryBasenameRejectsTraversalAndNestedPaths`
- `testFailedCheckpointPublishPreservesPriorCanonicalCheckpoint`
- `testCheckpointStateSurvivesSelfUpgradeOrAdoptsAsUnknown` when
  `LABPTY_OP_UPGRADE` exists; otherwise the updated fd-handoff ExecPlan is the
  compatibility gate
- `testCheckpointCapabilityAbsentFallsBackWithoutSendingNewOperations`

### Milestone 2 — Writer, watermark, and clean detach

Promote Milestone 0's export/import implementation into
`Sources/LabanTerminalCore/` and `Sources/LabanCore/Session.swift`. Add the
versioned blob codec in `Sources/LabanCore/LabptyCheckpoint.swift`. The decoder
must validate magic, version, section bounds, integer overflow, identity,
offset, recorded size, and SHA-256 before mutating a session. Import is atomic:
decode into owned temporary state first, then reset-before-import and commit
under `Session`'s recursive handle lock.

Extend `LabptyParserFeed` in
`Sources/LabanApp/AppSessionCoordinator.swift`:

- Track last successfully published offset and state revision. Capture only
  after `poll()` has completely applied bytes through `lastOffset`, and bind the
  capture to the descriptor's current checkpoint epoch and terminal size.
- Coalesce at most one pending publish per session. Capture an immutable blob
  on the feed's serial queue; perform file I/O and the publish RPC on a
  dedicated checkpoint I/O queue. The daemon's epoch-and-size compare is the
  commit point: if output changes after capture, the older blob remains valid
  because the tail is replayable; if resize changes the epoch, publication is
  rejected and the temporary file is discarded. Never serialize or write on
  the main thread.
- Skip only when both offset and checkpoint-relevant state revision are
  unchanged. After a successful resize, notify the feed so the revision and
  recorded terminal size change even without output. Milestone 0's
  classification table must remain exhaustive: any newly discovered state that
  is neither ring-derived nor deterministically reapplied requires a daemon
  epoch invalidation path before it may enter the blob.
- Trigger after the existing active-to-quiet transition in
  `parkLabptyOutputWakeAfterQuiet()` and on clean detach. Add no checkpoint
  timer. Emit `labpty.checkpoint` structured events through the existing
  `EventLog` path for publish success/failure, with bounded metadata only.
  Failure removes the abandoned temporary file and leaves the prior valid
  checkpoint in place.
- Replace parser-response calls to plain `writeInput` with
  `writeTerminalResponse(...answeredThrough: result.newOffset)`. Suppress or
  advance nothing when that operation fails. If replay state is unknown, retain
  `catchUpResponseSuppressionPending` for the entire initial catch-up; do not
  reinterpret numeric zero as a known watermark.

Clean detach needs an explicit lifetime barrier. Add
`LabptyParserFeed.stopAndPublishCheckpoint(completion:)` and
`AppSessionCoordinator.detach(completion:)`. Stop new polling, perform one
final poll, capture/publish if dirty, and invoke completion after success or a
bounded failure. Keep the captured `LabptyTerminalSessionClient` alive until
all feed completions finish; close it only afterward.

Move app-quit coordination from the too-late
`AppDelegate.applicationWillTerminate` detach call into
`applicationShouldTerminate`. Return `.terminateLater`, start the asynchronous
detach, and call `NSApp.reply(toApplicationShouldTerminate:)` after completion
or a two-second deadline. The deadline closes the client and permits quit; it
must not leave the main thread blocked. Other non-quit detach call sites use
the same completion API.

Add tests:

- `testCheckpointDirtyCheckUsesOffsetAndStateRevision`
- `testCheckpointPublishesAfterOutputBecomesQuietWithoutNewTimer`
- `testCheckpointPublishesAfterResizeWithoutNewOutput`
- `testDelayedPreResizeCheckpointCannotReplacePostResizeState`
- `testCleanDetachPublishesCheckpointBeforeClosingClient`
- `testCleanDetachDeadlineDoesNotBlockApplicationTermination`

### Milestone 3 — Validated restore and exact tail replay

On the existing-session branch of `ensureLabptyDescriptor` /
`startLabptyFeed`:

1. Read the live ring identity, readable-window size, current write offset,
   daemon descriptor size, and checkpoint epoch before changing the PTY size.
   Fetch replay state when `answered-through/v1` or `state-checkpoint/v1` was
   negotiated. The tagged watermark is gated by the former; optional checkpoint
   metadata is gated by the latter, so either capability can degrade
   independently.
2. Validate exact incarnation and compute
   `oldestRetainedOffset = max(0, currentWriteOffset - readableOutputWindow)`.
   Accept only
   `oldestRetainedOffset <= checkpointOffset <= currentWriteOffset`. Require the
   checkpoint epoch and recorded size to equal the live replay-state values.
   Validate the canonical sidecar with `O_NOFOLLOW|O_CLOEXEC`, `fstat`,
   ownership, exact length, SHA-256, blob header, recorded size, and version.
3. For a valid checkpoint, reset the viewer first, import atomically at its
   recorded terminal size, and initialize the feed at `checkpointOffset`.
   Capture `attachCutoff = reader.outputWriteOffset()` after import.
4. Read `(checkpointOffset, attachCutoff]`. If this first tail read overflows,
   if confirmation retries report uncertainty, or if any offset moves
   backwards or beyond the ring, discard the imported state, reset again, and
   execute the unchanged retained-window fallback from offset 0.
5. If `answeredThrough` is known, split catch-up at its offset: feed the
   historical portion while draining and suppressing generated replies, then
   feed bytes above the watermark while forwarding generated replies through
   the atomic response-write path. If a parser chunk straddles the watermark,
   split the byte buffer at the exact offset before calling `feedOutput`. If the
   watermark is unknown, suppress generated replies for the entire initial
   retained-window catch-up exactly as the baseline implementation does; this
   deliberately forgoes answering detached-period queries rather than risking
   duplicate historical input.
6. After catch-up reaches `attachCutoff`, use normal live forwarding. Only then
   apply the current UI resize to the viewer and daemon. Mark the tab dirty so
   the restored frame is autonomously observable.
7. On any missing capability, absent file, validation failure, unsupported
   blob, publication race, import error, or tail overflow, log a reason code
   and use the baseline retained-window replay. No partially imported frame may
   become visible. Emit the same bounded `labpty.checkpoint` event shape for
   restore, rejection/fallback, cleanup, and detach-deadline outcomes so
   `GET /debug/events` can prove which path ran without exposing checkpoint
   contents.

Add real-daemon end-to-end tests in
`Tests/LabanAppTests/LabanAppTests.swift`:

- `testReattachedLabptySessionRestoresCheckpointAndReplaysBoundedTail`: compare
  against an uninterrupted full-lifetime parse, not a retained-window replay;
  set a DEC mode before overflowing the ring, checkpoint, detach, append a
  tail, reattach, and assert full state equality plus fewer than 64 KiB parsed.
- `testReattachedLabptySessionRoutesResponsesAcrossAnsweredThroughWatermark`:
  prove a query answered before detach is suppressed while a child blocked on
  a query emitted during detach receives the newly generated reply.
- `testReattachedLabptySessionWithUnknownWatermarkUsesCoarseSuppression`: create
  the session through a client that does not advertise `answered-through/v1`,
  then reattach with a capable client and prove no historical reply is sent.
- `testReattachRejectsFutureOffsetAndWrongIncarnationCheckpoint`
- `testReattachTailOverflowDiscardsImportedStateAndFallsBack`
- `testCheckpointEventsExposeOutcomeWithoutPayloadOrPath`
- Keep `testReattachedLabptySessionDoesNotReplayHistoricalQueryResponses` and
  `testLabptyViewerSessionAnswersCursorPositionQuery` green.

### Non-goals

- Raw serialization of private libghostty memory or pointer graphs.
- Any escape-sequence, cell, palette, or mode interpretation in `labpty`.
- Checkpoint survival across a `labpty` crash or a fresh restart that does not
  preserve the session incarnation. Exec-in-place self-upgrade continuity is
  explicitly covered above.
- Changing `laband` or Local-session behavior.
- Increasing the frozen 128 KiB control-frame maximum.
- A repeating checkpoint timer.

## Decision Log

- Decision: Checkpoints are a correctness-neutral optimization with full replay
  fallback.
  Rationale: app restart must never depend on optional cached state.
  Date/Author: 2026-07-18, pre-planning discussion with user.
- Decision: Milestone 0 is a strict lossless-equivalence gate; display-only
  restoration is a candidate, not a settled implementation.
  Rationale: documented parser divergence can corrupt future terminal behavior
  without activating fallback.
  Date/Author: 2026-07-18, review correction.
- Decision: Use a daemon-owned atomic sidecar with metadata-only RPCs rather
  than carrying checkpoint bytes in control frames.
  Rationale: the frozen frame maximum is 128 KiB while a useful bounded
  terminal checkpoint may be several MiB.
  Date/Author: 2026-07-18, review correction.
- Decision: Bind every checkpoint to byte-ring session hash plus creation time
  and delete it with the live session.
  Rationale: handles restart at 1, logical IDs are reusable, and `labpty` has no
  crash persistence.
  Date/Author: 2026-07-18, review correction.
- Decision: Advance `answeredThrough` atomically with accepted response input;
  it is required, not optional.
  Rationale: a separate watermark RPC has a crash window, and suppressing all
  bytes through attach time incorrectly withholds replies to queries emitted
  while detached.
  Date/Author: 2026-07-18, review correction.
- Decision: Represent `answeredThrough` as `unknown` or `known(offset)` and make
  unknown sticky for an incarnation after any non-capable or competing parser
  attachment.
  Rationale: numeric zero cannot distinguish "no response has been sent" from
  "an older client may have sent responses without trailers"; exact replay is
  unsafe without provenance.
  Date/Author: 2026-07-18, review correction.
- Decision: Bind checkpoint publication to a daemon-owned resize epoch and
  classify every blob field by replayability.
  Rationale: an asynchronous pre-resize capture can arrive after resize
  invalidation, and output replay cannot reconstruct geometry or arbitrary
  host-only state. Epoch comparison closes the publication race; excluding and
  reapplying host/UI state avoids unverifiable stale cache contents.
  Date/Author: 2026-07-18, review correction.
- Decision: Treat exec-in-place daemon self-upgrade as session continuity, not
  daemon crash recovery.
  Rationale: the active fd-handoff plan preserves PTY masters and rings while
  replacing registry memory, so checkpoint metadata and watermark validity must
  cross its versioned catalog or fail closed to no checkpoint plus unknown.
  Date/Author: 2026-07-18, review correction.
- Decision: Accept only a fixed-grammar, single-component temporary sidecar name
  and never remove the prior canonical file on candidate failure.
  Rationale: `O_NOFOLLOW` does not prevent traversal through intermediate path
  components, and replace-by-rename is recoverable only while the prior cache
  remains intact until successful commit.
  Date/Author: 2026-07-18, review correction.
- Decision: Event-driven writes on quiet and clean detach, with asynchronous
  termination coordination and no checkpoint timer.
  Rationale: preserves the zero-idle-CPU goal and guarantees the primary clean
  quit checkpoint completes before the client closes.
  Date/Author: 2026-07-18, review correction.

## Review Gate

A separate fresh agent must run this gate against the completed commit. Record
that commit SHA in `Progress`; do not review a dirty implementation tree.

- [ ] `test -z "$(rtk proxy git status --porcelain -- Sources/Labpty Sources/LabanTerminalCore Sources/LabanCore Sources/LabanApp Tests/LabptyTests Tests/LabanAppTests Tests/LabanTerminalCoreTests specs/labpty proofs/labpty docs/adr execplans/active/labpty-fd-handoff-self-upgrade.md execplans/active/labpty-reattach-state-checkpoint.md)"`
  exits 0.
- [ ] Run
  `for cap in state-checkpoint/v1 answered-through/v1; do for file in Sources/Labpty/labpty_protocol.c Sources/LabanCore/LabptyProtocol.swift docs/adr/0030-labpty-state-checkpoint-cache.md; do rtk proxy rg -q "$cap" "$file" || exit 1; done; done`;
  expect exit 0, proving both capabilities occur in all three files.
- [ ] Run `rtk swift test --filter LabptyCheckpointFeasibilityTests`; expect exit 0
  and `testCheckpointRoundTripPreservesSubsequentTerminalBehavior` to pass.
- [ ] Run `rtk swift test --filter LabptyProtocolTests` and
  `rtk swift test --filter LabptyDaemonTests`; expect exit 0, including
  `testCheckpointControlFramesStayBelowFrozenMaximum`,
  `testCheckpointFromPriorSessionIncarnationIsRejected`, and
  `testCheckpointFilesAreRemovedOnTerminateAndReuse`,
  `testCheckpointSidecarsStayInsideDaemonShmDirectory`,
  `testCheckpointPublishRejectedWithMultipleAttachedClients`,
  `testOldClientOnNewDaemonLeavesAnsweredThroughUnknown`,
  `testCheckpointPublishCapturedBeforeResizeIsRejectedAfterResize`,
  `testCheckpointPublishRejectsResizeABAEpoch`,
  `testCheckpointTemporaryBasenameRejectsTraversalAndNestedPaths`, and
  `testFailedCheckpointPublishPreservesPriorCanonicalCheckpoint`.
- [ ] Run
  `rtk swift test --filter testCleanDetachPublishesCheckpointBeforeClosingClient`;
  expect pass.
- [ ] Run
  `rtk swift test --filter testReattachedLabptySessionRestoresCheckpointAndReplaysBoundedTail`;
  expect pass with an assertion that parsed tail bytes are below 65,536 for a
  session whose total output exceeds the readable ring window.
- [ ] Run
  `rtk swift test --filter testReattachedLabptySessionRoutesResponsesAcrossAnsweredThroughWatermark`;
  expect pass and assertions for both suppressed historical and forwarded
  detached-period queries.
- [ ] Run
  `rtk swift test --filter testReattachedLabptySessionWithUnknownWatermarkUsesCoarseSuppression`;
  expect exactly one test to run and pass, with an assertion that a session
  created by a non-capable client emits no historical replay response.
- [ ] If `rtk proxy rg -q 'LABPTY_OP_UPGRADE' Sources/Labpty`, run
  `rtk swift test --filter testCheckpointStateSurvivesSelfUpgradeOrAdoptsAsUnknown`
  and expect exactly one test to pass. Otherwise run
  `rtk rg -n 'checkpoint_epoch|answered_through_known' execplans/active/labpty-fd-handoff-self-upgrade.md`
  and expect both fields in its catalog, M2, acceptance, and decision sections.
- [ ] Run
  `rtk swift test --filter testCheckpointEventsExposeOutcomeWithoutPayloadOrPath`;
  expect pass and an event containing outcome/reason/offset/bytes/duration but
  no terminal text, blob bytes, checksum, or sidecar path.
- [ ] With `BASELINE_SHA` from `Progress`, run
  `rtk proxy git diff "$BASELINE_SHA" -- Sources/LabanApp/AppSessionCoordinator.swift | rtk rg '^\+.*(scheduledTimer|makeTimerSource|DispatchSourceTimer)'`;
  expect exit 1 and no output, proving no repeating timer was added.
- [ ] Run `rtk ./scripts/check-specs`, `rtk ./scripts/check-cbmc`,
  `rtk ./scripts/check-cbmc-contracts`, `rtk ./scripts/check-trace`, `rtk ./scripts/check-model-coverage`,
  `rtk ./scripts/check-anchors`, and `rtk ./scripts/check-fd-hygiene`; every command
  must exit 0. Confirm both checkpoint negative-control configs report their
  expected counterexamples rather than verification success.
- [ ] Run `rtk ./scripts/check`; expect exit 0 with no skipped checkpoint tests.
- [ ] Run
  `rtk rg -n '128 KiB|optional capability|out-of-band|daemon crash|exec-in-place self-upgrade' docs/adr/0030-labpty-state-checkpoint-cache.md`;
  expect five hits, one for each required compatibility/lifetime statement.
- [ ] Run
  `for field in checkpoint_epoch answered_through_known; do rtk proxy rg -q "$field" execplans/active/labpty-fd-handoff-self-upgrade.md || exit 1; if rtk proxy rg -q 'LABPTY_OP_UPGRADE' Sources/Labpty; then rtk proxy rg -q "$field" Sources/Labpty || exit 1; fi; done`;
  expect exit 0, proving the active handoff plan—and implemented handoff source,
  when present—carry both continuity fields. Also confirm the preceding-minor
  handoff test named above passes rather than silently defaulting to known zero.

Review status: NOT REVIEWED

## Surprises & Discoveries

- Observation: The baseline historical OSC 10/11 answers were computed from
  the reattaching viewer's current theme-injected palette, not the palette at
  query time.
  Evidence: before the baseline fix the regression exposed
  `^[]10;rgb:adad/bcbc/bcbc^[\^[[1;1R` in snapshot text.
- Observation: A 4 MiB `putCheckpoint`/`getCheckpoint` payload cannot use the
  control socket because the complete frame is frozen at 128 KiB.
  Evidence: `LabptyFrameHeader.maxFrameBytes` and ADR 0007 both specify
  128 KiB; the corrected design uses a sidecar and metadata-only frames.
- Observation: RIS cannot follow state import.
  Evidence: the existing overflow path feeds `ESC c` specifically to reset
  parser and render state before replay.
- Observation: checkpoint files cannot meaningfully survive a daemon crash or
  fresh restart that loses the session incarnation.
  Evidence: daemon teardown closes PTY masters and byte rings, and
  `LabptyTerminalSessionClient` documents that prior sessions are gone after a
  daemon crash.
- Observation: an exec-in-place daemon self-upgrade is not equivalent to a
  crash because the active fd-handoff plan preserves PTY masters and byte rings.
  Evidence: `execplans/active/labpty-fd-handoff-self-upgrade.md` versions and
  serializes live registry state across `execve`; new checkpoint and watermark
  fields must join that contract or fail closed on adopt.
- Observation: invalidating a canonical checkpoint during resize is insufficient
  when an older prepared publication can finish afterward.
  Evidence: the publication path intentionally performs file I/O asynchronously;
  an exact daemon-owned resize epoch is required to reject the delayed commit,
  including A-to-B-to-A geometry.
- Observation: `answeredThrough = 0` is ambiguous across additive protocol
  evolution.
  Evidence: a new daemon accepts Phase 1 `writeInput` from an older client but
  receives no trailer identifying parser-generated response writes.

## Concrete Steps

Run every command from `/Users/rrj/wrk/laban`. Milestone ordering is strict.
Write the failing test first, observe the intended failure, implement, then
rerun the focused test before broadening.

Baseline and Milestone 0:

    rtk swift build
    rtk swift test --filter testReattachedLabptySessionDoesNotReplayHistoricalQueryResponses
    rtk swift test --filter LabptyCheckpointFeasibilityTests

Before Milestone 1, update `Interfaces and Dependencies`, the blob v1 section
table, `Surprises & Discoveries`, and `Progress` with Milestone 0 evidence.

Milestone 1:

    rtk swift test --filter LabptyProtocolTests
    rtk swift test --filter LabptyDaemonTests
    rtk ./scripts/check-specs
    rtk ./scripts/check-cbmc
    rtk ./scripts/check-cbmc-contracts
    rtk ./scripts/check-trace
    rtk ./scripts/check-model-coverage
    rtk ./scripts/check-anchors
    rtk ./scripts/check-fd-hygiene

Milestones 2 and 3:

    rtk swift test --filter testCheckpoint
    rtk swift test --filter testReattachedLabptySession
    rtk swift test --filter LabanAppTests

Final verification:

    rtk ./scripts/check
    rtk ./scripts/install-app

The real app-test daemon is `.build/debug/labpty`. Tests that cannot find it
may use `XCTSkip`; build first and treat any checkpoint-test skip as a failed
validation, not a pass.

## Validation and Acceptance

Acceptance is behavioral:

1. With a daemon lacking `state-checkpoint/v1`, Background sessions reattach
   through the baseline retained-window replay and all existing tests pass.
2. With the capability, a valid checkpoint restores the same current and
   subsequent behavior as an uninterrupted full-lifetime parser, including
   state established before the retained ring window.
3. The bounded-tail end-to-end test parses less than 64 KiB after reattach in
   its quiet-detach scenario even though total output exceeds the retained
   window.
4. With a known watermark, a historical query is not answered twice while a
   query emitted while the app is detached receives a reply after reattach.
   With an unknown watermark caused by an older or competing client, the whole
   initial catch-up is coarsely suppressed and no historical reply is injected.
5. Missing, stale, wrong-incarnation, wrong-epoch, future-offset, truncated,
   oversized, and checksum-invalid checkpoints expose no partial restored frame
   and fall back to retained-window replay. A capture prepared before resize is
   rejected even when the session later returns to the same rows and columns.
6. Clean app termination publishes dirty checkpoints before closing the
   control client without blocking the main thread beyond the asynchronous
   two-second termination deadline.
7. `rtk ./scripts/check` and every listed formal/proof gate pass with no skipped
   checkpoint tests.
8. If exec-in-place fd handoff is present, a self-upgrade preserves valid
   checkpoint metadata and tagged response-watermark state. If an older handoff
   catalog cannot carry them, adopt removes the checkpoint and marks the
   watermark unknown before serving the preserved session.
9. After `rtk ./scripts/install-app`, start a Background session, establish a mode
   and produce enough output to exceed the minimum readable window, wait for
   quiet publication, quit, and relaunch. The installed app restores the live
   shell without visible historical query garbage or a full-window repaint
   delay. Confirm the running bundle's build stamp matches the reviewed commit,
   and query `GET /debug/events` to observe a bounded `labpty.checkpoint`
   restore event for that session.

## Idempotence and Recovery

Checkpoint publication is replace-by-rename: retries write a new uniquely
named temporary file and never modify the current canonical checkpoint in
place. A failed write, open, validation, or publish removes only its candidate
temporary file and leaves the previous checkpoint valid. The daemon accepts
only the exact single-component temporary-name grammar, derives canonical names
itself, and never resolves a client-provided slash. Fresh startup and session
teardown remove abandoned temporary and canonical files only after validating
they are regular owned files inside the private shm directory.

Import decodes and validates into temporary owned state. It commits only after
all checks pass, so retrying after a corrupt blob is equivalent to having no
checkpoint. A tail overflow after import resets again and takes the baseline
fallback. A delayed pre-resize publisher cannot commit because the daemon
compares its captured epoch and size against the live registry. Old clients and
daemons continue using the frozen Phase 1 behavior because the new capability
is optional and all new payload fields are additive; any session touched by a
non-capable parser retains an unknown watermark and therefore the baseline
coarse-suppression behavior.

If Milestone 0 fails, revert only its prototype code, keep the evidence and
decision in this plan, mark the checkpoint milestones blocked by feasibility,
and stop. Do not ship the daemon storage path without a lossless importer.

## Interfaces and Dependencies

End-state interfaces:

- `Sources/LabanCore/LabptyCheckpoint.swift` defines
  `LabptySessionIncarnation`, `LabptyAnsweredThroughState`,
  `LabptyReplayState`, `LabptyCheckpointMetadata`, `LabptyCheckpointPublish`,
  and the bounded blob codec. `LabptyAnsweredThroughState` is a tagged
  `unknown`/`known(UInt64)` value; it never uses a numeric sentinel. Use
  CryptoKit SHA-256 for corruption detection; no new package dependency is
  required on macOS.
- `Sources/LabanCore/LabptyByteRingReader.swift` exposes read-only
  `sessionIdHash` and `createdAtUnixNs` fields already present in the ring
  header.
- `Sources/LabanCore/Session.swift` exposes the export/import/revision methods
  finalized by Milestone 0. All three use the existing recursive handle lock.
- `Sources/LabanCore/PTYLabClient.swift` exposes optional capability state,
  metadata publish/fetch, and terminal-response writing with an atomic
  answered-through trailer.
- `Sources/Labpty/labpty_protocol.{c,h}` add bounded metadata operations and
  the optional write-input trailer without changing
  `LABPTY_MAX_FRAME`, ABI major, or existing request semantics.
- `Sources/Labpty/labpty_registry.{c,h}` bind canonical checkpoint metadata and
  tagged `answeredThrough` state to the live session incarnation, maintain the
  monotonic checkpoint epoch, and own all cleanup.
- `execplans/active/labpty-fd-handoff-self-upgrade.md` includes checkpoint epoch,
  optional canonical metadata, and tagged answered-through state in its
  versioned state-file contract. When that plan is implemented, its adopt
  decoder treats absent fields as no checkpoint plus unknown rather than zero.
- `docs/adr/0030-labpty-state-checkpoint-cache.md` is the compatibility and
  lifetime contract.

Blob v1 starts with a fixed-width, little-endian envelope containing magic
`LBPTY-CP`, format major/minor, header length, session hash, ring creation time,
checkpoint offset, checkpoint epoch, terminal-state revision, rows, columns,
payload length, and SHA-256. Milestone 0 must replace this paragraph with the
exact ordered section table, sizes, bounds, required/optional rules, and the
field replayability classification before Milestone 1 starts. Unknown major
versions fail closed; a newer minor may append length-delimited optional
sections, while required unknown sections force fallback.
