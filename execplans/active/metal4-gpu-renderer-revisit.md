# Revisit Metal 4 For The GPU Cell Renderer

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds. A
fresh contributor should be able to read only this file and the current working
tree, then decide whether Metal 4 should return to Laban's renderer without
repeating the previous false starts.

## Purpose / Big Picture

Laban already has a user-selectable GPU-driven cell renderer on macOS 26, but it
uses the regular Metal command model. A previous Metal 4 production attempt
became pixel-correct after explicit residency and drawable-wait fixes, then lost
the release p50 frame-time comparison and was removed. This plan reopens Metal 4
only as a proof-gated experiment: either it produces a measured, parity-safe win
over the current plain-Metal GPU cell path, or it is discarded again with better
evidence.

After this work, a developer can run an opt-in Metal 4 test and timing matrix
that either demonstrates a production-worthy path or conclusively explains why
Metal 4 should remain out of Laban's renderer.

## Progress

- [x] Created this ExecPlan from the completed GPU renderer plan and ADR 0016.
- [ ] Recreate an isolated Metal 4 correctness harness behind explicit test flags.
- [ ] Prove resource visibility, argument-table binding, feedback reporting, and
      drawable/readback ordering without touching the shipping renderer path.
- [ ] Add an opt-in production candidate only after the isolated harness passes.
- [ ] Run raw-RGBA parity and release timing against the current plain-Metal GPU
      cell path.
- [ ] Retain the Metal 4 path only if it beats the predeclared gate; otherwise
      remove the production candidate and record the no-go evidence.

## Decision Log

- Decision: Metal 4 must start in a separate proof harness, not as an immediate
  rewrite of `MetalRenderer`.
  Rationale: The previous M5 production attempt first failed with invisible
  glyphs because resources bound through `gpuAddress` and `gpuResourceID` were
  not made resident. Correctness work must be isolated and observable before it
  is allowed back into the interactive renderer.
  Date/Author: 2026-06-02 / Codex.

- Decision: The existing plain-Metal GPU cell renderer remains the baseline and
  fallback throughout this plan.
  Rationale: ADR 0016 says `classic` is the default renderer, `gpuDriven`
  remains opt-in on macOS 26, and Metal 4 is not part of the shipping path
  today. This plan may not make Metal 4 default or remove the plain-Metal GPU
  path.
  Date/Author: 2026-06-02 / Codex.

- Decision: Metal 4 texture copy is not a production dependency for this plan.
  Rationale: The previous branch saw `MTL4ComputeCommandEncoder.copy` return
  zeroed data before the residency fix, and the current renderer can present and
  read back by rendering directly. A copy probe is useful evidence, but copy
  success must not block parity work.
  Date/Author: 2026-06-02 / Codex.

## Context and Orientation

The completed plan at `execplans/completed/gpu-driven-cell-renderer.md` created
two permanent renderer choices:

- `classic`: the default renderer on every supported OS. It uses the established
  `[FrameCommand]` drawing path and a damage-scoped Metal instance rebuild.
- `gpuDriven`: an opt-in macOS 26 renderer that consumes a
  `TerminalCellPayload`, stores one record per terminal cell in a persistent GPU
  buffer, and patches only dirty rows for local interactive sessions.

ADR 0016 at `docs/adr/0016-gpu-driven-cell-renderer.md` records the current
policy: Metal 4 is not part of the shipping renderer path. The prior M5 attempt
is still valuable evidence:

- A standalone encode spike used `MTL4CommandBuffer`,
  `MTL4CommandAllocator.reset()`, `beginCommandBuffer(allocator:)`,
  `MTL4RenderCommandEncoder`, and `MTL4ArgumentTable`; it measured about
  `+3.75 us` p50 in favor of Metal 4 for a narrow encode-only case.
- The production branch initially rendered solids but not cell glyphs.
  Residency and drawable-wait wiring fixed the first plain-text parity blocker.
- The final production timing row measured the plain-Metal M3 GPU cell path at
  `6.871/8.205/8.667 ms` p50/p95/p99 and the Metal 4 GPU cell path at
  `7.071/8.039/8.259 ms`; p50 was `0.200 ms` slower, so the branch was removed.

Definitions used in this plan:

- Metal 4 is Apple's newer command model for Metal. It uses `MTL4`-prefixed
  command queues, command buffers, command encoders, command allocators, and
  argument tables. It is not the same thing as the current regular `MTLCommandBuffer`
  and `MTLRenderCommandEncoder` path.
- An argument table is an explicit resource-binding object used by Metal 4
  encoders. Instead of calling many per-stage `setBuffer`/`setTexture` methods,
  the renderer fills a table with buffer addresses, texture IDs, and samplers,
  then binds that table to pipeline stages.
