import CoreGraphics
import XCTest

@testable import LabanRenderer

/// Regression for the software renderer's color pipeline.
///
/// Terminal/theme colors are sRGB values. Two things must hold:
/// 1. The produced `BitmapSurface.cgImage` is tagged sRGB so the window server
///    color-manages it to the display. A deviceRGB-tagged image is treated as
///    display-native and oversaturates on wide-gamut (P3) panels — the bug this
///    test guards. See `BitmapSurface` context creation and `cgColorFrom`.
/// 2. Pure primaries round-trip exactly through the bitmap. The previous
///    deviceRGB setup chose its color space to avoid an sRGB→deviceRGB
///    conversion that silently discarded pure-blue components on some
///    configurations; with the context and the colors both sRGB there is no
///    cross-space conversion, so this must still hold.
final class SoftwareRendererColorSpaceTests: XCTestCase {

  private func renderSolidRect(_ color: UInt32, width: Int = 16, height: Int = 16) -> BitmapSurface
  {
    let surface = BitmapSurface(width: width, height: height)
    let renderer = SoftwareRenderer(surface: surface, fontAtlas: FontAtlas())
    renderer.render([
      .rect(CGRect(x: 0, y: 0, width: width, height: height), color: color, source: .terminal)
    ])
    return surface
  }

  func testBitmapSurfaceImageIsTaggedSRGB() {
    let surface = renderSolidRect(0xF6EE_DBFF)
    guard let image = surface.cgImage else {
      XCTFail("BitmapSurface must produce a CGImage")
      return
    }
    // The image must be sRGB-tagged so AppKit color-manages it on wide-gamut
    // displays instead of treating the sRGB bytes as display-native.
    let name = image.colorSpace?.name as String?
    XCTAssertEqual(
      name, CGColorSpace.sRGB as String,
      "BitmapSurface.cgImage must be tagged sRGB, got \(name ?? "nil")")
  }

  func testCgColorFromIsSRGBTagged() {
    let color = cgColorFrom(0x0000_FFFF)
    let name = color.colorSpace?.name as String?
    XCTAssertEqual(
      name, CGColorSpace.sRGB as String,
      "cgColorFrom must produce an sRGB-tagged color, got \(name ?? "nil")")
  }

  /// Pure blue (and every primary) must survive a fill unchanged. This is the
  /// "pure blue components silently discarded" artifact the old deviceRGB
  /// comment was working around; sRGB-everywhere removes the conversion that
  /// caused it, so the round-trip must be exact.
  func testPurePrimariesRoundTripExactly() {
    let cases: [(name: String, rgba: UInt32, r: UInt32, g: UInt32, b: UInt32)] = [
      ("pureBlue", 0x0000_FFFF, 0, 0, 255),
      ("pureRed", 0xFF00_00FF, 255, 0, 0),
      ("pureGreen", 0x00FF_00FF, 0, 255, 0),
      ("pureCyan", 0x00FF_FFFF, 0, 255, 255),
      ("pureMagenta", 0xFF00_FFFF, 255, 0, 255),
      ("pureYellow", 0xFFFF_00FF, 255, 255, 0),
      ("white", 0xFFFF_FFFF, 255, 255, 255),
      ("black", 0x0000_00FF, 0, 0, 0),
      ("cream", 0xF6EE_DBFF, 0xF6, 0xEE, 0xDB),
      ("tealAccent", 0x30A7_BEFF, 0x30, 0xA7, 0xBE),
    ]
    for c in cases {
      let surface = renderSolidRect(c.rgba)
      guard let px = surface.pixel(x: 8, y: 8) else {
        XCTFail("\(c.name): no pixel at (8,8)")
        continue
      }
      let r = (px >> 24) & 0xFF
      let g = (px >> 16) & 0xFF
      let b = (px >> 8) & 0xFF
      let a = px & 0xFF
      XCTAssertEqual(r, c.r, "\(c.name): red channel changed (\(r) != \(c.r))")
      XCTAssertEqual(g, c.g, "\(c.name): green channel changed (\(g) != \(c.g))")
      XCTAssertEqual(b, c.b, "\(c.name): blue channel changed (\(b) != \(c.b))")
      XCTAssertEqual(a, 0xFF, "\(c.name): alpha must be opaque")
    }
  }
}
