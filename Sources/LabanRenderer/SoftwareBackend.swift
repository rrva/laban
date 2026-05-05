import CoreGraphics
import Foundation
import QuartzCore

/// Adapter that pairs a `BitmapSurface` with a `SoftwareRenderer` and
/// presents the contract `RendererBackend` callers depend on. Resize is a
/// fresh allocation since `SoftwareRenderer` is wired to one surface.
public final class SoftwareBackend: RendererBackend {

  public private(set) var surface: BitmapSurface
  public private(set) var renderer: SoftwareRenderer
  public let fontAtlas: FontAtlas
  public let sidebarFontAtlas: FontAtlas
  private var lastImage: CGImage?

  public init(
    fontAtlas: FontAtlas,
    sidebarFontAtlas: FontAtlas? = nil,
    pixelWidth: Int = 1, pixelHeight: Int = 1, scale: CGFloat = 1
  ) {
    self.fontAtlas = fontAtlas
    self.sidebarFontAtlas = sidebarFontAtlas ?? fontAtlas
    let s = BitmapSurface(width: max(1, pixelWidth), height: max(1, pixelHeight), scale: scale)
    self.surface = s
    self.renderer = SoftwareRenderer(
      surface: s, fontAtlas: fontAtlas, sidebarFontAtlas: self.sidebarFontAtlas)
  }

  /// Reallocate the surface if the requested dimensions or scale differ.
  /// Returns true when a new surface was created.
  @discardableResult
  public func resize(pixelWidth: Int, pixelHeight: Int, scale: CGFloat) -> Bool {
    let pw = max(1, pixelWidth)
    let ph = max(1, pixelHeight)
    guard pw != surface.width || ph != surface.height || scale != surface.scale else {
      return false
    }
    surface = BitmapSurface(width: pw, height: ph, scale: scale)
    renderer = SoftwareRenderer(
      surface: surface, fontAtlas: fontAtlas, sidebarFontAtlas: sidebarFontAtlas)
    lastImage = nil
    return true
  }

  public func render(_ commands: [FrameCommand], damage: RenderDamage) {
    // Software backend has no persistent target; damage is ignored.
    renderer.render(commands)
    lastImage = surface.cgImage
  }

  public var surfaceWidth: Int { surface.width }
  public var surfaceHeight: Int { surface.height }
  public var surfaceScale: CGFloat { surface.scale }

  public var presentationLayer: CALayer? { nil }
  public var presentationImage: CGImage? { lastImage }
  public var pngData: Data? { surface.pngData }
}
