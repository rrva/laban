# Prove GPU Renderer Default Readiness With Release Performance Evidence

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds. A
fresh contributor should be able to read only this file and the current working
tree, then produce the evidence needed to decide whether Laban's GPU-driven
renderer can become the macOS 26 default.

## Purpose / Big Picture

Laban now has two renderers: `classic`, which is the default, and `gpuDriven`,
which is opt-in on macOS 26. The GPU-driven renderer has real dirty-row payload
wins, but the completed M6 comparison did not prove the broad p50, p99, process
CPU, and energy wins required to make it default. This plan turns default
readiness into a measurable performance project instead of a preference.

After this work, a developer can run a release benchmark and live profiling
recipe that says either "make `gpuDriven` the macOS 26 default" or "keep it
opt-in", with enough data to defend the decision.

## Progress

- [x] Created this ExecPlan from ADR 0016 and the completed GPU renderer plan.
- [ ] Establish a reproducible baseline for classic and GPU-driven release
      timings on current `main`.
- [ ] Add artifact output that preserves benchmark rows, process CPU, dropped
      frames, and profiling metadata in a comparable format.
- [ ] Profile live `~/Laban.app` CPU, wakeups, and renderer hot stacks under
      classic and GPU-driven modes.
- [ ] Evaluate optimization candidates one at a time, keeping only changes that
      have attributable release evidence.
- [ ] Make a default/no-default decision and update code/docs only if the
      predeclared gate is met.

## Decision Log

- Decision: The default-readiness gate is the ADR 0016 gate, not a single fast
  microbenchmark.
  Rationale: The user-visible risk is not whether one internal loop is faster;
  it is whether a default renderer improves normal terminal workloads without
  p99, full-redraw, energy, or correctness regressions.
  Date/Author: 2026-06-02 / Codex.

- Decision: Optimization candidates must be measured one at a time.
  Rationale: Prior renderer work found that batched benchmarking hides which
  change helped or hurt. A retained optimization must have attributable release
  evidence.
  Date/Author: 2026-06-02 / Codex.

## Context and Orientation

The current renderer policy is recorded in
`docs/adr/0016-gpu-driven-cell-renderer.md`:

- `classic` is the default renderer on every supported OS.
- `gpuDriven` is persisted under `LabanRendererMode`, offered only when
  `RendererMode.gpuDriven.isAvailableOnCurrentOS` is true, and remains opt-in.
- The default-enable threshold requires at least `25%` lower render CPU at both
  p50 and p99 on streaming/TUI workloads, no more than a `10%` full-redraw
  regression, no energy regression, and zero parity failures.

The completed GPU renderer plan recorded the relevant evidence:

- The M3 payload path can be much cheaper than classic command production for
  dirty-row CPU work. One recorded routed dirty-row p50 was classic commands
  plus M1 scoped rebuild at `113.1 us` versus payload fill plus GPU patch at
  `14.8 us`.
- The broader M6 matrix did not clear the default gate. Example rows included
  one-row append p50 classic `6.651 ms` versus GPU `6.718 ms`, and
  emoji/CJK/ZWJ p99 classic `9.642 ms` versus GPU `11.487 ms`. Process CPU per
  frame was often higher for GPU-driven, and the XCTest harness did not prove an
  energy/wakeup win.
- Remote/laband snapshots currently fall back to classic effective rendering
  because they do not carry the full local `TerminalCellPayload`.

Definitions used in this plan:

- Render CPU is the CPU time spent producing and submitting a frame, measured by
  the renderer timing harness.
- Process CPU is total process CPU per frame, measured from process resource
  usage. It can rise even when render CPU falls if the renderer causes extra
  work elsewhere.
- p50 is the median frame; p99 is the worst 1% tail. Terminals need both because
  occasional long frames are visible as hitching.
- A workload is a repeatable scenario such as cursor blink, one-row append,
  sparse dirty rows, full repaint, fast scroll, dense colors, box drawing,
  emoji/CJK/ZWJ clusters, theme/atlas growth, or remote fallback.
- Energy/wakeup evidence means a live or system-level measurement that shows
  the renderer does not increase idle wakeups or sustained CPU/GPU activity.

The files most likely touched are:

