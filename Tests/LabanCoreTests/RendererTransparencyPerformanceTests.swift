import Foundation
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanCore

/// Fast contract check for the workload used by
/// `scripts/benchmark-transparency-renderers`. Timing is owned by the dedicated
/// release executable so this test remains part of the ordinary debug suite.
final class RendererTransparencyPerformanceTests: XCTestCase {
  func testBaselineFixtureProducesFixedGridWorkload() throws {
    let fixtureURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("fixtures/cjk/trust-gate.fixture.json")
    let fixture = try FixtureRunner.load(from: fixtureURL)
    XCTAssertEqual(fixture.fixture.name, "trust-gate")
    XCTAssertEqual(fixture.fixture.version, 1)

    var size = LabanTerminalSize()
    size.cols = 160
    size.rows = 48
    let model = try AppModel(initialSize: size)
    try fixture.apply(to: model)
    let snapshot = try XCTUnwrap(
      model.activeTab
        .flatMap { model.session(forTab: $0.id) }
        .flatMap { $0.snapshot() })
    defer { laban_snapshot_destroy(snapshot) }

    XCTAssertEqual(snapshot.pointee.cols, 160)
    XCTAssertEqual(snapshot.pointee.rows, 48)
    let fontAtlas = FontAtlas(pointSize: 14, fontName: nil)
    let commands = FrameProducer(
      cellWidth: Int(fontAtlas.cellSize.width),
      cellHeight: Int(fontAtlas.cellSize.height)
    ).commands(from: UnsafePointer(snapshot))
    XCTAssertFalse(commands.isEmpty)
    XCTAssertGreaterThan(Int(fontAtlas.cellSize.width) * 160 * 2, 0)
    XCTAssertGreaterThan(Int(fontAtlas.cellSize.height) * 48 * 2, 0)
  }
}
