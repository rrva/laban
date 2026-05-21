# 4. Advance libghostty-vt Pin

Date: 2026-05-21

## Status

Accepted

## Context

ADR 0001 selects `libghostty-vt` as Laban's VT parsing library and keeps the
application responsible for PTY ownership. Laban originally pinned Ghostty at
`fdb6e3d2c8543e2e756b7e07f44372efbc0fba4b`. Upstream Ghostty `main` has moved
to `46d54ed673a004df09078bee56e809421a82370e`.

The upstream range includes changes that matter to Laban:

- `815ccb06` fixes a viewport pin during resize reflow.
- `c20fcfa1` fixes zero-width grapheme attachment while wrap is pending.
- `e51de8b5` removes libc++ and libc++ ABI dependencies from `libghostty`.
- `2c1dad79` adds `_get_multi` helpers for terminal, render, row, and cell
  getters.
- `3a9ae7a0` exposes DECBKM/backarrow key mode through `libghostty-vt`.
- `0069e28c` exposes APC maximum byte limits.
- `aa6943da` adds a C log callback hook.
- `3295bf40` adds Kitty graphics convenience accessors.

The MVP regression contract in `docs/product/mvp.md` still excludes Kitty
graphics display and requires Swift to see snapshots rather than raw
libghostty state.

## Decision

Advance Laban's pinned `libghostty-vt` dependency to Ghostty commit
`46d54ed673a004df09078bee56e809421a82370e`.

Keep the existing Laban C boundary. The bump does not expose raw libghostty
handles to Swift, does not move PTY ownership out of `LabanTerminalCore`, and
does not add Kitty graphics display.

Evaluate upstream additions conservatively:

- DECBKM/backarrow support may be used through existing Ghostty key encoder
  state if tests show Laban needs explicit handling.
- APC byte limits may be set if they reduce parser resource risk without
  product surface.
- `_get_multi` APIs are used inside `LabanTerminalCore` for hot snapshot
  extraction where they reduce repeated C ABI calls without changing snapshot
  ownership. Broader migration is optional performance work.
- The log callback may be wired later into Laban diagnostics if it can be kept
  quiet in normal release operation.
- Kitty graphics helpers remain unbound until product scope includes graphics
  rendering.

## Consequences

- The pinned commit in `scripts/fetch-libghostty-vt`,
  `.github/workflows/check.yml`, and ADR 0001 must match
  `46d54ed673a004df09078bee56e809421a82370e`.
- The local `.external/libghostty-vt` checkout and `zig-out` static archive must
  be rebuilt at the new commit.
- The explicit `-lc++` linker flag can be removed only after SwiftPM builds
  against the rebuilt archive without it.
- Resize, scrollback, key input, mouse input, paste, formatter, and render
  snapshot tests are the compatibility guardrail for this bump.

## Applies To New Code

1. Keep `LabanTerminalCore` as the only layer that holds raw libghostty handles.
2. Do not bind Kitty graphics helpers until the product docs include graphics
   display behavior.
3. Prefer existing Ghostty terminal-mode synchronization before adding
   Laban-side mode mirrors for key or mouse encoding.
4. Any use of `_get_multi` must keep snapshot ownership unchanged: Swift
   receives owned `LabanSnapshot` data, not borrowed libghostty pointers.
5. Any future log callback wiring must route through the existing observability
   policy and must not emit noisy normal-operation logs.
