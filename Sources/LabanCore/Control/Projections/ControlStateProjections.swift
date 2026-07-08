import CoreGraphics
import Foundation
import LabanRenderer
import LabanTerminalCore

public enum ControlStateProjections {
  public static func stateResponse(_ ctx: ControlProjectionContext) -> StateResponse {
    switch ctx.readRedaction {
    case .appObserveSummary:
      return appObserveStateResponse(ctx)
    case .sessionObserveSummary:
      return sessionObserveStateResponse(ctx)
    case .none:
      break
    }
    let tabs = filteredTabs(ctx).enumerated().map { index, tab in
      tabResponse(for: tab, index: index, ctx: ctx)
    }
    let activeTab = ctx.model.activeTab
    let scopedActiveTab: Tab? = {
      guard let scoped = ctx.scopedSessionID else { return activeTab }
      return tabs.first.flatMap { tab in ctx.model.tabs.first { $0.id == tab.id } }
        ?? ctx.model.tabs.first { $0.sessionId == scoped }
    }()
    let findStates = findStateResponses(ctx)
    return StateResponse(
      mode: ctx.mode,
      frame: ctx.frame,
      window: WindowResponse(width: ctx.windowWidth, height: ctx.windowHeight, focused: true),
      tabs: tabs,
      activeTabId: scopedActiveTab?.id ?? (ctx.scopedSessionID == nil ? activeTab?.id : nil),
      activeSessionId: scopedActiveTab?.sessionId
        ?? (ctx.scopedSessionID == nil ? activeTab?.sessionId : nil),
      findStateBySession: findStates,
      cursorSettings: cursorSettingsResponse(
        activeTab: scopedActiveTab ?? (ctx.scopedSessionID == nil ? activeTab : nil), ctx: ctx),
      emojiRendering: emojiRenderingSettingsResponse(),
      attentionNotifications: filteredAttentionNotifications(ctx).map(
        attentionNotificationDecisionResponse)
    )
  }

  private static func filteredAttentionNotifications(_ ctx: ControlProjectionContext)
    -> [AttentionNotificationDecision]
  {
    let all = ctx.model.recentAttentionNotificationDecisions
    guard let scoped = ctx.scopedSessionID else { return all }
    return all.filter { decision in
      guard let tab = ctx.model.tabs.first(where: { $0.id == decision.event.tabId }) else {
        return false
      }
      return tab.sessionId == scoped
    }
  }

  public static func accessibilityResponse(_ ctx: ControlProjectionContext) -> AccessibilityResponse
  {
    AccessibilityResponse(
      isElement: true,
      role: "AXTextArea",
      label: "Terminal",
      value: accessibilityValue(ctx),
      focusRingType: "none",
      display: ctx.accessibilityDisplayFlags)
  }

  public static func terminalModesResponse(_ ctx: ControlProjectionContext) -> TerminalModesResponse
  {
    var graphemeCluster2027 = false
    var synchronizedOutput = false
    var focusReporting = false
    var mouseTracking = false
    if let tab = tabForScopedRead(ctx),
      let session = ctx.model.session(forTab: tab.id),
      let snapshot = session.snapshot()
    {
      defer { laban_snapshot_destroy(snapshot) }
      graphemeCluster2027 = snapshot.pointee.grapheme_cluster_2027 != 0
      synchronizedOutput = snapshot.pointee.synchronized_output != 0
      focusReporting = snapshot.pointee.focus_reporting != 0
      mouseTracking = snapshot.pointee.mouse_tracking != 0
    }
    return TerminalModesResponse(
      graphemeCluster2027: graphemeCluster2027,
      synchronizedOutput: synchronizedOutput,
      focusReporting: focusReporting,
      mouseTracking: mouseTracking)
  }

  public static func sessionsResponse(_ ctx: ControlProjectionContext) -> SessionsResponse {
    let list = filteredTabs(ctx).enumerated().map { index, tab in
      sessionResponse(for: tab, index: index, includeGrid: false, ctx: ctx)
    }
    return SessionsResponse(sessions: list)
  }

  public static func sessionResponse(
    id: String,
    query: [String: String],
    ctx: ControlProjectionContext
  ) -> ControlJSONResponse {
    guard
      let match = ctx.model.tabs.enumerated().first(where: { $0.element.sessionId == id })
    else {
      return controlJSONError("session not found: \(id)", status: 404)
    }
    let includeGrid = query["includeGrid"] == "true"
    return controlJSONEncode(
      sessionResponse(for: match.element, index: match.offset, includeGrid: includeGrid, ctx: ctx))
  }

