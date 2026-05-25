# Make `laband` Own Live Terminal Sessions

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

After this work, quitting, crashing, or upgrading the Laban app must not kill
important live terminal work. A separate per-user background process named
`laband` will own PTYs, child processes, terminal parser state, scrollback, and
session metadata. The app becomes a renderer/controller that can detach and
reattach to those live sessions. Claude Code and Codex remain first-class:
when a live PTY survives, the app reattaches; when the PTY is gone, Laban still
offers the existing semantic resume workflow.

The most important user-visible test is simple: start Claude Code or Codex in
Laban, quit or replace the app, relaunch, and see the same live process still
running without flicker or sluggish input.

## Progress

- [x] (2026-05-24) Completed M0 before-measurement target
  `bench-keystroke-latency` and recorded release baseline numbers in
  `execplans/active/keystroke-latency-baseline.md`.
- [x] (2026-05-24) Spawned a fresh review agent for this ExecPlan and folded
  its blocking findings into the milestone gates: M3 needs a daemon-mode
  benchmark, ADR 0005 must gate M1, and debug/headless parity needs explicit
  acceptance.
- [x] (2026-05-24) Researched post-Mosh terminal persistence/state-sync
  systems and refined M3 around latest-coherent semantic state rather than
  generic GPU or image transport.
- [x] (2026-05-24) Addressed the second fresh review pass by making the
  remaining milestone acceptance checks name exact test files, scripts,
  commands, and snapshot-ring ABI fields.
- [x] (2026-05-25) Drafted and accepted
  `docs/adr/0005-laband-owns-live-session-pty-lifecycle.md`, and indexed it
  from `AGENTS.md`. This satisfies the hard prerequisite before M1
  implementation starts.
- [x] (2026-05-25) M1: created a real `laband` executable that owns one
  PTY-backed `LabanCore.Session` in dev/test mode over the length-prefixed
  JSON control socket. `Tests/LabandTests/LabandControlProtocolTests.swift`
  launches `.build/debug/laband`, creates `/bin/cat`, writes `x`, observes the
  echo in a daemon snapshot, verifies the child process parent is the daemon
  pid, terminates the session, and observes `listSessions` marking it
  terminated.
- [x] (2026-05-25) Started M2 by adding the AppKit-free
  `TerminalSessionClient` boundary in `LabanCore`, with
  `InProcessTerminalSessionClient` and `LabandTerminalSessionClient`
  implementations. The `LabandControlProtocolTests` coverage now drives the
  daemon through `LabandTerminalSessionClient` instead of a test-local socket
  client.
- [x] (2026-05-25) M2: wired `LABAN_TERMINAL_BACKEND` through the AppKit
  launch path and the headless debug runtime. Headless laband mode now starts
  or connects to a run-id-scoped daemon, creates a remote `/bin/cat` session
  using the tab session id as the logical session id, routes `typeText` and
  resize through `TerminalSessionClient`, and exposes `transportMode`,
  `logicalSessionId`, `incarnationId`, `daemonProcessPid`, attached-client
  count, and lease holder fields from `/debug/sessions`.
- [x] M2: add a versioned local client protocol and connect the app/headless
  harness through it for one session.
- [x] (2026-05-25) M3: added the normative
  `LBNDSS01` snapshot-ring ABI in Swift and C, `attachSnapshotRing` control
  negotiation, daemon-side mmap ring publication from the PTY reader path,
  client-side coherent ring sampling, direct ring echo sampling in
  `bench-keystroke-latency`, and ring coverage in
  `LabandControlProtocolTests`. The fresh-state M3 review gate passed after
  the run-id path-scope fix.
- [x] (2026-05-25) Addressed the first M3 review gate block by removing fixed
  reusable dev/test artifact and temp defaults from `scripts/run-debug`,
  `scripts/run-headless`, `scripts/smoke-runtime`, and the benchmark's laband
  journal fallback. These paths now come from `LABAN_RUN_ID`, explicit
  `LABAN_ARTIFACTS`/`LABAN_TMP`, or a generated per-run id.
- [x] M3: move terminal snapshots to a low-latency shared-memory transport.
- [x] (2026-05-25) M4: added an append-only `lifecycle.jsonl` under the
  run-id-scoped `--journal` directory. `laband` now syncs session-created,
  lease-transfer, terminate-requested, and session-terminated records before
  acknowledging those lifecycle operations, replays terminated/dead session
  catalog entries on restart, and exposes minimal lease history through
  `listSessions`.
- [x] M4: persist session catalog and append-only lifecycle journal.
- [ ] M5: support detach/reattach across app restart without killing the live
  PTY.
- [ ] M6: restore Claude/Codex semantic resume on daemon loss while preserving
  the existing restore picker workflow.
- [ ] M7: multi-attach read-only observers plus a single input/resize lease.
- [ ] M8: ship upgrade-safe launchd lifecycle and compatibility checks.

## M0 Baseline

M0 is complete. It exists to keep the `laband` migration honest: every later
milestone must compare against the current in-process architecture before
claiming low latency.

Primary release results from `bench-keystroke-latency`:

