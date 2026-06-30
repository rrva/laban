import CoreGraphics
import Foundation
import Metal
import XCTest

@testable import LabanRenderer

/// The user's report: after a continuous zoom settles, SOME glyphs (often the
/// bold / styled runs) render at the wrong size — "like an async bake races
/// another async bake." This pins the discriminator: in a correct settled frame
/// every glyph resolves to a font at exactly the current terminal size. The
/// renderer records the distinct font point sizes it drew last frame
/// (`lastFrameGlyphFontSizes`); a stray size is the bug caught red-handed.
final class VectorZoomGlyphSizeConsistencyTests: XCTestCase {
  private func makeRenderer(pt: CGFloat) throws -> VectorGlyphRenderer {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let atlas = FontAtlas(pointSize: pt, fontName: nil)
    return try XCTUnwrap(
      VectorGlyphRenderer(
        fontAtlas: atlas, sidebarFontAtlas: atlas, pixelWidth: 1200, pixelHeight: 700, scale: 2))
  }

  /// A full screen of mixed regular + BOLD text (the styled path the screenshot
  /// implicated), so any size leak in the bold variant surfaces.
  private func mixedStyleCommands() -> [FrameCommand] {
    let cellH: CGFloat = 19
    var cmds: [FrameCommand] = [
      .rect(CGRect(x: 0, y: 0, width: 1200, height: 700), color: 0x10_10_10_FF, source: .terminal)
    ]
    let words = ["transition", "Goal", "continuous", "Just", "Laban", "recap", "config", "sweep"]
    for row in 0..<30 {
      let bold: TextAttributes = (row % 2 == 0) ? [.bold] : []
      cmds.append(
        .glyphRun(
          origin: CGPoint(x: 8, y: CGFloat(row) * cellH + 4),
          text: words[row % words.count] + " 0123456789 /usr/bin/login -flp",
          foreground: 0xEE_EE_EE_FF,
          background: 0x10_10_10_FF,
          attributes: bold,
          source: .terminal))
    }
    return cmds
  }

  /// Reproduce the scenario: render at a size, then reconfigure to a NEW size
  /// (the zoom commit) and render — repeatedly, including zoom-OUT (more glyphs
  /// revealed). After each commit's settle frames, exactly one terminal size may
  /// appear among drawn glyphs.
  func testGlyphSizesStaySingleAcrossZoomCommits() throws {
    let renderer = try makeRenderer(pt: 14)
    // Warm the start size.
    _ = renderer.render(mixedStyleCommands(), damage: .full)

    // A sequence of commits: up big, then OUT small (the user's race trigger),
    // then a fractional mid-size.
    let targets: [CGFloat] = [28, 35, 9, 11, 22.4, 17.3]
    for target in targets {
      let atlas = FontAtlas(pointSize: target, fontName: nil)
      renderer.reconfigureFonts(fontAtlas: atlas, sidebarFontAtlas: atlas)
      // Render frames until one is NOT dropped (the drawable scheduler may
      // no-op a busy frame, leaving `lastFrameGlyphFontSizes` from a prior size);
      // we want the size set from a frame that actually drew this size.
      var drew = false
      for _ in 0..<40 where !drew {
        drew = renderer.render(mixedStyleCommands(), damage: .full)
      }
      XCTAssertTrue(drew, "renderer never produced a non-dropped frame at \(target)pt")

      let sizes = renderer.lastFrameGlyphFontSizes
      XCTAssertEqual(
        sizes.count, 1,
        "settled frame at \(target)pt drew glyphs at multiple font sizes \(sizes) "
          + "— the per-glyph size mix")
      if let only = sizes.first {
        XCTAssertEqual(
          only, Double(target), accuracy: 1e-6,
          "drawn glyph size \(only) != committed terminal size \(target)")
      }
    }
  }
}
