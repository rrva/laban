import Foundation
import LabanCore
import LabanRenderer
import LabanTerminalCore

extension HeadlessDebugRuntime {
  public func state() -> DebugResponse {
    withRuntimeLock {
      stateUnlocked()
    }
  }

  func stateUnlocked() -> DebugResponse {
    syncSessionMetadataUnlocked()
    let tabs = model.tabs.enumerated().map { index, tab -> TabResponse in
      tabResponse(for: tab, index: index)
    }
    let activeTab = model.activeTab
    return jsonEncode(
      StateResponse(
        mode: mode,
        frame: currentFrame,
        window: WindowResponse(width: windowWidth, height: windowHeight, focused: true),
        tabs: tabs,
        activeTabId: activeTab?.id,
        activeSessionId: activeTab?.sessionId,
        findStateBySession: findStateResponsesUnlocked(),
        cursorSettings: cursorSettingsResponseUnlocked(activeTab: activeTab),
        emojiRendering: emojiRenderingSettingsResponse(),
        attentionNotifications: model.recentAttentionNotificationDecisions.map(
          Self.attentionNotificationDecisionResponse)
      ))
  }

  public func accessibility() -> DebugResponse {
    withRuntimeLock {
      syncSessionMetadataUnlocked()
      refreshTerminalClientSessionInfoUnlocked()
      return jsonEncode(
        AccessibilityResponse(
          isElement: true,
          role: "AXTextArea",
          label: "Terminal",
          value: accessibilityValueUnlocked(),
          focusRingType: "none",
          display: accessibilityDisplayFlags))
    }
  }

  /// Effective DEC private mode state for the active session, read from a fresh
  /// in-process snapshot. Reports the mode-2027 (grapheme cluster) handshake
  /// result plus the sibling per-snapshot mode booleans. Defaults to all-false
  /// when the active session has no in-process snapshot (e.g. remote transport).
  public func terminalModes() -> DebugResponse {
    withRuntimeLock {
      syncSessionMetadataUnlocked()
      var graphemeCluster2027 = false
      var synchronizedOutput = false
      var focusReporting = false
      var mouseTracking = false
      if let activeTab = model.activeTab,
        let session = model.session(forTab: activeTab.id),
        let snapshot = session.snapshot()
      {
        defer { laban_snapshot_destroy(snapshot) }
        graphemeCluster2027 = snapshot.pointee.grapheme_cluster_2027 != 0
        synchronizedOutput = snapshot.pointee.synchronized_output != 0
        focusReporting = snapshot.pointee.focus_reporting != 0
        mouseTracking = snapshot.pointee.mouse_tracking != 0
      }
      return jsonEncode(
        TerminalModesResponse(
          graphemeCluster2027: graphemeCluster2027,
          synchronizedOutput: synchronizedOutput,
          focusReporting: focusReporting,
          mouseTracking: mouseTracking))
    }
  }