- `Tests/LabanRendererTests/MetalFrameTimingBench.swift`: current release timing
  matrix. Extend this before adding new optimizations.
- `Tests/LabanCoreTests/TerminalCellPayloadAllocationBench.swift`: payload build
  allocation and routed dirty-row CPU evidence.
- `Tests/LabanRendererTests/GPUCellParityTests.swift`: raw-RGBA parity gate.
- `Sources/LabanRenderer/MetalRenderer.swift`: renderer hot path and timing
  samples.
- `Sources/LabanApp/TerminalBitmapView.swift`: frame scheduling, live AppKit
  repaint behavior, and renderer-mode switching.
- `Sources/LabanApp/RenderJournal.swift`: useful for diagnosing blanking or
  fallback events during live soak, but not a substitute for release timings.

## Plan of Work

### M0 - Baseline And Artifact Contract

Run the current release matrix without changing renderer behavior. If the
matrix does not already write machine-readable artifacts, extend
`MetalFrameTimingBench` so each run writes a compact JSON or TSV artifact under
`LABAN_ARTIFACTS` containing:

- git SHA;
- macOS version and SDK availability relevant to `gpuDriven`;
- renderer mode;
- workload name;
- terminal dimensions, font name, font size, backing scale;
- render CPU p50/p95/p99;
- process CPU per frame;
- GPU p50/p99 when available;
- dropped render attempts;
- whether the workload used payload mode or classic fallback;
- artifact path and timestamp.

Acceptance for M0:

```sh
LABAN_RUN_PERF_BENCH=1 rtk swift test -c release --filter MetalFrameTimingBench/testFrameTimingsAcrossWorkloads
LABAN_RUN_PERF_BENCH=1 rtk swift test -c release --filter TerminalCellPayloadAllocationBench
```

The commands pass, print the expected tables, and leave artifact files that can
be compared across commits.

### M1 - Live App CPU, Wakeup, And Energy Baseline

Benchmark tests are necessary but not enough. Add a repeatable local profiling
recipe under `docs/process/` or in this plan's artifact notes that profiles a
real installed `~/Laban.app` in both `classic` and `gpuDriven` modes. The recipe
must not kill user PTY sessions. It should include:

- how to confirm the installed app's git SHA or build age;
- how to switch renderer mode through user defaults or the View menu;
- a quiet shell idle scenario;
- a fast output scenario such as `yes | head -n 5000` or a scripted fixture;
- a fullscreen TUI scenario such as a known alternate-screen program or replay;
- an agent TUI scenario if a safe fixture exists;
- `sample`, `xctrace`, `ps`, or equivalent commands for CPU stacks;
- any available wakeup or energy counters on the target macOS version.

Acceptance for M1:

The plan records classic and GPU-driven live profiles for the same scenarios and
states whether GPU-driven increases idle CPU, wakeups, or sustained CPU/GPU
work. If a system-level energy counter is unavailable, record the exact command
and failure mode rather than treating "not measured" as a pass.

### M2 - One-At-A-Time Optimization Candidates

Investigate candidates one at a time. For each candidate, create a small branch
or commit, run the M0 matrix and any focused tests, then either keep the change
with evidence or revert it before moving to the next candidate.

Candidate list:

- Sparse dirty rows: the classic path uses a dirty-union scissor, while the GPU
  path may still pay full-target costs. Explore row-batched or multi-pass damage
  so sparse rows do not force unnecessary work.
- Full-frame overhead: identify whether GPU-driven's full-frame rows lose to
  classic because of extra pass setup, readback, target reuse, buffer upload, or
  present scheduling.
- Payload construction: keep `TerminalCellPayloadAllocationBench` at zero warmed
  heap growth and look for CPU copies or UTF-8/cluster handling that remain hot.
- Atlas churn: reduce repeated glyph atlas rasterization, cache invalidation, or
  texture upload costs during theme/atlas growth workloads.
- Idle and cursor frames: ensure cursor-only frames preserve the cell cache and
  do not cause avoidable command production or target clears.
- Remote/laband fallback frequency: measure whether common restored or remote
  sessions fall back so often that GPU-driven default would not affect real use.

Acceptance for M2:

Every retained optimization has:

