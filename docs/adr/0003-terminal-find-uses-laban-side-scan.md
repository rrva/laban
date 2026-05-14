# 3. Terminal Find Uses Laban-Side Snapshot And Scrollback Scan

Date: 2026-05-14

## Status

Accepted

## Context

Laban needs Command-F search for the active terminal session. The vendored
libghostty-vt source tree contains a mature Zig search engine, including screen
search, page-list search, and highlight flattening. That engine is not exposed
through the public C ABI in `.external/libghostty-vt/include/ghostty/vt/`.

Swift code currently sees terminal content only through owned `LabanSnapshot`
values and narrow C helpers on `LabanSession`. Exposing libghostty-vt's search
engine directly would require new C bindings for its Zig-only search types and
for durable match anchors. That would cross the vendored-library boundary and
change the adapter contract established by ADR 0001.

The public C ABI already exposes enough information for a first version:
visible cells are available through `LabanSnapshot`, and scrollback plus the
active screen can be copied as plain text through libghostty-vt's formatter
while holding the session lock.

## Decision

Laban implements terminal find above the existing `LabanSession` boundary. The
Swift find engine scans `LabanSnapshot` rows for visible refreshes and scans a
caller-owned plain-text scrollback block extracted by
`laban_session_scrollback_extract` for full searches. Match identity is the
current `(row, startColumn, endColumn)` in the terminal generation.

Laban does not modify vendored libghostty-vt and does not bind directly to its
Zig `ScreenSearch`, `Pin`, or highlight-flattening internals for this version.

## Consequences

- The feature remains headless and capture/replay friendly because it uses the
  same snapshots, frame commands, and debug endpoints as the rest of Laban.
- Search is synchronous on the app/model path. Full scrollback scans run on
  explicit find actions: open, needle change, and step. Streaming output
  refreshes only the visible area so verbose output cannot trigger repeated
  full-history scans.
- Matches are positional in the current terminal generation. They are
  recomputed after output and resize instead of being pinned to libghostty page
  serials.
- ASCII smart-case behavior mirrors libghostty-vt's current matcher. Unicode
  case folding, regex, durable pinned anchors, and threaded background search
  remain future work.
- If libghostty-vt later exposes stable C search bindings, Laban can replace
  the implementation behind the Swift `TerminalFind` surface without changing
  AppKit, debug, or renderer contracts.

## Applies To New Code

Before changing terminal find architecture, answer:

1. Does Swift still avoid holding raw libghostty-vt search, page, or pin types?
2. Are buffers crossing the C boundary caller-owned or otherwise protected from
   the background PTY reader thread?
3. Do `findMatch` and `findSelected` frame commands still expose the highlight
   geometry for headless tests?
4. Does streaming output avoid repeated full scrollback scans?
5. If binding libghostty-vt search internals, is the new C ABI documented and
   covered by a follow-up ADR?
