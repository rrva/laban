import Darwin
import Foundation

/// Errors from secure discovery of the app-observe advertisement file.
public enum ControlDiscoveryError: Error, Equatable, Sendable {
  case fileNotFound
  case notRegularFile
  case symlink
  case wrongOwner
  case insecurePermissions
  case oversized(maxBytes: Int)
  case malformedJSON
  case missingField(String)
  case untrustedSocketPath
}

/// Parsed contents of `control.json`. The token is the low-stakes app-observe
/// bearer; it must still never be printed or logged outside this structure.
public struct ControlAdvertisementRecord: Equatable, Codable, Sendable {
  public var url: String
  public var token: String
  public var pid: Int
  public var runId: String

  public init(url: String, token: String, pid: Int, runId: String) {
    self.url = url
    self.token = token
    self.pid = pid
    self.runId = runId
  }
}

/// Redacted view suitable for CLI/JSON output. The token is replaced by
/// `hasAppObserveToken` so callers never accidentally serialize it.
public struct RedactedControlAdvertisement: Equatable, Codable, Sendable {
  public var path: String
  public var url: String
  public var pid: Int
  public var runId: String
  public var hasAppObserveToken: Bool

  public init(
    path: String,
    url: String,
    pid: Int,
    runId: String,
    hasAppObserveToken: Bool
  ) {
    self.path = path
    self.url = url
    self.pid = pid
    self.runId = runId
    self.hasAppObserveToken = hasAppObserveToken
  }
}

/// Secure discovery parsing for the app-observe advertisement file.
///
/// The implementation uses an open-then-`fstat` flow: it opens `control.json`
/// with `O_NOFOLLOW`, validates the opened fd (regular file, same-uid owner,
/// no group/other read or write bits, bounded size), and only then parses the
/// JSON. The advertised socket path is constrained to the trusted Laban control
/// directory so a compromised advertisement cannot redirect a same-user client
/// to an arbitrary UDS outside Laban's private directory.
public enum ControlDiscovery {
  public static let maxControlFileBytes = 64 * 1024

  /// Returns the default `control.json` URL, optionally within a specific
  /// control directory. Tests use the `directory` parameter to redirect reads.
  public static func controlFileURL(directory: URL? = nil) -> URL {
    let dir = directory ?? ControlAdvertisement.directory()
    return dir.appendingPathComponent("control.json")
  }

  /// Reads and validates `control.json`.
  ///
  /// - Parameters:
  ///   - fileURL: Optional explicit file URL. Defaults to `control.json`
  ///     inside the control directory.
  ///   - controlDirectory: Optional control directory used both to locate the
  ///     file and to validate that the advertised socket path is inside it.
  ///     Tests use this to exercise path validation in an isolated directory.
  public static func read(
    fileURL: URL? = nil,
    controlDirectory: URL? = nil
  ) throws -> ControlAdvertisementRecord {
    let directory = controlDirectory ?? ControlAdvertisement.directory()
    let url = fileURL ?? controlFileURL(directory: directory)
    let fd = try openValidatedControlFile(at: url)
    defer { Darwin.close(fd) }

    var st = stat()
    guard Darwin.fstat(fd, &st) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    try validateFileStat(&st, maxBytes: maxControlFileBytes)

    let data = try readAll(fd: fd, size: Int(st.st_size))
    return try parseRecord(from: data, controlDirectory: directory)
  }

  /// Returns a redacted view of a record for safe serialization.
  public static func redacted(
    record: ControlAdvertisementRecord,
    path: String
  ) -> RedactedControlAdvertisement {
    RedactedControlAdvertisement(
      path: path,
      url: record.url,
      pid: record.pid,
      runId: record.runId,
      hasAppObserveToken: !record.token.isEmpty)
  }

  // MARK: - Private

