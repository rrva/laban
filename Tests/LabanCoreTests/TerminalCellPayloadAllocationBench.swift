import CoreGraphics
import Foundation
import LabanTerminalCore
import Metal
import XCTest

@testable import LabanCore
@testable import LabanRenderer

/// Disabled in normal CI; opt in via:
///   LABAN_RUN_PERF_BENCH=1 swift test -c release --filter TerminalCellPayloadAllocationBench
///
/// This gates the payload builder's retained-storage contract. The warmed
/// one-dirty-row path must not grow any payload arrays; ASCII glyph cells also
/// stay on the scalar fast path and do not materialize per-cell String text.
final class TerminalCellPayloadAllocationBench: XCTestCase {
  private enum PayloadFillStyle {
    case ascii
    case denseColor
    case decorated
    case hyperlink
    case wide
  }

  private struct PayloadFillMicroCase {
    var label: String
    var style: PayloadFillStyle
    var dirtyRows: [Int]
  }

  private func enabled() -> Bool {
    ProcessInfo.processInfo.environment["LABAN_RUN_PERF_BENCH"] == "1"
  }

  func testOneDirtyRowPayloadHasZeroWarmStorageGrowth() throws {
    guard enabled() else { return }
    #if DEBUG
      throw XCTSkip("allocation bench must run with -c release")
    #else
      var size = LabanTerminalSize()
      size.rows = 48
      size.cols = 160
      let session = try Session.fixture(size: size)
      defer { session.close() }

      _ = session.write(Array(String(repeating: "A", count: Int(size.cols)).utf8))
      _ = session.poll()
      let snap = try XCTUnwrap(session.snapshot())
      defer { laban_snapshot_destroy(snap) }

      let producer = FrameProducer(
        cellWidth: 9,
        cellHeight: 19,
        originX: 0,
        originY: 0,
        contentYOffset: 0)
      var payload = TerminalCellPayload(
        rows: Int(size.rows),
        cols: Int(size.cols),
        origin: .zero,
        cellSize: CGSize(width: 9, height: 19),
        contentYOffset: 0,
        defaultBackground: snap.pointee.default_background_rgba)

      let dirtyRows = [0]
      producer.fillTerminalCellPayload(
        into: &payload,
        from: UnsafePointer(snap),
        includedRows: dirtyRows,
        cursorBlinkVisible: false)
      let warmed = payload.capacitySnapshot

      var storageGrowthEvents = 0
      let iterations = 10_000
      let start = ContinuousClock.now
      for _ in 0..<iterations {
        let before = payload.capacitySnapshot
        producer.fillTerminalCellPayload(
          into: &payload,
          from: UnsafePointer(snap),
          includedRows: dirtyRows,
          cursorBlinkVisible: false)
        storageGrowthEvents += before.storageGrowthEvents(to: payload.capacitySnapshot)
      }
      let elapsed = ContinuousClock.now - start
      let elapsedMs =
        Double(elapsed.components.seconds) * 1000
        + Double(elapsed.components.attoseconds) / 1e15
      print(
        String(
          format:
            "\n=== TerminalCellPayload allocation bench ===\n  one dirty row: iterations=%d storageGrowthEvents=%d total=%.3f ms perFrame=%.3f us capacities=%@\n",
          iterations,
          storageGrowthEvents,
          elapsedMs,
          elapsedMs * 1000 / Double(iterations),
          String(describing: warmed)))

      XCTAssertEqual(storageGrowthEvents, 0)
      XCTAssertEqual(payload.capacitySnapshot, warmed)
      XCTAssertEqual(payload.dirtyRows, dirtyRows)
      XCTAssertNil(payload.fallbackReason)
    #endif
  }

