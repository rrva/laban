import AppKit

func usage() -> String {
  """
  Usage:
    LabanApp [options]

  Options:
    --no-persistence-restore   Start without loading workspace.json while
                               leaving future persistence writes enabled.
    --no-persistence           Disable workspace, transcript, and agent
                               persistence for this process.
    --terminal-backend <name>   Use in-process/local or laband sessions for
                               this launch. Also accepts --terminal-backend=name.
    --local-sessions           Alias for --terminal-backend in-process.
    --laband-sessions          Alias for --terminal-backend laband.
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

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
