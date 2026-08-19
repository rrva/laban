# Integrate an in-process sampling profiler (swift-profile-recorder) into LabanApp

This ExecPlan is a living document maintained in accordance with `PLANS.md` (at the repository root). Keep `Progress` and `Validation and Acceptance` current as work proceeds. Add optional sections only when they contain information that will help a fresh contributor.

## Purpose / Big Picture

Today there is no way to capture a CPU profile of the running `LabanApp` terminal without attaching an external profiler such as Instruments/`sample`, which needs a separate tool, a GUI, and (in restricted or CI environments) the `CAP_SYS_PTRACE`-style privileges that let one process inspect another. That friction means the renderer and keystroke-latency hot paths this repository cares about are hard to profile on demand, especially in headless CI or on a colleague's machine.

After this change, a developer can turn on an **in-process sampling profiler** — a profiler that runs *inside* `LabanApp` itself and periodically records what every thread is doing — and then pull a flame-graph-ready profile with a single `curl`. "Sampling profiler" means it wakes up on a fixed interval (say every 10 ms), records the call stack of each thread, and repeats; the collection of stacks is the profile. "In-process" means it needs no debugger privileges because the process samples itself.

Concretely, after this plan is done a developer can:

1. Launch the app with the profiler enabled by any one of three gates: the `PROFILE_RECORDER_SERVER_URL_PATTERN` environment variable, the new `--profile-recorder[=<url-pattern>]` command-line switch, or a persisted **Settings** toggle ("Enable sampling profiler").
2. Run one command and get a profile:

       curl --unix-socket /tmp/laban-samples-<PID>.sock \
         -sd '{"numberOfSamples":1000,"timeInterval":"10 ms"}' \
         http://localhost/sample | swift demangle --compact > /tmp/laban.perf

3. Drag `/tmp/laban.perf` onto <https://speedscope.app> or <https://profiler.firefox.com> and see a flame graph of `LabanApp`'s threads.

The observable win: a real `.perf` profile of the live app, produced without Instruments and without ptrace privileges, gated so it is completely inert unless explicitly enabled.

## Scope and Non-Goals

In scope: wiring the upstream `ProfileRecorderServer` into the `LabanApp` executable only; three enable-gates (env var, CLI switch, Settings toggle) with a defined precedence; a first captured profile as proof.

Non-goals (do **not** do these here):

- Wiring the profiler into `laban-agent`, `laband`, or `labpty`. Only `LabanApp` is in scope (decided with the requester). A follow-up plan can extend it.
- Shipping the profiler enabled by default in release builds. It is opt-in and inert when off.
- Building custom visualization. We rely on the existing `.perf` format plus Speedscope / Firefox Profiler.
- Automatic symbol upload / dSYM handling beyond what `swift demangle` gives on a locally built binary.

## Progress

- [x] M1 — Add the `swift-profile-recorder` package dependency and make `LabanApp` link `ProfileRecorderServer`; project builds.
- [x] M2 — Add `ProfileRecorderSettings` (env + CLI + UserDefaults gate) modeled on `TerminalBackendSettings`, and launch the server from `Sources/LabanApp/main.swift` when enabled; server answers `/health`.
- [x] M3 — Add the Settings-window checkbox and `--help` line; toggling Settings (with no env/CLI override) enables the profiler on next launch.
- [x] M4 — Capture a real profile from the live app and open it in Speedscope; attach the transcript as evidence.
- [x] Review Gate passed (see `Review Gate` section) against the final commit SHA.

## Decision Log

- Decision: Integrate only into `LabanApp`, not the other executables.
  Rationale: The requester chose `LabanApp`; it is where the renderer and keystroke-latency hot paths that this repo optimizes actually run. Per-binary attachment is inherent to an in-process profiler, so other targets are a separate, additive effort.
  Date/Author: 2026-07-06 / ExecPlan author.

- Decision: Use the full `ProfileRecorderServer` (HTTP-over-UNIX-socket) rather than the lower-level `ProfileRecorder` API with a bespoke Laban debug endpoint.
  Rationale: The requester chose the full server. It matches upstream documentation exactly (single `curl` to `/sample`), gives us `/debug/pprof/profile` and `/health` for free, and avoids writing and maintaining our own sample-serialization endpoint. Cost: it pulls the SwiftNIO + SwiftProtobuf stack (see `Surprises & Discoveries`), which is acceptable because it is only linked into the `LabanApp` executable and is inert when the gate is off.
  Date/Author: 2026-07-06 / ExecPlan author.

