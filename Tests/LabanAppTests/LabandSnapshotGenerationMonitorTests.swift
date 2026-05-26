import Foundation
import XCTest

@testable import LabanApp

final class LabandSnapshotGenerationMonitorTests: XCTestCase {
  func testTrackSeedsCurrentGenerationWithoutWaking() {
    let state = LockedGenerationState(["session": 7])
    let unexpectedWake = expectation(description: "no initial wake")
    unexpectedWake.isInverted = true

    let monitor = LabandSnapshotGenerationMonitor(
      interval: .milliseconds(5),
      generationProvider: { state.generation(for: $0) },
      wakeHandler: { _, _ in unexpectedWake.fulfill() })
    defer { monitor.stop() }

    monitor.track(sessionId: "session")

    wait(for: [unexpectedWake], timeout: 0.05)
  }

  func testGenerationAdvanceWakesRenderer() {
    let state = LockedGenerationState(["session": 1])
    let woke = expectation(description: "generation advance wakes")
    let monitor = LabandSnapshotGenerationMonitor(
      interval: .milliseconds(5),
      generationProvider: { state.generation(for: $0) },
      wakeHandler: { sessionId, _ in
        XCTAssertEqual(sessionId, "session")
        woke.fulfill()
      })
    defer { monitor.stop() }

    monitor.track(sessionId: "session")
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(20)) {
      state.setGeneration(2, for: "session")
    }

    wait(for: [woke], timeout: 1)
  }

  func testBoostPollsBeforeIdleInterval() {
    let state = LockedGenerationState(["session": 1])
    let woke = expectation(description: "boosted generation advance wakes")
    let monitor = LabandSnapshotGenerationMonitor(
      interval: .milliseconds(250),
      activeInterval: .milliseconds(5),
      generationProvider: { state.generation(for: $0) },
      wakeHandler: { sessionId, _ in
        XCTAssertEqual(sessionId, "session")
        woke.fulfill()
      })
    defer { monitor.stop() }

    monitor.track(sessionId: "session")
    state.setGeneration(2, for: "session")
    monitor.boost(sessionId: "session")

    wait(for: [woke], timeout: 0.1)
  }
}

private final class LockedGenerationState: @unchecked Sendable {
  private let lock = NSLock()
  private var generations: [String: UInt64]

  init(_ generations: [String: UInt64]) {
    self.generations = generations
  }

  func generation(for sessionId: String) -> UInt64? {
    lock.lock()
    defer { lock.unlock() }
    return generations[sessionId]
  }

  func setGeneration(_ generation: UInt64, for sessionId: String) {
    lock.lock()
    generations[sessionId] = generation
    lock.unlock()
  }
}