  public static func findStateResponse(_ state: TerminalFindState) -> FindStateResponse {
    FindStateResponse(
      isActive: state.isActive,
      needle: state.needle,
      total: state.matches.count,
      selectedIndex: state.selectedIndex,
      matches: state.matches.map {
        FindMatchResponse(row: $0.row, startColumn: $0.startColumn, endColumn: $0.endColumn)
      },
      viewportScrollOffsetAtStart: state.viewportScrollOffsetAtStart
    )
  }

  public static func findStateResponses(_ ctx: ControlProjectionContext) -> [String:
    FindStateResponse]
  {
    let states: [String: TerminalFindState]
    if let scoped = ctx.scopedSessionID {
      states = ctx.model.allFindStates.filter { $0.key == scoped }
    } else {
      states = ctx.model.allFindStates
    }
    return states.mapValues { findStateResponse($0) }
  }

  public static func findState(
    query: [String: String],
    ctx: ControlProjectionContext
  ) -> ControlJSONResponse {
    let request = FindSessionRequest(
      sessionID: query["sessionID"],
      sessionId: query["sessionId"]
    )
    guard let sessionId = targetSessionId(request.targetSessionId, ctx: ctx) else {
      return controlJSONError("session not found", status: 404)
    }
    return controlJSONEncode(findStateResponse(ctx.model.findState(forSession: sessionId)))
  }

  public static func shellIntegrationState(
    query: [String: String],
    ctx: ControlProjectionContext
  ) -> ControlJSONResponse {
    let requested = query["sessionID"] ?? query["sessionId"]
    let sessionId: Session.ID?
    if let requested {
      guard ctx.model.session(forSessionID: requested) != nil else {
        return controlJSONError("session not found: \(requested)", status: 404)
      }
      sessionId = requested
    } else {
      sessionId = resolvedDefaultSessionID(ctx: ctx)
    }
    guard let sessionId, let session = ctx.model.session(forSessionID: sessionId) else {
      return controlJSONError("session not found", status: 404)
    }
    let state = session.shellIntegrationState()
    return controlJSONEncode(
      ShellIntegrationStateResponse(
        sessionId: sessionId,
        phase: state.phase.rawValue,
        lastExitCode: state.lastExitCode
      ))
  }

  public static func scrollIndicatorState(
    query: [String: String],
    ctx: ControlProjectionContext
  ) -> ControlJSONResponse {
    let requested = query["sessionID"] ?? query["sessionId"]
    let targetTab: Tab? = {
      if let requested,
        let tab = ctx.model.tabs.first(where: { $0.sessionId == requested })
      {
        return tab
      }
      if requested != nil { return nil }
      if let scoped = ctx.scopedSessionID {
        return ctx.model.tabs.first { $0.sessionId == scoped }
      }
      return ctx.model.activeTab
    }()
    guard let tab = targetTab, let session = ctx.model.session(forTab: tab.id) else {
      return controlJSONError("session not found", status: 404)
    }
    guard let vs = session.viewportState() else {
      return controlJSONEncode(
        ScrollIndicatorStateResponse(available: false, input: nil, output: nil))
    }
    let hover = (query["hover"] ?? "false").lowercased() == "true"
    let input = TerminalScrollIndicator.Input(
      viewportOffset: vs.viewportOffset,
      totalRows: vs.totalRows,
      viewportRows: vs.viewportRows,
      isHoverEdge: hover,
      isAltScreen: vs.altScreen,
      isMouseTracking: vs.mouseTracking
    )
    let output = TerminalScrollIndicator.decide(input)
    return controlJSONEncode(
      ScrollIndicatorStateResponse(available: true, input: input, output: output))
  }