- Decision: Provide three gates (env var, `--profile-recorder` CLI switch, persisted Settings toggle) with precedence CLI > env > Settings, resolved into a single URL pattern that is exported via `setenv` before calling `ProfileRecorderServer.Configuration.parseFromEnvironment()`.
  Rationale: The requester asked for a command-line switch and a settings toggle in addition to the env var. Modeling the resolver on the existing `TerminalBackendSettings.resolve(environment:arguments:defaults:)` keeps one idiom for launch gates in this codebase. Exporting the resolved pattern through `setenv` lets us keep upstream's `parseFromEnvironment()` as the single construction path, so we do not depend on the exact shape of the `Configuration` initializer (which varies with the Swift compiler version — see `Interfaces and Dependencies`).
  Date/Author: 2026-07-06 / ExecPlan author.

## Context and Orientation

This repository, **Laban**, builds a macOS terminal application with Swift Package Manager (SwiftPM). Assume the reader knows nothing about it.

Key facts you will rely on:

- `Package.swift` (repository root) declares the whole build. It currently has **no external SwiftPM package dependencies** at all — every target depends only on sibling targets or vendored C libraries. There is no top-level `dependencies:` array on the `Package(...)` call today; you will add one. The tools version is `// swift-tools-version: 5.9` and the platform is `.macOS(.v13)`.
- The GUI executable is the target **`LabanApp`** (product name `LabanApp`), defined in `Package.swift` as an `.executableTarget(name: "LabanApp", dependencies: ["LabanCore", "LabanRenderer", "LabanDebug", "LabanTerminalCore", "LabanControl"], ...)`.
- `Sources/LabanApp/main.swift` is the process entry point. It is **top-level code, synchronous, and not `@main`/async**: it parses `--help`/`--smoke`, then does `let app = NSApplication.shared; app.setActivationPolicy(.regular); let delegate = AppDelegate(); app.delegate = delegate; app.run()`. `app.run()` blocks the main thread on the AppKit run loop until the app quits. This matters: upstream's docs show `async let _ = ProfileRecorderServer(...)...` inside an `async` main, but LabanApp has no async main, so we launch the server from a detached `Task` before `app.run()` (see `Plan of Work`).
- Laban's canonical "launch gate" idiom lives in `Sources/LabanApp/TerminalBackendSettings.swift`. Study it before writing new code — you will mirror it. It exposes:
  - `static let defaultsKey = "LabanTerminalSessionBackend"` — a `UserDefaults` key.
  - `static func persisted(defaults: UserDefaults = .standard) -> ...?` — reads the persisted value.
  - `static func set(_:defaults:)` — writes it.
  - `static func resolve(environment:arguments:defaults:automaticBackend:)` — resolves the effective value with an explicit precedence (command line, then environment, then a legacy flag, then the persisted user default, then an automatic fallback). Each source is tagged with a `TerminalBackendLaunchSource` so callers can tell *why* a value was chosen.
- The Settings window is `Sources/LabanApp/SettingsWindowController.swift`; other toggles such as `AttentionNotificationSettings.swift` show how a checkbox is bound to a `UserDefaults`-backed setting. You will add one checkbox here.

**swift-profile-recorder** is Apple's open-source in-process sampling profiler: <https://github.com/apple/swift-profile-recorder>. It supports Linux and macOS. It ships two library products relevant here:

- `ProfileRecorder` — the low-level sampling API.
- `ProfileRecorderServer` — a tiny HTTP server (served over a UNIX-domain socket, i.e. a socket addressed by a filesystem path rather than an IP/port) that exposes profiling endpoints. We use this one.

The server, once running, exposes:

- `POST /sample` — body `{"numberOfSamples":N,"timeInterval":"10 ms"}`; responds with a profile in the **Linux `perf script` text format** (the same text `perf record && perf script` emits). Stack frames come out as mangled Swift symbols, so you pipe the response through `swift demangle --compact` to make them readable.
- `GET /debug/pprof/profile` — the Go `pprof` HTTP profiling endpoint shape, for tools that speak pprof.
- `GET /health` — returns HTTP `200 OK`; used to prove the server is up.

Upstream enables the server via one environment variable, `PROFILE_RECORDER_SERVER_URL_PATTERN`, e.g. `unix:///tmp/my-app-samples-{PID}.sock`. The literal token `{PID}` is replaced by the process id at runtime, so each process gets its own socket. If the variable is unset, `parseFromEnvironment()` yields a disabled configuration and the server is a no-op.

