import Foundation

extension ControlStateProjections {
  /// What closing a pane, tab, the window, or the app would ask, without
  /// showing the dialog. `scope` defaults to `tab`. `pane` targets the named
  /// or default session; `tab` the tab holding it (or `tabId`); `window` and
  /// `quit` every session.
  public static func closeConfirmationState(
    query: [String: String],
    ctx: ControlProjectionContext
  ) -> ControlJSONResponse {
    let rawScope = query["scope"] ?? CloseConfirmationScope.tab.rawValue
    guard let scope = CloseConfirmationScope(rawValue: rawScope) else {
      return controlJSONError("unknown scope: \(rawScope)", status: 400)
    }
    let sessionIds: [Session.ID]
    switch scope {
    case .window, .quit:
      sessionIds = ctx.model.tabs.flatMap(\.allSessionIds)
    case .pane, .tab:
      let tab: Tab?
      let sessionId: Session.ID?
      if let tabId = query["tabId"] {
        tab = ctx.model.tabs.first { $0.id == tabId }
        sessionId = tab?.focusedSessionId
      } else {
        let requested = query["sessionID"] ?? query["sessionId"]
        sessionId = requested ?? resolvedDefaultSessionID(ctx: ctx)
        tab = sessionId.flatMap { id in ctx.model.tabs.first { $0.allSessionIds.contains(id) } }
      }
      guard let tab, let sessionId else {
        return controlJSONError("session not found", status: 404)
      }
      sessionIds = scope == .pane ? [sessionId] : tab.allSessionIds
    }
    let model = ctx.model
    let clientInfo = ctx.sessionClientInfoById
    let environment =
      ctx.closeConfirmationEnvironment
      ?? CloseConfirmationEnvironment(
        shellPid: { CloseConfirmation.shellPid(for: $0, model: model, clientInfo: clientInfo) },
        sessionsSurviveQuit: false)
    return controlJSONEncode(
      CloseConfirmation.decide(
        scope: scope, sessionIds: sessionIds, model: model, environment: environment))
  }
}
