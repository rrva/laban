import CoreGraphics
import Foundation
import QuartzCore

/// What changed since the last frame, in surface (CG-points, y-up) coordinates.
///
/// `.full` forces a complete redraw — the safe default and the only behaviour
/// the software backend supports today. `.partial` lets the Metal backend
/// constrain its persistent target update to a set of dirty Y bands instead
/// of re-rasterizing every cell.
public enum RenderDamage: Equatable, Sendable {
  case full
  /// Each entry is `(y, height)` in CG-points, y measured up from the bottom
  /// of the surface. Empty list means "nothing changed" — the backend may
  /// skip the persistent-target update entirely and just re-present.
  case partial(yRanges: [DirtyYRange])
}

public struct DirtyYRange: Equatable, Sendable {
  public var y: CGFloat
  public var height: CGFloat
  public init(y: CGFloat, height: CGFloat) {
    self.y = y
    self.height = height
  }
}

/// Explicit gamma / color-space compositing model used by a renderer.
///
/// - `nativePlatformReference` — the platform's own text rasterizer
///   (CoreText/CoreGraphics on macOS). It is the result reference, not an
///   implementation choice.
/// - `linearLight` — compositing performed in linear light, typically by
///   linearizing sRGB inputs and writing to an sRGB-encoded surface so the
///   display sees correct gamma. Slug and vector use this path.
/// - `encodedSRGBCompatibility` — compositing performed directly in encoded
///   sRGB values without linearization. Used by the legacy Metal glyph paths
///   for compatibility with existing atlas and blend behavior.
public enum TextCompositeModel: String, Equatable, Sendable, Encodable {
  case nativePlatformReference
  case linearLight
  case encodedSRGBCompatibility
}

public struct RendererStatus: Equatable, Sendable, Encodable {
  public var configuredRenderer: String
  public var effectiveRenderer: String
  public var fallbackReason: String?
  public var rasterFallbackGlyphs: Int?
  public var vectorSubpixelLayout: String?
  public var textCompositeModel: TextCompositeModel?

  public init(
    configuredRenderer: String,
    effectiveRenderer: String,
    fallbackReason: String? = nil,
    rasterFallbackGlyphs: Int? = nil,
    vectorSubpixelLayout: String? = nil,
    textCompositeModel: TextCompositeModel? = nil
  ) {
    self.configuredRenderer = configuredRenderer
    self.effectiveRenderer = effectiveRenderer
    self.fallbackReason = fallbackReason
    self.rasterFallbackGlyphs = rasterFallbackGlyphs
    self.vectorSubpixelLayout = vectorSubpixelLayout
    self.textCompositeModel = textCompositeModel
  }
}

public struct RendererZoomDiagnostics: Equatable, Sendable {
  public var glyphFontSizes: [Double]
  public var rasterAtlasCellHeight: Double
  public var quadHeights: [Int]
  public var curveBufferBuildCount: Int?
  public var geometryBufferUploadCount: Int?

  public init(
    glyphFontSizes: [Double] = [],
    rasterAtlasCellHeight: Double = 0,
    quadHeights: [Int] = [],
    curveBufferBuildCount: Int? = nil,
    geometryBufferUploadCount: Int? = nil
  ) {
    self.glyphFontSizes = glyphFontSizes
    self.rasterAtlasCellHeight = rasterAtlasCellHeight
    self.quadHeights = quadHeights
    self.curveBufferBuildCount = curveBufferBuildCount
    self.geometryBufferUploadCount = geometryBufferUploadCount
  }
}

/// Optional capability for renderers that can scale the whole terminal surface
/// during a continuous zoom gesture without rebuilding font resources per
/// frame. The gesture scale is applied in the renderer's projection, not via a
/// layer transform, so every presented frame uses the same transform.
public protocol GestureZoomRenderable: AnyObject {
  var supportsFractionalLiveZoom: Bool { get }
  func setGestureZoom(_ factor: CGFloat, anchor: CGPoint)
  var zoomDiagnostics: RendererZoomDiagnostics { get }
}

extension GestureZoomRenderable {
  public var supportsFractionalLiveZoom: Bool { true }
}

/// Optional capability for GPU backends whose CAMetalLayer is presented by an
/// internal CAMetalDisplayLink. The host view drives this from the same
/// animate-or-park policy as its frame-production display link.
public protocol DisplayLinkPresentingRenderer: AnyObject {
  func setPresentLinkRunning(_ running: Bool)
  func presentDisplayLinkStats(reset: Bool) -> [String: Double]?
}

