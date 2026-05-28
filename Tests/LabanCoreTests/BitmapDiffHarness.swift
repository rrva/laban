import CoreGraphics
import Foundation
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanCore

/// Drives a fixture Session through a defined byte-stream scenario and
/// renders the resulting cell grid to a BitmapSurface using the
/// software renderer. Sessions are deterministic when fed deterministic
/// bytes — two scenarios that should produce the same screen must
/// produce byte-identical bitmaps. Tests that diverge from that
/// expectation surface as pixel-level diffs in `.artifacts/`.
struct RenderScenario {
  var name: String
  var rows: Int = 24
  var cols: Int = 67
  /// One or more byte chunks fed via `Session.feedOutput`. Splitting
  /// at non-standard boundaries is what catches VT-parser seam bugs.
  var feeds: [[UInt8]]
  /// Optional in-band action after feeds — exercises code paths that
  /// touch the local Session beyond raw output, e.g. `writePaste`.
  var action: ((Session) -> Void)? = nil
}

/// A pixel-by-pixel comparison result for two same-size BitmapSurfaces.
struct BitmapDiffResult {
  var width: Int
  var height: Int
  var mismatchedPixels: Int
  var maxChannelDelta: Int
  var diff: BitmapSurface

  var isIdentical: Bool { mismatchedPixels == 0 }
}

enum BitmapDiff {
  static func compare(_ a: BitmapSurface, _ b: BitmapSurface) -> BitmapDiffResult? {
    guard a.width == b.width, a.height == b.height else { return nil }
    let diff = BitmapSurface(width: a.width, height: a.height)
    // Paint the diff canvas opaque white so the bright red diff pixels
    // we draw next stand out at any zoom level. The default surface
    // is initialised to all-zero bytes which renders as transparent
    // black — invisible over a typical image viewer.
    diff.context.setFillColor(cgColorFrom(0xFFFF_FFFF))
    diff.context.fill(CGRect(x: 0, y: 0, width: diff.width, height: diff.height))

    var mismatched = 0
    var maxDelta = 0
    diff.context.setFillColor(cgColorFrom(0xFF00_00FF))
    for y in 0..<a.height {
      for x in 0..<a.width {
        guard let pa = a.pixel(x: x, y: y), let pb = b.pixel(x: x, y: y) else { continue }
        if pa == pb { continue }
        mismatched += 1
        // Channel-wise max delta is a stable proxy for "by how much"
        // — small font-rasterization drift would show single-digit
        // deltas, real corruption shows hundreds.
        for shift in [24, 16, 8, 0] {
          let ca = Int((pa >> UInt32(shift)) & 0xFF)
          let cb = Int((pb >> UInt32(shift)) & 0xFF)
          let d = abs(ca - cb)
          if d > maxDelta { maxDelta = d }
        }
        diff.context.fill(CGRect(x: x, y: y, width: 1, height: 1))
      }
    }
    return BitmapDiffResult(
      width: a.width, height: a.height,
      mismatchedPixels: mismatched, maxChannelDelta: maxDelta, diff: diff)
  }
}

enum BitmapDiffHarness {
  static func render(
    _ scenario: RenderScenario,
    file: StaticString = #file,
    line: UInt = #line
  ) throws -> BitmapSurface {
    var size = LabanTerminalSize()
    size.rows = Int32(scenario.rows)
    size.cols = Int32(scenario.cols)
    let session = try Session.fixture(size: size)
    defer { session.close() }

    for chunk in scenario.feeds {
      let rc = session.feedOutput(chunk)
      if rc != 0 {
        XCTFail(
          "scenario \(scenario.name): feedOutput returned \(rc)",
          file: file, line: line)
      }
    }
    scenario.action?(session)

    guard let snap = session.snapshot() else {
      XCTFail("scenario \(scenario.name): snapshot failed", file: file, line: line)
      return BitmapSurface(width: 1, height: 1)
    }
    defer { laban_snapshot_destroy(snap) }

    let cellWidth = 8
    let cellHeight = 16
    let producer = FrameProducer(
      cellWidth: cellWidth, cellHeight: cellHeight,
      originX: 0, originY: 0)
    let commands = producer.commands(from: snap, cursorBlinkVisible: false)

    let pixelWidth = scenario.cols * cellWidth
    let pixelHeight = scenario.rows * cellHeight
    let backend = SoftwareBackend(
      fontAtlas: FontAtlas(),
      pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: 1)
    _ = backend.render(commands, damage: .full)
    return backend.surface
  }

  /// Writes the two scenarios' bitmaps and the diff PNG to the test
  /// artifacts directory and emits an XCTFail with the paths. The
  /// artifacts survive the test run and are easy to open side-by-side.
  static func saveFailureArtifacts(
    label: String,
    expected: BitmapSurface,
    actual: BitmapSurface,
    diff: BitmapSurface,
    file: StaticString,
    line: UInt
  ) {
    let runId = ProcessInfo.processInfo.environment["LABAN_RUN_ID"]
      ?? "bitmap-diff-\(UUID().uuidString.prefix(8))"
    let dir = URL(fileURLWithPath: ".artifacts/tests/\(runId)/\(label)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if let png = expected.pngData {
      try? png.write(to: dir.appendingPathComponent("expected.png"))
    }
    if let png = actual.pngData {
      try? png.write(to: dir.appendingPathComponent("actual.png"))
    }
    if let png = diff.pngData {
      try? png.write(to: dir.appendingPathComponent("diff.png"))
    }
    XCTFail(
      "[\(label)] bitmaps differ; artifacts written to \(dir.path)",
      file: file, line: line)
  }

  /// XCTAssert that two scenarios produce identical bitmaps. On
  /// mismatch, writes expected.png / actual.png / diff.png to the
  /// test artifacts directory.
  static func assertBitmapsMatch(
    expected: RenderScenario,
    actual: RenderScenario,
    label: String,
    file: StaticString = #file,
    line: UInt = #line
  ) throws {
    let e = try render(expected, file: file, line: line)
    let a = try render(actual, file: file, line: line)
    guard let result = BitmapDiff.compare(e, a) else {
      XCTFail(
        "[\(label)] bitmap dimensions differ: \(e.width)x\(e.height) vs \(a.width)x\(a.height)",
        file: file, line: line)
      return
    }
    if !result.isIdentical {
      saveFailureArtifacts(
        label: label, expected: e, actual: a, diff: result.diff,
        file: file, line: line)
    }
  }
}

