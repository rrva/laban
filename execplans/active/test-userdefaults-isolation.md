# Give each test process its own UserDefaults domain so the big targets can run in parallel

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
It unblocks parallel execution for the five test targets that
`scripts/test-split` currently forces to run sequentially. Success is
demonstrated by those targets passing under `swift test --parallel` across
repeated runs, with a measured wall-clock drop and no quarantine list.

Related plans, both of which stop short of this work:

- `execplans/active/faster-full-test-suite.md` established on 2026-07-12 that
  `swift test`'s `UserDefaults.standard` resolves to the on-disk
  `com.apple.dt.xctest.tool` preference domain rather than a per-run sandbox,
  and hardened the *victims* of one leak (`LabanVectorTextWeight`) without
  hardening its source. It concluded the suite "must not depend on unsafe
  parallel execution".
- `execplans/active/parallel-test-safety-and-overlapped-check-stages.md`
  fixed a separate labpty slot-exhaustion race and is complete. Its audit
  explicitly looked for `UserDefaults.standard` contamination but scoped the
  response to target-level sharding, not per-key isolation.

## Purpose / Big Picture

`scripts/test-split` shards by target: `LabandTests`, `LabptyTests`,
`LabanAgentTests`, `LabanCLITests` and `LabanTerminalCoreTests` run under
`--parallel`, while `LabanCoreTests`, `LabanRendererTests`, `LabanDebugTests`,
`LabanAppTests` and `LabanControlTests` run in one sequential invocation.

That sequential half contains the suite's heaviest work, including the vector
and slug glyph oracle sweeps. Serialising it is why a full run takes ~6.5
minutes of test execution. The blocker is not the tests being logically
order-dependent; it is that `swift test --parallel` runs each test class in its
own process while every process shares one preferences domain, so a suite that
save/restores a global settings key around a test is correct alone and
destructive alongside others.

The fix is to stop reading and writing the shared domain from tests: route
settings access through an injectable `UserDefaults` so each test supplies its
own suite, exactly as `Tests/LabanCoreTests/HoverPreviewSettingsTests.swift`
already does.

## Progress

- [x] (2026-07-25) Measure the ceiling. Fully serial: 386.4s of test execution,
  2855 tests. Fully parallel: 106s wall. So the available win is ~3.6x.
- [x] (2026-07-25) Confirm the mechanism from failure signatures rather than
  assumption. A full `--parallel` run failed 18 cases across 12 suites with
  values that name the contended key directly: `"10.0" is not equal to
  "14.0"` (`FontAtlas.userFontSizeKey`), `"vectorGlyph" is not equal to
  "classic"` (`RendererSelection.defaultsKey`), `"color" is not equal to
  "monochrome"`, `"100.0" is not equal to "73.0"` (transparency).
- [x] (2026-07-25) Establish that victims and culprits are different sets. Of
  the five suites writing `FontAtlas.userFontKey`
  (`FontSizeActionTests`, `GlyphAtlasLadderTests`, `LabanRendererSmokeTests`,
  `FontAtlasZoomTests`, `ContinuousZoomTests`), three never fail themselves.
  Hardening only the failing suites therefore cannot work.
- [x] (2026-07-25) Rule out quarantining as a stable strategy, empirically.
  Skipping all 12 failing suites plus the 3 known polluters surfaced **7
  different** failing suites on the next run (`CursorSettingsUITests` with
  `"block" is not equal to "bar"`, `ColorEmojiTests`,
  `MetalRendererSmokeTests`, `RendererActivationNoBlankWindowTests`,
  `VectorGlyphParityTests`, `CursorSettingsHeadlessTests`, and this plan's own
  `SettingsEnvironmentCacheTests`). A quarantine list does not converge
  because 42 test files touch the shared domain; only the ones that currently
  collide are visible.
- [x] (2026-07-25) Harden `SettingsEnvironmentCacheTests` so its concurrency
  case hammers an injected suite instead of `UserDefaults.standard`.