  public static func selectionResponse(_ ctx: ControlProjectionContext) -> SelectionResponse {
    let targetTab: Tab? = {
      if let scoped = ctx.scopedSessionID {
        return ctx.model.tabs.first { $0.sessionId == scoped }
      }
      return ctx.model.activeTab
    }()
    guard let tab = targetTab, let session = ctx.model.session(forTab: tab.id) else {
      return SelectionResponse(
        active: false, sessionId: nil, anchor: nil, focus: nil, rects: [], text: "")
    }

    guard let selection = ctx.selectionBySession[session.id] else {
      return SelectionResponse(
        active: false,
        sessionId: tab.sessionId,
        anchor: nil,
        focus: nil,
        rects: [],
        text: "")
    }

    var rects: [RectResponse] = []
    var text = ""

    if let snapshot = session.snapshot() {
      defer { laban_snapshot_destroy(snapshot) }
      let rows = Int(snapshot.pointee.rows)
      let cols = Int(snapshot.pointee.cols)
      for rect in selection.cgRects(
        rows: rows,
        cols: cols,
        cellWidth: CGFloat(ctx.cellWidth),
        cellHeight: CGFloat(ctx.cellHeight),
        originX: CGFloat(ctx.sidebarWidth),
        originY: 0
      ) {
        rects.append(ControlGridProjection.rectResponse(rect))
      }
      if let viewportState = session.viewportState() {
        text = selection.selectedText(
          from: session,
          viewportSnapshot: snapshot.pointee,
          viewportState: viewportState
        )
      } else {
        text = selection.selectedText(from: snapshot.pointee)
      }
    }

    return SelectionResponse(
      active: true,
      sessionId: tab.sessionId,
      anchor: CellCoordResponse(row: selection.anchor.row, col: selection.anchor.col),
      focus: CellCoordResponse(row: selection.focus.row, col: selection.focus.col),
      rects: rects,
      text: text
    )
  }

  public static func actionResult(
    ok: Bool,
    ctx: ControlProjectionContext,
    targetSessionID: Session.ID? = nil
  ) -> ActionResult {
    let active: Tab? = {
      if let targetSessionID {
        return ctx.model.tabs.first { $0.sessionId == targetSessionID }
      }
      return tabForScopedRead(ctx)
    }()
    return ActionResult(
      ok: ok,
      frame: ctx.frame,
      activeTabId: active?.id,
      activeSessionId: active?.sessionId,
      error: nil
    )
  }

  // MARK: - Private helpers

  private static func filteredTabs(_ ctx: ControlProjectionContext) -> [Tab] {
    guard let scoped = ctx.scopedSessionID else {
      return ctx.model.tabs
    }
    return ctx.model.tabs.filter { $0.sessionId == scoped }
  }

  private static func resolvedDefaultSessionID(ctx: ControlProjectionContext) -> Session.ID? {
    if let scoped = ctx.scopedSessionID {
      return scoped
    }
    return ctx.model.activeTab?.sessionId
  }

  private static func targetSessionId(_ requested: String?, ctx: ControlProjectionContext)
    -> Session.ID?
  {
    if let requested, ctx.model.session(forSessionID: requested) != nil {
      return requested
    }
    if requested != nil {
      return nil
    }
    return resolvedDefaultSessionID(ctx: ctx)
  }

  private static func appObserveStateResponse(_ ctx: ControlProjectionContext) -> StateResponse {
    let tabs = ctx.model.tabs.enumerated().map { index, tab in
      tabResponse(for: tab, index: index, ctx: ctx, redaction: .appObserveSummary)
    }
    let activeTab = ctx.model.activeTab
    return StateResponse(
      mode: ctx.mode,
      frame: ctx.frame,
      window: WindowResponse(width: ctx.windowWidth, height: ctx.windowHeight, focused: true),
      tabs: tabs,
      activeTabId: activeTab?.id,
      activeSessionId: activeTab?.sessionId,
      findStateBySession: [:],
      cursorSettings: cursorSettingsResponse(activeTab: activeTab, ctx: ctx),
      emojiRendering: emojiRenderingSettingsResponse(),
      attentionNotifications: [])
  }

  private static func sessionObserveStateResponse(_ ctx: ControlProjectionContext) -> StateResponse
  {
    let tabs = filteredTabs(ctx).enumerated().map { index, tab in
      tabResponse(for: tab, index: index, ctx: ctx, redaction: .sessionObserveSummary)
    }
    let activeTab = ctx.model.activeTab
    let scopedActiveTab: Tab? = {
      guard let scoped = ctx.scopedSessionID else { return activeTab }
      return ctx.model.tabs.first { $0.sessionId == scoped }
    }()
    return StateResponse(
      mode: ctx.mode,
      frame: ctx.frame,
      window: WindowResponse(width: ctx.windowWidth, height: ctx.windowHeight, focused: true),
      tabs: tabs,
      activeTabId: scopedActiveTab?.id ?? (ctx.scopedSessionID == nil ? activeTab?.id : nil),
      activeSessionId: scopedActiveTab?.sessionId
        ?? (ctx.scopedSessionID == nil ? activeTab?.sessionId : nil),
      findStateBySession: [:],
      cursorSettings: cursorSettingsResponse(
        activeTab: scopedActiveTab ?? (ctx.scopedSessionID == nil ? activeTab : nil), ctx: ctx),
      emojiRendering: emojiRenderingSettingsResponse(),
      attentionNotifications: [])
  }

