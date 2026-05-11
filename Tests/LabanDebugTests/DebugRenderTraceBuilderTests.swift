import CoreGraphics
import LabanRenderer
import XCTest

@testable import LabanDebug

final class DebugRenderTraceBuilderTests: XCTestCase {
  func testTraceBuilderProjectsSourcesRangesAndTruncation() {
    let commands: [FrameCommand] = [
      .rect(CGRect(x: 0, y: 0, width: 200, height: 40), color: 0x1111_11FF, source: .sidebar),
      .glyphRun(
        origin: CGPoint(x: 200, y: 0),
        text: "ab",
        foreground: 0xFFFF_FFFF,
        background: 0x0000_00FF,
        attributes: [.bold],
        source: .terminal),
      .rect(CGRect(x: 200, y: 0, width: 20, height: 10), color: 0x0000_00FF, source: .terminal),
      .cursor(CGRect(x: 200, y: 0, width: 10, height: 20), color: 0xFFFF_FFFF),
    ]
    let sampler = DebugPixelProbeSampler(width: 640, height: 480) { x, y in
      (x, y) == (4, 5) ? 0x0102_0304 : nil
    }

    let response = DebugRenderTraceBuilder(
      frame: 7,
      windowWidth: 640,
      windowHeight: 480,
      sidebarWidth: 200,
      surfaceWidth: 640,
      surfaceHeight: 480,
      surfaceScale: 2,
      cellWidth: 10,
      cellHeight: 20,
      hasActiveTab: true,
      terminalSnapshot: DebugRenderTraceTerminalSnapshot(
        sessionId: "session-1", rows: 24, cols: 80),
      commands: commands,
      limit: 2,
      pixelProbes: [PixelProbeReq(name: "cursor", x: 4, y: 5)],
      pixelSampler: sampler
    ).response()

    XCTAssertEqual(response.traceId, "frame-7")
    XCTAssertEqual(response.backend, "software")
    XCTAssertEqual(response.surface.width, 640)
    XCTAssertEqual(response.surface.scale, 2)
    XCTAssertEqual(response.sources.map(\.id), ["state-7", "term-snap-7"])
    XCTAssertEqual(response.layout.first { $0.id == "layout-terminal" }?.rect.width, 440)
    XCTAssertEqual(response.packets.first?.sourceRefs, ["term-snap-7"])
    XCTAssertEqual(response.packets.first?.glyphRuns, 1)
    XCTAssertEqual(response.packets.first?.backgroundRuns, 1)
    XCTAssertEqual(response.commandRanges.map(\.producer), ["sidebar", "terminal"])
    XCTAssertEqual(response.commandRanges[0].firstCommandId, "cmd-0")
    XCTAssertEqual(response.commandRanges[0].lastCommandId, "cmd-0")
    XCTAssertEqual(response.commandRanges[1].firstCommandId, "cmd-1")
    XCTAssertEqual(response.commandRanges[1].lastCommandId, "cmd-2")
    XCTAssertEqual(response.commands.map(\.id), ["cmd-0", "cmd-1"])
    XCTAssertTrue(response.truncated)
    XCTAssertEqual(response.passes.first?.draws.first?.commandRefs, ["cmd-0", "cmd-1"])
    XCTAssertEqual(response.pixelProbes.first?.rgba, [1, 2, 3, 4])
    XCTAssertEqual(response.invariants.first?.kind, "renderer.software")
  }

  func testTraceBuilderOmitsTerminalPacketWithoutActiveTab() {
    let response = DebugRenderTraceBuilder(
      frame: 8,
      windowWidth: 100,
      windowHeight: 80,
      sidebarWidth: 120,
      surfaceWidth: 100,
      surfaceHeight: 80,
      surfaceScale: 1,
      cellWidth: 8,
      cellHeight: 16,
      hasActiveTab: false,
      terminalSnapshot: nil,
      commands: [],
      limit: 10,
      pixelProbes: nil,
      pixelSampler: DebugPixelProbeSampler(width: 100, height: 80) { _, _ in nil }
    ).response()

    XCTAssertEqual(response.sources.map(\.id), ["state-8"])
    XCTAssertTrue(response.packets.isEmpty)
    XCTAssertEqual(response.layout.first { $0.id == "layout-terminal" }?.rect.width, 1)
    XCTAssertEqual(response.passes.first?.draws.count, 0)
    XCTAssertFalse(response.truncated)
  }
}
