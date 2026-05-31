import Foundation
import XCTest

@testable import LabanCore

final class AttentionPulseTests: XCTestCase {
  private func at(_ t: TimeInterval) -> Double {
    AttentionPulse.alpha(at: Date(timeIntervalSinceReferenceDate: t))
  }

  func testFloorAtPhaseZero() {
    XCTAssertEqual(at(0), AttentionPulse.floor, accuracy: 1e-9)
  }

  func testFullAtHalfPeriod() {
    XCTAssertEqual(at(AttentionPulse.period / 2), 1.0, accuracy: 1e-9)
  }

  func testFloorAgainAtFullPeriod() {
    XCTAssertEqual(at(AttentionPulse.period), AttentionPulse.floor, accuracy: 1e-9)
  }

  /// The breath never leaves `[floor, 1]` — it pulses, it does not blink to zero.
  func testAlwaysWithinFloorAndOne() {
    for i in 0...300 {
      let v = at(Double(i) / 100.0)
      XCTAssertGreaterThanOrEqual(v, AttentionPulse.floor - 1e-9)
      XCTAssertLessThanOrEqual(v, 1.0 + 1e-9)
    }
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
