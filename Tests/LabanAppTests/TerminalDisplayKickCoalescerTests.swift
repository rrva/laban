import XCTest

@testable import LabanApp

@MainActor
final class TerminalDisplayKickCoalescerTests: XCTestCase {
  func testRequestsCoalesceUntilMainActorAdvanceRuns() async {
    let coalescer = TerminalDisplayKickCoalescer()
    let first = Date(timeIntervalSinceReferenceDate: 1)
    let second = Date(timeIntervalSinceReferenceDate: 2)
    var advances = 0

    coalescer.requestFrameAdvance(now: first) {
      advances += 1
    }
    coalescer.requestFrameAdvance(now: second) {
      advances += 1
    }

    XCTAssertEqual(coalescer.latestDirtyAt(), second)
    await drainMainActorTasks()
    XCTAssertEqual(advances, 1)

    coalescer.requestFrameAdvance(now: Date(timeIntervalSinceReferenceDate: 3)) {
      advances += 1
    }
    await drainMainActorTasks()
    XCTAssertEqual(advances, 2)
  }

  private func drainMainActorTasks() async {
    for _ in 0..<3 {
      await Task.yield()
    }
  }
}
