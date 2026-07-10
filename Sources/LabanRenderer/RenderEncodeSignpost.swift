import Foundation
import OSLog

/// Signposts for per-frame renderer encode work (e.g. the slug present blit),
/// emitted on a normal custom category rather than `.pointsOfInterest`: these
/// fire once or more per frame, and would flood the Points of Interest track
/// that `RenderSignpost` uses for rare renderer-config changes.
///
/// Capture notes:
///  - The Metal System Trace template records no signposts by default; add the
///    os_signpost instrument to the session. Its "Enable Subsystems" list can
///    stay empty (it only opts subsystems into the DynamicTracing categories);
///    ordinary categories like this one are always recorded once the
///    instrument is present.
///  - Spans may begin on the render thread or the present-link thread; each
///    interval carries its own signpost ID so concurrent blits don't collide.
enum RenderEncodeSignpost {
  static let signposter = OSSignposter(
    logHandle: OSLog(subsystem: "com.rrva.laban.render", category: "encode"))
}