| Grid | Raw rendered frame p50 / p95 / p99 | Estimated current AppKit commit p50 / p95 / p99 | Estimated photon mean p50 / p95 / p99 |
| --- | ---: | ---: | ---: |
| 80x24 | 0.272 / 0.344 / 0.367 ms | 12.272 / 12.344 / 12.367 ms | 16.439 / 16.511 / 16.534 ms |
| 120x36 | 0.512 / 0.682 / 1.171 ms | 12.512 / 12.682 / 13.171 ms | 16.679 / 16.849 / 17.338 ms |
| 160x48 | 0.706 / 0.838 / 0.885 ms | 12.706 / 12.838 / 12.885 ms | 16.872 / 17.005 / 17.052 ms |

The modeled current AppKit estimate is dominated by the output-settle policy:
a 12 ms quiet window in `Sources/LabanApp/TerminalRenderGate.swift`. The M0
harness does not physically measure photons, WindowServer, or onscreen Metal
presentation. It measures keystroke-to-rendered-frame in the headless/offscreen
path and then adds deterministic policy estimates. The raw PTY echo, snapshot,
command extraction, and software render path is already under 1 ms p99 at
160x48. `laband` must not add noticeable local latency. A local `laband`
reattach path should target less than 0.5 ms p50 and less than 2 ms p95
overhead over the M0 raw total.

Artifacts from the M0 run are under:

- `.artifacts/runs/keystroke-latency-before/result-release-80x24.json`
- `.artifacts/runs/keystroke-latency-before/result-release.json`
- `.artifacts/runs/keystroke-latency-before/result-release-160x48.json`

## Definitions

`laband` is a daemon: a background process that keeps running after the app UI
exits. In this repository it will be a Swift executable target plus lower-level
C/Swift code that owns `LabanTerminalCore` sessions.

A PTY is a pseudo-terminal: the OS object that connects Laban to a shell or
agent process. Today the app process owns the PTY through
`Sources/LabanTerminalCore/session_lifecycle.c`, as documented in
`docs/adr/0001-libghostty-vt-owns-vt-parsing.md` and
`docs/adr/0002-pty-launch-uses-openpty-constrained-fork.md`. This plan changes
that ownership, so it requires a new ADR before implementation.

A logical session is the durable user-facing session identity. It survives app
restart and can survive semantic Claude/Codex resume. An incarnation is one
PTY/process lifetime under that logical session.

A client is an app, headless test harness, or future network viewer attached to
`laband`. Many clients may observe one session, but only one client holds the
input/resize lease.

## Decision Log

- Decision: `laband` owns the PTY master fd, shell child/process group,
  `LabanTerminalCore` session, libghostty-vt parser state, scrollback, title,
  terminal modes, input encoding state, process metadata, agent detection,
  transcript writing, durable catalog, and append-only journal.
  Rationale: Live process survival requires the object that owns the PTY to
  outlive the app. Splitting parser state from PTY state would create two
  terminal truths and make flicker/latency worse.
  Date/Author: 2026-05-24 / Design grilling.

- Decision: The app owns AppKit input normalization, window/sidebar layout,
  renderer selection, glyph atlas, Metal/software drawing, menus, and update UI.
  Rationale: Presentation belongs with the visible client. Keeping CAMetalLayer
  and glyph rasterization in the app avoids a remote-GPU command protocol and
  keeps local rendering low-latency.
  Date/Author: 2026-05-24 / Design grilling.

- Decision: The local hot path uses semantic terminal snapshots, not JSON and
  not generic GPU command streaming. `laband` publishes immutable snapshots
  through a triple-buffer/shared-memory ring; clients render locally.
  Rationale: JSON is too slow for frame cadence. Generic GPU command streaming
  has a large security and compatibility surface. Semantic snapshots preserve
  a narrow terminal contract and keep the renderer close to the display.
  Date/Author: 2026-05-24 / Design grilling.

- Decision: Snapshot delivery is latest-coherent-state-wins. A client may skip
  intermediate generations, but every generation it renders must be internally
  complete and must identify the terminal state, cursor, damage, scrollback
  anchor, and input sequence metadata that produced it.
  Rationale: Mosh's post-SSH contribution was to fast-forward the user to the
  current terminal state instead of replaying stale bytes. Same-machine Laban
  can use that abstraction without WAN packet loss and without adding an 8 ms
  mobile-network collection delay.
  Date/Author: 2026-05-24 / Post-Mosh research.

- Decision: The v1 shared-memory snapshot format reserves `inputSeqApplied`
  and `echoAckSeq` fields even if speculative local echo ships later.
  Rationale: Mosh eliminated prediction flicker by letting authoritative
  server state say which keystrokes had had enough time to affect the screen.
  Reserving these sequence fields now prevents a protocol break when Laban
  later adds prediction for local or network clients.
  Date/Author: 2026-05-24 / Post-Mosh research.

- Decision: Do not compress the local hot-path snapshot in v1. Use packed
  binary cells, dirty row ranges, fixed-size headers, generation counters, and
  no allocation on the render path. Compression is reserved for network casting,
  replay artifacts, or cold scrollback transfer.
  Rationale: A terminal grid is small by graphics standards. M0 shows the local
  compute path is already sub-millisecond; compression would add complexity and
  latency risk before evidence says it is needed.
  Date/Author: 2026-05-24 / Post-Mosh research.

