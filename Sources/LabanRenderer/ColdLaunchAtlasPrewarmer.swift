import CoreGraphics
import Foundation
import Metal

/// Prewarms a single-size `MetalGlyphAtlas` pair (terminal + sidebar) for the
/// printable-ASCII range on a dedicated background queue, so a cold launch into
/// `.vectorGlyph`/`.slugGlyph` can show a fast temporary backend immediately
/// and adopt this already-warm atlas when it swaps to the real backend, instead
/// of rasterizing every first-frame glyph synchronously on the main thread.
///
/// Distinct from `GlyphAtlasLadder`'s queue: this is a one-shot launch-time
/// prewarm and must never block behind (or block) the ladder's own zoom-related
/// background work. It mirrors `GlyphAtlasLadder.makePrewarmedAtlas(fontAtlas:)`'s
/// proven-safe pattern (CoreText rasterization plus `MTLTexture.replace` uploads
/// off the main thread while no renderer references the atlas) but builds a
/// single size, not a whole zoom ladder.
public enum ColdLaunchAtlasPrewarmer {
  private static let queue = DispatchQueue(
    label: "laban.cold-launch-atlas-prewarm", qos: .userInitiated)

  /// Build and prewarm a terminal + sidebar glyph atlas for `fontAtlas`'s cell
  /// geometry on a background queue, then call `completion` on that same
  /// background queue with the results. Either or both may be `nil` if Metal
  /// allocation failed, in which case the caller simply proceeds without a
  /// prebuilt atlas and the real renderer builds a fresh (cold) one as today.
  /// The caller is responsible for hopping to the main thread before touching
  /// AppKit state. Safe to call before the renderer that will adopt these
  /// atlases exists: it only needs the `MTLDevice`.
  public static func prewarm(
    device: MTLDevice,
    fontAtlas: FontAtlas,
    sidebarFontAtlas: FontAtlas,
    scale: CGFloat,
    completion:
      @escaping (_ terminalAtlas: MetalGlyphAtlas?, _ sidebarAtlas: MetalGlyphAtlas?) -> Void
  ) {
    queue.async {
      let terminal = makePrewarmedAtlas(
        device: device, fontAtlas: fontAtlas, scale: scale)
      let sidebar: MetalGlyphAtlas?
      if sidebarFontAtlas === fontAtlas {
        sidebar = terminal
      } else {
        sidebar = makePrewarmedAtlas(
          device: device, fontAtlas: sidebarFontAtlas, scale: scale)
      }
      completion(terminal, sidebar)
    }
  }

  /// Synchronous variant of `prewarm` for tests/debug: builds and prewarms on
  /// the calling thread and returns the atlases directly (no background queue,
  /// no completion hop). Used by `TerminalBitmapView`'s
  /// `debugPerformColdLaunchSwapSynchronously` to drive the cold-launch swap
  /// deterministically in headless tests.
  public static func prewarmSync(
    device: MTLDevice,
    fontAtlas: FontAtlas,
    sidebarFontAtlas: FontAtlas,
    scale: CGFloat
  ) -> (terminal: MetalGlyphAtlas?, sidebar: MetalGlyphAtlas?) {
    let terminal = makePrewarmedAtlas(
      device: device, fontAtlas: fontAtlas, scale: scale)
    let sidebar: MetalGlyphAtlas?
    if sidebarFontAtlas === fontAtlas {
      sidebar = terminal
    } else {
      sidebar = makePrewarmedAtlas(
        device: device, fontAtlas: sidebarFontAtlas, scale: scale)
    }
    return (terminal, sidebar)
  }

  private static func makePrewarmedAtlas(
    device: MTLDevice,
    fontAtlas: FontAtlas,
    scale: CGFloat
  ) -> MetalGlyphAtlas? {
    let cellSize = fontAtlas.cellSize
    guard
      let atlas = MetalGlyphAtlas(
        device: device,
        cellWidth: cellSize.width,
        cellHeight: cellSize.height,
        descent: fontAtlas.descent,
        scale: scale)
    else { return nil }
    atlas.prewarmASCII(fontAtlas: fontAtlas)
    return atlas
  }
}
