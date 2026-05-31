import XCTest

@testable import LabanCore

final class LabptyByteRingOverflowGateTests: XCTestCase {
  /// A restart reconnect: the first read positions the cursor from offset 0 and
  /// overflows because the session has emitted more than a window of output over
  /// its lifetime. That join-mid-stream repaint must not count as a live drop.
  func testFirstReadOverflowIsNotALiveDrop() {
    var gate = LabptyByteRingOverflowGate()
    XCTAssertFalse(gate.isLiveDrop(overflowed: true))
  }

  /// Once positioned, an overflow means we fell behind the producer in real time
  /// — the rare, badge-worthy event.
  func testOverflowAfterPositioningIsALiveDrop() {
    var gate = LabptyByteRingOverflowGate()
    _ = gate.isLiveDrop(overflowed: true)  // reconnect join
    XCTAssertTrue(gate.isLiveDrop(overflowed: true))
  }

  /// A fresh spawn's first read does not overflow (tiny lifetime); a genuine
  /// later overflow must still be reported. The cursor is marked positioned by
  /// the first read even though it did not overflow.
  func testFirstReadWithoutOverflowStillPositionsCursor() {
    var gate = LabptyByteRingOverflowGate()
    XCTAssertFalse(gate.isLiveDrop(overflowed: false))
    XCTAssertTrue(gate.isLiveDrop(overflowed: true))
  }

  /// Non-overflowing reads are never live drops, no matter how many precede.
  func testNonOverflowingReadsAreNeverLiveDrops() {
    var gate = LabptyByteRingOverflowGate()
    for _ in 0..<5 {
      XCTAssertFalse(gate.isLiveDrop(overflowed: false))
    }
  }

  /// After a live drop the reader catches up; a subsequent overflow re-arms as a
  /// fresh live drop (the gate stays positioned, it does not latch off).
  func testRepeatedLiveDropsAfterPositioning() {
    var gate = LabptyByteRingOverflowGate()
    _ = gate.isLiveDrop(overflowed: false)  // position
    XCTAssertTrue(gate.isLiveDrop(overflowed: true))
    XCTAssertFalse(gate.isLiveDrop(overflowed: false))
    XCTAssertTrue(gate.isLiveDrop(overflowed: true))
  }
}