- Decision: Reserve capability-negotiated future transports named
  `sharedTexture/v1` and `encodedVideo/v1`, but do not make them v1 defaults.
  Rationale: Shared textures are useful for exact-pixel previews, casting, and
  future network work, but the best local keystroke latency is app-side render
  from semantic state.
  Date/Author: 2026-05-24 / Design grilling.

- Decision: Product `laband` is a per-user ServiceManagement LaunchAgent with
  an XPC listener. Dev/test may use explicit Unix sockets under `.tmp/<run-id>`.
  Rationale: Sessions must survive app UI exit and upgrade. Worktree isolation
  forbids fixed global dev sockets and ports.
  Date/Author: 2026-05-24 / Design grilling.

- Decision: Close Tab terminates the session. App quit/window close detaches.
  Rationale: This preserves the shipped MVP close-tab semantics while adding
  live survival for app lifecycle events.
  Date/Author: 2026-05-24 / Design grilling.

- Decision: Claude Code and Codex are first-class agents. The existing weak
  process/session-file detection is valid for durable restore metadata. Future
  structured integrations are allowed, but anything that modifies Claude or
  Codex user-visible config is deferred.
  Rationale: The current detection works and should keep working. Hidden agent
  config mutation would damage trust and needs separate opt-in design.
  Date/Author: 2026-05-24 / User direction.

- Decision: Tests and headless mode must use a real `laband` process for any
  behavior that claims PTY/session lifecycle, restore, attach, detach, or
  daemon ownership. Pure parser, codec, and renderer unit tests may stay direct.
  Rationale: A fake daemon would miss exactly the lifecycle bugs this feature
  exists to prevent.
  Date/Author: 2026-05-24 / User direction.

## Research: 2026 State Of The Art After Mosh

This section records the design research so a fresh contributor does not need
the conversation history.

Mosh proved the most important abstraction for interactive terminals: the
remote endpoint should synchronize terminal state, not force the client to
replay every byte of historical output. The server owns a terminal emulator,
the client renders a current screen object, intermediate screen states may be
skipped, and input remains a priority path. Mosh also showed that prediction
without an authoritative echo acknowledgment flickers; its later design put an
echo-ack field into the synchronized terminal object. Mosh's known limitation
is scrollback: synchronizing only the current screen can lose history during
disconnects or floods.

Post-Mosh systems split into useful families:

| System family | What it proves | What Laban should copy | What Laban should avoid |
| --- | --- | --- | --- |
| `tmux`/`screen` | A separate process can own PTYs and survive client detach. | PTY ownership lives outside the visible app; close vs detach is explicit. | Text UI borders and byte replay as the primary native app interface. |
| `tmux -CC` / iTerm2 integration | A terminal app can render multiplexer panes as native tabs/panes through a structured control protocol. | Separate session control from native presentation; keep app UI native. | Letting a slower client accumulate unbounded output debt. |
| WezTerm mux domains | A terminal GUI can attach to a local or remote daemon/mux over Unix sockets, SSH, or TLS while the daemon owns panes. | `laband` as a per-user mux daemon with versioned attach/detach. | Making the daemon own all renderer/glyph/Metal policy by default. |
| VS Code persistent terminals | Users expect process reconnection after window reload and safe process revive after full restart. | Distinguish live reattach from semantic relaunch and expose both. | Pretending relaunched commands are the same as still-live PTYs. |
| Zellij session resurrection | Layout, commands, viewport, and optional scrollback can be serialized, but rerunning commands is hazardous. | Keep the low-friction restore picker and default risky semantic resume unchecked. | Auto-running recovered commands after daemon loss. |
| Eternal Terminal | Reconnectable remote shells are valued; native scrolling and tmux control-mode compatibility matter. | Preserve client-native scrollback/search where possible. | Treat reconnect alone as enough; Laban also needs app-upgrade survival. |
| Agent terminals such as Warp Full Terminal Use | Modern terminals expose the active PTY/buffer to agents and let user and agent trade control. | Model Claude/Codex and future agents as first-class clients competing for the input lease. | Hidden agent config mutation or ambiguous control ownership. |

The 2026 target for Laban is therefore not "Mosh but local" and not "tmux with
a prettier skin." It is a combined design: WezTerm-style daemon ownership,
Mosh-style latest-state synchronization, VS Code-style live reattach vs revive,
Zellij-style cautious semantic recovery, and agent-aware lease control. The
hot path remains terminal-semantic and locally rendered.

## Review Gate

A separate fresh-state review agent must verify these checks before M3 is
considered complete. The executing agent must not mark this ExecPlan complete
until the gate passes.

- [ ] `docs/adr/0005-*.md` exists, `AGENTS.md` indexes it, and the ADR states
  that `laband` owns the process running `LabanTerminalCore` while preserving
  ADR 0002's `openpty`/fork/process-group invariants.
- [ ] `bench-keystroke-latency` supports both `--transport in-process` and
  `--transport laband --socket <path>`; the M3 acceptance command measures the
  daemon path, not just the original in-process baseline.
- [ ] `bench-keystroke-latency` exits nonzero unless stdout contains
  `verifiedEcho=<samples>/<samples>`.
- [ ] Headless/debug mode starts or connects to a real `laband` process for
  attach/detach/restore lifecycle tests; no test-only fake daemon claims
  lifecycle coverage.
