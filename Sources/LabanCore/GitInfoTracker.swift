import Darwin
import Foundation

/// Resolves the current git branch for a working directory and caches the
/// answer keyed by cwd. Off-main, mtime-invalidated, worktree-aware.
///
/// **Why this exists.** The naive approach (spawn `git -C <cwd> branch
/// --show-current` per poll) is hundreds of milliseconds per tab. Direct
/// `.git/HEAD` reads are microseconds. We follow the same path git itself
/// does internally:
///   1. Walk up from cwd looking for `.git` (file or directory).
///   2. If `.git` is a directory → HEAD lives at `.git/HEAD`.
///   3. If `.git` is a regular file (worktree / submodule) → it contains a
///      `gitdir: <path>` pointer; HEAD lives at `<path>/HEAD`.
///   4. Parse HEAD: `ref: refs/heads/<name>` for a normal branch, otherwise
///      first 7 chars of the SHA for detached HEAD.
///
/// **Refresh policy.** Each `refresh(cwd:)` call hops to a utility queue,
/// stats HEAD (single syscall), and only re-reads when the mtime moved.
/// `git checkout`, `switch`, `reset`, `pull` all touch HEAD's mtime, so
/// branch updates are picked up within one polling cycle without ever
/// re-reading the file unless something actually changed.
public final class GitInfoTracker: @unchecked Sendable {

  public init() {}

  public typealias Completion = @Sendable (_ cwd: String, _ branch: String?) -> Void

  private struct CacheEntry {
    /// Resolved absolute path to the HEAD file. nil means "this cwd has no
    /// git context" — we cache the negative answer to avoid re-walking the
    /// filesystem on every poll for tabs in non-repo directories.
    var headPath: String?
    /// HEAD mtime as seen on the last successful read. 0 means never read.
    var lastMtime: TimeInterval = 0
    /// Last parsed branch (or short SHA for detached HEAD).
    var branch: String?
  }

  // Mutated only on `queue`. The class is marked @unchecked Sendable
  // because the actor-style serialisation is queue-based, not value-based.
  private let queue = DispatchQueue(label: "laban.git-info", qos: .utility)
  private var byCwd: [String: CacheEntry] = [:]

  /// Resolve the branch for `cwd`. Calls `completion` on the main queue with
  /// either the new branch or nil (no repo / detached HEAD with no SHA).
  /// Safe to call every poll cycle — when the cache is warm and HEAD's
  /// mtime hasn't moved, this is a single stat() syscall.
  public func refresh(cwd: String, completion: @escaping Completion) {
    queue.async { [weak self] in
      guard let self else { return }
      let branch = self.compute(cwd: cwd)
      DispatchQueue.main.async { completion(cwd, branch) }
    }
  }

  /// Drop the cached entry for `cwd`. Call when a session is closed so the
  /// cache doesn't grow unboundedly across the lifetime of the app.
  public func forget(cwd: String) {
    queue.async { [weak self] in self?.byCwd.removeValue(forKey: cwd) }
  }

  // MARK: Implementation (queue-only)

  private func compute(cwd: String) -> String? {
    var entry = byCwd[cwd] ?? CacheEntry()

    // First-time encounter: walk up from cwd to find .git. Cached forever
    // for this cwd unless filesystem layout changes (unusual mid-session).
    if entry.headPath == nil {
      entry.headPath = Self.locateHEAD(startingAt: cwd)
    }
    guard let headPath = entry.headPath else {
      byCwd[cwd] = entry
      return nil
    }

    // Cheap mtime probe — only re-read the file if it actually changed.
    var st = stat()
    if stat(headPath, &st) != 0 {
      // HEAD vanished (rm -rf .git, branch deleted, worktree removed).
      // Nuke the cache and force re-walk on next call.
      byCwd[cwd] = CacheEntry()
      return nil
    }
    let mtime =
      TimeInterval(st.st_mtimespec.tv_sec)
      + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000
    if mtime != entry.lastMtime {
      entry.lastMtime = mtime
      entry.branch = Self.parseHEAD(at: headPath)
    }
    byCwd[cwd] = entry
    return entry.branch
  }

  private static func locateHEAD(startingAt cwd: String) -> String? {
    var dir = (cwd as NSString).standardizingPath
    let fm = FileManager.default
    while dir != "/", !dir.isEmpty {
      let dotGit = (dir as NSString).appendingPathComponent(".git")
      var isDir: ObjCBool = false
      if fm.fileExists(atPath: dotGit, isDirectory: &isDir) {
        if isDir.boolValue {
          return (dotGit as NSString).appendingPathComponent("HEAD")
        }
        // Regular file → worktree or submodule. Contents look like:
        //   gitdir: /abs/path/to/.git/worktrees/foo
        //   gitdir: ../path  (relative — resolve against the .git's parent)
        if let raw = try? String(contentsOfFile: dotGit, encoding: .utf8) {
          for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("gitdir:") else { continue }
            let target = trimmed
              .dropFirst("gitdir:".count)
              .trimmingCharacters(in: .whitespaces)
            let absolute: String
            if (target as NSString).isAbsolutePath {
              absolute = target
            } else {
              absolute = (dir as NSString).appendingPathComponent(target)
            }
            return (absolute as NSString)
              .standardizingPath
              .appending("/HEAD")
          }
        }
      }
      let parent = (dir as NSString).deletingLastPathComponent
      if parent == dir { break }
      dir = parent
    }
    return nil
  }

  private static func parseHEAD(at path: String) -> String? {
    guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = "ref: refs/heads/"
    if trimmed.hasPrefix(prefix) {
      let name = String(trimmed.dropFirst(prefix.count))
      return name.isEmpty ? nil : name
    }
    // Detached HEAD: file contains a 40-char SHA. Surface the short form
    // so the user can at least see *something* identifying.
    if trimmed.count >= 7,
      trimmed.allSatisfy({ $0.isHexDigit })
    {
      return String(trimmed.prefix(7))
    }
    return nil
  }
}
