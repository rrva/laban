# Upgrade libghostty-vt to Upstream Main

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

Laban uses `libghostty-vt` as its terminal parser, renderer-state source, and
input encoder. Upgrading the pinned Ghostty commit brings upstream fixes for
resize reflow, pending-wrap grapheme handling, build simplification, and new C
API conveniences. The observable result is that Laban builds and passes its
terminal regression suite against the newer static `libghostty-vt` artifact
while keeping the Swift-facing terminal boundary unchanged.

This plan also decides which new upstream APIs should become Laban features now.
The default is conservative: bind an upstream addition only if it fixes an
existing Laban behavior, removes an existing local workaround, or fits current
product scope without implying a deferred MVP non-goal.

## Progress

- [x] 2026-05-21 Confirmed upstream Ghostty `main` is
  `46d54ed673a004df09078bee56e809421a82370e`.
- [x] 2026-05-21 Reviewed `docs/product/mvp.md`, `PLANS.md`, and
  `docs/adr/0001-libghostty-vt-owns-vt-parsing.md`.
- [x] 2026-05-21 Used RPG `plan_change` to identify Laban's compatibility
  surface: terminal effects, key input, mouse input, paste, and link smoke
  tests.
- [x] 2026-05-21 Updated the dependency pin in `scripts/fetch-libghostty-vt`,
  `.github/workflows/check.yml`, ADR 0001, and new ADR 0004.
- [x] 2026-05-21 Rebuilt `.external/libghostty-vt` at the new commit.
- [x] 2026-05-21 Removed Laban's explicit `-lc++` linker flag after the rebuilt
  upstream static archive linked successfully without it.
- [x] 2026-05-21 Evaluated upstream additions and bound only the additions that
  should be part of Laban now.
- [x] 2026-05-21 Adopted `_get_multi` narrowly in the terminal snapshot hot
  path, while keeping the Swift-facing `LabanSnapshot` ownership boundary.
- [x] 2026-05-21 Added DECBKM/backarrow key-mode coverage, proving the new
  upstream mode flows through Laban's existing key encoder synchronization.
- [x] 2026-05-21 Ran focused and full validation.
- [x] 2026-05-21 Prepared the completed bump for commit.

## Decision Log

- Decision: Do not expose Kitty graphics rendering as part of this bump.
  Rationale: Kitty graphics display is an explicit MVP non-goal in
  `docs/product/mvp.md`. Upstream added useful Kitty graphics C helpers, but
  binding them now would expand product scope beyond a dependency upgrade.
  Date/Author: 2026-05-21 / Codex.

- Decision: Use `_get_multi` only in the snapshot hot path.
  Rationale: Laban's C layer still owns snapshot extraction, but each cell
  previously made multiple C ABI calls into libghostty for raw cell data, style,
  grapheme length, and metadata. Batching those reads reduces per-frame call
  volume without exposing borrowed libghostty pointers to Swift. Foreground and
  background color getters stay individual because unset colors intentionally
  return `GHOSTTY_INVALID_VALUE` and `_get_multi` stops at the first error.
  Date/Author: 2026-05-21 / Codex.

- Decision: Remove the explicit `-lc++` linker flag from `Package.swift`.
  Rationale: Upstream now builds vendored C++ SIMD dependencies in no-libc++
  mode for `libghostty-vt`. `rtk swift test --filter GhosttyVTLinkTests`
  linked and ran successfully with only the static archive flag.
  Date/Author: 2026-05-21 / Codex.

- Decision: Add DECBKM coverage without adding a Laban-side mode mirror.
  Rationale: Upstream exposes backarrow key mode and `setopt_from_terminal`
  already synchronizes terminal state into the key encoder. A test in
  `LabanSessionKeyEncodingTests` verifies backspace switches between DEL and
  BS when the terminal receives `CSI ? 67 h/l`.
  Date/Author: 2026-05-21 / Codex.

- Decision: Do not install a libghostty log callback or override APC byte
  limits in this bump.
  Rationale: The log callback needs observability policy design to avoid noisy
  release logs. Upstream APC handling already has a built-in 65 MiB Kitty limit;
  lowering it would be a behavioral policy decision for a future resource-limit
  change rather than a dependency bump.
  Date/Author: 2026-05-21 / Codex.

## Context and Orientation

`scripts/fetch-libghostty-vt` owns the Ghostty commit pin, clones the upstream
repository into `.external/libghostty-vt`, applies local source patches, and
runs `zig build -Demit-lib-vt -Doptimize=ReleaseFast`. CI repeats the pin in
`.github/workflows/check.yml` so the cache key changes when the dependency
changes. `docs/adr/0001-libghostty-vt-owns-vt-parsing.md` records why Laban uses
`libghostty-vt` and requires an ADR entry when the pin advances.

