import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import LabanCore
import LabanRenderer
import LabanTerminalCore

public enum CaptureScreenshotPolicy: String, Codable, Sendable {
  case final
  case marked
  case all
  case none
}

public enum CaptureRecorderError: Error, Equatable {
  case invalidName
  case outsideArtifactRoot
  case alreadyFinished
  case missingManifest
}

public final class CaptureRecorder: CaptureSink {
  public let runId: String
  public let directoryURL: URL
  public let screenshots: CaptureScreenshotPolicy

  private let lock = NSLock()
  private let createdAt = Date()
  private let executable: String
  private let buildConfiguration: String
  private let gitSha: String

  private var sequence = 0
  private var eventCount = 0
  private var frames: Set<Int> = []
  private var finished = false
  private var interrupted = false

  private let timelineURL: URL
  private let manifestURL: URL
  private let manifestTmpURL: URL
  private var timelineHandle: FileHandle
  private var streamHandles: [CaptureByteDirection: FileHandle] = [:]
  private var streamOffsets: [CaptureByteDirection: Int] = [:]
  private var streamHashers: [CaptureByteDirection: SHA256] = [:]

  public init(
    artifactRoot: URL,
    name: String? = nil,
    screenshots: CaptureScreenshotPolicy = .marked,
    executable: String = ProcessInfo.processInfo.processName,
    buildConfiguration: String = "debug",
    gitSha: String = "unknown"
  ) throws {
    self.runId = CaptureRecorder.makeRunId(name: name)
    self.screenshots = screenshots
    self.executable = executable
    self.buildConfiguration = buildConfiguration
    self.gitSha = gitSha

    let root = artifactRoot.standardizedFileURL
    let captureDir = root.appendingPathComponent(runId, isDirectory: true)
    self.directoryURL = captureDir
    self.timelineURL = captureDir.appendingPathComponent("timeline.ndjson")
    self.manifestURL = captureDir.appendingPathComponent("manifest.json")
    self.manifestTmpURL = captureDir.appendingPathComponent("manifest.json.tmp")

    try CaptureRecorder.createPrivateDirectory(root)
    try CaptureRecorder.createPrivateDirectory(captureDir)
    try CaptureRecorder.createPrivateDirectory(captureDir.appendingPathComponent("streams"))
    try CaptureRecorder.createPrivateDirectory(captureDir.appendingPathComponent("frames"))
    try CaptureRecorder.createPrivateDirectory(captureDir.appendingPathComponent("snapshots"))
    try CaptureRecorder.createPrivateDirectory(captureDir.appendingPathComponent("replay"))

    CaptureRecorder.createPrivateFile(timelineURL)
    self.timelineHandle = try FileHandle(forWritingTo: timelineURL)

    for direction in [CaptureByteDirection.ptyInput, .ptyOutput, .terminalResponse] {
      let url = captureDir.appendingPathComponent("streams")
        .appendingPathComponent(direction.streamFileName)
      CaptureRecorder.createPrivateFile(url)
      streamHandles[direction] = try FileHandle(forWritingTo: url)
      streamOffsets[direction] = 0
      streamHashers[direction] = SHA256()
    }

    try writeManifestLocked(finishedAt: nil, interrupted: false, final: false)
    record(CaptureTimelineEvent(kind: .captureStarted))
  }

  deinit {
    if !finished {
      _ = try? finish(interrupted: true)
    }
  }

  public static func makeRunId(name: String?) -> String {
    if let name, !name.isEmpty {
      let safe = name.map { ch -> Character in
        if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == "." { return ch }
        return "-"
      }
      .reduce(into: "") { $0.append($1) }
      if !safe.isEmpty { return safe }
    }
    let fmt = DateFormatter()
    fmt.calendar = Calendar(identifier: .gregorian)
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(secondsFromGMT: 0)
    fmt.dateFormat = "yyyyMMdd-HHmmss"
    return "capture-\(fmt.string(from: Date()))-\(UUID().uuidString.prefix(8))"
  }

