import Foundation
import LabanCore

/// Routes Phase 0 control requests against the live AppModel rendered by the
/// GUI. Server callbacks arrive off-main; mutations hop to the main thread so
/// model observers and AppKit-facing refresh paths keep their existing contract.
final class LiveIntentRouter: ControlRouter {
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

  private func onMain<T>(_ body: @escaping () -> T) -> T {
    if Thread.isMainThread { return body() }
    return DispatchQueue.main.sync(execute: body)
  }
}
