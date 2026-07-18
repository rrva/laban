import AppKit
import LabanCore
import LabanRenderer

/// Owns the View → Theme menu and its persisted user choice.
///
/// Picking a theme updates the matching dark/light slot in `Theme` and
/// immediately applies it. Follow-system stays on by default — the user's
/// dark pick is what gets restored when macOS goes dark, the user's light
/// pick when it goes light.
///
/// Imported themes live in `TerminalThemeStore` and are merged into the menu
/// and Settings popup alongside bundled themes. Bundled themes keep their
/// existing order; imported themes are appended alphabetically within each
/// brightness group.
final class ThemeMenuController: NSObject, NSMenuItemValidation {

  private static let darkKey = "LabanThemeDark"
  private static let lightKey = "LabanThemeLight"
  private static let currentKey = "LabanThemeCurrent"
  private static let followsKey = "LabanThemeFollowsSystem"

  private let themeStore: TerminalThemeStore

  /// Stable order shown in the menu. Item tag is the index here.
  private lazy var themes: [ThemeData] = Self.mergeImportedThemes(
    store: themeStore,
    bundledDark: Theme.allDarkThemes,
    bundledLight: Theme.allLightThemes,
    imported: (try? themeStore.allManagedThemes()) ?? [])

  init(themeStore: TerminalThemeStore = TerminalThemeStore()) {
    self.themeStore = themeStore
    super.init()
  }

  /// Reloads imported themes from the store. Called after an import or removal
  /// so the menu and Settings popup stay in sync with the on-disk set.
  func reloadImportedThemes() {
    themes = Self.mergeImportedThemes(
      store: themeStore,
      bundledDark: Theme.allDarkThemes,
      bundledLight: Theme.allLightThemes,
      imported: (try? themeStore.allManagedThemes()) ?? [])
  }

  /// Loads persisted choices into `Theme` so the first appearance KVO firing
  /// already uses the user's last picks. Call before AppDelegate installs
  /// the appearance observation.
  func loadPersistedChoices() {
    reloadImportedThemes()
    let d = UserDefaults.standard
    if let darkName = d.string(forKey: Self.darkKey),
      let theme = themes.first(where: { $0.name == darkName })
    {
      Theme.darkVariant = theme
    }
    if let lightName = d.string(forKey: Self.lightKey),
      let theme = themes.first(where: { $0.name == lightName })
    {
      Theme.lightVariant = theme
    }
    if d.object(forKey: Self.followsKey) != nil {
      Theme.followsSystemAppearance = d.bool(forKey: Self.followsKey)
    }
    if !Theme.followsSystemAppearance,
      let currentName = d.string(forKey: Self.currentKey),
      let theme = themes.first(where: { $0.name == currentName })
    {
      Theme.apply(theme)
    }
    applyAppAppearanceChoice()
  }

  /// Builds the items shown under View → Theme. Caller installs them into
  /// the parent menu and is responsible for inserting separators.
  func makeMenuItems() -> [NSMenuItem] {
    var items: [NSMenuItem] = []
    for (i, theme) in themes.enumerated() {
      let item = NSMenuItem(
        title: theme.name,
        action: #selector(selectTheme(_:)),
        keyEquivalent: ""
      )
      item.tag = i
      item.target = self
      items.append(item)
      // Separator between the last dark theme and the first light theme so
      // the two groups are visually distinct without nesting submenus.
      let isLastDark =
        theme.isDark && (i + 1 < themes.count) && !themes[i + 1].isDark
      if isLastDark {
        items.append(NSMenuItem.separator())
      }
    }
    items.append(NSMenuItem.separator())
    let follows = NSMenuItem(
      title: L10n.tr("Follow System Appearance"),
      action: #selector(toggleFollowsSystemAppearance(_:)),
      keyEquivalent: ""
    )
    follows.target = self
    items.append(follows)
    return items
  }

  // MARK: Settings access

  /// Themes in menu order (dark group, then light group). The Settings window
  /// builds its theme popup from this so it shows the same list as the menu.
  var orderedThemes: [ThemeData] { themes }

  /// Name of the theme currently applied — used to preselect the popup.
  var currentThemeName: String { Theme.current.name }

