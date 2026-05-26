# Close Background-Session Regressions Against Local Sessions

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds. A
fresh contributor should be able to read only this file and the current
working tree, then close three regressions that appear in Laban's
background-session (`laband`) mode but not in local in-process mode.

## Purpose / Big Picture

Laban can run terminal sessions in two modes:

- **In-process mode (`.inProcess`)**: the app owns the PTY directly through
  the libghostty terminal engine. This is the historical default.
- **Background mode (`.laband`)**: the app delegates ownership of the PTY,
  the VT parser, and the scrollback to a separate per-user daemon process
  named `laband`. The app becomes a renderer/controller. The shipped
  behavior contract for this mode lives in
  `execplans/active/laband-live-session-daemon.md` and ADR 0005
  (`docs/adr/0005-laband-owns-live-session-pty-lifecycle.md`).

In background mode three user-visible regressions exist today that do not
exist in local mode:

1. **Tab titles never tell the user what is running.** In local mode the
   sidebar tab row shows the current foreground command, OSC-set terminal
   title (for example `* Claude Code`), and the cwd as `~` / `~/sub`. In
   background mode every tab shows only the position label like `Tab 1`,
   `Tab 2`.
2. **The Claude Code crab mascot renders with hairline black gaps between
   block-element cells.** Local rendering closed this gap by drawing block
   elements (`U+2580..U+259F`) as procedural filled rectangles instead of
   font glyphs. The background-mode rendering path still routes block
   elements through the font and so the seams reappear.
3. **A black border can appear between the sidebar and the terminal area
   (rarely reproducible).** A user reported it; we have a screenshot but no
   reproducer. The remote rendering path derives the terminal-area
   background color from `snapshot.cells.first?.backgroundRGBA ??
   Theme.current.bg0` rather than from the daemon's true
   `snapshot.default_background_rgba`. When the first cell is unstyled the
   field is 0 (transparent black), which leaves the layer-backed view's
   underlying color visible.

After this work, a tab running `claude` in background mode shows the same
title/cwd metadata as in local mode; the Claude crab mascot renders
seam-free on both paths; and the remote rendering path uses the daemon's
authoritative default-background color so a "transparent first cell" can no
longer leak through as a black border.

## Progress

- [x] (2026-05-26) Investigated the three regressions, identified the
  responsible code paths, and chose an umbrella ExecPlan with three
  smallest-blast-radius-first milestones (M1 seam, M2 metadata, M3 default
  bg).
- [x] (2026-05-26) M1: emit procedural `.rect` commands for block elements
  in the `LabandSnapshotResponse` rendering path. Verified failing without
  the fix and passing with it via
  `Tests/LabanCoreTests/FrameProducerRemoteBlockElementTests.swift`.
- [x] (2026-05-26) M2: surface daemon-side foreground-process metadata and
  terminal title through the laband control protocol and feed them into
  the per-tab title model. Daemon throttles foreground-process polling to
  1 Hz per session; coordinator throttles client-side `listSessions`
  refresh to ~4 Hz. Verified by
  `Tests/LabandTests/LabandSessionMetadataTests.swift` (daemon end) and
  the new `testRefreshTabMetadataFlowsForegroundCommandIntoModel` case in
  `Tests/LabanAppTests/AppLabandSessionCoordinatorTests.swift` (app end).
- [x] (2026-05-26) M3: add `defaultBackgroundRGBA` (optional, additive) to
  `LabandSnapshotResponse`, populate from `snapshot.default_background_rgba`
  in `laband`, and consume in both `FrameProducer.commands(from:
  LabandSnapshotResponse, ...)` and
  `TerminalSurfaceController.makeFrame(remoteSnapshot:...)`. Treats nil
  and 0 as "unknown" and falls back to `Theme.current.bg0` — never to
  `cells.first?.backgroundRGBA`. Verified failing without the fix and
  passing with it via
  `Tests/LabanCoreTests/FrameProducerRemoteDefaultBackgroundTests.swift`.
- [x] (2026-05-26) Full `swift test` pass: 778 tests, 0 failures, 5
  skipped (skips are environmental, not regressions). `./scripts/build-app`
  succeeds; app + daemon ad-hoc code-signed.

