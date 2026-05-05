import Foundation

enum BuildInfo {
  static var commit: String {
    value(for: "LABANBuildCommit", fallback: "dev")
  }

  static var date: String {
    value(for: "LABANBuildDate", fallback: "unknown")
  }

  static var summary: String {
    "laban \(commit) (\(date))"
  }

  private static func value(for key: String, fallback: String) -> String {
    guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
      !value.isEmpty
    else {
      return fallback
    }
    return value
  }
}
