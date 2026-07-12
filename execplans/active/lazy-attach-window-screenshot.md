# Lazy-Attach Full-Window Screenshots

This ExecPlan is a living document maintained in accordance with `PLANS.md` at
the repository root. Keep `Progress`, `Decision Log`, and `Validation and
Acceptance` current as work proceeds.

## Purpose / Big Picture

An agent already running inside a normal Laban tab can read terminal text and
scrollback after a user-approved lazy attach, but it cannot see the surrounding
window chrome or an open sheet/dialog. That makes UI debugging needlessly blind:
the terminal model can be correct while the visible approval sheet, proposal
sheet, title bar, sidebar, or status chrome is wrong.

After this change, the agent can run:

    laban session screenshot --output /tmp/laban-window.png --json

Laban asks for a separate window-screenshot permission. On approval it captures
the visible Laban window containing the requesting session, including title bar,
sidebar, attached sheets, and child dialogs, then the CLI writes a mode `0600`
PNG and prints JSON metadata. A stable signed principal may choose Always Allow
for this exact route so later captures can observe an already-open dialog without
putting another consent sheet in front of it. The request is rejected when the
caller's session is not the visible active tab, so it cannot expose another
session's terminal content by switching tabs behind the agent.

The related 400-line history behavior already exists and requires no control
plane change:

    laban session get-text --scrollback --max-lines 400 --json

The installed Codex/Claude skill will call that out explicitly alongside the new
screenshot command.

## Progress

- [x] (2026-07-11) Confirmed `terminal.getText` already supports bounded
  scrollback reads larger than the visible grid.
- [x] (2026-07-11) Inspected the GUI intent router, lazy approval store and
  presenter, route/intent catalogs, CLI parser, AppKit probe screenshot seam,
  threat-model invariants, and GUI parity tests.
- [x] (2026-07-11) Chose a request-exact screenshot grant and JSON/base64
  transport design.
- [x] (2026-07-11) Implement the core response type, GUI-only intent, route, allowlist entry,
  and request-exact lazy approval branch.
- [x] (2026-07-11) Implement full-window AppKit capture, including attached sheets and child
  dialogs, with active-session enforcement and a 10 MiB PNG ceiling.
- [x] (2026-07-11) Implement `laban session screenshot [--output PATH] [--json]` and secure
  local file writing.
- [x] (2026-07-11) Add focused control, CLI, presenter, router, and capture tests.
- [x] (2026-07-11) Update the threat model, controlling-agent guide, CLI help, and installed
  Codex/Claude skill.
- [x] (2026-07-11) Run focused tests, generated-contract checks, skill validation,
  and install the profilable release bundle without interrupting the active app.
- [x] (2026-07-12) Diagnosed why live capture never produced a PNG: several
  compounding permission/registration issues plus one root cause.
- [x] (2026-07-12) Migrated `LabanWindowScreenshotCapture.capture(window:)` to
  ScreenCaptureKit for macOS 14+, keeping the legacy `CGImage` path for <14.
- [x] (2026-07-12) Restarted Laban and verified a live lazy screenshot artifact
  visually: `laban session screenshot` returned a real 2400x1576 PNG of the full
  window (title bar, sidebar, terminal content) with no permission dialog.
- [x] (2026-07-12) Reproduced that a separate visible Settings window is omitted
  even when it is key, because it is not an AppKit child of the terminal window.
- [x] Extend the exact screenshot capture with the visible, explicitly identified
  Settings window and its attached dialogs; retain the exclusion of arbitrary
  top-level Laban windows and other applications.
- [x] Add focused capture-selection regression coverage and run focused tests.
- [x] Build and install the release app at `~/Laban.app`.
- [ ] Restart the installed app and verify the live Settings capture through
  `laban session screenshot`.
- [x] (2026-07-12) Diagnosed recurring lazy-attach `ENOENT` as a concurrent
  XCTest server displacing the live app's shared Unix socket, not an approval
  timeout.
- [x] Prevent live-socket displacement and isolate XCTest's default control
  directory; the second-server regression test proves the first listener stays
  reachable.
