# 34. Advance libghostty-vt Pin To Zig 0.16

Date: 2026-09-24

## Status

Accepted. Advances the pin set by ADR 0004; ADR 0001's boundary is unchanged.

## Context

Laban pinned Ghostty at `46d54ed673a004df09078bee56e809421a82370e`
(2026-05-20). Between May and September 2026 upstream completed its Kitty
graphics protocol implementation: animation (`a88ad03e6`), relative placements
(`08450e21e`), image scrolling and clipping inside scroll margins
(`1ffa77c90`), spec-conformance fixes for deletes and queries
(`2ced1e5c8`..`48c7006b9`), and hardening of the shared-memory and file
transmission mediums (`ec7929c9c`, `cf4de795b`). At the old pin every
animation command answers `ERROR: unimplemented action`. Kitty graphics
rendering is the largest remaining gap for agent multiplexers such as herdr
that forward images to their host terminal, so any rendering work should
target the complete implementation rather than the May snapshot.

Upstream moved to Zig 0.16.0 on 2026-07-21 (`e8525c0fd`), before all of that
work. There is no Zig 0.15.2-compatible commit that contains it.

The C API changed in the range, and three of the changes affect Laban:

- `ghostty_terminal_new` takes `cols, rows` directly. The
  `GhosttyTerminalOptions` struct and its `max_scrollback` field are gone.
  Scrollback limits are now the `GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES` and
  `..._MAX_LINES` options. The default byte budget is ~10 KB, so it must be set
  explicitly.
- `ghostty_terminal_mode_get/set` were folded into `ghostty_terminal_get/set`
  with `GHOSTTY_TERMINAL_DATA_MODE` / `GHOSTTY_TERMINAL_OPT_MODE` and a
  `GhosttyTerminalModeConfig`.
- `ghostty_render_state_colors_get` became
  `ghostty_render_state_get(..., GHOSTTY_RENDER_STATE_DATA_COLORS, ...)`.

## Decision

Advance the pin to Ghostty `7c40388b2c63b7dcc5d6c9b9804e40fb2574444f`
(upstream `main`, 2026-09-24) and require Zig exactly 0.16.0.

- Keep the three Laban patches. 0001 (alt-screen pen) applies unchanged. 0002
  is rebased: upstream now rate-limits unsupported-mode warnings through
  `logUnsupportedOnce`, and the patch keeps Laban's debug level and log scope
  at the two mode call sites. 0003 (DECXCPR) is rebased; upstream still
  answers only the plain `CSI 6 n`.
- Preserve the old ~10 MB scrollback budget by setting
  `GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES` to 10,000,000 right after
  `ghostty_terminal_new`. The old `max_scrollback` field fed the same byte
  limit (`PageList.max_size`).
- Wrap mode access in `laban_terminal_mode_get/set` in
  `Sources/LabanTerminalCore/session_internal.h`, so call sites keep their
  shape.
- Bind no new upstream features in this bump. That includes Kitty graphics,
  the OSC 9/777 desktop-notification, progress-report and clipboard callbacks,
  and the render-hold callback. Laban's own `osc_host.c` scanner (ADR 0012)
  keeps handling OSC 9/10/11/52/99/777. With their callbacks unset, those
  upstream features stay inert.

## Consequences

- The pin must match in `scripts/fetch-libghostty-vt`,
  `.github/workflows/check.yml`, ADR 0001, and `THIRD_PARTY_LICENSES.md`.
  `scripts/check-dependencies` enforces the script/ADR match and the Zig 0.16.0
  guard.
- Developers and CI need Zig 0.16.0 (`brew install zig@0.16`). A machine that
  still links `zig@0.15` must unlink it. The fetch script's `float.h` shim
  still applies: Zig 0.16.0's bundled headers also lack `__need_infinity_nan`
  for the macOS 27 SDK.
- Kitty graphics rendering can now be built on the complete upstream
  implementation. The library advances animation frames itself, and each image
  exposes a generation counter for texture re-upload. That work needs its own
  ExecPlan.

## Applies To New Code

1. Keep `LabanTerminalCore` as the only layer holding raw libghostty handles.
2. Read and write terminal modes through `laban_terminal_mode_get/set`, not raw
   `GhosttyTerminalModeConfig` plumbing at each call site.
3. Configure scrollback only through the byte/line options. Never rely on
   upstream's default budget.
4. Before replacing an `osc_host.c` responsibility with a new upstream
   callback, amend ADR 0012. Do not register both for the same sequence.
