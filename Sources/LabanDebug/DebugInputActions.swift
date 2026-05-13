import Foundation
import LabanCore
import LabanTerminalCore

struct DebugInputActions {
  private unowned let runtime: HeadlessDebugRuntime

  init(runtime: HeadlessDebugRuntime) {
    self.runtime = runtime
  }

  func typeText(_ request: TextActionRequest) -> DebugResponse {
    guard let text = request.text else { return jsonError("typeText requires text") }
    let frameBefore = runtime.currentFrame
    let activeTab = runtime.model.activeTab
    let bytes = Array(text.utf8)
    if let tab = runtime.model.activeTab, let session = runtime.model.session(forTab: tab.id) {
      let deltaRows = session.scrollViewportToActiveBottom()
      appendInputFollowBottom(deltaRows: deltaRows, frameBefore: frameBefore, tab: tab)
      session.write(bytes)
      runtime.model.noteOutput(forTab: tab.id)
      runtime.appendTerminalLog(sessionId: session.id, direction: "input", bytes: bytes)
    }
    runtime.appendInputEnvelope(
      InputEventEnvelope(
        inputId: UUID().uuidString,
        source: "debug",
        kind: "text",
        route: "terminal",
        frameBefore: frameBefore,
        tabId: activeTab?.id,
        sessionId: activeTab?.sessionId,
        text: text,
        encodedHex: bytes.map { String(format: "%02x", $0) }.joined(),
        encodedLength: bytes.count
      ))
    runtime.renderFrameUnlocked()
    runtime.appendEvent(EventEntry(kind: "input.typed", text: text))
    return runtime.actionResult(ok: true)
  }

  func feedOutput(_ request: TextActionRequest) -> DebugResponse {
    guard let text = request.text else { return jsonError("feedOutput requires text") }
    if let tab = runtime.model.activeTab, let session = runtime.model.session(forTab: tab.id) {
      let bytes = Array(text.utf8)
      session.feedOutput(bytes)
      runtime.model.noteOutput(forTab: tab.id)
      runtime.appendTerminalLog(sessionId: session.id, direction: "output", bytes: bytes)
    }
    runtime.renderFrameUnlocked()
    runtime.appendEvent(EventEntry(kind: "output.fed", text: text))
    return runtime.actionResult(ok: true)
  }

  func key(_ request: DebugKeyActionRequest) -> DebugResponse {
    guard let keyName = request.key,
      let key = DebugRuntimeKeyInput.key(fromName: keyName)
    else {
      return jsonError("key action requires a valid key name")
    }
    let action = DebugRuntimeKeyInput.action(from: request.type)
    let mods = DebugRuntimeKeyInput.modifiers(from: request.modifiers)
    let consumed = DebugRuntimeKeyInput.modifiers(from: request.consumedModifiers)
    let frameBefore = runtime.currentFrame
    let activeTab = runtime.model.activeTab
    let inputId = UUID().uuidString

    if mods.contains(.command) {
      let (route, commandStr) = commandRoute(for: key)
      runtime.appendInputEnvelope(
        InputEventEnvelope(
          inputId: inputId, seq: 0,
          source: "debug", kind: "key", route: route,
          frameBefore: frameBefore,
          tabId: activeTab?.id, sessionId: activeTab?.sessionId,
          key: keyName, modifiers: request.modifiers, command: commandStr
        ))
      runtime.appendEvent(EventEntry(kind: "input.key", text: keyName, action: "key"))
      if route == "appCommand" {
        executeCommandKey(key)
      }
      return runtime.actionResult(ok: true)
    }

    var unshiftedCodepoint: UInt32 = 0
    if let unshifted = request.unshifted, let scalar = unshifted.unicodeScalars.first {
      unshiftedCodepoint = scalar.value
    }
    let keyEvent = KeyEvent(
      action: action,
      key: key,
      modifiers: mods,
      consumedModifiers: consumed,
      unshiftedCodepoint: unshiftedCodepoint,
      text: request.text
    )
    var encodedHex: String? = nil
    var encodedLength: Int? = nil
    if let tab = activeTab, let session = runtime.model.session(forTab: tab.id) {
      if action != .release {
        let deltaRows = session.scrollViewportToActiveBottom()
        appendInputFollowBottom(deltaRows: deltaRows, frameBefore: frameBefore, tab: tab)
      }
      let sent = session.sendKeyCapturingBytes(keyEvent)
      if sent.result == 0, !sent.bytes.isEmpty {
        encodedHex = sent.bytes.map { String(format: "%02x", $0) }.joined()
        encodedLength = sent.bytes.count
        runtime.appendTerminalLog(sessionId: session.id, direction: "input", bytes: sent.bytes)
      }
    }
    runtime.appendInputEnvelope(
      InputEventEnvelope(
        inputId: inputId, seq: 0,
        source: "debug", kind: "key", route: "terminal",
        frameBefore: frameBefore,
        tabId: activeTab?.id, sessionId: activeTab?.sessionId,
        key: keyName, text: request.text,
        modifiers: request.modifiers, consumedModifiers: request.consumedModifiers,
        encodedHex: encodedHex, encodedLength: encodedLength
      ))
    runtime.renderFrameUnlocked()
    runtime.appendEvent(EventEntry(kind: "input.key", text: keyName, action: "key"))
    return runtime.actionResult(ok: true)
  }

  private func commandRoute(for key: Key) -> (route: String, command: String?) {
    DebugRuntimeKeyInput.commandRoute(for: key)
  }

  private func executeCommandKey(_ key: Key) {
    switch key {
    case .t:
      _ = try? runtime.model.createTab()
      runtime.renderFrameUnlocked()
    case .w:
      if let tabId = runtime.model.activeTab?.id {
        try? runtime.model.closeTab(tabId)
        runtime.renderFrameUnlocked()
      }
    default:
      guard let index = DebugRuntimeKeyInput.tabIndex(for: key),
        index < runtime.model.tabs.count
      else {
        return
      }
      runtime.model.selectTab(runtime.model.tabs[index].id)
      runtime.renderFrameUnlocked()
    }
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
