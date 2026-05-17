import Foundation
import LabanCore
import XCTest

@testable import LabanApp

/// Tests for the runtime kill-switch behavior on the JSONL mirror.
/// The unit tests for `AgentObserverHost` already cover the
/// lifecycle hand-off; this file pins the mirror's own self-gating
/// so a flip-the-menu-off operation truly stops snapshots even when
/// the host doesn't get a fresh observation to react to.
final class AgentJSONLMirrorTests: XCTestCase {

  func testSnapshotIsNoOpWhenToggleDisabled() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-mirror-toggle-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("session.jsonl")
    try Data("hello\n".utf8).write(to: source)

    var enabled = true
    let mirror = AgentJSONLMirror(
      store: PersistenceStore(baseURL: dir),
      periodicInterval: .seconds(300),
      isEnabled: { enabled })

    let tabId = "tab-mirror-toggle"
    mirror.track(tabId: tabId, jsonlPath: source.path)
    // track() calls snapshot once synchronously — the file should exist.
    let dest = dir
      .appendingPathComponent("agent-mirror", isDirectory: true)
      .appendingPathComponent("\(tabId).jsonl")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: dest.path),
      "enabled track must produce an immediate snapshot")

    // Flip the gate off and snapshot again — the destination mtime
    // must not advance.
    enabled = false
    let beforeMtime = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.modificationDate])
      as? Date
    Thread.sleep(forTimeInterval: 0.05)
    try Data("changed\n".utf8).write(to: source)
    mirror.snapshot(tabId: tabId)
    let afterMtime = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.modificationDate])
      as? Date
    XCTAssertEqual(beforeMtime, afterMtime,
      "disabled snapshot must NOT copy the source even when called explicitly")
    mirror.untrack(tabId: tabId, finalSnapshot: false)
  }
}
