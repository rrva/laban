import Darwin
import Foundation
import LabanCore
import LabanTerminalCore

extension HeadlessDebugRuntime {
  public func wait(_ data: Data) -> DebugResponse {
    guard let request = try? JSONDecoder().decode(WaitRequest.self, from: data) else {
      return jsonError("invalid wait request")
    }

    let startTime = Date()
    let timeoutSec = Double(request.timeoutMs) / 1000.0

    while true {
      let result = withRuntimeLock {
        syncSessionMetadataUnlocked()
        let satisfied = checkConditionUnlocked(request.condition)
        if !satisfied && deterministic {
          for tab in model.tabs {
            model.session(forTab: tab.id)?.poll()
          }
          renderFrameUnlocked()
        }
        return (satisfied: satisfied, frame: currentFrame)
      }
      if result.satisfied {
        let elapsed = Date().timeIntervalSince(startTime) * 1000.0
        return jsonEncode(WaitResult(ok: true, frame: result.frame, elapsedMs: elapsed))
      }

      if Date().timeIntervalSince(startTime) >= timeoutSec { break }
      usleep(10_000)
      if Date().timeIntervalSince(startTime) >= timeoutSec { break }
    }

    let frame = withRuntimeLock { currentFrame }
    let elapsed = Date().timeIntervalSince(startTime) * 1000.0
    return jsonEncode(
      WaitResult(
        ok: false,
        frame: frame,
        elapsedMs: elapsed,
        error: "timeout after \(request.timeoutMs)ms"
      ))
  }

  func checkConditionUnlocked(_ condition: WaitCondition) -> Bool {
    switch condition.kind {
    case "frameAtLeast":
      return currentFrame >= (condition.frame ?? 0)
    case "tabCount":
      return model.tabs.count == (condition.count ?? 0)
    case "activeTab":
      return model.activeTab?.id == condition.tabId
    case "sessionStatus":
      let tabId =
        condition.sessionId.flatMap { sessionId in
          model.tabs.first(where: { $0.sessionId == sessionId })?.id
        } ?? condition.tabId ?? model.activeTab?.id
      if let id = tabId,
        let tab = model.tabs.first(where: { $0.id == id }),
        let snapshot = terminalClientSnapshotUnlocked(sessionId: tab.sessionId)
      {
        return snapshot.lifecycleState.rawValue == condition.status
      }
      guard let id = tabId,
        let session = model.session(forTab: id),
        let snapshot = session.snapshot()
      else { return false }
      defer { laban_snapshot_destroy(snapshot) }
      return snapshotStatus(UnsafePointer(snapshot)) == condition.status
    case "titleEquals":
      let tab =
        condition.tabId.flatMap { id in model.tabs.first(where: { $0.id == id }) }
        ?? model.activeTab
      return tab?.title == condition.title
    case "textVisible":
      guard let tab = waitTargetTabUnlocked(condition) else { return false }
      if let snapshot = terminalClientSnapshotUnlocked(sessionId: tab.sessionId) {
        return snapshot.visibleText.contains(condition.text ?? "")
      }
      guard let session = model.session(forTab: tab.id),
        let snapshot = session.snapshot()
      else { return false }
      defer { laban_snapshot_destroy(snapshot) }
      return TerminalSnapshotText.visibleText(
        from: UnsafePointer(snapshot),
        mode: .trimmedNonEmptyRows
      ).contains(condition.text ?? "")
    case "renderCommandSeen":
      guard let kind = condition.commandKind else { return false }
      return lastFrameCommands.contains { DebugFrameCommandSerializer.kind($0) == kind }
    case "eventSeen":
      guard let kind = condition.eventKind else { return false }
      return logs.containsEvent(kind: kind)
    case "renderTraceInvariant":
      return true
    default:
      return false
    }
  }

  func waitTargetTabUnlocked(_ condition: WaitCondition) -> Tab? {
    if let sessionId = condition.sessionId {
      return model.tabs.first { $0.sessionId == sessionId }
    }
    if let tabId = condition.tabId {
      return model.tabs.first { $0.id == tabId }
    }
    return model.activeTab
  }
}