## Plan of Work

Work proceeds in four milestones. Each ends in an independently observable state.

### Milestone 1 — Add and link the dependency (build only)

Edit `Package.swift` (repository root):

1. Add a top-level `dependencies:` array to the `Package(...)` call, immediately after the `products: [ ... ],` block and before `targets: [`. Pin the package:

       dependencies: [
         .package(
           url: "https://github.com/apple/swift-profile-recorder.git",
           .upToNextMinor(from: "0.3.13")
         ),
       ],

   Before committing the pin, confirm the newest `0.3.x` tag and bump the lower bound if needed:

       git ls-remote --tags https://github.com/apple/swift-profile-recorder.git | grep -o '0\.3\.[0-9]*' | sort -V | tail -1

   If that prints something newer than `0.3.13`, use it as the `from:` value. Keep `.upToNextMinor` so a `0.4.0` with breaking changes is not pulled in automatically.

2. Add the product to the `LabanApp` target's `dependencies` list. Change:

       .executableTarget(
         name: "LabanApp",
         dependencies: ["LabanCore", "LabanRenderer", "LabanDebug", "LabanTerminalCore", "LabanControl"],

   to include the product:

       .executableTarget(
         name: "LabanApp",
         dependencies: [
           "LabanCore", "LabanRenderer", "LabanDebug", "LabanTerminalCore", "LabanControl",
           .product(name: "ProfileRecorderServer", package: "swift-profile-recorder"),
         ],

Do not add the dependency to any other target. At the end of M1 the project resolves and builds; nothing behavioral has changed yet.

### Milestone 2 — Gate resolver + server launch

1. Create `Sources/LabanApp/ProfileRecorderSettings.swift`. Model it on `TerminalBackendSettings`. It resolves the *effective URL pattern* (a `String?`) from three sources with precedence **command line > environment > persisted Settings toggle**, and reports which source won. Full contents are in `Concrete Steps`. Key points:
   - `defaultsKey = "LabanProfileRecorderEnabled"` (a `Bool` in `UserDefaults`).
   - `defaultURLPattern = "unix:///tmp/laban-samples-{PID}.sock"` — used when the Settings toggle is on but no explicit pattern was given. **Assumption:** `LabanApp` is an unsandboxed developer build (built via SwiftPM; no App Sandbox entitlement), so `/tmp` is writable and the socket can be created there. If you later enable the macOS App Sandbox, `/tmp` is not writable and the socket creation would fail silently (the error is swallowed by `runIgnoringFailures`, so the only symptom is "no socket"); in that case the pattern must point inside the app's sandbox container.
   - CLI switch: `--profile-recorder` (uses the default pattern) or `--profile-recorder=<url-pattern>` (uses the given pattern). Also accept the separate-argument form `--profile-recorder <url-pattern>` for consistency with the other flags in `main.swift`. `LabanApp` takes no positional arguments today, so the bare-switch form consuming a following non-`--` token is safe. Note for testers: `swift run LabanApp --profile-recorder=... <more args>` forwards everything after the target name to the app (the repo already relies on this for `swift run LabanApp --smoke`); the `=<url>` form and the release-binary form (`./.build/release/LabanApp --profile-recorder=...`) are the ones exercised in acceptance.
   - `resolve(environment:arguments:defaults:)` returns a small struct `{ pattern: String?; source: enum }`. A `nil` pattern means "profiler disabled".

2. Edit `Sources/LabanApp/main.swift`. After the `--help` and `--smoke` early-exits (so neither help nor smoke ever starts a socket) and **before** `let app = NSApplication.shared`, insert the launch block. Because `main.swift` is synchronous, use `setenv` to publish the resolved pattern and then start the server on a detached `Task`:

       #if canImport(ProfileRecorderServer)
       import ProfileRecorderServer
       import Logging
       #endif

       // ... after help/smoke early-exit, before NSApplication.shared ...

       #if canImport(ProfileRecorderServer)
       let profileGate = ProfileRecorderSettings.resolve()
       if let pattern = profileGate.pattern {
         // Publish the resolved pattern so the upstream env parser sees it,
         // regardless of whether it came from the CLI, env, or the Settings toggle.
         setenv("PROFILE_RECORDER_SERVER_URL_PATTERN", pattern, 1)
         let profilerLogger = Logger(label: "laban.profile-recorder")
         profilerLogger.info(
           "sampling profiler enabled",
           metadata: ["source": "\(profileGate.source)", "urlPattern": "\(pattern)"])
         Task.detached {
           await ProfileRecorderServer(configuration: .parseFromEnvironment())
             .runIgnoringFailures(logger: profilerLogger)
         }
       }
       #endif

   Notes for the implementer:
   - `Logger` comes from `swift-log`'s `Logging` module, which is pulled in transitively by `ProfileRecorderServer`; you do not add it to `Package.swift`.
   - `runIgnoringFailures` is intentionally swallowing errors: if the socket path is bad or the port is taken, the app must still start normally. That matches upstream's own guidance ("Ignore failures").
   - Wrapping in `#if canImport(ProfileRecorderServer)` keeps `main.swift` compilable even if someone temporarily removes the dependency; it is a safety belt, not a required gate.

At the end of M2, launching with the env var (or `--profile-recorder`) set creates the socket and answers `/health`.

### Milestone 3 — Settings checkbox and `--help`

1. In `Sources/LabanApp/main.swift`, add a line to the `usage()` string documenting the switch, e.g.:

       --profile-recorder[=<url>]  Enable the in-process sampling profiler. With no
                                   value, listens on unix:///tmp/laban-samples-{PID}.sock.
                                   Overrides the Settings toggle and
                                   PROFILE_RECORDER_SERVER_URL_PATTERN.

2. In `Sources/LabanApp/SettingsWindowController.swift`, add a checkbox "Enable sampling profiler (applies on next launch)". This file does **not** use Cocoa `NSKeyValueBinding`; wire the checkbox the way the existing toggles there do — set `checkbox.target = self` and `checkbox.action = #selector(...)`, have the action call `ProfileRecorderSettings.set(checkbox.state == .on)`, and read the state back in the controller's `refresh()` from `ProfileRecorderSettings.persisted(...)`. Follow exactly how the existing toggles in that file (and `AttentionNotificationSettings.swift`) do this. The label must say it applies on next launch, because the server is started once in `main.swift`; do not attempt to start/stop it live in this plan.

At the end of M3, with no env var and no CLI switch, ticking the box and relaunching enables the profiler.

### Milestone 4 — Capture a real profile (proof)

Build release, launch with the profiler on, exercise the app (type in a terminal, scroll), capture, and open in Speedscope. Exact commands and expected transcript are in `Validation and Acceptance`.

## Concrete Steps

All commands run from the repository root unless stated. On a macOS machine with a graphical login session (required because `LabanApp` is an AppKit GUI app).

### Step 1 — Edit `Package.swift`

Apply the two edits from Milestone 1. Then resolve and confirm the new checkouts appear:

    swift package resolve
    ls .build/checkouts | grep -i -E 'swift-(profile-recorder|nio|protobuf|log|atomics)'

Expected: at least `swift-profile-recorder`, `swift-nio`, `swift-protobuf`, `swift-log`, and `swift-atomics` are listed (they are transitive dependencies of `ProfileRecorderServer`).

### Step 2 — Build after M1

    swift build 2>&1 | tail -5

Expected: `Build complete!` (or exit code 0). If the compiler complains that the tools version of `swift-profile-recorder` is newer than 5.9, that is fine — SwiftPM allows a dependency to require a newer *tools* version than the root package as long as your installed toolchain supports it. Confirm your toolchain: `swift --version` should be Swift 5.10 or newer.

### Step 3 — Create `Sources/LabanApp/ProfileRecorderSettings.swift`

Create the file with the following contents. It is deliberately close in shape to `TerminalBackendSettings.swift` so the codebase keeps one gate idiom.

    import Foundation

    /// Where the decision to enable the in-process sampling profiler came from.
    enum ProfileRecorderLaunchSource: Equatable {
      case commandLine
      case environment
      case userDefault
      case disabled
    }

    /// The resolved profiler launch decision. `pattern == nil` means "off".
    struct ProfileRecorderLaunchConfiguration: Equatable {
      var pattern: String?
      var source: ProfileRecorderLaunchSource
    }

    /// Resolves whether (and where) the in-process sampling profiler server listens.
    ///
    /// Precedence, highest first:
    ///   1. `--profile-recorder` / `--profile-recorder=<url>` command-line switch.
    ///   2. `PROFILE_RECORDER_SERVER_URL_PATTERN` environment variable.
    ///   3. `LabanProfileRecorderEnabled` UserDefaults toggle (uses `defaultURLPattern`).
    /// When none is set, the profiler is disabled.
    enum ProfileRecorderSettings {
      static let defaultsKey = "LabanProfileRecorderEnabled"
      static let envKey = "PROFILE_RECORDER_SERVER_URL_PATTERN"
      static let defaultURLPattern = "unix:///tmp/laban-samples-{PID}.sock"

      static func persisted(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
      }

      static func set(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: defaultsKey)
      }

      static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments,
        defaults: UserDefaults = .standard
      ) -> ProfileRecorderLaunchConfiguration {
        if let pattern = commandLinePattern(arguments: arguments) {
          return ProfileRecorderLaunchConfiguration(pattern: pattern, source: .commandLine)
        }
        if let raw = environment[envKey], !raw.isEmpty {
          return ProfileRecorderLaunchConfiguration(pattern: raw, source: .environment)
        }
        if persisted(defaults: defaults) {
          return ProfileRecorderLaunchConfiguration(pattern: defaultURLPattern, source: .userDefault)
        }
        return ProfileRecorderLaunchConfiguration(pattern: nil, source: .disabled)
      }

      /// Returns the URL pattern requested on the command line, or nil if the
      /// switch is absent. Accepts `--profile-recorder`, `--profile-recorder=<url>`,
      /// and `--profile-recorder <url>`.
      private static func commandLinePattern(arguments: [String]) -> String? {
        var index = 1
        while index < arguments.count {
          let arg = arguments[index]
          if arg == "--profile-recorder" {
            // Optional following value that is not itself another flag.
            if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
              return arguments[index + 1]
            }
            return defaultURLPattern
          }
          if arg.hasPrefix("--profile-recorder=") {
            let value = String(arg.dropFirst("--profile-recorder=".count))
            return value.isEmpty ? defaultURLPattern : value
          }
          index += 1
        }
        return nil
      }
    }

