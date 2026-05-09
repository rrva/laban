# Reproduce And Observe Fragmented Spinner Cursor Jumps

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

Laban can show a cursor hop while command-line spinners update with fragmented
terminal writes such as `ESC [ 1 G`, `ESC [ 0 K`, then one spinner glyph. A
manual full capture can hide the problem because Metal readback changes frame
timing. After this change, a developer can run a deterministic spinner program
inside Laban, collect AppKit frame observations without enabling capture
readback, optionally collect a normal full capture, and get a machine-readable
summary of cursor columns and spinner visibility. This makes the bug visible to
agents before any rendering fix is attempted.

## Progress

- [x] Read `docs/product/mvp.md`, `docs/process/dev-process.md`, current AppKit
  capture code, Metal capture-mode code, and shell launch behavior.
- [x] Create this focused ExecPlan.
- [x] Add a standalone fragmented-spinner PTY program.
- [x] Add an AppKit frame probe that records rendered cursor/text state without
  calling `pngData` or enabling Metal capture mode.
- [x] Add a runner and analyzer for probe-only and full-capture repro runs.
- [x] Run the reproducer locally and record artifact paths and analyzer output.

## Decision Log

- Decision: Use the `SHELL` environment variable to launch the reproducer as
  the initial AppKit terminal program.
  Rationale: `Session.realShell` already resolves the child executable from
  `$SHELL` when no explicit configuration is present. This avoids adding a new
  user-facing launch setting just for the repro while still exercising the real
  PTY, reader thread, AppKit frame loop, and Metal renderer.
  Date/Author: 2026-05-09 / Codex.

- Decision: Add a probe sidecar separate from full capture.
  Rationale: Full capture turns on Metal drawable readback so `pngData` has
  bytes to store. The reported bug changes when capture is enabled, so an
  observer that does not call `pngData` is needed to see capture-off behavior.
  The probe records frame commands and snapshot cursor fields only.
  Date/Author: 2026-05-09 / Codex.

## Context and Orientation

`Sources/LabanApp/TerminalBitmapView.swift` owns the visible AppKit frame loop.
It snapshots the active `Session`, turns the snapshot into `FrameCommand`
values, calls the current renderer, and optionally records full-capture
sidecars. Full capture is toggled by `Debug > Toggle PTY Capture` and, for
Metal, sets `MetalRenderer.captureMode = true`, which adds a drawable-to-CPU
readback pass. That readback is useful for screenshots but changes timing.

`Sources/LabanCore/Session.swift` launches a real PTY-backed child through
`Session.realShell`. The C terminal core resolves the child executable from
`LabanLaunchConfig.executable`; if absent, it uses the `SHELL` environment
variable. A script with a shebang can therefore be run as the initial program by
starting Laban with `SHELL=/path/to/script`.

`scripts/replay-capture` validates full-capture artifacts, but replay cannot
show what happened when capture was off because no full capture exists. The new
probe fills that gap by writing local NDJSON under a requested artifact
directory.

## Plan of Work

Add `scripts/cursor-spinner-repro`, an executable Python script that emits a
header line and then repeated fragmented spinner updates. The default update is
three writes: cursor to column 1, erase to end of line, spinner glyph. Small
sleep gaps between writes make it likely that the PTY reader and AppKit wake
path can observe incomplete spinner states.

Add `TerminalBitmapView.FrameProbe` support. When
`LABAN_FRAME_PROBE_DIR=/path/to/dir` is set, the view creates the directory and
writes `frame-probe.ndjson`. Each rendered frame records the frame number,
snapshot cursor row/column/visibility, terminal glyph runs, cursor rectangles,
surface size, and command count. The probe must not call `backend.pngData` and
must not set `MetalRenderer.captureMode`.

Add automation environment flags for reproducibility:

- `LABAN_AUTOSTART_CAPTURE=1` starts the existing full capture after the view
  is constructed.
- `LABAN_AUTO_QUIT_AFTER_SECONDS=<seconds>` stops any active capture and quits
  the app after a short run.

Add `scripts/analyze-spinner-repro`, which accepts either a `frame-probe.ndjson`
file or a full capture directory. It reports how many rendered frames had a
leftmost cursor column and how many had no spinner glyph visible. Add
`scripts/run-spinner-repro` to build the app, run probe-only and/or capture
mode, and invoke the analyzer on produced artifacts.

## Validation and Acceptance

Run from `/Users/rrj/wrk/laban`:

```sh
rtk scripts/cursor-spinner-repro --cycles 3 --frame-gap-ms 1 >/tmp/spinner.bin
rtk scripts/analyze-spinner-repro /Users/rrj/Library/Logs/Laban/captures/appkit-2026-05-09T07-05-06Z
rtk scripts/run-spinner-repro --seconds 3 --mode probe
rtk scripts/run-spinner-repro --seconds 3 --mode capture --no-build
```

Acceptance:

- The standalone spinner script exits 0 and emits `ESC[1G` / `ESC[0K` spinner
  sequences.
- The analyzer reports the latest manual capture has 173 frames and zero
  non-one cursor columns.
- A probe-only run writes `.artifacts/spinner-repro/.../probe/frame-probe.ndjson`
  and prints a JSON summary.
- A capture run writes both probe output and a normal full capture directory
  under `.artifacts/spinner-repro/.../captures/`.

Validation completed on 2026-05-09 from `/Users/rrj/wrk/laban`:

```sh
rtk scripts/cursor-spinner-repro --cycles 3 --frame-gap-ms 1 >/tmp/laban-spinner-repro.bin
rtk scripts/analyze-spinner-repro /Users/rrj/Library/Logs/Laban/captures/appkit-2026-05-09T07-05-06Z --pretty
rtk swift test --filter TerminalBitmapViewSyncOutputTests
rtk scripts/run-spinner-repro --seconds 2 --mode probe
rtk scripts/run-spinner-repro --seconds 2 --mode capture --no-build
rtk env LABAN_SPINNER_STYLE=split-home LABAN_SPINNER_HOME_GAP_MS=4 scripts/run-spinner-repro --seconds 2 --mode both --no-build
rtk ./scripts/lint
rtk python3 -m py_compile scripts/cursor-spinner-repro scripts/analyze-spinner-repro
rtk ./scripts/check-docs
```

Observed outputs:

- Latest manual capture
  `/Users/rrj/Library/Logs/Laban/captures/appkit-2026-05-09T07-05-06Z`:
  `frames=173`, `cursorCols={"1":173}`, `leftCursorFrames=0`.
- Aggressive three-write probe-only run
  `.artifacts/spinner-repro/20260509T072205Z/probe-off/probe/frame-probe.ndjson`:
  `frames=39`, `cursorCols={"0":20,"1":19}`, `leftCursorFrames=20`.
- Closer two-write split-home run
  `.artifacts/spinner-repro/20260509T072224Z/probe-off/probe/frame-probe.ndjson`:
  `frames=22`, `cursorCols={"0":1,"1":21}`, `leftCursorFrames=1`.
- Matching split-home capture run
  `.artifacts/spinner-repro/20260509T072224Z/capture-on/captures/appkit-2026-05-09T07-22-28Z`:
  `frames=22`, `cursorCols={"0":1,"1":21}`, `leftCursorFrames=1`.

## Idempotence and Recovery

All generated artifacts live under `.artifacts/spinner-repro/` unless the user
passes another root. Re-running the scripts creates a new timestamped run
directory. If the app fails to quit automatically, `scripts/run-spinner-repro`
terminates the launched process after a timeout.
