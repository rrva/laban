import Foundation

/// Resolves a terminal token (a selected string, or the word under a Quick Look
/// gesture) to a previewable file URL. Kept free of AppKit so the resolution
/// rules are unit-testable; the file-existence check is injectable.
enum TerminalQuickLook {
  /// Resolve `candidate` to an existing file URL suitable for Quick Look:
  /// - strips a matched pair of surrounding quotes,
  /// - accepts `file://` URLs,
  /// - expands a leading `~`,
  /// - resolves a relative path against `workingDirectory` (the session's OSC 7
  ///   / process-metadata cwd).
  ///
  /// Returns nil when the candidate is empty or does not name an existing file
  /// or directory. Quick Look only previews files, so a bare word or a non-file
  /// URL (a web link) intentionally resolves to nil here.
  static func fileURL(
    for candidate: String,
    workingDirectory: String?,
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
  ) -> URL? {
    var token = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    if token.count >= 2, let first = token.first, let last = token.last,
      first == last, first == "\"" || first == "'"
    {
      token = String(token.dropFirst().dropLast())
    }
    guard !token.isEmpty else { return nil }

    if token.hasPrefix("file://") {
      guard let url = URL(string: token), url.isFileURL else { return nil }
      return fileExists(url.path) ? url : nil
    }

    let expanded = (token as NSString).expandingTildeInPath
    var pathsToTry: [String] = []
    if expanded.hasPrefix("/") {
      pathsToTry.append(expanded)
    } else if let cwd = workingDirectory, !cwd.isEmpty {
      pathsToTry.append((cwd as NSString).appendingPathComponent(expanded))
    }

    for path in pathsToTry where fileExists(path) {
      return URL(fileURLWithPath: path)
    }
    return nil
  }
}
