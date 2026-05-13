import CoreGraphics
import LabanRenderer
import XCTest

@testable import LabanDebug

final class DebugFrameCommandSerializerTests: XCTestCase {
  func testListCommandSerializesGlyphRunDecorations() {
    let serializer = DebugFrameCommandSerializer(cellWidth: 9, cellHeight: 18)
    let command = FrameCommand.glyphRun(
      origin: CGPoint(x: 12, y: 24),
      text: "ab",
      foreground: 0x1122_3344,
      background: 0x5566_7788,
      attributes: [.bold, .underline],
      source: .terminal,
      underlineStyle: .curly,
      underlineColor: 0x0102_0304,
      hyperlink: "https://example.test"
    )

    let response = serializer.listCommand(command, index: 7, includeText: true)

    XCTAssertEqual(response.id, "cmd-7")
    XCTAssertEqual(response.kind, "glyphRun")
    XCTAssertEqual(response.source, "terminal")
    XCTAssertEqual(response.rect?.x, 12)
    XCTAssertEqual(response.rect?.y, 24)
    XCTAssertEqual(response.rect?.width, 18)
    XCTAssertEqual(response.rect?.height, 18)
    XCTAssertEqual(response.foreground, [17, 34, 51, 68])
    XCTAssertEqual(response.background, [85, 102, 119, 136])
    XCTAssertEqual(response.text, "ab")
    XCTAssertEqual(response.attributes, ["bold", "underline"])
    XCTAssertEqual(response.underlineStyle, "curly")
    XCTAssertEqual(response.underlineColor, [1, 2, 3, 4])
    XCTAssertEqual(response.hyperlink, "https://example.test")
  }

  func testListCommandCanHideTextPayload() {
    let serializer = DebugFrameCommandSerializer(cellWidth: 10, cellHeight: 20)
    let command = FrameCommand.glyphRun(
      origin: .zero,
      text: "secret",
      foreground: 0,
      background: 0,
      attributes: [],
      source: .sidebar
    )

    let response = serializer.listCommand(command, index: 0, includeText: false)

    XCTAssertNil(response.text)
    XCTAssertNil(response.attributes)
  }

  func testTraceCommandAndKindShareCommandNames() {
    let serializer = DebugFrameCommandSerializer(cellWidth: 10, cellHeight: 20)
    let command = FrameCommand.selection(
      CGRect(x: 1, y: 2, width: 3, height: 4), color: 0xAABB_CCDD)

    let trace = serializer.traceCommand(command, index: 2)

    XCTAssertEqual(DebugFrameCommandSerializer.kind(command), "selection")
    XCTAssertEqual(trace.id, "cmd-2")
    XCTAssertEqual(trace.kind, "selection")
    XCTAssertEqual(trace.source, "selection")
    XCTAssertEqual(trace.rect?.x, 1)
    XCTAssertEqual(trace.rect?.y, 2)
    XCTAssertEqual(trace.rect?.width, 3)
    XCTAssertEqual(trace.rect?.height, 4)
  }
}
