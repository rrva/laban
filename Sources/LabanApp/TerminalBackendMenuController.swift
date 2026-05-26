import AppKit
import LabanCore

final class TerminalBackendMenuController: NSObject {
  typealias RestartPrompt = (
    _ selectedBackend: TerminalSessionBackend,
    _ activeBackend: TerminalSessionBackend,
    _ source: TerminalBackendLaunchSource
  ) -> Void

  private let defaults: UserDefaults
  private let restartPrompt: RestartPrompt
  private var activeBackend: TerminalSessionBackend = .inProcess
  private var launchSource: TerminalBackendLaunchSource = .automatic
  private var localItem: NSMenuItem?
  private var labandItem: NSMenuItem?

  init(
    defaults: UserDefaults = .standard,
    restartPrompt: @escaping RestartPrompt = TerminalBackendMenuController.showRestartPrompt
  ) {
    self.defaults = defaults
    self.restartPrompt = restartPrompt
  }

  func configure(activeBackend: TerminalSessionBackend, launchSource: TerminalBackendLaunchSource) {
    self.activeBackend = activeBackend
    self.launchSource = launchSource
    syncMenuState()
  }

  func makeMenuItem() -> NSMenuItem {
    let parent = NSMenuItem(title: "Terminal Sessions", action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: "Terminal Sessions")
    parent.submenu = submenu

    let local = NSMenuItem(
      title: "Local Sessions",
      action: #selector(selectLocal(_:)),
      keyEquivalent: "")
    local.target = self
    submenu.addItem(local)
    localItem = local

    let laband = NSMenuItem(
      title: "laband Sessions",
      action: #selector(selectLaband(_:)),
      keyEquivalent: "")
    laband.target = self
    submenu.addItem(laband)
    labandItem = laband

    syncMenuState()
    return parent
  }

  @objc func selectLocal(_ sender: Any?) {
    select(.inProcess)
  }

  @objc func selectLaband(_ sender: Any?) {
    select(.laband)
  }

  private func select(_ backend: TerminalSessionBackend) {
    TerminalBackendSettings.set(backend, defaults: defaults)
    syncMenuState()
    if backend != activeBackend || launchSource.isOverride {
      restartPrompt(backend, activeBackend, launchSource)
    }
  }

  private func syncMenuState() {
    let selected = TerminalBackendSettings.persisted(defaults: defaults) ?? activeBackend
    localItem?.state = selected == .inProcess ? .on : .off
    labandItem?.state = selected == .laband ? .on : .off
  }

  private static func showRestartPrompt(
    selectedBackend: TerminalSessionBackend,
    activeBackend: TerminalSessionBackend,
    source: TerminalBackendLaunchSource
  ) {
    let selectedName = selectedBackend == .laband ? "laband" : "local"
    let alert = NSAlert()
    alert.messageText = "Restart Laban to use \(selectedName) sessions?"
    if source.isOverride {
      alert.informativeText =
        "This launch is using a command-line or environment override. Remove that override for the saved menu choice to apply on restart."
    } else {
      alert.informativeText =
        "Existing tabs stay on the current session backend until Laban restarts."
    }
    alert.addButton(withTitle: "Restart Now")
    alert.addButton(withTitle: "Later")
    if alert.runModal() == .alertFirstButtonReturn {
      AppDelegate.restartApp()
    }
  }
}
