import CoreGraphics
import Foundation
import Metal
import os

/// Prebuilt per-size atlas collection backing live font-size zoom.
///
/// A "ladder entry" is a ready-to-swap bundle for one integer point size in
/// the zoom range (`FontAtlas.zoomMinimumPointSize`…`zoomMaximumPointSize`):
/// terminal + sidebar `FontAtlas` metrics and terminal + sidebar
/// `MetalGlyphAtlas` GPU textures with printable ASCII already rasterized.
/// Entries are built entirely off the main thread on a utility queue and
/// published immutable; the renderer adopts them on the main thread between
/// frames (`MetalRenderer.reconfigureFonts`), so a zoom step never rasterizes
/// glyphs on the hot path. The ladder is purely an accelerator — a miss falls
/// back to a synchronous build in the caller.
public final class GlyphAtlasLadder {
  public struct Entry {
    /// Terminal font metrics at this point size.
    public let fontAtlas: FontAtlas
    /// Sidebar metrics at terminal × 11/14 (the restart path's derivation).
    public let sidebarFontAtlas: FontAtlas
    public let terminalAtlas: MetalGlyphAtlas
    public let sidebarAtlas: MetalGlyphAtlas

    public init(
      fontAtlas: FontAtlas,
      sidebarFontAtlas: FontAtlas,
      terminalAtlas: MetalGlyphAtlas,
      sidebarAtlas: MetalGlyphAtlas
    ) {
      self.fontAtlas = fontAtlas
      self.sidebarFontAtlas = sidebarFontAtlas
      self.terminalAtlas = terminalAtlas
      self.sidebarAtlas = sidebarAtlas
    }
  }

  private static let log = Logger(subsystem: "com.rrva.laban", category: "atlas-ladder")

  /// Backing scale the textures were rasterized for. A backing-scale change
  /// invalidates the whole ladder; the owner discards and rebuilds.
  public let scale: CGFloat
  /// Persisted font name the ladder was built for (nil = bundled default).
  /// A font-family change invalidates the ladder; the owner skips it until
  /// the restart that family changes require.
  public let fontName: String?
  public let sidebarFontName: String

  private let device: MTLDevice
  private let templateFontAtlas: FontAtlas
  private let templateSidebarFontAtlas: FontAtlas
  private let lock = NSLock()
  private var entriesBySize: [Int: Entry] = [:]
  private let buildQueue = DispatchQueue(label: "laban.atlas-ladder", qos: .utility)

  public init(device: MTLDevice, scale: CGFloat, fontName: String?) {
    let fontAtlas = FontAtlas(pointSize: FontAtlas.defaultTerminalPointSize, fontName: fontName)
    self.device = device
    self.scale = max(scale, 1)
    self.templateFontAtlas = fontAtlas
    self.templateSidebarFontAtlas = FontAtlas(
      pointSize: FontAtlas.sidebarPointSize(
        forTerminalPointSize: FontAtlas.defaultTerminalPointSize),
      fontName: fontName)
    self.fontName = fontAtlas.fontPostScriptName
    self.sidebarFontName = templateSidebarFontAtlas.fontPostScriptName
  }

  public init(
    device: MTLDevice,
    scale: CGFloat,
    fontAtlas: FontAtlas,
    sidebarFontAtlas: FontAtlas
  ) {
    self.device = device
    self.scale = max(scale, 1)
    self.templateFontAtlas = fontAtlas
    self.templateSidebarFontAtlas = sidebarFontAtlas
    self.fontName = fontAtlas.fontPostScriptName
    self.sidebarFontName = sidebarFontAtlas.fontPostScriptName
  }

  /// Build every reachable zoom size on the background queue. CPU-side
  /// CoreText drawing and `MTLTexture.replaceRegion` uploads are safe off-main
  /// for textures no renderer references yet; entries become visible only once
  /// fully built. The `activeSize` argument is kept at the call site to make the
  /// caller's current-size intent explicit, but the ladder now also builds it
  /// so returning to the default/launch size is still a prebuilt swap.
  public func beginPrebuild(excluding activeSize: Int) {
    buildQueue.async { [self] in
      prebuild(excluding: activeSize)
    }
  }

