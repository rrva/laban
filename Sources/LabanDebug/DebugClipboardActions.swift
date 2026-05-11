import Foundation
import LabanCore
import LabanTerminalCore

struct DebugClipboardActions {
  private unowned let runtime: HeadlessDebugRuntime

  init(runtime: HeadlessDebugRuntime) {
    self.runtime = runtime
  }

  func setClipboardText(_ request: TextActionRequest) -> DebugResponse {
    guard let text = request.text else { return jsonError("setClipboardText requires text") }
    runtime.debugClipboard = text
    runtime.appendEvent(EventEntry(kind: "clipboard.set", text: text))
    return runtime.actionResult(ok: true)
  }

  func copy(_ request: SessionTargetActionRequest) -> DebugResponse {
    let frameBefore = runtime.currentFrame
    let targetTab =
      request.sessionId.flatMap { sessionId in
        runtime.model.tabs.first(where: { $0.sessionId == sessionId })
      } ?? runtime.model.activeTab
    guard let tab = targetTab, let session = runtime.model.session(forTab: tab.id) else {
      return jsonError("no session for copy")
    }
    guard let selection = runtime.selectionBySession[session.id] else {
      runtime.lastCopyText = ""
      runtime.appendEvent(EventEntry(kind: "clipboard.copied", text: ""))
      return runtime.actionResult(ok: true)
    }
    let text: String
    if let snapshot = session.snapshot() {
      defer { laban_snapshot_destroy(snapshot) }
      text = selection.selectedText(from: snapshot.pointee)
    } else {
      text = ""
    }
    runtime.lastCopyText = text
    runtime.debugClipboard = text
    runtime.appendInputEnvelope(
      InputEventEnvelope(
        inputId: UUID().uuidString,
        source: "debug",
        kind: "copy",
        route: "appCommand",
        frameBefore: frameBefore,
        tabId: tab.id,
        sessionId: session.id,
        command: "copy"
      ))
    runtime.appendEvent(EventEntry(kind: "clipboard.copied", text: text))
    return runtime.actionResult(ok: true)
  }

  func paste() -> DebugResponse {
    let frameBefore = runtime.currentFrame
    let activeTab = runtime.model.activeTab
    let pasteHardLimit = TerminalPaste.hardLimitBytes
    if runtime.debugClipboard.utf8.count > pasteHardLimit {
      return jsonError("clipboard exceeds paste limit (\(pasteHardLimit) bytes)")
    }
    let sanitized = TerminalPaste.sanitize(runtime.debugClipboard)
    var encodedBytes: [UInt8] = []
    if let tab = runtime.model.activeTab, let session = runtime.model.session(forTab: tab.id) {
      let result: Session.PasteWriteResult?
      if sanitized.isEmpty {
        result = nil
      } else {
        let sent = session.writePasteCapturingBytes(sanitized)
        result = sent.result
        encodedBytes = sent.bytes
      }
      runtime.lastPasteText = sanitized
      runtime.lastPasteUsedBracketedPaste = result?.bracketed
      runtime.lastPasteIgnoredNonText = sanitized != runtime.debugClipboard
      if !encodedBytes.isEmpty {
        runtime.appendTerminalLog(
          sessionId: session.id,
          direction: "input",
          bytes: encodedBytes
        )
      }
    }
    runtime.renderFrameUnlocked()
    runtime.appendInputEnvelope(
      InputEventEnvelope(
        inputId: UUID().uuidString,
        source: "debug",
        kind: "paste",
        route: "terminal",
        frameBefore: frameBefore,
        tabId: activeTab?.id,
        sessionId: activeTab?.sessionId,
        text: sanitized,
        command: "paste",
        encodedHex: encodedBytes.isEmpty
          ? nil
          : encodedBytes.map { String(format: "%02x", $0) }.joined(),
        encodedLength: encodedBytes.isEmpty ? nil : encodedBytes.count
      ))
    runtime.appendEvent(EventEntry(kind: "clipboard.pasted", text: sanitized))
    return runtime.actionResult(ok: true)
  }
}
