import Foundation
import LabanTerminalCore
import XCTest

@testable import LabanCore

/// The host PNG decoder the terminal core calls for Kitty `f=100`
/// transmissions (moved out of the C core to keep ImageIO behind the
/// boundary).
final class KittyPNGDecoderTests: XCTestCase {
  /// 1x1 PNG, red at 50% alpha.
  private let redHalfAlphaPNGBase64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DQAAAEgQGALFXOsAAAAABJRU5ErkJggg=="
  /// 1x1 GIF. ImageIO would decode it; the Kitty PNG path must not.
  private let gifBase64 = "R0lGODlhAQABAIAAAP///wAAACH5BAEAAAAALAAAAAABAAEAAAICRAEAOw=="

  override func setUp() {
    super.setUp()
    KittyPNGDecoder.install()
    laban_set_kitty_graphics_enabled(true)
  }

  override func tearDown() {
    laban_set_kitty_graphics_enabled(false)
    super.tearDown()
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

  func testNonPNGBytesSentAsPNGAreRejected() throws {
    let session = try makeSession()
    defer { laban_session_destroy(session) }
    write(session, "\u{1b}_Gi=9,a=T,f=100,q=2;\(gifBase64)\u{1b}\\")
    XCTAssertEqual(try snapshotPlacements(session).count, 0, "a GIF must not decode as PNG")
  }

  private func makeSession() throws -> OpaquePointer {
    var config = LabanLaunchConfig()
    config.fixture_mode = 1
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    size.cell_width = 10
    size.cell_height = 20
    var session: OpaquePointer?
    XCTAssertEqual(laban_session_create(&config, size, &session), 0)
    let created = try XCTUnwrap(session)
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

  private func snapshotPlacements(_ session: OpaquePointer) throws -> [LabanImagePlacement] {
    var snap: UnsafeMutablePointer<LabanSnapshot>?
    XCTAssertEqual(laban_session_snapshot(session, &snap), 0)
    let s = try XCTUnwrap(snap)
    defer { laban_snapshot_destroy(s) }
    guard let placements = s.pointee.image_placements else { return [] }
    return Array(UnsafeBufferPointer(start: placements, count: s.pointee.image_placement_count))
  }
}