- A residency set tells Metal 4 which buffers, textures, heaps, and drawable
  resources must be GPU-accessible for a submitted command buffer. Residency is
  about resource visibility; it does not make CPU writes safe while the GPU is
  still reading an old buffer slot.
- Raw-RGBA parity means byte-for-byte equality of the rendered pixels. One
  differing pixel fails.

The source files most likely touched by this plan are:

- `Sources/LabanRenderer/MetalRenderer.swift`: owns the interactive Metal
  renderer, renderer-mode branch, GPU cell buffer preparation, content passes,
  readback, and timing samples.
- `Sources/LabanRenderer/MetalGlyphAtlas.swift`: owns the production glyph atlas
  texture that Metal 4 must sample correctly. Do not substitute only a tiny
  1x1 texture and claim production parity.
- `Sources/LabanRenderer/MetalReadback.swift`: owns readback for pixel parity
  and screenshots.
- `Sources/LabanRenderer/RendererMode.swift`: owns the persisted `classic` /
  `gpuDriven` setting. This plan should not add a user-visible Metal 4 mode
  unless the release gate passes and ADR 0016 is revised.
- `Tests/LabanRendererTests/GPUCellParityTests.swift`: raw-RGBA parity harness.
- `Tests/LabanRendererTests/MetalFrameTimingBench.swift`: release timing matrix.

## Plan of Work

### M0 - Isolated Metal 4 Capability Harness

Create a test-only Metal 4 harness in `Tests/LabanRendererTests` or a small
`internal` helper under `Sources/LabanRenderer` that is unavailable on macOS
versions without Metal 4. It must be opt-in through an environment variable such
as `LABAN_TEST_MTL4_COMMAND_MODEL=1`. With the variable unset, tests should skip
cleanly and still compile.

The harness must prove:

- a color render pass writes nonzero pixels into a readback texture;
- a glyph-like textured quad samples a real `R8Unorm` texture, not only a
  one-pixel fake;
- resources used through Metal 4 argument tables are placed in an
  `MTLResidencySet` before work is committed;
- command feedback errors are surfaced as XCTest failures;
- drawable ordering uses the Metal 4 drawable wait/signal sequence when a
  drawable is involved;
- readback-only rendering works without acquiring a drawable, so parity failures
  can be separated from presentation failures.

Acceptance for M0:

```sh
rtk swift test --filter Metal4
LABAN_TEST_MTL4_COMMAND_MODEL=1 rtk swift test --filter Metal4
```

With the flag unset, Metal 4 tests skip cleanly. With the flag set on a capable
macOS 26 machine, all isolated probes pass and write clear failure messages if
residency, argument-table binding, feedback, or readback fails.

### M1 - Production Atlas And Buffer Visibility Probe

Before adding a production Metal 4 renderer branch, write probes that exercise
the same resource shapes as Laban's real renderer:

- the production-sized glyph atlas from `MetalGlyphAtlas`, including glyphs
  populated by normal atlas calls;
- a compacted cell glyph buffer with records generated from
  `TerminalCellPayload`;
- uniform buffers, solid instance buffers, cursor buffers, and the readback
  texture;
- atlas mutation across two frames, where a new glyph is added after the first
  frame and must be visible in the second frame;
- backing-scale and drawable-size changes, where render target resources are
  recreated and residency must be refreshed.

Keep these probes test-only. Do not introduce a user-visible Metal 4 setting in
M1.

Acceptance for M1:

```sh
LABAN_TEST_MTL4_COMMAND_MODEL=1 rtk swift test --filter 'GPUCellParityTests/testMetal4.*'
rtk swift test --filter GPUCellParityTests
```

The opt-in Metal 4 mini-matrix passes on a capable machine, and the default
`GPUCellParityTests` suite remains green without the environment variable.

### M2 - Opt-In Production Candidate

Only after M0 and M1 pass, add an internal production candidate in
`MetalRenderer.swift`. Keep the public renderer modes unchanged:

- user-facing `RendererMode.gpuDriven` still means "use the GPU cell renderer";
- an internal static flag or environment variable may choose the Metal 4 command
  model for tests and local profiling;
- if any Metal 4 setup step fails, the renderer must fail closed by using the
  existing plain-Metal GPU cell path or classic fallback status, never by
  presenting blank text.

The production candidate must render the same content as the current GPU cell
path: solids, sidebar glyphs, terminal cell glyphs, text decorations, procedural
cells, selection/find overlays, cursor overlays, smooth-scroll offsets, atlas
growth, and resize frames. It must not change the `[FrameCommand]` contract or
the software renderer.

Acceptance for M2:

```sh
LABAN_TEST_MTL4_COMMAND_MODEL=1 rtk swift test --filter 'GPUCellParityTests/testMetal4.*'
rtk swift test --filter 'GPUCellParityTests|MetalRendererSmokeTests|RendererModeSettingsTests'
```

Every Metal 4 parity fixture must compare raw RGBA bytes and assert no feedback
errors. The renderer mode menu and persisted defaults remain unchanged.

