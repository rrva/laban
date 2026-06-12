import AppKit
import LabanRenderer

enum RendererSelection: String, Codable, CaseIterable, Sendable {
  case software
  case classic
  case gpuDriven

  static let defaultsKey = RendererMode.defaultsKey

  var isAvailableOnCurrentOS: Bool {
    switch self {
    case .software, .classic:
      return true
    case .gpuDriven:
      return RendererMode.gpuDriven.isAvailableOnCurrentOS
    }
  }

  var metalMode: RendererMode? {
    switch self {
    case .software:
      return nil
    case .classic:
      return .classic
    case .gpuDriven:
      return .gpuDriven
    }
  }

  static func persisted(defaults: UserDefaults = .standard) -> RendererSelection {
    guard let raw = defaults.string(forKey: defaultsKey),
      let selection = RendererSelection(rawValue: raw),
      selection.isAvailableOnCurrentOS
    else {
      return RendererSelection(metalMode: RendererMode.defaultMode)
    }
    return selection
  }

  static func set(_ selection: RendererSelection, defaults: UserDefaults = .standard) {
    let resolved = selection.isAvailableOnCurrentOS ? selection : .classic
    defaults.set(resolved.rawValue, forKey: defaultsKey)
  }

  init(metalMode: RendererMode) {
    switch metalMode {
    case .classic:
      self = .classic
    case .gpuDriven:
      self = .gpuDriven
    }
  }
}

final class RendererModeMenuController: NSObject {
  typealias ApplySelection = (RendererSelection) -> Void

  private let defaults: UserDefaults
  private let applySelection: ApplySelection
  private var softwareItem: NSMenuItem?
  private var classicItem: NSMenuItem?
  private var gpuDrivenItem: NSMenuItem?

  init(
    defaults: UserDefaults = .standard,
    applySelection: @escaping ApplySelection
  ) {
    self.defaults = defaults
    self.applySelection = applySelection
  }

  func makeMenuItem() -> NSMenuItem {
    let parent = NSMenuItem(title: "Renderer", action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: "Renderer")
    parent.submenu = submenu

    let software = NSMenuItem(
      title: "Software Renderer",
      action: #selector(selectSoftware(_:)),
      keyEquivalent: "")
    software.target = self
    submenu.addItem(software)
    softwareItem = software

    let classic = NSMenuItem(
      title: "Classic Metal Renderer",
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

  @objc func selectSoftware(_ sender: Any?) {
    select(.software)
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

  /// The renderer currently persisted (and applied). Used to preselect the
  /// Settings popup.
  var currentSelection: RendererSelection { RendererSelection.persisted(defaults: defaults) }

  /// Apply a renderer choice from the Settings popup, routing through the same
  /// persist + live-apply path as the menu items.
  func choose(_ selection: RendererSelection) {
    select(selection)
  }

  private func select(_ selection: RendererSelection) {
    let previous = RendererSelection.persisted(defaults: defaults)
    RendererSelection.set(selection, defaults: defaults)
    let selected = RendererSelection.persisted(defaults: defaults)
    syncMenuState()
    if selected != previous {
      applySelection(selected)
    }
  }

  private func syncMenuState() {
    let selected = RendererSelection.persisted(defaults: defaults)
    softwareItem?.state = selected == .software ? .on : .off
    classicItem?.state = selected == .classic ? .on : .off
    gpuDrivenItem?.state = selected == .gpuDriven ? .on : .off
    gpuDrivenItem?.isEnabled = RendererMode.gpuDriven.isAvailableOnCurrentOS
    gpuDrivenItem?.title = gpuDrivenTitle
  }
}
