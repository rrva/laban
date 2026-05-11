import Foundation
import LabanCore

struct DebugViewportActions {
  private unowned let runtime: HeadlessDebugRuntime

  init(runtime: HeadlessDebugRuntime) {
    self.runtime = runtime
  }

  func scrollViewport(_ request: ScrollViewportActionRequest) -> DebugResponse {
    let frameBefore = runtime.currentFrame
    let targetTab =
      request.sessionId.flatMap { sessionId in
        runtime.model.tabs.first(where: { $0.sessionId == sessionId })
      } ?? runtime.model.activeTab
    guard let tab = targetTab, let session = runtime.model.session(forTab: tab.id) else {
      return jsonError("no session for scrollViewport")
    }
    let deltaRows = request.deltaRows ?? 0
    session.scrollViewport(deltaRows: deltaRows)
    runtime.appendInputEnvelope(
      InputEventEnvelope(
        inputId: UUID().uuidString,
        source: "debug",
        kind: "scroll",
        route: "terminal",
        frameBefore: frameBefore,
        tabId: tab.id,
        sessionId: session.id,
        command: "scrollViewport",
        deltaRows: deltaRows
      ))
    runtime.renderFrameUnlocked()
    runtime.appendEvent(
      EventEntry(kind: "viewport.scrolled", sessionId: tab.sessionId, deltaRows: request.deltaRows)
    )
    return runtime.actionResult(ok: true)
  }
}
