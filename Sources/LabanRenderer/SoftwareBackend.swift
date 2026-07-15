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
  public private(set) var surfaceTransparency: RendererSurfaceTransparency
  private var lastImage: CGImage?
  public var onFrameCompleted: (() -> Void)?
  public var rendererStatus: RendererStatus

  public init(
    fontAtlas: FontAtlas,
    sidebarFontAtlas: FontAtlas? = nil,
    pixelWidth: Int = 1,
    pixelHeight: Int = 1,
    scale: CGFloat = 1,
    surfaceTransparency: RendererSurfaceTransparency = RendererSurfaceTransparency(
      isOpaque: true),
    rendererStatus: RendererStatus = RendererStatus(
      configuredRenderer: RendererSelection.software.rawValue,
      effectiveRenderer: RendererSelection.software.rawValue,
      textCompositeModel: .nativePlatformReference)
  ) {
    self.fontAtlas = fontAtlas
    self.sidebarFontAtlas = sidebarFontAtlas ?? fontAtlas
    self.surfaceTransparency = surfaceTransparency
    self.rendererStatus = rendererStatus
    let s = BitmapSurface(width: max(1, pixelWidth), height: max(1, pixelHeight), scale: scale)
    self.surface = s
    self.renderer = SoftwareRenderer(
      surface: s, fontAtlas: fontAtlas, sidebarFontAtlas: self.sidebarFontAtlas)
  }

  public func setSurfaceTransparency(_ transparency: RendererSurfaceTransparency) {
    guard transparency != surfaceTransparency else { return }
    surfaceTransparency = transparency
    // The software presentation image is backed by this reusable bitmap. A
    // surface-policy transition must not expose pixels rendered under the old
    // alpha contract, so replace the bitmap just as a resize does and withhold
    // presentation until the next complete synchronous render.
    surface = BitmapSurface(width: surface.width, height: surface.height, scale: surface.scale)
    renderer = SoftwareRenderer(
      surface: surface, fontAtlas: fontAtlas, sidebarFontAtlas: sidebarFontAtlas)
    lastImage = nil
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

  @discardableResult
  public func render(_ commands: [FrameCommand], damage: RenderDamage) -> Bool {
    // Software backend has no persistent target; damage is ignored.
    renderer.resetCanvas(to: Self.resolvedCanvasColor(commands))
    renderer.render(commands)
    lastImage = surface.cgImage
    onFrameCompleted?()
    return true
  }

  public var surfaceWidth: Int { surface.width }
  public var surfaceHeight: Int { surface.height }
  public var surfaceScale: CGFloat { surface.scale }

  public var presentationLayer: CALayer? { nil }
  public var presentationImage: CGImage? { lastImage }
  public var pngData: Data? { surface.pngData }

  /// FrameProducer emits the terminal canvas first. Without that semantic
  /// canvas, reset to transparent black; a sidebar or overlay is not a valid
  /// substitute for the terminal's zoom-margin color.
  private static func resolvedCanvasColor(_ commands: [FrameCommand]) -> UInt32 {
    for case .rect(_, let color, .terminal, .replace) in commands {
      return color
    }
    return 0x0000_0000
  }
}