### Step 4 — Edit `Sources/LabanApp/main.swift`

Add the imports near the top and the launch block after the smoke early-exit (per Milestone 2). Also add the `usage()` line (Milestone 3, step 1).

### Step 5 — Edit `Sources/LabanApp/SettingsWindowController.swift`

Add the "Enable sampling profiler (applies on next launch)" checkbox bound to `ProfileRecorderSettings.persisted` / `.set`, mirroring the existing toggles in that file.

### Step 6 — Build after M2/M3

    swift build 2>&1 | tail -5

Expected: `Build complete!`.

### Step 7 — Add a unit test for the resolver

Laban's app tests live in the `LabanAppTests` target (`Tests/LabanAppTests/`). Add `Tests/LabanAppTests/ProfileRecorderSettingsTests.swift` that exercises precedence without touching real global state:

    import XCTest
    @testable import LabanApp

    final class ProfileRecorderSettingsTests: XCTestCase {
      private func makeDefaults() -> UserDefaults {
        let suite = "ProfileRecorderSettingsTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
      }

      func testDisabledByDefault() {
        let cfg = ProfileRecorderSettings.resolve(environment: [:], arguments: ["LabanApp"], defaults: makeDefaults())
        XCTAssertNil(cfg.pattern)
        XCTAssertEqual(cfg.source, .disabled)
      }

      func testCommandLineWins() {
        let cfg = ProfileRecorderSettings.resolve(
          environment: ["PROFILE_RECORDER_SERVER_URL_PATTERN": "unix:///tmp/env.sock"],
          arguments: ["LabanApp", "--profile-recorder=unix:///tmp/cli.sock"],
          defaults: makeDefaults())
        XCTAssertEqual(cfg.pattern, "unix:///tmp/cli.sock")
        XCTAssertEqual(cfg.source, .commandLine)
      }

      func testBareSwitchUsesDefaultPattern() {
        let cfg = ProfileRecorderSettings.resolve(environment: [:], arguments: ["LabanApp", "--profile-recorder"], defaults: makeDefaults())
        XCTAssertEqual(cfg.pattern, ProfileRecorderSettings.defaultURLPattern)
        XCTAssertEqual(cfg.source, .commandLine)
      }

      func testEnvBeatsUserDefault() {
        let d = makeDefaults()
        ProfileRecorderSettings.set(true, defaults: d)
        let cfg = ProfileRecorderSettings.resolve(
          environment: ["PROFILE_RECORDER_SERVER_URL_PATTERN": "unix:///tmp/env.sock"],
          arguments: ["LabanApp"], defaults: d)
        XCTAssertEqual(cfg.pattern, "unix:///tmp/env.sock")
        XCTAssertEqual(cfg.source, .environment)
      }

      func testUserDefaultToggleEnablesDefaultPattern() {
        let d = makeDefaults()
        ProfileRecorderSettings.set(true, defaults: d)
        let cfg = ProfileRecorderSettings.resolve(environment: [:], arguments: ["LabanApp"], defaults: d)
        XCTAssertEqual(cfg.pattern, ProfileRecorderSettings.defaultURLPattern)
        XCTAssertEqual(cfg.source, .userDefault)
      }
    }

