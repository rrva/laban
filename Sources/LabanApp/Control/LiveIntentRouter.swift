import Foundation
import LabanCore
import LabanTerminalCore

/// Routes Phase 0 control requests against the live AppModel rendered by the
/// GUI. Server callbacks arrive off-main; mutations hop to the main thread so
/// model observers and AppKit-facing refresh paths keep their existing contract.
final class LiveIntentRouter: IntentRouter {
  private weak var model: AppModel?

  init(model: AppModel) {
    self.model = model
  }

  func snapshotState() -> ControlState {
    onMain {
      guard let model = self.model else {
        return ControlState(tabs: [], activeTabId: nil)
      }
      let tabs = model.tabs
      return ControlState(
        tabs: tabs.enumerated().map { index, tab in
          ControlTabState(
            id: tab.id,
            index: index,
            active: tab.isActive,
            sessionId: tab.sessionId)
        },
        activeTabId: model.activeTab?.id)
    }
  }

  func selectTab(index: Int) -> ControlActionResult {
    onMain {
      guard let model = self.model else {
        return ControlActionResult(ok: false, activeTabId: nil, error: "model released")
      }
      let tabs = model.tabs
      guard index >= 0, index < tabs.count else {
        return ControlActionResult(
          ok: false,
          activeTabId: model.activeTab?.id,
          error: "index \(index) out of range 0..<\(tabs.count)")
      }
      model.selectTab(tabs[index].id)
      return ControlActionResult(ok: true, activeTabId: model.activeTab?.id, error: nil)
    }
  }

  func route(_ intent: Intent) -> ControlResponse {
    switch intent {
    case .tabSelect(let input):
      guard let index = input.index else {
        return .error(400, "missing index")
      }
      return .json(selectTab(index: index))
    case .terminalTypeText(let input):
      return .json(typeText(input.text))
    case .terminalSendKey(let input):
      return sendKey(input)
    case .legacyDebugAction, .unsupportedDebugAction:
      return .error(400, "unsupported")
    }
  }

  func typeText(_ text: String) -> ControlActionResult {
    onMain {
      guard let model = self.model else {
        return ControlActionResult(ok: false, activeTabId: nil, error: "model released")
      }
      guard let tab = model.activeTab, let session = model.session(forTab: tab.id) else {
        return ControlActionResult(
          ok: false, activeTabId: model.activeTab?.id, error: "no active terminal session")
      }
      _ = session.write(Array(text.utf8))
      return ControlActionResult(ok: true, activeTabId: model.activeTab?.id, error: nil)
    }
  }

  func sendKey(_ input: SendKeyInput) -> ControlResponse {
    guard let key = ControlKeyName.key(fromName: input.key) else {
      return .error(400, "unknown key '\(input.key)'")
    }
    let modifiers = ControlKeyName.modifiers(from: input.modifiers)
    return .json(
      onMain {
        guard let model = self.model else {
          return ControlActionResult(ok: false, activeTabId: nil, error: "model released")
        }
        guard let tab = model.activeTab, let session = model.session(forTab: tab.id) else {
          return ControlActionResult(
            ok: false, activeTabId: model.activeTab?.id, error: "no active terminal session")
        }
        _ = session.sendKey(KeyEvent(action: .press, key: key, modifiers: modifiers))
        return ControlActionResult(ok: true, activeTabId: model.activeTab?.id, error: nil)
      })
  }

  func query(_ query: Query) -> ControlResponse {
    switch query {
    case .state:
      return .json(snapshotState())
    }
  }

  func artifact(_ request: ArtifactRequest) -> ControlResponse? {
    nil
  }

  private func onMain<T>(_ body: @escaping () -> T) -> T {
    if Thread.isMainThread { return body() }
    return DispatchQueue.main.sync(execute: body)
  }
}