- [ ] Dev/test sockets, journals, pid files, artifacts, and temp dirs are all
  under explicit run-id paths such as `.tmp/<run-id>/` or
  `.artifacts/runs/<run-id>/`; there are no fixed global dev sockets.
- [ ] `/debug/sessions` or its successor exposes enough daemon metadata to
  prove live session id, incarnation id, process pid, lease holder, attached
  client count, and transport mode.

Review status: NOT REVIEWED after this research update.

Review update on 2026-05-25: first M3 review pass was BLOCKED because
`scripts/run-debug`, `scripts/run-headless`, `scripts/smoke-runtime`, and the
benchmark laband journal fallback still used fixed reusable dev/test paths.
Those defaults were removed and a fresh re-review was requested.

Review update on 2026-05-25: fresh M3 re-review passed with no findings. The
reviewer confirmed ADR 0005 indexing, benchmark transport/echo verification,
real headless `laband` process use, run-id-scoped dev/test paths, and daemon
metadata exposure through `/debug/sessions`.

## Surprises & Discoveries

- Observation: The first review found the original M3 acceptance could not
  prove daemon overhead because the benchmark only had an in-process mode.
  Implication: M3 must extend the benchmark to drive a real `laband` process
  before latency claims are allowed.

- Observation: The current benchmark printed echo verification but exited 0
  even if some samples failed verification.
  Implication: `Tools/KeystrokeLatencyBench/main.swift` now treats any failed
  measured echo as a benchmark failure.

- Observation: AF_UNIX socket path length is evaluated against the literal
  path passed to `bind(2)` and `connect(2)`. In this deep worktree, an absolute
  `.tmp/<run-id>/laband.sock` path exceeded the Darwin limit.
  Implication: Dev/test `laband` commands should keep using run-id-scoped
  relative paths such as `.tmp/<run-id>/laband.sock` from the repository root,
  matching the worktree isolation contract while avoiding path-length failure.

- Observation: A test cannot safely run `swift build --product laband` from
  inside `swift test`; SwiftPM waits on the same build directory lock while the
  parent test invocation waits for the test process.
  Implication: The `LabanDebugTests` target depends on the `Laband` executable
  target so the daemon binary is built before `LabandHeadlessBackendTests`
  starts.

- Observation: The first M3 benchmark attempt read the mmap ring by expanding
  it into the JSON-shaped `LabandSnapshotResponse` on every poll, which spent
  roughly 2 ms allocating cell arrays and visible text for an 80x24 grid.
  Implication: The hot benchmark path now uses a direct coherent cell sampler
  from the ring for echo verification, matching the intended shared-memory
  rendering model where clients sample structured memory instead of rebuilding
  debug JSON.

- Observation: The first M3 review pass found old manual helper scripts still
  used fixed reusable artifact/temp directories even though the new daemon and
  benchmark paths were run-id scoped.
  Implication: Manual and smoke helpers now derive `.artifacts/runs/<run-id>/`
  and `.tmp/<run-id>/` from `LABAN_RUN_ID` or a generated per-run id, and the
  benchmark refuses laband socket paths that do not include a run-id directory.

## Context and Orientation

Current session ownership is in-process. `AppModel` creates `Session` objects
from `Sources/LabanCore/Session.swift`; `Session` wraps the C `LabanSession`.
`SessionRegistry` starts one `SessionRunner` per session; the runner owns a
background thread that calls `laban_session_poll_blocking`. `TerminalBitmapView`
renders AppKit windows through `TerminalSurfaceController` and either
`MetalRenderer` or `SoftwareBackend`.

Current persistence is semantic resume, not live PTY survival. The active plan
`execplans/active/workspace-restore-and-claude-resume.md` persists workspace
shape and Claude/Codex resume metadata. That workflow must remain: if `laband`
or the OS loses the live PTY, Laban asks the user which resumable agent sessions
to restore using the low-friction picker already designed in the grilling
session.

The debug/headless harness is product infrastructure. `HeadlessDebugRuntime`
currently owns in-process sessions. Under this plan, headless mode must start
or connect to a real `laband` process and then drive it through the same client
transport as the app.

## Plan of Work

### M1: Daemon Skeleton

Add a new executable target named `laband`. Do not start this milestone until
ADR 0005 exists and is indexed in `AGENTS.md`.

Edit `Package.swift` to add product `.executable(name: "laband", targets:
["Laband"])` and target `.executableTarget(name: "Laband", dependencies:
["LabanCore", "LabanRenderer", "LabanDebug", "LabanTerminalCore"])`. Create
`Sources/Laband/main.swift` for argument parsing and process startup. Put
shared, AppKit-free protocol types in `Sources/LabanCore/LabandProtocol.swift`
so both `LabanApp` and `LabanDebug` can import them.

In dev/test mode `laband` accepts:

```sh
laband --socket .tmp/<run-id>/laband.sock --journal .artifacts/runs/<run-id>/laband
```

The M1 control transport is deliberately simple and not the final hot path:
a Unix domain socket with one request per frame. Each frame is a 4-byte
little-endian payload length followed by UTF-8 JSON. All request and response
objects include `protocolVersion`, `requestId`, and `type`. Every error
response includes `code`, `message`, and `retryable`.

It should expose a minimal local control API with these request types:

