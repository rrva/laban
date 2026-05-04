import CoreGraphics
import Foundation
import QuartzCore

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
  /// to its layer (Metal).
  func render(_ commands: [FrameCommand])

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