- [x] (2026-07-25) Inventory and size the work. 129 references across 42 test
  files, 45 across 19 production files, ~32 distinct keys behind ~21 settings
  types. **16 of those types already have a `defaults:` seam**; only 5 need one
  (`FontAtlas`, `ScrollSettings`, `CursorSettings`,
  `AttentionNotificationSettings`, `RestoreOnLaunchSettings`). All 42 affected
  test files sit in the four sequential-shard targets and none in the five
  parallel-safe ones, so `scripts/test-split`'s existing boundary was drawn
  exactly along this fault line.
- [x] (2026-07-26) Milestone 1: `FontAtlas` seam and its direct consumers.
  Added `terminalPointSize(from:)`, `sidebarPointSize(from:)`,
  `previewPointSize(from:)` and `init(pointSize:defaults:)`, each keeping the
  existing `.standard` accessor as a delegating wrapper so production is
  untouched. Converted `FontAtlasZoomTests`, `GlyphAtlasLadderTests` and
  `LabanRendererSmokeTests` to private suites; all three dropped out of the
  `--parallel` failure list across 3 consecutive runs. The wiped-suite pattern
  also deletes the manual save/restore blocks those tests carried.
- [x] (2026-07-26) Milestone 2: settings the renderer reads from
  `UserDefaults.standard` are now supplied through the **registration domain**
  instead of being persisted. `register(defaults:)` is per-process, never
  reaches disk, and `object(forKey:)` resolves it exactly like a persisted
  value, so no renderer-level injection was needed after all. Converted
  `VectorGlyphGammaTests`, `VectorWeightCoreTextParityTests`,
  `SlugWeightCoreTextParityTests`, `VectorGlyphParityTests`,
  `SlugGlyphRendererTests`, `SlugGlyphAAFidelityTests`, `ColorEmojiTests`,
  `CJKFontMetricsTests`, `TranslucentLinearBlendTests`,
  `ColorGlyphScrollBench`, and both copies of `withTemporaryUserDefault`.
  `LabanRendererTests` failures under `--parallel` went 8 suites -> 0
  state-related, and the `com.apple.dt.xctest.tool` domain stays **empty**
  after 3 consecutive runs.
- [x] (2026-07-26) Milestone 2b: private suite names must be process-unique.
  SwiftPM's `--parallel` forks per *test case*, not per class, so sibling test
  methods sharing a fixed `suiteName` clobber each other through
  `removePersistentDomain`. That is why `CJKFontSettingsTests` failed
  intermittently despite already injecting a suite. All fixed names are now
  pid-scoped, matching the `UUID().uuidString` convention `GPUCellParityTests`
  and `VectorSubpixelLayoutTests` already used.
- [x] (2026-07-26) `LabanRendererTests` promoted to the parallel shard in
  `scripts/test-split`, with `VectorGlyphParityTests` held back in a new
  serial shard. Measured `test-split` 345s -> 313s.
- [ ] Milestone 3: promote `LabanCoreTests`, `LabanDebugTests` and
  `LabanAppTests`. These now dominate: with the renderer moved out, the
  sequential shard is the remaining bottleneck, so this is where the rest of
  the speedup lives.
- [ ] Superseded, kept for context: renderer-level injection. `VectorGlyphGammaTests` (fails
  3/3 under `--parallel`) writes `VectorTextWeightSettings.defaultsKey` and
  `LabanVectorPresentDisplayLink` *so that the renderer under test reads them*,
  so a private suite would silently change what the test exercises. The
  renderer has to accept injected defaults first. Same shape blocks
  `ContinuousZoomTests` (drives `applyZoomMagnification`, which persists via
  `TerminalBitmapView`) and `FontSizeActionTests` (drives a headless runtime).
- [ ] Milestone 3: the non-defaults class. `SlugGlyphDamageTests` fails 3/3
  with golden-hash mismatches despite zero `UserDefaults.standard` references;
  the hypothesis is that Milestone 2 fixes it for free by stopping the text
  weight leak, and it should be re-measured before being investigated.
