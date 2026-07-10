import AppKit
import LabanCore

#if canImport(ProfileRecorderServer)
  import ProfileRecorderServer
  import Logging
#endif

func usage() -> String {
  """
  Usage:
    LabanApp [options]

  Options:
    --no-persistence-restore   Start without loading workspace.json while
                               leaving future persistence writes enabled.
    --no-persistence           Disable workspace, transcript, and agent
                               persistence for this process.
    --terminal-backend <name>   Use local, background, or detached sessions for
                               this launch. Also accepts --terminal-backend=name.
    --local-sessions           Alias for --terminal-backend in-process.
    --background-sessions      Alias for --terminal-backend background.
    --detached-sessions        Alias for --terminal-backend detached.
    --laband-sessions          Compatibility alias for --detached-sessions.
    --scroll-debug[=port]      Start the loopback scroll-indicator diagnostics
                               control surface (default port 8787) and write a
                               viewport trace under
                               ~/Library/Logs/Laban/scroll-trace/. Debug-only.
    --agent-attached-session   Advanced/dev/CI: open the first tab so it injects
                               a one-time C14 attach bootstrap (opts into
                               LABAN_CONTROL_ATTACH_ENV=1), letting `laban agent
                               run` attach with no approval dialog. Humans can
                               instead let an already-running agent attach on
                               demand via lazy attach (approve once).
    --profile-recorder[=<url>]  Enable the in-process sampling profiler. With no
                               value, listens under ~/Library/Application Support/
                               Laban/profiling/. Overrides the Settings toggle and
                               PROFILE_RECORDER_SERVER_URL[_PATTERN].
    --smoke                    Print a startup smoke line and exit.
    --help, -h                 Show this help.
  """
}

if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
  print(usage())
  exit(0)
}

// --agent-attached-session is the dev/E2E CLI entry point for C14 attach;
// it opts the first tab into both agent-attached mode and env bootstrap delivery.
if CommandLine.arguments.contains("--agent-attached-session") {
  setenv(ControlEnvironmentKeys.attachEnvOptIn, "1", 1)
}

let smokeMode =
  ProcessInfo.processInfo.environment["LABAN_SMOKE"] == "1"
  || CommandLine.arguments.contains("--smoke")

if smokeMode {
  NSApplication.shared.setActivationPolicy(.prohibited)
  print("laban-app: smoke ok")
  exit(0)
}

#if canImport(ProfileRecorderServer)
  let profileGate = ProfileRecorderSettings.resolve()
  if let pattern = profileGate.pattern {
    ProfileRecorderSettings.prepareDefaultDirectoryIfNeeded(for: pattern)
    // Upstream checks PROFILE_RECORDER_SERVER_URL before the pattern key; clear
    // any inherited direct URL so the resolved pattern is what the server binds.
    unsetenv("PROFILE_RECORDER_SERVER_URL")
    setenv("PROFILE_RECORDER_SERVER_URL_PATTERN", pattern, 1)
    let profilerLogger = Logger(label: "laban.profile-recorder")
    profilerLogger.info(
      "sampling profiler enabled",
      metadata: ["source": "\(profileGate.source)", "urlPattern": "\(pattern)"])
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
  }
#endif

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
