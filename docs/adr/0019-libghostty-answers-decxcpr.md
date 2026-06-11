# 19. libghostty Answers DECXCPR (Vendored Patch)

Date: 2026-06-11

## Status

Accepted.

This is a local patch to the vendored libghostty-vt pinned by ADR 0004 (Ghostty
`46d54ed6`), carried under the patch regime ADR 0011 established. It does not
change the ADR 0001 boundary (libghostty still owns VT parsing and query
replies); it adds a reply upstream is missing.

## Context

The DEC-private cursor position report DECXCPR — request `CSI ? 6 n`, reply
`CSI ? row ; col R` — is the form modern TUIs prefer for cursor probes, because
the plain DSR reply `CSI row ; col R` is byte-ambiguous with modified
function-key input (`CSI 1 ; <mod> R` is also F3 with modifiers under several
encodings). The terminal-support compatibility spec Laban targets requires the
`?`-marked reply (its conformance test sends `CSI 4;7 H` `CSI ? 6 n` and
expects `CSI ? 4 ; 7 R`).

libghostty-vt parses `CSI ? 6 n` (its DSR dispatcher extracts the `?`
intermediate) but `device_status.zig` has no entry for value 6 with the
question bit, so `reqFromInt(6, true)` returns null and the query is logged and
dropped. Upstream Ghostty has the same gap. The plain `CSI 6 n` form is
answered (used by termenv-style fence probes; see the ordering note in
`osc_host.c`).

A Laban-side scanner (the ADR 0012 pattern) was considered and rejected for
this sequence: a correct CPR reply must reflect cursor state at the exact
stream position of the query (bytes after the query may move the cursor) and
must honor origin mode relative to the scrolling region — both of which the
in-library DSR handler already has, and which a post-chunk scanner would have
to re-derive with worse ordering guarantees.

## Decision

Patch vendored libghostty so DECXCPR is recognized and answered with the
DEC-private marker:

- **The change** lives in three files:
  - `src/terminal/device_status.zig`: add entry
    `.{ .name = "cursor_position_dec", .value = 6, .question = true }`.
  - `src/terminal/stream_terminal.zig` (`deviceStatus`): handle
    `.cursor_position_dec` alongside `.cursor_position` — same origin-mode
    position computation, reply format `\x1B[?{};{}R`.
  - `src/termio/stream_handler.zig`: same addition; this file is not part of
    the `-Demit-lib-vt` build, but its `switch (req)` over the request enum is
    exhaustive, so full-Ghostty builds (and upstreaming) need the arm.
- **Persistence.** Captured as
  `patches/libghostty-vt-0003-decxcpr-cursor-position-report.patch`, applied by
  `scripts/fetch-libghostty-vt` after the pinned clone with a hard failure on
  apply error, per ADR 0011.
- **Rebuild.** `zig build -Demit-lib-vt -Doptimize=ReleaseFast` in
  `.external/libghostty-vt`.
- **Regression.** `LabanSessionTests.testDECXCPRRepliesWithDECPrivateMarker`
  feeds `CSI 4;7 H` + `CSI ? 6 n` to a fixture session and asserts the drained
  reply is exactly `\x1b[?4;7R`, and that plain `CSI 6 n` still replies
  unmarked. Red/green verified: with the patch reverse-applied and the library
  rebuilt, the test fails (empty reply for `?6n`); re-applied, it passes.

## Consequences

- Apps probing with `CSI ? 6 n` (spec conformance test 23) get the unambiguous
  `?`-marked report; the plain form is unchanged, so existing fence probes
  (`OSC 11;?` + `CSI 6 n`) keep their reply order and format.
- Should be upstreamed to `ghostty-org/ghostty`; when the pin advances past an
  upstream fix, drop the patch and the script step (the hard-fail apply will
  surface the drift).
- Same operational caveat as ADR 0011: after rebuilding the `.a`, SwiftPM does
  not track it as a build input — force a relink (touch a file in
  `LabanTerminalCore` or clean the build dir) before trusting test results.

## Applies To New Code

Follow ADR 0011's patch regime for any further vendored changes. When adding a
query reply, prefer extending libghostty's own dispatcher when the reply
depends on parser-time state (cursor, modes); reserve the ADR 0012 scanner for
sequences whose answers come from Laban-side state (theme colors, clipboard,
notifications).
