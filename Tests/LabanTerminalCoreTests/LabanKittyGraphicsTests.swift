import LabanTerminalCore
import XCTest

/// Kitty graphics in the terminal core (execplans/active/kitty-graphics-rendering.md,
/// Milestone 1): enablement gate, PNG decoding, visible placements in the
/// snapshot, pixel copies, and damage when images change.
final class LabanKittyGraphicsTests: XCTestCase {
  /// 2x2 RGB image: red, green / blue, white.
  private let checkerBase64 = "/wAAAP8AAAD/////"
  /// 1x1 PNG, red at 50% alpha.
  private let redHalfAlphaPNGBase64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DQAAAEgQGALFXOsAAAAABJRU5ErkJggg=="

  override func setUp() {
    super.setUp()
    laban_set_kitty_graphics_enabled(true)
  }

  override func tearDown() {
    laban_set_kitty_graphics_enabled(false)
    super.tearDown()
  }

  func testTransmitAndDisplayYieldsOneVisiblePlacement() throws {
    let session = try makeSession()
    defer { laban_session_destroy(session) }

    write(session, "\u{1b}_Gi=7,a=T,f=24,s=2,v=2,c=8,r=4,q=2;\(checkerBase64)\u{1b}\\")

    let placements = try snapshotPlacements(session)
    XCTAssertEqual(placements.count, 1)
    let p = try XCTUnwrap(placements.first)
    XCTAssertEqual(p.image_id, 7)
    XCTAssertEqual(p.layer, Int32(LABAN_IMAGE_LAYER_ABOVE_TEXT))
    XCTAssertEqual(p.viewport_col, 0)
    XCTAssertEqual(p.viewport_row, 0)
    XCTAssertEqual(p.grid_cols, 8)
    XCTAssertEqual(p.grid_rows, 4)
    // 8x4 cells of 10x20 px.
    XCTAssertEqual(p.pixel_width, 80)
    XCTAssertEqual(p.pixel_height, 80)
    XCTAssertEqual([p.source_x, p.source_y, p.source_width, p.source_height], [0, 0, 2, 2])
    XCTAssertNotEqual(p.image_generation, 0)
  }

  func testImageCopyReturnsStraightRGBA() throws {
    let session = try makeSession()
    defer { laban_session_destroy(session) }

    write(session, "\u{1b}_Gi=7,a=T,f=24,s=2,v=2,q=2;\(checkerBase64)\u{1b}\\")
    let p = try XCTUnwrap(try snapshotPlacements(session).first)

    var image = LabanKittyImage()
    XCTAssertEqual(laban_session_kitty_image_copy(session, 7, p.image_generation, &image), 0)
    defer { laban_kitty_image_free(&image) }
    XCTAssertEqual(image.width, 2)
    XCTAssertEqual(image.height, 2)
    let bytes = Array(UnsafeBufferPointer(start: image.rgba, count: 16))
    XCTAssertEqual(
      bytes,
      [0xFF, 0, 0, 0xFF, 0, 0xFF, 0, 0xFF, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])

    var stale = LabanKittyImage()
    XCTAssertEqual(
      laban_session_kitty_image_copy(session, 7, p.image_generation &+ 1, &stale), -1,
      "a copy for a stale generation must fail so the caller refetches placements")
    XCTAssertEqual(laban_session_kitty_image_copy(session, 99, p.image_generation, &stale), -1)
  }

  func testPNGDecodesToStraightAlpha() throws {
    let session = try makeSession()
    defer { laban_session_destroy(session) }

    write(session, "\u{1b}_Gi=9,a=T,f=100,q=2;\(redHalfAlphaPNGBase64)\u{1b}\\")
    let p = try XCTUnwrap(try snapshotPlacements(session).first, "the PNG must decode and place")

    var image = LabanKittyImage()
    XCTAssertEqual(laban_session_kitty_image_copy(session, 9, p.image_generation, &image), 0)
    defer { laban_kitty_image_free(&image) }
    XCTAssertEqual([image.width, image.height], [1, 1])
    let px = Array(UnsafeBufferPointer(start: image.rgba, count: 4))
    XCTAssertEqual(px[0], 0xFF, accuracy: 2, "red must not be premultiplied by alpha")
    XCTAssertEqual(px[1], 0)
    XCTAssertEqual(px[2], 0)
    XCTAssertEqual(px[3], 128, accuracy: 1)
  }

  func testQueryIsAcknowledgedWhenEnabled() throws {
    let session = try makeSession()
    defer { laban_session_destroy(session) }

    write(session, "\u{1b}_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\u{1b}\\")
    XCTAssertEqual(String(bytes: drainResponse(session), encoding: .utf8), "\u{1b}_Gi=31;OK\u{1b}\\")
  }