  /// User cursor preferences plus the active session's DECSCUSR / mode-12
  /// override flags from a fresh snapshot. Override flags are nil when the
  /// active session has no in-process snapshot (remote transport).
  private func cursorSettingsResponseUnlocked(activeTab: Tab?) -> CursorSettingsResponse {
    var styleOverridden: Bool?
    var blinkOverridden: Bool?
    if let activeTab,
      let session = model.session(forTab: activeTab.id),
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

  func emojiRenderingSettingsResponse() -> EmojiRenderingSettingsResponse {
    let mode = EmojiRenderingSettings.current().rawValue
    return EmojiRenderingSettingsResponse(mode: mode, effectiveMode: mode)
  }

  static func attentionNotificationDecisionResponse(
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

  private func accessibilityValueUnlocked() -> String {
    guard let activeTab = model.activeTab else { return "" }
    if let snapshot = terminalSessionClient == nil
      ? nil
      : terminalClientSnapshotUnlocked(sessionId: activeTab.sessionId)
    {
      return snapshot.visibleText
    }
    guard let session = model.session(forTab: activeTab.id),
      let snapshot = session.snapshot()
    else { return "" }
    defer { laban_snapshot_destroy(snapshot) }
    return TerminalSnapshotText.visibleText(
      from: UnsafePointer(snapshot),
      mode: .trimmedNonEmptyRows)
  }

  public func sessions() -> DebugResponse {
    withRuntimeLock {
      syncSessionMetadataUnlocked()
      refreshTerminalClientSessionInfoUnlocked()

      let list = model.tabs.enumerated().map { index, tab in
        sessionResponse(for: tab, index: index, includeGrid: false)
      }

      return jsonEncode(SessionsResponse(sessions: list))
    }
  }

  func findStateResponsesUnlocked() -> [String: FindStateResponse] {
    model.allFindStates.mapValues { Self.findStateResponse($0) }
  }

  static func findStateResponse(_ state: TerminalFindState) -> FindStateResponse {
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

  public func session(id: String, query: [String: String]) -> DebugResponse {
    withRuntimeLock {
      syncSessionMetadataUnlocked()
      refreshTerminalClientSessionInfoUnlocked()

      guard let match = model.tabs.enumerated().first(where: { $0.element.sessionId == id }) else {
        return jsonError("session not found: \(id)", status: 404)
      }
      let includeGrid = query["includeGrid"] == "true"
      return jsonEncode(
        sessionResponse(for: match.element, index: match.offset, includeGrid: includeGrid))
    }
  }

  func syncSessionMetadataUnlocked() {
    _ = surfaceController.syncSessions(
      captureFrame: currentFrame + 1,
      polling: .pollAllSessions,
      markInactiveDirtyRendered: false,
      noteOutputOnDirty: false)
  }

  private func tabResponse(for tab: Tab, index: Int) -> TabResponse {
    let metadata = tab.titleMetadata
    let status = model.session(forTab: tab.id) != nil ? tab.status.debugString : "failed"
    return TabResponse(
      id: tab.id,
      index: index,
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
      attention: TabAttentionClassifier.classify(metadata, isActive: tab.isActive).rawValue,
      exitStatus: metadata.exitStatus,
      shellPhase: metadata.shellPhase.rawValue,
      lastCommandExitCode: metadata.lastCommandExitCode,
      workspace: metadata.workspace,
      process: metadata.process,
      agent: metadata.agent,
      progress: metadata.progress,
      active: tab.isActive,
      status: status,
      sessionId: tab.sessionId
    )
  }

  private func sessionResponse(for tab: Tab, index _: Int, includeGrid: Bool) -> SessionResponse {
    let metadata = tab.titleMetadata
    let sessionObj = model.session(forTab: tab.id)
    let clientInfo = terminalClientSessionInfoById[tab.sessionId]
    let clientSnapshot =
      terminalSessionClient == nil ? nil : terminalClientSnapshotUnlocked(sessionId: tab.sessionId)
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
        grid = sessionGridResponse(from: snapshot, maxCells: 2_000)
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
        grid = sessionGridResponse(from: snapshot, maxCells: 2_000)
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
    let transportMode = terminalSessionClient?.transportMode ?? terminalBackend.rawValue
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
      transportMode: transportMode,
      status: status,
      exitStatus: exitStatus,
      rows: rows,
      cols: cols,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
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

  private func sessionGridResponse(
    from snapshot: LabandSnapshotResponse,
    maxCells: Int
  ) -> SessionGridResponse {
    var result: [SessionGridCellResponse] = []
    result.reserveCapacity(min(snapshot.cells.count, maxCells))
    var truncated = false
    for cell in snapshot.cells where !cell.text.isEmpty {
      if result.count >= maxCells {
        truncated = true
        break
      }
      result.append(
        SessionGridCellResponse(
          row: cell.row,
          col: cell.col,
          text: cell.text,
          foreground: DebugFrameCommandSerializer.rgbaArray(cell.foregroundRGBA),
          background: DebugFrameCommandSerializer.rgbaArray(cell.backgroundRGBA),
          attributes: TextAttributes(rawValue: cell.flags).intersection(.renderableMask).names,
          wide: "narrow",
          hyperlink: nil
        ))
    }
    return SessionGridResponse(
      rows: snapshot.rows,
      cols: snapshot.cols,
      cells: result,
      truncated: truncated
    )
  }

  private func sessionGridResponse(
    from snapshotPointer: UnsafePointer<LabanSnapshot>,
    maxCells: Int
  ) -> SessionGridResponse {
    let snapshot = snapshotPointer.pointee
    let rows = max(Int(snapshot.rows), 1)
    let cols = max(Int(snapshot.cols), 1)
    guard let cells = snapshot.cells, let storage = snapshot.utf8_storage else {
      return SessionGridResponse(rows: rows, cols: cols, cells: [], truncated: false)
    }

    let links = snapshotHyperlinks(snapshot)
    var result: [SessionGridCellResponse] = []
    result.reserveCapacity(min(Int(snapshot.cell_count), maxCells))
    var truncated = false

    for row in 0..<rows {
      for col in 0..<cols {
        let idx = row * cols + col
        guard idx < Int(snapshot.cell_count) else { continue }
        let cell = cells[idx]
        guard cell.utf8_length > 0 else { continue }

        let ptr = UnsafeRawPointer(storage).advanced(by: Int(cell.utf8_offset))
        let buffer = UnsafeBufferPointer<UInt8>(
          start: ptr.assumingMemoryBound(to: UInt8.self),
          count: Int(cell.utf8_length)
        )
        guard let text = String(bytes: buffer, encoding: .utf8), !text.isEmpty else { continue }

        if result.count >= maxCells {
          truncated = true
          break
        }

        let hyperlink: String? = {
          let id = Int(cell.hyperlink_id)
          guard id > 0, id <= links.count else { return nil }
          return links[id - 1]
        }()

        result.append(
          SessionGridCellResponse(
            row: row,
            col: col,
            text: text,
            foreground: DebugFrameCommandSerializer.rgbaArray(cell.foreground_rgba),
            background: DebugFrameCommandSerializer.rgbaArray(cell.background_rgba),
            attributes: TextAttributes(rawValue: cell.flags).intersection(.renderableMask).names,
            wide: wideName(cell.wide),
            hyperlink: hyperlink
          ))
      }
      if truncated { break }
    }

    return SessionGridResponse(rows: rows, cols: cols, cells: result, truncated: truncated)
  }

  private func snapshotHyperlinks(_ snapshot: LabanSnapshot) -> [String] {
    let count = Int(snapshot.hyperlink_count)
    guard count > 0, let table = snapshot.hyperlink_uris else { return [] }
    var result: [String] = []
    result.reserveCapacity(count)
    for idx in 0..<count {
      result.append(table[idx].map { String(cString: $0) } ?? "")
    }
    return result
  }

  private func wideName(_ wide: UInt8) -> String {
    switch Int(wide) {
    case Int(LABAN_CELL_WIDE_WIDE): return "wide"
    case Int(LABAN_CELL_WIDE_SPACER_TAIL): return "spacerTail"
    case Int(LABAN_CELL_WIDE_SPACER_HEAD): return "spacerHead"
    default: return "narrow"
    }
  }
}
