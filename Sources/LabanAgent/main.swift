import CoreGraphics
import Darwin
import Foundation
import LabanControl
import LabanCore
import LabanDebug
import LabanRenderer
import LabanTerminalCore

// MARK: - Arg parsing

struct AgentArgs {
  var help = false
  var headless = false
  var debugServerAddress: String? = nil
  var fixture: String? = nil
  var artifacts: String? = nil
  var tempDir: String? = nil
  var deterministic = false
  var capture: String? = nil
  var captureScreenshots: CaptureScreenshotPolicy = .marked
  var rendererSelection: RendererSelection = .software
  var emojiRenderingMode: EmojiRenderingMode? = nil
  var replayCapture: String? = nil
  var replayMode: CaptureReplayMode = .both
  var controlAttach = false
  var controlAttachSmokePaths: [String] = []
  /// Optional persistence directory. When set, the headless runtime
  /// wires the same PersistenceCoordinator / TranscriptHost /
  /// AgentObserverHost chain that `MainWindowController` uses in the
  /// real app — so persistence bugs can be reproduced and observed
  /// inside the debug harness against the production classes.
  var persistenceDir: String? = nil
  var noPersistenceRestore = false
  var noPersistence = false
}

func parseArgs() -> AgentArgs {
  var a = AgentArgs()
  for arg in CommandLine.arguments.dropFirst() {
    switch arg {
    case "--help", "-h": a.help = true
    case "--headless": a.headless = true
    case "--deterministic": a.deterministic = true
    case "--debug-server": a.debugServerAddress = "127.0.0.1:0"
    case "--control-attach": a.controlAttach = true
    case PersistenceRestoreLaunchFlag.argument: a.noPersistenceRestore = true
    case PersistenceRestoreLaunchFlag.noPersistenceArgument: a.noPersistence = true
    default:
      if arg.hasPrefix("--fixture=") {
        a.fixture = String(arg.dropFirst("--fixture=".count))
      } else if arg.hasPrefix("--artifacts=") {
        a.artifacts = String(arg.dropFirst("--artifacts=".count))
      } else if arg.hasPrefix("--temp-dir=") {
        a.tempDir = String(arg.dropFirst("--temp-dir=".count))
      } else if arg.hasPrefix("--debug-server=") {
        a.debugServerAddress = String(arg.dropFirst("--debug-server=".count))
      } else if arg.hasPrefix("--capture=") {
        a.capture = String(arg.dropFirst("--capture=".count))
      } else if arg.hasPrefix("--capture-screenshots=") {
        let raw = String(arg.dropFirst("--capture-screenshots=".count)).lowercased()
        switch raw {
        case "final": a.captureScreenshots = .final
        case "all": a.captureScreenshots = .all
        case "none": a.captureScreenshots = .none
        default: a.captureScreenshots = .marked
        }
      } else if arg.hasPrefix("--renderer=") {
        let raw = String(arg.dropFirst("--renderer=".count))
        a.rendererSelection = RendererSelection(rawValue: raw) ?? .software
      } else if arg.hasPrefix("--emoji-rendering=") {
        let raw = String(arg.dropFirst("--emoji-rendering=".count))
        a.emojiRenderingMode = EmojiRenderingMode(rawValue: raw)
      } else if arg.hasPrefix("--replay-capture=") {
        a.replayCapture = String(arg.dropFirst("--replay-capture=".count))
      } else if arg.hasPrefix("--replay-mode=") {
        let raw = String(arg.dropFirst("--replay-mode=".count)).lowercased()
        a.replayMode = CaptureReplayMode(rawValue: raw) ?? .both
      } else if arg.hasPrefix("--persistence-dir=") {
        a.persistenceDir = String(arg.dropFirst("--persistence-dir=".count))
      } else if arg.hasPrefix("--control-attach-smoke=") {
        a.controlAttach = true
        a.controlAttachSmokePaths.append(String(arg.dropFirst("--control-attach-smoke=".count)))
      }
    }
  }
  return a
}

