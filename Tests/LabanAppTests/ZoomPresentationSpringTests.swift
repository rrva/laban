import XCTest

@testable import LabanApp

final class ZoomPresentationSpringTests: XCTestCase {
  func testSettlesExactlyOnTarget() {
    var spring = ZoomPresentationSpring(omega: ZoomPresentationSpring.wheelOmega, scale: 1)
    spring.retarget(scale: 1.07)
    for _ in 0..<60 { spring.advance(by: 1.0 / 60) }
    XCTAssertTrue(spring.isSettled)
    XCTAssertEqual(spring.displayedScale, 1.07, accuracy: 1e-12)
  }

  /// A wheel notch must glide over several frames, not land in one.
  func testWheelNotchSpreadsOverFrames() {
    var spring = ZoomPresentationSpring(omega: ZoomPresentationSpring.wheelOmega, scale: 1)
    spring.retarget(scale: 1.07)
    var previous = spring.displayedScale
    var largestStep = 0.0
    var framesToNinetyPercent = 0
    for frame in 1...60 {
      spring.advance(by: 1.0 / 60)
      largestStep = max(largestStep, spring.displayedScale / previous - 1)
      previous = spring.displayedScale
      if framesToNinetyPercent == 0, spring.displayedScale >= 1.063 {
        framesToNinetyPercent = frame
      }
    }
    XCTAssertLessThan(largestStep, 0.025, "no single 60 Hz frame takes more than a third of a notch")
    XCTAssertGreaterThanOrEqual(framesToNinetyPercent, 4)
    XCTAssertLessThanOrEqual(framesToNinetyPercent, 9, "the glide still lands in ~150 ms")
  }

  /// The trackpad judder on a 60 Hz panel: input arrives 1, 1, 0, 2, ... per
  /// frame. Applied directly, the zero frames are hitches; through the spring
  /// every frame moves and the step range narrows.
  func testBeatingTrackpadInputStillMovesEveryFrame() {
    let eventsPerFrame = [1, 1, 0, 2, 1, 0, 2, 1, 1, 0, 2, 1, 1, 1, 0, 2, 1, 1, 0, 2]
    var spring = ZoomPresentationSpring(omega: ZoomPresentationSpring.trackpadOmega, scale: 1)
    var target = 1.0
    var previous = 1.0
    var steps: [Double] = []
    for count in eventsPerFrame {
      for _ in 0..<count { target *= 1.01 }
      spring.retarget(scale: target)
      spring.advance(by: 1.0 / 60)
      steps.append(spring.displayedScale / previous - 1)
      previous = spring.displayedScale
    }
    let moving = Array(steps.dropFirst())
    XCTAssertGreaterThan(moving.min()!, 0.003, "no still frames while input keeps coming")
    XCTAssertLessThan(moving.max()!, 0.0175, "no full double step")
  }

  /// Same wall-clock glide at 60 and 120 Hz.
  func testGlideIsFrameRateIndependent() {
    var at60 = ZoomPresentationSpring(omega: ZoomPresentationSpring.wheelOmega, scale: 1)
    var at120 = at60
    at60.retarget(scale: 1.5)
    at120.retarget(scale: 1.5)
    for _ in 0..<6 { at60.advance(by: 1.0 / 60) }
    for _ in 0..<12 { at120.advance(by: 1.0 / 120) }
    XCTAssertEqual(at60.displayedScale, at120.displayedScale, accuracy: 1e-9)
  }

  func testZoomOutMirrorsZoomIn() {
    var zoomIn = ZoomPresentationSpring(omega: ZoomPresentationSpring.wheelOmega, scale: 1)
    var zoomOut = zoomIn
    zoomIn.retarget(scale: 2)
    zoomOut.retarget(scale: 0.5)
    for _ in 0..<3 {
      zoomIn.advance(by: 1.0 / 60)
      zoomOut.advance(by: 1.0 / 60)
    }
    XCTAssertEqual(zoomIn.displayedScale * zoomOut.displayedScale, 1, accuracy: 1e-12)
  }
}
