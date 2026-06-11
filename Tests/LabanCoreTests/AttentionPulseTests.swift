import Foundation
import XCTest

@testable import LabanCore

final class AttentionPulseTests: XCTestCase {
  func testEntranceFadesFromZeroToFull() {
    XCTAssertEqual(AttentionPulse.markerAlpha(elapsed: 0), 0, accuracy: 1e-9)
    XCTAssertEqual(
      AttentionPulse.markerAlpha(elapsed: AttentionPulse.entranceDuration / 2), 0.5,
      accuracy: 1e-9)
    XCTAssertEqual(
      AttentionPulse.markerAlpha(elapsed: AttentionPulse.entranceDuration), 1.0, accuracy: 1e-9)
  }

  /// After the announce the marker rests static — a continuous loop in the
  /// peripheral sidebar is the blink pattern this design exists to avoid.
  func testRestIsStaticFullOpacity() {
    for t in [1.0, 10.0, 30.0, 44.0] {
      XCTAssertEqual(
        AttentionPulse.markerAlpha(elapsed: AttentionPulse.entranceDuration + t), 1.0,
        accuracy: 1e-9, "rest at +\(t)s must be static")
    }
  }

  func testPingDipsToFloorAndRecovers() {
    let pingMid =
      AttentionPulse.entranceDuration + AttentionPulse.pingPeriod + AttentionPulse.pingDuration / 2
    XCTAssertEqual(
      AttentionPulse.markerAlpha(elapsed: pingMid), AttentionPulse.pingFloor, accuracy: 1e-9)
    let afterPing =
      AttentionPulse.entranceDuration + AttentionPulse.pingPeriod + AttentionPulse.pingDuration
      + 0.1
    XCTAssertEqual(AttentionPulse.markerAlpha(elapsed: afterPing), 1.0, accuracy: 1e-9)
  }

  func testHaloOnlyDuringEntrance() {
    let mid = AttentionPulse.halo(elapsed: AttentionPulse.entranceDuration / 2)
    XCTAssertNotNil(mid, "the entrance blooms a halo")
    XCTAssertGreaterThan(mid?.scale ?? 0, 1.0)
    XCTAssertNil(AttentionPulse.halo(elapsed: AttentionPulse.entranceDuration + 0.01))
    XCTAssertNil(AttentionPulse.halo(elapsed: -0.01))
  }

  /// Frame pacing contract: animating only inside entrance/ping windows, and
  /// the rest gaps report how long until the next window so the frame loop
  /// can schedule a single wake instead of ticking.
  func testAnimationWindowsAndWakeDelays() {
    XCTAssertTrue(AttentionPulse.isAnimating(elapsed: 0.1))
    XCTAssertFalse(AttentionPulse.isAnimating(elapsed: AttentionPulse.entranceDuration + 10))
    XCTAssertTrue(
      AttentionPulse.isAnimating(
        elapsed: AttentionPulse.entranceDuration + AttentionPulse.pingPeriod + 0.1))
    XCTAssertEqual(AttentionPulse.delayToNextAnimation(elapsed: 0.1), 0)
    XCTAssertEqual(
      AttentionPulse.delayToNextAnimation(elapsed: AttentionPulse.entranceDuration + 10),
      AttentionPulse.pingPeriod - 10, accuracy: 1e-9)
    XCTAssertEqual(
      AttentionPulse.delayToNextAnimation(
        elapsed: AttentionPulse.entranceDuration + AttentionPulse.pingPeriod + 5),
      AttentionPulse.pingPeriod - 5, accuracy: 1e-9)
  }

  func testApplyAlphaOnlyChangesLowByte() {
    let base: UInt32 = 0xFA57_50FF
    let out = AttentionPulse.applyAlpha(base, 0.5)
    XCTAssertEqual(out & 0xFFFF_FF00, base & 0xFFFF_FF00, "RGB preserved")
    XCTAssertEqual(out & 0xFF, 128, "alpha = round(0.5*255) = 128")
  }

  func testApplyAlphaClamps() {
    XCTAssertEqual(AttentionPulse.applyAlpha(0x1122_33FF, 2.0) & 0xFF, 0xFF)
    XCTAssertEqual(AttentionPulse.applyAlpha(0x1122_33FF, -1.0) & 0xFF, 0x00)
  }
}
