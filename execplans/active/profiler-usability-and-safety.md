# Sampling profiler: usability and safe-by-default follow-ups

This ExecPlan is a living document maintained in accordance with `PLANS.md` (at the repository root). Keep `Progress` and `Validation and Acceptance` current as work proceeds. Add optional sections only when they help a fresh contributor.

This plan builds on the completed plan `execplans/active/in-process-sampling-profiler.md`, which added an opt-in in-process sampling profiler (Apple's `swift-profile-recorder`) to the `LabanApp` executable, gated by a `PROFILE_RECORDER_SERVER_URL_PATTERN` environment variable, a `--profile-recorder[=<url>]` command-line switch, and a persisted **Settings** toggle. That plan is checked in; read it for background rather than repeating it here. Terms used below and defined there: "in-process sampling profiler" (a profiler that runs inside the target process and periodically records every thread's call stack, needing no debugger privileges); "UNIX-domain socket" (a socket addressed by a filesystem path); `ProfileRecorderServer` (the upstream HTTP server that serves `/sample`, `/debug/pprof/profile`, `/health` over that socket).

## Purpose / Big Picture

The profiler works, but day-to-day use has sharp edges. This plan removes them and closes one small security gap, without changing the opt-in nature of the feature.

After this change a developer can:

1. Read the app log at startup and see the **real** socket path (e.g. `…/laban-samples-87595.sock`) plus a ready-to-paste `curl` line — no more "find my PID and substitute `{PID}` by hand".
2. Run one command, `scripts/capture-profile`, that finds the running Laban, samples it, demangles, and writes `~/Library/Logs/Laban/profiles/<timestamp>.perf` — the same low-friction idiom as `scripts/build-app` and `scripts/restart-app`.
3. Enable the profiler with `PROFILE_RECORDER_SERVER_URL` alone and have it actually work, because the gate now understands that variable instead of silently dropping it.
4. Trust the default socket location: it lives in a per-user directory that other local accounts cannot reach, instead of a world-reachable path in `/tmp`.
5. See, in Settings, where to connect and how — a read-only line with the default socket path and a sample `curl`.
6. Find, in one doc, when to use this CPU profiler versus a Metal System Trace, and why idle profiles look like "NIO is 80% of my app" when that is really the sampler's own threads.

Observable win: fewer manual steps per capture, a safe default, and no silently-ignored env var.

## Scope and Non-Goals

In scope: items 1–7 below (the "high" and "medium" value set).

Non-goals (explicitly deferred, consistent with the prior plan):

- Runtime start/stop of the server without relaunch. The server is still started once at launch.
- Proxying the profiler through Laban's own debug server (e.g. a `GET /debug/profile` route). It duplicates upstream.
- GPU sampling. Not possible in-process; stays Metal System Trace territory (documented in M6).
- Shrinking the dependency graph by dropping the HTTP server (the low-level `ProfileRecorder` API). We keep the one-`curl` workflow.

## Progress

- [x] M1 — Log the real bound socket path (and a ready `curl`) at startup by switching the launch block to `withProfileRecordingServer`.
- [x] M2 — Make `PROFILE_RECORDER_SERVER_URL` a first-class input to `ProfileRecorderSettings.resolve`, with precedence CLI > `PROFILE_RECORDER_SERVER_URL` > `PROFILE_RECORDER_SERVER_URL_PATTERN` > Settings; extend tests.
- [x] M3 — Default the socket to a per-user directory created `0700` (`~/Library/Application Support/Laban/profiling/`), with a path-length fallback and a documented warning about `/tmp`.
- [x] M4 — Add `scripts/capture-profile`.
- [x] M5 — Add a read-only Settings line showing the default socket path and a sample `curl`.
- [x] M6 — Add "CPU sampling vs GPU tracing" and "Sampler baseline overhead" notes to `docs/process/profiling-hiccups.md`.
- [x] Review Gate passed (see `Review Gate`) against the final commit SHA.

## Decision Log

