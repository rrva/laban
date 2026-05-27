import Darwin
import CoreGraphics
import Foundation
import LabanCore
import LabanRenderer
import LabanTerminalCore

private let outputSettleQuietMs = 12.0

private enum Transport: String, Codable {
  case inProcess = "in-process"
  case laband
  case labpty
}

private struct Options {
  var samples = 200
  var warmup = 30
  var cols = 120
  var rows = 36
  var jsonPath: String?
  var displayHz = 120.0
  var transport: Transport = .inProcess
  var socketPath: String?

  static func parse(_ args: [String]) throws -> Options {
    var options = Options()
    var i = 0
    while i < args.count {
      let arg = args[i]
      func value() throws -> String {
        guard i + 1 < args.count else { throw BenchError.message("missing value for \(arg)") }
        i += 1
        return args[i]
      }
      switch arg {
      case "--samples":
        options.samples = try Int(value()) ?? {
          throw BenchError.message("--samples must be an integer")
        }()
      case "--warmup":
        options.warmup = try Int(value()) ?? {
          throw BenchError.message("--warmup must be an integer")
        }()
      case "--cols":
        options.cols = try Int(value()) ?? {
          throw BenchError.message("--cols must be an integer")
        }()
      case "--rows":
        options.rows = try Int(value()) ?? {
          throw BenchError.message("--rows must be an integer")
        }()
      case "--json":
        options.jsonPath = try value()
      case "--display-hz":
        options.displayHz = try Double(value()) ?? {
          throw BenchError.message("--display-hz must be a number")
        }()
      case "--transport":
        let raw = try value()
        guard let transport = Transport(rawValue: raw) else {
          throw BenchError.message("--transport must be in-process or laband")
        }
        options.transport = transport
      case "--socket":
        options.socketPath = try value()
      case "--help", "-h":
        print(
          """
          Usage: bench-keystroke-latency [options]

          Options:
            --samples N       measured samples (default: 200)
            --warmup N        discarded warmup samples (default: 30)
            --cols N          terminal columns (default: 120)
            --rows N          terminal rows (default: 36)
            --display-hz HZ   display cadence estimate (default: 120)
            --transport MODE  in-process or laband (default: in-process)
            --socket PATH     laband socket path for --transport laband
            --json PATH       write machine-readable results
          """)
        exit(0)
      default:
        throw BenchError.message("unknown argument: \(arg)")
      }
      i += 1
    }
    guard options.samples > 0 else { throw BenchError.message("--samples must be > 0") }
    guard options.warmup >= 0 else { throw BenchError.message("--warmup must be >= 0") }
    guard options.cols > 0, options.rows > 0 else {
      throw BenchError.message("--cols and --rows must be > 0")
    }
    guard options.displayHz > 0 else { throw BenchError.message("--display-hz must be > 0") }
    if options.transport == .laband, options.socketPath == nil {
      throw BenchError.message("--transport laband requires --socket")
    }
    return options
  }
}

private enum BenchError: Error, CustomStringConvertible {
  case message(String)

  var description: String {
    switch self {
    case .message(let text): return text
    }
  }
}

private final class DirtyTracker: @unchecked Sendable {
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private var latestSequence = 0
  private var latestTimeNs: UInt64 = 0

  func currentSequence() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return latestSequence
  }

  func markDirty() {
    lock.lock()
    latestSequence += 1
    latestTimeNs = nowNs()
    lock.unlock()
    semaphore.signal()
  }

  func waitForNext(after sequence: Int, timeoutMs: Int) -> UInt64? {
    let timeout = DispatchTime.now() + .milliseconds(timeoutMs)
    while true {
      lock.lock()
      let seq = latestSequence
      let time = latestTimeNs
      lock.unlock()
      if seq > sequence { return time }
      if semaphore.wait(timeout: timeout) == .timedOut {
        return nil
      }
    }
  }
}

private struct Sample: Codable {
  var keyWriteMs: Double
  var ptyDrainMs: Double
  var syncMs: Double
  var makeFrameMs: Double
  var snapshotMs: Double
  var commandExtractionMs: Double
  var renderMs: Double
  var rawTotalMs: Double
  var estimatedCurrentAppCommitMs: Double
  var estimatedPhotonMeanMs: Double
  var commandCount: Int
  var verifiedEcho: Bool
}

