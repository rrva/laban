import Foundation
import LabanCore
import LabanTerminalCore

struct DebugPreeditActions {
  private unowned let runtime: HeadlessDebugRuntime

  init(runtime: HeadlessDebugRuntime) {
    self.runtime = runtime
  }

  func setPreedit(_ request: PreeditActionRequest) -> DebugResponse {
    let frameBefore = runtime.currentFrame
    let targetTab = runtime.targetTab(sessionId: request.sessionId)
    guard let tab = targetTab, runtime.model.session(forSessionID: tab.focusedSessionId) != nil
    else {
      return jsonError("no session for setPreedit")
    }

    let text = request.text ?? ""
    if text.isEmpty {
      runtime.preeditBySession.removeValue(forKey: tab.focusedSessionId)
    } else {
      let graphemeClusterMode: Bool
      if let session = runtime.model.session(forSessionID: tab.focusedSessionId),
        let snapshot = session.snapshot()
      {
        defer { laban_snapshot_destroy(snapshot) }
        graphemeClusterMode = snapshot.pointee.grapheme_cluster_2027 != 0
      } else {
        graphemeClusterMode = false
      }
      let maxCaretCells = FrameProducer.preeditCaretCells(
        for: text, graphemeClusterMode: graphemeClusterMode)
      let requestedCaret = request.caretCells ?? maxCaretCells
      let caretCells = min(max(0, requestedCaret), maxCaretCells)
      runtime.preeditBySession[tab.focusedSessionId] = (text: text, caretCells: caretCells)
    }

    runtime.appendInputEnvelope(
      InputEventEnvelope(
        inputId: UUID().uuidString,
        source: "debug",
        kind: "preedit",
        route: "appCommand",
        frameBefore: frameBefore,
        tabId: tab.id,
        sessionId: tab.focusedSessionId,
        text: text.isEmpty ? nil : text,
        command: "setPreedit"
      ))
    runtime.renderFrameUnlocked()
    runtime.appendEvent(
      EventEntry(
        kind: text.isEmpty ? "preedit.cleared" : "preedit.set",
        sessionId: tab.focusedSessionId))
    return runtime.actionResult(ok: true)
  }
}