  func testPayloadFillMicrobench() throws {
    guard enabled() else { return }
    #if DEBUG
      throw XCTSkip("payload fill microbench must run with -c release")
    #else
      let rows = 48
      let cols = 160
      let cases: [PayloadFillMicroCase] = [
        .init(label: "ascii 1 row", style: .ascii, dirtyRows: [rows - 1]),
        .init(label: "ascii 5 rows", style: .ascii, dirtyRows: Array(20..<25)),
        .init(label: "ascii full", style: .ascii, dirtyRows: Array(0..<rows)),
        .init(label: "dense colors", style: .denseColor, dirtyRows: Array(20..<25)),
        .init(label: "decorated", style: .decorated, dirtyRows: Array(20..<25)),
        .init(label: "hyperlink", style: .hyperlink, dirtyRows: Array(20..<25)),
        .init(label: "wide glyphs", style: .wide, dirtyRows: Array(20..<25)),
      ]
      let samples =
        ProcessInfo.processInfo.environment["LABAN_BENCH_PAYLOAD_FILL_SAMPLES"].flatMap(Int.init)
        ?? 800
      let producer = FrameProducer(
        cellWidth: 9,
        cellHeight: 19,
        originX: 0,
        originY: 0,
        contentYOffset: 0)

      print("\n=== TerminalCellPayload fill microbench (160x48, release, us) ===")
      print("  case             p50/p95/p99 us   growth glyphs bgRuns utf8 fallback")
      for benchCase in cases {
        let fixture = try payloadFillSnapshot(
          rows: rows,
          cols: cols,
          style: benchCase.style)
        defer {
          laban_snapshot_destroy(fixture.snapshot)
          fixture.session.close()
        }

        var payload = TerminalCellPayload(
          rows: rows,
          cols: cols,
          origin: .zero,
          cellSize: CGSize(width: 9, height: 19),
          contentYOffset: 0,
          defaultBackground: fixture.snapshot.pointee.default_background_rgba)
        producer.fillTerminalCellPayload(
          into: &payload,
          from: UnsafePointer(fixture.snapshot),
          includedRows: benchCase.dirtyRows,
          cursorBlinkVisible: false)
        let warmedCapacity = payload.capacitySnapshot

        var timings: [Double] = []
        timings.reserveCapacity(samples)
        var storageGrowthEvents = 0
        for _ in 0..<samples {
          let before = payload.capacitySnapshot
          let start = DispatchTime.now().uptimeNanoseconds
          producer.fillTerminalCellPayload(
            into: &payload,
            from: UnsafePointer(fixture.snapshot),
            includedRows: benchCase.dirtyRows,
            cursorBlinkVisible: false)
          let end = DispatchTime.now().uptimeNanoseconds
          timings.append(Double(end - start) / 1_000.0)
          storageGrowthEvents += before.storageGrowthEvents(to: payload.capacitySnapshot)
        }

        XCTAssertEqual(payload.capacitySnapshot, warmedCapacity)
        print(
          String(
            format: "  %-16@ %.1f/%.1f/%.1f    %6d %6d %6d %4d %@",
            benchCase.label as NSString,
            percentile(timings, 0.50),
            percentile(timings, 0.95),
            percentile(timings, 0.99),
            storageGrowthEvents,
            payload.glyphs.count,
            payload.backgroundRuns.count,
            payload.utf8Bytes.count,
            String(describing: payload.fallbackReason) as NSString))
      }
    #endif
  }

