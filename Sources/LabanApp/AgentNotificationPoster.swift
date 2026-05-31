import AppKit
import Foundation
import LabanCore
import UserNotifications

/// Posts a native macOS user notification when a tab's program emits an OSC 9
/// desktop notification — for example the Codex agent TUI signalling "agent
/// turn complete" or "approval requested" while the user is looking elsewhere.
///
/// This is the AppKit consumer of `AppModel.onAgentNotification`. The headless
/// debug runtime records the same event instead (see
/// `recordAgentNotificationEvent`), keeping the two runtimes in feature parity.
///
/// Authorization is requested lazily and best-effort: if the user denies
/// notifications, AppModel's per-tab attention dot still tells them the tab
/// wants attention. The banner is suppressed when the originating tab is the
/// active tab of the focused app, so the user is never notified about the pane
/// already in front of them.
final class AgentNotificationPoster {
  /// Returns true when `tabId` is the tab the user is currently looking at, so
  /// its notification should be suppressed. Defaults to never-suppress.
  var isTabFrontmost: (String) -> Bool = { _ in false }

  private var requestedAuthorization = false

  func post(tabId: String, tabTitle: String?, text: String) {
    let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return }
    if isTabFrontmost(tabId) { return }
    // UNUserNotificationCenter.current() traps without a real app bundle; guard
    // so a non-bundled host (tooling, some test rigs) cannot crash here.
    guard Bundle.main.bundleIdentifier != nil else { return }

    ensureAuthorization()
    let content = UNMutableNotificationContent()
    let trimmedTitle = tabTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
    content.title = (trimmedTitle?.isEmpty == false) ? trimmedTitle! : "Terminal"
    content.body = body
    let request = UNNotificationRequest(
      identifier: UUID().uuidString, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
  }

  private func ensureAuthorization() {
    guard !requestedAuthorization else { return }
    requestedAuthorization = true
    UNUserNotificationCenter.current().requestAuthorization(
      options: [.alert, .sound]) { _, _ in }
  }
}