  public static func validateCaptureName(_ name: String) throws {
    guard !name.isEmpty else { throw CaptureRecorderError.invalidName }
    guard !name.contains("/") && !name.contains("\\") && name != "." && name != ".." else {
      throw CaptureRecorderError.outsideArtifactRoot
    }
  }

  public var manifestPath: String { manifestURL.path }
  public var timelinePath: String { timelineURL.path }

  public func nextSequence() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return nextSequenceLocked()
  }

  public func record(_ event: CaptureTimelineEvent) {
    lock.lock()
    defer { lock.unlock() }
    guard !finished else { return }
    writeEventLocked(event)
  }

  public func recordInput(_ envelope: InputEventEnvelope) {
    record(CaptureTimelineEvent(input: envelope))
  }

  public func recordBytes(
    direction: CaptureByteDirection,
    sessionId: Session.ID?,
    frame: Int,
    bytes: UnsafeRawBufferPointer,
    preview: String?
  ) -> CaptureByteRef? {
    guard bytes.count > 0, let base = bytes.baseAddress else { return nil }
    let data = Data(bytes: base, count: bytes.count)

    lock.lock()
    defer { lock.unlock() }
    guard !finished, let handle = streamHandles[direction] else { return nil }
    let offset = streamOffsets[direction] ?? 0
    do {
      try handle.write(contentsOf: data)
      streamOffsets[direction] = offset + data.count
      if var hasher = streamHashers[direction] {
        hasher.update(data: data)
        streamHashers[direction] = hasher
      }
    } catch {
      var event = CaptureTimelineEvent(kind: .captureError, frame: frame, sessionId: sessionId)
      event.error = "byte stream write failed: \(error)"
      writeEventLocked(event)
      return nil
    }

    let ref = CaptureByteRef(
      stream: direction.rawValue,
      path: "streams/\(direction.streamFileName)",
      offset: offset,
      length: data.count,
      sha256: CaptureHash.sha256(data),
      escapedPreview: preview ?? CaptureRecorder.escapedPreview(data)
    )
    var event = CaptureTimelineEvent(
      kind: direction.eventKind,
      frame: frame,
      sessionId: sessionId
    )
    event.stream = ref.stream
    event.path = ref.path
    event.offset = ref.offset
    event.length = ref.length
    event.sha256 = ref.sha256
    event.escapedPreview = ref.escapedPreview
    writeEventLocked(event)
    return ref
  }

  @discardableResult
  public func recordFrameCommands(
    frame: Int,
    commands: [FrameCommand],
    surfaceWidth: Int,
    surfaceHeight: Int,
    scale: Double,
    backend: String = "software"
  ) -> CaptureFrameRef? {
    let payload = CapturedFrameCommands(
      frame: frame,
      backend: backend,
      surface: CapturedSurface(width: surfaceWidth, height: surfaceHeight, scale: scale),
      commands: FrameCommandCaptureCodec.serialized(commands)
    )
    guard let data = try? FrameCommandCaptureCodec.encoder.encode(payload) else { return nil }
    let rel = String(format: "frames/frame-%06d.commands.json", frame)
    guard let hash = try? writeSidecar(data: data, relativePath: rel) else { return nil }
    lock.lock()
    defer { lock.unlock() }
    frames.insert(frame)
    var event = CaptureTimelineEvent(kind: .frameCommands, frame: frame)
    event.path = rel
    event.sha256 = hash
    event.commandCount = commands.count
    event.width = surfaceWidth
    event.height = surfaceHeight
    event.scale = scale
    event.backend = backend
    writeEventLocked(event)
    return CaptureFrameRef(path: rel, sha256: hash, commandCount: commands.count)
  }

  @discardableResult
  public func recordTerminalSnapshot(
    frame: Int,
    tabId: String?,
    sessionId: String?,
    snapshot: UnsafePointer<LabanSnapshot>
  ) -> String? {
    let visible = TerminalSnapshotText.visibleText(from: snapshot, mode: .fullGrid)
    let visibleHash = CaptureHash.sha256(Data(visible.utf8))
    let snap = snapshot.pointee
    let payload = CapturedTerminalSnapshot(
      frame: frame,
      sessionId: sessionId,
      rows: Int(snap.rows),
      cols: Int(snap.cols),
      cursorRow: Int(snap.cursor_row),
      cursorCol: Int(snap.cursor_col),
      cursorVisible: snap.cursor_visible != 0,
      title: snap.title.flatMap { String(cString: $0) },
      status: CaptureRecorder.statusString(snap.status),
      mouseTracking: snap.mouse_tracking != 0,
      focusReporting: snap.focus_reporting != 0,
      dirty: snap.dirty != 0,
      visibleText: visible,
      visibleHash: visibleHash
    )
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    guard let data = try? enc.encode(payload) else { return nil }
    let rel = String(format: "frames/frame-%06d.snapshot.json", frame)
    guard let hash = try? writeSidecar(data: data, relativePath: rel) else { return nil }
    lock.lock()
    defer { lock.unlock() }
    var event = CaptureTimelineEvent(
      kind: .terminalSnapshot,
      frame: frame,
      tabId: tabId,
      sessionId: sessionId
    )
    event.path = rel
    event.sha256 = hash
    event.rows = payload.rows
    event.cols = payload.cols
    event.cursorRow = payload.cursorRow
    event.cursorCol = payload.cursorCol
    event.cursorVisible = payload.cursorVisible
    event.title = payload.title
    event.status = payload.status
    event.mouseTracking = payload.mouseTracking
    event.focusReporting = payload.focusReporting
    event.dirty = payload.dirty
    event.visibleHash = visibleHash
    writeEventLocked(event)
    return visibleHash
  }

  /// Backend-neutral rendered-frame recorder: anything that can produce
  /// PNG bytes + surface metrics can call this. Software callers pipe the
  /// `BitmapSurface.pngData` accessor; Metal callers pipe a blit-readback PNG.
  public func recordRenderedFrame(
    frame: Int,
    pngData: Data?,
    width: Int,
    height: Int,
    scale: Double,
    backend: String
  ) {
    let pixelHash = pngData.map(CaptureHash.sha256)
    let payload = CapturedRenderFrame(
      frame: frame,
      backend: backend,
      surface: CapturedSurface(width: width, height: height, scale: scale),
      pixelHash: pixelHash
    )
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    if let data = try? enc.encode(payload) {
      let rel = String(format: "frames/frame-%06d.render.json", frame)
      _ = try? writeSidecar(data: data, relativePath: rel)
    }
    lock.lock()
    var event = CaptureTimelineEvent(kind: .frameRendered, frame: frame)
    event.width = width
    event.height = height
    event.scale = scale
    event.backend = backend
    event.pixelHash = pixelHash
    writeEventLocked(event)
    lock.unlock()

    if screenshots == .all, let png = pngData {
      _ = recordScreenshot(frame: frame, data: png)
    }
  }

  /// Convenience for software callers that already have a `BitmapSurface`.
  public func recordRenderedFrame(
    frame: Int,
    surface: BitmapSurface,
    backend: String = "software"
  ) {
    recordRenderedFrame(
      frame: frame,
      pngData: surface.pngData,
      width: surface.width,
      height: surface.height,
      scale: Double(surface.scale),
      backend: backend)
  }

  @discardableResult
  public func recordScreenshot(frame: Int, data: Data) -> String? {
    let rel = String(format: "frames/frame-%06d.png", frame)
    guard let hash = try? writeSidecar(data: data, relativePath: rel) else { return nil }
    lock.lock()
    defer { lock.unlock() }
    var event = CaptureTimelineEvent(kind: .screenshotCaptured, frame: frame)
    event.path = rel
    event.sha256 = hash
    event.length = data.count
    writeEventLocked(event)
    return rel
  }

  public func writeSnapshotBundle(frame: Int, files: [String: Data]) throws -> String {
    let relDir = String(format: "snapshots/snapshot-%06d", frame)
    for (name, data) in files {
      _ = try writeSidecar(data: data, relativePath: "\(relDir)/\(name)")
    }
    let manifest = ["frame": frame, "files": Array(files.keys).sorted()] as [String: Any]
    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
    _ = try writeSidecar(data: data, relativePath: "\(relDir)/manifest.json")
    lock.lock()
    defer { lock.unlock() }
    var event = CaptureTimelineEvent(kind: .captureSnapshot, frame: frame)
    event.path = relDir
    writeEventLocked(event)
    return relDir
  }

  public func finish(interrupted: Bool = false, finalScreenshot: Data? = nil, frame: Int? = nil)
    throws -> URL
  {
    lock.lock()
    defer { lock.unlock() }
    guard !finished else { return manifestURL }
    self.interrupted = interrupted
    if let finalScreenshot, let frame {
      lock.unlock()
      _ = recordScreenshot(frame: frame, data: finalScreenshot)
      lock.lock()
    }
    var event = CaptureTimelineEvent(kind: .captureFinished, frame: frame)
    event.interrupted = interrupted
    writeEventLocked(event)
    for handle in streamHandles.values { try? handle.synchronize() }
    try? timelineHandle.synchronize()
    try writeManifestLocked(finishedAt: Date(), interrupted: interrupted, final: true)
    try? timelineHandle.close()
    for handle in streamHandles.values { try? handle.close() }
    finished = true
    return manifestURL
  }

  private func nextSequenceLocked() -> Int {
    let value = sequence
    sequence += 1
    return value
  }

  private func writeEventLocked(_ input: CaptureTimelineEvent) {
    var event = input
    if event.seq < 0 {
      event.seq = nextSequenceLocked()
    } else if event.seq >= sequence {
      sequence = event.seq + 1
    }
    if event.timeNs == 0 {
      event.timeNs = CaptureClock.nowNs()
    }
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    guard let data = try? enc.encode(event) else { return }
    do {
      try timelineHandle.write(contentsOf: data)
      try timelineHandle.write(contentsOf: Data([0x0A]))
      eventCount += 1
    } catch {
      // The recorder must not crash the terminal app. A later manifest will
      // expose the shorter event count and replay will stop at the last JSON line.
    }
  }

  private func writeSidecar(data: Data, relativePath: String) throws -> String {
    let url = directoryURL.appendingPathComponent(relativePath)
    try CaptureRecorder.createPrivateDirectory(url.deletingLastPathComponent())
    try data.write(to: url, options: [.atomic])
    chmod(url.path, S_IRUSR | S_IWUSR)
    return CaptureHash.sha256(data)
  }

  private func writeManifestLocked(finishedAt: Date?, interrupted: Bool, final: Bool) throws {
    let streams = CaptureManifest.Streams(
      ptyInput: streamManifest(.ptyInput),
      ptyOutput: streamManifest(.ptyOutput),
      terminalResponse: streamManifest(.terminalResponse)
    )
    let sortedFrames = frames.sorted()
    let manifest = CaptureManifest(
      runId: runId,
      createdAt: CaptureRecorder.iso8601(createdAt),
      finishedAt: finishedAt.map(CaptureRecorder.iso8601),
      interrupted: interrupted,
      app: CaptureManifest.App(
        gitSha: gitSha, buildConfiguration: buildConfiguration, executable: executable),
      privacy: CaptureManifest.Privacy(
        containsTerminalBytes: true,
        containsScreenshots: screenshots != .none,
        redaction: "none"),
      timeline: CaptureManifest.Timeline(path: "timeline.ndjson", events: eventCount),
      streams: streams,
      frames: CaptureManifest.Frames(
        count: sortedFrames.count,
        first: sortedFrames.first,
        last: sortedFrames.last)
    )
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try enc.encode(manifest)
    try data.write(to: manifestTmpURL, options: [.atomic])
    chmod(manifestTmpURL.path, S_IRUSR | S_IWUSR)
    if final {
      try? FileManager.default.removeItem(at: manifestURL)
      try FileManager.default.moveItem(at: manifestTmpURL, to: manifestURL)
      chmod(manifestURL.path, S_IRUSR | S_IWUSR)
    }
  }

  private func streamManifest(_ direction: CaptureByteDirection) -> CaptureManifest.Stream {
    let rel = "streams/\(direction.streamFileName)"
    let digest = streamHashers[direction]?.finalize() ?? SHA256.hash(data: Data())
    return CaptureManifest.Stream(
      path: rel,
      sha256: CaptureHash.hex(digest),
      bytes: streamOffsets[direction] ?? 0)
  }

  private static func createPrivateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    chmod(url.path, S_IRWXU)
  }

  private static func createPrivateFile(_ url: URL) {
    FileManager.default.createFile(
      atPath: url.path,
      contents: Data(),
      attributes: [.posixPermissions: 0o600]
    )
    chmod(url.path, S_IRUSR | S_IWUSR)
  }

  private static func iso8601(_ date: Date) -> String {
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fmt.string(from: date)
  }

  private static func statusString(_ status: Int32) -> String {
    switch status {
    case 1: return "exited"
    case 2: return "signaled"
    default: return "running"
    }
  }

  private static func escapedPreview(_ data: Data) -> String {
    var out = ""
    for byte in data.prefix(80) {
      switch byte {
      case 0x0A: out += "\\n"
      case 0x0D: out += "\\r"
      case 0x09: out += "\\t"
      case 0x1B: out += "\\u{1B}"
      case 0x20...0x7E:
        out.append(Character(UnicodeScalar(byte)))
      default:
        out += String(format: "\\x%02x", byte)
      }
    }
    return out
  }

}

