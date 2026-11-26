import Foundation
import LabanCore

/// Headless parity for `session.spawnTab` / `session.spawnSplit`. Validation,
/// anchoring to the caller's own pane, focus, label, and the "Opened by a
/// program" notice match the GUI path. The headless runtime always starts its
/// own session kind (a fixture or `/bin/sh`), so `argv` is validated but not
/// executed here; the GUI runs it.
struct DebugSpawnActions {
  unowned let runtime: HeadlessDebugRuntime

  func spawn(action: String, request: ControlSpawnRequest, scopedSessionID: String?)
    -> DebugResponse
  {
    guard let intentID = DebugActionIntentID.intentID(forAction: action),
      let body = try? JSONEncoder().encode(request)
    else { return jsonError("unsupported action") }
    let plan: ControlSpawnPlan
    switch ControlSpawnRouting.plan(
      intentID: intentID,
      body: body,
      scopedSessionID: scopedSessionID,
      activeSessionID: runtime.model.activeTab?.focusedSessionId)
    {
    case .failure(let rejection):
      return jsonError(rejection.reason, status: rejection.status)
    case .success(let value):
      plan = value
    }
    let notice = ControlSpawnRouting.noticeText(argv: plan.argv)
    let response: ControlSpawnResponse
    if let axis = plan.placement.paneAxis {
      guard let anchor = plan.anchorSessionID,
        let tab = runtime.model.tabs.first(where: { $0.allSessionIds.contains(anchor) })
      else { return jsonError("caller session is not open", status: 409) }
      guard runtime.terminalBackend != .laband else {
        return jsonError("this terminal backend cannot split panes", status: 409)
      }
      do {
        let id = try runtime.model.splitPane(
          inTab: tab.id, axis: axis, anchor: anchor, focusNewPane: plan.focus
        ) { id, size, cwd in
          try runtime.model.makePaneSession(id: id, inTab: tab.id, size: size, cwd: cwd)
        }
        response = ControlSpawnResponse(tabID: tab.id, sessionID: id, placement: plan.placement)
      } catch AppModel.PaneError.tooSmall {
        return jsonError("not enough room to split this pane", status: 409)
      } catch {
        return jsonError("could not open terminal: \(error)", status: 500)
      }
      _ = runtime.model.postTabNotice(forTab: tab.id, note: "control.spawn", text: notice)
    } else {
      let previous = runtime.model.activeTab?.id
      do {
        let tab = try runtime.model.createTab()
        try runtime.ensureTerminalClientSessionUnlocked(for: tab)
        if let label = plan.label { try? runtime.model.renameTab(tab.id, title: label) }
        _ = runtime.model.postTabNotice(forTab: tab.id, note: "control.spawn", text: notice)
        if !plan.focus, let previous { runtime.model.selectTab(previous) }
        response = ControlSpawnResponse(
          tabID: tab.id, sessionID: tab.focusedSessionId, placement: .tab)
      } catch {
        return jsonError("could not open terminal: \(error)", status: 500)
      }
    }
    runtime.renderFrameUnlocked()
    runtime.appendEvent(
      EventEntry(kind: "control.spawn", tabId: response.tabID, sessionId: response.sessionID))
    return jsonEncode(response)
  }
}