private struct Summary: Codable {
  var mean: Double
  var p50: Double
  var p95: Double
  var p99: Double
  var min: Double
  var max: Double
}

private struct Report: Codable {
  var name: String
  var transport: Transport
  var date: String
  var samples: Int
  var warmup: Int
  var cols: Int
  var rows: Int
  var displayHz: Double
  var outputSettleQuietMs: Double
  var displayMeanWaitMs: Double
  var stages: [String: Summary]
  var rawSamples: [Sample]
}

private func nowNs() -> UInt64 {
  DispatchTime.now().uptimeNanoseconds
}

private func ms(_ ns: UInt64) -> Double {
  Double(ns) / 1_000_000.0
}

private func makeSize(cols: Int, rows: Int, cellWidth: Int = 0, cellHeight: Int = 0)
  -> LabanTerminalSize
{
  var size = LabanTerminalSize()
  size.cols = Int32(cols)
  size.rows = Int32(rows)
  size.cell_width = Int32(cellWidth)
  size.cell_height = Int32(cellHeight)
  size.pixel_width = Int32(cols * max(cellWidth, 0))
  size.pixel_height = Int32(rows * max(cellHeight, 0))
  return size
}

private func makeCatSession(size: LabanTerminalSize) throws -> Session {
  var config = LabanLaunchConfig()
  config.fixture_mode = 0
  let executable = "/bin/cat"
  let argv = ["/bin/cat"]
  return try executable.withCString { exePtr in
    try withCStringArray(argv) { argvPtr in
      config.executable = exePtr
      config.argv = argvPtr
      return try Session(config: &config, size: size)
    }
  }
}

private func withCStringArray<R>(
  _ strings: [String],
  _ body: (UnsafePointer<UnsafePointer<CChar>?>) throws -> R
) rethrows -> R {
  let cStrings = strings.map { strdup($0) }
  defer {
    for ptr in cStrings {
      if let ptr { free(ptr) }
    }
  }
  var pointers = cStrings.map { ptr -> UnsafePointer<CChar>? in
    guard let ptr else { return nil }
    return UnsafePointer(ptr)
  }
  pointers.append(nil)
  return try pointers.withUnsafeBufferPointer { buffer in
    try body(buffer.baseAddress!)
  }
}

private func keyForLetter(_ scalar: UnicodeScalar) -> Key {
  switch scalar {
  case "a": return .a
  case "b": return .b
  case "c": return .c
  case "d": return .d
  case "e": return .e
  case "f": return .f
  case "g": return .g
  case "h": return .h
  case "i": return .i
  case "j": return .j
  case "k": return .k
  case "l": return .l
  case "m": return .m
  case "n": return .n
  case "o": return .o
  case "p": return .p
  case "q": return .q
  case "r": return .r
  case "s": return .s
  case "t": return .t
  case "u": return .u
  case "v": return .v
  case "w": return .w
  case "x": return .x
  case "y": return .y
  default: return .z
  }
}

private func echoVerified(
  session: Session,
  sampleIndex: Int,
  cols: Int,
  rows: Int,
  expected: UnicodeScalar
) -> Bool {
  guard sampleIndex >= 0, sampleIndex < cols * rows else { return false }
  guard let snap = session.snapshot() else { return false }
  defer { laban_snapshot_destroy(snap) }
  let snapshot = snap.pointee
  guard Int(snapshot.rows) == rows, Int(snapshot.cols) == cols else { return false }
  let cellIndex = sampleIndex
  guard cellIndex >= 0, cellIndex < Int(snapshot.cell_count) else { return false }
  return snapshot.cells[cellIndex].codepoint == expected.value
}

private func summarize(_ values: [Double]) -> Summary {
  let sorted = values.sorted()
  let count = sorted.count
  let mean = sorted.reduce(0, +) / Double(max(count, 1))
  func percentile(_ p: Double) -> Double {
    guard count > 0 else { return 0 }
    let index = min(count - 1, max(0, Int((Double(count - 1) * p).rounded())))
    return sorted[index]
  }
  return Summary(
    mean: mean,
    p50: percentile(0.50),
    p95: percentile(0.95),
    p99: percentile(0.99),
    min: sorted.first ?? 0,
    max: sorted.last ?? 0
  )
}

