import XCTest

@testable import LabanApp

final class RemoteSnapshotRenderTrackerTests: XCTestCase {
  func testGenerationIsDirtyOnlyUntilRendered() {
    var tracker = RemoteSnapshotRenderTracker()
    let tabId = "tab-1"

    XCTAssertTrue(
      tracker.terminalDirty(tabId: tabId, generation: 7, fallbackDirty: true))

    tracker.markRendered(tabId: tabId, generation: 7)

    XCTAssertFalse(
      tracker.terminalDirty(tabId: tabId, generation: 7, fallbackDirty: true))
    XCTAssertTrue(
      tracker.terminalDirty(tabId: tabId, generation: 8, fallbackDirty: false))
  }

  func testNilGenerationUsesFallbackDirtyFlag() {
    var tracker = RemoteSnapshotRenderTracker()
    let tabId = "tab-1"
    tracker.markRendered(tabId: tabId, generation: 7)

    XCTAssertTrue(
      tracker.terminalDirty(tabId: tabId, generation: nil, fallbackDirty: true))
    XCTAssertFalse(
      tracker.terminalDirty(tabId: tabId, generation: nil, fallbackDirty: false))
  }

  func testClearForgetsRenderedGeneration() {
    var tracker = RemoteSnapshotRenderTracker()
    let tabId = "tab-1"
    tracker.markRendered(tabId: tabId, generation: 7)

    tracker.clear(tabId: tabId)

    XCTAssertTrue(
      tracker.terminalDirty(tabId: tabId, generation: 7, fallbackDirty: false))
  }
}