  /// Names of the pinned dark/light variants — used to preselect the
  /// per-appearance popups shown while following the system appearance.
  var darkVariantName: String { Theme.darkVariant.name }
  var lightVariantName: String { Theme.lightVariant.name }

  /// Whether the app is currently following the system dark/light appearance.
  var followsSystemAppearance: Bool { Theme.followsSystemAppearance }

  /// The store backing imported themes. Exposed so the Settings window can
  /// import and remove themes through the same controller.
  var importedThemeStore: TerminalThemeStore { themeStore }

  // MARK: Actions

  @objc func selectTheme(_ sender: NSMenuItem) {
    applyTheme(at: sender.tag)
  }

  /// Apply the theme at `index` into `orderedThemes`: pin it as the matching
  /// dark/light variant, stop following the system, and apply immediately.
  /// Shared by the View menu item and the Settings popup so both behave alike.
  func applyTheme(at index: Int) {
    guard index >= 0, index < themes.count else { return }
    let theme = themes[index]
    if theme.isDark {
      Theme.darkVariant = theme
    } else {
      Theme.lightVariant = theme
    }
    Theme.followsSystemAppearance = false
    Theme.apply(theme)
    applyAppAppearanceChoice()
    persist()
  }

  @objc func toggleFollowsSystemAppearance(_ sender: NSMenuItem) {
    setFollowsSystem(!Theme.followsSystemAppearance)
  }

  /// Pins a theme as the dark or light variant without leaving follow-system
  /// mode. Applies immediately only when the system is currently in that
  /// appearance, so picking the other appearance's theme never flashes it on
  /// screen. Unlike `applyTheme(at:)`, this never turns following off.
  func pinVariant(at index: Int) {
    guard index >= 0, index < themes.count else { return }
    let theme = themes[index]
    if theme.isDark {
      Theme.darkVariant = theme
    } else {
      Theme.lightVariant = theme
    }
    if Theme.followsSystemAppearance, theme.isDark == Theme.current.isDark {
      Theme.apply(theme)
    }
    applyAppAppearanceChoice()
    persist()
  }

  /// Turn system-appearance following on or off. When turning on, snap the
  /// palette to the live system appearance immediately.
  func setFollowsSystem(_ on: Bool) {
    Theme.followsSystemAppearance = on
    if on {
      let isDark =
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        == .darkAqua
      Theme.applyForAppearance(isDark: isDark)
    }
    applyAppAppearanceChoice()
    persist()
  }

  // MARK: Validation

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(selectTheme(_:)) {
      let isCurrent =
        menuItem.tag >= 0
        && menuItem.tag < themes.count
        && themes[menuItem.tag].name == Theme.current.name
      menuItem.state = isCurrent ? .on : .off
      return true
    }
    if menuItem.action == #selector(toggleFollowsSystemAppearance(_:)) {
      menuItem.state = Theme.followsSystemAppearance ? .on : .off
      return true
    }
    return true
  }

  // MARK: Persistence

  private func persist() {
    let d = UserDefaults.standard
    d.set(Theme.darkVariant.name, forKey: Self.darkKey)
    d.set(Theme.lightVariant.name, forKey: Self.lightKey)
    d.set(Theme.current.name, forKey: Self.currentKey)
    d.set(Theme.followsSystemAppearance, forKey: Self.followsKey)
  }

  private func applyAppAppearanceChoice() {
    guard !Theme.followsSystemAppearance else {
      NSApp.appearance = nil
      return
    }
    NSApp.appearance = NSAppearance(named: Theme.current.isDark ? .darkAqua : .aqua)
  }

  private static func mergeImportedThemes(
    store: TerminalThemeStore,
    bundledDark: [ThemeData],
    bundledLight: [ThemeData],
    imported: [TerminalManagedTheme]
  ) -> [ThemeData] {
    let importedDark =
      imported
      .filter(\.isDark)
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    let importedLight =
      imported
      .filter { !$0.isDark }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    let resolvedDark = importedDark.compactMap { store.resolveTheme($0) }
    let resolvedLight = importedLight.compactMap { store.resolveTheme($0) }

    return bundledDark + resolvedDark + bundledLight + resolvedLight
  }
}