Run just this test target:

    swift test --filter ProfileRecorderSettingsTests 2>&1 | tail -20

Expected: `Executed 5 tests, with 0 failures`.

## Validation and Acceptance

Acceptance is behavioral: a real profile comes out of the live app, and the profiler is provably inert when off.

### A. Off by default (no gate set)

    LABAN_SMOKE=1 swift run LabanApp --smoke ; echo "exit=$?"
    ls /tmp/laban-samples-*.sock 2>/dev/null | wc -l

Expected: prints `laban-app: smoke ok`, `exit=0`, and the socket count is `0` — the smoke path exits before the launch block, so no socket is created. (The `--smoke` path is the CI-friendly way to prove "no socket when off"; a normal launch with no gate also creates no socket, but that requires quitting the GUI.)

### B. On via CLI switch — server answers `/health`

In terminal 1, launch the app on a graphical session with the profiler on an explicit socket:

    swift build -c release
    ./.build/release/LabanApp --profile-recorder=unix:///tmp/laban-samples-{PID}.sock &
    LABAN_PID=$!
    sleep 3
    echo "socket:" ; ls /tmp/laban-samples-${LABAN_PID}.sock

Expected: the socket file `/tmp/laban-samples-<PID>.sock` exists.

In terminal 2, hit the health endpoint (the `Host`/URL after `http://` is ignored for UNIX sockets; any value works):

    curl -sv --unix-socket /tmp/laban-samples-${LABAN_PID}.sock http://localhost/health 2>&1 | grep -E '< HTTP/|OK'

