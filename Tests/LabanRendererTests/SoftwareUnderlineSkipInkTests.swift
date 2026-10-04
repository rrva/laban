import CoreGraphics
import XCTest

@testable import LabanRenderer

/// The software renderer backs the headless debug runtime, so its underlines
/// must skip descender ink like the app's Slug renderer does.
final class SoftwareUnderlineSkipInkTests: XCTestCase {
  /// Red underline pixels within two pixels of green glyph ink.
  private func redTouchingInk(_ text: String, style: UnderlineStyle) -> Int {
    let atlas = FontAtlas(pointSize: 24, fontName: nil)
    let surface = BitmapSurface(width: 420, height: 96, scale: 2)
    let renderer = SoftwareRenderer(surface: surface, fontAtlas: atlas)
    renderer.render([
      .rect(CGRect(x: 0, y: 0, width: 210, height: 48), color: 0x10_10_10_FF, source: .terminal),
      .glyphRun(
        origin: CGPoint(x: 12, y: 10), text: text, foreground: 0x00_EE_00_FF,
        background: 0x10_10_10_FF, attributes: [.underline], source: .terminal,
        underlineStyle: style, underlineColor: 0xFF_00_00_FF),
    ])
    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int)? {
      guard x >= 0, y >= 0, x < surface.width, y < surface.height,
        let pixel = surface.pixel(x: x, y: y)
      else { return nil }
      return (Int((pixel >> 24) & 0xFF), Int((pixel >> 16) & 0xFF), Int((pixel >> 8) & 0xFF))
    }
    var count = 0
    for y in 0..<surface.height {
      for x in 0..<surface.width {
        guard let (r, g, b) = rgb(x, y), r > 200, g < 60, b < 60 else { continue }
        var nearInk = false
        for dy in -2...2 {
          for dx in -2...2 {
            if let (_, gg, _) = rgb(x + dx, y + dy), gg > 120 { nearInk = true }
          }
        }
        if nearInk { count += 1 }
      }
    }
    return count
  }

  private func redPixels(
    _ text: String, style: UnderlineStyle, pointSize: CGFloat = 24, scale: CGFloat = 2
  ) -> Int {
    let atlas = FontAtlas(pointSize: pointSize, fontName: nil)
    let surface = BitmapSurface(
      width: Int(210 * scale), height: Int(48 * scale), scale: scale)
    let renderer = SoftwareRenderer(surface: surface, fontAtlas: atlas)
    renderer.render([
      .rect(CGRect(x: 0, y: 0, width: 210, height: 48), color: 0x10_10_10_FF, source: .terminal),
      .glyphRun(
        origin: CGPoint(x: 12, y: 10), text: text, foreground: 0x00_EE_00_FF,
        background: 0x10_10_10_FF, attributes: [.underline], source: .terminal,
        underlineStyle: style, underlineColor: 0xFF_00_00_FF),
    ])
    var count = 0
    for y in 0..<surface.height {
      for x in 0..<surface.width {
        guard let p = surface.pixel(x: x, y: y) else { continue }
        if (p >> 24) & 0xFF > 200, (p >> 16) & 0xFF < 60, (p >> 8) & 0xFF < 60 { count += 1 }
      }
    }
    return count
  }

  func testUnderlinesStopShortOfDescenderInk() {
    for style in [UnderlineStyle.single, .double, .dotted, .dashed, .curly] {
      XCTAssertGreaterThan(redPixels("gjpqy", style: style), 0, "\(style) underline must draw")
      // Anti-aliased glyph edges leave a few pixels; an uncut underline
      // crossing five descenders leaves dozens.
      XCTAssertLessThanOrEqual(
        redTouchingInk("gjpqy", style: style), 12,
        "\(style) underline must stop short of descender ink")
    }
  }

  func testUnderlineWithoutDescendersIsUncut() {
    // Scale 1 is what the headless runtime renders at.
    for (size, scale) in [(CGFloat(12), CGFloat(1)), (13, 1), (24, 2)] {
      XCTAssertEqual(
        redPixels("aceos", style: .single, pointSize: size, scale: scale),
        redPixels("     ", style: .single, pointSize: size, scale: scale),
        "letters without descenders must not cut a \(size)pt underline at scale \(scale)")
    }
  }
}