enum CaptureHash {
  static func sha256(_ data: Data) -> String {
    hex(SHA256.hash(data: data))
  }

  static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined()
  }
}

private struct CaptureManifest: Encodable {
  var schemaVersion = 1
  var kind = "laban-capture"
  var runId: String
  var createdAt: String
  var finishedAt: String?
  var interrupted: Bool
  var app: App
  var privacy: Privacy
  var timeline: Timeline
  var streams: Streams
  var frames: Frames

  struct App: Encodable {
    var gitSha: String
    var buildConfiguration: String
    var executable: String
  }

  struct Privacy: Encodable {
    var containsTerminalBytes: Bool
    var containsScreenshots: Bool
    var redaction: String
  }

  struct Timeline: Encodable {
    var path: String
    var events: Int
  }

  struct Stream: Encodable {
    var path: String
    var sha256: String
    var bytes: Int
  }

  struct Streams: Encodable {
    var ptyInput: Stream
    var ptyOutput: Stream
    var terminalResponse: Stream
  }

  struct Frames: Encodable {
    var count: Int
    var first: Int?
    var last: Int?
  }
}

public struct CapturedSurface: Codable, Equatable, Sendable {
  public var width: Int
  public var height: Int
  public var scale: Double
}

public struct CapturedFrameCommands: Codable, Equatable, Sendable {
  public var schemaVersion = 1
  public var frame: Int
  public var backend: String
  public var surface: CapturedSurface
  public var commands: [CapturedFrameCommand]
}