- `hello`: returns protocol version, build version, capabilities;
- `createSession`: starts one PTY-backed terminal session from an executable,
  argv, cwd, environment patch, terminal rows/cols, and optional logical
  session id;
- `listSessions`: returns live catalog entries with logical session id,
  incarnation id, pid, cwd, command display name, title, rows, cols, lifecycle
  state, attached client count, and lease holder;
- `writeInput`: writes bytes or encoded key events to the input lease holder's
  session;
- `snapshot`: returns a copy-based semantic snapshot for the first milestone;
- `resizeSession`: applies the lease holder's PTY size;
- `terminateSession`: kills the PTY process group and marks the session dead;
- `shutdownWhenIdle`: exits only if no live sessions exist.

The first milestone may use a copy-based snapshot over the control transport.
It exists to prove ownership and lifecycle, not final performance.

Acceptance for M1:

```sh
rtk swift build --product laband
rtk .build/debug/laband --socket .tmp/laband-m1/laband.sock --journal .artifacts/runs/laband-m1
rtk swift test --filter LabandControlProtocolTests
```

Validation recorded on 2026-05-25:

```sh
rtk swift build --product laband
# Build of product 'laband' complete.

rtk swift test --filter LabandControlProtocolTests
# Executed 1 test, with 0 failures.
```

Create `Tests/LabandTests/LabandControlProtocolTests.swift`. The test launches
`.build/debug/laband` with a run-id-scoped socket and journal directory,
connects with the length-prefixed JSON client, sends `hello`, creates
`/bin/cat`, writes `x`, asks for `snapshot`, observes `x` at row 0 column 0,
terminates the session, and observes `listSessions` marking the session dead.
It also asserts the app test process has no `LabanTerminalCore` session for
this tab; the `laband` process owns the PTY master fd and child process group.

### M2: App/Headless Client Boundary

Introduce a client abstraction in `LabanCore` that can be backed by either the
current in-process `Session` or a `laband` connection during migration.

Create or update these AppKit-free types:

- `Sources/LabanCore/TerminalSessionClient.swift`: protocol for
  `createSession`, `writeInput`, `resize`, `snapshot`, `markRendered`,
  `terminate`, and `listSessions`.
- `Sources/LabanCore/InProcessTerminalSessionClient.swift`: adapter around the
  current `Session` and `SessionRunner` behavior.
- `Sources/LabanCore/LabandTerminalSessionClient.swift`: adapter that speaks
  the M1 length-prefixed JSON protocol.

Use the abstraction from both `MainWindowController.makeAndShow` and
`HeadlessDebugRuntime`. The feature flag is `LABAN_TERMINAL_BACKEND`, accepted
values `in-process` and `laband`. When `laband` is selected in headless mode,
the runtime must either start a run-id-scoped daemon or connect to
`LABAN_LABAND_SOCKET`.

Create `Tests/LabanDebugTests/LabandHeadlessBackendTests.swift` and
`fixtures/debug-script-laband-basic.scenario.json`. The scenario sends one key
to `/bin/cat`, waits for the echoed text, captures `/debug/sessions`, and
writes the final snapshot.

Acceptance for M2:

```sh
rtk swift test --filter LabandHeadlessBackendTests
LABAN_TERMINAL_BACKEND=in-process rtk ./scripts/run-debug-script fixtures/debug-script-laband-basic.scenario.json --artifacts .artifacts/runs/laband-m2-in-process --temp-dir .tmp/laband-m2-in-process
LABAN_TERMINAL_BACKEND=laband LABAN_LABAND_SOCKET=.tmp/laband-m2/laband.sock rtk ./scripts/run-debug-script fixtures/debug-script-laband-basic.scenario.json --artifacts .artifacts/runs/laband-m2-laband --temp-dir .tmp/laband-m2-laband
```

The test and script must assert `/debug/sessions.sessions[0].transportMode` is
the selected backend. In `laband` mode they must also assert
`daemonProcessPid > 0`, `logicalSessionId` is non-empty, and `incarnationId` is
non-empty.

Validation recorded on 2026-05-25:

```sh
rtk swift build --product laband
# Build of product 'laband' complete.

rtk swift build --product laban-agent
# Build of product 'laban-agent' complete.

rtk swift build --product LabanApp
# Build of product 'LabanApp' complete.

rtk swift test --filter LabandControlProtocolTests
# Executed 1 test, with 0 failures.

rtk swift test --filter LabandHeadlessBackendTests
# Executed 1 test, with 0 failures.

LABAN_TERMINAL_BACKEND=in-process rtk ./scripts/run-debug-script fixtures/debug-script-laband-basic.scenario.json --artifacts .artifacts/runs/laband-m2-in-process --temp-dir .tmp/laband-m2-in-process
# debug script passed

LABAN_TERMINAL_BACKEND=laband LABAN_LABAND_SOCKET=.tmp/laband-m2/laband.sock rtk ./scripts/run-debug-script fixtures/debug-script-laband-basic.scenario.json --artifacts .artifacts/runs/laband-m2-laband --temp-dir .tmp/laband-m2-laband
# debug script passed
```

The AppKit path parses the same backend flag and holds the selected
`TerminalSessionClient`. Full AppKit rendering from daemon-owned snapshots
remains intentionally deferred to M3, where the shared-memory snapshot ring
replaces the copy-based debug/control transport.

