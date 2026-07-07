import Foundation
import LabanCore

struct DebugFindActions {
  private unowned let runtime: HeadlessDebugRuntime

  init(runtime: HeadlessDebugRuntime) {
    self.runtime = runtime
  }

  func start(_ request: FindStartRequest) -> DebugResponse {
    guard let needle = request.needle, !needle.isEmpty else {
      return jsonError("find.start requires a non-empty needle")
    }
    guard let sessionId = targetSessionId(request.targetSessionId) else {
      return jsonError("session not found", status: 404)
    }
    guard runtime.model.startFind(sessionID: sessionId, needle: needle) != nil else {
      return jsonError("session not found: \(sessionId)", status: 404)
    }
    recordFindInput(command: "find.start", sessionId: sessionId, text: needle)
    runtime.renderFrameUnlocked()
    runtime.appendEvent(EventEntry(kind: "find.started", sessionId: sessionId))
    return state(sessionId: sessionId)
  }

  func step(_ request: FindStepRequest) -> DebugResponse {
    guard let direction = TerminalFindDirection(rawValue: request.direction ?? "next") else {
      return jsonError("find.step direction must be next or previous")
    }
    guard let sessionId = targetSessionId(request.targetSessionId) else {
      return jsonError("session not found", status: 404)
    }
    guard runtime.model.stepFind(sessionID: sessionId, direction: direction) != nil else {
      return jsonError("find is not active for session: \(sessionId)", status: 404)
    }
    recordFindInput(command: "find.step", sessionId: sessionId, text: direction.rawValue)
    runtime.renderFrameUnlocked()
    runtime.appendEvent(
      EventEntry(kind: "find.stepped", sessionId: sessionId, action: direction.rawValue))
    return state(sessionId: sessionId)
  }

  func stop(_ request: FindSessionRequest) -> DebugResponse {
    guard let sessionId = targetSessionId(request.targetSessionId) else {
      return jsonError("session not found", status: 404)
    }
    _ = runtime.model.stopFind(sessionID: sessionId)
    recordFindInput(command: "find.stop", sessionId: sessionId, text: nil)
    runtime.renderFrameUnlocked()
    runtime.appendEvent(EventEntry(kind: "find.stopped", sessionId: sessionId))
    return jsonEncode(FindStopResponse(stopped: true))
  }

  func state(_ request: FindSessionRequest) -> DebugResponse {
    guard let sessionId = targetSessionId(request.targetSessionId) else {
      return jsonError("session not found", status: 404)
    }
    return state(sessionId: sessionId)
  }

  private func state(sessionId: Session.ID) -> DebugResponse {
    jsonEncode(
      ControlStateProjections.findStateResponse(runtime.model.findState(forSession: sessionId)))
  }

  private func targetSessionId(_ requested: String?) -> Session.ID? {
    if let requested, runtime.model.session(forSessionID: requested) != nil {
      return requested
    }
    if requested != nil {
      return nil
    }
    return runtime.model.activeTab?.sessionId
  }

  private func recordFindInput(command: String, sessionId: Session.ID, text: String?) {
    let tab = runtime.model.tabs.first { $0.sessionId == sessionId }
    runtime.appendInputEnvelope(
      InputEventEnvelope(
        inputId: UUID().uuidString,
        source: "debug",
        kind: "find",
        route: "appCommand",
        frameBefore: runtime.currentFrame,
        tabId: tab?.id,
        sessionId: sessionId,
        text: text,
        command: command
      ))
  }
}
