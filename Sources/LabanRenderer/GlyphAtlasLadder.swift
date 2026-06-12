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

  private let device: MTLDevice
  private let lock = NSLock()
  private var entriesBySize: [Int: Entry] = [:]
  private let buildQueue = DispatchQueue(label: "laban.atlas-ladder", qos: .utility)

  public init(device: MTLDevice, scale: CGFloat, fontName: String?) {
    self.device = device
    self.scale = max(scale, 1)
    self.fontName = fontName
  }

  /// Build every reachable zoom size on the background queue, skipping the
  /// active size (which already has a live atlas in the renderer). CPU-side
  /// CoreText drawing and `MTLTexture.replaceRegion` uploads are safe
  /// off-main for textures no renderer references yet; entries become
  /// visible only once fully built.
  public func beginPrebuild(excluding activeSize: Int) {
    buildQueue.async { [self] in
      prebuild(excluding: activeSize)
    }
  }

  /// Synchronous body of `beginPrebuild`; the test seam for exercising the
  /// full ladder build without queue timing.
  func prebuild(excluding activeSize: Int) {
    let start = ContinuousClock.now
    var built = 0
    let lo = Int(FontAtlas.zoomMinimumPointSize)
    let hi = Int(FontAtlas.zoomMaximumPointSize)
    for size in lo...hi where size != activeSize {
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
    let fontAtlas = FontAtlas(pointSize: CGFloat(size))
    let sidebarFontAtlas = FontAtlas(
      pointSize: FontAtlas.sidebarPointSize(forTerminalPointSize: CGFloat(size)))
    let cell = fontAtlas.cellSize
    let sidebarCell = sidebarFontAtlas.cellSize
    guard
      let terminalAtlas = MetalGlyphAtlas(
        device: device,
        cellWidth: cell.width,
        cellHeight: cell.height,
        descent: fontAtlas.descent,
        scale: scale,
        textureSize: Self.textureSize(
          cellWidth: cell.width, cellHeight: cell.height, scale: scale)),
      let sidebarAtlas = MetalGlyphAtlas(
        device: device,
        cellWidth: sidebarCell.width,
        cellHeight: sidebarCell.height,
        descent: sidebarFontAtlas.descent,
        scale: scale,
        textureSize: Self.textureSize(
          cellWidth: sidebarCell.width, cellHeight: sidebarCell.height, scale: scale))
    else { return nil }
    terminalAtlas.prewarmASCII(font: fontAtlas.font)
    sidebarAtlas.prewarmASCII(font: sidebarFontAtlas.font)
    return Entry(
      fontAtlas: fontAtlas,
      sidebarFontAtlas: sidebarFontAtlas,
      terminalAtlas: terminalAtlas,
      sidebarAtlas: sidebarAtlas)
  }

  /// Smallest of 512/768/1024/1536/2048 whose area is at least 2× the
  /// estimated prewarm footprint (95 printable ASCII glyphs at device-pixel
  /// cell size). The 2× headroom leaves room for the live alphabet beyond
  /// ASCII; the renderer's overflow-grow path covers underestimates. Measured
  /// at 2× scale the full 8…40 ladder is ~33 MB — coarser steps (512/1024/2048
  /// with 3× headroom) blew the 48 MB budget at 69 MB.
  static func textureSize(cellWidth: CGFloat, cellHeight: CGFloat, scale: CGFloat) -> Int {
    let prewarmArea = 95.0 * Double(cellWidth * scale) * Double(cellHeight * scale)
    for candidate in [512, 768, 1024, 1536, 2048]
    where Double(candidate * candidate) >= prewarmArea * 2 {
      return candidate
    }
    return 2048
  }
}