### M3: Low-Latency Snapshot Ring

Replace copy-based snapshots on the hot path with a shared-memory ring. The
control socket still creates sessions, grants leases, and returns metadata, but
render cadence reads from shared memory.

- three or more slots;
- one writer in `laband`;
- immutable completed snapshots;
- sequence numbers and dimensions per slot;
- client samples newest complete slot at render cadence;
- damage information included with each snapshot.

The ring is a memory-mapped file or shared-memory object whose descriptor/path
is negotiated through `attachSnapshotRing`. The initial v1 layout is:

- file header: magic `LBNDSS01`, ABI version, byte order marker, session id,
  incarnation id, slot count, slot stride, cell stride, max rows, max columns,
  and current writer generation;
- slot header: seqlock integer, generation, rows, columns, cursor row/column,
  alternate-screen flag, title generation, scrollback anchor, dirty row range
  count, `inputSeqApplied`, `echoAckSeq`, and monotonic timestamps for PTY
  drain and snapshot publish;
- dirty ranges: row start/end pairs for rows changed since the previous
  completed generation;
- cells: fixed-size records containing codepoint or grapheme-table index,
  width, style flags, foreground color, background color, underline style, and
  hyperlink/semantic token indexes where present;
- optional string table: UTF-8 grapheme clusters and other variable-length
  metadata referenced by cells.

The writer marks a slot seqlock odd while writing and even when complete. The
client only renders a slot if it observes the same even seqlock before and
after copying or reading the slot header. If multiple complete generations are
available, the client chooses the newest one and skips older generations.

Create the normative ABI in `Sources/LabanCore/LabandSnapshotRingLayout.swift`
and mirror it for C tests in
`Sources/LabanTerminalCore/include/laband_snapshot_ring.h`. All integer fields
are little-endian fixed-width unsigned integers. Headers and slot starts are
8-byte aligned. Readers reject files whose `headerBytes`, `slotHeaderBytes`, or
`cellBytes` are smaller than the v1 constants.

File header v1:

| Field | Type | Notes |
| --- | --- | --- |
| `magic` | 8 bytes | ASCII `LBNDSS01` |
| `abiVersion` | `UInt16` | `1` for this layout |
| `headerBytes` | `UInt16` | byte size of file header |
| `slotHeaderBytes` | `UInt16` | byte size of each slot header |
| `cellBytes` | `UInt16` | byte size of each cell record |
| `slotCount` | `UInt16` | at least 3 |
| `maxRows` | `UInt16` | maximum rows in every slot |
| `maxCols` | `UInt16` | maximum columns in every slot |
| `slotStride` | `UInt32` | bytes from one slot start to the next |
| `sessionIdHash` | `UInt64` | stable hash for diagnostics only |
| `incarnationIdHash` | `UInt64` | stable hash for diagnostics only |
| `writerGeneration` | `UInt64` | latest completed generation |
| `flags` | `UInt64` | bitset, zero for v1 |

Slot header v1:

| Field | Type | Notes |
| --- | --- | --- |
| `seqlock` | `UInt64` | odd while writing, even when complete |
| `generation` | `UInt64` | wraps by unsigned overflow; equality is authoritative |
| `rows` / `cols` | `UInt16` | active grid dimensions |
| `cursorRow` / `cursorCol` | `UInt16` | zero-based cursor cell |
| `flags` | `UInt32` | alternate screen, cursor visible, cursor blink, synchronized output |
| `dirtyRangeCount` | `UInt16` | number of row ranges following the header |
| `stringTableBytes` | `UInt32` | bytes of per-slot UTF-8 table |
| `scrollbackAnchor` | `UInt64` | daemon-owned scrollback generation or row id |
| `inputSeqApplied` | `UInt64` | latest input sequence consumed by parser |
| `echoAckSeq` | `UInt64` | latest input sequence safe to treat as reflected |
| `ptyDrainMonoNs` | `UInt64` | monotonic timestamp for PTY drain |
| `snapshotPublishMonoNs` | `UInt64` | monotonic timestamp for completed slot |

Each dirty row range is two `UInt16` values: inclusive start row and exclusive
end row. Each cell record is fixed-size and contains a Unicode scalar when the
cell fits in one scalar, otherwise a byte offset and byte length into the
per-slot string table. String-table offsets are valid only within the same slot
and generation. A client must copy or render all referenced string bytes before
sampling a newer slot. Future-compatible readers may skip unknown trailing bytes
using the header byte-size fields; incompatible `abiVersion` values are rejected
and force the client back to copy-based snapshots.

Control messages remain separate from the hot path. JSON remains debug-only.
The local v1 ring is not compressed. Compression belongs in future network
casting or artifact export, not in the same-machine render loop.

Extend `bench-keystroke-latency` before claiming M3 complete:

```sh
rtk .build/release/bench-keystroke-latency --transport in-process --samples 500 --warmup 50 --cols 160 --rows 48 --json .artifacts/runs/keystroke-latency-after/in-process-160x48.json
rtk .build/release/bench-keystroke-latency --transport laband --socket .tmp/keystroke-latency-after/laband.sock --samples 500 --warmup 50 --cols 160 --rows 48 --json .artifacts/runs/keystroke-latency-after/laband-160x48.json
```

