import CoreGraphics
import CryptoKit
import Foundation
import Metal
import XCTest

@testable import LabanRenderer

/// M4 correctness gate for
/// `execplans/active/slug-render-loop-perf-and-aa-quality.md`: the geometry
/// arrays (`curves`/`glyphs`/`bands`/`bandIndices`) are append-only, and
/// `ensureGeometryBuffersIfNeeded` now grows their backing `MTLBuffer`s
/// incrementally (tail-only writes within capacity, capacity-doubling
/// reallocation-and-recopy-from-CPU-array on overflow) instead of
/// re-uploading the whole array every time any glyph is new. This test
/// proves incremental growth produces pixel-identical output to a from-
/// scratch single-shot upload of the same final geometry, across enough new
/// glyphs to force multiple capacity-doubling reallocations.
final class SlugGlyphIncrementalGeometryUploadTests: XCTestCase {
  func testIncrementalBufferGrowthMatchesFreshSingleShotUpload() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let cols = 60
    let rows = 20
    let cellW: CGFloat = 9
    let cellH: CGFloat = 19
    let scale: CGFloat = 2
    let pixelW = Int(CGFloat(cols) * cellW * scale)
    let pixelH = Int(CGFloat(rows) * cellH * scale)

    let renderer = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: FontAtlas(pointSize: 14),
        pixelWidth: pixelW,
        pixelHeight: pixelH,
        scale: scale))
    renderer.waitForFrameCompletion = true
    renderer.presentsToLayer = false

    // Walk well past the incremental buffer's initial 1024-element capacity
    // (Latin Extended Additional has simple, few-curve outlines, so plenty
    // of new glyphs are needed to grow `curves`/`bands`/`bandIndices` past
    // that threshold; 40 frames x 20 new glyphs = 800 unique glyphs is
    // comfortably enough to force at least one doubling for every array).
    var nextScalar: UInt32 = 0x1E00
    var allNewText = ""
    let framesToIntroduce = 40
    let glyphsPerFrame = 20
    let uploadsBefore = renderer.geometryBufferUploadCount
    for frame in 0..<framesToIntroduce {
      var line = ""
      for _ in 0..<glyphsPerFrame {
        guard let scalar = Unicode.Scalar(nextScalar) else { continue }
        line.unicodeScalars.append(scalar)
        allNewText.unicodeScalars.append(scalar)
        nextScalar += 1
      }
      let row = frame % rows
      XCTAssertTrue(
        renderer.render(
          [
            .rect(
              CGRect(x: 0, y: 0, width: CGFloat(pixelW) / scale, height: CGFloat(pixelH) / scale),
              color: 0x10_10_10_FF, source: .terminal),
            .glyphRun(
              origin: CGPoint(x: 4, y: CGFloat(row) * cellH + 4),
              text: line,
              foreground: 0xEE_EE_EE_FF,
              background: 0x10_10_10_FF,
              attributes: [],
              source: .terminal),
          ],
          damage: .full),
        "frame \(frame) failed to render")
    }
    let uploadsAfter = renderer.geometryBufferUploadCount
    XCTAssertGreaterThan(
      uploadsAfter, uploadsBefore,
      "introducing new glyphs across frames must trigger geometry buffer uploads")

    // Final frame: every glyph introduced above, all on screen together, on
    // the incrementally-grown renderer.
    let finalCommands: [FrameCommand] = [
      .rect(
        CGRect(x: 0, y: 0, width: CGFloat(pixelW) / scale, height: CGFloat(pixelH) / scale),
        color: 0x10_10_10_FF, source: .terminal),
      .glyphRun(
        origin: CGPoint(x: 4, y: 4),
        text: allNewText,
        foreground: 0xEE_EE_EE_FF,
        background: 0x10_10_10_FF,
        attributes: [],
        source: .terminal),
    ]
    XCTAssertTrue(renderer.render(finalCommands, damage: .full))
    let incrementalHash = hash(try XCTUnwrap(renderer.pngData))

    // Reference: a fresh renderer sees the exact same final frame in one
    // shot, so its geometry buffers are allocated and fully written once,
    // with no incremental growth involved.
    let reference = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: FontAtlas(pointSize: 14),
        pixelWidth: pixelW,
        pixelHeight: pixelH,
        scale: scale))
    reference.waitForFrameCompletion = true
    reference.presentsToLayer = false
    XCTAssertTrue(reference.render(finalCommands, damage: .full))
    let referenceHash = hash(try XCTUnwrap(reference.pngData))

    XCTAssertEqual(
      incrementalHash, referenceHash,
      "incrementally-grown geometry buffers must render identically to a fresh single-shot upload"
    )
  }

  /// Companion to `SlugGlyphRendererTests.testGestureZoomScalesRenderedPixelsWithoutRebuildingGeometry`:
  /// the M4 incremental path must preserve the existing "zoom never re-uploads
  /// geometry" contract (`geometryBufferUploadCount` only advances when a
  /// genuinely new glyph is appended, never merely because the projection
  /// changed).
  func testGestureZoomStillDoesNotTriggerGeometryUpload() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let renderer = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: FontAtlas(pointSize: 14),
        pixelWidth: 360,
        pixelHeight: 180,
        scale: 1))
    renderer.waitForFrameCompletion = true
    renderer.presentsToLayer = false
    let commands: [FrameCommand] = [
      .rect(CGRect(x: 0, y: 0, width: 360, height: 180), color: 0x00_00_00_FF, source: .terminal),
      .glyphRun(
        origin: CGPoint(x: 20, y: 36),
        text: "Slug",
        foreground: 0xFF_FF_FF_FF,
        background: 0x00_00_00_FF,
        attributes: [],
        source: .terminal),
    ]
    XCTAssertTrue(renderer.render(commands, damage: .full))
    let uploadsAfterFirstRender = renderer.geometryBufferUploadCount
    XCTAssertGreaterThan(uploadsAfterFirstRender, 0)

    renderer.setGestureZoom(1.75, anchor: CGPoint(x: 50, y: 50))
    for _ in 0..<5 {
      XCTAssertTrue(renderer.render(commands, damage: .full))
    }
    XCTAssertEqual(renderer.geometryBufferUploadCount, uploadsAfterFirstRender)
  }

  private func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
