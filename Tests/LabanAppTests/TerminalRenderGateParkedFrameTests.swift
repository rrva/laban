import XCTest

@testable import LabanApp

/// `advanceFrame` parks (idle early-return) on every vsync while the window is
/// visible. The parked-frame journal gate must stay silent at the live bottom
/// (the common idle case) and emit exactly one entry per distinct off-bottom
/// position, so a dropped scroll-to-bottom trigger is visible without the
/// bounded render-journal ring being flooded by idle ticks.
final class TerminalRenderGateParkedFrameTests: XCTestCase {

  func testLiveBottomNeverRecordsAndResetsSignature() {
    let decision = TerminalRenderGate.parkedFrameDecision(
      appliedScrollRows: 0,
      lastParkSignature: "-3")
    XCTAssertFalse(decision.shouldRecord)
    XCTAssertNil(decision.signature)
  }

  func testFirstOffBottomParkRecords() {
    let decision = TerminalRenderGate.parkedFrameDecision(
      appliedScrollRows: -3,
      lastParkSignature: nil)
    XCTAssertTrue(decision.shouldRecord)
    XCTAssertEqual(decision.signature, "-3")
  }

  func testSustainedParkAtSamePositionRecordsOnce() {
    let first = TerminalRenderGate.parkedFrameDecision(
      appliedScrollRows: -3,
      lastParkSignature: nil)
    let second = TerminalRenderGate.parkedFrameDecision(
      appliedScrollRows: -3,
      lastParkSignature: first.signature)
    XCTAssertTrue(first.shouldRecord)
    XCTAssertFalse(second.shouldRecord)
    XCTAssertEqual(second.signature, "-3")
  }

  func testMovingToNewOffBottomPositionRecordsAgain() {
    let decision = TerminalRenderGate.parkedFrameDecision(
      appliedScrollRows: -4,
      lastParkSignature: "-3")
    XCTAssertTrue(decision.shouldRecord)
    XCTAssertEqual(decision.signature, "-4")
  }

  func testReturningToBottomThenOffBottomLogsFresh() {
    // Off-bottom, parked, logged.
    let parked = TerminalRenderGate.parkedFrameDecision(
      appliedScrollRows: -2,
      lastParkSignature: nil)
    // Snapped to the live bottom: signature clears.
    let atBottom = TerminalRenderGate.parkedFrameDecision(
      appliedScrollRows: 0,
      lastParkSignature: parked.signature)
    // Scrolled back to the same position: must log again, not dedupe.
    let again = TerminalRenderGate.parkedFrameDecision(
      appliedScrollRows: -2,
      lastParkSignature: atBottom.signature)
    XCTAssertTrue(parked.shouldRecord)
    XCTAssertFalse(atBottom.shouldRecord)
    XCTAssertTrue(again.shouldRecord)
  }
}
