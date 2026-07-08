import Foundation

/// POSIX single-quote escaping: wrap in single quotes and replace each inner
/// `'` with `'\''`. This safely embeds any path, including ones containing
/// spaces, quotes, or shell metacharacters.
func shellSingleQuote(_ string: String) -> String {
  "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func installShim(
  prefix: String?,
  dryRun: Bool,
  executablePath: String
) throws -> String {
  let resolvedExecutable = URL(fileURLWithPath: executablePath)
    .resolvingSymlinksInPath()
    .standardizedFileURL.path

  let prefixURL: URL
  if let prefix {
    prefixURL = URL(fileURLWithPath: prefix, isDirectory: true)
  } else {
    prefixURL = URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent(".local", isDirectory: true)
      .appendingPathComponent("bin", isDirectory: true)
  }

  let shimURL = prefixURL.appendingPathComponent("laban", isDirectory: false)
  let shimContent = """
    #!/bin/sh
    exec \(shellSingleQuote(resolvedExecutable)) "$@"
    """

  if dryRun {
    return "Would install shim: \(shimURL.path) -> \(resolvedExecutable)"
  }

  try FileManager.default.createDirectory(
    at: prefixURL,
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o755])

  try shimContent.write(to: shimURL, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes(
    [.posixPermissions: NSNumber(value: 0o755)],
    ofItemAtPath: shimURL.path)

  return "Installed shim: \(shimURL.path) -> \(resolvedExecutable)"
}