/// Common surface contract for swappable rendering backends.
///
/// Two backends ship today:
/// - `SoftwareBackend` wraps `SoftwareRenderer` + `BitmapSurface`. Used in
///   headless / fixture / capture-replay tests and as a fallback for the
///   AppKit shell. The host view installs no special layer and reads
///   `presentationImage` to blit each frame in `draw(_:)`.
/// - `MetalRenderer` self-presents into a `CAMetalLayer` it owns. The host
///   view installs `presentationLayer` and never paints in `draw(_:)`.
public protocol RendererBackend: AnyObject {
  /// Render one frame from the given command list. The backend either
  /// snapshots the result for later blit (software) or presents it directly
  /// to its layer (Metal). The `damage` hint lets backends with a persistent
  /// target avoid re-rasterizing clean rows; backends without one ignore it
  /// and always do a full redraw.
  @discardableResult
  func render(_ commands: [FrameCommand], damage: RenderDamage) -> Bool

  /// Render one frame with an optional terminal-cell payload. Backends that do
  /// not understand the payload ignore it and render the command stream.
  @discardableResult
  func render(
    _ commands: [FrameCommand],
    cellPayload: TerminalCellPayload?,
    damage: RenderDamage
  ) -> Bool

  @discardableResult
  func render(
    _ commands: [FrameCommand],
    cellPayload: TerminalCellPayload?,
    damage: RenderDamage,
    rendererFallbackReason: String?
  ) -> Bool

  /// Reallocate presentation resources for the requested device-pixel size.
  @discardableResult
  func resize(pixelWidth: Int, pixelHeight: Int, scale: CGFloat) -> Bool

  /// Surface metrics in device pixels and the backing scale factor.
  var surfaceWidth: Int { get }
  var surfaceHeight: Int { get }
  var surfaceScale: CGFloat { get }

  /// CAMetalLayer or other CALayer the host view should install on itself.
  /// Nil means the host renders via its default layer + the
  /// `presentationImage` path.
  var presentationLayer: CALayer? { get }

  /// Most recent rendered frame as a CGImage. Used by the host view's
  /// `draw(_:)` path on backends that don't self-present. Nil for self-
  /// presenting backends (Metal).
  var presentationImage: CGImage? { get }

  /// PNG bytes of the most recent rendered frame for screenshots / capture.
  var pngData: Data? { get }

  /// Called after a backend has completed a frame. GPU backends fire this from
  /// their command-buffer completion path; CPU/readback backends fire it after
  /// their synchronous render.
  var onFrameCompleted: (() -> Void)? { get set }

  /// When true, `render` blocks until the committed frame has fully completed
  /// before returning, instead of presenting asynchronously. Off for normal
  /// display-link frames. The live resize / font-size apply path turns it on
  /// for one frame so a self-presenting GPU backend never presents a frame that
  /// mixes old and new atlas state (e.g. glyphs at two sizes during a continuous
  /// pinch-zoom). Backends that render synchronously (software) ignore it via
  /// the default no-op below.
  var waitForFrameCompletion: Bool { get set }

  var rendererStatus: RendererStatus { get }
}

extension RendererBackend {
  public var rendererStatus: RendererStatus {
    RendererStatus(configuredRenderer: "software", effectiveRenderer: "software")
  }

  /// Default for backends that render synchronously (software): nothing is ever
  /// in flight, so the flag is a no-op. GPU backends store a real flag.
  public var waitForFrameCompletion: Bool {
    get { false }
    set {}
  }

  @discardableResult
  public func render(
    _ commands: [FrameCommand],
    cellPayload: TerminalCellPayload?,
    damage: RenderDamage
  ) -> Bool {
    render(
      commands,
      cellPayload: cellPayload,
      damage: damage,
      rendererFallbackReason: nil)
  }

  @discardableResult
  public func render(
    _ commands: [FrameCommand],
    cellPayload: TerminalCellPayload?,
    damage: RenderDamage,
    rendererFallbackReason: String?
  ) -> Bool {
    render(commands, damage: damage)
  }

  /// Convenience for callers that have no damage info — equivalent to a full
  /// redraw.
  @discardableResult
  public func render(_ commands: [FrameCommand]) -> Bool {
    render(commands, cellPayload: nil, damage: .full, rendererFallbackReason: nil)
  }
}