  /// Synchronous body of `beginPrebuild`; the test seam for exercising the
  /// full ladder build without queue timing.
  func prebuild(excluding _: Int) {
    let start = ContinuousClock.now
    var built = 0
    let lo = Int(FontAtlas.zoomMinimumPointSize)
    let hi = Int(FontAtlas.zoomMaximumPointSize)
    for size in lo...hi {
      guard entry(forPointSize: size) == nil else { continue }
      guard let entry = makeEntry(forPointSize: size) else { continue }
      lock.lock()
      entriesBySize[size] = entry
      lock.unlock()
      built += 1
    }
    let elapsed = start.duration(to: .now)
    let elapsedMs =
      Double(elapsed.components.seconds) * 1000
      + Double(elapsed.components.attoseconds) / 1e15
    let megabytes = Double(totalTextureBytes) / (1024 * 1024)
    Self.log.info(
      "atlas-ladder: built \(built) sizes in \(String(format: "%.0f", elapsedMs)) ms, \(String(format: "%.1f", megabytes)) MB"
    )
  }

  /// The prebuilt entry for an integer point size, or nil while the prebuild
  /// has not reached it (or the size was excluded).
  public func entry(forPointSize size: Int) -> Entry? {
    lock.lock()
    defer { lock.unlock() }
    return entriesBySize[size]
  }

  /// Total R8 texture memory currently held by the ladder, in bytes.
  public var totalTextureBytes: Int {
    lock.lock()
    defer { lock.unlock() }
    return entriesBySize.values.reduce(0) { sum, entry in
      sum
        + entry.terminalAtlas.textureSize * entry.terminalAtlas.textureSize
        + entry.sidebarAtlas.textureSize * entry.sidebarAtlas.textureSize
    }
  }

  /// Build one entry synchronously: both `FontAtlas` metrics, both GPU
  /// atlases (texture sized to the prewarm estimate), printable ASCII
  /// prewarmed into the textures.
  func makeEntry(forPointSize size: Int) -> Entry? {
    let fontAtlas = templateFontAtlas.withPointSize(CGFloat(size))
    let sidebarFontAtlas = templateSidebarFontAtlas.withPointSize(
      FontAtlas.sidebarPointSize(forTerminalPointSize: CGFloat(size)))
    guard
      let terminalAtlas = makePrewarmedAtlas(fontAtlas: fontAtlas),
      let sidebarAtlas = makePrewarmedAtlas(fontAtlas: sidebarFontAtlas)
    else { return nil }
    return Entry(
      fontAtlas: fontAtlas,
      sidebarFontAtlas: sidebarFontAtlas,
      terminalAtlas: terminalAtlas,
      sidebarAtlas: sidebarAtlas)
  }

  private func makePrewarmedAtlas(fontAtlas: FontAtlas) -> MetalGlyphAtlas? {
    let cell = fontAtlas.cellSize
    let startSize = Self.textureSize(
      cellWidth: cell.width,
      cellHeight: cell.height,
      scale: scale)
    func build(textureSize: Int) -> MetalGlyphAtlas? {
      guard
        let atlas = MetalGlyphAtlas(
          device: device,
          cellWidth: cell.width,
          cellHeight: cell.height,
          descent: fontAtlas.descent,
          scale: scale,
          textureSize: textureSize)
      else { return nil }
      atlas.prewarmASCII(fontAtlas: fontAtlas)
      return atlas.didOverflow ? nil : atlas
    }

    let maxTextureSize = Self.maximumTextureSize
    guard var best = build(textureSize: maxTextureSize) else { return nil }
    var low = min(startSize, maxTextureSize)
    var high = maxTextureSize - 1
    while low <= high {
      let mid = low + (high - low) / 2
      if let atlas = build(textureSize: mid) {
        best = atlas
        high = mid - 1
      } else {
        low = mid + 1
      }
    }
    return best
  }

  private static let maximumTextureSize = 2048

  /// Lower-bound estimate at 2× the single-style printable ASCII footprint.
  /// Styled prewarm can need more room depending on real font variants and
  /// fallback slop, so `makePrewarmedAtlas` treats this as a starting point and
  /// binary-searches upward until prewarm completes without overflow.
  static func textureSize(cellWidth: CGFloat, cellHeight: CGFloat, scale: CGFloat) -> Int {
    let prewarmArea = 95.0 * Double(cellWidth * scale) * Double(cellHeight * scale)
    return min(
      maximumTextureSize,
      max(1, Int(ceil(sqrt(prewarmArea * 2)))))
  }
}
