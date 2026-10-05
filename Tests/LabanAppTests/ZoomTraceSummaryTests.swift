import LabanRenderer
import XCTest

@testable import LabanApp

final class ZoomTraceSummaryTests: XCTestCase {
  private func input(_ t: Double) -> ZoomTraceInput {
    ZoomTraceInput(
      time: t, source: "precise", deltaY: 0, scrollingDeltaY: 1, phase: 0, momentumPhase: 0)
  }

  private func presents(start: Double, sizes: [Double], hz: Double = 60) -> [ZoomPresentSample] {
    sizes.enumerated().map { i, s in
      ZoomPresentSample(time: start + Double(i) / hz, visualPointSize: s, fresh: true)
    }
  }

  func testEvenGlideHasNoStillVsyncs() {
    let sizes = (0..<30).map { 14 * pow(1.01, Double($0)) }
    let summary = ZoomTraceSummary(
      inputs: (0..<30).map { input(1 + Double($0) / 60) },
      presents: presents(start: 1, sizes: sizes), commits: [])
    let burst = try! XCTUnwrap(summary.bursts.first)
    XCTAssertEqual(summary.bursts.count, 1)
    XCTAssertEqual(burst.vsyncs, 29)
    XCTAssertEqual(burst.stillVsyncs, 0)
    XCTAssertEqual(burst.p50StepPercent, 1, accuracy: 1e-6)
    XCTAssertEqual(burst.maxStepPercent, 1, accuracy: 1e-6)
  }

  /// The judder pattern on a 60 Hz panel: some vsyncs miss an input (no size
  /// change) and the next shows a double step.
  func testBeatingInputCountsStillVsyncsAndDoubleSteps() {
    var sizes: [Double] = [14]
    for step in [1, 1, 0, 2, 1, 0, 2, 1, 1, 1] {
      sizes.append(sizes.last! * pow(1.01, Double(step)))
    }
    let summary = ZoomTraceSummary(
      inputs: (0..<10).map { input(1 + Double($0) / 60) },
      presents: presents(start: 1, sizes: sizes), commits: [])
    let burst = try! XCTUnwrap(summary.bursts.first)
    XCTAssertEqual(burst.vsyncs, 10)
    XCTAssertEqual(burst.stillVsyncs, 2)
    XCTAssertEqual(burst.maxStepPercent, 2.01, accuracy: 1e-6)
  }

  func testIdleVsyncsAroundMotionAreNotCounted() {
    let sizes = [14, 14, 14, 14.14, 14.28, 14.28, 14.28, 14.28]
    let summary = ZoomTraceSummary(
      inputs: [input(1.04)], presents: presents(start: 1, sizes: sizes), commits: [])
    XCTAssertEqual(summary.bursts.first?.vsyncs, 2)
    XCTAssertEqual(summary.bursts.first?.stillVsyncs, 0)
  }

  func testGapSplitsBurstsAndAttributesCommits() {
    let commits = [
      ZoomTraceCommit(time: 1.2, durationMs: 21, pointSize: 15),
      ZoomTraceCommit(time: 3.2, durationMs: 19, pointSize: 16),
      ZoomTraceCommit(time: 3.3, durationMs: 22, pointSize: 17),
    ]
    let summary = ZoomTraceSummary(
      inputs: [input(1), input(1.1), input(3), input(3.05)], presents: [], commits: commits)
    XCTAssertEqual(summary.bursts.map(\.inputs), [2, 2])
    XCTAssertEqual(summary.bursts.map(\.commits), [1, 2])
    XCTAssertEqual(summary.bursts[1].maxCommitMs, 22)
  }

  func testMomentumInputsDoNotFormBursts() {
    let momentum = ZoomTraceInput(
      time: 5, source: "momentum", deltaY: 0, scrollingDeltaY: 1, phase: 0, momentumPhase: 4)
    let summary = ZoomTraceSummary(inputs: [momentum], presents: [], commits: [])
    XCTAssertTrue(summary.bursts.isEmpty)
  }
}
