import Foundation

enum BuildInfo {
  static var version: String {
    value(for: "CFBundleShortVersionString", fallback: "0.0.0")
  }

  static var commit: String {
    value(for: "LABANBuildCommit", fallback: "dev")
  }

  static var date: String {
    value(for: "LABANBuildDate", fallback: "unknown")
  }

  static var summary: String {
    "laban \(version) \(commit) (\(date))"
  }

  /// The build timestamp parsed back into a `Date`, or `nil` when the stamp
  /// is missing (`dev` builds) or unparseable.
  static var buildDate: Date? {
    isoFormatter.date(from: date)
  }

  /// How long ago this build was stamped, e.g.
  /// "3 days, 4 hours, 12 minutes, 7 seconds ago", measured against `now`
  /// (the moment the About panel is opened). `nil` when the build has no
  /// parseable timestamp.
  static func ageDescription(now: Date = Date()) -> String? {
    guard let built = buildDate else { return nil }
    return relativeAge(seconds: now.timeIntervalSince(built))
  }

  /// Pure formatter shared with tests: renders a positive interval as the
  /// full day/hour/minute/second breakdown. Clock skew (a build that claims
  /// to be in the future) clamps to zero rather than printing negatives.
  static func relativeAge(seconds interval: TimeInterval) -> String {
    let total = max(0, Int(interval.rounded()))
    let days = total / 86_400
    let hours = (total % 86_400) / 3_600
    let minutes = (total % 3_600) / 60
    let seconds = total % 60
    func unit(_ value: Int, _ name: String) -> String {
      "\(value) \(name)\(value == 1 ? "" : "s")"
    }
    let parts = [
      unit(days, "day"), unit(hours, "hour"), unit(minutes, "minute"),
      unit(seconds, "second"),
    ]
    return parts.joined(separator: ", ") + " ago"
  }

  private static let isoFormatter = ISO8601DateFormatter()

  private static func value(for key: String, fallback: String) -> String {
    guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
      !value.isEmpty
    else {
      return fallback
    }
    return value
  }
}
