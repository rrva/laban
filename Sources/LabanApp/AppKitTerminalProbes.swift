import AppKit
import CoreGraphics
import LabanCore
import LabanRenderer
import LabanTerminalCore

final class AppKitFrameProbe {
  private struct ProbeGlyph: Encodable {
    var x: Double
    var y: Double
    var text: String
  }

  private struct ProbeRect: Encodable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
      x = Double(rect.origin.x)
      y = Double(rect.origin.y)
      width = Double(rect.size.width)
      height = Double(rect.size.height)
    }
  }

  private struct ProbeCursor: Encodable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
  }

  private struct ProbeEvent: Encodable {
    var schemaVersion = 1
    var frame: Int
    var timeNs: UInt64
    var surfaceWidth: Int
    var surfaceHeight: Int
    var surfaceScale: Double
    var commandCount: Int
    var cursorRow: Int
    var cursorCol: Int
    var cursorVisible: Bool
    var terminalGlyphs: [ProbeGlyph]
    var sidebarGlyphs: [ProbeGlyph]
    var sidebarRects: [ProbeRect]
    var cursors: [ProbeCursor]
  }

  private let handle: FileHandle
  private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()

  init(directory: URL) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("frame-probe.ndjson")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: 0)
  }

  func record(
    frame: Int,
    snapshot: LabanSnapshot,
    commands: [FrameCommand],
    surfaceWidth: Int,
    surfaceHeight: Int,
    surfaceScale: Double
  ) {
    var terminalGlyphs: [ProbeGlyph] = []
    var sidebarGlyphs: [ProbeGlyph] = []
    var sidebarRects: [ProbeRect] = []
    var cursors: [ProbeCursor] = []
    for command in commands {
      switch command {
      case .glyphRun(let origin, let text, _, _, _, let source, _, _, _, _, _, _, _)
      where source == .terminal:
        terminalGlyphs.append(ProbeGlyph(x: Double(origin.x), y: Double(origin.y), text: text))
      case .glyphRun(let origin, let text, _, _, _, let source, _, _, _, _, _, _, _)
      where source == .sidebar:
        sidebarGlyphs.append(ProbeGlyph(x: Double(origin.x), y: Double(origin.y), text: text))
      case .rect(let rect, _, let source, _) where source == .sidebar:
        sidebarRects.append(ProbeRect(rect))
      case .cursor(let rect, _):
        cursors.append(
          ProbeCursor(
            x: Double(rect.origin.x), y: Double(rect.origin.y),
            width: Double(rect.size.width), height: Double(rect.size.height)))
      default:
        break
      }
    }

    let event = ProbeEvent(
      frame: frame,
      timeNs: CaptureClock.nowNs(),
      surfaceWidth: surfaceWidth,
      surfaceHeight: surfaceHeight,
      surfaceScale: surfaceScale,
      commandCount: commands.count,
      cursorRow: Int(snapshot.cursor_row),
      cursorCol: Int(snapshot.cursor_col),
      cursorVisible: snapshot.cursor_visible != 0,
      terminalGlyphs: terminalGlyphs,
      sidebarGlyphs: sidebarGlyphs,
      sidebarRects: sidebarRects,
      cursors: cursors)
    guard let data = try? encoder.encode(event) else { return }
    handle.write(data)
    handle.write(Data([0x0A]))
  }

  func close() {
    try? handle.close()
  }

  deinit { close() }
}