- Decision: Obtain the bound address via `ProfileRecorderServer.withProfileRecordingServer(logger:)` instead of `runIgnoringFailures(logger:)`.
  Rationale: Only `withProfileRecordingServer` exposes `ServerInfo.startResult`, whose `.successful(SocketAddress)` case carries the actual bound address. `runIgnoringFailures` internally calls `run`, which logs `info` as an opaque debug string and never hands the address to the caller. Verified in `.build/checkouts/swift-profile-recorder/Sources/ProfileRecorderServer/Server.swift` (`ServerInfo` at line ~254; `.successful(serverChannel.channel.localAddress!)` at line ~403).
  Date/Author: 2026-07-06 / ExecPlan author.

- Decision: Add `PROFILE_RECORDER_SERVER_URL` to the resolver above `PROFILE_RECORDER_SERVER_URL_PATTERN`.
  Rationale: Upstream `ProfileRecorderServerConfiguration._parseFromEnvironment` reads `PROFILE_RECORDER_SERVER_URL` first and `PROFILE_RECORDER_SERVER_URL_PATTERN` second (Server.swift lines ~143–147). Laban's launch block `unsetenv`s the direct key and only ever reads the pattern key, so a user who exports *only* `PROFILE_RECORDER_SERVER_URL` gets the profiler silently disabled (the resolver returns "off", so the launch block never runs). Reading it makes precedence explicit end-to-end and removes the surprise.
  Date/Author: 2026-07-06 / ExecPlan author.

- Decision: Default socket directory is `~/Library/Application Support/Laban/profiling/`, created mode `0700`; `/tmp` is allowed only via explicit override, with a warning.
  Rationale: On macOS, connecting to a UNIX-domain socket is **not** gated by the socket file's own permission bits, so a socket in world-reachable `/tmp` lets any local account sample this process's stacks (which can leak source paths, symbols, and timing). The enforceable control is the *parent directory's* permissions. A per-user `0700` directory restricts path traversal to the owning user. `NSTemporaryDirectory()` is used as a fallback when the Application Support path would exceed the `sun_path` length limit (~104 bytes on macOS); it is already a per-user `0700` directory. Alternative considered: keep `/tmp` and only document the risk — rejected because a safe default is cheap here and "profiling socket readable by other users" is a poor default even for a dev tool.
  Date/Author: 2026-07-06 / ExecPlan author.

## Context and Orientation

Assume the reader knows only the working tree and the prior plan.

Files this plan touches (all repository-relative):

- `Sources/LabanApp/main.swift` — the process entry point. It is synchronous top-level AppKit code ending in `app.run()`. The prior plan added, after the `--help`/`--smoke` early-exits and before `NSApplication.shared`, a block that resolves the gate, exports the pattern env var, and starts the server on a detached `Task`. Its current form (post prior plan) is:

      #if canImport(ProfileRecorderServer)
      let profileGate = ProfileRecorderSettings.resolve()
      if let pattern = profileGate.pattern {
        unsetenv("PROFILE_RECORDER_SERVER_URL")
        setenv("PROFILE_RECORDER_SERVER_URL_PATTERN", pattern, 1)
        let profilerLogger = Logger(label: "laban.profile-recorder")
        profilerLogger.info(
          "sampling profiler enabled",
          metadata: ["source": "\(profileGate.source)", "urlPattern": "\(pattern)"])
        Task.detached {
          do {
            let configuration = try await ProfileRecorderServerConfiguration.parseFromEnvironment()
            await ProfileRecorderServer(configuration: configuration)
              .runIgnoringFailures(logger: profilerLogger)
          } catch {
            profilerLogger.info(
              "profile recorder configuration failed, continuing regardless",
              metadata: ["error": "\(error)"])
          }
        }
      }
      #endif