Acceptance: the daemon-mode command starts or connects to a real `laband`
process, drives the same `/bin/cat` workload through the real client protocol,
and reports `verifiedEcho=500/500`. Local `laband` overhead over the
in-process raw total is less than 0.5 ms p50 and less than 2 ms p95 at 160x48.

Validation recorded on 2026-05-25:

```sh
rtk swift build -c release --product laband
# Build of product 'laband' complete.

rtk swift build -c release --product bench-keystroke-latency
# Build of product 'bench-keystroke-latency' complete.

rtk .build/release/bench-keystroke-latency --transport in-process --samples 500 --warmup 50 --cols 160 --rows 48 --json .artifacts/runs/keystroke-latency-after/in-process-160x48.json
# verifiedEcho=500/500
# rawTotalMs p50=0.870 ms p95=0.983 ms p99=1.048 ms

rtk .build/release/bench-keystroke-latency --transport laband --socket .tmp/keystroke-latency-after/laband.sock --samples 500 --warmup 50 --cols 160 --rows 48 --json .artifacts/runs/keystroke-latency-after/laband-160x48.json
# verifiedEcho=500/500
# rawTotalMs p50=0.499 ms p95=0.638 ms p99=0.656 ms
```

Focused regression checks:

```sh
rtk swift test --filter LabandControlProtocolTests
# Executed 2 tests, with 0 failures.

rtk swift test --filter LabandHeadlessBackendTests
# Executed 1 test, with 0 failures.

LABAN_TERMINAL_BACKEND=laband LABAN_LABAND_SOCKET=.tmp/laband-m3-debug/laband.sock rtk ./scripts/run-debug-script fixtures/debug-script-laband-basic.scenario.json --artifacts .artifacts/runs/laband-m3-debug --temp-dir .tmp/laband-m3-debug
# debug script passed
```

### M4: Durable Catalog And Journal

Add `laband` storage under the per-user Application Support directory for
product runs and under explicit artifacts/temp dirs for tests. Use an
append-first lifecycle journal. Sync before acknowledging lifecycle-critical
records:

- session created;
- terminate requested;
- agent identity discovered or changed;
- process exit;
- lease grant/revoke/transfer;
- catalog checkpoint/rotation.

Buffer PTY output, routine metadata, render snapshots, and diagnostics without
blocking input or the PTY drain loop.

Create `Tests/LabandTests/LabandJournalTests.swift`. Acceptance for M4:

```sh
rtk swift test --filter LabandJournalTests
rtk .build/debug/laband --socket .tmp/laband-m4/laband.sock --journal .artifacts/runs/laband-m4/laband
```

The test creates a session, writes input, transfers a lease once, terminates the
session, stops `laband`, restarts it with the same journal directory, and
asserts `listSessions` reconstructs the same logical session id, incarnation
id, exit state, agent metadata when present, and lease history. The journal file
must be append-only during the test: record offsets only increase, and
checkpoint or rotation records never rewrite earlier lifecycle records.

Validation recorded on 2026-05-25:

```sh
rtk swift test --filter LabandJournalTests
# Executed 1 test, with 0 failures.

rtk swift test --filter LabandControlProtocolTests
# Executed 2 tests, with 0 failures.

rtk swift test --filter LabandHeadlessBackendTests
# Executed 1 test, with 0 failures.

rtk swift build --product LabanApp
# Build of product 'LabanApp' complete.

LABAN_TERMINAL_BACKEND=laband LABAN_LABAND_SOCKET=.tmp/laband-m4-debug/laband.sock rtk ./scripts/run-debug-script fixtures/debug-script-laband-basic.scenario.json --artifacts .artifacts/runs/laband-m4-debug --temp-dir .tmp/laband-m4-debug
# debug script passed
```

### M5: Detach/Reattach

Change app quit/window close to detach from sessions while `laband` keeps them
running. On relaunch, the app reads saved workspace references, asks `laband`
for matching live sessions, and reattaches. Extra orphaned live sessions show a
small recovery picker with cwd, title, process, agent, and age.

Close Tab remains destructive and calls `terminateSession`.

### M6: Agent Restore Fallback

Preserve the existing Claude/Codex semantic restore workflow:

- live `laband` session: reattach directly;
- daemon lost but agent metadata exists: show a low-friction restore picker;
- selected restore: run the existing login-shell trampoline
  `$SHELL -l -i -c '<resume>; exec $SHELL -l -i'`;
- missing cwd or repo fingerprint mismatch: warn and default unchecked.

Do not install or modify Claude/Codex config in this milestone.

### M7: Multi-Attach And Lease

Allow many clients to observe one session. Exactly one client holds the
input/control lease for a session. The lease holder owns PTY resize. Observers
render the current grid without resizing it. Selection, local scroll/find,
hover, zoom, and sidebar layout remain per-client.

Lease state is stored in daemon memory and journaled on grant/revoke/transfer.
Each lease has `leaseId`, `sessionId`, `holderClientId`, `epoch`,
`grantedAtMonoNs`, and `expiresAtMonoNs`. The holder renews periodically; if it
misses the timeout, `laband` revokes the lease and the next focused client may
request it. A client cannot write input or resize unless its request includes
the current lease id and epoch. A read-only observer can request control, but
the app must present this as a low-friction takeover rather than silently
stealing input from another visible client.

