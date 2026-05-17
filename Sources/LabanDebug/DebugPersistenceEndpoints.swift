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
      persistenceCoordinator?.flushSync()
      model.closeAllSessions()
      let loaded = persistenceCoordinator?.load()
      if let loaded {
        model.replaceTabs(from: loaded)
      }
      renderFrameUnlocked()
      return responseJSON([
        "ok": true,
        "restoredTabCount": model.tabs.count,
        "activeTabId": model.activeTab?.id ?? "",
      ])
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
