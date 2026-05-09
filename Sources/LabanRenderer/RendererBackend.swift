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
}

extension RendererBackend {
  /// Convenience for callers that have no damage info — equivalent to a full
  /// redraw.
  @discardableResult
  public func render(_ commands: [FrameCommand]) -> Bool {
    render(commands, damage: .full)
  }
}
