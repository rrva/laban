# Advance the libghostty-vt pin to upstream's complete Kitty graphics implementation

This ExecPlan is a living document maintained in accordance with `PLANS.md`
at the repository root. Keep `Progress` and `Validation and Acceptance`
current as work proceeds.

## Purpose / Big Picture

Laban's terminal core is libghostty-vt, the terminal state machine from
Ghostty. Laban builds it from source at an exact upstream commit (the "pin").
The pin was a May 2026 snapshot. Since then upstream finished the Kitty
graphics protocol, the escape-sequence protocol that lets programs show images
in a terminal. It gained animation, relative placements, correct scrolling
inside scroll regions, many conformance fixes, and hardened file and
shared-memory transfer. At the old pin, animation commands are rejected with
`ERROR: unimplemented action`.

This plan moves Laban to upstream `main` as of 2026-09-24 and changes nothing
users can see. Every existing test, replay fixture and the app itself must
behave exactly as before. The payoff is the next plan: Kitty graphics
rendering can be built on the complete upstream implementation instead of a
partial one. Tools such as herdr (an agent multiplexer that forwards images to
its host terminal) and image-capable CLIs then work in Laban.

To see it working: `./scripts/fetch-libghostty-vt` reports the new commit,
`swift test` passes, and the installed app behaves as before, including 10 MB
of scrollback.

## Progress

- [x] (2026-09-24) Confirmed every Kitty graphics completion commit is newer
  than upstream's switch to Zig 0.16.0 (`e8525c0fd`, 2026-07-21). There is no
  Zig 0.15-compatible commit with the work.
- [x] (2026-09-24) Installed Zig 0.16.0 locally (`brew unlink zig@0.15 &&
  brew install zig`).
- [x] (2026-09-24) Updated the pin and Zig version in
  `scripts/fetch-libghostty-vt`, `scripts/check-dependencies`,
  `.github/workflows/check.yml`, `README.md`, ADR 0001 and
  `THIRD_PARTY_LICENSES.md`. Added ADR 0034.
- [x] (2026-09-24) Rebased patches 0002 and 0003. 0001 applies unchanged.
- [x] (2026-09-24) Built libghostty-vt at the new pin with Zig 0.16.0.
- [x] (2026-09-24) Adapted `LabanTerminalCore` to the C API changes (terminal
  creation, scrollback option, mode get/set, render-state colors).
  `swift build --build-tests` succeeds.
- [x] (2026-09-24) Full `swift test`: every libghostty-related suite passes.
  The failures left over also fail on `main` at `3f48b88c`, so they predate
  this change: 11 `TerminalSurfaceControllerTests` cell-payload/damage tests,
  `GPUCellRetainedRingRegressionTests.testGPUCellRetainedLabptyClaudeUIRepaintsOnFirstSnapshotAfterCleanRenderState`,
  and two order-dependent `CJKFontSettingsTests`.
- [x] (2026-09-24) Absorbed two upstream behavior changes surfaced by
  `LabanSessionTests` (see Surprises).
- [ ] `./scripts/check` passes.
- [ ] Installed-app smoke check: scrollback depth, alt-screen apps, DECXCPR.

## Decision Log

- Decision: Pin upstream `main` HEAD
  (`7c40388b2c63b7dcc5d6c9b9804e40fb2574444f`) rather than a release tag.
  Rationale: The newest tag, v1.3.1, predates the Kitty graphics work, and
  HEAD is the only point that contains all of it plus the medium-hardening
  fixes (`ec7929c9c`, `cf4de795b`). The previous pin was also a `main`
  snapshot.
  Date/Author: 2026-09-24 / Claude.

- Decision: Keep patch 0002's debug level for unknown modes even though
  upstream now logs each unknown mode only once.
  Rationale: This is a dependency bump; log volume and level must not change.
  Whether to drop 0002 is a separate, reviewable decision.
  Date/Author: 2026-09-24 / Claude.

- Decision: Set `GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES` to 10,000,000
  after `ghostty_terminal_new`.
  Rationale: The removed `GhosttyTerminalOptions.max_scrollback` fed
  `PageList.max_size`, a byte budget, so 10,000,000 there meant ~10 MB. The new
  default is ~10 KB, which would silently cut scrollback to almost nothing.
  Date/Author: 2026-09-24 / Claude.

- Decision: Do not vendor the Ghostty source tree into this repository.
  Rationale: The pin plus reviewed patches already gives reproducibility and
  local control. Upstream is actively landing exactly the complicated,
  spec-heavy work Laban wants, such as Kitty graphics conformance, and a
  vendored copy would turn every future bump into a manual merge. A GitHub
  fork used as the fetch URL is the lighter hedge if upstream availability
  ever becomes a concern.
  Date/Author: 2026-09-24 / Claude, at the user's prompt.

## Surprises & Discoveries

