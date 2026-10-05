import Foundation

/// Glides the zoom presentation scale toward the scale the input asked for,
/// one display-link tick at a time, so the size on screen advances by even
/// per-frame steps however input events fall against vsync. On a 60 Hz panel a
/// ~60 Hz trackpad stream beats against vsync (some frames get no event, the
/// next gets two), and a notched wheel lands each notch in one frame; both
/// read as judder when applied directly.
///
/// Works in log scale so a zoom in and the matching zoom out glide alike. Same
/// closed-form critically damped update as smooth scroll in
/// `TerminalBitmapView.advanceFrame`: exact at any tick interval, so the glide
/// takes the same wall-clock time at 60 and 120 Hz.
struct ZoomPresentationSpring: Equatable {
  /// Trackpad: ~14 ms time constant, ~29 ms steady lag (2/omega). Against a
  /// 60 Hz stream beating on a 60 Hz vsync (1, 1, 0, 2, ... events per frame)
  /// per-frame steps stay within ~1.7x of each other; at omega 110 they range
  /// 2.7x, at 60 1.5x for 33 ms lag. Smooth scroll's omega is 50 (40 ms).
  static let trackpadOmega: Double = 70
  /// Notched wheel: a 7 % notch glides over ~120 ms instead of one frame.
  static let wheelOmega: Double = 40

  let omega: Double
  private(set) var displayedLog: Double
  private(set) var targetLog: Double
  /// d(displayedLog)/dt, per second.
  private(set) var velocity: Double = 0

  init(omega: Double, scale: Double) {
    self.omega = omega
    displayedLog = log(scale)
    targetLog = displayedLog
  }

  var displayedScale: Double { exp(displayedLog) }
  var targetScale: Double { exp(targetLog) }
  var isSettled: Bool { displayedLog == targetLog && velocity == 0 }

  mutating func retarget(scale: Double) {
    targetLog = log(scale)
  }

  mutating func advance(by dt: Double) {
    guard !isSettled, dt > 0 else { return }
    //   err(t) = (e0 + (v0 + ω·e0)·t)·e^(−ω·t),  err = displayed − target
    let e0 = displayedLog - targetLog
    let c2 = velocity + omega * e0
    let decay = exp(-omega * dt)
    displayedLog = targetLog + (e0 + c2 * dt) * decay
    velocity = (c2 - omega * (e0 + c2 * dt)) * decay
    // 1e-4 in log scale is a 0.01 % size difference: invisible.
    if abs(displayedLog - targetLog) < 1e-4, abs(velocity) < 1e-2 {
      displayedLog = targetLog
      velocity = 0
    }
  }
}
