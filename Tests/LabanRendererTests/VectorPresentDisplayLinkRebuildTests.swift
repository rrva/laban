import Metal
import QuartzCore
import XCTest

@testable import LabanRenderer

private final class PresentRunLoopBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: CFRunLoop?

  var value: CFRunLoop? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storage
    }
    set {
      lock.lock()
      storage = newValue
      lock.unlock()
    }
  }
}

/// The clamshell/display-detach bug (2026-07-21): a `CAMetalDisplayLink` whose
/// display disappears never fires again (frozen terminal) and later aborts its
/// run loop on the dead vsync port (`__CFRunLoopServiceMachPort.cold.1`).
/// `VectorPresentDisplayLink.rebuild()` swaps in a fresh link on the present
/// thread. These gates pin the rebuild lifecycle: no-op before start/after
/// stop, exactly one rebuild per call, and the park intent surviving the swap.
@available(macOS 14.0, *)
final class VectorPresentDisplayLinkRebuildTests: XCTestCase {
  private func makeLink() -> VectorPresentDisplayLink? {
    guard let device = MTLCreateSystemDefaultDevice() else { return nil }
    let layer = CAMetalLayer()
    layer.device = device
    return VectorPresentDisplayLink(layer: layer)
  }

  private func rebuilds(_ link: VectorPresentDisplayLink) -> Double {
    link.presentIntervalStats(reset: false)["rebuilds"] ?? -1
  }

  /// Wait until `predicate` holds, pumping the main run loop so the present
  /// thread gets scheduled. Returns false on timeout.
  private func waitFor(
    _ timeout: TimeInterval = 5, _ predicate: () -> Bool
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if predicate() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    return predicate()
  }

  /// `CFRunLoopStop()` called before `CFRunLoopRun()` does not apply to the
  /// later activation (measured on the macOS 27 incident build). The lifecycle
  /// helper must queue the stop so a backend teardown in this startup window
  /// cannot leak the dedicated present thread.
  func testStopRequestBeforeRunActivationStopsFirstActivation() {
    let captured = expectation(description: "run loop captured")
    let exited = expectation(description: "run loop exited")
    let proceed = DispatchSemaphore(value: 0)
    let box = PresentRunLoopBox()
    let thread = Thread {
      let keepalive = Timer(timeInterval: 3600, repeats: true) { _ in }
      RunLoop.current.add(keepalive, forMode: .default)
      box.value = CFRunLoopGetCurrent()
      captured.fulfill()
      proceed.wait()
      CFRunLoopRun()
      exited.fulfill()
    }
    thread.start()

    wait(for: [captured], timeout: 1)
    guard let runLoop = box.value else {
      XCTFail("present thread must publish its run loop")
      proceed.signal()
      return
    }
    requestPresentRunLoopStop(runLoop)
    proceed.signal()
    wait(for: [exited], timeout: 1)
  }

  func testRebuildBeforeStartIsNoOp() {
    guard let link = makeLink() else { return }
    link.rebuild()
    XCTAssertEqual(rebuilds(link), 0, "no present thread yet -> nothing to rebuild")
    link.stop()
  }

  func testRebuildAfterStopIsNoOp() {
    guard let link = makeLink() else { return }
    link.start()
    link.stop()
    link.rebuild()
    XCTAssertEqual(rebuilds(link), 0, "stopped link must stay dead")
  }

  func testRebuildOnRunningLinkSwapsExactlyOnce() {
    guard let link = makeLink() else { return }
    link.start()
    link.rebuild()
    XCTAssertTrue(
      waitFor { self.rebuilds(link) == 1 },
      "rebuild must run on the present thread and record itself")
    link.rebuild()
    XCTAssertTrue(
      waitFor { self.rebuilds(link) == 2 },
      "each rebuild call swaps the link once")
    link.stop()
  }

  /// The host's park intent must survive the swap: a terminal the idle policy
  /// wants running comes out of the rebuild unpaused (so the next publish
  /// presents), and a parked terminal stays parked.
  func testRebuildPreservesRunIntent() {
    guard let link = makeLink() else { return }
    link.start()

    link.setRunning(true)
    link.rebuild()
    XCTAssertTrue(waitFor { self.rebuilds(link) == 1 })
    XCTAssertFalse(link.debugLinkIsPaused, "host wants running -> rebuilt link runs")

    link.setRunning(false)
    link.rebuild()
    XCTAssertTrue(waitFor { self.rebuilds(link) == 2 })
    XCTAssertTrue(link.debugLinkIsPaused, "host parked -> rebuilt link stays parked")
    link.stop()
  }

  /// setRunning/notifyContentPublished racing a rebuild must not crash or
  /// resurrect a stopped link.
  func testRunStateCallsRaceRebuildSafely() {
    guard let link = makeLink() else { return }
    link.start()
    // Absorb the startup window first: rebuilds requested before the present
    // thread captures its run loop collapse into one deferred swap, so an
    // exact count is only meaningful once the thread is live.
    link.rebuild()
    XCTAssertTrue(waitFor { self.rebuilds(link) == 1 })
    for _ in 0..<20 {
      link.rebuild()
      link.setRunning(true)
      link.notifyContentPublished()
      link.setRunning(false)
    }
    XCTAssertTrue(
      waitFor { self.rebuilds(link) == 21 },
      "all queued rebuilds complete on the present thread")
    link.stop()
    let stopped = rebuilds(link)
    link.rebuild()
    link.setRunning(true)
    XCTAssertEqual(rebuilds(link), stopped, "post-stop calls are inert")
  }
}