- [x] Build and install the control-socket fix at `~/Laban.app`.
- [ ] Restart the installed app and verify repeated lazy screenshots while a
  parallel XCTest worktree is active do not lose the control socket.

## Discoveries and Surprises

- Observation: A test process from another worktree could orphan the live app's
  listener without stopping it. `prepareSocketPath` unlinked any existing socket
  before binding; a test then bound the same pathname and removed it at teardown.
  Evidence: live `lsof -U` showed LabanApp PID 81924 and a faster-checks
  `LabanPackageTests.xctest` process owning the shared
  `~/Library/Application Support/Laban/control.sock` pathname at different
  points in the collision. The live app retained its listener FD after the test
  teardown, but the pathname was gone and lazy attach returned `ENOENT`.

- Observation: The repository-wide `./scripts/check` reached the broad XCTest
  stage and remained active for more than four minutes without printing a
  failure, so its process was stopped to release the shared SwiftPM build lock.
  Evidence: Focused `LabanWindowScreenshotCaptureTests`, `LiveControlObserveTests`,
  `ControlAvailabilityParityTests`, `./scripts/format`, and `./scripts/lint`
  completed successfully before the release install.

- Observation: The macOS 26 SDK removes the old
  `CGWindowListCreateImageFromArray` Swift spelling in favor of the
  `CGImage(windowListFromArrayScreenBounds:windowArray:imageOption:)`
  initializer.
  Evidence: The initial compile failed on the old symbol; the replacement builds
  and the helper's related-window selection tests pass.
- Observation: Ordering synthetic AppKit windows in the shared XCTest process
  contaminated the following labpty process test and made XCTest exit with
  signal 11, although each suite passed alone.
  Evidence: Running the two suites together reproduced the crash. Refactoring
  the capture selection into a pure related-window graph test made the same
  six-test sequence pass. Production capture still uses the same own-window
  Core Graphics mechanism as Laban's existing AppKit terminal probe.
- Observation: The repository gate reaches one stable pre-existing renderer
  threshold failure unrelated to this control-plane change.
  Evidence:
  `testDefaultVectorTextFidelityStaysNearMetalOnLightBackground` reports partial
  edge spread `0.4556901650290947` over ceiling `0.43275590551181103` both in
  the full gate and when rerun alone. All focused screenshot/control tests pass.

## Decision Log

- Decision: Keep `window.screenshot` outside `ControlSessionObserveFamily` and
  persist only an exact route/intent grant.
  Rationale: A full-window image is broader than own-session text. It may contain
  sidebar metadata and dialogs. Widening the family would make an existing
  read-family approval silently authorize this new data class and filesystem
  workflow. An exact grant gives it explicit wording and independent revocation.
  Date/Author: 2026-07-11 / Codex.

- Decision: Allow Always Allow only for the exact screenshot route and only for
  a stable signed principal under the existing persistence rules.
  Rationale: A one-time screenshot approval sheet necessarily closes before the
  image is captured. A remembered exact grant is what makes the debugging use
  case possible when another dialog is already open, without granting unrelated
  reads or actions.
  Date/Author: 2026-07-11 / Codex.

- Decision: Return PNG bytes as base64 inside a typed JSON response and let the
  CLI write the output file.
  Rationale: Existing broker and lazy transports are JSON/text oriented. This
  avoids teaching both proxy protocols a second binary framing format and avoids
  letting the GUI process write an agent-selected arbitrary filesystem path.
  Date/Author: 2026-07-11 / Codex.

- Decision: Require the lazy caller's bound session to be the active visible tab
  at capture time.
  Rationale: The whole window includes terminal content. Without this check an
  agent in tab A could wait for tab B to become active and capture tab B, breaking
  the own-session boundary. Window chrome and tab/sidebar metadata are already
  available through app-observe, but hidden-session terminal content is not.
  Date/Author: 2026-07-11 / Codex.

- Decision: Capture the main window plus visible attached sheets and child
  windows, not the desktop.
  Rationale: The user specifically needs dialogs for debugging, while desktop
  capture could expose unrelated applications and would require macOS screen
  recording permission.
  Date/Author: 2026-07-11 / Codex.