## Context and Orientation

The reader needs the following landmarks. All paths are relative to the
repo root.

### Two rendering paths from one frame producer

`Sources/LabanCore/FrameProducer.swift` exposes two distinct `commands(...)`
overloads:

1. The **local** one takes `UnsafePointer<LabanSnapshot>` — the C struct
   filled in by libghostty. It is exercised when the in-process session
   feeds output through libghostty. See `FrameProducer.swift:57-398`.
2. The **remote** one takes a Swift-native `LabandSnapshotResponse`. It is
   exercised when the daemon hands back a snapshot over the control
   protocol or the shared-memory snapshot ring. See
   `FrameProducer.swift:400-570`.

Both produce `[FrameCommand]` consumed by `MetalRenderer` /
`SoftwareBackend`. The local overload at `FrameProducer.swift:301-321`
emits **procedural `.rect` commands** for any scalar that
`BoxDrawing.isProceduralCellElement(_:)` returns true for. That branch is
**missing in the remote overload**, which always reaches the
`.glyphRun(...)` path at `FrameProducer.swift:512-520` — so block elements
get rendered as font glyphs, leaving hairline seams between adjacent cells
(the regression visible on Claude's crab mascot).

The procedural geometry itself lives in
`Sources/LabanRenderer/BoxDrawing.swift` and is fully backend-agnostic; the
remote path just needs to call it.

### Background session metadata flow

When the app is launched in `.laband` mode (`AppKitTerminalBackend.laband`),
`MainWindowController.swift:60-81` builds the `AppModel` with a
`Session.fixture(size:)` placeholder per tab. The fixture session has no
PTY, no libghostty handle, and so:

- `Session.processMetadata()` (in
  `Sources/LabanCore/Session.swift:534-574`) returns `nil` because it
  early-outs on `handle == nil`.
- `Session.consumeTitle()` returns `(false, "")` for the same reason.

`TerminalSurfaceController.syncSessions(...)`
(`Sources/LabanCore/TerminalSurfaceController.swift:245-307`) iterates over
the active in-process sessions and calls
`AppModel.syncSurfaceMetadata(...)`, which calls into
`TabMetadataSynchronizer.syncSurfaceMetadata(...)`
(`Sources/LabanCore/TabMetadataSynchronizer.swift:239-285`). For background
mode this is operating on the fixture session, so it consistently sees no
process metadata and no title — and the sidebar falls back to "Tab N".

The real metadata is owned by the daemon. `Sources/Laband/main.swift`
already polls foreground PID via `refreshProcessMetadata(_:)` at
`main.swift:1070-1075`, but it discards the human-readable strings —
`foregroundProcess`, `foregroundCommand`, `foregroundArguments`, `cwd` —
because they are not declared on `ManagedLabandSession` / `LabandSessionInfo`.
The daemon **does** capture the terminal title (OSC 0/2) in
`snapshotResponse(_:)` at `main.swift:1193-1200` and exposes it both on
`LabandSnapshotResponse.title` and `LabandSessionInfo.title`.

### Default background color in remote rendering

The local FrameProducer overload uses `snapshot.default_background_rgba`
straight from libghostty (`FrameProducer.swift:69`).
`LabandSnapshotResponse` (`Sources/LabanCore/LabandProtocol.swift:258-303`)
**does not carry** a `defaultBackgroundRGBA` field. Both the remote
`FrameProducer.commands(from: LabandSnapshotResponse, ...)` at
`FrameProducer.swift:409` and `TerminalSurfaceController.makeFrame(
remoteSnapshot:...)` at `TerminalSurfaceController.swift:478` improvise:
```
let defaultBg = snapshot.cells.first?.backgroundRGBA ?? Theme.current.bg0
```
If the snapshot is sparse (no cells), they use `Theme.current.bg0`.
**If the first cell is present but its `backgroundRGBA` is 0 (RGBA 0/0/0/0
— fully transparent black), that 0 is preferred over the theme color.**
That zero then becomes the fill color of the terminal-area background
rect. With our Metal/Software backends drawing on a layer-backed `NSView`
whose underlying NSWindow content is dark, the user sees a black band
between the sidebar (which uses `Theme.current.bg1`) and the actual
terminal cell content (where individual cells may carry their own bg).

This is consistent with the user's screenshot showing a thin black band
between sidebar (lighter blue) and terminal area (darker blue) with no
clear reproducer — it triggers whenever the daemon's first snapshot cell
happens to have `backgroundRGBA == 0` before real content arrives.

## Plan of Work

### Milestone M1 — Block-element seam parity in the remote renderer

Scope: one branch in one function. Smallest blast radius first, so the
build/test/verify loop is proven on the easy case.

Edit `Sources/LabanCore/FrameProducer.swift`. In the
`commands(from: LabandSnapshotResponse, ...)` overload, replace the inner
loop at `FrameProducer.swift:525-549` with a version that, before falling
into the `runText`/`flushRun` glyph-run accumulator, checks whether
`cell.text` is a single Unicode scalar for which
`BoxDrawing.isProceduralCellElement(scalar)` is true. If it is:

1. `flushRun()` to terminate any in-progress glyph run.
2. Compute the cell origin as `originX + CGFloat(col) * cw, cellY`.
3. Emit one `.rect(...)` `FrameCommand` per `FilledRect` produced by
   `BoxDrawing.proceduralCellElementRects(scalar, at:, cellWidth: cw,
   cellHeight: ch, foreground: cell.foregroundRGBA)`.
4. `continue` to the next column.

This mirrors the local path at `FrameProducer.swift:301-321` exactly,
except the cell's text and colors come from `LabandSnapshotCell` instead
of the libghostty C struct.

### Milestone M2 — Tab metadata parity for background sessions

Scope: extend the daemon → app metadata channel for the title plus the
foreground process. Two paths, kept separate because they have different
sources:

**Terminal title (OSC 0/2).** The daemon already populates
`LabandSessionInfo.title` in `sessionInfo(_:)` at `main.swift:1171-1190`.
On the app side, `AppLabandSessionCoordinator.ensureSession(for:size:)`
already calls `client.attachSession(...)` and `client.createSession(...)`
and stores the resulting `LabandSessionInfo`. We need a periodic refresh
pulse that calls `client.attachSession(...)` (or a new
`client.refreshSession(...)`) for each known tab and, when the returned
`title` is non-empty and differs from the last applied value, calls
`AppModel.updateTerminalTitle(_:forTab:)`
(`Sources/LabanCore/AppModel.swift:854-863`). The simplest hook is to
piggy-back on the existing snapshot-frame fetch in
`TerminalBitmapView.beginRender()`
(`Sources/LabanApp/TerminalBitmapView.swift:980-987`): after the frame is
acquired, ask the coordinator for the freshest known title for every tab
and push titles into the model. The snapshot itself also carries a `title`
on `LabandSnapshotResponse`, so for the active tab we can take it directly
from the rendered frame and avoid an extra round-trip.

**Foreground process metadata.** This requires three edits:

1. In `Sources/Laband/main.swift`, extend `ManagedLabandSession` (and its
   journal record fields) with `foregroundProcess: String?`,
   `foregroundCommand: String?`, `foregroundArguments: [String]?`, and
   `daemonCwd: String?`. Update `refreshProcessMetadata(_:)`
   (`main.swift:1070-1075`) to copy these from
   `session.processMetadata()` rather than discarding them. The journal
   does not need to persist these (they are derived from the live
   foreground PID and are cheap to re-derive after replay), but the
   in-memory `ManagedLabandSession` must hold them so `sessionInfo(_:)`
   can include them.
2. In `Sources/LabanCore/LabandProtocol.swift`, add the same four
   optional fields to `LabandSessionInfo`. Keep them `Codable` and default
   to `nil` for backwards compatibility — the existing
   length-prefixed-JSON control protocol tolerates unknown / absent
   fields. Bump no version: this is additive.
3. In `Sources/LabanApp/AppLabandSessionCoordinator.swift`, expose
   a per-tab `processMetadata(for: Tab) -> Session.ProcessMetadata?`
   accessor that synthesizes a `Session.ProcessMetadata` from the cached
   `LabandSessionInfo`. Then call `AppModel.applyProcessMetadata(_:forTab:)`
   from the same render-loop refresh pulse described above.
   `AppModel.applyProcessMetadata(_:forTab:)` is currently package-internal
   (`Sources/LabanCore/AppModel.swift:978-1007`); widen it to `public` so
   the `LabanApp` module can call it without going through
   `Session.processMetadata()`.

The throttling already lives inside
`TabMetadataSynchronizer.applyProcessMetadata` (it is triggered from the
sync path; we are calling apply directly which bypasses throttle — that's
fine because the snapshot generation monitor already gates how often this
runs, and `applyProcessMetadata` early-outs when nothing changed).

### Milestone M3 — Honor daemon-supplied default background

Scope: replace the brittle `cells.first?.backgroundRGBA ?? Theme.current.bg0`
fallback with the daemon's real default-background color.

1. In `Sources/LabanCore/LabandProtocol.swift`, add a non-optional
   `defaultBackgroundRGBA: UInt32` field to `LabandSnapshotResponse`. Make
   the decoder tolerate older daemons that don't emit it by giving the
   `Codable` decoder a fallback to 0 — code that consumes it must treat 0
   as "missing, fall back to theme" so old daemons keep working during a
   rolling upgrade.
2. In `Sources/Laband/main.swift`, in `snapshotResponse(_:)` at
   `main.swift:1193-1240`, copy `snap.pointee.default_background_rgba`
   into the new field.
3. In `Sources/LabanCore/FrameProducer.swift` (`:409`) and
   `Sources/LabanCore/TerminalSurfaceController.swift` (`:478`), prefer
   `snapshot.defaultBackgroundRGBA` when it is non-zero, falling back to
   the old `cells.first?.backgroundRGBA ?? Theme.current.bg0` chain only
   when it is zero. Document the precedence inline.

This is a hypothesis-driven defensive fix. The user-reported black border
has no reliable reproducer, so the acceptance below is phrased as
"transparent first-cell can no longer reach the terminal-area rect", not
"no black border ever again." If a user encounters the regression after
this lands we will need a new reproducer; the plan calls that out in
Surprises & Discoveries.

## Concrete Steps

All commands run from the repo root.

```
# M1 verification.
swift test --filter LabanCoreTests.FrameProducerRemoteBlockElementTests

# M2 verification.
swift test --filter LabandTests.LabandSessionMetadataTests
swift test --filter LabanAppTests.AppLabandSessionCoordinatorTests.testProcessMetadataFlowsToTabTitleModel

# M3 verification.
swift test --filter LabanCoreTests.FrameProducerRemoteDefaultBackgroundTests

# Full project build.
./scripts/build-app
```

Add new test files where they fit the existing layout:

- `Tests/LabanCoreTests/FrameProducerRemoteBlockElementTests.swift`
- `Tests/LabanCoreTests/FrameProducerRemoteDefaultBackgroundTests.swift`
- `Tests/LabandTests/LabandSessionMetadataTests.swift`
- Either a new test method on `AppLabandSessionCoordinatorTests` or a new
  file alongside it.

## Validation and Acceptance

**M1 (block-element seams):** A unit test on
`FrameProducer.commands(from: LabandSnapshotResponse, ...)` constructs a
snapshot with two adjacent cells both containing `U+2588 FULL BLOCK` and
asserts the output contains two `.rect` commands at integer-aligned cell
origins, with no `.glyphRun` for those cells. Without the fix this test
fails because the path produces a `.glyphRun`. With the fix it passes.

**M2 (tab metadata parity):**

- A daemon-level test launches `laband`, creates a session running
  `/bin/sh -c 'sleep 30'`, calls `listSessions`, and asserts the returned
  `LabandSessionInfo.foregroundCommand` contains `sh` and
  `foregroundArguments` mentions `sleep`. Without the fix the new fields
  do not exist (compile-time check) or are nil (runtime check).
- An app-level test wires a fake `LabandTerminalSessionClient` (or uses
  the existing real-daemon harness from `LabandControlProtocolTests`)
  with a session whose `LabandSessionInfo` carries
  `foregroundCommand = "claude"`, calls the coordinator's metadata-refresh
  entry point, and asserts that the tab's `titleMetadata.process` reflects
  `"claude"` and that `TabTitleResolver.resolve(...)` returns a non-
  fallback display title.
- The `/debug/sessions` HTTP endpoint exposes a tab whose
  `titleMetadata.process.foregroundCommand` is set in background mode.
  Add an assertion to `LabandHeadlessBackendTests` or write a new one.

**M3 (default background):**

- A unit test calls
  `FrameProducer.commands(from: LabandSnapshotResponse, ...)` with a
  snapshot whose `defaultBackgroundRGBA = 0x123456FF` and whose
  `cells.first?.backgroundRGBA = 0`. It asserts the first emitted `.rect`
  uses `0x123456FF`. Without the fix the test fails because the first
  emitted rect uses 0.
- A second unit test verifies the legacy fallback: when
  `defaultBackgroundRGBA == 0`, the path falls back to
  `cells.first?.backgroundRGBA ?? Theme.current.bg0`.

**Whole build:** `./scripts/build-app` succeeds. `swift test` is green.

## Idempotence and Recovery

All edits are additive at the protocol level (new optional struct fields
default to nil or zero in older payloads). Re-running `./scripts/build-app`
and `swift test` is safe. No journal migration required — process metadata
is derived from the live foreground PID, so a restarted daemon
re-populates the fields on its next snapshot.

## Interfaces and Dependencies

Modules touched:

- `LabanCore` (FrameProducer remote overload, LabandProtocol additions,
  AppModel public surface widening).
- `Laband` daemon (ManagedLabandSession storage, snapshotResponse,
  refreshProcessMetadata, sessionInfo).
- `LabanApp` (AppLabandSessionCoordinator metadata accessor and refresh
  call site in TerminalBitmapView's render loop).
- `LabanRenderer` (no change; `BoxDrawing` is already public).

Public signatures the milestones must expose at completion:

```swift
// LabanCore.AppModel — widen existing internal method.
public func applyProcessMetadata(
  _ metadata: Session.ProcessMetadata,
  forTab tabId: Tab.ID,
  now: Date = Date()
) -> Bool

// LabanCore.LabandProtocol — additive.
public struct LabandSessionInfo {
  // ...existing fields...
  public var foregroundProcess: String?
  public var foregroundCommand: String?
  public var foregroundArguments: [String]?
  public var daemonCwd: String?
}
public struct LabandSnapshotResponse {
  // ...existing fields...
  public var defaultBackgroundRGBA: UInt32
}

// LabanApp.AppLabandSessionCoordinator — new accessor.
func processMetadata(for tab: Tab) -> Session.ProcessMetadata?
func refreshTabMetadata(into model: AppModel, tabs: [Tab])
```

## Decision Log

- **Decision:** One umbrella ExecPlan with three milestones rather than
  three separate plans.
  **Rationale:** All three regressions share a single root domain
  (background-mode parity) and the milestones can validate the
  build/verify loop incrementally. PLANS.md treats milestones as the
  staging mechanism for exactly this case.
  **Date/Author:** 2026-05-26 / executing agent.

- **Decision:** Order milestones by tightest blast radius first:
  M1 (one branch, one test), then M2 (cross-process plumbing), then
  M3 (hypothesis-driven, no reproducer).
  **Rationale:** M1 proves the build/verify loop and the FrameProducer
  test scaffold. M2 builds on that scaffold and adds the daemon test
  harness. M3 is hypothesis-driven; we want as much of the safe work
  shipped before we touch the speculative one.
  **Date/Author:** 2026-05-26 / executing agent.

- **Decision:** Bridge daemon process metadata into the tab model via a
  new `AppLabandSessionCoordinator` accessor + a widened public
  `AppModel.applyProcessMetadata`, rather than teaching `Session` to
  return remote metadata.
  **Rationale:** `Session` is an in-process libghostty wrapper; adding
  daemon awareness to it would bleed the daemon transport into the
  terminal-core layer, which ADR 0001 / ADR 0005 keep separate. The
  coordinator is the right seam.
  **Date/Author:** 2026-05-26 / executing agent.

- **Decision:** Treat M3 as a hypothesis-driven defensive fix, not a
  promise that the user-reported black border is gone.
  **Rationale:** The bug has no reliable reproducer. The hypothesis (zero
  RGBA on the first remote cell leaks into the terminal-area background
  rect) is testable in isolation. The plan acceptance is phrased around
  the hypothesis, not the user observation, so a future regression in a
  different code path stays in scope as a follow-up.
  **Date/Author:** 2026-05-26 / executing agent.

## Surprises & Discoveries

- **Observation:** `refreshProcessMetadata` was being called from
  `sessionInfo(_:)` on every catalog read, which fires whenever any client
  calls `listSessions`. With the app's 4 Hz `refreshTabMetadata` poll and
  N sessions per daemon that becomes 4N foreground-process polls per
  second across the daemon.
  **Evidence:** Inspecting the call graph in `Sources/Laband/main.swift`
  after wiring M2 — `sessionInfo` → `refreshProcessMetadata` →
  `Session.processMetadata` → libghostty / `process_metadata.c`.
  **Decision:** Added a 1 Hz per-session throttle inside
  `refreshProcessMetadata` (1_000_000_000 ns floor on
  `lastForegroundProcessPollMonoNs`). Foreground-command transitions
  remain visually instantaneous to the user.

- **Observation:** `refreshTabMetadata` is a synchronous unix-socket
  roundtrip on the main thread inside `TerminalBitmapView.beginRender`.
  Throttled at ~4 Hz client-side; under a slow daemon this could cause a
  per-frame hitch every 250 ms.
  **Decision:** Accept for now. The control protocol's `listSessions` is
  a single small JSON payload, the socket is local, and the daemon's
  1 Hz internal throttle on the heavy `processMetadata` call keeps it
  cheap. If a future profile shows hitching, move the poll onto the
  snapshot-generation monitor's queue or a dedicated timer.

- **Observation:** All three regressions (M1 block-element seam, M2
  foreground-process metadata, M3 default background color) share a
  single shape: libghostty produces state in the daemon, the
  parsed-state-over-IPC schema does not carry it, and the app's renderer
  improvises a fallback that fails silently. This is a recurring
  bug-class, not a coincidence.
  **Decision:** Documented as the load-bearing motivation for
  `docs/adr/0006-three-tier-session-architecture.md` (Three-Tier Session
  Architecture, accepted 2026-05-26). Under the layered architecture
  introduced by ADR 0006, M1/M2/M3 become the regression contract for
  `laband`'s multi-client serving mode specifically; the new
  single-client mode (laband forwards the byte ring and the app parses
  in-process) cannot produce regressions of this class because there is
  no parsed-state serialization between libghostty and the renderer.
  Phase 1 of the migration is scoped in
  `execplans/active/labpty-extraction.md`.

## Review Gate

A separate fresh-state agent must verify the following before this plan is
considered complete:

- [ ] `git grep -n 'BoxDrawing.isProceduralCellElement' Sources/LabanCore/FrameProducer.swift`
      returns at least two hits (one in the local overload, one in the
      remote overload).
- [ ] `swift test --filter LabanCoreTests.FrameProducerRemoteBlockElementTests`
      exits 0.
- [ ] `git grep -n 'foregroundCommand' Sources/LabanCore/LabandProtocol.swift`
      returns at least one hit.
- [ ] `git grep -n 'foregroundCommand' Sources/Laband/main.swift` returns
      at least one hit, and it is reached by `refreshProcessMetadata` or
      `sessionInfo`.
- [ ] `swift test --filter LabandTests.LabandSessionMetadataTests` exits 0.
- [ ] `swift test --filter LabanAppTests.AppLabandSessionCoordinatorTests`
      exits 0.
- [ ] `git grep -n 'defaultBackgroundRGBA' Sources/LabanCore/LabandProtocol.swift Sources/Laband/main.swift Sources/LabanCore/FrameProducer.swift Sources/LabanCore/TerminalSurfaceController.swift`
      returns at least four hits.
- [ ] `./scripts/build-app` succeeds.

Review status: NOT REVIEWED

Review findings (filled in by the review agent):

(none yet)
