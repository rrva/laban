import Foundation
import UserNotifications

/// Routes user interaction with a delivered native notification back into Laban.
///
/// The handler owns no AppKit state. Its injected closures keep the routing logic
/// deterministic in tests and let `AppDelegate` decide how to activate the app
/// and focus a live tab.
final class NativeNotificationResponseHandler {
  typealias RunOnMain = (@escaping () -> Void) -> Void

  private let activateApplication: () -> Void
  private let focusTab: (String) -> Bool
  private let runOnMain: RunOnMain

  init(
    activateApplication: @escaping () -> Void,
    focusTab: @escaping (String) -> Bool,
    runOnMain: @escaping RunOnMain = NativeNotificationResponseHandler.runOnMain
  ) {
    self.activateApplication = activateApplication
    self.focusTab = focusTab
    self.runOnMain = runOnMain
  }

  func handle(
    actionIdentifier: String,
    userInfo: [AnyHashable: Any],
    completion: @escaping () -> Void
  ) {
    runOnMain { [activateApplication, focusTab] in
      defer { completion() }

      guard actionIdentifier == UNNotificationDefaultActionIdentifier else { return }

      if let tabId = Self.tabId(from: userInfo) {
        _ = focusTab(tabId)
      }
      // Always activate Laban for a default tap. If the originating tab no
      // longer exists, this is the graceful fallback and leaves the current
      // tab selection untouched.
      activateApplication()
    }
  }

  private static func tabId(from userInfo: [AnyHashable: Any]) -> String? {
    guard let tabId = userInfo["tabId"] as? String, !tabId.isEmpty else { return nil }
    return tabId
  }

  private static func runOnMain(_ operation: @escaping () -> Void) {
    if Thread.isMainThread {
      operation()
    } else {
      DispatchQueue.main.async(execute: operation)
    }
  }
}
