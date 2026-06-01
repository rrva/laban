# 16. GPU-Driven Cell Renderer Remains Opt-In Beside Classic

Date: 2026-06-02

## Status

Accepted.

## Context

Laban is CPU-render-bound, not GPU-bound. The renderer profile that started
`execplans/active/gpu-driven-cell-renderer.md` showed low GPU utilization and a
large CPU cost in frame-command production, instance-list construction, and
Metal command encoding. The plan therefore split the work into two permanent
paths:

- the existing Metal renderer, improved with damage-scoped classic rebuilds;
- a macOS-26-gated GPU-driven cell renderer that consumes a neutral
  `TerminalCellPayload`, stores one GPU record per terminal cell, and patches
  only dirty rows in local interactive sessions.

The GPU-driven path is an acceleration for the interactive Metal surface only.
It does not replace the shared `[FrameCommand]` language. The software/offscreen
backend, `/debug/frame-commands`, capture replay, frame probes, and render traces
continue to consume frame commands.

M5 evaluated the Metal 4 command model as a possible encode-overhead win. The
standalone proof spike was promising, but the production GPU-cell branch failed
the release frame-level p50 gate against the M3 plain-Metal GPU-cell path, so the
production Metal 4 command-model path was retired. The spike remains as evidence;
Metal 4 is not part of the shipping renderer path today.

## Decision

Keep two user-selectable renderers:

- `classic` is the default renderer on every supported OS.
- `gpuDriven` remains persisted under `LabanRendererMode`, is offered only when
  `RendererMode.gpuDriven.isAvailableOnCurrentOS` is true, and is hidden behind
  `#available(macOS 26, *)` behavior. On older macOS versions the UI leaves the
  GPU-driven item disabled and the renderer resolves to classic.

The renderer switch is a surface-level setting, not a session-backend setting.
Switching it updates the existing `MetalRenderer.configuredRendererMode`, forces
a full redraw, and preserves the `AppModel`, active tab id, and `Session` object.
It does not restart Laban or recreate terminal sessions.

The classic renderer remains the default because the predeclared M6 threshold
for default enablement is not met. The threshold required at least 25% lower
render CPU at both p50 and p99 on streaming/TUI workloads, no >10% full-redraw
regression, no energy regression, and zero parity failures. Current evidence
shows useful dirty-row payload CPU wins for the GPU-driven path, but the
full-frame comparison is within noise or regresses in some runs, energy/wakeups
have not shown a measured win, remote/laband frames fall back to classic, and
the Metal 4 production branch failed its p50 gate.

## Evidence

- Pixel parity: `GPUCellParityTests` compares raw RGBA bytes between classic and
  GPU-driven paths, with zero tolerance and expected/actual/diff PNG artifacts on
  mismatch.
- M1 classic damage scoping: release instance-list rebuild p50 at 160x48 dropped
  from roughly 580-616 us full rebuild to roughly 14 us for one dirty row; sparse
  rows still expose the dirty-union limitation.
- M3 payload routing: release routed dirty-row p50 reported classic commands plus
  M1 scoped rebuild at 113.1 us versus payload fill plus GPU patch at 14.8 us, and
  the warmed payload allocation bench reported `storageGrowthEvents=0`.
- M4 parity: decorations, procedural cells, hyperlink visuals, selection/find/
  cursor overlays, wide/CJK/cluster glyphs, and fractional scroll offsets have
  raw-RGBA parity coverage through command-fed and/or payload-fed GPU-cell paths.
- M5 no-go: the production Metal 4 GPU-cell row measured M3 GPU-cell at
  `6.871/8.205/8.667 ms` p50/p95/p99 and MTL4 GPU-cell at
  `7.071/8.039/8.259 ms`; p50 was 0.200 ms slower, so the production MTL4 branch
  was removed.

## Consequences

- The default path is conservative and available on the full macOS deployment
  range.
- Users on macOS 26 can opt in to the GPU-driven cell renderer from the View menu
  without losing session identity.
- The GPU-driven path remains valuable as a measured local-interactive
  acceleration and as a proving ground for future sparse-damage or multi-scissor
  work, but it must continue to earn any default-enable decision with release
  benchmarks and parity evidence.
- Remote/laband snapshots intentionally use classic effective rendering even when
  GPU-driven is configured, because the remote snapshot payload lacks the full
  local cell data needed for the GPU-cell path.
- Metal 4 may be revisited only behind a new proof gate that includes residency,
  argument-table churn, drawable ordering, parity, and release frame-level timing.

## Applies To New Code

New renderer features must preserve the frame-command contract first. A GPU-only
optimization may add side-channel payloads or buffers, but it cannot make the
software/offscreen/debug/capture paths depend on Metal internals. Any new
renderer mode or default-selection change must ship with raw-RGBA parity tests,
release-mode timing evidence, and a session-identity check for live switching.
