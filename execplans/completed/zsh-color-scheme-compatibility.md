# Zsh Color Scheme Compatibility

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

Users report that zsh color schemes do not work in Laban. After this
investigation, zsh prompt/theme color output should either render correctly or
have a specific, reproducible cause recorded with tests. The visible behavior
to protect is simple: zsh-generated SGR color sequences such as `%F{red}`,
`%F{#00ff00}`, `%F{46}`, `%K{blue}`, and `%K{#112233}` should produce
non-default foreground/background colors in Laban snapshots and frame commands.

## Progress

- [x] Read `docs/product/mvp.md`, `docs/product/spec.md`, and prototype notes
  for the color and shell-environment contract.
- [x] Verified the current launch environment strips inherited `NO_COLOR` and
  supplies `TERM=xterm-256color` plus `COLORTERM=truecolor`.
- [x] Confirmed local zsh expands common prompt color forms to standard SGR:
  ANSI 16-color (`31`/`44`), truecolor (`38;2`/`48;2`), palette index
  (`38;5`), and inverse/standout (`7`/`27`).
- [x] Add focused regression tests for zsh-style SGR foreground/background
  colors through Laban's snapshot and frame-command pipeline.
- [x] Added a real `/bin/zsh` PTY regression showing zsh-generated truecolor,
  256-color, and background colors reach snapshots with the expected RGB.
- [x] Added an OSC 4 `rgb:RR/GG/BB` regression for zsh/base16-style terminal
  palette scripts.
- [x] Identified and fixed the startup ordering bug: the first terminal session
  was created before the initial system-appearance theme was applied, allowing
  Laban's late initial theme notification to overwrite shell-provided palette
  changes shortly after zsh startup.
- [x] Run targeted tests and the repository check gate.

## Decision Log

- Decision: Treat "zsh color schemes" as zsh-generated terminal color escape
  output first, not as a request to add user-configurable Laban themes.
  Rationale: The MVP explicitly fixes Laban's UI theme to Selenized Light but
  requires colored CLI output, 256-color, and truecolor rendering. A user's zsh
  theme controls shell output, not Laban chrome.
  Date/Author: 2026-05-08 / Codex
- Decision: Apply the initial AppKit appearance theme before constructing the
  first `AppModel`/PTY session and observe only later appearance changes with
  KVO.
  Rationale: zsh color-scheme scripts frequently change the terminal palette
  during startup via OSC 4/10/11. The previous launch order created the shell
  session first, then delivered the appearance observer's `.initial` theme
  notification, which could re-inject Laban's palette after zsh had set its
  own. Priming `Theme.current` first preserves the intended initial Laban
  theme without a post-startup palette clobber.
  Date/Author: 2026-05-08 / Codex

## Context and Orientation

`Sources/LabanTerminalCore/session.c` launches the user's shell under a PTY and
builds the child environment in `build_spawn_env`. It removes inherited `TERM`,
`COLORTERM`, and `NO_COLOR`, then adds `TERM=xterm-256color` and
`COLORTERM=truecolor` unless explicit launch overrides are supplied. It also
converts libghostty render-state cells into `LabanSnapshot` colors.

`Sources/LabanCore/FrameProducer.swift` converts `LabanSnapshot` cells into
renderer `FrameCommand.glyphRun` and `.rect` commands. Tests in
`Tests/LabanCoreTests/FrameProducerTests.swift` already cover truecolor output
and inverse video, but they do not currently pin zsh's common ANSI 16-color and
256-color forms.

`Tests/LabanTerminalCoreTests/LabanSessionTests.swift` includes PTY launch and
environment tests. It verifies explicit overrides can set `NO_COLOR`, but does
not yet verify the default launch clears inherited `NO_COLOR` without explicit
opt-in.

`Sources/LabanApp/AppDelegate.swift` previously installed the system appearance
observer with `.initial` after `MainWindowController.makeAndShow()` had already
created the first terminal session. That ordering could overwrite OSC palette
changes emitted by shell startup files.

## Outcomes & Retrospective

The parser, snapshot, and frame-command pipeline already handled the common
zsh SGR color forms correctly. Real `/bin/zsh` under Laban's PTY environment
also emitted and rendered truecolor, 256-color, and background colors
correctly. The actionable bug was an app startup race: Laban could apply its
initial system-appearance theme after zsh startup scripts had changed the
terminal palette. The fix primes `Theme.current` before the first terminal
session is created and reserves the appearance observer for later live changes.

## Plan of Work

First add focused tests that feed the same SGR sequences zsh emits for common
prompt-theme color forms into a fixture session, then assert the resulting
frame commands carry non-default foreground/background colors. Include both
ANSI 16-color and 256-color forms because zsh's `%F{red}` and `%F{46}` emit
those forms. Keep truecolor coverage if the existing tests are insufficient for
background color.

If those render tests pass, add an environment-focused PTY test proving default
interactive launches remove inherited color-suppression variables that zsh
themes and CLI tools often honor. Then fix the app launch ordering so the
initial Laban theme is applied before shell startup instead of through a late
initial KVO callback.

## Validation and Acceptance

Run these commands from `/Users/dev/wrk/laban`:

```sh
rtk swift test --filter FrameProducerTests
rtk swift test --filter AppDelegateThemeTests
rtk swift test --filter StyleAttributePlumbingTests
rtk swift test --filter LabanSessionTests/testPTYSpawnEnvironment
rtk swift test --filter LabanSessionTests/testPTYZshPromptColorSequencesReachSnapshot
rtk ./scripts/check
```

Acceptance: zsh-style ANSI 16-color, 256-color, and truecolor SGR output is
visible in frame commands with non-default colors; default shell launches do
not inherit color suppression unless explicitly overridden; shell OSC palette
scripts are not clobbered by an initial app theme notification; and the full
check passes or any unrelated baseline failure is recorded with evidence.

## Artifacts and Notes

Local zsh expansion observed on 2026-05-08:

```text
%F{red}       -> ESC [ 31 m ... ESC [ 39 m
%F{#00ff00}   -> ESC [ 38 ; 2 ; 0 ; 255 ; 0 m ... ESC [ 39 m
%F{46}        -> ESC [ 38 ; 5 ; 46 m ... ESC [ 39 m
%K{blue}      -> ESC [ 44 m ... ESC [ 49 m
%K{#112233}   -> ESC [ 48 ; 2 ; 17 ; 34 ; 51 m ... ESC [ 49 m
%S/%s         -> ESC [ 7 m ... ESC [ 27 m
```

Validation run on 2026-05-08:

```text
rtk swift test --filter FrameProducerTests/testZshPaletteSchemeOsc4RgbFormAffectsAnsiColors
rtk swift test --filter AppDelegateThemeTests
rtk swift test --filter LabanSessionTests/testPTYSpawnEnvironmentStripsInheritedColorSuppression
rtk swift test --filter LabanSessionTests/testPTYSpawnEnvironmentAppliesDefaultsAndOverrides
rtk swift test --filter LabanSessionTests/testPTYZshPromptColorSequencesReachSnapshot
rtk swift test --filter FrameProducerTests
rtk swift test --filter StyleAttributePlumbingTests
rtk swift test --filter LabanSessionTests/testPTYSpawnEnvironment
rtk ./scripts/check
```
