# 11. libghostty Alternate-Screen Clear Uses the Primary Pen (Vendored Patch)

Date: 2026-05-30

## Status

Accepted.

This is a local patch to the vendored libghostty-vt pinned by ADR 0004 (Ghostty
`46d54ed6`). It does not change the ADR 0001 boundary (libghostty still owns VT
parsing); it corrects a defect inside that library. It establishes the pattern
for carrying local libghostty patches.

## Context

Quitting one full-screen app and starting another briefly painted the terminal
area black. Reproduced deterministically: a program (btop) enters the alternate
screen, fills it with a background colour, and on quit leaves its SGR background
set (btop emits `␛[48;2;0;0;0m␛[?1049l`). The next program (top) enters the
alternate screen with `␛[?1049h` and relies on the xterm-specified clear-on-enter
— it sends no `␛[2J` of its own, just `␛[H` and draws. So wherever top has not
yet painted, the screen shows the previous app's background until top fills it.

The cause is in libghostty's `Terminal.switchScreenMode` (mode 1049 enable). It
runs, in order: `saveCursor` → `switchScreen(.alternate)` → `eraseDisplay` →
`cursorCopy(primary cursor)`. libghostty keeps a **per-screen cursor**, so right
after the switch the active pen is the alternate screen's *leftover* pen (btop's
black). `eraseDisplay` clears with background-colour-erase using that stale pen,
and only afterward is the primary cursor copied in — too late. xterm avoids this
because it has a single cursor; libghostty's per-screen model exposes the
ordering. A LabanCore probe confirmed it: fill the alt buffer green, leave the
pen red, quit, re-enter — the re-entered screen clears to **red** (the stale
pen), not green (cells) or the theme background.

Laban renders the cleared cells faithfully, so this surfaced as the user-visible
"black flash". It is terminal-area only (the sidebar is themed separately), and
only on app→app transitions (the first shell→app entry is clean because the alt
buffer started empty). An earlier app-side guess (clearing the Metal target to
the theme background instead of black, commit `3564afb`) did not fix it, because
the black is data the snapshot legitimately carries, not a render clear colour.

## Decision

Patch vendored libghostty so the 1049-enter branch copies the primary cursor
**before** erasing, so the clear uses the primary screen's pen (the current SGR,
typically the theme default) rather than the alternate screen's stale pen.

- **The change** lives in `.external/libghostty-vt/src/terminal/Terminal.zig`,
  `switchScreenMode`, `.@"1049" => if (enabled)`: move the `cursorCopy(old.cursor)`
  block above `self.eraseDisplay(.complete, false)`.
- **Persistence.** `.external/` is a git-ignored, shared, pinned checkout, so the
  edit is not tracked by this repo. It is captured as
  `patches/libghostty-vt-0001-alt-screen-clear-uses-primary-pen.patch` and
  re-applied by `scripts/fetch-libghostty-vt` (via `git -C "$DEST" apply`) after
  it clones the pinned commit — mirroring the existing `stream.zig` patch the
  script already applies. The apply is a hard failure (`|| fail`) so a pin bump
  that drifts the context surfaces loudly instead of silently dropping the fix.
- **Rebuild.** The static library is rebuilt with
  `zig build -Demit-lib-vt -Doptimize=ReleaseFast` (ReleaseFast is required for
  performance — see the script's note on `verifyIntegrity`).
- **Regression.** `Tests/LabanCoreTests/AltScreenClearUsesPrimaryPenTests.swift`
  drives the btop→top sequence and asserts the re-entered alternate screen clears
  to the theme background, not the stale pen. It is red/green verified: with the
  patch reversed and the library rebuilt clean, it fails (`cell bg == black`).

## Consequences

- App→app alternate-screen transitions clear to the current/primary background;
  no stale-pen flash. Single-cursor terminals were never affected, so behaviour
  now matches them and xterm.
- This should be upstreamed to `ghostty-org/ghostty`. When a fix lands upstream
  and the ADR 0004 pin advances past it, drop the patch and the script step.
- The patch is fragile to context drift on a pin bump by design: the `git apply`
  fails the build, forcing a human to re-roll the patch (or confirm it is fixed
  upstream) rather than shipping a silently-unpatched library.
- Verifying changes to the vendored library requires a **clean** SwiftPM rebuild:
  the `.a` is linked via `unsafeFlags`, which SwiftPM does not track as a build
  input, so it will not relink after only the `.a` changes. Rebuild the `.a` with
  zig, then `rm -rf .build` (or the test build dir) before `swift test`/`build-app`.

## Applies To New Code

A local patch to vendored libghostty must: (1) live as a numbered patch file in
`patches/`, (2) be applied by `scripts/fetch-libghostty-vt` after the pinned
clone with a hard failure on apply error, (3) carry a Laban-side regression test
that fails without the patch (mutation-verified via a clean rebuild), and (4) be
recorded in an ADR with intent to upstream. Do not commit edits directly into
`.external/` — it is shared across worktrees and reconstructed from the pin.
