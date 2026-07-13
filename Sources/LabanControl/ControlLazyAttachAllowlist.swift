import Foundation
import LabanCore

// The own-session read family (`ControlSessionObserveFamily`) IS the lazy
// attach allowlist: a request whose resolved intent is a family member is
// eligible for a dialog-first grant. `persistable` is uniform across every
// entry because persistability is now a whole-grant property (Always-Allow
// persists the whole family grant for the approved principal/session, never
// a single intent); see execplans/active/dialog-first-session-observe.md,
// Design/Server (Milestone 1), step 1.
public enum ControlLazyAttachAllowlist {
  public struct Entry: Sendable, Equatable {
    public let cliCommand: String
    public let method: String
    public let path: String
    public let intentID: String
    public let routeID: String
    public let persistable: Bool

    public init(
      cliCommand: String,
      method: String,
      path: String,
      intentID: String,
      routeID: String,
      persistable: Bool
    ) {
      self.cliCommand = cliCommand
      self.method = method
      self.path = path
      self.intentID = intentID
      self.routeID = routeID
      self.persistable = persistable
    }
  }

  public static let entries: [Entry] = [
    Entry(
      cliCommand: "session.state",
      method: "GET",
      path: "/debug/state",
      intentID: "app.state",
      routeID: "GET /debug/state",
      persistable: true),
    Entry(
      cliCommand: "session.scroll",
      method: "POST",
      path: "/debug/actions",
      intentID: "terminal.scrollViewport",
      routeID: "POST /debug/actions",
      persistable: true),
    Entry(
      cliCommand: "command.propose",
      method: "POST",
      path: "/debug/actions",
      intentID: "command.propose",
      routeID: "POST /debug/actions",
      persistable: true),
    Entry(
      cliCommand: "terminal.getText",
      method: "GET",
      path: "/debug/text",
      intentID: "terminal.getText",
      routeID: "GET /debug/text",
      persistable: true),
    Entry(
      cliCommand: "window.screenshot",
      method: "GET",
      path: "/debug/window-screenshot",
      intentID: "window.screenshot",
      routeID: "GET /debug/window-screenshot",
      persistable: true),
    Entry(
      cliCommand: "notifications.test",
      method: "POST",
      path: "/debug/notifications/test",
      intentID: "notifications.test",
      routeID: "POST /debug/notifications/test",
      persistable: false),
    Entry(
      cliCommand: "session.detail",
      method: "GET",
      path: "/debug/sessions/<id>",
      intentID: "session.detail",
      routeID: "GET /debug/sessions/<id>",
      persistable: true),
    Entry(
      cliCommand: "selection.read",
      method: "GET",
      path: "/debug/selection",
      intentID: "selection.read",
      routeID: "GET /debug/selection",
      persistable: true),
    Entry(
      cliCommand: "find.state",
      method: "GET",
      path: "/debug/find/state",
      intentID: "find.state",
      routeID: "GET /debug/find/state",
      persistable: true),
    Entry(
      cliCommand: "shellIntegration.state",
      method: "GET",
      path: "/debug/shell-integration/state",
      intentID: "shellIntegration.state",
      routeID: "GET /debug/shell-integration/state",
      persistable: true),
    Entry(
      cliCommand: "scrollIndicator.state",
      method: "GET",
      path: "/debug/scroll-indicator/state",
      intentID: "scrollIndicator.state",
      routeID: "GET /debug/scroll-indicator/state",
      persistable: true),
    Entry(
      cliCommand: "commandProposal.list",
      method: "POST",
      path: "/debug/actions",
      intentID: "commandProposal.list",
      routeID: "POST /debug/actions",
      persistable: true),
    Entry(
      cliCommand: "commandProposal.get",
      method: "POST",
      path: "/debug/actions",
      intentID: "commandProposal.get",
      routeID: "POST /debug/actions",
      persistable: true),
    Entry(
      cliCommand: "commandProposal.cancel",
      method: "POST",
      path: "/debug/actions",
      intentID: "commandProposal.cancel",
      routeID: "POST /debug/actions",
      persistable: true),
  ]

  public static func entry(cliCommand: String) -> Entry? {
    entries.first { $0.cliCommand == cliCommand }
  }

  /// Looks up by `intentID` alone: each family intent maps to exactly one
  /// entry, and matching also by literal `path` would break for
  /// path-parameterized routes (e.g. `session.detail`'s `/debug/sessions/<id>`
  /// never equals a live request's `/debug/sessions/<realID>`). `method`/
  /// `path` are kept as parameters for call-site compatibility; the resolved
  /// `intentID` passed in is already route-derived and authoritative.
  public static func entry(method: String, path: String, intentID: String) -> Entry? {
    entries.first { $0.intentID == intentID }
  }

  public static func isAllowlisted(method: String, path: String, intentID: String) -> Bool {
    entry(method: method, path: path, intentID: intentID) != nil
  }
}
