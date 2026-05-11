import XCTest

@testable import LabanDebug

final class DebugActionDecodingTests: XCTestCase {
  func testDecodesResizePayloadFromFlatWireShape() throws {
    guard case .resizeWindow(let request) = try decode(
      #"{"action":"resizeWindow","width":132,"height":44}"#
    ) else {
      return XCTFail("Expected resizeWindow action")
    }

    XCTAssertEqual(request.width, 132)
    XCTAssertEqual(request.height, 44)
  }

  func testDecodesKeyPayloadFromFlatWireShape() throws {
    guard case .key(let request) = try decode(
      #"{"action":"key","key":"ArrowLeft","type":"keyDown","modifiers":["shift"],"text":"x"}"#
    ) else {
      return XCTFail("Expected key action")
    }

    XCTAssertEqual(request.key, "ArrowLeft")
    XCTAssertEqual(request.type, "keyDown")
    XCTAssertEqual(request.modifiers, ["shift"])
    XCTAssertEqual(request.text, "x")
  }

  func testDecodesPayloadFreeActions() throws {
    guard case .paste = try decode(#"{"action":"paste","ignored":true}"#) else {
      return XCTFail("Expected paste action")
    }
  }

  func testUnknownActionDecodesAsUnsupported() throws {
    guard case .unsupported(let action) = try decode(#"{"action":"futureAction"}"#) else {
      return XCTFail("Expected unsupported action")
    }

    XCTAssertEqual(action, "futureAction")
  }

  func testMissingDiscriminatorFailsDecoding() {
    XCTAssertThrowsError(try decode(#"{"width":132,"height":44}"#))
  }

  private func decode(_ json: String) throws -> DebugAction {
    try JSONDecoder().decode(DebugAction.self, from: Data(json.utf8))
  }
}
