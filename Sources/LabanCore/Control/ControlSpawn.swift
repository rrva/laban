import Foundation

/// Where a control-plane spawn puts its new terminal: a new tab, or a split of
/// the caller's own pane. See ADR 0024, Amendment (2026-11-26).
public enum ControlSpawnPlacement: String, Codable, Sendable, Equatable {
  case tab
  case right
  case down

  /// The pane-tree axis for a split placement; nil for a new tab.
  public var paneAxis: PaneAxis? {
    switch self {
    case .tab: return nil
    case .right: return .vertical
    case .down: return .horizontal
    }
  }
}

/// `session.spawnTab` / `session.spawnSplit` request body (`POST /debug/actions`
/// with action `spawnTab` or `spawnSplit`). An empty or absent `argv` opens the
/// user's login shell; otherwise `argv[0]` is the executable.
public struct ControlSpawnRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var action: String?
  public var argv: [String]?
  public var cwd: String?
  public var label: String?
  public var focus: Bool?
  /// `spawnSplit` only: `right` (side by side) or `down` (stacked). Default `right`.
  public var direction: String?

  public init(
    action: String?,
    argv: [String]? = nil,
    cwd: String? = nil,
    label: String? = nil,
    focus: Bool? = nil,
    direction: String? = nil
  ) {
    self.action = action
    self.argv = argv
    self.cwd = cwd
    self.label = label
    self.focus = focus
    self.direction = direction
  }

  public static var jsonSchema: SchemaNode {
    .object(
      properties: [
        "action": .string(
          enumValues: ["spawnTab", "spawnSplit"], const: nil, format: nil, pattern: nil),
        "argv": .array(
          .string(enumValues: nil, const: nil, format: nil, pattern: nil), minItems: 0),
        "cwd": .string(enumValues: nil, const: nil, format: nil, pattern: nil),
        "label": .string(enumValues: nil, const: nil, format: nil, pattern: nil),
        "focus": .boolean,
        "direction": .string(enumValues: ["right", "down"], const: nil, format: nil, pattern: nil),
      ],
      required: ["action"],
      additionalProperties: false)
  }
}

public struct ControlSpawnResponse: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var ok: Bool
  public var tabID: String
  public var sessionID: String
  public var placement: String

  public init(tabID: String, sessionID: String, placement: ControlSpawnPlacement) {
    self.ok = true
    self.tabID = tabID
    self.sessionID = sessionID
    self.placement = placement.rawValue
  }

  public static var jsonSchema: SchemaNode {
    .object(
      properties: [
        "ok": .boolean,
        "tabID": .string(enumValues: nil, const: nil, format: nil, pattern: nil),
        "sessionID": .string(enumValues: nil, const: nil, format: nil, pattern: nil),
        "placement": .string(
          enumValues: ["tab", "right", "down"], const: nil, format: nil, pattern: nil),
      ],
      required: ["ok", "tabID", "sessionID", "placement"],
      additionalProperties: false)
  }
}

/// A validated spawn request: what the router hands to the window.
public struct ControlSpawnPlan: Sendable, Equatable {
  public var placement: ControlSpawnPlacement
  /// Empty means the login shell.
  public var argv: [String]
  public var cwd: String?
  public var label: String?
  public var focus: Bool
  /// The pane a split divides: always the caller's own session when scoped.
  public var anchorSessionID: String?
}

public enum ControlSpawnRouting {
  public static let maxArgvCount = 256
  public static let maxArgvBytes = 64 * 1024
  public static let maxLabelBytes = 128
  public static let maxCwdBytes = 4096

  public struct Rejection: Error, Equatable, Sendable {
    public let status: Int
    public let reason: String
  }

