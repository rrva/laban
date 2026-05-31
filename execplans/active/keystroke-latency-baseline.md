# Measure Keystroke-To-Rendered-Frame Latency

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

Laban is moving toward a `laband` process that owns live PTYs while the app
renders them. Before changing that boundary, we need a repeatable "before"
measurement for interactive latency. In this document, "keystroke-to-rendered
frame" means the time from a terminal key event being accepted by Laban to the
first completed frame containing the PTY echo. It is not a literal photon
measurement: the current headless path cannot observe the display panel or
WindowServer. It is still the right baseline for the daemon split because it
measures the code path that will move: key encoding, PTY write, PTY drain,
terminal parsing, snapshot production, frame-command production, and rendering.

## Progress

- [x] (2026-05-24) Read current debug/headless, render, PTY, and AppKit frame-loop code.
- [x] (2026-05-24) Add `bench-keystroke-latency`, a repeatable benchmark target that measures current pre-daemon latency stages.
- [x] (2026-05-24) Run debug and release baselines on the current codebase and record the before numbers here.
- [x] (2026-05-24) Validate the target builds and write JSON artifacts under `.artifacts/runs/keystroke-latency-before/`.
- [x] (2026-05-24) Make echo verification a hard benchmark requirement:
  `bench-keystroke-latency` exits nonzero if any measured sample does not show
  the expected echoed glyph in the terminal snapshot.

## M0 Baseline Result

These are the current pre-`laband` numbers on 2026-05-24. The primary results
come from release builds. The benchmark drives a real PTY child running
`/bin/cat`, sends real Laban key events, waits for the reader thread to drain
the echoed byte, builds a terminal frame, renders into the existing headless
software surface, and verifies every sample's echoed glyph.

| Grid | Raw rendered frame p50 / p95 / p99 | Estimated current AppKit commit p50 / p95 / p99 | Estimated photon mean p50 / p95 / p99 |
| --- | ---: | ---: | ---: |
| 80x24 | 0.272 / 0.344 / 0.367 ms | 12.272 / 12.344 / 12.367 ms | 16.439 / 16.511 / 16.534 ms |
| 120x36 | 0.512 / 0.682 / 1.171 ms | 12.512 / 12.682 / 13.171 ms | 16.679 / 16.849 / 17.338 ms |
| 160x48 | 0.706 / 0.838 / 0.885 ms | 12.706 / 12.838 / 12.885 ms | 16.872 / 17.005 / 17.052 ms |

The "estimated current AppKit commit" column adds the current 12 ms output
settle quiet window from `Sources/LabanApp/TerminalRenderGate.swift`. The
"estimated photon mean" column adds half a 120 Hz refresh interval (4.167 ms).
It is still an estimate, not a physical photon measurement.

Detailed 160x48 release stage timings:

| Stage | Mean | p50 | p95 | p99 |
| --- | ---: | ---: | ---: | ---: |
| Key encode/write | 0.004 ms | 0.004 ms | 0.008 ms | 0.010 ms |
| PTY echo/drain | 0.004 ms | 0.004 ms | 0.007 ms | 0.011 ms |
| Session sync | 0.024 ms | 0.023 ms | 0.029 ms | 0.039 ms |
| Snapshot | 0.180 ms | 0.178 ms | 0.196 ms | 0.207 ms |
| Command extraction | 0.118 ms | 0.118 ms | 0.143 ms | 0.159 ms |
| Software render | 0.379 ms | 0.369 ms | 0.473 ms | 0.526 ms |
| Raw total | 0.713 ms | 0.706 ms | 0.838 ms | 0.885 ms |

Related existing benches:

- `TerminalDisplayKickCoalescerBench` in release mode reported one
  background-to-main wake at mean 12.82 us, p50 12.25 us, p95 21.00 us,
  p99 29.96 us. That wake is not a latency driver compared with the 12 ms
  output-settle policy.
- `MetalFrameTimingBench` in release mode reported synthetic full-redraw GPU
  p50 values of 0.132 ms at 80x24 and 0.445 ms at 160x48. Its CPU p50 was
  about 9 ms because that bench stress-drives full frames through the Metal
  renderer and is not the keystroke echo path.

