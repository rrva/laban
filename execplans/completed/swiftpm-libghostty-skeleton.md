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
- [x] Add `Package.swift` with the target graph selected by the completed stack
  decision.
- [x] Add minimal source files for `LabanTerminalCore`, `LabanCore`,
  `LabanRenderer`, `LabanDebug`, `LabanApp`, and `LabanAgent`.
- [x] Add a C smoke function in `LabanTerminalCore` and a Swift test proving
  Swift can call it.
- [x] Pin libghostty or add a repeatable fetch/probe script with an exact
  commit or release identifier.
- [x] Inspect the pinned libghostty source and record the exact C API headers,
  symbols, and link/build implications in this plan.
- [x] Add `scripts/build-app` that creates `.build/laban/Laban.app` from the
  SwiftPM-built `LabanApp` executable.
- [x] Add or update stable scripts needed for this shard, including
  `scripts/test` and `scripts/check`.
- [x] Run validation commands and update this plan with any discoveries.
- [x] Add `scripts/smoke-runtime` with checks for agent placeholder output, plist
  validity, app executable bit, and AppKit smoke startup via `LABAN_SMOKE=1`.
- [x] Add `--smoke`/`LABAN_SMOKE=1` exit path to `Sources/LabanApp/main.swift`
  so the app initializes AppKit, prints nothing to stdout, and exits 0.
- [x] Wire `scripts/check` to call `scripts/smoke-runtime` after
  `scripts/build-app`.
- [x] Run `./scripts/smoke-runtime` and `./scripts/check`; both exit 0.

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
./scripts/smoke-runtime
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
- `./scripts/smoke-runtime` exits 0 with message `smoke-runtime passed`.
- `LABAN_SMOKE=1 .build/laban/Laban.app/Contents/MacOS/LabanApp` exits 0
  without opening a persistent window.
- `.build/debug/laban-agent` prints exactly
  `laban-agent: placeholder, headless mode not yet implemented`.
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

## libghostty Probe Results

- **Source URL:** https://github.com/ghostty-org/ghostty
- **Pinned tag:** v1.3.1 (annotated tag object
  `22efb0be2bbea73e5339f5426fa3b20edabcaa11`; tree commit
  `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`)
- **Local source path:** `.external/libghostty` (fetched by
  `scripts/fetch-libghostty`, not committed)
- **Header path:** `.external/libghostty/include/ghostty.h` (1178 lines)
- **Module map:** `.external/libghostty/include/module.modulemap` (defines
  module `GhosttyKit` with umbrella header `ghostty.h`)

### Initialization symbols

```c
int ghostty_init(uintptr_t argc, char** argv);  // global init, call first
ghostty_config_t ghostty_config_new();
void ghostty_config_finalize(ghostty_config_t);
ghostty_app_t ghostty_app_new(const ghostty_runtime_config_s*, ghostty_config_t);
ghostty_surface_t ghostty_surface_new(ghostty_app_t, ghostty_surface_config_s*);
```

`ghostty_surface_config_s` carries a `ghostty_platform_macos_s` containing
`void* nsview`. A live NSView must be passed to create a surface. There is no
headless-only surface constructor in this release.

### Render and state symbols

```c
void ghostty_surface_draw(ghostty_surface_t);
void ghostty_surface_refresh(ghostty_surface_t);
void ghostty_app_tick(ghostty_app_t);
ghostty_surface_size_s ghostty_surface_size(ghostty_surface_t);
bool ghostty_surface_process_exited(ghostty_surface_t);   // new in v1.3.x
bool ghostty_surface_has_selection(ghostty_surface_t);
bool ghostty_surface_read_selection(ghostty_surface_t, ghostty_text_s*);
bool ghostty_surface_read_text(ghostty_surface_t, ...);
void ghostty_surface_free_text(ghostty_surface_t, ghostty_text_s*);
```

There is no explicit snapshot or software-render export in this API version.
Rendering is driven by Metal internally through the NSView. The software
renderer required for headless tests will need to be built separately.

### Key encoder symbols

```c
bool ghostty_surface_key(ghostty_surface_t, ghostty_input_key_s);
bool ghostty_surface_key_is_binding(ghostty_surface_t, ghostty_input_key_s, ...);
void ghostty_surface_text(ghostty_surface_t, const char*, uintptr_t);
void ghostty_surface_preedit(ghostty_surface_t, const char*, uintptr_t);  // IME
ghostty_input_mods_e ghostty_surface_key_translation_mods(ghostty_surface_t,
                                                          ghostty_input_mods_e);
bool ghostty_app_key(ghostty_app_t, ghostty_input_key_s);
```