  /// Validates a spawn body. A scoped caller (session token or lazy attach)
  /// splits only its own pane; an unscoped fixture caller splits the active
  /// pane. `directoryExists` is injected so tests need no filesystem.
  public static func plan(
    intentID: String,
    body: Data,
    scopedSessionID: String?,
    activeSessionID: String?,
    directoryExists: (String) -> Bool = ControlSpawnRouting.isDirectory
  ) -> Result<ControlSpawnPlan, Rejection> {
    guard let request = try? JSONDecoder().decode(ControlSpawnRequest.self, from: body) else {
      return .failure(Rejection(status: 400, reason: "bad request"))
    }
    let placement: ControlSpawnPlacement
    switch intentID {
    case "session.spawnTab":
      guard request.direction == nil else {
        return .failure(Rejection(status: 400, reason: "direction applies to spawnSplit only"))
      }
      placement = .tab
    case "session.spawnSplit":
      switch request.direction ?? "right" {
      case "right": placement = .right
      case "down": placement = .down
      default: return .failure(Rejection(status: 400, reason: "direction must be right or down"))
      }
    default:
      return .failure(Rejection(status: 400, reason: "unsupported action"))
    }

    let argv = request.argv ?? []
    guard argv.count <= maxArgvCount,
      argv.reduce(0, { $0 + $1.utf8.count + 1 }) <= maxArgvBytes
    else {
      return .failure(Rejection(status: 413, reason: "argv too large"))
    }
    if let first = argv.first, first.isEmpty {
      return .failure(Rejection(status: 400, reason: "argv[0] is empty"))
    }
    guard !argv.contains(where: { $0.utf8.contains(0) }) else {
      return .failure(Rejection(status: 400, reason: "argv contains NUL"))
    }

    var cwd: String?
    if let raw = request.cwd {
      guard raw.utf8.count <= maxCwdBytes, raw.hasPrefix("/"), !raw.utf8.contains(0) else {
        return .failure(Rejection(status: 400, reason: "cwd must be an absolute path"))
      }
      guard directoryExists(raw) else {
        return .failure(Rejection(status: 400, reason: "cwd is not a directory"))
      }
      cwd = raw
    }

    var label: String?
    if let raw = request.label {
      guard raw.utf8.count <= maxLabelBytes else {
        return .failure(Rejection(status: 413, reason: "label too large"))
      }
      guard !containsUnsafeScalar(raw) else {
        return .failure(Rejection(status: 400, reason: "label contains control characters"))
      }
      let trimmed = raw.trimmingCharacters(in: .whitespaces)
      label = trimmed.isEmpty ? nil : trimmed
    }

    let anchor: String?
    if placement == .tab {
      anchor = scopedSessionID
    } else {
      guard let resolved = scopedSessionID ?? activeSessionID else {
        return .failure(Rejection(status: 400, reason: "no session to split"))
      }
      anchor = resolved
    }

    return .success(
      ControlSpawnPlan(
        placement: placement,
        argv: argv,
        cwd: cwd,
        label: label,
        focus: request.focus ?? true,
        anchorSessionID: anchor))
  }

  /// Control characters and invisible formatting characters (bidi overrides,
  /// zero-width joiners) are refused so a label cannot spoof the sidebar.
  public static func containsUnsafeScalar(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
      scalar.properties.generalCategory == .control
        || scalar.properties.generalCategory == .format
        || scalar.properties.generalCategory == .lineSeparator
        || scalar.properties.generalCategory == .paragraphSeparator
    }
  }

  public static func isDirectory(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  /// The notice shown on the new tab so the user can tell a program opened it.
  public static func noticeText(argv: [String]) -> String {
    var what = argv.first.map { ($0 as NSString).lastPathComponent } ?? "shell"
    if containsUnsafeScalar(what) || what.utf8.count > maxLabelBytes { what = "command" }
    return "Opened by a program: \(what)"
  }
}

/// Caps how fast control-plane callers can open terminals, so a runaway
/// script cannot flood the window with tabs. App-wide, sliding window.
public struct ControlSpawnRateLimiter: Sendable {
  public static let window: TimeInterval = 10
  public static let limit = 20

  private var admitted: [Date] = []

  public init() {}

  public mutating func admit(now: Date = Date()) -> Bool {
    admitted.removeAll { now.timeIntervalSince($0) >= Self.window }
    guard admitted.count < Self.limit else { return false }
    admitted.append(now)
    return true
  }
}
