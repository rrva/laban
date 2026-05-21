import Foundation
import LabanCore

/// Result of `HeadlessDebugRuntime.recentCastBytes` — either the
/// encoded cast plus metadata, or an HTTP status + JSON error
/// payload the caller can return verbatim.
public enum RecentCastResult {
  case success(data: Data, tabId: String, chunks: Int, windowSeconds: TimeInterval)
  case failure(status: Int, message: String)
}

extension HeadlessDebugRuntime {
  /// Snapshot the most recent N seconds of the given tab's PTY
  /// output and encode it as an asciinema v2 cast. Mirrors the
  /// "Export Recent" menu action so agents and CI can grab a cast
  /// without driving the AppKit menu bar.
  public func recentCastBytes(seconds: TimeInterval, tabId: String?) -> RecentCastResult {
    withRuntimeLock {
      guard let host = transcriptHost else {
        return .failure(
          status: 400,
          message: "transcript host is not wired (use --persistence-dir)")
      }
      let resolvedTabId: String
      if let tabId, !tabId.isEmpty {
        resolvedTabId = tabId
      } else if let active = model.activeTab {
        resolvedTabId = active.id
      } else {
        return .failure(status: 404, message: "no active tab")
      }
      guard let ring = host.recentByteRing(forTabId: resolvedTabId) else {
        return .failure(
          status: 404,
          message: "no recent-byte ring for tab \(resolvedTabId)")
      }
      let castSnapshot = ring.castWindowSnapshot(window: seconds)
      let entries = castSnapshot.entries
      let size = model.terminalSize
      let cols = max(Int(size.cols), 1)
      let rows = max(Int(size.rows), 1)
      let initialFrameBytes = AsciinemaCast.fullFrameSnapshotBytes(
        replaying: castSnapshot.initialEntries,
        cols: cols,
        rows: rows)
      // Cast header timestamp is when the window started, not when
      // the export ran, so a player's "recorded at" string matches
      // what the user actually saw. NOTE: cols/rows reflect the
      // grid as of export — a resize mid-recording will produce a
      // slightly off-grid playback for affected frames.
      let startedAt = Date().addingTimeInterval(-seconds).timeIntervalSince1970
      do {
        let data = try AsciinemaCast.encode(
          entries: entries,
          cols: cols,
          rows: rows,
          title: resolvedTabId,
          startedAtUnixSeconds: startedAt,
          initialFrameBytes: initialFrameBytes,
          timelineBaseNanos: initialFrameBytes.isEmpty ? nil : castSnapshot.cutoffNanos)
        return .success(
          data: data,
          tabId: resolvedTabId,
          chunks: entries.count,
          windowSeconds: seconds)
      } catch {
        return .failure(status: 500, message: "cast encode failed: \(error)")
      }
    }
  }
}