func usage() -> String {
  """
  Usage:
    laban-agent --headless --fixture=PATH --artifacts=PATH [--deterministic]
    laban-agent --headless --debug-server[=127.0.0.1:0] [options]
    laban-agent --replay-capture=PATH [--replay-mode=both|terminal|renderer]
    laban-agent --control-attach [--control-attach-smoke=PATH ...]

  Debug server options:
    --fixture=PATH                  Load a deterministic fixture session.
                                    Without --fixture, the debug server starts a real /bin/sh PTY.
    --artifacts=PATH                Write screenshots, snapshots, and captures here.
    --temp-dir=PATH                 Use an isolated temp directory.
    --capture=NAME                  Start full capture recording immediately.
    --capture-screenshots=POLICY    final, all, none, or marked.
    --renderer=NAME                 software, classic, gpuDriven, vectorGlyph, or slugGlyph
                                    for the debug/headless renderer backend.
    --emoji-rendering=MODE          monochrome or color. Process-local override
                                    for autonomous renderer verification.
    --persistence-dir=PATH          Wire workspace.json + transcript + agent
                                    persistence against PATH. Use this directory
                                    to reproduce M0/M1/M2 bugs against the same
                                    PersistenceCoordinator / TranscriptHost /
                                    AgentObserverHost the real app uses.
    --no-persistence-restore        Start without loading workspace.json while
                                    leaving future persistence writes enabled.
    --no-persistence                Do not wire workspace, transcript, or agent
                                    persistence for this process.

  Discoverability:
    The debug server prints one readiness JSON line:
      {"debugServer":"/path/to/control.sock","debugToken":"...","pid":12345,"runId":"..."}

    Export the socket path as DEBUG_URL and the token as DEBUG_TOKEN, then ask the live server what it supports:
      curl --unix-socket "$DEBUG_URL" -H "Authorization: Bearer $DEBUG_TOKEN" http://localhost/debug | jq
      curl --unix-socket "$DEBUG_URL" -H "Authorization: Bearer $DEBUG_TOKEN" http://localhost/debug/capabilities | jq

    Useful starting points:
      GET  /debug/health
      GET  /debug/state
      GET  /debug/metrics
      POST /debug/actions
      POST /debug/find/start
      GET  /debug/find/state
      POST /debug/wait
      POST /debug/snapshot
      POST /debug/fixture

  Live GUI attach:
    --control-attach                Redeem LABAN_SESSION_ATTACH against LABAN_CONTROL_URL,
                                    then keep the connection open and proxy JSONL stdin
                                    requests of {"method":"GET","path":"/debug/state"}.
    --control-attach-smoke=PATH     After attach, request PATH on the same bound
                                    connection, print the status/body JSON, then exit.
  """
}

// MARK: - Result

struct HeadlessResult: Encodable {
  let mode: String
  let frameCount: Int
  let activeTabId: String
  let activeSessionId: String
  let terminalRows: Int
  let terminalCols: Int
  let screenshotPath: String
  let foundExpectedText: Bool?

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(mode, forKey: .mode)
    try c.encode(frameCount, forKey: .frameCount)
    try c.encode(activeTabId, forKey: .activeTabId)
    try c.encode(activeSessionId, forKey: .activeSessionId)
    try c.encode(terminalRows, forKey: .terminalRows)
    try c.encode(terminalCols, forKey: .terminalCols)
    try c.encode(screenshotPath, forKey: .screenshotPath)
    try c.encodeIfPresent(foundExpectedText, forKey: .foundExpectedText)
  }

  private enum CodingKeys: String, CodingKey {
    case mode, frameCount, activeTabId, activeSessionId
    case terminalRows, terminalCols, screenshotPath, foundExpectedText
  }
}

// MARK: - Helpers

func fail(_ message: String) -> Never {
  fputs("laban-agent: error: \(message)\n", stderr)
  exit(1)
}

func resolveURL(_ path: String) -> URL {
  if (path as NSString).isAbsolutePath {
    return URL(fileURLWithPath: path)
  }
  let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  return cwd.appendingPathComponent(path)
}

func defaultDebugArtifactsPath() -> String {
  let pid = ProcessInfo.processInfo.processIdentifier
  let suffix = UUID().uuidString.prefix(8)
  return ".artifacts/runs/debug-server-\(pid)-\(suffix)"
}

