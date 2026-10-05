import Foundation

/// Watches, after a display change, whether the renderer's present link calls
/// back as often as the main display link while both run. After a display was
/// removed from under the window, Laban's present link kept calling back at the
/// removed display's 60 Hz on the 120 Hz built-in panel, through link rebuilds,
/// until the renderer (and its CAMetalLayer) was recreated. A refresh made while
/// the window was hidden did not always stick, so a timed refresh alone is not
/// enough: this check confirms the cadence once both links are running.
///
/// Armed by a display change; disarmed by one healthy window, or after
/// `maximumRefreshes` corrective refreshes, so a present link that is slow for
/// another reason never causes a refresh loop. GPU-free so it is unit-tested.
struct PresentCadenceCheck: Equatable {
  /// Seconds of running links per comparison.
  static let window: TimeInterval = 2.0
  /// Fewer main ticks than this per window (an idle or throttled main link) is
  /// not a meaningful comparison.
  static let minimumMainTicks = 60
  /// Present callbacks below this fraction of main ticks count as stuck. A
  /// stuck link measured 0.5; a healthy one 1.0 or more.
  static let stuckRatio = 0.75
  static let maximumRefreshes = 2

  enum Verdict: Equatable {
    case keep
    case refresh(ratio: Double)
  }

  private(set) var armed = false
  private(set) var refreshesThisArming = 0
  private var mainTicks = 0
  private var windowStart: (time: TimeInterval, mainTicks: Int, presentCallbacks: Int)?

  static func == (a: Self, b: Self) -> Bool {
    a.armed == b.armed && a.refreshesThisArming == b.refreshesThisArming
  }

  mutating func arm() {
    armed = true
    refreshesThisArming = 0
    windowStart = nil
  }

  /// One main display-link tick. `presentCallbacks` is the present link's
  /// lifetime callback count, nil without a present link; `linksRunning` is
  /// false whenever either link is parked or the window is not visible.
  mutating func tick(at now: TimeInterval, presentCallbacks: Int?, linksRunning: Bool) -> Verdict {
    guard armed else { return .keep }
    guard linksRunning, let presentCallbacks else {
      windowStart = nil
      return .keep
    }
    mainTicks += 1
    // A recreated renderer brings a new link whose count restarts.
    guard let start = windowStart, presentCallbacks >= start.presentCallbacks else {
      windowStart = (now, mainTicks, presentCallbacks)
      return .keep
    }
    guard now - start.time >= Self.window else { return .keep }
    windowStart = (now, mainTicks, presentCallbacks)
    let main = mainTicks - start.mainTicks
    guard main >= Self.minimumMainTicks else { return .keep }
    let ratio = Double(presentCallbacks - start.presentCallbacks) / Double(main)
    guard ratio < Self.stuckRatio else {
      armed = false
      return .keep
    }
    refreshesThisArming += 1
    if refreshesThisArming >= Self.maximumRefreshes { armed = false }
    windowStart = nil
    return .refresh(ratio: ratio)
  }
}
