import Foundation
import os

/// Centralized log handles. Each call writes to BOTH:
///
///   1. Apple's unified logging system (`os_log` / `Logger`) — visible
///      in Console.app live and queryable via the `log show` CLI when
///      the user has appropriate privileges.
///
///   2. A rolling text file at `~/Library/Application Support/Laban/log/`.
///      This is the canonical record we bundle into Send Diagnostics:
///      OSLogStore reads its own process's logs only with an
///      entitlement we don't carry, and `log show` needs admin to read
///      the local-log-store from a regular user. A plain text file
///      sidesteps both — every reader can `cat` it.
///
/// Both are kept because they serve different needs: OSLog for live
/// development under Console, plain file for retrievable bug reports
/// from any user setup.
enum AppLog {
  static let subsystem = "com.rrva.laban"

  static let app = Channel(category: "app")
  static let watchdog = Channel(category: "watchdog")
  static let render = Channel(category: "render")
  static let capture = Channel(category: "capture")

  /// Wraps an `os.Logger` with mirroring to disk. The methods mirror
  /// `Logger`'s common levels with String-only payloads (no String
  /// interpolation tricks) — the file path doesn't need privacy
  /// markers because we control what goes in.
  struct Channel {
    let category: String
    private let logger: Logger
    init(category: String) {
      self.category = category
      self.logger = Logger(subsystem: AppLog.subsystem, category: category)
    }
    func debug(_ message: String) {
      logger.debug("\(message, privacy: .public)")
      LogFile.shared.append(level: "D", category: category, message: message)
    }
    func info(_ message: String) {
      logger.info("\(message, privacy: .public)")
      LogFile.shared.append(level: "I", category: category, message: message)
    }
    func notice(_ message: String) {
      logger.notice("\(message, privacy: .public)")
      LogFile.shared.append(level: "N", category: category, message: message)
    }
    func error(_ message: String) {
      logger.error("\(message, privacy: .public)")
      LogFile.shared.append(level: "E", category: category, message: message)
    }
  }
}

/// Plain-text rolling log file. One file per day under `~/Library/
/// Application Support/Laban/log/YYYY-MM-DD.log`, kept for 7 days.
final class LogFile: @unchecked Sendable {
  static let shared = LogFile()

  private let queue = DispatchQueue(label: "laban.logfile", qos: .utility)
  private let dirURL: URL
  private var currentDate: String = ""
  private var currentHandle: FileHandle?
  private static let retainDays = 7

  private init() {
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first ?? URL(fileURLWithPath: NSHomeDirectory())
    self.dirURL = appSupport
      .appendingPathComponent("Laban")
      .appendingPathComponent("log")
    try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
  }

  var directoryURL: URL { dirURL }

  func append(level: String, category: String, message: String) {
    queue.async { [weak self] in
      self?.writeLocked(level: level, category: category, message: message)
    }
  }

  func pruneOldFiles() {
    queue.async { [weak self] in
      guard let self else { return }
      let fm = FileManager.default
      let cutoff = Date().addingTimeInterval(-Double(Self.retainDays * 86400))
      guard let entries = try? fm.contentsOfDirectory(
        at: self.dirURL, includingPropertiesForKeys: [.contentModificationDateKey])
      else { return }
      for url in entries {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate) ?? Date()
        if mtime < cutoff { try? fm.removeItem(at: url) }
      }
    }
  }

  private func writeLocked(level: String, category: String, message: String) {
    let now = Date()
    let day = Self.dayString(now)
    if day != currentDate {
      currentDate = day
      try? currentHandle?.close()
      currentHandle = nil
      let url = dirURL.appendingPathComponent("\(day).log")
      if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
      }
      currentHandle = try? FileHandle(forWritingTo: url)
      try? currentHandle?.seekToEnd()
    }
    let line = "\(Self.tsString(now)) \(level) [\(category)] \(message)\n"
    if let data = line.data(using: .utf8) {
      try? currentHandle?.write(contentsOf: data)
    }
  }

  private static let tsFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
  private static func tsString(_ d: Date) -> String { tsFormatter.string(from: d) }

  private static func dayString(_ d: Date) -> String {
    var t = time_t(d.timeIntervalSince1970)
    var tm = tm()
    localtime_r(&t, &tm)
    return String(
      format: "%04d-%02d-%02d",
      tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday)
  }
}
