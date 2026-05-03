# Scaffold SwiftPM And Prove The libghostty Boundary

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds. This
is the first execution shard for the broader plan in
`execplans/active/swiftpm-appkit-software-renderer-mvp.md`.

## Purpose / Big Picture

This shard turns the repository from documentation-only into a buildable
SwiftPM project with the correct target boundaries. After this shard is
complete, a developer can run `swift build`, run a Swift test that calls a C
function through `LabanTerminalCore`, inspect a pinned libghostty source/probe
record, and create a local developer `.app` bundle containing a minimal AppKit
executable.

This shard does not implement a working terminal, a PTY-backed shell, a
software renderer, debug endpoints, tabs, fixtures, or E2E tests. It exists to
prove the build shape before deeper terminal behavior is written.

## Progress

- [x] Read `AGENTS.md`, `PLANS.md`, `README.md`, `docs/product/mvp.md`,
  `docs/process/dev-process.md`,
  `docs/process/worktree-isolation.md`,
  `docs/reference/prototype-implementation-notes.md`,
  `execplans/completed/choose-implementation.md`, and
  `execplans/active/swiftpm-appkit-software-renderer-mvp.md`.
- [x] Create this focused first execution shard.
- [ ] Add `Package.swift` with the target graph selected by the completed stack
  decision.
- [ ] Add minimal source files for `LabanTerminalCore`, `LabanCore`,
  `LabanRenderer`, `LabanDebug`, `LabanApp`, and `LabanAgent`.
- [ ] Add a C smoke function in `LabanTerminalCore` and a Swift test proving
  Swift can call it.
- [ ] Pin libghostty or add a repeatable fetch/probe script with an exact
  commit or release identifier.
- [ ] Inspect the pinned libghostty source and record the exact C API headers,
  symbols, and link/build implications in this plan.
- [ ] Add `scripts/build-app` that creates `.build/laban/Laban.app` from the
  SwiftPM-built `LabanApp` executable.
- [ ] Add or update stable scripts needed for this shard, including
  `scripts/test` and `scripts/check`.
- [ ] Run validation commands and update this plan with any discoveries.

## Decision Log

- Decision: This shard may use placeholder Swift libraries and a minimal
  AppKit window, but it must not fake terminal behavior.
  Rationale: The goal is to prove build, C interop, libghostty availability,
  and local bundling. Fake VT parsing or fake terminal snapshots would create
  confidence in the wrong boundary.
  Date/Author: 2026-05-03 / Codex.

- Decision: The first `.app` bundle is developer-only and unsigned.
  Rationale: The user explicitly deferred signing, packaging, and Xcode polish.
  SwiftPM plus a small bundle script is enough to prove that AppKit can launch
  locally.
  Date/Author: 2026-05-03 / Codex.

## Context and Orientation

The repository currently has no `Package.swift` and no `Sources/` or `Tests/`
implementation tree. `README.md` documents the chosen direction: SwiftPM,
AppKit, C `LabanTerminalCore` wrapping libghostty and PTY ownership, a
software renderer first, local debug/headless infrastructure later, and a
developer `.app` only.

The completed selection decision is in
`execplans/completed/choose-implementation.md`. The broader implementation
plan is in `execplans/active/swiftpm-appkit-software-renderer-mvp.md`. This
shard implements only that broader plan's first build-scaffold step.

Terms used here:

- SwiftPM means Swift Package Manager. It reads `Package.swift` and builds
  targets under `Sources/` and tests under `Tests/`.
- AppKit means Apple's native macOS UI framework. This shard uses it only for a
  minimal local executable so bundling can be tested.
- `LabanTerminalCore` is the C target that will eventually own libghostty, the
  PTY, child process, resize, title, terminal state, and snapshots. In this
  shard it only exposes a smoke function and records how libghostty will be
  called.
- libghostty is the Ghostty terminal engine. It is mandatory for real terminal
  behavior. This shard must pin and inspect it, not replace it.