### M3 - Release Gate And Keep-Or-Retire Decision

Extend `Tests/LabanRendererTests/MetalFrameTimingBench.swift` with a Metal 4 row
that compares three paths on the same workloads:

- classic;
- current plain-Metal GPU cell;
- Metal 4 GPU cell candidate.

Run in release mode only. The candidate must be measured on the same macOS 26
machine, with the same terminal dimensions, font settings, workload list, and
warm-up policy as the plain-Metal GPU cell row.

The Metal 4 production candidate earns its keep only if all of these are true:

- zero raw-RGBA parity failures;
- zero Metal 4 feedback errors;
- no new renderer-mode/session-identity regression;
- p50 and p99 frame CPU are no worse than the current plain-Metal GPU cell path
  on every correctness-sensitive workload;
- the encode-overhead or full-frame timing win is large enough to justify the
  added code. Use `>= 10%` lower renderer CPU p50 on at least the workloads where
  command encoding is the dominant cost as the minimum bar for keeping an
  internal opt-in branch. Use the stricter ADR 0016 default gate before making it
  user-visible or default.

If the candidate fails this gate, remove the production candidate in the same
plan and keep only the isolated proof harness if it remains useful.

Acceptance for M3:

```sh
LABAN_RUN_PERF_BENCH=1 rtk swift test -c release --filter MetalFrameTimingBench/testFrameTimingsAcrossWorkloads
LABAN_TEST_MTL4_COMMAND_MODEL=1 LABAN_RUN_PERF_BENCH=1 rtk swift test -c release --filter MetalFrameTimingBench/testFrameTimingsAcrossWorkloads
rtk git diff --check
```

Record the table in this ExecPlan, update ADR 0016 if the durable policy
changes, and either keep the branch with the measured win or delete it with the
measured no-go.

## Validation and Acceptance

This plan is complete only when a fresh contributor can run the relevant
commands from the repository root and observe one of two clear outcomes:

- Metal 4 remains out of production: the proof harness and benchmark evidence
  explain why, the production candidate is absent, the plain-Metal GPU cell path
  remains green, and ADR 0016 still matches the code.
- Metal 4 returns as an internal or user-visible path: raw-RGBA parity is green,
  release timing beats the stated gate, renderer switching preserves sessions,
  feedback errors fail tests, and ADR 0016 or a successor ADR records the new
  policy.

At minimum, run:

```sh
rtk swift test --filter GPUCellParityTests
rtk swift test --filter 'MetalRendererSmokeTests|RendererModeSettingsTests'
LABAN_RUN_PERF_BENCH=1 rtk swift test -c release --filter MetalFrameTimingBench/testFrameTimingsAcrossWorkloads
rtk git diff --check
```

When Metal 4 tests exist, also run the opt-in commands documented in the
milestones on a macOS 26 machine with a Metal 4 SDK.

## Idempotence and Recovery

Every Metal 4 path in this plan must be guarded by availability checks and an
explicit test/profiling flag until the release gate passes. If a test fails
halfway, rerun it with a fresh process; Metal command queues, command allocators,
residency sets, and drawables are process-local resources and should not require
manual cleanup. If a production candidate regresses parity or frame timing,
delete that candidate and keep the current plain-Metal GPU cell path unchanged.

Do not refresh or commit `.rpg/graph.json` as part of this plan unless a human
explicitly asks for semantic-graph maintenance.

## Artifacts and Notes

Record benchmark tables, parity artifact directories, and any Metal feedback
errors here as the plan progresses. Keep the entries concise and tied to commit
SHAs.

## Review Gate

A separate fresh-state review agent must verify these checks before this
ExecPlan is considered complete:

- [ ] Grep `Sources/LabanRenderer/RendererMode.swift`; expect no new
      user-visible `metal4` renderer mode unless this plan's M3 gate passed and
      ADR 0016 or a successor ADR was updated.
- [ ] Run `rtk swift test --filter GPUCellParityTests`; expect exit 0.
- [ ] If any `MTL4` production code exists under `Sources/LabanRenderer`, run
      `LABAN_TEST_MTL4_COMMAND_MODEL=1 rtk swift test --filter 'GPUCellParityTests/testMetal4.*'`
      on a macOS 26 machine and expect exit 0.
- [ ] If any `MTL4` production code exists, grep it for `MTLResidencySet` or the
      equivalent current SDK residency API; expect every buffer/texture/drawable
      used through an argument table to be covered by a test or helper named in
      this plan.
- [ ] If any `MTL4` production code exists, grep tests for an assertion that
      Metal 4 command feedback errors fail the test rather than only logging.
- [ ] Run the release timing command from M3 and paste the classic, plain-Metal
      GPU cell, and Metal 4 rows into this plan before checking this item.

Review status: NOT REVIEWED.