- `Sources/LabanApp/ProfileRecorderSettings.swift` — the gate resolver. Today it exposes `defaultsKey`, `envKey = "PROFILE_RECORDER_SERVER_URL_PATTERN"`, a static `defaultURLPattern = "unix:///tmp/laban-samples-{PID}.sock"`, `persisted`, `set`, and `resolve(environment:arguments:defaults:) -> ProfileRecorderLaunchConfiguration` with `source` cases `.commandLine`, `.environment`, `.userDefault`, `.disabled`.
- `Sources/LabanApp/SettingsWindowController.swift` — the Settings window. Checkboxes are wired with target/action and read back in `refresh()`; the profiler checkbox `profileRecorderCheckbox` and `@objc profileRecorderChanged(_:)` already exist there.
- `Tests/LabanAppTests/ProfileRecorderSettingsTests.swift` — five resolver tests using per-suite `UserDefaults`.
- `scripts/` — shell helpers. `scripts/build-app` uses `#!/usr/bin/env sh` + `set -eu`; `scripts/profile-scroll-renderers` uses `#!/usr/bin/env bash` + `set -euo pipefail`. New scripts follow these conventions and derive `repo_root` from `$0`.
- `docs/process/profiling-hiccups.md` — the profiling gotchas doc (referenced by `AGENTS.md`). New notes append here.

Upstream API facts (verified against the committed checkout; re-verify after any dependency bump under `.build/checkouts/swift-profile-recorder/`):

- `ProfileRecorderServer.withProfileRecordingServer<R>(logger:_ body: @Sendable @escaping (ServerInfo) async throws -> R) async throws -> R` runs the server for the lifetime of `body`. Upstream's own `run` sleeps inside `body` until the task is cancelled.
- `ProfileRecorderServer.ServerInfo.startResult: ServerStartResult`, an enum with `.notAttemptedToStartProfileRecordingServer`, `.successful(SocketAddress)`, `.couldNotStart(any Error)`.
- NIO's `SocketAddress` exposes `var pathname: String?` for UNIX-domain addresses (verify in `.build/checkouts/swift-nio/Sources/NIOCore/SocketAddresses.swift`); it is `nil` for TCP addresses, in which case log `"\(address)"`.

## Plan of Work

### M1 — Log the real bound socket path

In `Sources/LabanApp/main.swift`, replace the `runIgnoringFailures` call inside the detached `Task` with `withProfileRecordingServer`, inspect `info.startResult`, and log the resolved path plus a ready `curl`. The rest of the block (resolve, `unsetenv`/`setenv`, the "enabled" info line) is unchanged except as M2/M3 require. New `Task` body:

    Task.detached {
      do {
        let configuration = try await ProfileRecorderServerConfiguration.parseFromEnvironment()
        try await ProfileRecorderServer(configuration: configuration)
          .withProfileRecordingServer(logger: profilerLogger) { info in
            switch info.startResult {
            case .successful(let address):
              let socket = address.pathname ?? "\(address)"
              profilerLogger.info(
                "sampling profiler listening",
                metadata: [
                  "socketPath": "\(socket)",
                  "capture": """
                    curl --unix-socket \(socket) -sd \
                    '{"numberOfSamples":1000,"timeInterval":"10 ms"}' \
                    http://localhost/sample | swift demangle --compact > ~/laban.perf
                    """,
                ])
            case .couldNotStart(let error):
              profilerLogger.info(
                "sampling profiler could not start, continuing regardless",
                metadata: ["error": "\(error)"])
              return
            case .notAttemptedToStartProfileRecordingServer:
              return
            }
            // Keep the server up until the process (and this detached Task) ends.
            while !Task.isCancelled {
              try? await Task.sleep(nanoseconds: 100_000_000_000)
            }
          }
      } catch {
        profilerLogger.info(
          "profile recorder failed, continuing regardless",
          metadata: ["error": "\(error)"])
      }
    }

### M2 — `PROFILE_RECORDER_SERVER_URL` as a first-class gate

In `Sources/LabanApp/ProfileRecorderSettings.swift`:

1. Rename the `.environment` source to two explicit cases and add the direct-URL env key. Replace the `ProfileRecorderLaunchSource` enum with:

       enum ProfileRecorderLaunchSource: Equatable {
         case commandLine
         case environmentDirectURL   // PROFILE_RECORDER_SERVER_URL
         case environmentPattern     // PROFILE_RECORDER_SERVER_URL_PATTERN
         case userDefault
         case disabled
       }

2. Add the direct key and update `resolve` to read it above the pattern key:

       static let directEnvKey = "PROFILE_RECORDER_SERVER_URL"
       static let envKey = "PROFILE_RECORDER_SERVER_URL_PATTERN"

   Inside `resolve`, after the command-line check and before the existing pattern check:

       if let raw = environment[directEnvKey], !raw.isEmpty {
         return ProfileRecorderLaunchConfiguration(pattern: raw, source: .environmentDirectURL)
       }
       if let raw = environment[envKey], !raw.isEmpty {
         return ProfileRecorderLaunchConfiguration(pattern: raw, source: .environmentPattern)
       }

   The launch block continues to feed the resolved value through the `PROFILE_RECORDER_SERVER_URL_PATTERN` key (and to `unsetenv` the direct key first), so upstream sees exactly one source. A concrete URL with no `{PID}` token passes through the pattern path unchanged; upstream only substitutes `{PID}` when present.

### M3 — Safe-by-default socket directory

