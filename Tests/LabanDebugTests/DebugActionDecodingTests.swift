import XCTest

@testable import LabanDebug

final class DebugActionDecodingTests: XCTestCase {
  func testDecodesResizePayloadFromFlatWireShape() throws {
    guard
      case .resizeWindow(let request) = try decode(
        #"{"action":"resizeWindow","width":132,"height":44}"#
      )
    else {
      return XCTFail("Expected resizeWindow action")
    }

    XCTAssertEqual(request.width, 132)
    XCTAssertEqual(request.height, 44)
  }

  func testDecodesKeyPayloadFromFlatWireShape() throws {
    guard
      case .key(let request) = try decode(
        #"{"action":"key","key":"ArrowLeft","type":"keyDown","modifiers":["shift"],"text":"x"}"#
      )
    else {
      return XCTFail("Expected key action")
    }

    XCTAssertEqual(request.key, "ArrowLeft")
    XCTAssertEqual(request.type, "keyDown")
    XCTAssertEqual(request.modifiers, ["shift"])
    XCTAssertEqual(request.text, "x")
  }

  func testDecodesDropFilesPayloadFromFlatWireShape() throws {
    guard
      case .dropFiles(let request) = try decode(
        #"{"action":"dropFiles","paths":["/tmp/a.png","/tmp/file with spaces.pdf"]}"#
      )
    else {
      return XCTFail("Expected dropFiles action")
    }

    XCTAssertEqual(request.paths, ["/tmp/a.png", "/tmp/file with spaces.pdf"])
  }

  func testDecodesPayloadFreeActions() throws {
    guard case .paste = try decode(#"{"action":"paste","ignored":true}"#) else {
      return XCTFail("Expected paste action")
    }
  }

  func testDecodesFindActions() throws {
    guard
      case .findStart(let start) = try decode(
        #"{"action":"find.start","sessionID":"s1","needle":"apple"}"#
      )
    else {
      return XCTFail("Expected find.start action")
    }
    XCTAssertEqual(start.targetSessionId, "s1")
    XCTAssertEqual(start.needle, "apple")

    guard case .findStep(let step) = try decode(#"{"action":"find.step","direction":"previous"}"#)
    else {
      return XCTFail("Expected find.step action")
    }
    XCTAssertEqual(step.direction, "previous")

    guard case .findStop = try decode(#"{"action":"find.stop"}"#) else {
      return XCTFail("Expected find.stop action")
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