Create `Tests/LabandTests/LabandLeaseTests.swift`. Acceptance for M7:

```sh
rtk swift test --filter LabandLeaseTests
```

The test launches one `laband` process, attaches two clients to the same
session, grants the lease to client A, verifies client B can read snapshots but
cannot write input or resize, transfers the lease to client B, verifies client A
is denied writes with a stale `leaseId`/`epoch`, then lets client B's lease
expire and verifies client A can acquire a new lease. `/debug/sessions` must
report `attachedClientCount == 2` during the dual-attach phase and the current
lease holder client id after each transfer.

### M8: Product Lifecycle And Upgrade

Install product `laband` as a per-user LaunchAgent via ServiceManagement and
expose an XPC listener. A new app must connect to an old daemon through a
versioned compatibility protocol. App upgrades must not kill live sessions.
Daemon restart happens only when no live sessions exist or when the user
explicitly approves terminating live work.

Product `laband` stores its catalog and journal under the user's Application
Support directory. Dev/test never uses that location unless explicitly running
product-mode tests. On app launch, the app first attempts XPC `hello`. If the
daemon is older but compatible, the app continues with the older capability set.
If incompatible and live sessions exist, the app shows a non-scary choice:
"Live terminal sessions are still running. Continue with the current helper or
close selected sessions to upgrade it." The default is to continue with the
current helper.

Create `Tests/LabandTests/LabandLifecycleTests.swift` for non-privileged
LaunchAgent/XPC compatibility logic and
`Tests/LabanAppTests/LabandUpgradePromptTests.swift` for the app prompt policy.
Acceptance for M8:

```sh
rtk swift test --filter LabandLifecycleTests
rtk swift test --filter LabandUpgradePromptTests
LABAN_PRODUCT_LABAND_TESTS=1 rtk swift test --filter LabandProductLaunchAgentTests
```

The first two commands must run in normal CI without installing a LaunchAgent.
They assert version negotiation, incompatible-daemon handling, idle-only daemon
restart policy, and the default "continue with current helper" choice when live
sessions exist. The third command is opt-in and may install/remove the per-user
LaunchAgent in a disposable test label; it must be skipped unless
`LABAN_PRODUCT_LABAND_TESTS=1` is set.

## Validation and Acceptance

Every milestone must rerun the relevant part of M0 and record before/after
numbers in this plan.

Required commands after M3 and later:

```sh
rtk swift build -c release --product bench-keystroke-latency
rtk .build/release/bench-keystroke-latency --transport in-process --samples 500 --warmup 50 --cols 160 --rows 48 --json .artifacts/runs/keystroke-latency-after/in-process-160x48.json
rtk .build/release/bench-keystroke-latency --transport laband --socket .tmp/keystroke-latency-after/laband.sock --samples 500 --warmup 50 --cols 160 --rows 48 --json .artifacts/runs/keystroke-latency-after/laband-160x48.json
```

Required user-visible acceptance after M5:

1. Start Laban through the debug harness with a real `laband` process.
2. Start a long-running shell command in a tab, such as `while true; do date; sleep 1; done`.
3. Quit the app client without terminating `laband`.
4. Relaunch the app client.
5. The tab reattaches to the still-running process; output continues from the
   same live PTY; no duplicate process is created.
6. `/debug/sessions` reports the same logical session id and incarnation id
   before and after app restart, with `attachedClientCount` changing from 1 to
   0 to 1 and the same child process pid throughout.

Create `scripts/test-laband-reattach` and
`fixtures/debug-script-laband-reattach.scenario.json`. The script starts a
run-id-scoped `laband`, starts a first headless client with
`LABAN_TERMINAL_BACKEND=laband`, captures `/debug/sessions` as
`.artifacts/runs/laband-m5/before-sessions.json`, terminates only the client,
starts a second headless client against the same daemon socket, captures
`.artifacts/runs/laband-m5/after-sessions.json`, and exits nonzero unless
logical session id, incarnation id, child pid, and visible continuing output
all match the expected reattach behavior.

Required command after M5:

```sh
rtk ./scripts/test-laband-reattach --socket .tmp/laband-m5/laband.sock --artifacts .artifacts/runs/laband-m5 --temp-dir .tmp/laband-m5
```

Required user-visible acceptance after M6:

1. Start Claude Code or Codex in a tab and let detection capture the session id.
2. Simulate daemon loss so the live PTY is gone.
3. Relaunch the app.
4. Laban shows a low-friction restore picker with session age and cwd/repo
   warnings.
5. Selecting the session resumes through the agent's native resume command.

## Idempotence and Recovery

Development runs must use explicit `--socket`, `--journal`, `--artifacts`, or
`--temp-dir` paths with run IDs. Do not use global fixed sockets, ports, pid
files, or temp paths in tests. If a milestone leaves a stray dev `laband`,
terminate only that process by its run-specific socket/pid metadata; never kill
unrelated user sessions.

## Open Questions

- Whether the 12 ms output-settle gate should stay for all PTY output or be
  bypassed for simple local echo after `laband` introduces immutable snapshots.
- Exact XPC message schema and capability negotiation names.
- Exact product retention limit for closed-session transcripts.
