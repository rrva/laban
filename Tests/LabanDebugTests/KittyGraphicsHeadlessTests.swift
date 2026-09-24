import Foundation
import LabanCore
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanDebug

/// Kitty graphics in the headless runtime: rendered frames draw the image,
/// `/debug/render` reports it, and captures carry the pixels so renderer
/// replay reproduces the frame (execplans/active/kitty-graphics-rendering.md,
/// Milestone 2).
final class KittyGraphicsHeadlessTests: XCTestCase {
  private let checker = "\u{1b}_Gi=7,a=T,f=24,s=2,v=2,c=8,r=4,q=2;/wAAAP8AAAD/////\u{1b}\\"

  override func setUp() {
    super.setUp()
    laban_set_kitty_graphics_enabled(true)
  }

  override func tearDown() {
    laban_set_kitty_graphics_enabled(false)
    super.tearDown()
  }

  func testRenderStateReportsDrawnImage() throws {
    let artifacts = temporaryDirectory("kitty-render-state")
    defer { try? FileManager.default.removeItem(at: artifacts) }
    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil, artifactsURL: artifacts, tempURL: nil, deterministic: true,
      runId: "kitty-render-state")

    feed(runtime, checker)
    _ = try runtime.screenshotBytes()

    let render = try json(runtime.renderState())
    let lastDraw = try XCTUnwrap(render["lastDraw"] as? [String: Any])
    XCTAssertEqual(lastDraw["images"] as? Int, 1)
    let kitty = try XCTUnwrap(render["kittyGraphics"] as? [String: Any])
    XCTAssertEqual(kitty["enabled"] as? Bool, true)
    XCTAssertGreaterThanOrEqual(kitty["storedImages"] as? Int ?? 0, 1)
  }

  func testCaptureReplaysImageFramesFromSidecarPixels() throws {
    let artifacts = temporaryDirectory("kitty-replay")
    defer { try? FileManager.default.removeItem(at: artifacts) }
    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil, artifactsURL: artifacts, tempURL: nil, deterministic: true,
      runId: "kitty-replay", captureName: "kitty-replay", captureScreenshots: .final)

    feed(runtime, checker)
    let stop = runtime.stopCapture()
    XCTAssertEqual(stop.status, 200)
    let capture = URL(fileURLWithPath: try XCTUnwrap(try json(stop)["directory"] as? String))

    let imagesDir = capture.appendingPathComponent("images")
    let sidecars = try FileManager.default.contentsOfDirectory(atPath: imagesDir.path)
    XCTAssertEqual(sidecars.count, 1, "the image's pixels are saved once")
    let resourceId = try XCTUnwrap(
      UInt64(sidecars[0].replacingOccurrences(of: "image-", with: "")
        .replacingOccurrences(of: ".rgba", with: "")))

    // A replay process never held the image: drop it and replay from disk.
    FrameImageStore.shared.remove([resourceId])
    let report = try CaptureReplayRunner(captureURL: capture, mode: .renderer).run()
    XCTAssertEqual(report.rendererReplay, "passed")
    XCTAssertTrue(report.mismatches.isEmpty, "\(report.mismatches)")
    XCTAssertFalse(FrameImageStore.shared.contains(resourceId), "replay cleans up after itself")

    // Without the sidecar the replayed frame lacks the image and must differ.
    try FileManager.default.removeItem(at: imagesDir.appendingPathComponent(sidecars[0]))
    let missing = try CaptureReplayRunner(captureURL: capture, mode: .renderer).run()
    XCTAssertFalse(missing.mismatches.isEmpty, "a frame replayed without its image must mismatch")
  }

  // MARK: - Helpers

  private func feed(_ runtime: HeadlessDebugRuntime, _ text: String) {
    let body = try! JSONSerialization.data(withJSONObject: ["action": "feedOutput", "text": text])
    let response = runtime.applyAction(body)
    XCTAssertEqual(response.status, 200, String(data: response.body, encoding: .utf8) ?? "")
  }

  private func json(_ response: DebugResponse) throws -> [String: Any] {
    XCTAssertEqual(response.status, 200)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
  }

  private func temporaryDirectory(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-\(name)-\(UUID().uuidString)")
  }
}
