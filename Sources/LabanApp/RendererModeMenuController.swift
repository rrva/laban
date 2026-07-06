import AppKit
import LabanRenderer

final class RendererModeMenuController: NSObject {
  typealias ApplySelection = (RendererSelection) -> Void

  private let defaults: UserDefaults
  private let applySelection: ApplySelection
  private var softwareItem: NSMenuItem?
  private var classicItem: NSMenuItem?
  private var gpuDrivenItem: NSMenuItem?
  private var vectorGlyphItem: NSMenuItem?
  private var slugGlyphItem: NSMenuItem?

  init(
    defaults: UserDefaults = .standard,
    applySelection: @escaping ApplySelection
  ) {
    self.defaults = defaults
    self.applySelection = applySelection
  }

  func makeMenuItem() -> NSMenuItem {
    let parent = NSMenuItem(title: L10n.tr("Renderer"), action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: L10n.tr("Renderer"))
    parent.submenu = submenu

    let software = NSMenuItem(
      title: L10n.tr("Software Renderer"),
      action: #selector(selectSoftware(_:)),
      keyEquivalent: "")
    software.target = self
    submenu.addItem(software)
    softwareItem = software

    let classic = NSMenuItem(
      title: L10n.tr("Classic Metal Renderer"),
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

    let vectorGlyph = NSMenuItem(
      title: L10n.tr("Vector Glyph Renderer"),
      action: #selector(selectVectorGlyph(_:)),
      keyEquivalent: "")
    vectorGlyph.target = self
    submenu.addItem(vectorGlyph)
    vectorGlyphItem = vectorGlyph

    let slugGlyph = NSMenuItem(
      title: L10n.tr("Slug Glyph Renderer"),
      action: #selector(selectSlugGlyph(_:)),
      keyEquivalent: "")
    slugGlyph.target = self
    submenu.addItem(slugGlyph)
    slugGlyphItem = slugGlyph

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

  @objc func selectVectorGlyph(_ sender: Any?) {
    select(.vectorGlyph)
  }

  @objc func selectSlugGlyph(_ sender: Any?) {
    select(.slugGlyph)
  }

  private var gpuDrivenTitle: String {
    if RendererMode.gpuDriven.isAvailableOnCurrentOS {
      return L10n.tr("GPU-driven Renderer")
    }
    return L10n.tr("GPU-driven Renderer (requires macOS 26)")
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
    vectorGlyphItem?.state = selected == .vectorGlyph ? .on : .off
    slugGlyphItem?.state = selected == .slugGlyph ? .on : .off
    gpuDrivenItem?.isEnabled = RendererMode.gpuDriven.isAvailableOnCurrentOS
    gpuDrivenItem?.title = gpuDrivenTitle
  }
}