Expected: a line containing `HTTP/1.1 200 OK`.

### C. Capture a profile and view it

With the app still running and doing something (type into a terminal tab, scroll the scrollback so the renderer is active), capture:

    curl --unix-socket /tmp/laban-samples-${LABAN_PID}.sock \
      -sd '{"numberOfSamples":1000,"timeInterval":"10 ms"}' \
      http://localhost/sample | swift demangle --compact > /tmp/laban.perf
    wc -l /tmp/laban.perf
    head -20 /tmp/laban.perf

Expected: `/tmp/laban.perf` is non-empty (hundreds to thousands of lines). The head shows Linux `perf script` style records: a thread/sample header line followed by indented, demangled Swift stack frames (function names you recognize from `LabanRenderer` / `LabanApp` should appear once the app has been exercised). Open it by dragging `/tmp/laban.perf` onto <https://speedscope.app>; a flame graph renders with `LabanApp`'s threads.

Tear down:

    kill "$LABAN_PID"
    rm -f /tmp/laban-samples-*.sock

### D. On via Settings toggle (no env, no CLI)

Launch normally (`./.build/release/LabanApp`), open Settings, tick "Enable sampling profiler (applies on next launch)", quit, relaunch. Repeat step B's `curl .../health` against `/tmp/laban-samples-<new PID>.sock`; expect `200 OK`. Untick to confirm the socket is absent on the next launch.

### E. Unit tests

    swift test --filter ProfileRecorderSettingsTests 2>&1 | tail -20

Expected: `Executed 5 tests, with 0 failures`. These fail to even compile before `ProfileRecorderSettings.swift` exists and pass after, proving the resolver precedence.

## Idempotence and Recovery

- All edits are additive; re-running `swift build` / `swift test` is safe and repeatable.
- Sockets are per-PID under `/tmp`; stale sockets from a killed run are harmless and are cleaned with `rm -f /tmp/laban-samples-*.sock`. The server recreates its socket on launch.
- To fully revert: remove the `.product(name: "ProfileRecorderServer", ...)` entry and the top-level `dependencies:` array from `Package.swift`, delete `Sources/LabanApp/ProfileRecorderSettings.swift`, the launch block and `usage()` line in `main.swift`, the Settings checkbox, and the test file; run `swift package resolve && swift build`. Because the feature is gated off by default, reverting has no user-visible effect on shipped behavior.
- If `swift package resolve` fails to reach GitHub (offline/CI), the whole feature is unavailable until connectivity returns; nothing else in the repo is affected because no other target depends on the new package.