- Decision: Treat only the visible `LabanSettings` window as an auxiliary root
  for `window.screenshot`.
  Rationale: Settings is a separate top-level AppKit window and therefore is not
  reachable through the terminal window's sheet/child hierarchy. Including all
  frontmost or all same-process windows would weaken the documented boundary by
  exposing unrelated future Laban windows. A stable AppKit window identifier
  lets the app inject Settings only when it is already visible; its own sheets
  and child dialogs remain included through the existing recursive selection.
  Date/Author: 2026-07-12 / Codex.

## Context and Orientation

Laban's live control plane is HTTP over a same-user Unix domain socket. A normal
agent process with no broker can call `POST /control/session/attach/request` with
an intended request. `Sources/LabanControl/LabanControlServerLazyAttach.swift`
verifies process ancestry, resolves the intent server-side, presents an approval
dialog, revalidates identity after approval, and dispatches once under a scoped
token. `Sources/LabanControl/ControlAttachApprovalStore.swift` can remember an
exact signed-principal grant containing the session, route, intent, capability,
data sensitivity, and side-effect class.

Most current lazy commands use `ControlSessionObserveFamily`, a whole-family
grant covering session text/state, scrolling, and command proposals. A full
window screenshot must not join that family. `ControlLazyAttachAllowlist.Entry`
already has a `persistable` flag, but the current server implementation assumes
every allowlisted request is a family request. This change restores a general
request-exact branch alongside the family branch.

The existing `GET /debug/screenshot` artifact route is headless-only and returns
renderer pixels, not AppKit window chrome or dialogs. The new route is
`GET /debug/window-screenshot`, intent `window.screenshot`, and returns typed
JSON containing base64 PNG data and pixel dimensions. `LiveIntentRouter` runs on
the main thread and will receive a capture provider bound by
`MainWindowController` after the real `NSWindow` exists.

`SettingsWindowController` owns a separate top-level `NSWindow`; it is neither a
sheet nor a child window of `MainWindowController.window`. The capture helper's
current related-window graph intentionally filters it out. Give the Settings
window a stable `NSUserInterfaceItemIdentifier`, and have `AppDelegate` provide
that window to `MainWindowController` only while it is visible. The helper must
accept explicit auxiliary roots and recurse through their sheets/children just
as it does for the main window.

`Sources/LabanApp/AppKitTerminalProbes.swift` proves that this application can
capture its own `NSWindow` through CoreGraphics. The new production helper will
use the Core Graphics multi-window `CGImage` initializer over the main window
plus its visible sheets/children so the image includes dialog surfaces while
excluding other applications and unrelated Laban windows.

The CLI parser and execution live in `Sources/LabanCLI/LabanCommand.swift` and
`Sources/LabanCLI/LabanCLI.swift`. Broker and lazy responses are already text
JSON, so a base64 response traverses both unchanged. The CLI decodes it, enforces
the PNG signature and 10 MiB ceiling, writes a private file, and emits metadata
without echoing image data.

## Plan of Work

Add `WindowScreenshotResponse` and its JSON schema in `LabanCore` and
`schemas/debug/`. Add a GUI-only `window.screenshot` descriptor with
`observeSensitive` capability and `screenshot` data sensitivity. Bind
`GET /debug/window-screenshot` in `ControlRouteCatalog` and add an exact,
persistable lazy allowlist entry.

Generalize `LabanControlServerLazyAttach` so a family intent continues to mint
and persist the whole-family token/record, while a non-family allowlist entry
mints and persists only the exact resolved request. Build approval presentation
content specifically for a full-window screenshot: what it includes, what it
cannot do, and whether the exact permission can be remembered. Keep raw
`session request` non-persistable.

Add a small AppKit capture helper and inject it into `LiveIntentRouter`. Before
capture, verify the scoped session matches `model.activeTab.sessionId`; return
HTTP `409 sessionNotVisible` otherwise. Capture the main window and its visible
sheets/children, encode PNG, reject empty or over-10-MiB payloads, then return the
typed response.

Extend the CLI with `session screenshot`, an optional `--output`, and JSON/plain
output. With no output path, choose a unique file in the per-user temporary
directory. Create parent directories only when the caller explicitly supplied a
path, write atomically, and set mode `0600`. Never print the base64 payload.

