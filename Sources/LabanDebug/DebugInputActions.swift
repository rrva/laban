import Foundation
import LabanCore
import LabanRenderer
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
    if let tab = runtime.model.activeTab, let client = runtime.terminalSessionClient {
      do {
        try runtime.ensureTerminalClientSessionUnlocked(for: tab)
        try client.writeInput(
          sessionId: runtime.terminalClientRemoteSessionId(for: tab.sessionId),
          bytes: bytes
        )
        runtime.appendTerminalLog(sessionId: tab.sessionId, direction: "input", bytes: bytes)
      } catch {
        runtime.appendError(
          kind: "laband.writeInput.failed",
          message: String(describing: error),
          sessionId: tab.sessionId,
          tabId: tab.id
        )
        return jsonError("typeText failed: \(error)")
      }
    } else if let tab = runtime.model.activeTab, let session = runtime.model.session(forTab: tab.id)
    {
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
    // Honor explicit `tabId` so callers can target a specific tab
    // without first having to selectTab + risk losing focus context.
    // Falls back to the active tab when `tabId` is omitted.
    let targetTabId = request.tabId ?? runtime.model.activeTab?.id
    guard let tabId = targetTabId,
      let session = runtime.model.session(forTab: tabId)
    else {
      return jsonError("feedOutput could not resolve a target tab")
    }
    let bytes = Array(text.utf8)
    session.feedOutput(bytes)
    runtime.model.noteOutput(forTab: tabId)
    runtime.appendTerminalLog(sessionId: session.id, direction: "output", bytes: bytes)
    runtime.renderFrameUnlocked()
    runtime.appendEvent(EventEntry(kind: "output.fed", tabId: tabId, text: text))
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

    let (appRoute, commandStr) = DebugRuntimeKeyInput.appCommandRoute(
      for: key,
      modifiers: mods
    )
    if appRoute == "appCommand" {
      runtime.appendInputEnvelope(
        InputEventEnvelope(
          inputId: inputId, seq: 0,
          source: "debug", kind: "key", route: appRoute,
          frameBefore: frameBefore,
          tabId: activeTab?.id, sessionId: activeTab?.sessionId,
          key: keyName, modifiers: request.modifiers, command: commandStr
        ))
      runtime.appendEvent(EventEntry(kind: "input.key", text: keyName, action: "key"))
      if let commandStr {
        executeCommandKey(commandStr, key: key)
      }
      return runtime.actionResult(ok: true)
    }

    if mods.contains(.command),
      !DebugRuntimeKeyInput.isCommandLineEditingKey(key, modifiers: mods)
    {
      runtime.appendInputEnvelope(
        InputEventEnvelope(
          inputId: inputId, seq: 0,
          source: "debug", kind: "key", route: "ignored",
          frameBefore: frameBefore,
          tabId: activeTab?.id, sessionId: activeTab?.sessionId,
          key: keyName, modifiers: request.modifiers
        ))
      runtime.appendEvent(EventEntry(kind: "input.key", text: keyName, action: "key"))
      return runtime.actionResult(ok: true)
    }

    if let bytes = DebugRuntimeKeyInput.commandLineEditingBytes(for: key, modifiers: mods),
      action != .release
    {
      var encodedHex: String? = nil
      var encodedLength: Int? = nil
      if let tab = activeTab, let session = runtime.model.session(forTab: tab.id) {
        let deltaRows = session.scrollViewportToActiveBottom()
        appendInputFollowBottom(deltaRows: deltaRows, frameBefore: frameBefore, tab: tab)
        encodedHex = bytes.map { String(format: "%02x", $0) }.joined()
        encodedLength = bytes.count
        session.write(bytes)
        runtime.appendTerminalLog(sessionId: session.id, direction: "input", bytes: bytes)
      }
      runtime.appendInputEnvelope(
        InputEventEnvelope(
          inputId: inputId, seq: 0,
          source: "debug", kind: "key", route: "terminal",
          frameBefore: frameBefore,
          tabId: activeTab?.id, sessionId: activeTab?.sessionId,
          key: keyName, modifiers: request.modifiers,
          encodedHex: encodedHex, encodedLength: encodedLength
        ))
      runtime.renderFrameUnlocked()
      runtime.appendEvent(EventEntry(kind: "input.key", text: keyName, action: "key"))
      return runtime.actionResult(ok: true)
    }

    if DebugRuntimeKeyInput.isCommandLineEditingRelease(key, modifiers: mods, action: action) {
      runtime.appendInputEnvelope(
        InputEventEnvelope(
          inputId: inputId, seq: 0,
          source: "debug", kind: "key", route: "ignored",
          frameBefore: frameBefore,
          tabId: activeTab?.id, sessionId: activeTab?.sessionId,
          key: keyName, modifiers: request.modifiers
        ))
      runtime.appendEvent(EventEntry(kind: "input.key", text: keyName, action: "key"))
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
      text: request.text,
      optionAsMeta: OptionKeySettings.current()
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

  private func executeCommandKey(_ command: String, key: Key) {
    switch command {
    case "newTab":
      if let tab = try? runtime.model.createTab() {
        try? runtime.ensureTerminalClientSessionUnlocked(for: tab)
      }
      runtime.renderFrameUnlocked()
    case "closeTab":
      if let tabId = runtime.model.activeTab?.id {
        if let sessionId = runtime.model.activeTab?.sessionId {
          runtime.terminateTerminalClientSessionUnlocked(sessionId: sessionId)
        }
        try? runtime.model.closeTab(tabId)
        runtime.renderFrameUnlocked()
      }
    case "find":
      if let sessionId = runtime.model.activeTab?.sessionId {
        _ = runtime.model.startFind(sessionID: sessionId)
        runtime.renderFrameUnlocked()
      }
    case "selectLastTab":
      selectTab(at: runtime.model.tabs.count - 1)
    case "selectNextTab":
      selectRelativeTab(delta: 1)
    case "selectPreviousTab":
      selectRelativeTab(delta: -1)
    case "selectTab":
      if let index = DebugRuntimeKeyInput.tabIndex(for: key) {
        selectTab(at: index)
      }
    case "increaseFontSize":
      _ = DebugWindowActions(runtime: runtime).setFontSize(
        SetFontSizeActionRequest(pointSize: Double(runtime.fontAtlas.pointSize) + 1))
    case "decreaseFontSize":
      _ = DebugWindowActions(runtime: runtime).setFontSize(
        SetFontSizeActionRequest(pointSize: Double(runtime.fontAtlas.pointSize) - 1))
    case "resetFontSize":
      _ = DebugWindowActions(runtime: runtime).setFontSize(
        SetFontSizeActionRequest(pointSize: Double(FontAtlas.defaultTerminalPointSize)))
    default:
      return
    }
  }

  private func selectTab(at index: Int) {
    guard index >= 0, index < runtime.model.tabs.count else { return }
    runtime.model.selectTab(runtime.model.tabs[index].id)
    runtime.renderFrameUnlocked()
  }

  private func selectRelativeTab(delta: Int) {
    let tabs = runtime.model.tabs
    guard tabs.count > 1, let activeTab = runtime.model.activeTab,
      let currentIndex = tabs.firstIndex(where: { $0.id == activeTab.id })
    else {
      return
    }
    let nextIndex = (currentIndex + delta + tabs.count) % tabs.count
    selectTab(at: nextIndex)
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