struct LiveControlAttachReady: Encodable {
  var mode = "control-attach"
  var ok = true
  var sessionID: String
}

struct LiveControlAttachRequest: Decodable {
  var method: String?
  var path: String
  var body: String?
}

struct LiveControlAttachResponse: Encodable {
  var path: String
  var status: Int
  var body: String
}

struct LiveControlAttachSmokeResponse: Encodable {
  var path: String
  var status: Int
}

func printJSON<T: Encodable>(_ value: T) {
  let enc = JSONEncoder()
  enc.outputFormatting = [.sortedKeys]
  guard let data = try? enc.encode(value), let text = String(data: data, encoding: .utf8) else {
    fail("failed to encode JSON output")
  }
  print(text)
  fflush(stdout)
}

func requestLiveControl(fd: Int32, request: LiveControlAttachRequest) throws
  -> LiveControlAttachResponse
{
  let body = request.body.flatMap { Data($0.utf8) }
  let (status, responseBody) = try ControlUDSClient.request(
    fd: fd,
    method: request.method ?? "GET",
    path: request.path,
    body: body,
    keepConnectionOpen: true)
  return LiveControlAttachResponse(
    path: request.path,
    status: status,
    body: String(data: responseBody, encoding: .utf8) ?? "")
}

func runLiveControlAttach(_ args: AgentArgs) -> Never {
  let env = ProcessInfo.processInfo.environment
  guard let socketPath = env[ControlEnvironmentKeys.controlURL], !socketPath.isEmpty else {
    fail("\(ControlEnvironmentKeys.controlURL) is required for --control-attach")
  }
  guard let bootstrap = env[ControlEnvironmentKeys.sessionAttach], !bootstrap.isEmpty else {
    fail("\(ControlEnvironmentKeys.sessionAttach) is required for --control-attach")
  }

  var attachment: (fd: Int32, sessionID: String)?
  let attempts = 5
  for attempt in 0..<attempts {
    do {
      attachment = try ControlUDSClient.redeemAttachBootstrap(
        socketPath: socketPath,
        bootstrap: bootstrap)
      break
    } catch {
      if attempt == attempts - 1 {
        fail("control attach failed after \(attempts) attempts: \(error)")
      }
      let delay = min(0.1 * pow(2.0, Double(attempt)), 1.0)
      Thread.sleep(forTimeInterval: delay)
    }
  }
  guard let attachment else {
    fail("control attach failed: no attachment produced")
  }
  defer { Darwin.close(attachment.fd) }

  printJSON(LiveControlAttachReady(sessionID: attachment.sessionID))

  if !args.controlAttachSmokePaths.isEmpty {
    for path in args.controlAttachSmokePaths {
      do {
        let response = try requestLiveControl(
          fd: attachment.fd,
          request: LiveControlAttachRequest(method: "GET", path: path, body: nil))
        printJSON(LiveControlAttachSmokeResponse(path: response.path, status: response.status))
      } catch {
        fail("control smoke request failed for \(path): \(error)")
      }
    }
    exit(0)
  }

  while let line = readLine() {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { continue }
    do {
      let request = try JSONDecoder().decode(
        LiveControlAttachRequest.self,
        from: Data(trimmed.utf8))
      printJSON(try requestLiveControl(fd: attachment.fd, request: request))
    } catch {
      fputs("laban-agent: control proxy request failed: \(error)\n", stderr)
      fflush(stderr)
    }
  }
  exit(0)
}

func installTerminationSource(
  signal signalNumber: Int32,
  runtime: HeadlessDebugRuntime,
  server: LabanControlServer
) -> DispatchSourceSignal {
  Darwin.signal(signalNumber, SIG_IGN)
  let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
  source.setEventHandler {
    runtime.shutdown(interrupted: true)
    server.stop()
    exit(0)
  }
  source.resume()
  return source
}

// MARK: - Entry point

let args = parseArgs()

if args.help {
  print(usage())
  exit(0)
}

