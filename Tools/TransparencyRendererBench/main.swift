import CoreGraphics
import Darwin
import Foundation
import LabanCore
import LabanRenderer
import LabanTerminalCore
import Metal

private enum BenchmarkError: Error, CustomStringConvertible {
  case invalidArgument(String)
  case rendererUnavailable(String)
  case renderFailed(renderer: String, metric: String, frame: Int)
  case invalidSamples(metric: String, expected: Int, actual: Int)

  var description: String {
    switch self {
    case .invalidArgument(let message): return message
    case .rendererUnavailable(let renderer): return "renderer unavailable: \(renderer)"
    case .renderFailed(let renderer, let metric, let frame):
      return "\(renderer) \(metric) render failed at frame \(frame)"
    case .invalidSamples(let metric, let expected, let actual):
      return "\(metric) accepted \(actual) samples; expected \(expected)"
    }
  }
}

private struct Configuration {
  let renderer: RendererSelection
  let fixtureURL: URL
  let outputURL: URL
  let run: Int
  let warmupFrames: Int
  let measuredFrames: Int

  init(arguments: [String]) throws {
    var values: [String: String] = [:]
    for argument in arguments {
      guard argument.hasPrefix("--"), let separator = argument.firstIndex(of: "=") else {
        throw BenchmarkError.invalidArgument("arguments must use --name=value syntax")
      }
      let name = String(argument[argument.index(argument.startIndex, offsetBy: 2)..<separator])
      let value = String(argument[argument.index(after: separator)...])
      guard !name.isEmpty, !value.isEmpty, values[name] == nil else {
        throw BenchmarkError.invalidArgument("invalid or duplicate argument: \(argument)")
      }
      values[name] = value
    }

    let expectedNames = Set(["phase", "renderer", "fixture", "run", "warmup", "frames", "output"])
    guard Set(values.keys) == expectedNames else {
      let missing = expectedNames.subtracting(values.keys).sorted().joined(separator: ", ")
      let unknown = Set(values.keys).subtracting(expectedNames).sorted().joined(separator: ", ")
      throw BenchmarkError.invalidArgument(
        "argument set mismatch; missing=[\(missing)] unknown=[\(unknown)]")
    }
    guard values["phase"] == "baseline" else {
      throw BenchmarkError.invalidArgument("only --phase=baseline is implemented")
    }
    guard
      let rendererName = values["renderer"],
      let renderer = RendererSelection(rawValue: rendererName),
      renderer == .slugGlyph || renderer == .vectorGlyph
    else {
      throw BenchmarkError.invalidArgument("--renderer must be slugGlyph or vectorGlyph")
    }
    guard let rawRun = values["run"], let run = Int(rawRun), run > 0 else {
      throw BenchmarkError.invalidArgument("--run must be positive")
    }
    guard
      let rawWarmup = values["warmup"],
      let warmupFrames = Int(rawWarmup),
      warmupFrames > 0
    else {
      throw BenchmarkError.invalidArgument("--warmup must be positive")
    }
    guard
      let rawFrames = values["frames"],
      let measuredFrames = Int(rawFrames),
      measuredFrames > 0
    else {
      throw BenchmarkError.invalidArgument("--frames must be positive")
    }
    guard let fixture = values["fixture"], let output = values["output"] else {
      throw BenchmarkError.invalidArgument("--fixture and --output are required")
    }

    self.renderer = renderer
    fixtureURL = URL(fileURLWithPath: fixture)
    outputURL = URL(fileURLWithPath: output)
    self.run = run
    self.warmupFrames = warmupFrames
    self.measuredFrames = measuredFrames
  }
}

private struct MetricSummary: Codable {
  let acceptedSamples: Int
  let p50Milliseconds: Double
  let p95Milliseconds: Double
  let p99Milliseconds: Double
  let minimumMilliseconds: Double
  let maximumMilliseconds: Double

  init(samples: [Double]) {
    let sorted = samples.sorted()
    acceptedSamples = sorted.count
    p50Milliseconds = Self.percentile(sorted, 0.50)
    p95Milliseconds = Self.percentile(sorted, 0.95)
    p99Milliseconds = Self.percentile(sorted, 0.99)
    minimumMilliseconds = sorted.first ?? 0
    maximumMilliseconds = sorted.last ?? 0
  }

  private static func percentile(_ sorted: [Double], _ percentile: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let index = min(
      sorted.count - 1,
      max(0, Int((Double(sorted.count) * percentile).rounded()) - 1))
    return sorted[index]
  }
}

private struct RunMetrics: Codable {
  let cpuEncode: MetricSummary
  let wallTime: MetricSummary
}

private struct Grid: Codable {
  let columns: Int
  let rows: Int
  let cellWidthPoints: Int
  let cellHeightPoints: Int
}

private struct Antialiasing: Codable {
  let configured: String
  let effective: String
}

private struct FontIdentity: Codable {
  let primaryPostScriptName: String
  let cjkPostScriptName: String
  let cjkFamilyName: String
  let cjkSource: String
}