  func testDisabledGateStoresNothingAndAnswersNothing() throws {
    laban_set_kitty_graphics_enabled(false)
    let session = try makeSession()
    defer { laban_session_destroy(session) }

    write(session, "\u{1b}_Gi=7,a=T,f=24,s=2,v=2;\(checkerBase64)\u{1b}\\")
    XCTAssertEqual(drainResponse(session), [])
    XCTAssertEqual(try snapshotPlacements(session).count, 0)
  }

  func testDeleteRemovesPlacement() throws {
    let session = try makeSession()
    defer { laban_session_destroy(session) }

    write(session, "\u{1b}_Gi=7,a=T,f=24,s=2,v=2,q=2;\(checkerBase64)\u{1b}\\")
    XCTAssertEqual(try snapshotPlacements(session).count, 1)
    write(session, "\u{1b}_Ga=d,d=A,q=2\u{1b}\\")
    XCTAssertEqual(try snapshotPlacements(session).count, 0)
  }

  func testZIndexSelectsLayer() throws {
    let session = try makeSession()
    defer { laban_session_destroy(session) }

    write(session, "\u{1b}_Gi=1,a=T,f=24,s=2,v=2,z=-1,q=2;\(checkerBase64)\u{1b}\\")
    write(session, "\u{1b}_Gi=2,a=T,f=24,s=2,v=2,z=-1073741825,q=2;\(checkerBase64)\u{1b}\\")
    write(session, "\u{1b}_Gi=3,a=T,f=24,s=2,v=2,z=5,q=2;\(checkerBase64)\u{1b}\\")

    let layers = try snapshotPlacements(session).map { ($0.image_id, $0.layer) }
    // Sorted by layer: below background, below text, above text.
    XCTAssertEqual(layers.map { $0.0 }, [2, 1, 3])
    XCTAssertEqual(
      layers.map { $0.1 },
      [
        Int32(LABAN_IMAGE_LAYER_BELOW_BACKGROUND), Int32(LABAN_IMAGE_LAYER_BELOW_TEXT),
        Int32(LABAN_IMAGE_LAYER_ABOVE_TEXT),
      ])
  }

  func testScrollingMovesPlacementUpAndThenOutOfView() throws {
    let session = try makeSession(rows: 10)
    defer { laban_session_destroy(session) }

    // C=1 keeps the cursor still, so the image stays anchored at row 0.
    write(session, "\u{1b}_Gi=7,a=T,f=24,s=2,v=2,c=8,r=4,C=1,q=2;\(checkerBase64)\u{1b}\\")
    // Cursor to the last row, then two newlines scroll the screen by two.
    write(session, "\u{1b}[10;1H\n\n")
    let moved = try XCTUnwrap(try snapshotPlacements(session).first)
    XCTAssertEqual(moved.viewport_row, -2, "partly scrolled placements keep a negative row")

    write(session, String(repeating: "\n", count: 20))
    XCTAssertEqual(try snapshotPlacements(session).count, 0, "scrolled out of view")
  }

  func testImageChangeForcesFullDamageUntilRendered() throws {
    let session = try makeSession(rows: 10)
    defer { laban_session_destroy(session) }

    _ = try dirtyRows(session)
    XCTAssertEqual(laban_session_mark_rendered(session), 0)
    XCTAssertFalse(try dirtyRows(session).allSatisfy { $0 != 0 }, "idle screen is not fully dirty")

    write(session, "\u{1b}_Gi=7,a=T,f=24,s=2,v=2,c=2,r=1,C=1,q=2;\(checkerBase64)\u{1b}\\")
    XCTAssertTrue(try dirtyRows(session).allSatisfy { $0 != 0 }, "a new image forces full damage")
    XCTAssertEqual(laban_session_mark_rendered(session), 0)
    XCTAssertFalse(try dirtyRows(session).allSatisfy { $0 != 0 }, "rendered image is not re-damaged")

    write(session, "\u{1b}_Ga=d,d=A,q=2\u{1b}\\")
    XCTAssertTrue(try dirtyRows(session).allSatisfy { $0 != 0 }, "deleting an image forces full damage")
  }

  /// The app renders a session only when `laban_session_render_dirty` says
  /// so. Image changes without accompanying text (a placement with C=1, a
  /// delete) must still report dirty, or they only appear on the next
  /// unrelated repaint.
  func testImageOnlyChangesReportRenderDirty() throws {
    let session = try makeSession()
    defer { laban_session_destroy(session) }
    // Transmit without displaying, then settle to a rendered, idle state.
    write(session, "\u{1b}_Gi=7,a=t,f=24,s=2,v=2,q=2;\(checkerBase64)\u{1b}\\")
    renderAndMark(session)
    XCTAssertFalse(renderDirty(session), "idle after rendering")

    write(session, "\u{1b}_Ga=p,i=7,C=1,q=2\u{1b}\\")
    XCTAssertTrue(renderDirty(session), "placing an image (cursor unmoved) needs a frame")
    renderAndMark(session)
    XCTAssertFalse(renderDirty(session), "the rendered placement is not re-dirtied")

    write(session, "\u{1b}_Ga=d,d=A,q=2\u{1b}\\")
    XCTAssertTrue(renderDirty(session), "deleting an image needs a frame")
    renderAndMark(session)
    XCTAssertFalse(renderDirty(session))
  }