public struct CapturedFrameCommand: Codable, Equatable, Sendable {
  public var index: Int
  public var kind: String
  public var source: String
  public var rect: CapturedRect?
  public var color: UInt32?
  public var foreground: UInt32?
  public var background: UInt32?
  public var text: String?
  public var resourceId: UInt64?
  public var attributes: [String]?
  public var underlineStyle: String?
  public var underlineColor: UInt32?
  public var hyperlink: String?
}

public struct CapturedRect: Codable, Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double

  init(_ rect: CGRect) {
    self.x = Double(rect.origin.x)
    self.y = Double(rect.origin.y)
    self.width = Double(rect.size.width)
    self.height = Double(rect.size.height)
  }

  var cgRect: CGRect {
    CGRect(x: x, y: y, width: width, height: height)
  }
}

public enum FrameCommandCaptureCodec {
  public static let encoder: JSONEncoder = {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    return enc
  }()

  public static func serialized(_ commands: [FrameCommand]) -> [CapturedFrameCommand] {
    commands.enumerated().map { index, command in
      switch command {
      case .rect(let rect, let color, let source):
        return CapturedFrameCommand(
          index: index, kind: "rect", source: source.rawValue,
          rect: CapturedRect(rect), color: color)
      case .glyphRun(
        let origin, let text, let foreground, let background, let attributes, let source,
        let underlineStyle, let underlineColor, let hyperlink
      ):
        let attrNames = attributes.names
        return CapturedFrameCommand(
          index: index, kind: "glyphRun", source: source.rawValue,
          rect: CapturedRect(CGRect(x: origin.x, y: origin.y, width: 0, height: 0)),
          foreground: foreground, background: background, text: text,
          attributes: attrNames.isEmpty ? nil : attrNames,
          underlineStyle: underlineStyle.name,
          underlineColor: underlineColor,
          hyperlink: hyperlink)
      case .cursor(let rect, let color):
        return CapturedFrameCommand(
          index: index, kind: "cursor", source: FrameSource.cursor.rawValue,
          rect: CapturedRect(rect), color: color)
      case .selection(let rect, let color):
        return CapturedFrameCommand(
          index: index, kind: "selection", source: FrameSource.selection.rawValue,
          rect: CapturedRect(rect), color: color)
      case .clip(let rect):
        return CapturedFrameCommand(
          index: index, kind: "clip", source: "unknown", rect: CapturedRect(rect))
      case .texturedQuad(let rect, let resourceId, let source):
        return CapturedFrameCommand(
          index: index, kind: "texturedQuad", source: source.rawValue,
          rect: CapturedRect(rect), resourceId: resourceId)
      }
    }
  }