- a focused test or benchmark showing the intended path was exercised;
- a release timing row before and after the change;
- no `GPUCellParityTests` regression;
- no full-redraw regression above the default gate;
- a short entry in this ExecPlan's `Surprises & Discoveries` or
  `Outcomes & Retrospective` explaining why it stayed.

### M3 - Default Decision

After candidates are evaluated, rerun the full current matrix and the live
profiling recipe. Then make exactly one decision:

- If GPU-driven meets the ADR 0016 threshold, change the macOS 26 default in
  the renderer settings, keep the View menu override, update ADR 0016 or write a
  successor ADR, and add tests proving existing sessions survive the default
  transition and mode switching.
- If GPU-driven does not meet the threshold, leave `classic` as default, keep
  `gpuDriven` opt-in, and record the final evidence in this plan. Do not weaken
  the threshold after seeing the data.

Acceptance for M3:

```sh
rtk swift test --filter 'GPUCellParityTests|RendererModeSettingsTests|MetalRendererSmokeTests'
LABAN_RUN_PERF_BENCH=1 rtk swift test -c release --filter MetalFrameTimingBench/testFrameTimingsAcrossWorkloads
LABAN_RUN_PERF_BENCH=1 rtk swift test -c release --filter TerminalCellPayloadAllocationBench
rtk git diff --check
```

The final decision is reflected in code, tests, and docs. If default changes,
`RendererModeSettingsTests` must assert the new default on macOS 26 and the
fallback behavior on older systems. If default does not change, no renderer
default code should be modified.

## Validation and Acceptance

This plan is complete when the repository contains a reproducible release
performance and live-profiling record for the default decision. Correctness is
not negotiable: `GPUCellParityTests` must stay green, and live manual testing
may add confidence but cannot replace the automated gates.

Minimum validation from the repository root:

```sh
rtk swift test --filter 'GPUCellParityTests|RendererModeSettingsTests|MetalRendererSmokeTests'
LABAN_RUN_PERF_BENCH=1 rtk swift test -c release --filter MetalFrameTimingBench/testFrameTimingsAcrossWorkloads
LABAN_RUN_PERF_BENCH=1 rtk swift test -c release --filter TerminalCellPayloadAllocationBench
rtk git diff --check
```

Expected outcome: tests pass; release benchmark artifacts show whether
`gpuDriven` meets or misses the exact default gate; this plan records the
decision and evidence.

## Idempotence and Recovery

Benchmark commands are safe to rerun. Set `LABAN_ARTIFACTS` to a timestamped
directory when comparing runs so artifacts do not overwrite each other. If a
candidate optimization regresses parity, use normal git revert or reset of that
candidate commit only; do not revert unrelated renderer fixes. If a live profile
requires launching `~/Laban.app`, coordinate with the user before opening or
closing the app so existing agent sessions are not disrupted.

Do not refresh or commit `.rpg/graph.json` as part of this plan unless a human
explicitly asks for semantic-graph maintenance.

## Review Gate

A separate fresh-state review agent must verify these checks before this
ExecPlan is considered complete:

- [ ] Run `rtk swift test --filter GPUCellParityTests`; expect exit 0.
- [ ] Run `LABAN_RUN_PERF_BENCH=1 rtk swift test -c release --filter MetalFrameTimingBench/testFrameTimingsAcrossWorkloads`;
      expect exit 0 and a table or artifact containing classic and GPU-driven
      rows for every workload named in this plan.
- [ ] Run `LABAN_RUN_PERF_BENCH=1 rtk swift test -c release --filter TerminalCellPayloadAllocationBench`;
      expect exit 0 and `storageGrowthEvents=0` after warm-up.
- [ ] If code changes make `gpuDriven` the default, grep
      `docs/adr/0016-gpu-driven-cell-renderer.md` or its successor ADR; expect
      the default decision and benchmark evidence to be recorded.
- [ ] If code changes make `gpuDriven` the default, run
      `rtk swift test --filter RendererModeSettingsTests`; expect a test that
      proves renderer switching preserves the active session identity.
- [ ] Inspect this ExecPlan's `Outcomes & Retrospective`; expect it to state
      whether the ADR 0016 default gate passed or failed, with exact p50/p99 and
      energy/wakeup evidence.

Review status: NOT REVIEWED.

