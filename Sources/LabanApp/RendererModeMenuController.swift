import AppKit
import LabanRenderer

final class RendererModeMenuController: NSObject {
  typealias ApplyMode = (RendererMode) -> Void

  private let defaults: UserDefaults
  private let applyMode: ApplyMode
  private var classicItem: NSMenuItem?
  private var gpuDrivenItem: NSMenuItem?

  init(
    defaults: UserDefaults = .standard,
    applyMode: @escaping ApplyMode
  ) {
    self.defaults = defaults
    self.applyMode = applyMode
  }

  func makeMenuItem() -> NSMenuItem {
    let parent = NSMenuItem(title: "Renderer", action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: "Renderer")
    parent.submenu = submenu

    let classic = NSMenuItem(
      title: "Classic Renderer",
      action: #selector(selectClassic(_:)),
      keyEquivalent: "")
    classic.target = self
    submenu.addItem(classic)
    classicItem = classic

    let gpuDriven = NSMenuItem(
      title: gpuDrivenTitle,
      action: #selector(selectGPUDriven(_:)),
      keyEquivalent: "")
    gpuDriven.target = self
    gpuDriven.isEnabled = RendererMode.gpuDriven.isAvailableOnCurrentOS
    submenu.addItem(gpuDriven)
    gpuDrivenItem = gpuDriven

    syncMenuState()
    return parent
  }

  @objc func selectClassic(_ sender: Any?) {
    select(.classic)
  }

  @objc func selectGPUDriven(_ sender: Any?) {
    select(.gpuDriven)
  }

  private var gpuDrivenTitle: String {
    if RendererMode.gpuDriven.isAvailableOnCurrentOS {
      return "GPU-driven Renderer"
    }
    return "GPU-driven Renderer (requires macOS 26)"
  }

  private func select(_ mode: RendererMode) {
    let previous = RendererMode.persisted(defaults: defaults)
    RendererMode.set(mode, defaults: defaults)
    let selected = RendererMode.persisted(defaults: defaults)
    syncMenuState()
    if selected != previous {
      applyMode(selected)
    }
  }

  private func syncMenuState() {
    let selected = RendererMode.persisted(defaults: defaults)
    classicItem?.state = selected == .classic ? .on : .off
    gpuDrivenItem?.state = selected == .gpuDriven ? .on : .off
    gpuDrivenItem?.isEnabled = RendererMode.gpuDriven.isAvailableOnCurrentOS
    gpuDrivenItem?.title = gpuDrivenTitle
  }
}
