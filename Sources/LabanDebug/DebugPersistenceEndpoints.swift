import Foundation
import LabanCore

/// Persistence inspection + control surface exposed when the
/// headless runtime was launched with `--persistence-dir=PATH`. The
/// real `MainWindowController` ties these layers together through
/// `applicationWillTerminate` and a fresh process launch; the debug
/// harness routes them through HTTP so an agent can drive
/// quit-and-relaunch cycles without actually quitting the host
/// process.
extension HeadlessDebugRuntime {

  /// Synchronously drain the persistence debounce + transcript
  /// writers. Equivalent to what `AppDelegate.applicationWillTerminate`
  /// does. No-op when persistence is not wired.
  public func persistenceFlush() -> DebugResponse {
    withRuntimeLock {
      agentObserverHost?.observeNowAll()
      persistenceCoordinator?.flushSync()
      return responseJSON(["ok": true])
    }
  }

  /// Snapshot the persistence directory state — file existence,
  /// sizes, the workspace.json contents. Lets callers assert
  /// "M0 persisted what I expect" without parsing the raw JSON
  /// blob themselves.
  public func persistenceState() -> DebugResponse {
    withRuntimeLock {
      guard let store = persistenceStore else {
        return responseJSON(["enabled": false])
      }
      let fm = FileManager.default
      let workspaceExists = fm.fileExists(atPath: store.workspaceURL.path)
      let previousExists = fm.fileExists(atPath: store.previousURL.path)
      var transcripts: [[String: Any]] = []
      if let entries = try? fm.contentsOfDirectory(
        at: store.transcriptsURL, includingPropertiesForKeys: [.fileSizeKey])
      {
        for url in entries where url.pathExtension == "bin" {
          let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
          transcripts.append([
            "tabId": url.deletingPathExtension().lastPathComponent,
            "bytes": size,
          ])
        }
      }
      var mirrors: [[String: Any]] = []
      if let entries = try? fm.contentsOfDirectory(
        at: store.agentMirrorURL, includingPropertiesForKeys: [.fileSizeKey])
      {
        for url in entries where url.pathExtension == "jsonl" {
          let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
          mirrors.append([
            "tabId": url.deletingPathExtension().lastPathComponent,
            "bytes": size,
          ])
        }
      }
      var payload: [String: Any] = [
        "enabled": true,
        "baseURL": store.baseURL.path,
        "workspaceExists": workspaceExists,
        "previousExists": previousExists,
        "transcripts": transcripts,
        "agentMirrors": mirrors,
      ]
      if workspaceExists,
        let data = try? Data(contentsOf: store.workspaceURL),
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      {
        payload["workspace"] = parsed
      }
      return responseJSON(payload)
    }
  }

  /// Simulate a quit-then-relaunch cycle without leaving the host
  /// process. Flushes the persistence coordinator, closes every
  /// session, then rebuilds the AppModel + persistence wiring from
  /// the just-written `workspace.json`. The agent can use this to
  /// run multiple restore cycles inside one debug-server session.
  public func persistenceRelaunch() -> DebugResponse {
    withRuntimeLock {
      guard persistenceCoordinator != nil else {
        return jsonError("persistence is not enabled (use --persistence-dir)", status: 400)
      }
      agentObserverHost?.observeNowAll()
      persistenceCoordinator?.flushSync()
      model.closeAllSessions()
      let loaded = persistenceCoordinator?.load()
      prepareAgentRestorePickerUnlocked(for: loaded)
      if let loaded {
        model.replaceTabs(from: loaded)
        if terminalBackend != .laband {
          applyRestoreLaunchPlansUnlocked(for: loaded)
        }
      }
      renderFrameUnlocked()
      return responseJSON([
        "ok": true,
        "restoredTabCount": model.tabs.count,
        "activeTabId": model.activeTab?.id ?? "",
      ])
    }
  }

  public func persistenceRestorePicker() -> DebugResponse {
    withRuntimeLock {
      jsonEncode(
        AgentRestorePickerState(
          candidates: pendingAgentRestoreCandidatesByTab.values.sorted {
            $0.lastActiveAt > $1.lastActiveAt
          }))
    }
  }