## Decision Log

- Decision: The baseline will measure keystroke-to-rendered-frame in a real PTY
  session using the existing in-process architecture, and will separately report
  current AppKit policy costs such as output-settle delay and display cadence.
  Rationale: Literal photon timing requires either onscreen presentation timing
  or external hardware. The current repo already has headless render and Metal
  frame timing, but no photodiode or compositor timestamp contract. Separating
  measured compute time from deterministic policy delay keeps the numbers honest
  and makes them comparable after `laband` exists.
  Date/Author: 2026-05-24 / Codex.

## Context and Orientation

Current interactive Laban keeps PTY ownership inside the app process. The C
terminal layer in `Sources/LabanTerminalCore/` opens the PTY, writes encoded key
bytes, drains PTY output, feeds libghostty-vt, and produces snapshots. Swift
`Session` in `Sources/LabanCore/Session.swift` wraps that C object.

`AppModel` stores tabs and starts a `SessionRunner` for every live session.
`SessionRunner` owns a background thread that calls `laban_session_poll_blocking`
and invokes `AppModel.onSessionDirty` when PTY output arrives. In the AppKit app,
`TerminalBitmapView` coalesces that dirty callback into `advanceFrame()`, then
`TerminalSurfaceController` builds frame commands and the renderer draws them.

The AppKit path currently includes an output-settle gate in
`Sources/LabanApp/TerminalRenderGate.swift`: after PTY output arrives, normal
terminal output waits for a 12 ms quiet window before rendering, with a 25 ms
maximum hold. That gate reduces transient flicker but is part of perceived
latency and must be included in the baseline report.

## Plan of Work

Add a new Swift executable target named `bench-keystroke-latency` under
`Tools/KeystrokeLatencyBench`. It should create a real PTY session running
`/bin/cat`, route printable key events through Laban's existing key encoder,
let the existing `SessionRunner` drain PTY output on a background thread, and
render the frame through `TerminalSurfaceController` plus `SoftwareRenderer`.

For each sample, record stage durations:

- key encode/write: key event accepted through PTY write return;
- PTY echo/drain: waiting for `SessionRunner` to report drained output;
- frame build: `TerminalSurfaceController.syncSessions` plus `makeFrame`;
- render: `SoftwareRenderer.render`;
- raw total: key event to rendered offscreen frame;
- estimated current AppKit total: raw total plus the 12 ms output-settle quiet
  window and optional display-cadence wait.

The target should print human-readable p50/p95/p99/mean numbers and optionally
write JSON under a caller-provided artifact path. Generated artifacts belong
under `.artifacts/` and are not committed; the concise before summary belongs
in this ExecPlan.

## Validation and Acceptance

From `/Users/dev/wrk/laban`, run:

```sh
rtk swift build --product bench-keystroke-latency
rtk .build/debug/bench-keystroke-latency --samples 200 --warmup 30 --json .artifacts/runs/keystroke-latency-before/result.json
rtk swift build -c release --product bench-keystroke-latency
rtk .build/release/bench-keystroke-latency --samples 500 --warmup 50 --cols 160 --rows 48 --json .artifacts/runs/keystroke-latency-before/result-release-160x48.json
```

Acceptance:

- the benchmark exits 0;
- stdout includes p50/p95/p99 for each measured stage;
- stdout includes `verifiedEcho=<samples>/<samples>`; any smaller value exits
  nonzero and does not write a successful result;
- the JSON artifact exists and includes top-level `samples`, top-level
  `stages.rawTotalMs`, top-level `stages.estimatedCurrentAppCommitMs`, and
  `rawSamples[]` entries containing per-sample `rawTotalMs` and
  `estimatedCurrentAppCommitMs`;
- this plan records the observed before numbers.

## Idempotence and Recovery

The benchmark starts one temporary PTY session and destroys it before exit. It
writes only to an explicit artifact path when `--json` is passed. Re-running the
command replaces the JSON file and does not change product state.
