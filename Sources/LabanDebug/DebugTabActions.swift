import LabanCore

struct DebugTabActions {
  private unowned let runtime: HeadlessDebugRuntime

  init(runtime: HeadlessDebugRuntime) {
    self.runtime = runtime
  }

  func newTab() -> DebugResponse {
    do { try runtime.model.createTab() } catch {
      return jsonError("createTab failed: \(error)")
    }
    runtime.renderFrameUnlocked()
    runtime.appendEvent(EventEntry(kind: "tab.created", tabId: runtime.model.activeTab?.id))
    return runtime.actionResult(ok: true)
  }

  func closeTab(_ request: TabTargetActionRequest) -> DebugResponse {
    guard let tabId = request.tabId else { return jsonError("closeTab requires tabId") }
    let closingSessionId = runtime.model.tabs.first(where: { $0.id == tabId })?.sessionId
    do { try runtime.model.closeTab(tabId) } catch {
      return jsonError("closeTab failed: \(error)")
    }
    if let closingSessionId {
      runtime.selectionBySession.removeValue(forKey: closingSessionId)
    }
    runtime.renderFrameUnlocked()
    runtime.appendEvent(EventEntry(kind: "tab.closed", tabId: tabId))
    return runtime.actionResult(ok: true)
  }

  func selectTab(_ request: TabTargetActionRequest) -> DebugResponse {
    guard let tabId = request.tabId else { return jsonError("selectTab requires tabId") }
    runtime.model.selectTab(tabId)
    runtime.renderFrameUnlocked()
    runtime.appendEvent(EventEntry(kind: "tab.selected", tabId: tabId))
    return runtime.actionResult(ok: true)
  }

  func setTabTitle(_ request: TabTitleActionRequest) -> DebugResponse {
    let targetTabId = request.tabId ?? runtime.model.activeTab?.id
    guard let tabId = targetTabId else { return jsonError("setTabTitle requires an active tab") }
    guard let title = request.title ?? request.text else {
      return jsonError("setTabTitle requires title")
    }
    do { try runtime.model.renameTab(tabId, title: title) } catch {
      return jsonError("setTabTitle failed: \(error)")
    }
    runtime.renderFrameUnlocked()
    runtime.appendEvent(EventEntry(kind: "tab.title.set", tabId: tabId, text: title))
    return runtime.actionResult(ok: true)
  }

  func freezeTabTitle(_ request: TabTitleActionRequest) -> DebugResponse {
    let targetTabId = request.tabId ?? runtime.model.activeTab?.id
    guard let tabId = targetTabId else {
      return jsonError("freezeTabTitle requires an active tab")
    }
    do { try runtime.model.freezeTitle(forTab: tabId, frozen: request.frozen ?? true) } catch {
      return jsonError("freezeTabTitle failed: \(error)")
    }
    runtime.renderFrameUnlocked()
    runtime.appendEvent(EventEntry(kind: "tab.title.frozen", tabId: tabId))
    return runtime.actionResult(ok: true)
  }

  func clearTabTitle(_ request: TabTargetActionRequest) -> DebugResponse {
    let targetTabId = request.tabId ?? runtime.model.activeTab?.id
    guard let tabId = targetTabId else {
      return jsonError("clearTabTitle requires an active tab")
    }
    do { try runtime.model.clearUserTitle(forTab: tabId) } catch {
      return jsonError("clearTabTitle failed: \(error)")
    }
    runtime.renderFrameUnlocked()
    runtime.appendEvent(EventEntry(kind: "tab.title.cleared", tabId: tabId))
    return runtime.actionResult(ok: true)
  }

  func setTabMetadata(_ request: TabMetadataActionRequest) -> DebugResponse {
    let targetTabId = request.tabId ?? runtime.model.activeTab?.id
    guard let tabId = targetTabId else {
      return jsonError("setTabMetadata requires an active tab")
    }
    let workspace =
      request.cwd != nil || request.repoName != nil || request.repoRoot != nil
        || request.worktreeName != nil || request.branch != nil || request.isDirty != nil
      ? TabWorkspaceMetadata(
        cwd: request.cwd,
        repoName: request.repoName,
        repoRoot: request.repoRoot,
        worktreeName: request.worktreeName,
        branch: request.branch,
        isDirty: request.isDirty ?? false
      )
      : nil
    let process =
      request.foregroundProcess != nil || request.foregroundCommand != nil || request.pid != nil
      ? TabProcessMetadata(
        foregroundProcess: request.foregroundProcess,
        foregroundCommand: request.foregroundCommand,
        pid: request.pid
      )
      : nil
    let agent =
      request.agentName != nil || request.sessionName != nil || request.agentSessionId != nil
        || request.taskLabel != nil || request.model != nil || request.contextPercent != nil
        || request.awaitingInput != nil
      ? TabAgentMetadata(
        agentName: request.agentName,
        sessionName: request.sessionName,
        sessionId: request.agentSessionId,
        taskLabel: request.taskLabel,
        model: request.model,
        contextPercent: request.contextPercent,
        awaitingInput: request.awaitingInput ?? false
      )
      : nil
    let activityState = request.activityState.flatMap(TabActivityState.init(rawValue:))
    do {
      try runtime.model.updateTitleMetadata(
        forTab: tabId,
        workspace: workspace,
        process: process,
        agent: agent,
        activityState: activityState,
        unseenOutput: request.unseenOutput,
        exitStatus: request.exitStatus
      )
    } catch {
      return jsonError("setTabMetadata failed: \(error)")
    }
    runtime.renderFrameUnlocked()
    runtime.appendEvent(EventEntry(kind: "tab.metadata.set", tabId: tabId))
    return runtime.actionResult(ok: true)
  }
}