if let emojiRenderingMode = args.emojiRenderingMode {
  UserDefaults.standard.setVolatileDomain(
    [EmojiRenderingSettings.defaultsKey: emojiRenderingMode.rawValue],
    forName: UserDefaults.argumentDomain)
}

if args.controlAttach {
  runLiveControlAttach(args)
}

if let replayPath = args.replayCapture {
  do {
    let runner = CaptureReplayRunner(captureURL: resolveURL(replayPath), mode: args.replayMode)
    let report = try runner.run()
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try enc.encode(report)
    if let text = String(data: data, encoding: .utf8) {
      print(text)
    }
    if !report.mismatches.isEmpty {
      exit(1)
    }
    exit(0)
  } catch {
    fail("capture replay failed: \(error)")
  }
}

if let debugAddr = args.debugServerAddress {
  // Debug server mode — requires --headless
  guard args.headless else { fail("--headless is required for debug server mode") }

  let artifactsPath =
    args.artifacts ?? defaultDebugArtifactsPath()
  let artifactsURL = resolveURL(artifactsPath)
  let tempURL = args.tempDir.map(resolveURL)
  let fixtureURL = args.fixture.map(resolveURL)
  let runId = artifactsURL.lastPathComponent

  let serverAddress: DebugServerAddress
  do {
    serverAddress = try DebugServerAddress.parse(debugAddr)
  } catch {
    fail("invalid --debug-server address '\(debugAddr)': \(error)")
  }
  _ = serverAddress

  let socketPath: String
  if let tempURL {
    socketPath = tempURL.appendingPathComponent("control.sock").path
  } else {
    socketPath = artifactsURL.appendingPathComponent("control.sock").path
  }

  let runtime: HeadlessDebugRuntime
  do {
    runtime = try HeadlessDebugRuntime(
      fixtureURL: fixtureURL,
      artifactsURL: artifactsURL,
      tempURL: tempURL,
      deterministic: args.deterministic,
      runId: runId,
      sessionMode: fixtureURL == nil ? .realShell : .fixture,
      rendererSelection: args.rendererSelection,
      captureName: args.capture,
      captureScreenshots: args.captureScreenshots,
      persistenceBaseURL: args.noPersistence ? nil : args.persistenceDir.map(resolveURL),
      restorePersistedState: !(args.noPersistenceRestore || args.noPersistence)
    )
  } catch {
    fail("failed to initialise debug runtime: \(error)")
  }

  // The headless surface mounts the shared LabanControl server (one route-table
  // adapter for GUI + headless). HeadlessIntentRouter encodes the legacy
  // ActionResult/MouseActionResult/binary wire, and readinessRunID feeds
  // runtime.runId so the readiness JSON stays byte-stable.
  let server = LabanControlServer(
    router: HeadlessIntentRouter(runtime: runtime),
    surface: .headless,
    readinessRunID: runtime.runId)
  let readiness: ControlReadiness
  do {
    readiness = try server.start(socketPath: socketPath)
  } catch {
    fail("failed to start debug server: \(error)")
  }

  runtime.emitServerReady()

  // Print exactly one readiness JSON line to stdout; everything else goes to stderr.
  let enc = JSONEncoder()
  enc.outputFormatting = .sortedKeys
  if let data = try? enc.encode(readiness), let line = String(data: data, encoding: .utf8) {
    print(line)
    // Flush stdout immediately: when redirected to a file, C stdio fully buffers output
    // and the readiness line would be invisible until the buffer fills or the process exits.
    fflush(stdout)
  } else {
    fail("failed to encode readiness JSON")
  }

  // Block until the process is terminated; the dispatch sources run normal Swift
  // cleanup so active captures are finalized as interrupted before exit.
  let termSource = installTerminationSource(signal: SIGTERM, runtime: runtime, server: server)
  let intSource = installTerminationSource(signal: SIGINT, runtime: runtime, server: server)
  _ = (termSource, intSource)
  dispatchMain()
}

// MARK: - One-shot headless path (unchanged)

guard args.headless else { fail("--headless is required") }
guard let fixturePath = args.fixture else { fail("--fixture is required") }
guard let artifactsPath = args.artifacts else { fail("--artifacts is required") }