- Observation: libghostty now answers OSC 4/10/11/12 color queries itself
  whenever a color is configured, echoing the query's BEL or ST terminator.
  Laban's `osc_host.c` responder answered the same queries, so every query got
  two replies.
  Evidence: `testOSCForegroundColorQueryEchoesEffectiveForeground` saw
  `ESC]10;rgb:1a1a/2b2b/3c3c BEL ESC]10;rgb:1a1a/2b2b/3c3c ESC\`.
  Resolution: `respond_osc_color_query` now replies only when libghostty stays
  silent, meaning no color is configured, keeping its scheme-based fallback.
  Tests now expect the terminator echo. A new
  `testOSC4PaletteQueryRepliesWithPaletteEntry` covers palette queries, which
  herdr sends to theme itself.

- Observation: libghostty now sends an in-band size report immediately when
  mode 2048 is enabled, as the in-band resize spec requires.
  Evidence: `testInBandResizeReportIsEmittedWhenMode2048IsEnabled` received
  `ESC[48;24;80;0;0t` right after `CSI ? 2048 h`.
  Resolution: accepted as a conformance fix; the test now expects the report.

- Observation: The macOS 27 SDK `float.h` shim in `scripts/fetch-libghostty-vt`
  is still needed with Zig 0.16.0.
  Evidence: The fetch run printed `shimming zig float.h for
  __need_infinity_nan SDKs` and the build succeeded.

## Context and Orientation

- `scripts/fetch-libghostty-vt` clones Ghostty at `GHOSTTY_COMMIT` into
  `.external/libghostty-vt` (git-ignored). It applies `patches/*.patch` in the
  order 0002, 0001, 0003, then runs `zig build -Demit-lib-vt
  -Doptimize=ReleaseFast`. That produces `zig-out/lib/libghostty-vt.a` and
  headers under `zig-out/include/ghostty/vt/`. It refuses any Zig version other
  than the one it names.
- `scripts/check-dependencies` verifies that the script's pin matches ADR 0001
  and that the fetch script keeps its safety guards, including the exact Zig
  version check.
- `Sources/LabanTerminalCore` is the only code that calls libghostty. The
  files changed here are:
  - `session_lifecycle.c`: terminal creation and the scrollback budget.
  - `ghostty_vt_bridge_smoke.c`: a link smoke test.
  - `session_internal.h`: the new `laban_terminal_mode_get/set` helpers.
  - `osc133.c`, `paste.c`, `terminal_effects.c`: mode access.
  - `snapshot.c`: render-state colors.
- Git worktrees do not share `.external/` automatically; see
  `docs/process/worktree-isolation.md`. This work was done in a separate
  worktree with its own `.external`, so the main checkout kept building
  against the old pin until merge.

## Plan of Work

The pin, patch and API changes are done (see Progress). What remains is
validation. After merging to `main`, rerun `./scripts/fetch-libghostty-vt` in
the main checkout. The changed pin makes the script replace the old clone. Then
rebuild and reinstall the app.

## Concrete Steps

From the repository root, with Zig 0.16.0 on PATH:

    ./scripts/fetch-libghostty-vt
    # expect: "... done. artifacts at .external/libghostty-vt/zig-out/"
    ./scripts/check-dependencies
    swift build --build-tests
    swift test
    ./scripts/check

## Validation and Acceptance

- `./scripts/check-dependencies` exits 0.
- `swift test` reports 0 failures. Order-dependent test-isolation failures
  that also occur on the old pin (for example
  `CJKFontSettingsTests.testDefaultPreferenceIsPingFangSC`) are recorded here,
  not fixed in this plan.
- In a Laban tab, `seq 1 200000` followed by scrolling to the top of the
  scrollback shows early numbers (well below 150000). That proves the ~10 MB
  budget is in effect, not upstream's ~10 KB default.
- `printf '\e[?6n'; read -rs -d R r; printf '%q\n' "$r"` prints a reply that
  starts with `$'\E[?'`, proving patch 0003 is active.
- Quitting `btop` and launching `top` shows no black flash, proving patch
  0001 is active.

## Idempotence and Recovery

`./scripts/fetch-libghostty-vt` can be rerun safely. It resets the vendored
checkout to the pin before applying patches. To roll back, revert this plan's
commit, run `brew unlink zig && brew link zig@0.15`, and rerun the fetch
script.

## Interfaces and Dependencies

- Zig 0.16.0 exactly (`brew install zig@0.16`).
- Ghostty `7c40388b2c63b7dcc5d6c9b9804e40fb2574444f`.
- In `Sources/LabanTerminalCore/session_internal.h`:

      static inline GhosttyResult laban_terminal_mode_get(GhosttyTerminal t, GhosttyMode mode, bool *out_value);
      static inline GhosttyResult laban_terminal_mode_set(GhosttyTerminal t, GhosttyMode mode, bool value);