private func printSummary(_ label: String, _ summary: Summary) {
  let padded = label.padding(toLength: 31, withPad: " ", startingAt: 0)
  print(
    String(
      format: "  %@ mean=%7.3f ms  p50=%7.3f  p95=%7.3f  p99=%7.3f  max=%7.3f",
      padded, summary.mean, summary.p50, summary.p95, summary.p99, summary.max))
}

private func writeReport(_ report: Report, to path: String) throws {
  let url = URL(fileURLWithPath: path)
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  let data = try encoder.encode(report)
  try data.write(to: url, options: .atomic)
}

private func runInProcess(options: Options) throws -> Report {
  let fontAtlas = FontAtlas(pointSize: 14)
  let cellSize = fontAtlas.cellSize
  let cellWidth = max(1, Int(cellSize.width))
  let cellHeight = max(1, Int(cellSize.height))
  let terminalSize = makeSize(
    cols: options.cols, rows: options.rows, cellWidth: cellWidth, cellHeight: cellHeight)
  let dirty = DirtyTracker()

  let model = try AppModel(initialSize: terminalSize) { size in
    try makeCatSession(size: size)
  }
  model.onSessionDirty = { _ in dirty.markDirty() }
  defer { model.closeAllSessions() }

  guard let tab = model.activeTab, let session = model.session(forTab: tab.id) else {
    throw BenchError.message("missing initial session")
  }

  let sidebarWidth = 200
  let surfaceWidth = sidebarWidth + options.cols * cellWidth
  let surfaceHeight = options.rows * cellHeight
  let surface = BitmapSurface(width: surfaceWidth, height: surfaceHeight)
  let renderer = SoftwareRenderer(surface: surface, fontAtlas: fontAtlas)
  let controller = TerminalSurfaceController(
    model: model,
    cellWidth: cellWidth,
    cellHeight: cellHeight,
    sidebarWidth: CGFloat(sidebarWidth),
    sidebarCellWidth: cellSize.width,
    sidebarCellHeight: cellSize.height
  )

  func renderFrame(frame: Int) -> (
    syncMs: Double, makeFrameMs: Double, snapshotMs: Double, commandExtractionMs: Double,
    renderMs: Double, commandCount: Int, terminalFrame: TerminalSurfaceFrame?
  ) {
    let syncStart = nowNs()
    _ = controller.syncSessions(
      captureFrame: frame,
      polling: .none,
      markInactiveDirtyRendered: false,
      noteOutputOnDirty: true,
      recordTitleChanges: false
    )
    let syncEnd = nowNs()

    let makeStart = nowNs()
    let terminalFrame = controller.makeFrame(
      TerminalSurfaceFrameRequest(
        frame: frame,
        viewportWidth: CGFloat(surfaceWidth),
        viewportHeight: CGFloat(surfaceHeight),
        cursorBlinkVisible: true,
        includeTerminalAreaBackground: true,
        requireActiveSnapshot: true,
        forceFullDamage: true,
        surfaceWidth: surface.width,
        surfaceHeight: surface.height,
        surfaceScale: Double(surface.scale)
      ))
    let makeEnd = nowNs()

    let renderStart = nowNs()
    renderer.render(terminalFrame?.commands ?? [])
    let renderEnd = nowNs()
    _ = session.markRendered()

    let makeFrameMs = ms(makeEnd &- makeStart)
    let snapshotMs = terminalFrame?.snapshotMs ?? 0
    return (
      syncMs: ms(syncEnd &- syncStart),
      makeFrameMs: makeFrameMs,
      snapshotMs: snapshotMs,
      commandExtractionMs: max(0, makeFrameMs - snapshotMs),
      renderMs: ms(renderEnd &- renderStart),
      commandCount: terminalFrame?.commands.count ?? 0,
      terminalFrame: terminalFrame
    )
  }

  _ = renderFrame(frame: 0)

  let letters = Array("abcdefghijklmnopqrstuvwxyz".unicodeScalars)
  let total = options.warmup + options.samples
  var measured: [Sample] = []
  measured.reserveCapacity(options.samples)
  let displayMeanWaitMs = 1000.0 / options.displayHz / 2.0

  for index in 0..<total {
    let scalar = letters[index % letters.count]
    let text = String(scalar)
    let beforeSeq = dirty.currentSequence()
    let t0 = nowNs()
    let keyStart = t0
    let write = session.sendKeyCapturingBytes(
      KeyEvent(
        key: keyForLetter(scalar),
        unshiftedCodepoint: scalar.value,
        text: text))
    let keyEnd = nowNs()
    guard write.result == 0, write.bytes.count == text.utf8.count else {
      throw BenchError.message("key write failed at sample \(index)")
    }
    guard let dirtyAt = dirty.waitForNext(after: beforeSeq, timeoutMs: 1_000) else {
      throw BenchError.message("timed out waiting for PTY echo at sample \(index)")
    }
    let rendered = renderFrame(frame: index + 1)
    let tRendered = nowNs()
    let rawTotalMs = ms(tRendered &- t0)
    let appCommitMs = rawTotalMs + outputSettleQuietMs
    let sample = Sample(
      keyWriteMs: ms(keyEnd &- keyStart),
      ptyDrainMs: ms(dirtyAt &- keyEnd),
      syncMs: rendered.syncMs,
      makeFrameMs: rendered.makeFrameMs,
      snapshotMs: rendered.snapshotMs,
      commandExtractionMs: rendered.commandExtractionMs,
      renderMs: rendered.renderMs,
      rawTotalMs: rawTotalMs,
      estimatedCurrentAppCommitMs: appCommitMs,
      estimatedPhotonMeanMs: appCommitMs + displayMeanWaitMs,
      commandCount: rendered.commandCount,
      verifiedEcho: echoVerified(
        session: session,
        sampleIndex: index,
        cols: options.cols,
        rows: options.rows,
        expected: scalar)
    )
    if index >= options.warmup {
      measured.append(sample)
    }
  }

  let stages: [(String, (Sample) -> Double)] = [
    ("keyWriteMs", { $0.keyWriteMs }),
    ("ptyDrainMs", { $0.ptyDrainMs }),
    ("syncMs", { $0.syncMs }),
    ("makeFrameMs", { $0.makeFrameMs }),
    ("snapshotMs", { $0.snapshotMs }),
    ("commandExtractionMs", { $0.commandExtractionMs }),
    ("renderMs", { $0.renderMs }),
    ("rawTotalMs", { $0.rawTotalMs }),
    ("estimatedCurrentAppCommitMs", { $0.estimatedCurrentAppCommitMs }),
    ("estimatedPhotonMeanMs", { $0.estimatedPhotonMeanMs }),
  ]
  var summaries: [String: Summary] = [:]
  for (name, pick) in stages {
    summaries[name] = summarize(measured.map(pick))
  }

  return Report(
    name: "bench-keystroke-latency",
    transport: options.transport,
    date: ISO8601DateFormatter().string(from: Date()),
    samples: options.samples,
    warmup: options.warmup,
    cols: options.cols,
    rows: options.rows,
    displayHz: options.displayHz,
    outputSettleQuietMs: outputSettleQuietMs,
    displayMeanWaitMs: displayMeanWaitMs,
    stages: summaries,
    rawSamples: measured
  )
}