  private static func tabForScopedRead(_ ctx: ControlProjectionContext) -> Tab? {
    if let scoped = ctx.scopedSessionID {
      return ctx.model.tabs.first { $0.sessionId == scoped }
    }
    return ctx.model.activeTab
  }

  private static func tabForAccessibility(_ ctx: ControlProjectionContext) -> Tab? {
    tabForScopedRead(ctx)
  }

  private static func tabResponse(
    for tab: Tab,
    index: Int,
    ctx: ControlProjectionContext,
    redaction: ControlReadRedaction = .none
  ) -> TabResponse {
    let metadata = tab.titleMetadata
    let status = ctx.model.session(forTab: tab.id) != nil ? tab.status.debugString : "failed"
    let redactSensitiveMetadata = redaction != .none
    let redactTitles = redaction == .sessionObserveSummary
    let agent = redactSensitiveMetadata ? TabAgentMetadata() : metadata.agent
    let progress = redactSensitiveMetadata ? nil : metadata.progress
    return TabResponse(
      id: tab.id,
      index: index,
      title: redactTitles ? "" : metadata.displayTitle,
      displayTitle: redactTitles ? "" : metadata.displayTitle,
      titleSource: redactTitles ? "" : metadata.titleSource.rawValue,
      terminalTitle: redactSensitiveMetadata ? nil : metadata.terminalTitle,
      userTitle: redactSensitiveMetadata ? nil : metadata.userTitle,
      titleFrozen: redactTitles ? false : metadata.titleFrozen,
      activityState: metadata.activityState.rawValue,
      lastActivityAt: tab.lastActivityAt,
      lastOutputAt: tab.lastOutputAt,
      unseenOutput: metadata.unseenOutput,
      bellAttention: metadata.bellAttention,
      attention: TabAttentionClassifier.classify(metadata, isActive: tab.isActive).rawValue,
      exitStatus: metadata.exitStatus,
      shellPhase: metadata.shellPhase.rawValue,
      lastCommandExitCode: metadata.lastCommandExitCode,
      workspace: redactTitles ? TabWorkspaceMetadata() : metadata.workspace,
      process: redactTitles ? TabProcessMetadata() : metadata.process,
      agent: agent,
      progress: progress,
      active: tab.isActive,
      status: status,
      sessionId: tab.sessionId
    )
  }

  private static func tabResponse(for tab: Tab, index: Int, ctx: ControlProjectionContext)
    -> TabResponse
  {
    tabResponse(for: tab, index: index, ctx: ctx, redaction: ctx.readRedaction)
  }

  private static func cursorSettingsResponse(
    activeTab: Tab?,
    ctx: ControlProjectionContext
  ) -> CursorSettingsResponse {
    var styleOverridden: Bool?
    var blinkOverridden: Bool?
    if let activeTab,
      let session = ctx.model.session(forTab: activeTab.id),
      let snapshot = session.snapshot()
    {
      defer { laban_snapshot_destroy(snapshot) }
      styleOverridden = snapshot.pointee.cursor_style_explicit != 0
      blinkOverridden = snapshot.pointee.cursor_blink_explicit != 0
    }
    return CursorSettingsResponse(
      style: CursorSettings.style.rawValue,
      blinkEnabled: CursorSettings.blinkEnabled,
      styleOverridden: styleOverridden,
      blinkOverridden: blinkOverridden)
  }

  private static func emojiRenderingSettingsResponse() -> EmojiRenderingSettingsResponse {
    let mode = EmojiRenderingSettings.current().rawValue
    return EmojiRenderingSettingsResponse(mode: mode, effectiveMode: mode)
  }

  private static func attentionNotificationDecisionResponse(
    _ decision: AttentionNotificationDecision
  ) -> AttentionNotificationDecisionResponse {
    AttentionNotificationDecisionResponse(
      id: decision.event.id,
      tabId: decision.event.tabId,
      source: decision.event.source.rawValue,
      category: decision.event.category.rawValue,
      action: decision.action.rawValue,
      reason: decision.suppressionReason?.rawValue,
      title: decision.event.title,
      body: decision.event.body,
      dedupeKey: decision.event.dedupeKey,
      createdAt: decision.event.createdAt,
      decidedAt: decision.decidedAt)
  }

