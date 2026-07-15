import CoreGraphics
import Foundation
import LabanRenderer
import LabanTerminalCore
import Metal
import XCTest

@testable import LabanCore

/// Harness-only support for the terminal-background-transparency benchmark.
///
/// The checked-in wrapper launches this test in a fresh release XCTest process
/// for every renderer/run pair. Normal test runs return immediately.
final class RendererTransparencyPerformanceTests: XCTestCase {
  private enum BenchmarkError: Error, CustomStringConvertible {
    case invalidEnvironment(String)
    case rendererUnavailable(String)
    case renderFailed(renderer: String, metric: String, frame: Int)
    case invalidSamples(metric: String, expected: Int, actual: Int)

    var description: String {
      switch self {
      case .invalidEnvironment(let message): return message
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

    init(environment: [String: String]) throws {
      func required(_ name: String) throws -> String {
        guard let value = environment[name], !value.isEmpty else {
          throw BenchmarkError.invalidEnvironment("missing \(name)")
        }
        return value
      }

      let rendererName = try required("LABAN_TRANSPARENCY_BENCH_RENDERER")
      guard
        let renderer = RendererSelection(rawValue: rendererName),
        renderer == .slugGlyph || renderer == .vectorGlyph
      else {
        throw BenchmarkError.invalidEnvironment(
          "LABAN_TRANSPARENCY_BENCH_RENDERER must be slugGlyph or vectorGlyph")
      }
      guard let run = Int(try required("LABAN_TRANSPARENCY_BENCH_RUN")), run > 0 else {
        throw BenchmarkError.invalidEnvironment("LABAN_TRANSPARENCY_BENCH_RUN must be positive")
      }
      guard
        let warmupFrames = Int(try required("LABAN_TRANSPARENCY_BENCH_WARMUP")),
        warmupFrames > 0
      else {
        throw BenchmarkError.invalidEnvironment(
          "LABAN_TRANSPARENCY_BENCH_WARMUP must be positive")
      }
      guard
        let measuredFrames = Int(try required("LABAN_TRANSPARENCY_BENCH_FRAMES")),
        measuredFrames > 0
      else {
        throw BenchmarkError.invalidEnvironment(
          "LABAN_TRANSPARENCY_BENCH_FRAMES must be positive")
      }

      self.renderer = renderer
      fixtureURL = URL(fileURLWithPath: try required("LABAN_TRANSPARENCY_BENCH_FIXTURE"))
      outputURL = URL(fileURLWithPath: try required("LABAN_TRANSPARENCY_BENCH_OUTPUT"))
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

  private let columns = 160
  private let rows = 48
  private let scale: CGFloat = 2

  func testOpaqueRendererBaseline() throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["LABAN_RUN_TRANSPARENCY_BENCH"] == "1" else { return }
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let configuration = try Configuration(environment: environment)
    let fixture = try FixtureRunner.load(from: configuration.fixtureURL)
    guard fixture.fixture.name == "trust-gate", fixture.fixture.version == 1 else {
      throw BenchmarkError.invalidEnvironment(
        "fixture must be the version-1 CJK trust gate")
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

    // Baseline intentionally uses FrameProducer's ordinary defaults and does
    // not call any transparency API. Prove that its canvas is opaque before
    // timing the shipped renderer path.
    guard case .rect(_, let canvasColor, let source)? = commands.first,
      source == .terminal,
      canvasColor & 0xFF == 0xFF
    else {
      throw BenchmarkError.invalidEnvironment("opaque baseline canvas is not fully opaque")
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

    let cjk = fontAtlas.cjkFontDiagnostics
    let status = try rendererStatus(
      selection: configuration.renderer,
      fontAtlas: fontAtlas,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight)
    guard status.configuredRenderer == configuration.renderer.rawValue,
      status.effectiveRenderer == configuration.renderer.rawValue
    else {
      throw BenchmarkError.invalidEnvironment(
        "renderer identity mismatch: configured=\(status.configuredRenderer) "
          + "effective=\(status.effectiveRenderer)")
    }

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
      surfaceIsOpaque: true,
      antialiasing: Antialiasing(configured: "grayscale", effective: "grayscale"),
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
      throw BenchmarkError.invalidEnvironment("fixture snapshot failed")
    }
    defer { laban_snapshot_destroy(snapshot) }
    guard Int(snapshot.pointee.cols) == columns, Int(snapshot.pointee.rows) == rows else {
      throw BenchmarkError.invalidEnvironment(
        "fixture snapshot must remain \(columns)x\(rows)")
    }
    let producer = FrameProducer(cellWidth: cellWidth, cellHeight: cellHeight)
    return producer.commands(from: UnsafePointer(snapshot))
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
      throw BenchmarkError.invalidEnvironment(
        "\(selection.rawValue) presentation layer is not opaque")
    }
    renderer.waitForFrameCompletion = waitForCompletion
    return renderer
  }

  private func rendererStatus(
    selection: RendererSelection,
    fontAtlas: FontAtlas,
    pixelWidth: Int,
    pixelHeight: Int
  ) throws -> RendererStatus {
    try makeRenderer(
      selection: selection,
      fontAtlas: fontAtlas,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      waitForCompletion: true
    ).rendererStatus
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
      guard renderer.render(commands, damage: .full) else {
        throw BenchmarkError.renderFailed(
          renderer: selection.rawValue,
          metric: "\(metric)Warmup",
          frame: frame)
      }
    }

    var samples: [Double] = []
    samples.reserveCapacity(measuredFrames)
    for frame in 0..<measuredFrames {
      let start = DispatchTime.now().uptimeNanoseconds
      guard renderer.render(commands, damage: .full) else {
        throw BenchmarkError.renderFailed(
          renderer: selection.rawValue,
          metric: metric,
          frame: frame)
      }
      let end = DispatchTime.now().uptimeNanoseconds
      samples.append(Double(end - start) / 1_000_000)
    }

    // The CPU-encode path deliberately does not wait inside the measured
    // interval. Drain its final submitted frame before releasing the renderer.
    if !waitForCompletion {
      renderer.waitForFrameCompletion = true
      guard renderer.render(commands, damage: .full) else {
        throw BenchmarkError.renderFailed(
          renderer: selection.rawValue,
          metric: "cpuEncodeDrain",
          frame: measuredFrames)
      }
    }
    return samples
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
