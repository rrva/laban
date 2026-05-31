# Tighten libghostty Capability Responses

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

Terminal programs probe their terminal before enabling behavior. After this
change, Laban responds to the libghostty-vt capability queries that matter for
MVP shells and TUIs, and it avoids claiming primary device features that Laban
does not intentionally support. The observable result is a fixture session that
replies to ENQ, DA1/DA2/DA3, DSR, DECRQM, XTVERSION, XTWINOPS, color-scheme, and
in-band resize probes through `laban_session_drain_response`.

## Progress

- [x] 2026-05-06 Read `docs/product/mvp.md`, `docs/product/spec.md`, the
  libghostty C headers, `Sources/LabanTerminalCore/session.c`, and existing
  capability tests.
- [x] 2026-05-06 Add focused regression tests for missing and misleading capability
  behavior.
- [x] 2026-05-06 Patch `Sources/LabanTerminalCore/session.c` to register the missing
  libghostty effect and narrow DA1 claims.
- [x] 2026-05-06 Run focused terminal-core tests.
- [x] 2026-05-06 Run the package test suite.
- [x] 2026-05-07 Harden terminal-response capture so
  `laban_session_drain_response` only reports capability replies that were
  committed to the PTY, with fixture-mode replies still captured for tests.

## Decision Notes

The DA1 gap is not a request to emulate every historical VT option. Laban now
answers DA1 as VT220 plus ANSI color only (`ESC[?62;22c`). Full DA1 feature
advertising for 132-column mode would imply terminal-driven geometry behavior
that the MVP does not intentionally expose, and OSC-52 clipboard advertising is
also outside the current side-effect boundary.

ENQ is the one missing libghostty capability effect that directly fits the
existing terminal-response bridge. Laban registers it and returns the fixed
answerback string `laban`.

## Context and Orientation

`Sources/LabanTerminalCore/session.c` owns the libghostty-vt terminal handle,
PTY file descriptor, render state, key encoder, mouse encoder, and effect
callbacks. A libghostty "effect" is a callback invoked while parsing terminal
output for escape sequences that need a host response or side effect. Laban
already registers effects for PTY writes, size reports, device attributes,
XTVERSION, color scheme, and title changes. It does not currently register the
ENQ effect (`0x05`), so ENQ receives no answerback bytes.

Device attributes are terminal identity replies. DA1 is `CSI c`, DA2 is
`CSI > c`, and DA3 is `CSI = c`. Laban currently reports DA1 as VT220 plus
132-column support, selective erase, and ANSI color. Upstream libghostty's
default DA1 reports only ANSI color unless clipboard is enabled. The MVP
explicitly defers terminal-initiated side effects such as clipboard writes and
does not install a Laban-specific terminfo entry; capability claims must remain
conservative.

## Plan of Work

Add tests in `Tests/LabanTerminalCoreTests/LabanSessionTests.swift` because that
file already owns fixture-mode terminal capability response coverage. The tests
will assert:

- ENQ writes a bounded Laban answerback response.
- DA1 reports VT220 plus ANSI color only, with no 132-column or clipboard claim.
- DA3 returns a deterministic unit-id response.
- DECRQM and mode-2048 in-band resize responses are captured through the same
  response drain path.

Then update `Sources/LabanTerminalCore/session.c`:

- Add a `GHOSTTY_TERMINAL_OPT_ENQUIRY` callback returning a static string.
- Register that callback during session creation.
- Change `effect_device_attributes` DA1 feature list to ANSI color only.
- Keep DA2, DA3, size, color-scheme, XTVERSION, focus, mouse, bracketed paste,
  and synchronized-output handling as-is.

## Validation and Acceptance

Run from the repository root:

```sh
rtk swift test --filter LabanTerminalCoreTests.LabanSessionTests
rtk swift test
```

Acceptance is:

- Focused terminal-core tests pass: `rtk swift test --filter
  LabanTerminalCoreTests.LabanSessionTests` passed with 47 tests and 0 failures.
- Full package tests pass: `rtk swift test` passed with 347 tests, 2 skipped,
  and 0 failures.
- The new tests fail before the `session.c` change for ENQ and DA1 and pass
  after the change.

## Outcomes & Retrospective

Laban now has explicit test coverage for the libghostty-generated terminal
responses most likely to affect real shells and TUIs during startup or feature
probing. The only implementation change needed was to register ENQ and narrow
DA1's advertised features. Broader historical DA1 features remain unadvertised
until Laban intentionally supports their side effects and geometry semantics.

On 2026-05-07, response capture was tightened to match the actual send path:
PTY-mode capability replies are buffered for `laban_session_drain_response`
only after `write_pty_bytes` succeeds. A regression drives a DA1 query into a
session whose child has exited and verifies the failed PTY response is not
reported as if it had been delivered. Fixture sessions still capture responses
without a PTY so deterministic capability tests keep working.

## Idempotence and Recovery

The code changes are additive or narrowing. Re-running the tests is safe. If
SwiftPM fails because `.external/` is missing in this worktree, create the
documented symlink:

```sh
ln -s /Users/dev/wrk/laban/.external .external
```

Do not fetch a second copy of libghostty-vt into this worktree.
