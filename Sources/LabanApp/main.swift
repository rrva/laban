import AppKit

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
    --profile-recorder[=<url>]  Enable the in-process sampling profiler. With no
                               value, listens on unix:///tmp/laban-samples-{PID}.sock.
                               Overrides the Settings toggle and
                               PROFILE_RECORDER_SERVER_URL_PATTERN.
    --smoke                    Print a startup smoke line and exit.
    --help, -h                 Show this help.
  """
}

if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
  print(usage())
  exit(0)
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

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
