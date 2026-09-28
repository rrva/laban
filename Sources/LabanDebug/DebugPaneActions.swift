import Foundation
import LabanCore

struct DebugPaneActions {
  unowned let runtime: HeadlessDebugRuntime

  func apply(_ action: String, _ request: PaneActionRequest) -> DebugResponse {
    guard
      let tab = request.tabId.flatMap({ id in runtime.model.tabs.first { $0.id == id } })
        ?? (request.tabId == nil ? runtime.model.activeTab : nil)
    else {
      return jsonError("unknownSession", status: 404)
    }
    switch action {
    case "pane.split":
      guard runtime.terminalBackend != .laband else {
        return jsonError("unsupportedBackend", status: 400)
      }
      guard let axis = PaneAxis(rawValue: request.axis ?? "vertical") else {
        return jsonError("notALeaf", status: 400)
      }
      do {
        _ = try runtime.model.splitPane(inTab: tab.id, axis: axis) { id, size, cwd in
          try runtime.model.makePaneSession(id: id, inTab: tab.id, size: size, cwd: cwd)
        }
      } catch AppModel.PaneError.notALeaf { return jsonError("notALeaf", status: 400) } catch {
        return jsonError("daemonRefused: \(error)", status: 400)
      }
    case "pane.close":
      let id = request.sessionId ?? tab.focusedSessionId
      guard tab.panes.contains(id) else { return jsonError("unknownSession", status: 404) }
      runtime.model.closePane(inTab: tab.id, sessionId: id) {
        runtime.terminateTerminalClientSessionUnlocked(sessionId: $0)
        runtime.selectionBySession.removeValue(forKey: $0)
      }
    default:
      if let id = request.sessionId {
        guard tab.panes.contains(id) else { return jsonError("unknownSession", status: 404) }
        runtime.model.focusPane(inTab: tab.id, sessionId: id)
      } else if let direction = request.direction, ["next", "previous"].contains(direction) {
        runtime.model.focusAdjacentPane(inTab: tab.id, forward: direction == "next")
      } else {
        return jsonError("unknownSession", status: 400)
      }
    }
    runtime.renderFrameUnlocked()
    return jsonEncode(
      PaneActionResult(
        ok: true, frame: runtime.currentFrame,
        activeTabId: runtime.model.activeTab?.id,
        activeSessionId: runtime.model.activeTab?.focusedSessionId,
        sessionId: runtime.model.tabs.first(where: { $0.id == tab.id })?.focusedSessionId))
  }
}

private struct PaneActionResult: Encodable {
  let ok: Bool
  let frame: Int
  let activeTabId: String?
  let activeSessionId: String?
  let sessionId: String?
}
