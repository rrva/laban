import CoreGraphics
import Foundation
import ImageIO
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

  /// The same headless session drawn by software and by each Metal renderer
  /// through the real FrameProducer path: every pixel software paints in one
  /// of the image's four pure colors must carry that color in the Metal
  /// screenshot too.
  func testMetalRenderersDrawTheFixtureImageWhereSoftwareDoes() throws {
    let artifacts = temporaryDirectory("kitty-renderer-parity")
    defer { try? FileManager.default.removeItem(at: artifacts) }
    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil, artifactsURL: artifacts, tempURL: nil, deterministic: true,
      runId: "kitty-renderer-parity")
    feed(runtime, checker)

    let software = try XCTUnwrap(decode(try runtime.screenshotBytes().data))
    let pure: [[UInt8]] = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 255]]
    var imagePixels: [(index: Int, color: [UInt8])] = []
    for i in stride(from: 0, to: software.bytes.count, by: 4) {
      let rgb = Array(software.bytes[i..<i + 3])
      if pure.contains(rgb) { imagePixels.append((i, rgb)) }
    }
    XCTAssertGreaterThan(imagePixels.count, 400, "software must draw the checker")

    for renderer in ["classic", "gpuDriven", "slugGlyph"] {
      let body = try JSONSerialization.data(
        withJSONObject: ["action": "setRenderer", "renderer": renderer])
      guard runtime.applyAction(body).status == 200 else { continue }  // unavailable here
      feed(runtime, " ")  // a fresh frame through the new backend
      let metal = try XCTUnwrap(decode(try runtime.screenshotBytes().data), renderer)
      XCTAssertEqual(metal.bytes.count, software.bytes.count, renderer)
      guard metal.bytes.count == software.bytes.count else { continue }
      let mismatches = imagePixels.filter { pixel in
        zip(metal.bytes[pixel.index..<pixel.index + 3], pixel.color)
          .contains { abs(Int($0) - Int($1)) > 12 }
      }
      // Linear filtering may shade the one-pixel seams between quadrants.
      XCTAssertLessThan(
        Double(mismatches.count) / Double(imagePixels.count), 0.05,
        "\(renderer): \(mismatches.count) of \(imagePixels.count) image pixels differ")
    }
  }

  // MARK: - Helpers

  /// Straight RGBA8 in sRGB, row 0 = top.
  private func decode(_ png: Data) -> (width: Int, height: Int, bytes: [UInt8])? {
    guard let source = CGImageSourceCreateWithData(png as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let space = CGColorSpace(name: CGColorSpace.sRGB)
    else { return nil }
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: image.width, height: image.height,
          bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return true
    }
    return drawn ? (image.width, image.height, bytes) : nil
  }

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