private final class OwnedLabandDaemon {
  let process: Process?

  init(process: Process?) {
    self.process = process
  }

  func stop(client: LabandTerminalSessionClient?) {
    if let client, process != nil {
      try? client.shutdownWhenIdle()
      client.close()
    } else {
      client?.close()
    }
    guard let process, process.isRunning else { return }
    process.terminate()
    process.waitUntilExit()
  }
}

private func run(options: Options) throws -> Report {
  switch options.transport {
  case .inProcess:
    return try runInProcess(options: options)
  case .laband:
    return try runLaband(options: options)
  case .labpty:
    throw BenchError.message("--transport labpty is added in the labpty bench milestone")
  }
}

private func runLaband(options: Options) throws -> Report {
  guard let socketPath = options.socketPath else {
    throw BenchError.message("--transport laband requires --socket")
  }
  let fontAtlas = FontAtlas(pointSize: 14)
  let cellSize = fontAtlas.cellSize
  let cellWidth = max(1, Int(cellSize.width))
  let cellHeight = max(1, Int(cellSize.height))
  let sidebarWidth = 200
  let surfaceWidth = sidebarWidth + options.cols * cellWidth
  let surfaceHeight = options.rows * cellHeight
  let surface = BitmapSurface(width: surfaceWidth, height: surfaceHeight)
  let renderer = SoftwareRenderer(surface: surface, fontAtlas: fontAtlas)

  let daemon = try ensureLabandDaemon(socketPath: socketPath)
  var client: LabandTerminalSessionClient?
  do {
    client = try waitForLabandClient(socketPath: socketPath, timeoutMs: 5_000)
    guard let client else { throw BenchError.message("failed to connect to laband") }
    let session = try client.createSession(
      TerminalSessionLaunchRequest(
        executable: "/bin/cat",
        argv: ["/bin/cat"],
        cwd: FileManager.default.currentDirectoryPath,
        rows: options.rows,
        cols: options.cols
      ))
    defer {
      _ = try? client.terminate(sessionId: session.logicalSessionId)
      daemon.stop(client: client)
    }

    _ = try client.attachSnapshotRing(sessionId: session.logicalSessionId)
    let reader = try client.snapshotRingReader(sessionId: session.logicalSessionId)
    _ = try? reader.latestSnapshot()

    let letters = Array("abcdefghijklmnopqrstuvwxyz".unicodeScalars)
    let total = options.warmup + options.samples
    var measured: [Sample] = []
    measured.reserveCapacity(options.samples)
    let displayMeanWaitMs = 1000.0 / options.displayHz / 2.0

    for index in 0..<total {
      let scalar = letters[index % letters.count]
      let text = String(scalar)
      let t0 = nowNs()
      let keyStart = t0
      try client.writeInput(sessionId: session.logicalSessionId, bytes: Array(text.utf8))
      let keyEnd = nowNs()
      let waited = try waitForLabandEcho(
        reader: reader,
        sampleIndex: index,
        cols: options.cols,
        rows: options.rows,
        expected: scalar,
        timeoutMs: 1_000
      )
      let rendered = renderLabandCellFrame(
        cell: waited.cell,
        renderer: renderer,
        sidebarWidth: sidebarWidth,
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        rows: options.rows,
        cols: options.cols
      )
      let tRendered = nowNs()
      let rawTotalMs = ms(tRendered &- t0)
      let appCommitMs = rawTotalMs + outputSettleQuietMs
      let sample = Sample(
        keyWriteMs: ms(keyEnd &- keyStart),
        ptyDrainMs: ms(waited.observedAt &- keyEnd),
        syncMs: 0,
        makeFrameMs: rendered.makeFrameMs,
        snapshotMs: waited.snapshotMs,
        commandExtractionMs: rendered.makeFrameMs,
        renderMs: rendered.renderMs,
        rawTotalMs: rawTotalMs,
        estimatedCurrentAppCommitMs: appCommitMs,
        estimatedPhotonMeanMs: appCommitMs + displayMeanWaitMs,
        commandCount: rendered.commandCount,
        verifiedEcho: true
      )
      if index >= options.warmup {
        measured.append(sample)
      }
    }

    return makeReport(options: options, measured: measured, displayMeanWaitMs: displayMeanWaitMs)
  } catch {
    daemon.stop(client: client)
    throw error
  }
}