- A local `.app` bundle is a macOS directory with `Contents/Info.plist` and a
  `Contents/MacOS/` executable. This shard creates it under `.build/laban/`.

## Plan of Work

### 1. Add SwiftPM Target Boundaries

Create `Package.swift` at the repo root. Use macOS as the platform and define
these targets:

- C target: `LabanTerminalCore`
- Swift libraries: `LabanCore`, `LabanRenderer`, `LabanDebug`
- Executables: `LabanApp`, `LabanAgent`
- Test targets: `LabanTerminalCoreTests`, `LabanCoreTests`,
  `LabanRendererTests`, `LabanDebugTests`

Expose products:

```swift
.library(name: "LabanCore", targets: ["LabanCore"])
.library(name: "LabanRenderer", targets: ["LabanRenderer"])
.library(name: "LabanDebug", targets: ["LabanDebug"])
.executable(name: "LabanApp", targets: ["LabanApp"])
.executable(name: "laban-agent", targets: ["LabanAgent"])
```

Target dependencies for this shard:

```text
LabanTerminalCore
LabanRenderer
LabanCore -> LabanTerminalCore, LabanRenderer
LabanDebug -> LabanCore, LabanRenderer
LabanApp -> LabanCore, LabanRenderer, LabanDebug
LabanAgent -> LabanCore, LabanRenderer, LabanDebug
```

Do not add Metal dependencies. Do not add third-party Swift HTTP or rendering
libraries in this shard.

### 2. Add Minimal Sources

Create these files:

```text
Sources/LabanTerminalCore/include/LabanTerminalCore.h
Sources/LabanTerminalCore/session_smoke.c
Sources/LabanCore/LabanCore.swift
Sources/LabanRenderer/LabanRenderer.swift
Sources/LabanDebug/LabanDebug.swift
Sources/LabanApp/main.swift
Sources/LabanAgent/main.swift
Tests/LabanTerminalCoreTests/LabanTerminalCoreSmokeTests.swift
Tests/LabanCoreTests/LabanCoreSmokeTests.swift
Tests/LabanRendererTests/LabanRendererSmokeTests.swift
Tests/LabanDebugTests/LabanDebugSmokeTests.swift
```

`LabanTerminalCore.h` should expose a tiny smoke API:

```c
#ifndef LABAN_TERMINAL_CORE_H
#define LABAN_TERMINAL_CORE_H

const char *laban_terminal_core_smoke_version(void);

#endif
```

`session_smoke.c` should return a stable string such as
`"laban-terminal-core-smoke"`. This is only a C interop proof, not terminal
behavior.

`LabanApp/main.swift` should create the smallest AppKit process that can be
launched from a bundle. A one-window app with a plain title is sufficient.
Avoid preferences, tabs, custom rendering, and debug server code here.

`LabanAgent/main.swift` should parse no real options yet. It can print a short
placeholder line and exit 0, or start a placeholder run loop only if needed by
SwiftPM. Do not claim headless mode exists until the broader plan implements
it.

### 3. Pin And Probe libghostty

Before writing the real C bridge, pin libghostty in a repeatable way. The
preferred options are, in order:

1. Add a git submodule under `External/libghostty` pinned to an exact commit.
2. Add `scripts/fetch-libghostty` that clones a specific commit into
   `.external/libghostty`.
3. If neither is workable in this shard, add a checked-in
   `docs/reference/libghostty-pin.md` that records the exact repository URL,
   commit or release, why fetching/building is blocked, and what command should
   be used next.

After the source is present or the block is recorded, inspect the headers and
update this plan with a new section named `libghostty Probe Results` containing
at least:

- source URL
- pinned commit or release
- local source path
- header path or paths relevant to the C API
- initialization symbols found
- render-state or snapshot symbols found
- key encoder symbols found
- mouse encoder symbols found
- current link/build command or the exact reason it is still unknown

If libghostty cannot be fetched or built, do not replace it with a fake
terminal parser. Keep the C smoke target, record the block, and leave the real
terminal bridge for the next shard after the dependency is resolved.

### 4. Add Local App Bundling