  private static func accessibilityValue(_ ctx: ControlProjectionContext) -> String {
    guard let tab = tabForAccessibility(ctx) else { return "" }
    if let provider = ctx.accessibilityValueProvider {
      return provider(tab)
    }
    if let clientSnapshot = ctx.clientSnapshotProvider?(tab.sessionId) {
      return clientSnapshot.visibleText
    }
    guard let session = ctx.model.session(forTab: tab.id),
      let snapshot = session.snapshot()
    else { return "" }
    defer { laban_snapshot_destroy(snapshot) }
    return TerminalSnapshotText.visibleText(
      from: UnsafePointer(snapshot),
      mode: .trimmedNonEmptyRows)
  }

  private static func sessionResponse(
    for tab: Tab,
    index _: Int,
    includeGrid: Bool,
    ctx: ControlProjectionContext
  ) -> SessionResponse {
    let metadata = tab.titleMetadata
    let sessionObj = ctx.model.session(forTab: tab.id)
    let clientInfo = ctx.sessionClientInfoById[tab.sessionId]
    let clientSnapshot = ctx.clientSnapshotProvider?(tab.sessionId)
    var rows = 1
    var cols = 1
    var exitStatus: Int? = nil
    var mouseTracking = false
    var focusReporting = false
    var dirty = false
    var grid: SessionGridResponse? = nil

    if let snapshot = clientSnapshot {
      rows = max(snapshot.rows, 1)
      cols = max(snapshot.cols, 1)
      exitStatus = snapshot.exitStatus
      mouseTracking = snapshot.mouseTracking ?? false
      focusReporting = snapshot.focusReporting ?? false
      dirty = snapshot.dirty
      if includeGrid {
        grid = ControlGridProjection.sessionGridResponse(from: snapshot, maxCells: 2_000)
      }
    } else if let session = sessionObj, let snapshot = session.snapshot() {
      defer { laban_snapshot_destroy(snapshot) }
      rows = max(Int(snapshot.pointee.rows), 1)
      cols = max(Int(snapshot.pointee.cols), 1)
      if snapshot.pointee.status != 0 { exitStatus = Int(snapshot.pointee.exit_status) }
      mouseTracking = snapshot.pointee.mouse_tracking != 0
      focusReporting = snapshot.pointee.focus_reporting != 0
      dirty = snapshot.pointee.dirty != 0
      if includeGrid {
        grid = ControlGridProjection.sessionGridResponse(from: snapshot, maxCells: 2_000)
      }
    }
    if exitStatus == nil { exitStatus = metadata.exitStatus }

    var scrollbackLines = 0
    var viewportOffset = 0
    if let sessionObj, let viewportState = sessionObj.viewportState() {
      scrollbackLines = viewportState.scrollbackRows
      viewportOffset = viewportState.viewportOffset
    }

    let status =
      clientSnapshot?.lifecycleState.rawValue
      ?? (sessionObj != nil ? tab.status.debugString : "failed")
    return SessionResponse(
      id: tab.sessionId,
      tabId: tab.id,
      pid: clientInfo?.childPid,
      foregroundPid: clientInfo?.foregroundPid,
      daemonProcessPid: clientInfo?.daemonProcessPid,
      logicalSessionId: clientInfo?.logicalSessionId ?? tab.sessionId,
      incarnationId: clientInfo?.incarnationId,
      attachedClientCount: clientInfo?.attachedClientCount,
      leaseHolder: clientInfo?.leaseHolder,
      leaseId: clientInfo?.lease?.leaseId,
      leaseEpoch: clientInfo?.lease?.epoch,
      leaseExpiresAtMonoNs: clientInfo?.lease?.expiresAtMonoNs,
      transportMode: ctx.transportMode,
      status: status,
      exitStatus: exitStatus,
      rows: rows,
      cols: cols,
      cellWidth: ctx.cellWidth,
      cellHeight: ctx.cellHeight,
      scrollbackLines: scrollbackLines,
      viewportOffset: viewportOffset,
      title: metadata.displayTitle,
      displayTitle: metadata.displayTitle,
      titleSource: metadata.titleSource.rawValue,
      terminalTitle: metadata.terminalTitle,
      userTitle: metadata.userTitle,
      titleFrozen: metadata.titleFrozen,
      activityState: metadata.activityState.rawValue,
      lastActivityAt: tab.lastActivityAt,
      lastOutputAt: tab.lastOutputAt,
      unseenOutput: metadata.unseenOutput,
      bellAttention: metadata.bellAttention,
      workspace: metadata.workspace,
      process: metadata.process,
      agent: metadata.agent,
      mouseTracking: mouseTracking,
      focusReporting: focusReporting,
      dirty: dirty,
      grid: grid
    )
  }
}
