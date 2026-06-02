import Foundation

/// Resolves a terminal token that looks like a git commit hash to a Quick Look
/// preview of `git show` for that commit, run against the session's repository.
///
/// Detection is only a cheap lexical gate; the real test is whether `git`
/// confirms the token names a commit object, so a bare hex string that isn't a
/// commit falls through (the caller then tries file resolution). All `git`
/// invocations go through an injectable `runGit` so the logic is unit-testable
/// without a real repository, and arguments are always passed as argv — never
/// interpolated into a shell string.
enum TerminalGitLookup {
  /// Result of running git: process exit status and captured stdout.
  typealias GitResult = (status: Int32, stdout: String)

  /// If `token` is a commit hash that resolves in the repo at
  /// `workingDirectory`, render `git show` to a temp file and return its URL.
  /// Returns nil for a non-candidate token, a missing/empty cwd, a token that
  /// isn't a commit, or a git/IO failure. Runs `git` synchronously — call it
  /// off the main actor.
  static func commitPreviewURL(
    for token: String,
    workingDirectory: String?,
    runGit: (_ args: [String], _ cwd: String) -> GitResult? = TerminalGitLookup.runGit,
    writeTempFile: (_ name: String, _ contents: String) -> URL? = TerminalGitLookup.writeTempFile
  ) -> URL? {
    let sha = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard isCommitHashCandidate(sha) else { return nil }
    guard let cwd = workingDirectory, !cwd.isEmpty else { return nil }

    // Confirm it's actually a commit object — not just any hex string.
    guard let type = runGit(["cat-file", "-t", sha], cwd),
      type.status == 0,
      type.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "commit"
    else { return nil }

    guard let show = runGit(["show", "--no-color", "--stat", "--patch", sha], cwd),
      show.status == 0, !show.stdout.isEmpty
    else { return nil }

    return writeTempFile("commit-\(sha).diff", show.stdout)
  }

  /// Cheap lexical gate: 7–40 lowercase hex digits, the shape of an
  /// (abbreviated or full) SHA-1/SHA-256 object name as git prints it.
  static func isCommitHashCandidate(_ token: String) -> Bool {
    let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard t.count >= 7, t.count <= 64 else { return false }
    return t.allSatisfy { "0123456789abcdef".contains($0) }
  }

  // MARK: Defaults

  static func runGit(_ args: [String], _ cwd: String) -> GitResult? {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/git")
    process.arguments = ["-C", cwd] + args
    let stdout = Pipe()
    process.standardOutput = stdout
    // Discard stderr to a sink so a chatty git can't deadlock on a full pipe.
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return nil
    }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  /// 1 MiB cap so a giant commit can't write an enormous temp file.
  private static let maxPreviewBytes = 1_048_576

  static func writeTempFile(_ name: String, _ contents: String) -> URL? {
    let safeName = name.replacingOccurrences(of: "/", with: "_")
    let dir = FileManager.default.temporaryDirectory
      .appending(path: "laban-git", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appending(path: safeName, directoryHint: .notDirectory)
    let capped =
      contents.utf8.count > maxPreviewBytes
      ? String(contents.prefix(maxPreviewBytes)) + "\n…(truncated)\n"
      : contents
    do {
      try capped.write(to: url, atomically: true, encoding: .utf8)
    } catch {
      return nil
    }
    return url
  }
}
