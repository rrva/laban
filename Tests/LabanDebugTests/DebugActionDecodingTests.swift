import LabanCore
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

  func testDecodesSetFontSizePayloadFromFlatWireShape() throws {
    guard
      case .setFontSize(let request) = try decode(
        #"{"action":"setFontSize","pointSize":20}"#
      )
    else {
      return XCTFail("Expected setFontSize action")
    }

    XCTAssertEqual(request.pointSize, 20)
  }

  func testDecodesSetRendererPayloadFromFlatWireShape() throws {
    guard
      case .setRenderer(let request) = try decode(
        #"{"action":"setRenderer","renderer":"vectorGlyph"}"#
      )
    else {
      return XCTFail("Expected setRenderer action")
    }

    XCTAssertEqual(request.renderer, "vectorGlyph")
  }

  func testSetRendererSchemaIncludesSlugGlyph() throws {
    let schema = SetRendererActionRequest.jsonSchema.toJSONSchema()
    let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
    let renderer = try XCTUnwrap(properties["renderer"] as? [String: Any])
    let values = try XCTUnwrap(renderer["enum"] as? [String])
    XCTAssertTrue(values.contains("slugGlyph"))
  }

  func testSetBackgroundTransparencyDecodesOptionalBackdropStyle() throws {
    guard
      case .setBackgroundTransparency(let request) = try decode(
        #"{"action":"setBackgroundTransparency","opacity":0.7,"applyToExplicitCellBackgrounds":false,"backdropStyle":"systemBlur"}"#
      )
    else {
      return XCTFail("Expected setBackgroundTransparency action")
    }
    XCTAssertEqual(request.backdropStyle, .systemBlur)

    guard
      case .setBackgroundTransparency(let imageRequest) = try decode(
        #"{"action":"setBackgroundTransparency","opacity":0.7,"applyToExplicitCellBackgrounds":false,"backdropStyle":"image"}"#
      )
    else {
      return XCTFail("Expected image setBackgroundTransparency action")
    }
    XCTAssertEqual(imageRequest.backdropStyle, .image)

    guard
      case .setBackgroundTransparency(let legacyRequest) = try decode(
        #"{"action":"setBackgroundTransparency","opacity":0.7,"applyToExplicitCellBackgrounds":false}"#
      )
    else {
      return XCTFail("Expected legacy setBackgroundTransparency action")
    }
    XCTAssertNil(legacyRequest.backdropStyle)
    XCTAssertThrowsError(
      try decode(
        #"{"action":"setBackgroundTransparency","opacity":0.7,"applyToExplicitCellBackgrounds":false,"backdropStyle":"system-blur"}"#
      ))
  }

  func testSetBackgroundTransparencySchemaHasOptionalBackdropStyleEnum() throws {
    let schema = SetBackgroundTransparencyActionRequest.jsonSchema.toJSONSchema()
    let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
    let backdropStyle = try XCTUnwrap(properties["backdropStyle"] as? [String: Any])
    XCTAssertEqual(backdropStyle["enum"] as? [String], ["none", "systemBlur", "image"])
    let required = try XCTUnwrap(schema["required"] as? [String])
    XCTAssertFalse(required.contains("backdropStyle"))
  }

  func testDecodesTypedBackgroundImageActions() throws {
    guard
      case .setBackgroundSource(let source) = try decode(
        #"{"action":"setBackgroundSource","source":"image"}"#)
    else { return XCTFail("Expected setBackgroundSource action") }
    XCTAssertEqual(source.source, .image)

    guard
      case .setBackgroundImageScaling(let scaling) = try decode(
        #"{"action":"setBackgroundImageScaling","scaling":"stretch"}"#)
    else { return XCTFail("Expected setBackgroundImageScaling action") }
    XCTAssertEqual(scaling.scaling, .stretch)

    guard
      case .importBackgroundImage(let image) = try decode(
        #"{"action":"importBackgroundImage","path":"images/test.svg","scaling":"fit"}"#)
    else { return XCTFail("Expected importBackgroundImage action") }
    XCTAssertEqual(image.path, "images/test.svg")
    XCTAssertEqual(image.scaling, .fit)

    guard case .removeBackgroundImage = try decode(#"{"action":"removeBackgroundImage"}"#)
    else { return XCTFail("Expected removeBackgroundImage action") }
  }

  func testDecodesSetPreeditPayloadFromFlatWireShape() throws {
    guard
      case .setPreedit(let request) = try decode(
        #"{"action":"setPreedit","sessionId":"s1","text":"中👩‍💻a","caretCells":3}"#
      )
    else {
      return XCTFail("Expected setPreedit action")
    }

    XCTAssertEqual(request.sessionId, "s1")
    XCTAssertEqual(request.text, "中👩‍💻a")
    XCTAssertEqual(request.caretCells, 3)
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

  func testDebugActionMapsToIntentIDs() throws {
    XCTAssertEqual(
      try decode(#"{"action":"selectTab","tabId":"tab-1"}"#).intent,
      .tabSelect(TabSelectInput(tabId: "tab-1")))
    XCTAssertEqual(
      try decode(#"{"action":"typeText","text":"hello"}"#).intent,
      .terminalTypeText(TypeTextInput(text: "hello")))
    XCTAssertEqual(
      try decode(#"{"action":"key","key":"Enter","modifiers":["cmd"]}"#).intent,
      .terminalSendKey(SendKeyInput(key: "Enter", modifiers: ["cmd"])))
    XCTAssertEqual(try decode(#"{"action":"feedOutput"}"#).intentID, "fixture.feedOutput")
    XCTAssertEqual(try decode(#"{"action":"setRenderer"}"#).intentID, "renderer.set")
    XCTAssertEqual(try decode(#"{"action":"setPreedit"}"#).intentID, "preedit.set")
    XCTAssertEqual(
      try decode(#"{"action":"futureAction"}"#).intent,
      .unsupportedDebugAction(UnsupportedDebugActionInput(action: "futureAction")))
  }

  func testEveryKnownDebugActionNameMapsToCatalogDescriptor() throws {
    for action in DebugActionIntentID.knownActionNames {
      let payload: String
      switch action {
      case "setBackgroundTransparency":
        payload =
          #"{"action":"setBackgroundTransparency","opacity":0.7,"applyToExplicitCellBackgrounds":false}"#
      case "setNativeFullScreen":
        payload = #"{"action":"setNativeFullScreen","enabled":false}"#
      case "setBackgroundSource":
        payload = #"{"action":"setBackgroundSource","source":"none"}"#
      case "setBackgroundImageScaling":
        payload = #"{"action":"setBackgroundImageScaling","scaling":"fill"}"#
      case "importBackgroundImage":
        payload = #"{"action":"importBackgroundImage","path":"image.svg","scaling":"fill"}"#
      default:
        payload = #"{"action":"\#(action)"}"#
      }
      let decoded = try decode(payload)
      XCTAssertNotNil(IntentCatalog.all.descriptor(id: decoded.intentID), action)
    }
  }

  func testMissingDiscriminatorFailsDecoding() {
    XCTAssertThrowsError(try decode(#"{"width":132,"height":44}"#))
  }

  private func decode(_ json: String) throws -> DebugAction {
    try JSONDecoder().decode(DebugAction.self, from: Data(json.utf8))
  }
}