  public func persistenceRestoreSelection(_ data: Data) -> DebugResponse {
    withRuntimeLock {
      guard let request = try? JSONDecoder().decode(AgentRestoreSelectionRequest.self, from: data)
      else {
        return jsonError("invalid restore selection request", status: 400)
      }
      guard let client = terminalSessionClient else {
        return jsonError("terminal client is not configured", status: 400)
      }
      let requested = request.tabIds ?? request.selectedTabIds ?? []
      var restored: [AgentRestoreSelectionResult] = []
      var skipped: [AgentRestoreSelectionResult] = []

      for tabId in requested {
        guard let candidate = pendingAgentRestoreCandidatesByTab[tabId] else {
          skipped.append(
            AgentRestoreSelectionResult(tabId: tabId, ok: false, message: "no pending restore"))
          continue
        }
        guard let tab = model.tabs.first(where: { $0.id == tabId }) else {
          pendingAgentRestoreCandidatesByTab.removeValue(forKey: tabId)
          skipped.append(
            AgentRestoreSelectionResult(tabId: tabId, ok: false, message: "tab is not restored"))
          continue
        }

        let injection = RestoreShellInjection(command: candidate.command)
        let size = model.terminalSize
        do {
          let info = try client.createSession(
            TerminalSessionLaunchRequest(
              executable: injection.shellPath,
              argv: injection.argv,
              cwd: candidate.launchCwd,
              environmentPatch: candidateEnvironmentPatch(
                candidate,
                extra: request.environmentPatch ?? [:]),
              rows: Int(size.rows),
              cols: Int(size.cols),
              logicalSessionId: tabId))
          terminalClientSessionInfoById[tab.sessionId] = info
          attachSnapshotRingIfAvailable(client: client, localSessionId: tab.sessionId)
          pendingAgentRestoreCandidatesByTab.removeValue(forKey: tabId)
          appendEvent(EventEntry(kind: "agent.restore.selected", tabId: tabId))
          restored.append(
            AgentRestoreSelectionResult(
              tabId: tabId,
              ok: true,
              message: "restore launched",
              logicalSessionId: info.logicalSessionId,
              incarnationId: info.incarnationId))
        } catch {
          appendError(
            kind: "agent.restore.launch.failed",
            message: String(describing: error),
            tabId: tabId)
          skipped.append(
            AgentRestoreSelectionResult(tabId: tabId, ok: false, message: "\(error)"))
        }
      }

      renderFrameUnlocked()
      return jsonEncode(
        AgentRestoreSelectionResponse(
          ok: skipped.isEmpty,
          restored: restored,
          skipped: skipped,
          picker: AgentRestorePickerState(
            candidates: pendingAgentRestoreCandidatesByTab.values.sorted {
              $0.lastActiveAt > $1.lastActiveAt
            })))
    }
  }

  func applyRestoreLaunchPlansUnlocked(for state: WorkspaceState) {
    Self.applyRestoreLaunchPlans(for: state, model: model)
  }

  static func applyRestoreLaunchPlans(for state: WorkspaceState, model: AppModel) {
    // `.executeNow` is injected at spawn (the restored shell launches as
    // `$SHELL -l -i -c '<resume>; exec $SHELL -l -i'`), so this post-spawn pass
    // only types the `.prefillPrompt` case. Writing `.executeNow` here
    // too would run the resume command a second time.
    guard let window = state.windows.first else { return }
    let activityChecker = ProcessTreeRestoreSessionActivityChecker()
    for tabState in window.tabs {
      let instruction = RestoreLaunchPlanner.instruction(
        for: tabState,
        activityChecker: activityChecker)
      guard case .prefillPrompt(let command) = instruction else { continue }
      guard let session = model.session(forTab: tabState.id) else { continue }
      _ = session.write(Array(command.utf8))
    }
  }
}

private func responseJSON(_ payload: [String: Any]) -> DebugResponse {
  let body =
    (try? JSONSerialization.data(
      withJSONObject: payload, options: [.sortedKeys, .prettyPrinted]))
    ?? Data(#"{"error":"json encoding failed"}"#.utf8)
  return DebugResponse(status: 200, body: body)
}

private struct AgentRestoreSelectionRequest: Decodable {
  var tabIds: [String]?
  var selectedTabIds: [String]?
  var environmentPatch: [String: String]?
}

private struct AgentRestoreSelectionResult: Encodable {
  var tabId: String
  var ok: Bool
  var message: String
  var logicalSessionId: String?
  var incarnationId: String?

  init(
    tabId: String,
    ok: Bool,
    message: String,
    logicalSessionId: String? = nil,
    incarnationId: String? = nil
  ) {
    self.tabId = tabId
    self.ok = ok
    self.message = message
    self.logicalSessionId = logicalSessionId
    self.incarnationId = incarnationId
  }
}

private struct AgentRestoreSelectionResponse: Encodable {
  var ok: Bool
  var restored: [AgentRestoreSelectionResult]
  var skipped: [AgentRestoreSelectionResult]
  var picker: AgentRestorePickerState
}

private func candidateEnvironmentPatch(
  _ candidate: AgentRestoreCandidate,
  extra: [String: String] = [:]
) -> [String: String] {
  _ = candidate
  let env = ProcessInfo.processInfo.environment
  var patch: [String: String] = [:]
  for key in ["PATH", "SHELL", "TERM", "LANG", "LC_ALL", "LC_CTYPE"] {
    if let value = env[key], !value.isEmpty {
      patch[key] = value
    }
  }
  for (key, value) in extra where !value.isEmpty {
    patch[key] = value
  }
  return patch
}
