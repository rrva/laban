import Metal
import XCTest

@testable import LabanRenderer

/// `pngData` used to do the GPU wait, the CPU copy, the `CGImage` build and the
/// PNG deflate in one synchronous accessor, and per-frame capture called it from
/// the frame loop — so a full-surface libpng deflate ran on the main thread for
/// every captured frame. `renderedPixelSnapshot()` is the cheap half; the
/// encode moved to a background queue. The split has to be byte-for-byte
/// invisible in the artifact, because a capture's `pixelHash` is the sha256 of
/// exactly these bytes and the replay harness compares against it.
final class RenderedPixelSnapshotTests: XCTestCase {

  private var frame: [FrameCommand] {
    [
      .rect(CGRect(x: 0, y: 0, width: 32, height: 32), color: 0x2233_44FF, source: .terminal),
      .rect(CGRect(x: 4, y: 4, width: 8, height: 8), color: 0xCC55_22FF, source: .terminal),
    ]
  }

  func testSnapshotEncodeMatchesPNGDataForEveryGPUBackend() throws {
    try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "no Metal device")
    let atlas = FontAtlas(pointSize: 14)
    var backends: [(String, RendererBackend)] = []
    if let vector = VectorGlyphRenderer(fontAtlas: atlas, pixelWidth: 32, pixelHeight: 32) {
      backends.append(("vectorGlyph", vector))
    }
    if let slug = SlugGlyphRenderer(fontAtlas: atlas, pixelWidth: 32, pixelHeight: 32) {
      backends.append(("slugGlyph", slug))
    }
    try XCTSkipIf(backends.isEmpty, "no GPU backend could be created")

    for (name, backend) in backends {
      XCTAssertTrue(backend.render(frame, damage: .full), "\(name) render")
      let snapshot = try XCTUnwrap(backend.renderedPixelSnapshot(), "\(name) snapshot")
      XCTAssertEqual(snapshot.width, backend.surfaceWidth, "\(name) width")
      XCTAssertEqual(snapshot.height, backend.surfaceHeight, "\(name) height")
      XCTAssertEqual(snapshot.bytesPerRow, snapshot.width * 4, "\(name) stride")
      XCTAssertEqual(snapshot.pixels.count, snapshot.bytesPerRow * snapshot.height)
      XCTAssertEqual(
        snapshot.encodePNG(), backend.pngData,
        "\(name): deferring the encode must not change a single artifact byte")
    }
  }

  /// The host falls back to the synchronous `pngData` when a backend has no raw
  /// pixels to hand over. The software backend holds an already-realised bitmap
  /// rather than a GPU texture, so it opts out — and the fallback in
  /// `TerminalBitmapView.recordCapturedFrame` depends on that being nil.
  func testSoftwareBackendHasNoRawPixelSnapshot() {
    let backend = SoftwareBackend(
      fontAtlas: FontAtlas(pointSize: 14), pixelWidth: 8, pixelHeight: 8)
    _ = backend.render([
      .rect(CGRect(x: 0, y: 0, width: 8, height: 8), color: 0x1122_33FF, source: .terminal)
    ])
    XCTAssertNil(backend.renderedPixelSnapshot())
    XCTAssertNotNil(backend.pngData, "the fallback path still has to produce pixels")
  }
}
