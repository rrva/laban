import AppKit
import LabanRenderer

/// Owns the View → Theme menu and its persisted user choice.
///
/// Picking a theme updates the matching dark/light slot in `Theme` and
/// immediately applies it. Follow-system stays on by default — the user's
/// dark pick is what gets restored when macOS goes dark, the user's light
/// pick when it goes light.
final class ThemeMenuController: NSObject, NSMenuItemValidation {

  private static let darkKey = "LabanThemeDark"
  private static let lightKey = "LabanThemeLight"
  private static let followsKey = "LabanThemeFollowsSystem"

  /// Stable order shown in the menu. Item tag is the index here.
  private let themes: [ThemeData] = Theme.allDarkThemes + Theme.allLightThemes

  /// Loads persisted choices into `Theme` so the first appearance KVO firing
  /// already uses the user's last picks. Call before AppDelegate installs
  /// the appearance observation.
  func loadPersistedChoices() {
    let d = UserDefaults.standard
    if let darkName = d.string(forKey: Self.darkKey),
      let theme = Theme.allDarkThemes.first(where: { $0.name == darkName })
    {
      Theme.darkVariant = theme
    }
    if let lightName = d.string(forKey: Self.lightKey),
      let theme = Theme.allLightThemes.first(where: { $0.name == lightName })
    {
      Theme.lightVariant = theme
    }
    if d.object(forKey: Self.followsKey) != nil {
      Theme.followsSystemAppearance = d.bool(forKey: Self.followsKey)
    }
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
      title: "Follow System Appearance",
      action: #selector(toggleFollowsSystemAppearance(_:)),
      keyEquivalent: ""
    )
    follows.target = self
    items.append(follows)
    return items
  }

  // MARK: Actions

  @objc func selectTheme(_ sender: NSMenuItem) {
    guard sender.tag >= 0, sender.tag < themes.count else { return }
    let theme = themes[sender.tag]
    if theme.isDark {
      Theme.darkVariant = theme
    } else {
      Theme.lightVariant = theme
    }
    // Override followsSystemAppearance so the manual pick wins immediately
    // even when the system is showing the other appearance.
    let saved = Theme.followsSystemAppearance
    Theme.followsSystemAppearance = false
    Theme.apply(theme)
    Theme.followsSystemAppearance = saved
    persist()
  }

  @objc func toggleFollowsSystemAppearance(_ sender: NSMenuItem) {
    Theme.followsSystemAppearance.toggle()
    if Theme.followsSystemAppearance {
      let isDark =
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        == .darkAqua
      Theme.applyForAppearance(isDark: isDark)
    }
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
    d.set(Theme.followsSystemAppearance, forKey: Self.followsKey)
  }
}