let fixtureURL = resolveURL(fixturePath)
let artifactsURL = resolveURL(artifactsPath)

let runner: FixtureRunner
do {
  runner = try FixtureRunner.load(from: fixtureURL)
} catch {
  fail("failed to load fixture \(fixturePath): \(error)")
}

do {
  try FileManager.default.createDirectory(at: artifactsURL, withIntermediateDirectories: true)
} catch {
  fail("failed to create artifacts directory \(artifactsURL.path): \(error)")
}

if let tempPath = args.tempDir {
  let tempURL = resolveURL(tempPath)
  do {
    try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
  } catch {
    fail("failed to create temp directory \(tempURL.path): \(error)")
  }
}

var initialSize = LabanTerminalSize()
initialSize.rows = Int32(runner.fixture.initialSize.rows)
initialSize.cols = Int32(runner.fixture.initialSize.cols)

let model: AppModel
do {
  model = try AppModel(initialSize: initialSize)
} catch {
  fail("failed to create AppModel: \(error)")
}

let stepsFrameCount: Int
do {
  stepsFrameCount = try runner.apply(to: model)
} catch {
  fail("failed to apply fixture steps: \(error)")
}

guard let activeTab = model.activeTab,
  let session = model.session(forTab: activeTab.id),
  let snap = session.snapshot()
else {
  fail("failed to get snapshot")
}
defer { laban_snapshot_destroy(snap) }

let rows = Int(snap.pointee.rows)
let cols = Int(snap.pointee.cols)

let fontAtlas = FontAtlas(pointSize: 14)
let cellSize = fontAtlas.cellSize
let cellW = Int(cellSize.width)
let cellH = Int(cellSize.height)
let sidebarWidth: CGFloat = 200
let bitmapW = max(Int(sidebarWidth) + cols * cellW, 1)
let bitmapH = max(rows * cellH, 1)

let surface = BitmapSurface(width: bitmapW, height: bitmapH)
let renderer = SoftwareRenderer(surface: surface, fontAtlas: fontAtlas)

let sidebarProducer = SidebarProducer(
  sidebarWidth: sidebarWidth,
  cellWidth: CGFloat(cellW),
  cellHeight: CGFloat(cellH)
)
let frameProducer = FrameProducer(
  cellWidth: cellW,
  cellHeight: cellH,
  originX: sidebarWidth,
  originY: 0
)

var cmds: [FrameCommand] = []
cmds += sidebarProducer.commands(
  tabs: model.tabs, activeTabId: activeTab.id, height: CGFloat(bitmapH))
cmds += frameProducer.commands(from: UnsafePointer(snap))
renderer.render(cmds)

guard let pngData = surface.pngData else { fail("failed to encode PNG") }
let screenshotURL = artifactsURL.appendingPathComponent("screenshot.png")
do {
  try pngData.write(to: screenshotURL)
} catch {
  fail("failed to write screenshot: \(error)")
}

let foundExpectedText: Bool?
if let containsText = runner.fixture.expect?.containsText, !containsText.isEmpty {
  let text = runner.visibleText(from: UnsafePointer(snap))
  foundExpectedText = containsText.allSatisfy { text.contains($0) }
} else {
  foundExpectedText = nil
}

let result = HeadlessResult(
  mode: "headless",
  frameCount: stepsFrameCount + 1,
  activeTabId: activeTab.id,
  activeSessionId: activeTab.sessionId,
  terminalRows: rows,
  terminalCols: cols,
  screenshotPath: screenshotURL.path,
  foundExpectedText: foundExpectedText
)

let enc = JSONEncoder()
enc.outputFormatting = [.prettyPrinted, .sortedKeys]
let resultData: Data
do {
  resultData = try enc.encode(result)
} catch {
  fail("failed to encode result JSON: \(error)")
}

let resultURL = artifactsURL.appendingPathComponent("result.json")
do {
  try resultData.write(to: resultURL)
} catch {
  fail("failed to write result JSON: \(error)")
}

print("laban-agent: headless run complete")
print("  screenshot: \(screenshotURL.path)")
print("  result: \(resultURL.path)")
if let found = foundExpectedText {
  print("  foundExpectedText: \(found)")
}