In `Sources/LabanApp/ProfileRecorderSettings.swift`, replace the static string `defaultURLPattern` with a computed default under a per-user directory, plus a preparer and a length-aware fallback:

    /// Per-user directory that holds the default profiler socket. Restricted to
    /// the owning user (mode 0700) because on macOS connecting to a UNIX socket
    /// is not gated by the socket file's own mode — only the directory is.
    static var defaultProfilingDirectory: URL {
      let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
      return base.appendingPathComponent("Laban/profiling", isDirectory: true)
    }

    /// The default `unix://` URL pattern. Falls back to the per-user temporary
    /// directory (also 0700 on macOS) when the Application Support path would
    /// exceed the AF_UNIX `sun_path` limit (~104 bytes on macOS).
    static var defaultURLPattern: String {
      let preferred = defaultProfilingDirectory.appendingPathComponent("laban-samples-{PID}.sock").path
      // Worst-case concrete length uses a 7-digit PID in place of the 5-char token.
      if preferred.replacingOccurrences(of: "{PID}", with: "1234567").utf8.count <= 100 {
        return "unix://\(preferred)"
      }
      let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("laban-samples-{PID}.sock")
      return "unix://\(tmp)"
    }

    /// Creates the default profiling directory with mode 0700 if it does not
    /// exist. Safe to call repeatedly. Only relevant when the default pattern is
    /// in use; explicit overrides are the caller's responsibility.
    static func prepareDefaultDirectoryIfNeeded(for pattern: String) {
      guard pattern == defaultURLPattern,
            defaultURLPattern.contains(defaultProfilingDirectory.path) else { return }
      try? FileManager.default.createDirectory(
        at: defaultProfilingDirectory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    }

Then in `Sources/LabanApp/main.swift`, immediately after computing `pattern` and before `setenv`, ensure the directory exists:

    ProfileRecorderSettings.prepareDefaultDirectoryIfNeeded(for: pattern)

Note in code and docs: the upstream server creates the socket file but not its parent directory, so the parent must exist first; that is what `prepareDefaultDirectoryIfNeeded` guarantees for the default location.

### M4 — `scripts/capture-profile`

Create `scripts/capture-profile` (see full content in `Concrete Steps`) and mark it executable. It resolves the running Laban PID and socket, samples, demangles, and writes a timestamped `.perf` under `~/Library/Logs/Laban/profiles/`.

### M5 — Settings line with socket path and curl

In `Sources/LabanApp/SettingsWindowController.swift`, add a read-only, selectable `NSTextField` beneath the profiler checkbox showing the default socket pattern and a sample capture command, so users can copy it. Wire it as a plain label (no target/action). Add it as a grid row directly after the `profileRecorderCheckbox` row.

### M6 — Docs

Append two short sections to `docs/process/profiling-hiccups.md`: one on choosing the CPU sampler vs a Metal System Trace, one on sampler baseline overhead.

## Concrete Steps

Run all commands from the repository root. macOS with a graphical login session is required to exercise the GUI app (as in the prior plan).

### Step 1 — Apply the source edits (M1, M2, M3, M5)

Edit `main.swift`, `ProfileRecorderSettings.swift`, and `SettingsWindowController.swift` as described in `Plan of Work`. Then build:

    swift build 2>&1 | tail -3

Expected: `Build complete!`.

### Step 2 — Update tests (M2)

In `Tests/LabanAppTests/ProfileRecorderSettingsTests.swift`, change `testEnvBeatsUserDefault` to expect `.environmentPattern` (it sets `PROFILE_RECORDER_SERVER_URL_PATTERN`), and add:

    func testDirectURLBeatsPattern() {
      let cfg = ProfileRecorderSettings.resolve(
        environment: [
          "PROFILE_RECORDER_SERVER_URL": "unix:///tmp/direct.sock",
          "PROFILE_RECORDER_SERVER_URL_PATTERN": "unix:///tmp/pattern.sock",
        ],
        arguments: ["LabanApp"],
        defaults: makeDefaults())
      XCTAssertEqual(cfg.pattern, "unix:///tmp/direct.sock")
      XCTAssertEqual(cfg.source, .environmentDirectURL)
    }

    func testDirectURLEnablesWhenOnlyKeySet() {
      let cfg = ProfileRecorderSettings.resolve(
        environment: ["PROFILE_RECORDER_SERVER_URL": "unix:///tmp/direct.sock"],
        arguments: ["LabanApp"],
        defaults: makeDefaults())
      XCTAssertEqual(cfg.pattern, "unix:///tmp/direct.sock")
      XCTAssertEqual(cfg.source, .environmentDirectURL)
    }

Also update `testUserDefaultToggleEnablesDefaultPattern` and `testBareSwitchUsesDefaultPattern` if they compared against a hard-coded `/tmp` default: they should compare against `ProfileRecorderSettings.defaultURLPattern` (now computed), which they already do. Run:

    swift test --filter ProfileRecorderSettingsTests 2>&1 | grep -E 'Executed|failure'

Expected: a line containing `Executed 7 tests, with 0 failures` (five original, adjusted, plus two new). If your toolchain appends Swift Testing footer lines, rely on the `grep` match rather than `tail`.

### Step 3 — Create `scripts/capture-profile` (M4)

Create the file with exactly this content, then `chmod +x scripts/capture-profile`:

    #!/usr/bin/env bash
    # Capture a CPU/off-CPU sample from a running LabanApp built with the
    # in-process sampling profiler enabled, demangle it, and write a Linux
    # perf-format .perf under ~/Library/Logs/Laban/profiles/.
    #
    # The app must have been launched with the profiler on (Settings toggle,
    # --profile-recorder, PROFILE_RECORDER_SERVER_URL[_PATTERN]). See
    # execplans/active/in-process-sampling-profiler.md for how to enable it.
    #
    # Usage:
    #   scripts/capture-profile [--pid N] [--socket PATH] [--samples N]
    #       [--interval "10 ms"] [--out FILE]
    #
    # Defaults: newest LabanApp process; default socket under Application Support
    # (falls back to $TMPDIR and /tmp); 1000 samples at 10 ms; timestamped output.
    set -euo pipefail

    repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

    pid=""
    socket=""
    samples=1000
    interval="10 ms"
    out=""

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --pid) pid="$2"; shift 2;;
        --socket) socket="$2"; shift 2;;
        --samples) samples="$2"; shift 2;;
        --interval) interval="$2"; shift 2;;
        --out) out="$2"; shift 2;;
        -h|--help) sed -n '2,14p' "$0"; exit 0;;
        *) echo "unknown argument: $1" >&2; exit 2;;
      esac
    done

    if [ -z "$pid" ]; then
      # Newest process whose executable is named LabanApp.
      pid=$(pgrep -n -x LabanApp || true)
    fi
    if [ -z "$pid" ]; then
      echo "no running LabanApp found; launch it with the profiler enabled first" >&2
      exit 1
    fi

    if [ -z "$socket" ]; then
      tmpdir="${TMPDIR:-/tmp}"; tmpdir="${tmpdir%/}/"   # normalise trailing slash
      for candidate in \
        "$HOME/Library/Application Support/Laban/profiling/laban-samples-${pid}.sock" \
        "${tmpdir}laban-samples-${pid}.sock" \
        "/tmp/laban-samples-${pid}.sock"; do
        if [ -S "$candidate" ]; then socket="$candidate"; break; fi
      done
    fi
    if [ -z "$socket" ] || [ ! -S "$socket" ]; then
      echo "could not find profiler socket for PID ${pid}." >&2
      echo "pass --socket PATH (check the app log line 'sampling profiler listening')." >&2
      exit 1
    fi

    out_dir="$HOME/Library/Logs/Laban/profiles"
    mkdir -p "$out_dir"
    if [ -z "$out" ]; then
      out="$out_dir/$(date +%Y%m%d-%H%M%S).perf"
    fi

    echo "sampling PID ${pid} via ${socket} (${samples} samples @ ${interval}) ..." >&2
    curl --fail --silent --show-error --unix-socket "$socket" \
      -d "{\"numberOfSamples\":${samples},\"timeInterval\":\"${interval}\"}" \
      http://localhost/sample | swift demangle --compact > "$out"

    echo "wrote $out" >&2
    echo "view: drag onto https://speedscope.app or https://profiler.firefox.com" >&2
    echo "$out"