  public static func commands(from captured: [CapturedFrameCommand]) -> [FrameCommand] {
    captured.compactMap { item in
      let source = FrameSource(rawValue: item.source) ?? .terminal
      switch item.kind {
      case "rect":
        guard let rect = item.rect, let color = item.color else { return nil }
        return .rect(rect.cgRect, color: color, source: source)
      case "glyphRun":
        guard let rect = item.rect, let text = item.text,
          let foreground = item.foreground, let background = item.background
        else { return nil }
        let attributes = TextAttributes(names: item.attributes ?? [])
        let underlineStyle = item.underlineStyle.map { UnderlineStyle(name: $0) } ?? .none
        return .glyphRun(
          origin: CGPoint(x: rect.x, y: rect.y),
          text: text,
          foreground: foreground,
          background: background,
          attributes: attributes,
          source: source,
          underlineStyle: underlineStyle,
          underlineColor: item.underlineColor,
          hyperlink: item.hyperlink)
      case "cursor":
        guard let rect = item.rect, let color = item.color else { return nil }
        return .cursor(rect.cgRect, color: color)
      case "selection":
        guard let rect = item.rect, let color = item.color else { return nil }
        return .selection(rect.cgRect, color: color)
      case "clip":
        guard let rect = item.rect else { return nil }
        return .clip(rect.cgRect)
      case "texturedQuad":
        guard let rect = item.rect, let resourceId = item.resourceId else { return nil }
        return .texturedQuad(rect: rect.cgRect, resourceId: resourceId, source: source)
      default:
        return nil
      }
    }
  }
}

private struct CapturedTerminalSnapshot: Encodable {
  var schemaVersion = 1
  var frame: Int
  var sessionId: String?
  var rows: Int
  var cols: Int
  var cursorRow: Int
  var cursorCol: Int
  var cursorVisible: Bool
  var title: String?
  var status: String
  var mouseTracking: Bool
  var focusReporting: Bool
  var dirty: Bool
  var visibleText: String
  var visibleHash: String
}

private struct CapturedRenderFrame: Encodable {
  var schemaVersion = 1
  var frame: Int
  var backend: String
  var surface: CapturedSurface
  var pixelHash: String?
}
