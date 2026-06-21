import Foundation
import XCTest

@testable import LabanDebug

final class EmojiRenderingHeadlessTests: XCTestCase {
  private let defaultsKey = "LabanEmojiRenderingMode"

  override func setUp() {
    super.setUp()
    UserDefaults.standard.removeObject(forKey: defaultsKey)
  }

  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: defaultsKey)
    super.tearDown()
  }

  func testStateReportsDefaultMonochromeEmojiRendering() throws {
    let (runtime, artifacts) = try makeRuntime(runId: "emoji-rendering-default")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let settings = try emojiRendering(from: runtime.state())
    XCTAssertEqual(settings["mode"] as? String, "monochrome")
    XCTAssertEqual(settings["effectiveMode"] as? String, "monochrome")
  }

  func testStateAndRenderReportColorEmojiRendering() throws {
    UserDefaults.standard.set("color", forKey: defaultsKey)
    let (runtime, artifacts) = try makeRuntime(runId: "emoji-rendering-color")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let stateSettings = try emojiRendering(from: runtime.state())
    XCTAssertEqual(stateSettings["mode"] as? String, "color")
    XCTAssertEqual(stateSettings["effectiveMode"] as? String, "color")

    let renderSettings = try emojiRendering(from: runtime.renderState())
    XCTAssertEqual(renderSettings["mode"] as? String, "color")
    XCTAssertEqual(renderSettings["effectiveMode"] as? String, "color")
  }

  private func makeRuntime(runId: String) throws -> (HeadlessDebugRuntime, URL) {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-\(runId)-\(UUID().uuidString)")
    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: runId)
    return (runtime, artifacts)
  }

  private func emojiRendering(from response: DebugResponse) throws -> [String: Any] {
    XCTAssertEqual(response.status, 200)
    let obj = try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
    return try XCTUnwrap(
      obj["emojiRendering"] as? [String: Any],
      "debug response must include emojiRendering")
  }
}