final class AppKitResizeProbe {
  private struct ProbeRect: Encodable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
      x = Double(rect.origin.x)
      y = Double(rect.origin.y)
      width = Double(rect.size.width)
      height = Double(rect.size.height)
    }
  }

  private struct ProbeSize: Encodable {
    var width: Double
    var height: Double

    init(_ size: CGSize) {
      width = Double(size.width)
      height = Double(size.height)
    }
  }

  private struct ProbeEvent: Encodable {
    var schemaVersion = 1
    var sequence: Int
    var label: String
    var timeNs: UInt64
    var renderedFrame: Int
    var windowNumber: Int
    var windowFrame: ProbeRect
    var viewBounds: ProbeRect
    var layerBounds: ProbeRect?
    var drawableSize: ProbeSize
    var screenshotPath: String?
  }

  private let screenshotsDirectory: URL
  private let handle: FileHandle
  private var sequence = 0
  private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()

  init(directory: URL) throws {
    screenshotsDirectory = directory.appendingPathComponent("screenshots", isDirectory: true)
    try FileManager.default.createDirectory(
      at: screenshotsDirectory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("resize-probe.ndjson")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: 0)
  }

  func record(
    label: String,
    window: NSWindow,
    view: NSView,
    backend: RendererBackend,
    renderedFrame: Int
  ) {
    sequence += 1
    let safeLabel = label.map { char -> Character in
      char.isLetter || char.isNumber || char == "-" || char == "_" ? char : "-"
    }
    let screenshotName = String(format: "%03d-%@.png", sequence, String(safeLabel))
    let screenshotURL = screenshotsDirectory.appendingPathComponent(screenshotName)
    let screenshotPath: String?
    if let image = CGWindowListCreateImage(
      .null,
      .optionIncludingWindow,
      CGWindowID(window.windowNumber),
      [.boundsIgnoreFraming, .nominalResolution]),
      let data = PNGEncoder.encode(image)
    {
      try? data.write(to: screenshotURL, options: [.atomic])
      screenshotPath = "screenshots/\(screenshotName)"
    } else {
      screenshotPath = nil
    }

    let event = ProbeEvent(
      sequence: sequence,
      label: label,
      timeNs: CaptureClock.nowNs(),
      renderedFrame: renderedFrame,
      windowNumber: window.windowNumber,
      windowFrame: ProbeRect(window.frame),
      viewBounds: ProbeRect(view.bounds),
      layerBounds: view.layer.map { ProbeRect($0.bounds) },
      drawableSize: ProbeSize(
        CGSize(width: backend.surfaceWidth, height: backend.surfaceHeight)),
      screenshotPath: screenshotPath)
    guard let payload = try? encoder.encode(event) else { return }
    handle.write(payload)
    handle.write(Data([0x0A]))
  }

  func close() {
    try? handle.close()
  }

  deinit { close() }
}

/// Periodically grabs the composited window image — what actually hit the
/// screen — without touching the renderer. This is the "observed" half of
/// the two-channel `.composite` capture: unlike the in-app pixel readback
/// it never stalls the GPU pipeline, so recording does not pace (and
/// potentially mask) the present-path races it is meant to diagnose.
///
/// Grabs and PNG encoding run on a private serial queue; the sink is the
/// recorder's thread-safe `recordCompositeGrab`, whose file I/O is itself
/// async. `CGWindowListCreateImage` of the app's own window needs no
/// screen-recording permission.
final class CompositeWindowGrabber {
  static let defaultGrabHz: Double = 60

  private let windowNumber: CGWindowID
  private let sink: (Int, Data) -> Void
  private let queue: DispatchQueue
  private var timer: DispatchSourceTimer?
  private var sequence = 0

  init(windowNumber: CGWindowID, sink: @escaping (Int, Data) -> Void) {
    self.windowNumber = windowNumber
    self.sink = sink
    self.queue = DispatchQueue(
      label: "laban.capture.window-grab", qos: .userInitiated)
  }

  func start(hz: Double = CompositeWindowGrabber.defaultGrabHz) {
    guard timer == nil, hz > 0 else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(
      deadline: .now(),
      repeating: .milliseconds(Int(1000 / hz)),
      leeway: .milliseconds(2))
    timer.setEventHandler { [weak self] in self?.grab() }
    self.timer = timer
    timer.resume()
  }

  func stop() {
    timer?.cancel()
    timer = nil
    // Drain: stop() returns with no grab in flight, so the caller can
    // finish the recorder knowing every grabbed PNG was handed to it.
    queue.sync {}
  }

  private func grab() {
    guard
      let image = CGWindowListCreateImage(
        .null,
        .optionIncludingWindow,
        windowNumber,
        [.boundsIgnoreFraming, .nominalResolution]),
      let data = PNGEncoder.encode(image)
    else { return }
    sequence += 1
    sink(sequence, data)
  }

  deinit { timer?.cancel() }
}
