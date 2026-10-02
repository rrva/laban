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
      } catch AppModel.PaneError.notALeaf {
        return jsonError("notALeaf", status: 400)
      } catch AppModel.PaneError.tooSmall {
        return jsonError("tooSmall", status: 400)
      } catch {
        return jsonError("daemonRefused: \(error)", status: 400)
      }
    case "pane.close":
      guard tab.allSessionIds.count > 1 else { return jsonError("lastPane", status: 400) }
      let id = request.sessionId ?? tab.focusedSessionId
      guard tab.panes.contains(id) else { return jsonError("unknownSession", status: 404) }
      runtime.model.closePane(inTab: tab.id, sessionId: id) {
        runtime.terminateTerminalClientSessionUnlocked(sessionId: $0)
        runtime.selectionBySession.removeValue(forKey: $0)
      }
    case "pane.resize":
      if let failure = resize(request, in: tab) { return failure }
    case "pane.equalize":
      runtime.model.equalizePanes(inTab: tab.id)
    case "pane.zoom":
      runtime.model.setPaneZoom(inTab: tab.id, zoomed: request.zoomed)
    default:
      if let id = request.sessionId {
        guard tab.panes.contains(id) else { return jsonError("unknownSession", status: 404) }
        runtime.model.focusPane(inTab: tab.id, sessionId: id)
      } else if let direction = request.direction, ["next", "previous"].contains(direction) {
        runtime.model.focusAdjacentPane(inTab: tab.id, forward: direction == "next")
      } else if let direction = request.direction.flatMap(PaneDirection.init(rawValue:)) {
        // At the layout edge this is a no-op, exactly like the Cmd+Option+Arrow chord.
        runtime.model.focusPane(inTab: tab.id, direction: direction)
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

  /// `pane.resize`: `path` + `fraction` moves a divider; `direction` alone nudges the
  /// focused pane's nearest divider on that side by two cells. Returns an error response
  /// or nil on success.
  private func resize(_ request: PaneActionRequest, in tab: Tab) -> DebugResponse? {
    if let rawPath = request.path {
      var path: PanePath = []
      for component in rawPath {
        guard let side = PaneSide(rawValue: component) else {
          return jsonError("notSplit", status: 400)
        }
        path.append(side)
      }
      guard let fraction = request.fraction, fraction.isFinite else {
        return jsonError("pane.resize requires fraction with path", status: 400)
      }
      do {
        try runtime.model.setSplitFraction(inTab: tab.id, path: path, fraction: fraction)
      } catch AppModel.PaneError.notSplit {
        return jsonError("notSplit", status: 400)
      } catch {
        return jsonError("unknownSession", status: 404)
      }
      return nil
    }
    guard let direction = request.direction.flatMap(PaneDirection.init(rawValue:)) else {
      return jsonError("pane.resize requires path and fraction, or a direction", status: 400)
    }
    runtime.model.nudgeDivider(inTab: tab.id, direction: direction)
    return nil
  }
}

private struct PaneActionResult: Encodable {
  let ok: Bool
  let frame: Int
  let activeTabId: String?
  let activeSessionId: String?
  let sessionId: String?
}
