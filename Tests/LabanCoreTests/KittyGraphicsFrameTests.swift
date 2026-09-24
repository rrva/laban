import CoreGraphics
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanCore

/// Kitty graphics from snapshot to frame commands
/// (execplans/active/kitty-graphics-rendering.md, Milestone 2).
final class KittyGraphicsFrameTests: XCTestCase {
  /// 2x2 RGB image: red, green / blue, white.
  private let checkerBase64 = "/wAAAP8AAAD/////"
  private let producer = FrameProducer(cellWidth: 10, cellHeight: 20, originX: 100, originY: 0)

  override func setUp() {
    super.setUp()
    laban_set_kitty_graphics_enabled(true)
  }

  override func tearDown() {
    laban_set_kitty_graphics_enabled(false)
    super.tearDown()
  }

  func testQuadCoversPlacementCellsInFrameCoordinates() throws {
    let session = try makeSession(rows: 10)
    defer { laban_session_destroy(session) }
    write(session, "\u{1b}_Gi=7,a=T,f=24,s=2,v=2,c=8,r=4,q=2;\(checkerBase64)\u{1b}\\")

    let quads = try withSnapshot(session) { quads(in: producer.commands(from: $0)) }
    XCTAssertEqual(quads.count, 1)
    let quad = try XCTUnwrap(quads.first)
    // 8x4 cells of 10x20 pt at the top-left of a 10-row grid; frame y is
    // bottom-up, so the top 4 rows span y = 120...200.
    XCTAssertEqual(quad.rect, CGRect(x: 100, y: 120, width: 80, height: 80))
    XCTAssertEqual(quad.sourceRect, CGRect(x: 0, y: 0, width: 2, height: 2))
    XCTAssertEqual(quad.layer, .aboveText)
    XCTAssertNotEqual(quad.resourceId, 0)
  }

  func testQuadIsClippedAtTheTopAndSourceCroppedToMatch() throws {
    let session = try makeSession(rows: 10)
    defer { laban_session_destroy(session) }
    write(session, "\u{1b}_Gi=7,a=T,f=24,s=2,v=2,c=8,r=4,C=1,q=2;\(checkerBase64)\u{1b}\\")
    // Scroll the screen up two rows: the image's top half leaves the grid.
    write(session, "\u{1b}[10;1H\n\n")

    let quad = try XCTUnwrap(
      try withSnapshot(session) { quads(in: producer.commands(from: $0)) }.first)
    XCTAssertEqual(quad.rect, CGRect(x: 100, y: 160, width: 80, height: 40))
    XCTAssertEqual(
      quad.sourceRect, CGRect(x: 0, y: 1, width: 2, height: 1),
      "only the image's bottom row of pixels is still visible")
  }

  func testLayersSitAtTheirPlaceInTheCommandStream() throws {
    let session = try makeSession(rows: 10)
    defer { laban_session_destroy(session) }
    write(session, "\u{1b}_Gi=1,a=T,f=24,s=2,v=2,z=-1073741825,C=1,q=2;\(checkerBase64)\u{1b}\\")
    write(session, "\u{1b}_Gi=2,a=T,f=24,s=2,v=2,z=-1,C=1,q=2;\(checkerBase64)\u{1b}\\")
    write(session, "\u{1b}_Gi=3,a=T,f=24,s=2,v=2,z=1,C=1,q=2;\(checkerBase64)\u{1b}\\")
    // An explicit cell background and some text over the images.
    write(session, "\u{1b}[44mX\u{1b}[0mhello")

    let commands = try withSnapshot(session) { producer.commands(from: $0) }
    func index(of layer: ImageLayer) -> Int? {
      commands.firstIndex {
        if case .texturedQuad(_, _, _, let l, _) = $0 { return l == layer }
        return false
      }
    }
    let explicitBackground = commands.firstIndex {
      if case .rect(_, _, .terminal, .replace) = $0 { return true }
      return false
    }
    // Index 0 is the terminal-area rect; the explicit cell background follows.
    let cellBackground = commands.indices.dropFirst().first {
      if case .rect(_, _, .terminal, .replace) = commands[$0] { return true }
      return false
    }
    let firstGlyph = commands.firstIndex {
      if case .glyphRun = $0 { return true }
      return false
    }
    let cursor = commands.firstIndex {
      if case .cursor = $0 { return true }
      return false
    }
    let below = try XCTUnwrap(index(of: .belowBackground))
    let mid = try XCTUnwrap(index(of: .belowText))
    let above = try XCTUnwrap(index(of: .aboveText))
    XCTAssertEqual(explicitBackground, 0, "the terminal-area rect comes first")
    XCTAssertLessThan(below, try XCTUnwrap(cellBackground), "below-background before cell backgrounds")
    XCTAssertLessThan(try XCTUnwrap(cellBackground), mid, "below-text after cell backgrounds")
    XCTAssertLessThan(mid, try XCTUnwrap(firstGlyph), "below-text before text")
    XCTAssertLessThan(try XCTUnwrap(firstGlyph), above, "above-text after text")
    if let cursor { XCTAssertLessThan(above, cursor, "the cursor stays on top") }
  }

  func testOverlayCommandsCarryQuadsInLayerOrder() throws {
    let session = try makeSession(rows: 10)
    defer { laban_session_destroy(session) }
    write(session, "\u{1b}_Gi=3,a=T,f=24,s=2,v=2,z=1,C=1,q=2;\(checkerBase64)\u{1b}\\")
    write(session, "\u{1b}_Gi=2,a=T,f=24,s=2,v=2,z=-1,C=1,q=2;\(checkerBase64)\u{1b}\\")

    let layers = try withSnapshot(session) {
      quads(in: producer.overlayCommands(from: $0, selection: nil, cursorBlinkVisible: true))
        .map(\.layer)
    }
    XCTAssertEqual(layers, [.belowText, .aboveText])
  }

