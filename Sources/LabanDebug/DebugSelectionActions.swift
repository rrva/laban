import Foundation
import LabanCore

struct DebugSelectionActions {
  private unowned let runtime: HeadlessDebugRuntime

  init(runtime: HeadlessDebugRuntime) {
    self.runtime = runtime
  }

  func setSelection(_ request: SelectionActionRequest) -> DebugResponse {
    let frameBefore = runtime.currentFrame
    guard let anchorRequest = request.anchor, let focusRequest = request.focus else {
      return jsonError("setSelection requires anchor and focus")
    }
    let targetTab = runtime.targetTab(sessionId: request.sessionId)
    guard let tab = targetTab,
      let session = runtime.model.session(forSessionID: tab.focusedSessionId)
    else {
      return jsonError("no session for setSelection")
    }
    let selection = TerminalSelection(
      sessionId: session.id,
      anchor: TerminalCellCoordinate(row: anchorRequest.row, col: anchorRequest.col),
      focus: TerminalCellCoordinate(row: focusRequest.row, col: focusRequest.col)
    )
    runtime.selectionBySession[session.id] = selection
    runtime.appendInputEnvelope(
      InputEventEnvelope(
        inputId: UUID().uuidString,
        source: "debug",
        kind: "selection",
        route: "selection",
        frameBefore: frameBefore,
        tabId: tab.id,
        sessionId: session.id,
        command: "setSelection",
        anchorRow: anchorRequest.row,
        anchorCol: anchorRequest.col,
        focusRow: focusRequest.row,
        focusCol: focusRequest.col
      ))
    runtime.renderFrameUnlocked()
    runtime.appendEvent(EventEntry(kind: "selection.set", sessionId: tab.focusedSessionId))
    return runtime.actionResult(ok: true)
  }
}
