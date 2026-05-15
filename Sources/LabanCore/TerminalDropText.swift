import Foundation

public enum TerminalDropText {
  public static func format(urls: [URL]) -> String {
    format(paths: urls.map(\.path))
  }

  public static func format(paths: [String]) -> String {
    let quoted =
      paths
      .filter { !$0.isEmpty }
      .map(quote)
    guard !quoted.isEmpty else { return "" }
    return quoted.joined(separator: " ") + " "
  }

  public static func quote(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