  func testRoutedPayloadFrameBeatsClassicCommandFrameForOneDirtyRow() throws {
    guard enabled() else { return }
    #if DEBUG
      throw XCTSkip("dirty-row routing bench must run with -c release")
    #else
      guard MTLCreateSystemDefaultDevice() != nil else {
        throw XCTSkip("no Metal device available")
      }

      let rows = 48
      let cols = 160
      let cellW: CGFloat = 9
      let cellH: CGFloat = 19
      let scale: CGFloat = 1
      let snap = try fullASCIIGridSnapshot(rows: rows, cols: cols)
      defer {
        laban_snapshot_destroy(snap.snapshot)
        snap.session.close()
      }

      let producer = FrameProducer(
        cellWidth: Int(cellW),
        cellHeight: Int(cellH),
        originX: 0,
        originY: 0,
        contentYOffset: 0)
      let damage = RenderDamage.partial(
        yRanges: [DirtyYRange(y: CGFloat(rows - 1) * cellH, height: cellH)])
      let surfacePxH = Int(CGFloat(rows) * cellH * scale)
      let fontAtlas = FontAtlas(pointSize: 14)
      let classicRenderer = try XCTUnwrap(MetalRenderer(fontAtlas: fontAtlas, scale: scale))
      let payloadRenderer = try XCTUnwrap(MetalRenderer(fontAtlas: fontAtlas, scale: scale))
      let initialPayload = producer.terminalCellPayload(
        from: UnsafePointer(snap.snapshot),
        includedRows: Array(0..<rows),
        cursorBlinkVisible: false)
      _ = payloadRenderer.rebuildGPUCellPayloadInstancesForTesting(
        payload: try XCTUnwrap(initialPayload),
        commands: [],
        damage: .full,
        surfacePxH: surfacePxH)

      var payload = TerminalCellPayload(
        rows: rows,
        cols: cols,
        origin: .zero,
        cellSize: CGSize(width: cellW, height: cellH),
        contentYOffset: 0,
        defaultBackground: snap.snapshot.pointee.default_background_rgba)
      let dirtyRows = [0]

      var classicSamples: [Double] = []
      var payloadSamples: [Double] = []
      classicSamples.reserveCapacity(400)
      payloadSamples.reserveCapacity(400)

      for _ in 0..<40 {
        _ = producer.commands(from: UnsafePointer(snap.snapshot), cursorBlinkVisible: false)
        producer.fillTerminalCellPayload(
          into: &payload,
          from: UnsafePointer(snap.snapshot),
          includedRows: dirtyRows,
          cursorBlinkVisible: false)
        _ = payloadRenderer.rebuildGPUCellPayloadInstancesForTesting(
          payload: payload,
          commands: [],
          damage: damage,
          surfacePxH: surfacePxH)
      }

      let warmedPayloadCapacity = payload.capacitySnapshot
      let warmedRendererRowMarkerCapacity = payloadRenderer.payloadRowMarkerCapacityForTesting
      var payloadStorageGrowthEvents = 0
      var rendererRowMarkerGrowthEvents = 0

      for _ in 0..<400 {
        var start = DispatchTime.now().uptimeNanoseconds
        let commands = producer.commands(
          from: UnsafePointer(snap.snapshot),
          cursorBlinkVisible: false)
        _ = classicRenderer.rebuildInstancesForTesting(
          commands: commands,
          damage: damage,
          surfacePxH: surfacePxH)
        var end = DispatchTime.now().uptimeNanoseconds
        classicSamples.append(Double(end - start) / 1_000.0)

        start = DispatchTime.now().uptimeNanoseconds
        let beforePayloadCapacity = payload.capacitySnapshot
        let beforeRendererRowMarkerCapacity = payloadRenderer.payloadRowMarkerCapacityForTesting
        producer.fillTerminalCellPayload(
          into: &payload,
          from: UnsafePointer(snap.snapshot),
          includedRows: dirtyRows,
          cursorBlinkVisible: false)
        _ = payloadRenderer.rebuildGPUCellPayloadInstancesForTesting(
          payload: payload,
          commands: [],
          damage: damage,
          surfacePxH: surfacePxH)
        payloadStorageGrowthEvents += beforePayloadCapacity.storageGrowthEvents(
          to: payload.capacitySnapshot)
        if payloadRenderer.payloadRowMarkerCapacityForTesting > beforeRendererRowMarkerCapacity {
          rendererRowMarkerGrowthEvents += 1
        }
        end = DispatchTime.now().uptimeNanoseconds
        payloadSamples.append(Double(end - start) / 1_000.0)
      }

      let classicP50 = percentile(classicSamples, 0.50)
      let payloadP50 = percentile(payloadSamples, 0.50)
      print(
        String(
          format:
            "\n=== TerminalCellPayload routed dirty-row bench ===\n  classic commands+M1 scoped p50=%.1f us\n  payload fill+GPU patch p50=%.1f us\n  payloadStorageGrowthEvents=%d rendererRowMarkerGrowthEvents=%d rendererRowMarkerCapacity=%d\n",
          classicP50,
          payloadP50,
          payloadStorageGrowthEvents,
          rendererRowMarkerGrowthEvents,
          warmedRendererRowMarkerCapacity))

      XCTAssertLessThan(payloadP50, classicP50)
      XCTAssertEqual(payloadStorageGrowthEvents, 0)
      XCTAssertEqual(payload.capacitySnapshot, warmedPayloadCapacity)
      XCTAssertEqual(rendererRowMarkerGrowthEvents, 0)
      XCTAssertEqual(
        payloadRenderer.payloadRowMarkerCapacityForTesting,
        warmedRendererRowMarkerCapacity)
    #endif
  }

  private func fullASCIIGridSnapshot(
    rows: Int,
    cols: Int
  ) throws -> (session: Session, snapshot: UnsafeMutablePointer<LabanSnapshot>) {
    var size = LabanTerminalSize()
    size.rows = Int32(rows)
    size.cols = Int32(cols)
    let session = try Session.fixture(size: size)
    var bytes = Array("\u{1B}[?7l".utf8)
    for row in 1...rows {
      bytes += Array("\u{1B}[\(row);1H".utf8)
      bytes += Array(
        String(repeating: Character(UnicodeScalar(0x41 + (row % 26))!), count: cols).utf8)
    }
    _ = session.write(bytes)
    _ = session.poll()
    guard let snapshot = session.snapshot() else {
      session.close()
      throw XCTSkip("missing snapshot")
    }
    return (session, snapshot)
  }

