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
    let targetTab =
      request.sessionId.flatMap { sessionId in
        runtime.model.tabs.first(where: { $0.sessionId == sessionId })
      } ?? runtime.model.activeTab
    guard let tab = targetTab, runtime.model.session(forTab: tab.id) != nil else {
      return jsonError("no session for setPreedit")
    }

    let text = request.text ?? ""
    if text.isEmpty {
      runtime.preeditBySession.removeValue(forKey: tab.sessionId)
    } else {
      let graphemeClusterMode: Bool
      if let session = runtime.model.session(forTab: tab.id),
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
      runtime.preeditBySession[tab.sessionId] = (text: text, caretCells: caretCells)
    }

    runtime.appendInputEnvelope(
      InputEventEnvelope(
        inputId: UUID().uuidString,
        source: "debug",
        kind: "preedit",
        route: "appCommand",
        frameBefore: frameBefore,
        tabId: tab.id,
        sessionId: tab.sessionId,
        text: text.isEmpty ? nil : text,
        command: "setPreedit"
      ))
    runtime.renderFrameUnlocked()
    runtime.appendEvent(
      EventEntry(
        kind: text.isEmpty ? "preedit.cleared" : "preedit.set",
        sessionId: tab.sessionId))
    return runtime.actionResult(ok: true)
  }
}
