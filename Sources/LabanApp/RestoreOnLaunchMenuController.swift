import AppKit
import LabanCore

/// Owns the "Restore on Launch" checkable menu item. The action toggles
/// `RestoreOnLaunchSettings` (UserDefaults-backed) and re-syncs the
/// checkmark to the new value. No app restart required: the next quit
/// will (or will not) save and the next launch will (or will not)
/// load, depending on the value at those moments.
final class RestoreOnLaunchMenuController: NSObject {
  private(set) var menuItem: NSMenuItem?

  /// Build a fresh `NSMenuItem` whose target is this controller and
  /// whose checkmark reflects the current setting value. Holds a weak
  /// retention of the item via `menuItem` so subsequent toggle calls
  /// can update its state.
  func makeMenuItem() -> NSMenuItem {
    let item = NSMenuItem(
      title: "Restore on Launch",
      action: #selector(toggle(_:)),
      keyEquivalent: ""
    )
    item.target = self
    item.state = RestoreOnLaunchSettings.isEnabled ? .on : .off
    menuItem = item
    return item
  }

  @objc func toggle(_ sender: Any?) {
    let newValue = !RestoreOnLaunchSettings.isEnabled
    RestoreOnLaunchSettings.set(newValue)
    menuItem?.state = newValue ? .on : .off
  }
}