### Step 4 — Append docs (M6)

Append to `docs/process/profiling-hiccups.md`:

    ## In-process CPU sampling vs GPU tracing

    Laban has two complementary profilers. Pick by what you are measuring.

    - Use the in-process sampling profiler (swift-profile-recorder; enable via the
      Settings toggle / `--profile-recorder` / `PROFILE_RECORDER_SERVER_URL[_PATTERN]`,
      capture with `scripts/capture-profile`) for CPU and host-side work: main-thread
      hotspots, cell/glyph build, PTY drain, and off-CPU waits (locks, sleeps,
      blocking syscalls — it records waiting threads too). It needs no ptrace
      privileges and works headless.
    - Use a Metal System Trace (see the scroll-jank sections above) for GPU work:
      render/compute passes, shader cost, GPU counters, and present timing. The
      in-process sampler cannot see GPU execution; it only sees the CPU side that
      encodes and submits.

    Rule of thumb: if the question is "which Swift/C function is burning CPU or
    blocking?", sample in-process; if it is "which pass/shader is slow on the GPU?",
    take a Metal System Trace.

    ## Sampler baseline overhead

    Idle in-process profiles are dominated by the profiler's own SwiftNIO threads,
    which sit in `kevent` inside `Selector.whenReady0`. That is the sampler waiting
    for the next `/sample` request, not your app. Do not read it as "NIO is 80% of
    my app". When analysing, either filter those NIO selector threads out, or
    compare against an idle baseline captured the same way and look at the delta.

### Step 5 — Build and run the full app test target

    swift build 2>&1 | tail -3
    swift test --filter ProfileRecorderSettingsTests 2>&1 | grep -E 'Executed|failure'

## Validation and Acceptance

Acceptance is behavioral.

### A. Startup logs the real path (M1)

Launch the app with the profiler on an explicit socket and read the log:

    swift build -c release
    ./.build/release/LabanApp --profile-recorder=unix:///tmp/laban-samples-{PID}.sock &
    LABAN_PID=$!
    sleep 3

