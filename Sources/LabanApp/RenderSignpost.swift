import Foundation
import OSLog

/// Emits Points-of-Interest signposts that mark which renderer / smooth-scroll
/// mode is active, so a single Instruments capture can be sliced by configuration
/// (record once, switch renderers live, then segment the trace per segment).
///
/// Capture notes (these are why earlier signpost runs found nothing):
///  - Points-of-Interest signposts only land in a `.trace` if the recording
///    template includes the os_signpost / Points of Interest instrument. The
///    "Metal System Trace" template does NOT by default — add the "Points of
///    Interest" instrument to the session (or record with a template that has
///    it) or the segments won't be captured.
///  - The category MUST be `.pointsOfInterest`; that category is always enabled
///    and is what surfaces in the Points of Interest track.
enum RenderSignpost {
  static let subsystem = "com.rrva.laban.render"

  private static let signposter = OSSignposter(
    logHandle: OSLog(subsystem: subsystem, category: .pointsOfInterest))

  /// State of the currently open renderer-configuration interval, so switching
  /// closes the previous segment and opens the next. Main-thread only (renderer
  /// changes are main-thread), so no extra synchronization is needed.
  private static var openInterval: (state: OSSignpostIntervalState, label: String)?

  /// Mark a renderer/mode change: ends the previous "RenderConfig" interval and
  /// begins a new one labeled with the active configuration, and emits a point
  /// event at the transition. `label` should identify the config being measured,
  /// e.g. "vector/fluid" or "gpu-driven".
  static func configActivated(_ label: String) {
    if let open = openInterval {
      signposter.endInterval("RenderConfig", open.state)
    }
    signposter.emitEvent("RenderConfigChange", "\(label, privacy: .public)")
    let state = signposter.beginInterval("RenderConfig", "\(label, privacy: .public)")
    openInterval = (state, label)
  }
}
