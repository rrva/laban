import CoreGraphics
import CryptoKit
import Foundation
import LabanRenderer
import Metal
import XCTest

@testable import LabanDebug

/// Renderer-replay regression gate for
/// `execplans/active/slug-render-loop-perf-and-aa-quality.md`.
///
/// `scripts/replay-capture --mode=renderer` (`CaptureReplayRunner.runRendererReplay`)
/// always re-renders through `SoftwareRenderer`, so it cannot validate Slug's
/// own pixel output (see M0 Concrete Steps and Artifacts and Notes). This
/// test instead records a capture with `slugGlyph` selected, then replays
/// each captured frame's command list through a fresh `SlugGlyphRenderer` and
/// compares the resulting PNG hash against the `pixelHash` recorded in the
/// matching `frame-*.render.json` sidecar at capture time. This is the
/// mechanism the plan's M1/M2 acceptance criteria ("renderer replay of the M0
/// capture byte-identical") depends on; run it before and after each
/// milestone's changes.
final class SlugGlyphCaptureReplayTests: XCTestCase {
  func testSlugRendererReproducesCapturedPixelHashes() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-slug-capture-replay-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "slug-capture-replay",
      rendererSelection: .slugGlyph,
      captureName: "slug-capture-replay",
      captureScreenshots: .none
    )

    _ = runtime.applyAction(
      #"{"action":"typeText","text":"echo hello world"}"#.data(using: .utf8)!)
    _ = runtime.applyAction(#"{"action":"key","key":"Enter"}"#.data(using: .utf8)!)
    _ = runtime.applyAction(#"{"action":"advanceFrames","count":5}"#.data(using: .utf8)!)
    _ = runtime.applyAction(#"{"action":"typeText","text":"ls -la"}"#.data(using: .utf8)!)
    _ = runtime.applyAction(#"{"action":"advanceFrames","count":5}"#.data(using: .utf8)!)

    let stop = runtime.stopCapture()
    XCTAssertEqual(stop.status, 200)
    let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: stop.body) as? [String: Any])
    let dir = try XCTUnwrap(obj["directory"] as? String)
    let framesDir = URL(fileURLWithPath: dir).appendingPathComponent("frames", isDirectory: true)

    let commandFiles =
      try FileManager.default
      .contentsOfDirectory(at: framesDir, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasSuffix(".commands.json") }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    XCTAssertGreaterThan(commandFiles.count, 0, "expected at least one captured frame")

    var framesVerified = 0
    for commandsURL in commandFiles {
      let frameName = commandsURL.lastPathComponent.replacingOccurrences(
        of: ".commands.json", with: "")
      let renderURL = framesDir.appendingPathComponent("\(frameName).render.json")
      let renderInfo = try JSONDecoder().decode(
        CapturedRenderInfo.self, from: Data(contentsOf: renderURL))
      XCTAssertEqual(renderInfo.backend, "slugGlyph")
      guard let expectedHash = renderInfo.pixelHash else { continue }

      let captured = try JSONDecoder().decode(
        CapturedFrameCommands.self, from: Data(contentsOf: commandsURL))
      let commands = FrameCommandCaptureCodec.commands(from: captured.commands)

      let renderer = try XCTUnwrap(
        SlugGlyphRenderer(
          fontAtlas: FontAtlas(pointSize: FontAtlas.persistedTerminalPointSize),
          pixelWidth: max(renderInfo.surface.width, 1),
          pixelHeight: max(renderInfo.surface.height, 1),
          scale: CGFloat(renderInfo.surface.scale)),
        "SlugGlyphRenderer unavailable while replaying \(frameName)")
      renderer.waitForFrameCompletion = true
      renderer.presentsToLayer = false
      _ = renderer.render(commands, damage: .full)

      let png = try XCTUnwrap(renderer.pngData, "no PNG produced for \(frameName)")
      let actualHash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
      XCTAssertEqual(
        actualHash, expectedHash,
        "\(frameName) pixel hash mismatch between a fresh Slug render and the capture recorded "
          + "at capture time")
      framesVerified += 1
    }

    XCTAssertGreaterThan(framesVerified, 0, "no slugGlyph frames had a recorded pixel hash")
  }
}

private struct CapturedRenderInfo: Decodable {
  var frame: Int
  var backend: String
  var surface: CapturedSurface
  var pixelHash: String?
}