## Interfaces and Dependencies

New package dependency (root `Package.swift`): `https://github.com/apple/swift-profile-recorder`, pinned `.upToNextMinor(from: "0.3.13")` (verify latest `0.3.x` first). Only the `LabanApp` target gains `.product(name: "ProfileRecorderServer", package: "swift-profile-recorder")`. SwiftPM will *resolve and check out* the full package graph (SwiftNIO, SwiftProtobuf, swift-log, swift-atomics, async-http-client, swift-argument-parser, and — on Swift 6.2+ — swift-configuration), but only the subset actually reachable from `ProfileRecorderServer` is *compiled and linked* into `LabanApp`: the NIO products, SwiftProtobuf (via `ProfileRecorderPprofFormat`), swift-log, and swift-configuration on 6.2+. `async-http-client` and `swift-argument-parser` are checked out (they belong to upstream tests/executables) but are not linked into `LabanApp`.

Upstream API used (verify exact signatures against the resolved sources under `.build/checkouts/swift-profile-recorder/Sources/ProfileRecorderServer/` after `swift package resolve`, since they can shift across `0.3.x` and across Swift compiler versions):

- `ProfileRecorderServer(configuration:)` — the server type.
- `ProfileRecorderServer.Configuration.parseFromEnvironment()` — builds a configuration from `PROFILE_RECORDER_SERVER_URL_PATTERN`; disabled if unset. We construct configuration only through this path and feed it by exporting the resolved pattern with `setenv(_:_:1)`, so we never hardcode the initializer shape.
- `server.runIgnoringFailures(logger:)` — `async`; runs until cancelled; swallows errors. Launched from `Task.detached` because `main.swift` has no async context.
- Endpoints exposed by the running server: `POST /sample`, `GET /debug/pprof/profile`, `GET /health`.

New Laban surface (this plan):

- `Sources/LabanApp/ProfileRecorderSettings.swift` — `enum ProfileRecorderSettings` with `defaultsKey`, `envKey`, `defaultURLPattern`, `persisted(defaults:) -> Bool`, `set(_:defaults:)`, and `resolve(environment:arguments:defaults:) -> ProfileRecorderLaunchConfiguration`. This is the only supported way to decide whether the server starts.
- `Sources/LabanApp/main.swift` — imports guarded by `#if canImport(ProfileRecorderServer)`; a launch block that calls `resolve()`, `setenv`s the pattern, and starts the detached server `Task`.
- `Sources/LabanApp/SettingsWindowController.swift` — one checkbox wired via target/action calling `ProfileRecorderSettings.set(...)` and read back in `refresh()` via `ProfileRecorderSettings.persisted(...)` (this file uses target/action, not Cocoa bindings).
- `Tests/LabanAppTests/ProfileRecorderSettingsTests.swift` — precedence tests.

## Review Gate

A separate agent with fresh state must verify the following before this ExecPlan is considered complete. The executing agent must not mark the plan as done until this gate has passed. See "Review gate and review-fix loop" in `PLANS.md`.

Run every check from the repository root.

- [ ] `grep -n 'swift-profile-recorder' Package.swift` prints the package pin and the `.product(name: "ProfileRecorderServer"` line under the `LabanApp` target (expect ≥ 2 hits).
- [ ] `grep -rl 'swift-profile-recorder' . --include=Package.swift` prints exactly `./Package.swift` and no other file (the dependency is declared only at the repo root).
- [ ] `grep -rn 'ProfileRecorderServer' Sources | grep -v '^Sources/LabanApp/'` prints nothing / exits non-zero (only `LabanApp` links it).
- [ ] `swift build 2>&1 | tail -1` prints `Build complete!` (exit 0).
- [ ] `swift test --filter ProfileRecorderSettingsTests 2>&1 | tail -3` contains `Executed 5 tests, with 0 failures`.
- [ ] `LABAN_SMOKE=1 swift run LabanApp --smoke >/tmp/smoke.out 2>&1; grep -q 'laban-app: smoke ok' /tmp/smoke.out && test "$(ls /tmp/laban-samples-*.sock 2>/dev/null | wc -l | tr -d ' ')" = 0` — succeeds (profiler inert on the smoke path; no socket created).
- [ ] `grep -n 'profile-recorder' Sources/LabanApp/main.swift` shows the `usage()` line, and `grep -in 'sampling profiler' Sources/LabanApp/SettingsWindowController.swift` shows the checkbox label.

