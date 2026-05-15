import Foundation
import LabanCore

struct DebugDropActions {
  private unowned let runtime: HeadlessDebugRuntime

  init(runtime: HeadlessDebugRuntime) {
    self.runtime = runtime
  }

  func dropFiles(_ request: DropFilesActionRequest) -> DebugResponse {
    let frameBefore = runtime.currentFrame
    guard let paths = request.paths, !paths.isEmpty else {
      return jsonError("dropFiles requires paths")
    }
    let text = TerminalDropText.format(paths: paths)
    guard !text.isEmpty else {
      return jsonError("dropFiles requires at least one non-empty path")
    }
    guard text.utf8.count <= TerminalPaste.hardLimitBytes else {
      return jsonError(
        "dropFiles payload exceeds paste limit (\(TerminalPaste.hardLimitBytes) bytes)")
    }
    guard TerminalPaste.sanitize(text) == text else {
      return jsonError("dropFiles paths contain unsupported control characters")
    }
    guard let tab = runtime.model.activeTab,
      let session = runtime.model.session(forTab: tab.id)
    else {
      return jsonError("no session for dropFiles")
    }

    let deltaRows = session.scrollViewportToActiveBottom()
    appendInputFollowBottom(deltaRows: deltaRows, frameBefore: frameBefore, tab: tab)
    let sent = session.writePasteCapturingBytes(text)
    if !sent.bytes.isEmpty {
      runtime.appendTerminalLog(sessionId: session.id, direction: "input", bytes: sent.bytes)
    }
    runtime.appendInputEnvelope(
      InputEventEnvelope(
        inputId: UUID().uuidString,
        source: "debug",
        kind: "drop",
        route: "terminal",
        frameBefore: frameBefore,
        tabId: tab.id,
        sessionId: session.id,
        text: text,
        command: "dropFiles",
        encodedHex: sent.bytes.isEmpty
          ? nil
          : sent.bytes.map { String(format: "%02x", $0) }.joined(),
        encodedLength: sent.bytes.isEmpty ? nil : sent.bytes.count
      ))
    runtime.renderFrameUnlocked()
    runtime.appendEvent(
      EventEntry(kind: "drop.files", tabId: tab.id, sessionId: session.id, text: text)
    )
    return runtime.actionResult(ok: true)
  }

  private func appendInputFollowBottom(deltaRows: Int, frameBefore: Int, tab: Tab) {
    guard deltaRows != 0 else { return }
    runtime.appendInputEnvelope(
      InputEventEnvelope(
        inputId: UUID().uuidString,
        source: "debug",
        kind: "scroll",
        route: "terminal",
        frameBefore: frameBefore,
        tabId: tab.id,
        sessionId: tab.sessionId,
        command: "inputFollowBottom",
        deltaRows: deltaRows
      ))
  }
}