  private func renderDirty(_ session: OpaquePointer) -> Bool {
    var dirty: Int32 = 0
    XCTAssertEqual(laban_session_render_dirty(session, &dirty), 0)
    return dirty != 0
  }

  private func renderAndMark(_ session: OpaquePointer) {
    _ = try? snapshotPlacements(session)
    XCTAssertEqual(laban_session_mark_rendered(session), 0)
  }

  /// 1x1 GIF. ImageIO would decode it; the Kitty PNG path must not.
  private let gifBase64 = "R0lGODlhAQABAIAAAP///wAAACH5BAEAAAAALAAAAAABAAEAAAICRAEAOw=="

  func testNonPNGBytesSentAsPNGAreRejected() throws {
    let session = try makeSession()
    defer { laban_session_destroy(session) }
    write(session, "\u{1b}_Gi=9,a=T,f=100,q=2;\(gifBase64)\u{1b}\\")
    XCTAssertEqual(try snapshotPlacements(session).count, 0, "a GIF must not decode as PNG")
  }

  func testPNGAcceptanceChecksSignatureAndDecodedSize() throws {
    func acceptable(_ bytes: [UInt8]) -> Bool {
      bytes.withUnsafeBufferPointer { laban_kitty_png_acceptable($0.baseAddress, $0.count) }
    }
    func header(width: UInt32, height: UInt32) -> [UInt8] {
      let be = { (v: UInt32) in [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xFF) } }
      return [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + be(13) + Array("IHDR".utf8)
        + be(width) + be(height) + [8, 6, 0, 0, 0]
    }
    let png = try XCTUnwrap(Data(base64Encoded: redHalfAlphaPNGBase64))
    XCTAssertTrue(acceptable(Array(png)))
    XCTAssertFalse(acceptable(Array(try XCTUnwrap(Data(base64Encoded: gifBase64)))), "GIF")
    XCTAssertFalse(acceptable(Array(png.prefix(20))), "truncated before the dimensions")
    XCTAssertTrue(acceptable(header(width: 4000, height: 4000)), "64 MB budget: 4000x4000 fits")
    XCTAssertFalse(
      acceptable(header(width: 5000, height: 5000)),
      "100 MB decoded exceeds the 64 MB budget before any allocation")
    XCTAssertFalse(acceptable(header(width: 20000, height: 1)), "over the dimension cap")
    XCTAssertFalse(acceptable(header(width: 0, height: 16)), "zero width")
  }

  // MARK: - Helpers

  private func makeSession(rows: Int32 = 24, cols: Int32 = 80) throws -> OpaquePointer {
    var config = LabanLaunchConfig()
    config.fixture_mode = 1
    var size = LabanTerminalSize()
    size.rows = rows
    size.cols = cols
    size.cell_width = 10
    size.cell_height = 20
    var session: OpaquePointer?
    XCTAssertEqual(laban_session_create(&config, size, &session), 0)
    let created = try XCTUnwrap(session)
    // Cell pixel geometry reaches libghostty through resize; placements need
    // it to compute pixel sizes.
    XCTAssertEqual(laban_session_resize(created, size), 0)
    return created
  }

  private func write(_ session: OpaquePointer, _ text: String) {
    let bytes = Array(text.utf8)
    bytes.withUnsafeBytes { buf in
      _ = laban_session_write(
        session, buf.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count)
    }
  }

  private func drainResponse(_ session: OpaquePointer) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: 256)
    var len: size_t = 0
    XCTAssertEqual(laban_session_drain_response(session, &buf, buf.count, &len), 0)
    return Array(buf.prefix(Int(len)))
  }

  private func snapshotPlacements(_ session: OpaquePointer) throws -> [LabanImagePlacement] {
    var snap: UnsafeMutablePointer<LabanSnapshot>?
    XCTAssertEqual(laban_session_snapshot(session, &snap), 0)
    let s = try XCTUnwrap(snap)
    defer { laban_snapshot_destroy(s) }
    guard let placements = s.pointee.image_placements else { return [] }
    return Array(UnsafeBufferPointer(start: placements, count: s.pointee.image_placement_count))
  }

  private func dirtyRows(_ session: OpaquePointer) throws -> [UInt8] {
    var snap: UnsafeMutablePointer<LabanSnapshot>?
    XCTAssertEqual(laban_session_snapshot(session, &snap), 0)
    let s = try XCTUnwrap(snap)
    defer { laban_snapshot_destroy(s) }
    guard let rows = s.pointee.dirty_rows else { return [] }
    return Array(UnsafeBufferPointer(start: rows, count: s.pointee.dirty_row_count))
  }
}