private func makeReport(
  options: Options,
  measured: [Sample],
  displayMeanWaitMs: Double
) -> Report {
  let stages: [(String, (Sample) -> Double)] = [
    ("keyWriteMs", { $0.keyWriteMs }),
    ("ptyDrainMs", { $0.ptyDrainMs }),
    ("syncMs", { $0.syncMs }),
    ("makeFrameMs", { $0.makeFrameMs }),
    ("snapshotMs", { $0.snapshotMs }),
    ("commandExtractionMs", { $0.commandExtractionMs }),
    ("renderMs", { $0.renderMs }),
    ("rawTotalMs", { $0.rawTotalMs }),
    ("estimatedCurrentAppCommitMs", { $0.estimatedCurrentAppCommitMs }),
    ("estimatedPhotonMeanMs", { $0.estimatedPhotonMeanMs }),
  ]
  var summaries: [String: Summary] = [:]
  for (name, pick) in stages {
    summaries[name] = summarize(measured.map(pick))
  }

  return Report(
    name: "bench-keystroke-latency",
    transport: options.transport,
    date: ISO8601DateFormatter().string(from: Date()),
    samples: options.samples,
    warmup: options.warmup,
    cols: options.cols,
    rows: options.rows,
    displayHz: options.displayHz,
    outputSettleQuietMs: outputSettleQuietMs,
    displayMeanWaitMs: displayMeanWaitMs,
    stages: summaries,
    rawSamples: measured
  )
}

