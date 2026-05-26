import Foundation

public enum RepoFingerprint {
  public static func fingerprint(cwd rawCwd: String) -> String? {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: rawCwd, isDirectory: &isDir), isDir.boolValue else {
      return nil
    }

    var dir = (rawCwd as NSString).standardizingPath
    while dir != "/", !dir.isEmpty {
      let dotGit = (dir as NSString).appendingPathComponent(".git")
      var dotGitIsDir: ObjCBool = false
      if fm.fileExists(atPath: dotGit, isDirectory: &dotGitIsDir) {
        if dotGitIsDir.boolValue {
          return "root=\(dir);gitdir=\((dotGit as NSString).standardizingPath)"
        }
        if let raw = try? String(contentsOfFile: dotGit, encoding: .utf8) {
          for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("gitdir:") else { continue }
            let target =
              trimmed
              .dropFirst("gitdir:".count)
              .trimmingCharacters(in: .whitespaces)
            let absolute: String
            if (target as NSString).isAbsolutePath {
              absolute = target
            } else {
              absolute = (dir as NSString).appendingPathComponent(target)
            }
            return "root=\(dir);gitdir=\((absolute as NSString).standardizingPath)"
          }
        }
      }
      let parent = (dir as NSString).deletingLastPathComponent
      if parent == dir { break }
      dir = parent
    }
    return nil
  }
}