Update security/process docs and the shared skill in
`~/.codex/skills/laban-terminal-control`; the Claude installation is a symlink to
that canonical folder and therefore updates automatically.

## Concrete Steps

Run all commands from `/Users/rrj/wrk/laban` and preserve unrelated dirty files.

1. Add source and tests with focused iteration:

       rtk swift test --filter LabanCLITests
       rtk swift test --filter LazyAttach
       rtk swift test --filter WindowScreenshot
       rtk swift test --filter ControlPlaneInvariantTests
       rtk swift test --filter ControlAvailabilityParityTests

2. Run the repository gate:

       rtk ./scripts/check

3. Build/install and verify the visible app if the gate is green enough to do
   so safely:

       rtk ./scripts/install-app

   Restart Laban, then from an agent already running in a normal Laban tab:

       laban session get-text --scrollback --max-lines 400 --json
       laban session screenshot --output /tmp/laban-window.png --json

   Open the PNG and verify it contains the whole Laban window and an existing
   test sheet/dialog when one is open.

## Validation and Acceptance

Acceptance requires all of the following observable behavior:

- `laban session get-text --scrollback --max-lines 400 --json` returns up to 400
  historical lines and is not limited to the visible grid.
- The first lazy `session screenshot` presents screenshot-specific consent, not
  the generic whole-family wording.
- Choosing Allow Once returns one screenshot and does not authorize a second
  request silently.
- Choosing Always Allow for a stable signed principal allows a later screenshot
  without a new sheet, and the Settings approval record contains only the exact
  screenshot route and intent.
- The PNG contains the complete visible main window plus attached sheets/child
  dialogs, not only terminal renderer pixels and not other applications.
- If another tab is active, the caller receives `409 sessionNotVisible` and no
  PNG.
- The output is a valid PNG, no larger than 10 MiB, mode `0600`, and the CLI JSON
  omits base64 data.
- Existing family grants, broker commands, app-observe restrictions, input and
  clipboard denials, and cross-session reads remain unchanged.
- `ControlPlaneInvariantTests`, lazy-attach tests, CLI tests, GUI availability
  parity, and the repository gate pass or any unrelated baseline failures are
  recorded with exact evidence.

## Idempotence and Recovery

Source edits and tests are repeatable. Screenshot output defaults to a unique
temporary filename; an explicit output path may be replaced only by the caller's
request and is reset to mode `0600`. Test artifacts live in temporary directories
and are removed by test teardown. If live capture fails, keep the JSON/state
transcript and report the CoreGraphics error without weakening scope checks or
falling back to desktop capture.

## Outcomes

The repository now has a GUI-only, request-exact window screenshot intent and
lazy route, screenshot-specific approval UI, active-session enforcement,
full-window AppKit capture selection, bounded typed transport, secure CLI file
writing, generated discovery schema, documentation, and focused regression
coverage. The shared Codex skill and Claude symlink installation both describe
400-line scrollback reads and the full-window screenshot workflow.

Focused screenshot/control tests, the generated catalog check, Swift formatting,
and both installed skill validations pass. The release bundle installed at
`~/Laban.app` and its bundled CLI advertises `session screenshot`. The full
repository gate reaches one stable unrelated renderer fidelity threshold failure
recorded above; no screenshot/control test fails. Live visual verification is
deferred until the user restarts Laban because restarting the currently active
terminal would terminate this agent session.

## Interfaces and Dependencies

- `WindowScreenshotResponse` in `LabanCore`: Codable response with `ok`,
  `pngBase64`, `width`, `height`, `byteCount`, and `includesDialogs`.
- `GET /debug/window-screenshot`: GUI-only, `window.screenshot`,
  `observeSensitive`, sensitivity `screenshot`.
- `LiveIntentRouter.bindWindowScreenshotProvider(...)`: main-thread provider
  returning PNG data and pixel dimensions.
- `LabanWindowScreenshotCapture.capture(window:)`: AppKit/CoreGraphics helper
  capturing the main window plus visible attached sheets/children and explicitly
  supplied visible Settings roots.
- `laban session screenshot [--output PATH] [--json]`: broker-or-lazy CLI that
  writes a private PNG and returns path/size metadata.