  func testNoCellPixelGeometryMeansNoQuads() throws {
    // Without cell pixel sizes the terminal core cannot size placements.
    let session = try makeSession(rows: 10, cellPixels: false)
    defer { laban_session_destroy(session) }
    write(session, "\u{1b}_Gi=7,a=T,f=24,s=2,v=2,c=8,r=4,q=2;\(checkerBase64)\u{1b}\\")
    XCTAssertEqual(try withSnapshot(session) { quads(in: producer.commands(from: $0)) }.count, 0)
  }

  func testPublisherPublishesOncePerGenerationAndRetiresUnusedImages() throws {
    let session = try makeSession(rows: 10)
    defer { laban_session_destroy(session) }
    let store = FrameImageStore()
    let publisher = KittyImagePublisher(store: store)

    write(session, "\u{1b}_Gi=7,a=T,f=24,s=2,v=2,q=2;\(checkerBase64)\u{1b}\\")
    let id = try publish(publisher, session)
    let image = try XCTUnwrap(store.image(for: id))
    XCTAssertEqual([image.width, image.height], [2, 2])
    XCTAssertEqual(Array(image.rgba.prefix(4)), [0xFF, 0, 0, 0xFF])

    // Deleted: no snapshot references the image any more; it stays for the
    // retention window, then leaves the store.
    write(session, "\u{1b}_Ga=d,d=A,q=2\u{1b}\\")
    for _ in 0..<KittyImagePublisher.retentionSnapshots {
      _ = try publish(publisher, session, expectPlacement: false)
    }
    XCTAssertNotNil(store.image(for: id), "kept while in-flight frames may reference it")
    _ = try publish(publisher, session, expectPlacement: false)
    XCTAssertNil(store.image(for: id), "retired after the retention window")
  }

  func testPublisherRemoveAllClearsItsImages() throws {
    let session = try makeSession(rows: 10)
    defer { laban_session_destroy(session) }
    let store = FrameImageStore()
    let publisher = KittyImagePublisher(store: store)
    write(session, "\u{1b}_Gi=7,a=T,f=24,s=2,v=2,q=2;\(checkerBase64)\u{1b}\\")
    _ = try publish(publisher, session)
    XCTAssertEqual(store.count, 1)
    publisher.removeAll()
    XCTAssertEqual(store.count, 0)
  }

  func testCaptureCodecRoundTripsQuadLayerAndSourceRect() {
    let quad = FrameCommand.texturedQuad(
      rect: CGRect(x: 1, y: 2, width: 30, height: 40), resourceId: 77, source: .image,
      layer: .belowText, sourceRect: CGRect(x: 0, y: 0.5, width: 2, height: 1.5))
    let decoded = FrameCommandCaptureCodec.commands(
      from: FrameCommandCaptureCodec.serialized([quad]))
    XCTAssertEqual(decoded.count, 1)
    guard case .texturedQuad(let rect, let id, let source, let layer, let sourceRect) = decoded[0]
    else { return XCTFail("expected texturedQuad") }
    XCTAssertEqual(rect, CGRect(x: 1, y: 2, width: 30, height: 40))
    XCTAssertEqual(id, 77)
    XCTAssertEqual(source, .image)
    XCTAssertEqual(layer, .belowText)
    XCTAssertEqual(sourceRect, CGRect(x: 0, y: 0.5, width: 2, height: 1.5))
  }

  // MARK: - Helpers

  private struct Quad {
    var rect: CGRect
    var resourceId: UInt64
    var layer: ImageLayer
    var sourceRect: CGRect
  }

  private func quads(in commands: [FrameCommand]) -> [Quad] {
    commands.compactMap {
      guard case .texturedQuad(let rect, let id, _, let layer, let sourceRect) = $0 else {
        return nil
      }
      return Quad(rect: rect, resourceId: id, layer: layer, sourceRect: sourceRect)
    }
  }

  private func makeSession(rows: Int32, cellPixels: Bool = true) throws -> OpaquePointer {
    var config = LabanLaunchConfig()
    config.fixture_mode = 1
    var size = LabanTerminalSize()
    size.rows = rows
    size.cols = 40
    if cellPixels {
      size.cell_width = 10
      size.cell_height = 20
    }
    var session: OpaquePointer?
    XCTAssertEqual(laban_session_create(&config, size, &session), 0)
    return try XCTUnwrap(session)
  }

  private func write(_ session: OpaquePointer, _ text: String) {
    let bytes = Array(text.utf8)
    bytes.withUnsafeBytes { buf in
      _ = laban_session_write(
        session, buf.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count)
    }
  }

  private func withSnapshot<T>(
    _ session: OpaquePointer, _ body: (UnsafePointer<LabanSnapshot>) throws -> T
  ) throws -> T {
    var snap: UnsafeMutablePointer<LabanSnapshot>?
    XCTAssertEqual(laban_session_snapshot(session, &snap), 0)
    let s = try XCTUnwrap(snap)
    defer { laban_snapshot_destroy(s) }
    return try body(UnsafePointer(s))
  }

  /// Publishes one snapshot and returns its first placement's resource id.
  @discardableResult
  private func publish(
    _ publisher: KittyImagePublisher, _ session: OpaquePointer, expectPlacement: Bool = true
  ) throws -> UInt64 {
    try withSnapshot(session) { snap in
      publisher.publish(snapshot: snap, session: session)
      let count = snap.pointee.image_placement_count
      XCTAssertEqual(count > 0, expectPlacement)
      return count > 0 ? snap.pointee.image_placements![0].image_generation : 0
    }
  }
}