  private func payloadFillSnapshot(
    rows: Int,
    cols: Int,
    style: PayloadFillStyle
  ) throws -> (session: Session, snapshot: UnsafeMutablePointer<LabanSnapshot>) {
    var size = LabanTerminalSize()
    size.rows = Int32(rows)
    size.cols = Int32(cols)
    let session = try Session.fixture(size: size)
    let bytes = payloadFillBytes(rows: rows, cols: cols, style: style)
    _ = session.write(bytes)
    _ = session.poll()
    guard let snapshot = session.snapshot() else {
      session.close()
      throw XCTSkip("missing snapshot")
    }
    return (session, snapshot)
  }

  private func payloadFillBytes(
    rows: Int,
    cols: Int,
    style: PayloadFillStyle
  ) -> [UInt8] {
    var bytes = Array("\u{1B}[?7l\u{1B}[0m".utf8)
    for row in 1...rows {
      bytes += Array("\u{1B}[\(row);1H".utf8)
      switch style {
      case .ascii:
        appendASCIIRow(row: row, cols: cols, into: &bytes)
      case .denseColor:
        appendDenseColorRow(row: row, cols: cols, into: &bytes)
      case .decorated:
        appendDecoratedRow(row: row, cols: cols, into: &bytes)
      case .hyperlink:
        appendHyperlinkRow(row: row, cols: cols, into: &bytes)
      case .wide:
        appendWideRow(row: row, cols: cols, into: &bytes)
      }
    }
    bytes += Array("\u{1B}[0m".utf8)
    return bytes
  }

  private func appendASCIIRow(row: Int, cols: Int, into bytes: inout [UInt8]) {
    for col in 0..<cols {
      bytes.append(asciiByte(row: row, col: col))
    }
  }

  private func appendDenseColorRow(row: Int, cols: Int, into bytes: inout [UInt8]) {
    for col in 0..<cols {
      let seed = row * 17 + col * 29
      let fg = rgb(seed: seed + 5)
      let bg = rgb(seed: seed + 23)
      bytes += Array(
        "\u{1B}[38;2;\(fg.r);\(fg.g);\(fg.b);48;2;\(bg.r);\(bg.g);\(bg.b)m".utf8)
      bytes.append(asciiByte(row: row, col: col))
    }
    bytes += Array("\u{1B}[0m".utf8)
  }

  private func appendDecoratedRow(row: Int, cols: Int, into bytes: inout [UInt8]) {
    for col in 0..<cols {
      switch col % 12 {
      case 0:
        bytes += Array("\u{1B}[1;4m".utf8)
      case 4:
        bytes += Array("\u{1B}[3;9m".utf8)
      case 8:
        bytes += Array("\u{1B}[53m".utf8)
      default:
        break
      }
      bytes.append(asciiByte(row: row, col: col))
    }
    bytes += Array("\u{1B}[0m".utf8)
  }

  private func appendHyperlinkRow(row: Int, cols: Int, into bytes: inout [UInt8]) {
    var col = 0
    while col < cols {
      if col % 32 == 0 {
        bytes += Array("\u{1B}]8;;https://example.test/\(row)/\(col)\u{1B}\\".utf8)
        for offset in 0..<min(8, cols - col) {
          bytes.append(asciiByte(row: row, col: col + offset))
        }
        bytes += Array("\u{1B}]8;;\u{1B}\\".utf8)
        col += 8
      } else {
        bytes.append(asciiByte(row: row, col: col))
        col += 1
      }
    }
  }

  private func appendWideRow(row: Int, cols: Int, into bytes: inout [UInt8]) {
    let wideScalar = String(UnicodeScalar(0x754C)!)
    var col = 0
    while col < cols {
      if col + 1 < cols, (row + col).isMultiple(of: 16) {
        bytes += Array(wideScalar.utf8)
        col += 2
      } else {
        bytes.append(asciiByte(row: row, col: col))
        col += 1
      }
    }
  }

  private func asciiByte(row: Int, col: Int) -> UInt8 {
    UInt8(0x21 + ((row + col) % 94))
  }

  private func rgb(seed: Int) -> (r: Int, g: Int, b: Int) {
    ((seed * 37) & 0xFF, (seed * 89) & 0xFF, (seed * 167) & 0xFF)
  }
}

extension TerminalCellPayload.CapacitySnapshot {
  fileprivate func storageGrowthEvents(to next: Self) -> Int {
    [
      next.dirtyRows > dirtyRows,
      next.backgroundRuns > backgroundRuns,
      next.glyphs > glyphs,
      next.proceduralCells > proceduralCells,
      next.cursorRects > cursorRects,
      next.utf8Bytes > utf8Bytes,
    ].filter { $0 }.count
  }
}

private func percentile(_ values: [Double], _ p: Double) -> Double {
  guard !values.isEmpty else { return 0 }
  let sorted = values.sorted()
  let idx = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * p)))
  return sorted[idx]
}