- [ ] Add or confirm an injectable `defaults:` seam on the four remaining
  types: `ScrollSettings`, `CursorSettings`, `AttentionNotificationSettings`,
  `RestoreOnLaunchSettings`.
- [ ] Convert the test files, highest-contention keys first: `FontAtlas`
  font/size, `RendererSelection` + `VectorSubpixelLayout`, cursor style,
  emoji rendering, transparency, `ScrollSettings.modeKey`.
- [ ] Move targets from the sequential shard to the parallel shard in
  `scripts/test-split` one at a time, each backed by repeated green runs.
- [ ] Re-measure and record the wall-clock result.

## Decision Log

- Decision: do not ship a per-class quarantine list in `scripts/test` or
  `scripts/test-split`.
  Rationale: measured. Quarantining 15 suites produced a fresh set of 7
  failures rather than a green run, and the list would need re-deriving
  whenever scheduling shifts or a test is added. It also duplicates
  `scripts/test-split`, which already shards, at a granularity that cannot be
  kept correct by inspection.
  Date/Author: 2026-07-25 / Claude
- Decision: keep `scripts/test-split`'s target-level sharding as the entry
  point and change it only when a whole target has been made safe.
  Rationale: a target either is or is not parallel-safe, which is checkable;
  a per-class list is a snapshot of one scheduling order.
  Date/Author: 2026-07-25 / Claude

## Context and Orientation

- `scripts/test-split` holds the two shard regexes and is called by
  `scripts/check`. `scripts/pre-push` calls `swift test` directly.
- `Tests/LabanCoreTests/HoverPreviewSettingsTests.swift` is the reference
  pattern: a per-class `UserDefaults(suiteName:)` created in `setUp` and torn
  down with `removePersistentDomain`.
- `Sources/LabanRenderer/RendererSelection.swift` shows the production shape to
  copy: `persisted(defaults: UserDefaults = .standard)`, so production keeps
  its default while tests inject.

## Validation and Acceptance

- The five currently-sequential targets pass under `swift test --parallel`
  across at least 5 consecutive runs with no quarantine list.
- `./scripts/check` passes.
- Recorded before/after wall-clock timings from the same warm worktree.
- No production behaviour change: the `defaults:` parameters keep
  `.standard` defaults, so shipping code paths are untouched.

## Surprises & Discoveries

- The contended state is not only `UserDefaults`. `ControlSecurityFloorTests`
  has zero `UserDefaults.standard` references and still fails under
  `--parallel` (`"selection.read"` observed where `"app.state"` was expected),
  as do `SlugGlyphDamageTests` and `ChineseTransparencyTrustGateTests` via
  golden hashes that are sensitive to font state set elsewhere. Expect a
  second class of shared state (control-server audit state, headless runtime,
  golden-image inputs) that per-key defaults isolation will not fix.
- `swift test --parallel` masks its own exit status when piped, so a run that
  looks green in a `| tail` can be failing. Capture the status explicitly.
- The leak outlives the run. After a few `--parallel` experiments the
  `com.apple.dt.xctest.tool` domain was left holding `LabanFontSize = 15`,
  `LabanMetalPresentDisplayLink = 0`, `LabanEmojiRenderingMode = monochrome`
  and more, because a test whose `defer` restore lost a race leaves its value
  persisted on disk. That state then broke a *serial* run of an unrelated
  suite: `RendererTransparencyIdempotenceTests` failed with "renderer rejected
  frame" purely because the present display link had been left disabled, and
  passed immediately after `defaults delete com.apple.dt.xctest.tool`.
  So a green serial run is not proof of a clean tree, and a red one is not
  proof of a real regression. When a serial failure appears out of nowhere,
  read that domain before reading the diff. This also means the eventual fix
  removes a whole class of "works on my machine" confusion, not just wall-clock
  time.
