import Foundation
import LabanCore

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
      persistable: false),
    Entry(
      cliCommand: "command.propose",
      method: "POST",
      path: "/debug/actions",
      intentID: "command.propose",
      routeID: "POST /debug/actions",
      persistable: false),
  ]

  public static func entry(cliCommand: String) -> Entry? {
    entries.first { $0.cliCommand == cliCommand }
  }

  public static func entry(method: String, path: String, intentID: String) -> Entry? {
    entries.first { $0.method == method && $0.path == path && $0.intentID == intentID }
  }

  public static func isAllowlisted(method: String, path: String, intentID: String) -> Bool {
    entry(method: method, path: path, intentID: intentID) != nil
  }
}