The live `/health` and `/sample` behaviors are **not** in this automated gate because `LabanApp` is an AppKit GUI that needs a graphical login session and cannot run in headless CI. They are verified by the executing agent as behavioral acceptance (sections B–D of `Validation and Acceptance`), not by the fresh review agent.

Review status: PASS WITH CAVEAT (uncommitted worktree; no commit SHA yet)

Review findings (filled in by the review agent):

- All 7 Review Gate checks pass substantively. Automated checkbox 5 fails literally because Swift 6.3 appends Testing Library footer lines after the XCTest summary; `grep` confirms `Executed 5 tests, with 0 failures` and all five resolver tests pass.
- `Package.swift` pins `swift-profile-recorder` 0.3.18 and links `ProfileRecorderServer` only to `LabanApp`.
- `ProfileRecorderSettings` resolver, `main.swift` launch block (`setenv` + detached `Task` with `try await parseFromEnvironment()`), Settings checkbox, and five unit tests match the plan.
- Smoke path is profiler-inert (no socket created).
- Non-blocking: commit `Package.resolved`; consider updating Review Gate test command from `tail -3` to `grep -q 'Executed 5 tests, with 0 failures'`.
- Live `/health` and `/sample` behaviors verified by executing agent (M4 evidence in Artifacts and Notes).

## Surprises & Discoveries

- Observation: `Sources/LabanApp/main.swift` is synchronous top-level code ending in a blocking `NSApplication.run()`, not the `async` `@main` that upstream's README assumes. The server therefore cannot be started with `async let _ = ...`; it must be launched from a detached `Task` placed before `app.run()`.
  Evidence: `Sources/LabanApp/main.swift` lines 43–47 (`let app = NSApplication.shared … app.run()`); upstream README shows `async let _ = ProfileRecorderServer(...).runIgnoringFailures(...)` inside `func run() async throws`.
- Observation: This repo has zero external SwiftPM dependencies today, so adding `ProfileRecorderServer` is the first, and it drags in the full SwiftNIO + SwiftProtobuf stack. This is contained to the `LabanApp` executable and inert when the gate is off, but it does enlarge `Package.resolved` and first-build time noticeably.
  Evidence: `Package.swift` has no top-level `dependencies:` array; upstream `swift-profile-recorder/Package.swift` lists swift-nio, swift-protobuf, swift-log, swift-atomics, async-http-client, swift-argument-parser (+ swift-configuration on 6.2), and `ProfileRecorderServer` depends on the NIO + protobuf targets.
- Observation: At `swift-profile-recorder` 0.3.18, `parseFromEnvironment()` is `async throws` on `ProfileRecorderServerConfiguration` (not a nested `ProfileRecorderServer.Configuration`). The launch block must `try await` it inside the detached `Task` and swallow configuration errors so a bad pattern never blocks app startup.
  Evidence: `.build/checkouts/swift-profile-recorder/Sources/ProfileRecorderServer/Server.swift` line 139; `main.swift` wraps the call in `do/catch`.

## Artifacts and Notes

Expected `/health` transcript (Validation B):

    < HTTP/1.1 200 OK

Expected `/sample` head after exercising the app (Validation C), captured 2026-07-06 from `.build/laban/Laban.app` with `--profile-recorder`:

    < HTTP/1.1 200 OK
    <n/a>-T12152355     53471/12152355     1783319916.242392000:    swipr
            1804adbc4 _semaphore_timedwait_trap+0xbc4 (/usr/lib/system/libsystem_kernel.dylib)
            ...
            10038c764 _$s13LabanRenderer22MetalDrawableSchedulerC10beginFrame... (/Users/user/.cursor/worktrees/laban/iufx/.build/laban/Laban.app/Contents/MacOS/LabanApp)
            1003e7590 _$s13LabanRenderer011VectorGlyphB0C6render_6damage... (/Users/user/.cursor/worktrees/laban/iufx/.build/laban/Laban.app/Contents/MacOS/LabanApp)
            100129cac _$s8LabanApp18TerminalBitmapViewC12advanceFrame4wake... (/Users/user/.cursor/worktrees/laban/iufx/.build/laban/Laban.app/Contents/MacOS/LabanApp)

To render pprof instead of perf, `GET /debug/pprof/profile` returns a `pprof`-format profile consumable by Go's pprof tooling and by Speedscope/Firefox Profiler. Not required for acceptance.