`Package.swift` links `LabanTerminalCore` against
`.external/libghostty-vt/zig-out/lib/libghostty-vt.a`. Upstream now says the
library removed libc++ dependencies; this plan must verify whether Laban can
drop the explicit `-lc++` linker flag without breaking SwiftPM builds.

The narrow C boundary lives in `Sources/LabanTerminalCore`. Key compatibility
files are:

- `session_lifecycle.c`, which creates the Ghostty terminal, resizes it, and
  owns session teardown.
- `snapshot.c`, which reads Ghostty render state and produces owned
  `LabanSnapshot` values for Swift.
- `terminal_effects.c`, which registers host callbacks such as terminal size,
  device attributes, XTVERSION, answerback, title changes, focus, and
  synchronized output.
- `key_input.c`, `mouse_input.c`, and `paste.c`, which use Ghostty's encoders.
- `ghostty_vt_bridge_smoke.c` and
  `Tests/LabanTerminalCoreTests/GhosttyVTLinkTests.swift`, which prove the
  static library links and `ghostty_terminal_new` works.

## Plan of Work

First update pin metadata in `scripts/fetch-libghostty-vt`,
`.github/workflows/check.yml`, and
`docs/adr/0001-libghostty-vt-owns-vt-parsing.md`. The ADR update must name the
new commit and summarize the API delta and decision about new bindings.

Then rebuild `.external/libghostty-vt` using `./scripts/fetch-libghostty-vt`.
If the build succeeds, test whether `Package.swift` can remove `-lc++`; keep the
flag only if the new artifact still requires it. Because `.external/` is
git-ignored, this rebuild changes the local working artifact but should not add
vendored files to git.

After compilation, inspect upstream additions against current product scope:

- Use DECBKM/backarrow mode only if key encoding requires an explicit option
  beyond `ghostty_key_encoder_setopt_from_terminal`.
- Consider installing the new log callback only if it can feed existing Laban
  diagnostics without noisy release logs.
- Leave Kitty graphics helpers unbound in this bump because rendering graphics
  is a product feature, not dependency maintenance.
- Leave `_get_multi` render/terminal getters unbound unless tests or profiling
  show a concrete benefit during the bump.
- Consider APC byte-limit options if they reduce risk without product surface.

Finally run focused terminal-core tests, then `./scripts/check`. Update this
plan with validation results and any surprises before committing.

## Validation and Acceptance

Run from `/Users/rrj/wrk/laban`:

```sh
rtk ./scripts/fetch-libghostty-vt
rtk swift test --filter GhosttyVTLinkTests
rtk swift test --filter LabanSessionTests
rtk ./scripts/check
```

Acceptance is:

- `scripts/check-dependencies` accepts that the script pin, ADR commit, and
  local `.external/libghostty-vt` checkout agree. This passed on 2026-05-21.
- `GhosttyVTLinkTests` passes against the rebuilt static archive. This passed
  on 2026-05-21.
- `LabanSessionKeyEncodingTests` passes and includes
  `testBackarrowModeChangesBackspaceEncoding`. This passed with 10 tests on
  2026-05-21.
- `LabanSessionTests` passes, including resize/reflow and key/mouse/paste
  regressions. This passed with 68 tests on 2026-05-21.
- `./scripts/check` exits 0. This passed on 2026-05-21 with 668 package tests,
  3 skipped, 0 failures, plus build-app, smoke-runtime, and test-e2e.
- The final changeset either binds a justified upstream addition or documents
  why the additions are intentionally deferred. This plan and ADR 0004 document
  the decisions.

## Outcomes & Retrospective

Laban now builds against Ghostty commit
`46d54ed673a004df09078bee56e809421a82370e`. The bump adopts the upstream
static-library packaging improvement by removing `-lc++`, preserves the existing
Swift-facing C boundary, adds a regression for the new DECBKM/backarrow key
mode, and uses `_get_multi` inside terminal snapshot extraction to reduce
repeated libghostty getter calls. Broader upstream additions remain
intentionally deferred: Kitty graphics would expand product scope, log callbacks
need observability design, and APC policy should be handled as an explicit
resource-limit change.

## Idempotence and Recovery

`./scripts/fetch-libghostty-vt` is intended to be rerunnable. When the pin
changes, it removes a stale checkout under `.external/libghostty-vt`, clones the
pinned commit, reapplies local patches, and rebuilds the archive. If a build
fails after partially updating `.external/`, rerun the script after fixing the
reported issue.

Do not commit `.external/`, `.rpg/`, or build artifacts. If a pin edit compiles
but fails tests, restore only the files changed by this plan or fix forward; do
not reset unrelated user work.
