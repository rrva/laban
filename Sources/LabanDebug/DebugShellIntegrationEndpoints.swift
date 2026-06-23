import Foundation
import LabanCore

extension HeadlessDebugRuntime {
  /// `GET /debug/shell-integration/state` — return the OSC 133 phase and
  /// last exit code for the active session, or for the session named by a
  /// `sessionID` / `sessionId` query parameter. Reads the session's live
  /// state directly, so it is independent of event-delivery timing.
  public func shellIntegrationState(query: [String: String]) -> DebugResponse {
    withRuntimeLock {
      let requested = query["sessionID"] ?? query["sessionId"]
      let sessionId: Session.ID?
      if let requested {
        guard model.session(forSessionID: requested) != nil else {
          return jsonError("session not found: \(requested)", status: 404)
        }
        sessionId = requested
      } else {
        sessionId = model.activeTab?.sessionId
      }
      guard let sessionId, let session = model.session(forSessionID: sessionId) else {
        return jsonError("session not found", status: 404)
      }
      let state = session.shellIntegrationState()
      return jsonEncode(
        ShellIntegrationStateResponse(
          sessionId: sessionId,
          phase: state.phase.rawValue,
          lastExitCode: state.lastExitCode
        ))
    }
  }

  /// Record one OSC 133 transition on the event stream so
  /// `GET /debug/events` shows prompt/command/exit changes. Wired to
  /// `AppModel.onShellIntegrationChange`, which fires on the main queue.
  func recordShellIntegrationEvent(tabId: String, state: ShellIntegrationState) {
    let sessionId = model.tabs.first { $0.id == tabId }?.sessionId
    let exitText = state.lastExitCode.map(String.init)
    withRuntimeLock {
      appendEvent(
        EventEntry(
          kind: "shell.integration",
          tabId: tabId,
          sessionId: sessionId,
          text: exitText,
          action: state.phase.rawValue
        ))
    }
  }

  /// Record one OSC 9 desktop notification on the event stream so
  /// `GET /debug/events` shows agent turn-complete / approval notifications.
  /// Wired through the unified attention notification path.
  /// This is the headless parity for the AppKit native-notification presenter.
  func recordAgentNotificationEvent(tabId: String, text: String) {
    let sessionId = model.tabs.first { $0.id == tabId }?.sessionId
    withRuntimeLock {
      appendEvent(
        EventEntry(
          kind: "agent.notification",
          tabId: tabId,
          sessionId: sessionId,
          text: text
        ))
    }
  }

  /// Record an OSC 52 clipboard *write* on the event stream and mirror it into
  /// the debug clipboard, so `GET /debug/events` and `GET /debug/clipboard`
  /// reflect a program copying via `ESC ] 52 ; c ; <base64> ST`. Wired to
  /// `AppModel.onClipboardWrite` — the headless parity for the AppKit
  /// NSPasteboard writer.
  func recordClipboardOSC52Write(tabId: String, data: Data) {
    let text = String(decoding: data, as: UTF8.self)
    let sessionId = model.tabs.first { $0.id == tabId }?.sessionId
    withRuntimeLock {
      debugClipboard = text
      appendEvent(
        EventEntry(
          kind: "clipboard.osc52Write",
          tabId: tabId,
          sessionId: sessionId,
          text: text
        ))
    }
  }

  /// Record an OSC 7 working-directory report on the event stream so
  /// `GET /debug/events` shows a shell's `cd`. Wired to
  /// `AppModel.onWorkingDirectoryChange`; the headless parity for the cwd the
  /// metadata sync also adopts from the same OSC 7 report.
  func recordWorkingDirectoryEvent(tabId: String, cwd: String) {
    let sessionId = model.tabs.first { $0.id == tabId }?.sessionId
    withRuntimeLock {
      appendEvent(
        EventEntry(
          kind: "cwd.osc7",
          tabId: tabId,
          sessionId: sessionId,
          text: cwd
        ))
    }
  }
}