  private static func openValidatedControlFile(at url: URL) throws -> Int32 {
    let path = url.path

    // Reject a symlink at the final path component before opening.
    var lst = stat()
    if Darwin.lstat(path, &lst) == 0 {
      guard (lst.st_mode & S_IFMT) != S_IFLNK else {
        throw ControlDiscoveryError.symlink
      }
    } else if errno != ENOENT {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    // O_NOFOLLOW provides a second layer: if the file is replaced by a
    // symlink between lstat and open, open fails with ELOOP.
    let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else {
      switch errno {
      case ENOENT: throw ControlDiscoveryError.fileNotFound
      case ELOOP: throw ControlDiscoveryError.symlink
      default: throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    }
    try ControlFD.setCloseOnExec(fd)
    return fd
  }

  private static func validateFileStat(_ st: inout stat, maxBytes: Int) throws {
    guard (st.st_mode & S_IFMT) == S_IFREG else {
      throw ControlDiscoveryError.notRegularFile
    }
    guard st.st_uid == getuid() else {
      throw ControlDiscoveryError.wrongOwner
    }
    // Group and other must have no read or write access. We intentionally do
    // not require a specific owner mode beyond that; a same-user-only file is
    // acceptable as long as no other uid can access it.
    let groupOtherBits = st.st_mode & 0o077
    guard groupOtherBits == 0 else {
      throw ControlDiscoveryError.insecurePermissions
    }
    guard st.st_size <= maxBytes else {
      throw ControlDiscoveryError.oversized(maxBytes: maxBytes)
    }
  }

  private static func readAll(fd: Int32, size: Int) throws -> Data {
    var data = Data(count: size)
    var total = 0
    try data.withUnsafeMutableBytes { raw in
      guard let base = raw.baseAddress else { return }
      while total < size {
        let n = Darwin.read(fd, base.advanced(by: total), size - total)
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else {
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        total += n
      }
    }
    return data
  }

  private static func parseRecord(
    from data: Data,
    controlDirectory: URL
  ) throws -> ControlAdvertisementRecord {
    // Decode to a dictionary first so missing keys are distinguishable from
    // syntactically invalid JSON.
    let obj: [String: Any]
    do {
      guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ControlDiscoveryError.malformedJSON
      }
      obj = parsed
    } catch {
      throw ControlDiscoveryError.malformedJSON
    }

    guard let url = obj["url"] as? String, !url.isEmpty else {
      throw ControlDiscoveryError.missingField("url")
    }
    guard let token = obj["token"] as? String, !token.isEmpty else {
      throw ControlDiscoveryError.missingField("token")
    }
    guard let runId = obj["runId"] as? String, !runId.isEmpty else {
      throw ControlDiscoveryError.missingField("runId")
    }
    guard let pid = obj["pid"] as? Int, pid > 0 else {
      throw ControlDiscoveryError.missingField("pid")
    }
    guard trustedSocketPath(url, controlDirectory: controlDirectory) else {
      throw ControlDiscoveryError.untrustedSocketPath
    }
    return ControlAdvertisementRecord(url: url, token: token, pid: pid, runId: runId)
  }

  /// The advertised socket path must resolve to a location inside the trusted
  /// Laban control directory. This prevents a compromised or malicious
  /// `control.json` from redirecting same-user clients to an arbitrary UDS
  /// outside Laban's private directory. UDS paths outside the control directory
  /// are rejected here; any future allowance must be explicitly documented and
  /// tested with a concrete use-case.
  private static func trustedSocketPath(
    _ url: String,
    controlDirectory: URL
  ) -> Bool {
    guard !url.isEmpty else { return false }
    let socketURL = URL(fileURLWithPath: url)
    let resolvedSocket = socketURL.resolvingSymlinksInPath().standardizedFileURL.path
    let resolvedDir = controlDirectory.resolvingSymlinksInPath().standardizedFileURL.path
    guard resolvedSocket.hasPrefix(resolvedDir + "/") else { return false }
    return true
  }
}