`ghostty_input_key_s` carries action, mods, keycode (uint32), text (const
char*), and composing (bool).

### Mouse encoder symbols

```c
bool ghostty_surface_mouse_captured(ghostty_surface_t);
bool ghostty_surface_mouse_button(ghostty_surface_t,
                                  ghostty_input_mouse_state_e,
                                  ghostty_input_mouse_button_e,
                                  ghostty_input_mods_e);
void ghostty_surface_mouse_pos(ghostty_surface_t, double, double,
                               ghostty_input_mods_e);
void ghostty_surface_mouse_scroll(ghostty_surface_t, double, double,
                                  ghostty_input_scroll_mods_t);
void ghostty_surface_mouse_pressure(ghostty_surface_t, uint32_t, double);
```

### Link and build status

Zig 0.15.2 is installed. Ghostty v1.3.1's `build.zig` requires Zig ≥ 0.13.0.

On macOS, `zig build -Dapp-runtime=none -Demit-xcframework=true` (run inside
`.external/libghostty`) produces an xcframework, not a plain `.a`. The
xcframework contains a static library and the header. This is the form that
Ghostty's own macOS Xcode project links against.

A plain `libghostty.a` for macOS is not produced by the upstream build; the
non-Darwin path produces `.so` and `.a` but is not the macOS path. Linking
`LabanTerminalCore` against libghostty on macOS will require consuming the
xcframework output or adjusting the build step.

Full build was not attempted in this shard. Fetching all Zig dependencies and
compiling requires network access and significant build time. Build integration
is deferred to the next shard.

## Automated Acceptance Gate

These are mechanical checks for a fresh agent or automation runner:

- [x] Run `./scripts/check`; expect exit 0.
- [x] Run `swift test`; expect exit 0.
- [x] Run `./scripts/build-app`; expect
  `.build/laban/Laban.app/Contents/MacOS/LabanApp` to exist and be executable.
- [x] Run `rg -n "MetalKit|\\bMTL" Package.swift Sources Tests`; expect zero
  matches.
- [x] Run `rg -n "VT|ANSI parser|escape parser" Sources`; expect zero matches
  unless the match is in a comment explaining that parsing belongs to
  libghostty.
- [x] Confirm this plan has a `libghostty Probe Results` section with source
  URL, pin, local path, headers, discovered symbols, and link/build status.
- [x] Run `./scripts/smoke-runtime`; expect exit 0 and `smoke-runtime passed`.

## Surprises & Discoveries

- Observation: This shard is deliberately narrower than the umbrella MVP plan.
  Evidence: It stops at SwiftPM targets, C interop smoke testing, libghostty
  pin/probe, local `.app` bundling, and script integration.

- Discovery: On macOS, libghostty builds as an xcframework, not a plain static
  lib. The xcframework is the form Ghostty's Xcode project links against.
  Evidence: `build.zig` lines 51–76. The `libghostty.a` path in the same file is
  the non-Darwin branch.

- Discovery: `ghostty_surface_new` requires a live NSView pointer. There is no
  headless or off-screen surface constructor in the v1.3.1 C API. The software
  renderer for autonomous tests must be implemented separately from ghostty's
  internal Metal renderer.

- Discovery: Ghostty's module map defines the module as `GhosttyKit` (not
  `ghostty`). Import in Swift: `import GhosttyKit`.

- Discovery: `ghostty_init` signature changed between v1.1.0 and v1.3.1. In
  v1.3.1 it takes `(uintptr_t argc, char** argv)` rather than `void`. The
  runtime callbacks struct also changed: `ghostty_runtime_read_clipboard_cb`
  now returns `bool` instead of `void`.

- Discovery: The `.app` bundle must carry an ad-hoc `codesign` signature before
  `LABAN_SMOKE=1` can execute it on Apple Silicon. `cp` into the bundle strips
  the code signature from the SwiftPM-built binary; running an unsigned bundle
  from the command line fails with a `Killed: 9` on Apple Silicon with SIP
  active. Fix: `codesign --force --sign - .build/laban/Laban.app` added to the
  end of `scripts/build-app`.

- Discovery: `NSApplication.shared.setActivationPolicy(.prohibited)` must be
  called before `app.run()` in smoke mode. Without it, the smoke startup causes
  a Dock icon to appear and the app enters the app-switcher, which is unexpected
  during automated checks. `.prohibited` prevents both.