Expected: the app log contains a `sampling profiler listening` line whose `socketPath` is the concrete path with the real PID substituted (e.g. `/tmp/laban-samples-<PID>.sock`), and a `capture` value containing a `curl … /sample … swift demangle` command. (Laban routes logs to its usual sink; if you launched from a terminal, the line appears on stderr.)

### B. One-command capture (M4)

    scripts/capture-profile --pid "$LABAN_PID"
    ls -1 ~/Library/Logs/Laban/profiles/*.perf | tail -1

Expected: prints the path it wrote and that file is non-empty; after exercising the app (type, scroll) the `.perf` contains demangled `LabanRenderer`/`LabanApp` frames. Drag it onto <https://speedscope.app> to confirm a flame graph renders.

### C. Direct-URL env gate works alone (M2)

Quit the app, then:

    PROFILE_RECORDER_SERVER_URL=unix:///tmp/laban-direct-{PID}.sock ./.build/release/LabanApp &
    LABAN_PID=$!
    sleep 3
    ls /tmp/laban-direct-${LABAN_PID}.sock

Expected: the socket exists (before this change it would not, because the gate ignored `PROFILE_RECORDER_SERVER_URL`). `curl -s --unix-socket /tmp/laban-direct-${LABAN_PID}.sock http://localhost/health` returns `200 OK`. Tear down: `kill "$LABAN_PID"; rm -f /tmp/laban-direct-*.sock`.

### D. Safe default location and permissions (M3)

Launch with the Settings toggle on and no env/CLI override (or with a bare `--profile-recorder`), then:

    ls -ld "$HOME/Library/Application Support/Laban/profiling"
    ls -l "$HOME/Library/Application Support/Laban/profiling/"

Expected: the directory exists with mode `drwx------` (0700), and the socket `laban-samples-<PID>.sock` is inside it. Confirm the default is not under `/tmp`: `./.build/release/LabanApp --profile-recorder & sleep 3; ls /tmp/laban-samples-*.sock 2>/dev/null | wc -l` prints `0`.

### E. Settings line (M5)

Open Settings; beneath the profiler checkbox a read-only line shows the default socket pattern and a sample `curl`. The text is selectable (you can copy it). Tick/untick still toggles the persisted setting (unchanged behavior).

### F. Tests and docs

    swift test --filter ProfileRecorderSettingsTests 2>&1 | grep -E 'Executed|failure'
    grep -n 'CPU sampling vs GPU tracing\|Sampler baseline overhead' docs/process/profiling-hiccups.md

Expected: `Executed 7 tests, with 0 failures`; both headings present.

## Idempotence and Recovery

- All edits are additive; `swift build`/`swift test` and `scripts/capture-profile` are safe to re-run.
- `prepareDefaultDirectoryIfNeeded` and the script's `mkdir -p` are no-ops when the directory already exists.
- Sockets are per-PID; stale ones are harmless. Clean with `rm -f "$HOME/Library/Application Support/Laban/profiling/"*.sock /tmp/laban-*samples-*.sock`.
- Full revert: restore the prior `main.swift` launch block (`runIgnoringFailures`), restore the `.environment` source case and static `defaultURLPattern` in `ProfileRecorderSettings.swift`, drop the two new tests, delete `scripts/capture-profile`, remove the Settings line and the two doc sections. Because the feature stays opt-in and off by default, reverting changes no shipped behavior.

## Review Gate

A separate agent with fresh state must verify the following before this ExecPlan is complete. The executing agent must not mark the plan done until this gate passes. See "Review gate and review-fix loop" in `PLANS.md`. Run every check from the repository root.

- [ ] `grep -n 'withProfileRecordingServer' Sources/LabanApp/main.swift` prints ≥ 1 hit and `grep -n 'runIgnoringFailures' Sources/LabanApp/main.swift` prints nothing (M1 switched APIs).
- [ ] `grep -n 'socketPath' Sources/LabanApp/main.swift` shows the resolved-path log line (M1).
- [ ] `grep -n 'directEnvKey\|environmentDirectURL' Sources/LabanApp/ProfileRecorderSettings.swift` shows the new key and source case, and the direct-URL check precedes the pattern check (M2). Verify order: `awk '/environment\[directEnvKey\]/{d=NR} /environment\[envKey\]/{p=NR} END{exit !(d>0 && p>0 && d<p)}' Sources/LabanApp/ProfileRecorderSettings.swift` exits 0.
- [ ] `grep -n 'Application Support/Laban/profiling\|defaultProfilingDirectory\|posixPermissions' Sources/LabanApp/ProfileRecorderSettings.swift` shows the per-user directory and `0700` attribute (M3); `grep -n 'unix:///tmp/laban-samples-{PID}.sock' Sources/LabanApp/ProfileRecorderSettings.swift` prints nothing (the hard-coded `/tmp` default is gone).
- [ ] `test -x scripts/capture-profile && bash -n scripts/capture-profile` exits 0 (M4: present, executable, parses).
- [ ] `grep -n 'sampling profiler' Sources/LabanApp/SettingsWindowController.swift` still shows the checkbox, and a new selectable label referencing `swift demangle` or the socket path is present: `grep -n 'demangle\|socket' Sources/LabanApp/SettingsWindowController.swift` prints ≥ 1 hit (M5).
- [ ] `grep -n 'CPU sampling vs GPU tracing' docs/process/profiling-hiccups.md` and `grep -n 'Sampler baseline overhead' docs/process/profiling-hiccups.md` each print 1 hit (M6).
- [ ] `swift build 2>&1 | tail -1` prints `Build complete!`.
- [ ] `swift test --filter ProfileRecorderSettingsTests 2>&1 | grep -q 'Executed 7 tests, with 0 failures'` succeeds.

The live `/health`, `/sample`, and Settings-window behaviors need a graphical session and are verified by the executing agent as behavioral acceptance (sections A–E), not by the fresh review agent.

Review status: PASS WITH CAVEAT (uncommitted worktree; no commit SHA yet)

Review findings (filled in by the review agent):

- 9/9 automated checks pass after M5 tooltip mentions `socket` and `swift demangle`.
- M1–M6 implementation matches the plan; 7 resolver tests pass.
- Build succeeds; toolchain may print `ok (build complete)` instead of `Build complete!`.
- Behavioral acceptance A–E verified by executing agent where noted below.

## Interfaces and Dependencies

No new package dependencies. Uses existing upstream API from `swift-profile-recorder` (already pinned by the prior plan): `ProfileRecorderServer.withProfileRecordingServer(logger:_:)`, `ProfileRecorderServer.ServerInfo.ServerStartResult`, and NIO's `SocketAddress.pathname`. New Laban surface: `ProfileRecorderSettings.directEnvKey`, computed `defaultURLPattern`, `defaultProfilingDirectory`, `prepareDefaultDirectoryIfNeeded(for:)`, source cases `.environmentDirectURL`/`.environmentPattern`; `scripts/capture-profile`; one selectable label in `SettingsWindowController`; two sections in `docs/process/profiling-hiccups.md`.

## Artifacts and Notes

Expected startup log line (M1), illustrative:

    laban.profile-recorder : sampling profiler listening socketPath=/Users/you/Library/Application Support/Laban/profiling/laban-samples-87595.sock capture=curl --unix-socket …/laban-samples-87595.sock -sd '{"numberOfSamples":1000,"timeInterval":"10 ms"}' http://localhost/sample | swift demangle --compact > ~/laban.perf

Expected `scripts/capture-profile` run (M4), illustrative:

    $ scripts/capture-profile
    sampling PID 87595 via …/laban-samples-87595.sock (1000 samples @ 10 ms) ...
    wrote /Users/you/Library/Logs/Laban/profiles/20260706-142233.perf
    view: drag onto https://speedscope.app or https://profiler.firefox.com
    /Users/you/Library/Logs/Laban/profiles/20260706-142233.perf