Add `scripts/build-app`. It should:

1. Run `swift build --product LabanApp`.
2. Create `.build/laban/Laban.app/Contents/MacOS`.
3. Copy or symlink the built `LabanApp` executable to
   `.build/laban/Laban.app/Contents/MacOS/LabanApp`.
4. Write `.build/laban/Laban.app/Contents/Info.plist` with the minimum keys
   needed for a local developer app: bundle identifier, executable name,
   bundle name, package type `APPL`, and a macOS minimum system version.

The script must be idempotent: rerunning it replaces the generated bundle
contents under `.build/laban/` without touching source files.

### 5. Wire Local Checks

Add `scripts/test` as a small wrapper around `swift test`.

Update `scripts/check` to keep its existing behavior and also run the new
SwiftPM checks for this shard once `Package.swift` exists:

```sh
swift build
swift test
./scripts/build-app
```

Keep JSON validation, `AGENTS.md` size enforcement, active ExecPlan section
checks, and `git diff --check`.

## Concrete Steps

From the repo root:

```sh
cd /Users/rrj/wrk/laban
./scripts/check
```

Create the SwiftPM files and smoke tests described above, then run:

```sh
swift build
swift test
./scripts/build-app
test -x .build/laban/Laban.app/Contents/MacOS/LabanApp
```

After wiring scripts:

```sh
./scripts/test
./scripts/check
```

If using a libghostty fetch script, run it from the repo root and keep fetched
source out of the repository unless the chosen mechanism is an intentional
submodule:

```sh
./scripts/fetch-libghostty
```

## Validation and Acceptance

This shard is complete when:

- `Package.swift` exists and defines all targets and products named in this
  plan.
- `swift build` exits 0.
- `swift test` exits 0.
- `Tests/LabanTerminalCoreTests` contains a test that calls
  `laban_terminal_core_smoke_version()` through the Swift-imported C module.
- libghostty is pinned by submodule, repeatable fetch script, or documented
  block, and this plan contains `libghostty Probe Results`.
- `./scripts/build-app` creates
  `.build/laban/Laban.app/Contents/MacOS/LabanApp`.
- The generated app executable is executable.
- `./scripts/test` exits 0.
- `./scripts/check` exits 0.
- No Metal, renderer, debug server, PTY lifecycle, or fake terminal behavior is
  introduced in this shard.

## Idempotence and Recovery

Generated build output belongs under `.build/`. If using a fetch script, fetched
libghostty source belongs under `.external/` unless a submodule is intentionally
added under `External/`. Do not commit `.build/`, `.external/`, or generated
`.app` contents.

If SwiftPM fails because the local macOS toolchain is missing or too old, add a
`Surprises & Discoveries` entry with the exact `swift --version` and failure
before changing target structure.

If libghostty fetching fails because of network or upstream build issues,
record the failing command and output summary under `libghostty Probe Results`.
The shard may still land the SwiftPM skeleton and C smoke test, but it is not
complete until the pin/probe status is explicit.

## Automated Acceptance Gate

These are mechanical checks for a fresh agent or automation runner:

- [ ] Run `./scripts/check`; expect exit 0.
- [ ] Run `swift test`; expect exit 0.
- [ ] Run `./scripts/build-app`; expect
  `.build/laban/Laban.app/Contents/MacOS/LabanApp` to exist and be executable.
- [ ] Run `rg -n "MetalKit|\\bMTL" Package.swift Sources Tests`; expect zero
  matches.
- [ ] Run `rg -n "VT|ANSI parser|escape parser" Sources`; expect zero matches
  unless the match is in a comment explaining that parsing belongs to
  libghostty.
- [ ] Confirm this plan has a `libghostty Probe Results` section with source
  URL, pin, local path, headers, discovered symbols, and link/build status.

## Surprises & Discoveries

- Observation: This shard is deliberately narrower than the umbrella MVP plan.
  Evidence: It stops at SwiftPM targets, C interop smoke testing, libghostty
  pin/probe, local `.app` bundling, and script integration.