private struct RunRecord: Codable {
  let schemaVersion: Int
  let phase: String
  let renderer: String
  let configuredRenderer: String
  let effectiveRenderer: String
  let run: Int
  let processIdentifier: Int32
  let fixtureName: String
  let fixtureVersion: Int
  let grid: Grid
  let scale: Double
  let pixelWidth: Int
  let pixelHeight: Int
  let surfaceIsOpaque: Bool
  let antialiasing: Antialiasing
  let font: FontIdentity
  let warmupFrames: Int
  let measuredFrames: Int
  let metrics: RunMetrics
}

private struct TransparencyRendererBenchmark {
  private let columns = 160
  private let rows = 48
  private let scale: CGFloat = 2

  func run(configuration: Configuration) throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw BenchmarkError.rendererUnavailable("Metal device")
    }
    let fixture = try FixtureRunner.load(from: configuration.fixtureURL)
    guard fixture.fixture.name == "trust-gate", fixture.fixture.version == 1 else {
      throw BenchmarkError.invalidArgument("fixture must be the version-1 CJK trust gate")
    }

    let fontAtlas = FontAtlas(pointSize: 14, fontName: nil)
    let cellWidth = Int(fontAtlas.cellSize.width)
    let cellHeight = Int(fontAtlas.cellSize.height)
    let pixelWidth = columns * cellWidth * Int(scale)
    let pixelHeight = rows * cellHeight * Int(scale)
    let commands = try frameCommands(
      fixture: fixture,
      cellWidth: cellWidth,
      cellHeight: cellHeight)
    guard !commands.isEmpty else {
      throw BenchmarkError.invalidArgument("fixture produced no frame commands")
    }

    let cpuSamples = try measure(
      selection: configuration.renderer,
      fontAtlas: fontAtlas,
      commands: commands,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      warmupFrames: configuration.warmupFrames,
      measuredFrames: configuration.measuredFrames,
      waitForCompletion: false)
    let wallSamples = try measure(
      selection: configuration.renderer,
      fontAtlas: fontAtlas,
      commands: commands,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      warmupFrames: configuration.warmupFrames,
      measuredFrames: configuration.measuredFrames,
      waitForCompletion: true)
    try validateSamples(
      cpuSamples,
      metric: "cpuEncode",
      expected: configuration.measuredFrames)
    try validateSamples(
      wallSamples,
      metric: "wallTime",
      expected: configuration.measuredFrames)

    let identityRenderer = try makeRenderer(
      selection: configuration.renderer,
      fontAtlas: fontAtlas,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      waitForCompletion: true)
    let status = identityRenderer.rendererStatus
    guard status.configuredRenderer == configuration.renderer.rawValue,
      status.effectiveRenderer == configuration.renderer.rawValue
    else {
      throw BenchmarkError.invalidArgument(
        "renderer identity mismatch: configured=\(status.configuredRenderer) "
          + "effective=\(status.effectiveRenderer)")
    }
    guard identityRenderer.presentationLayer?.isOpaque == true else {
      throw BenchmarkError.invalidArgument(
        "\(configuration.renderer.rawValue) presentation layer is not opaque")
    }
    guard status.vectorSubpixelLayout == "grayscale" else {
      throw BenchmarkError.invalidArgument(
        "\(configuration.renderer.rawValue) effective AA is not grayscale")
    }

    let cjk = fontAtlas.cjkFontDiagnostics
    let record = RunRecord(
      schemaVersion: 1,
      phase: "baseline",
      renderer: configuration.renderer.rawValue,
      configuredRenderer: status.configuredRenderer,
      effectiveRenderer: status.effectiveRenderer,
      run: configuration.run,
      processIdentifier: ProcessInfo.processInfo.processIdentifier,
      fixtureName: fixture.fixture.name,
      fixtureVersion: fixture.fixture.version,
      grid: Grid(
        columns: columns,
        rows: rows,
        cellWidthPoints: cellWidth,
        cellHeightPoints: cellHeight),
      scale: Double(scale),
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      surfaceIsOpaque: identityRenderer.presentationLayer?.isOpaque == true,
      antialiasing: Antialiasing(
        configured: "grayscale",
        effective: status.vectorSubpixelLayout ?? "unknown"),
      font: FontIdentity(
        primaryPostScriptName: fontAtlas.fontPostScriptName,
        cjkPostScriptName: cjk.selectedFontPostScriptName,
        cjkFamilyName: cjk.selectedFamilyName,
        cjkSource: cjk.selectedSource),
      warmupFrames: configuration.warmupFrames,
      measuredFrames: configuration.measuredFrames,
      metrics: RunMetrics(
        cpuEncode: MetricSummary(samples: cpuSamples),
        wallTime: MetricSummary(samples: wallSamples)))

    try FileManager.default.createDirectory(
      at: configuration.outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(record).write(to: configuration.outputURL, options: .atomic)
  }

  private func frameCommands(
    fixture: FixtureRunner,
    cellWidth: Int,
    cellHeight: Int
  ) throws -> [FrameCommand] {
    var size = LabanTerminalSize()
    size.cols = Int32(columns)
    size.rows = Int32(rows)
    let model = try AppModel(initialSize: size)
    try fixture.apply(to: model)
    guard
      let tab = model.activeTab,
      let session = model.session(forTab: tab.id),
      let snapshot = session.snapshot()
    else {
      throw BenchmarkError.invalidArgument("fixture snapshot failed")
    }
    defer { laban_snapshot_destroy(snapshot) }
    guard Int(snapshot.pointee.cols) == columns, Int(snapshot.pointee.rows) == rows else {
      throw BenchmarkError.invalidArgument(
        "fixture snapshot must remain \(columns)x\(rows)")
    }
    return FrameProducer(cellWidth: cellWidth, cellHeight: cellHeight)
      .commands(from: UnsafePointer(snapshot))
  }

  private func makeRenderer(
    selection: RendererSelection,
    fontAtlas: FontAtlas,
    pixelWidth: Int,
    pixelHeight: Int,
    waitForCompletion: Bool
  ) throws -> RendererBackend {
    let renderer: RendererBackend?
    switch selection {
    case .slugGlyph:
      let slug = SlugGlyphRenderer(
        fontAtlas: fontAtlas,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        scale: scale)
      slug?.presentsToLayer = false
      slug?.setSubpixelLayout(.grayscale)
      renderer = slug
    case .vectorGlyph:
      let vector = VectorGlyphRenderer(
        fontAtlas: fontAtlas,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        scale: scale)
      vector?.setSubpixelLayout(.grayscale)
      renderer = vector
    default:
      renderer = nil
    }
    guard let renderer else {
      throw BenchmarkError.rendererUnavailable(selection.rawValue)
    }
    guard renderer.presentationLayer?.isOpaque == true else {
      throw BenchmarkError.invalidArgument("\(selection.rawValue) presentation layer is not opaque")
    }
    renderer.waitForFrameCompletion = waitForCompletion
    return renderer
  }

  private func measure(
    selection: RendererSelection,
    fontAtlas: FontAtlas,
    commands: [FrameCommand],
    pixelWidth: Int,
    pixelHeight: Int,
    warmupFrames: Int,
    measuredFrames: Int,
    waitForCompletion: Bool
  ) throws -> [Double] {
    let metric = waitForCompletion ? "wallTime" : "cpuEncode"
    let renderer = try makeRenderer(
      selection: selection,
      fontAtlas: fontAtlas,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      waitForCompletion: waitForCompletion)
    for frame in 0..<warmupFrames {
      _ = try renderAccepted(
        renderer: renderer,
        commands: commands,
        rendererName: selection.rawValue,
        metric: "\(metric)Warmup",
        frame: frame)
    }

    var samples: [Double] = []
    samples.reserveCapacity(measuredFrames)
    for frame in 0..<measuredFrames {
      let (start, end) = try renderAccepted(
        renderer: renderer,
        commands: commands,
        rendererName: selection.rawValue,
        metric: metric,
        frame: frame)
      samples.append(Double(end - start) / 1_000_000)
    }

    if !waitForCompletion {
      renderer.waitForFrameCompletion = true
      _ = try renderAccepted(
        renderer: renderer,
        commands: commands,
        rendererName: selection.rawValue,
        metric: "cpuEncodeDrain",
        frame: measuredFrames)
    }
    return samples
  }

  /// A renderer with one command buffer in flight may reject an immediate
  /// second submission while the prior frame completes. Such backpressure is
  /// not a failed sample: wait outside the timed interval, then record exactly
  /// the next accepted encode. Bound the retry so a genuinely wedged renderer
  /// still fails the benchmark deterministically.
  private func renderAccepted(
    renderer: RendererBackend,
    commands: [FrameCommand],
    rendererName: String,
    metric: String,
    frame: Int
  ) throws -> (start: UInt64, end: UInt64) {
    let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
    while DispatchTime.now().uptimeNanoseconds < deadline {
      let start = DispatchTime.now().uptimeNanoseconds
      if renderer.render(commands, damage: .full) {
        return (start, DispatchTime.now().uptimeNanoseconds)
      }
      Thread.sleep(forTimeInterval: 0.0001)
    }
    throw BenchmarkError.renderFailed(
      renderer: rendererName,
      metric: metric,
      frame: frame)
  }

  private func validateSamples(_ samples: [Double], metric: String, expected: Int) throws {
    guard samples.count == expected,
      samples.allSatisfy({ $0.isFinite && $0 > 0 })
    else {
      throw BenchmarkError.invalidSamples(
        metric: metric,
        expected: expected,
        actual: samples.filter { $0.isFinite && $0 > 0 }.count)
    }
  }
}

do {
  let configuration = try Configuration(arguments: Array(CommandLine.arguments.dropFirst()))
  try TransparencyRendererBenchmark().run(configuration: configuration)
} catch {
  fputs("transparency-renderer-bench: \(error)\n", stderr)
  fputs(
    "usage: transparency-renderer-bench --phase=baseline --renderer=slugGlyph|vectorGlyph "
      + "--fixture=PATH --run=N --warmup=N --frames=N --output=PATH\n",
    stderr)
  exit(2)
}
