import Foundation
import Darwin
import os

/// Append-only JSON-lines event recorder. One entry per line, one file
/// per day, kept under `~/Library/Application Support/Laban/events/`.
///
/// Why this exists: OSLog is great for *live* debugging (Console.app)
/// but ephemeral — it rolls off the system log and isn't easy to bundle
/// into a bug report. This file is the persistent, easily-bundlable
/// record. Send Diagnostics tars these up with the last few stall
/// captures and ships them as one file the user can drop into Slack.
///
/// Entry shape: a single flat JSON object per line. `ts` is ISO-8601
/// milliseconds, `kind` is the event type, everything else is payload
/// fields specific to that event. Designed to be greppable from a
/// terminal as much as machine-parseable.
final class EventLog: @unchecked Sendable {

  static let shared = EventLog()

  private let queue = DispatchQueue(label: "laban.events", qos: .utility)
  private let dirURL: URL
  private static let retainDays = 7

  private init() {
    let appSupport =
      FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first ?? URL(fileURLWithPath: NSHomeDirectory())
    self.dirURL =
      appSupport
      .appendingPathComponent("Laban")
      .appendingPathComponent("events")
    try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
  }

  /// Record one event. Payload values must be JSON-serialisable; non-
  /// serialisable values are silently dropped from the entry.
  func log(_ kind: String, _ payload: [String: Any] = [:]) {
    queue.async { [weak self] in
      self?.writeLocked(kind: kind, payload: payload)
    }
  }

  /// Snapshot the events directory URL — used by Send Diagnostics to
  /// bundle the last N days into a tarball.
  var directoryURL: URL { dirURL }

  /// Drop files older than `retainDays` from the events directory.
  /// Called on launch.
  func pruneOldFiles() {
    queue.async { [weak self] in
      guard let self else { return }
      let fm = FileManager.default
      let cutoff = Date().addingTimeInterval(-Double(Self.retainDays * 86400))
      guard
        let entries = try? fm.contentsOfDirectory(
          at: self.dirURL, includingPropertiesForKeys: [.contentModificationDateKey])
      else { return }
      for url in entries {
        let mtime =
          (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? Date()
        if mtime < cutoff { try? fm.removeItem(at: url) }
      }
    }
  }

  // MARK: Implementation (queue-only)

  private func writeLocked(kind: String, payload: [String: Any]) {
    let now = Date()
    var entry: [String: Any] = [
      "ts": Self.isoMs(now),
      "kind": kind,
    ]
    for (k, v) in payload where JSONSerialization.isValidJSONObject([k: v]) {
      entry[k] = v
    }
    guard let data = try? JSONSerialization.data(withJSONObject: entry, options: []) else {
      return
    }
    var line = data
    line.append(0x0A)  // "\n"
    let url = dirURL.appendingPathComponent("\(Self.dayString(now)).jsonl")
    Self.appendAtomically(line, to: url)
  }

  private static func appendAtomically(_ data: Data, to url: URL) {
    url.path.withCString { path in
      let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
      guard fd >= 0 else { return }
      defer { close(fd) }
      data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        var written = 0
        while written < rawBuffer.count {
          let result = write(fd, base.advanced(by: written), rawBuffer.count - written)
          guard result > 0 else { return }
          written += result
        }
      }
    }
  }

  private static let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
  private static func isoMs(_ d: Date) -> String { isoFormatter.string(from: d) }

  private static func dayString(_ d: Date) -> String {
    var t = time_t(d.timeIntervalSince1970)
    var tm = tm()
    localtime_r(&t, &tm)
    return String(
      format: "%04d-%02d-%02d",
      tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday)
  }
}
