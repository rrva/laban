import Foundation

/// Why a GPU renderer returned `false` from `render(...)`. Shared across
/// `MetalRenderer` and `SlugGlyphRenderer` so `TerminalBitmapView` can apply
/// the same backpressure policy (drop-and-retry on the next tick) regardless
/// of which backend is active.
public enum RenderFailureReason: String, Codable, Equatable, Sendable {
  /// The previous GPU frame had not retired yet (backpressure, not an error).
  case previousFrameInFlight
  /// `MTLCommandQueue.makeCommandBuffer()` returned nil.
  case commandBufferUnavailable
  /// The persistent terminal-content target texture could not be allocated.
  case targetTextureUnavailable
  /// A full redraw was required but the content pass produced nothing — e.g.
  /// a cell-payload build failure or a command-fed grid-geometry change that
  /// demands a full repaint. The frame is dropped and retried full next time.
  case fullRedrawProducedNoContent
  /// `CAMetalLayer` had no drawable available to present into.
  case drawableUnavailable
  /// A lazy motion-pipeline variant failed to compile.
  case motionPipelineCompilation
  /// The layer resized between target allocation and drawable acquisition, so
  /// the mismatched drawable was dropped and a full repaint forced.
  case drawableSizeMismatch

  /// GPU/compositor backpressure rather than a recoverable-by-retrying error:
  /// either the previous frame is still in flight or the display has not yet
  /// drained a drawable. The caller should leave the frame invalidated and let
  /// the next display-link tick repaint at the display's own cadence.
  public var isGPUBackpressure: Bool {
    switch self {
    case .previousFrameInFlight, .drawableUnavailable:
      return true
    case .commandBufferUnavailable, .targetTextureUnavailable,
      .fullRedrawProducedNoContent, .drawableSizeMismatch,
      .motionPipelineCompilation:
      return false
    }
  }
}

/// A GPU backend that reports why its last `render(...)` returned `false`.
///
/// The host (`TerminalBitmapView`) applies one backpressure policy to every
/// backend: a backpressure failure is paced or parked, anything else is
/// retried. It needs the reason to make that call, and a backend that does not
/// supply one is indistinguishable from a non-backpressure failure — which
/// turns a single busy GPU pipeline into an unbounded immediate-retry loop that
/// blocks the main thread in `MetalDrawableScheduler.beginFrame`.
///
/// This is a protocol rather than a chain of concrete casts at the call site so
/// that a new backend cannot opt out of the policy by being absent from a list;
/// `RenderFailureReasonTests` asserts every shipped GPU backend conforms.
public protocol RenderFailureReporting: AnyObject {
  var lastRenderFailureReason: RenderFailureReason? { get }
}