private func renderLabandCellFrame(
  cell: LabandSnapshotRingCellRead,
  renderer: SoftwareRenderer,
  sidebarWidth: Int,
  cellWidth: Int,
  cellHeight: Int,
  rows: Int,
  cols: Int
) -> (makeFrameMs: Double, renderMs: Double, commandCount: Int) {
  let makeStart = nowNs()
  let cw = CGFloat(cellWidth)
  let ch = CGFloat(cellHeight)
  var commands: [FrameCommand] = [
    .rect(
      CGRect(
        x: CGFloat(sidebarWidth),
        y: 0,
        width: CGFloat(cols * cellWidth),
        height: CGFloat(rows * cellHeight)
      ),
      color: 0x000000ff,
      source: .terminal
    )
  ]
  commands.reserveCapacity(3)
  if !cell.text.isEmpty {
    commands.append(
      .glyphRun(
        origin: CGPoint(x: CGFloat(sidebarWidth + cell.col * cellWidth), y: CGFloat(cell.row + 1) * ch),
        text: cell.text,
        foreground: cell.foregroundRGBA,
        background: cell.backgroundRGBA,
        attributes: TextAttributes(rawValue: cell.flags),
        source: .terminal
      ))
  }
  commands.append(
    .cursor(
      CGRect(
        x: CGFloat(sidebarWidth + cell.col * cellWidth),
        y: CGFloat(cell.row * cellHeight),
        width: cw,
        height: ch
      ),
      color: 0xffffffff
    ))
  let makeEnd = nowNs()
  let renderStart = nowNs()
  renderer.render(commands)
  let renderEnd = nowNs()
  return (ms(makeEnd &- makeStart), ms(renderEnd &- renderStart), commands.count)
}

private func waitForLabandEcho(
  reader: LabandSnapshotRingReader,
  sampleIndex: Int,
  cols: Int,
  rows: Int,
  expected: UnicodeScalar,
  timeoutMs: Int
) throws -> (cell: LabandSnapshotRingCellRead, snapshotMs: Double, observedAt: UInt64) {
  let deadline = nowNs() + UInt64(timeoutMs) * 1_000_000
  let row = sampleIndex / cols
  let col = sampleIndex % cols
  while nowNs() < deadline {
    let snapshotStart = nowNs()
    if let cell = try? reader.cell(row: row, col: col) {
      let snapshotEnd = nowNs()
      if cell.rows == rows, cell.cols == cols, cell.text.unicodeScalars.first == expected {
        return (cell, ms(snapshotEnd &- snapshotStart), snapshotEnd)
      }
    }
    usleep(100)
  }
  throw BenchError.message("timed out waiting for laband PTY echo at sample \(sampleIndex)")
}

private func echoVerified(
  snapshot: LabandSnapshotResponse,
  sampleIndex: Int,
  cols: Int,
  rows: Int,
  expected: UnicodeScalar
) -> Bool {
  guard snapshot.rows == rows, snapshot.cols == cols else { return false }
  guard sampleIndex >= 0, sampleIndex < min(cols * rows, snapshot.cells.count) else {
    return false
  }
  return snapshot.cells[sampleIndex].text.unicodeScalars.first == expected
}

