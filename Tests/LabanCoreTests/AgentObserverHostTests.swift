import Foundation
import LabanCore
import LabanTerminalCore
import XCTest

@testable import LabanCore

/// Tests for `AgentObserverHost`'s toggle-gating and
/// mirror-untrack-on-death behavior. The host owns no detector here
/// — we drive its `AgentSessionDetectorObserver` surface directly
/// with synthetic observations, which is the same path the real
/// detector takes.
final class AgentObserverHostTests: XCTestCase {

  private func makeModel() throws -> AppModel {
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    return try AppModel(initialSize: size, sessionFactory: { try Session.fixture(size: $0) })
  }

  private func makeMirror(in dir: URL) -> AgentJSONLMirror {
    AgentJSONLMirror(
      store: PersistenceStore(baseURL: dir),
      periodicInterval: .seconds(300))
  }

  func testObserverIgnoresObservationsWhenToggleDisabled() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-observer-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = try makeModel()
    let host = AgentObserverHost(
      appModel: model,
      mirror: makeMirror(in: dir),
      isEnabled: { false })

    // Construct a detector just so we have an object to identify.
    let detector = AgentSessionDetector(
      tabId: model.tabs[0].id, shellPid: 1, introspector: NoChildrenIntrospector())
    let observed = AgentInfo(
      name: .claude,
      sessionId: "0fa31a8c-1234-5678-9abc-deadbeef0000",
      jsonlPath: "/tmp/test.jsonl",
      wasRunningAtQuit: true)
    host.agentSessionDetector(detector, didObserve: observed)

    XCTAssertNil(
      model.agent(forTab: model.tabs[0].id),
      "disabled host must not push observations into AppModel")
  }

  func testDetachUntracksMirrorEvenWhenToggleFlippedOff() throws {
    // A tab was created while the toggle was on, a detector
    // started, the mirror picked up an agent and began its 5-min
    // timer. Then the user flips the menu toggle off. Closing the
    // tab MUST still untrack the mirror — otherwise the periodic
    // timer keeps running with no way to stop it short of quitting
    // Laban.
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-detach-untrack-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = try makeModel()
    let tabId = model.tabs[0].id

    let recordingMirror = RecordingMirror(store: PersistenceStore(baseURL: dir))
    var enabled = true
    let host = AgentObserverHost(
      appModel: model,
      mirror: recordingMirror,
      isEnabled: { enabled })

    let detector = AgentSessionDetector(
      tabId: tabId, shellPid: 1, introspector: NoChildrenIntrospector())
    let alive = AgentInfo(
      name: .claude,
      sessionId: "0fa31a8c-1234-5678-9abc-deadbeef0000",
      jsonlPath: "/tmp/session.jsonl",
      wasRunningAtQuit: true)
    host.agentSessionDetector(detector, didObserve: alive)
    XCTAssertEqual(
      recordingMirror.events,
      [.track(tabId: tabId, path: "/tmp/session.jsonl")])

    // Toggle off mid-session, then close the tab.
    enabled = false
    host.detach(tabId: tabId)
    XCTAssertTrue(
      recordingMirror.events.contains { event in
        if case .untrack(let id, _) = event, id == tabId { return true }
        return false
      },
      "detach must untrack mirror to cancel the periodic timer regardless of toggle state")
  }

  func testObserverUntracksMirrorWhenAgentDies() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-observer-untrack-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = try makeModel()
    let tabId = model.tabs[0].id

    // Recording mirror lets us assert the lifecycle events without
    // standing up a real file copy chain.
    let recordingMirror = RecordingMirror(store: PersistenceStore(baseURL: dir))
    let host = AgentObserverHost(
      appModel: model,
      mirror: recordingMirror,
      isEnabled: { true })
    let detector = AgentSessionDetector(
      tabId: tabId, shellPid: 1, introspector: NoChildrenIntrospector())

    let alive = AgentInfo(
      name: .claude,
      sessionId: "0fa31a8c-1234-5678-9abc-deadbeef0000",
      jsonlPath: "/tmp/session.jsonl",
      wasRunningAtQuit: true)
    host.agentSessionDetector(detector, didObserve: alive)
    XCTAssertEqual(
      recordingMirror.events,
      [.track(tabId: tabId, path: "/tmp/session.jsonl")],
      "alive observation must call track")

    // The detector emits a non-nil AgentInfo with
    // wasRunningAtQuit=false when the agent dies (preserves
    // identity). The host must treat that as "stop the periodic
    // timer" — NOT as "agent still alive, keep tracking."
    let dead = AgentInfo(
      name: .claude,
      sessionId: alive.sessionId,
      jsonlPath: alive.jsonlPath,
      wasRunningAtQuit: false)
    host.agentSessionDetector(detector, didObserve: dead)
    XCTAssertEqual(
      recordingMirror.events.last,
      .untrack(tabId: tabId, finalSnapshot: true),
      "dead observation must untrack with a final snapshot, not re-track")
  }
}

// MARK: - Helpers

private final class NoChildrenIntrospector: ProcessIntrospector {
  func children(of parent: pid_t) -> [(pid: pid_t, basename: String)] { [] }
  func openVnodePaths(of pid: pid_t) -> [String] { [] }
  func arguments(of pid: pid_t) -> [String] { [] }
  func environment(of pid: pid_t) -> [String: String] { [:] }
  func currentWorkingDirectory(of pid: pid_t) -> String? { nil }
}

private final class RecordingMirror: JSONLMirroring {
  enum Event: Equatable {
    case track(tabId: String, path: String)
    case untrack(tabId: String, finalSnapshot: Bool)
    case snapshotAll
  }
  var events: [Event] = []

  // Init takes a store argument for symmetry with how the real
  // mirror is constructed; tests pass a temp-rooted store.
  init(store: PersistenceStore) { _ = store }

  func track(tabId: String, jsonlPath: String) {
    events.append(.track(tabId: tabId, path: jsonlPath))
  }
  func untrack(tabId: String, finalSnapshot: Bool) {
    events.append(.untrack(tabId: tabId, finalSnapshot: finalSnapshot))
  }
  func snapshotAll() {
    events.append(.snapshotAll)
  }
}
