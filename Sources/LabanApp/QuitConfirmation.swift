import AppKit

/// The window-close and app-quit side of close confirmation (spec §28).
///
/// Closing the last window, closing the last tab, restarting, and automation
/// all end in a quit that must not ask again: the user already answered (or
/// the app started the quit itself). They note that with
/// `noteQuitConfirmed()`, which the next quit consumes, so it can never leak
/// into a later, unrelated quit.
final class QuitConfirmation {
  static let shared = QuitConfirmation()

  private var nextQuitConfirmed = false

  /// The next quit proceeds without asking.
  func noteQuitConfirmed() {
    nextQuitConfirmed = true
  }

  /// Presents a confirmation and reports the answer through `answer`, either
  /// before returning (a test responder or an app-modal alert) or later (a
  /// sheet).
  typealias Present = (_ answer: @escaping (Bool) -> Void) -> Void

  /// The `applicationShouldTerminate` answer. A sheet answers after this
  /// returns `.terminateLater`, and `reply` then resolves the pending quit.
  /// AppKit treats a second quit request while one is pending as a forced
  /// quit without calling the delegate again, so this is never re-entered.
  func shouldTerminate(
    asks: () -> Bool,
    present: Present,
    reply: @escaping (Bool) -> Void
  ) -> NSApplication.TerminateReply {
    if nextQuitConfirmed {
      nextQuitConfirmed = false
      return .terminateNow
    }
    guard asks() else { return .terminateNow }
    var syncAnswer: Bool?
    var deferred = false
    present { confirmed in
      if deferred {
        reply(confirmed)
      } else {
        syncAnswer = confirmed
      }
    }
    if let syncAnswer { return syncAnswer ? .terminateNow : .terminateCancel }
    deferred = true
    return .terminateLater
  }

  /// The `windowShouldClose` answer for the main window, whose close quits
  /// the app. A confirmed close marks the following quit as confirmed and
  /// then runs `close`.
  func windowShouldClose(
    asks: () -> Bool,
    present: Present,
    close: @escaping () -> Void
  ) -> Bool {
    guard asks() else { return true }
    present { [weak self] confirmed in
      guard confirmed else { return }
      self?.noteQuitConfirmed()
      close()
    }
    return false
  }
}