private func ensureLabandDaemon(socketPath: String) throws -> OwnedLabandDaemon {
  if let client = try? LabandTerminalSessionClient(socketPath: socketPath) {
    _ = try? client.hello()
    client.close()
    return OwnedLabandDaemon(process: nil)
  }

  let binary = try labandBinaryPath()
  try FileManager.default.createDirectory(
    at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  unlink(socketPath)
  let journalPath = try journalPathForSocket(socketPath)
  try FileManager.default.createDirectory(
    atPath: journalPath,
    withIntermediateDirectories: true
  )
  let process = Process()
  process.executableURL = URL(fileURLWithPath: binary)
  process.arguments = ["--socket", socketPath, "--journal", journalPath]
  try process.run()
  _ = try waitForLabandClient(socketPath: socketPath, timeoutMs: 5_000)
  return OwnedLabandDaemon(process: process)
}

private func waitForLabandClient(socketPath: String, timeoutMs: Int) throws -> LabandTerminalSessionClient {
  let deadline = nowNs() + UInt64(timeoutMs) * 1_000_000
  var lastError: Error?
  while nowNs() < deadline {
    do {
      let client = try LabandTerminalSessionClient(socketPath: socketPath)
      _ = try client.hello()
      return client
    } catch {
      lastError = error
      usleep(10_000)
    }
  }
  throw BenchError.message("timed out connecting to laband: \(String(describing: lastError))")
}

private func journalPathForSocket(_ socketPath: String) throws -> String {
  let components = socketPath.split(separator: "/").map(String.init).filter { !$0.isEmpty }
  guard components.count >= 3 else {
    throw BenchError.message(
      "--socket must be run-id scoped, for example .tmp/<run-id>/laband.sock")
  }
  let runId = components[components.count - 2]
  guard runId != ".tmp", runId != "tmp", runId != ".", runId != ".." else {
    throw BenchError.message(
      "--socket must include a run id under .tmp/<run-id>/laband.sock")
  }
  return ".artifacts/runs/\(runId)/laband"
}

private func labandBinaryPath() throws -> String {
  let candidates = [
    ".build/release/laband",
    ".build/debug/laband",
  ]
  for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
    return candidate
  }
  let build = Process()
  build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  build.arguments = ["swift", "build", "-c", "release", "--product", "laband"]
  try build.run()
  build.waitUntilExit()
  guard build.terminationStatus == 0 else {
    throw BenchError.message("failed to build laband helper")
  }
  guard FileManager.default.isExecutableFile(atPath: ".build/release/laband") else {
    throw BenchError.message("laband helper was not built at .build/release/laband")
  }
  return ".build/release/laband"
}

do {
  let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
  let report = try run(options: options)
  print("bench-keystroke-latency")
  print(
    "  transport=\(report.transport.rawValue) samples=\(report.samples) warmup=\(report.warmup) grid=\(report.cols)x\(report.rows)"
  )
  print(
    String(
      format:
        "  estimates: output-settle=%.3f ms, display mean wait @ %.1fHz=%.3f ms",
      report.outputSettleQuietMs, report.displayHz, report.displayMeanWaitMs))
  for name in [
    "keyWriteMs",
    "ptyDrainMs",
    "syncMs",
    "snapshotMs",
    "commandExtractionMs",
    "renderMs",
    "rawTotalMs",
    "estimatedCurrentAppCommitMs",
    "estimatedPhotonMeanMs",
  ] {
    if let summary = report.stages[name] {
      printSummary(name, summary)
    }
  }
  let verified = report.rawSamples.filter(\.verifiedEcho).count
  print("  verifiedEcho=\(verified)/\(report.rawSamples.count)")
  if verified != report.rawSamples.count {
    throw BenchError.message(
      "echo verification failed for \(report.rawSamples.count - verified) measured samples")
  }
  if let path = options.jsonPath {
    try writeReport(report, to: path)
    print("  json=\(path)")
  }
} catch {
  fputs("bench-keystroke-latency: \(error)\n", stderr)
  exit(1)
}
