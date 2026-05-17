import Foundation
import LabanTerminalCore

/// Per-tab transcript writer registry. Owns one `TranscriptWriter`
/// per active tab, wires the C persistence callback to it, and tears
/// it down when the tab closes. The `AppModel` calls into this host
/// via the `TranscriptHostDelegate` protocol so the persistence
/// subsystem stays optional — tests and headless runs that don't need
/// transcripts can leave the delegate nil.
public final class TranscriptHost {
  public let store: PersistenceStore
  public let isEnabled: () -> Bool

  private let lock = NSLock()
  private var writersByTab: [String: TranscriptWriter] = [:]
  private var bridges: [String: Unmanaged<TranscriptWriterBridge>] = [:]

  /// - Parameter isEnabled: gate consulted by every `TranscriptWriter`
  ///   this host hands out. When false, PTY bytes still flow into the
  ///   ring buffer (memcpy-only contract preserved), but nothing
  ///   reaches disk. The kill-switch toggle wires this to
  ///   `RestoreOnLaunchSettings.isEnabled`.
  public init(
    store: PersistenceStore = .shared,
    isEnabled: @escaping () -> Bool = { RestoreOnLaunchSettings.isEnabled }
  ) {
    self.store = store
    self.isEnabled = isEnabled
  }

  /// Path the writer for `tabId` appends to. Used by the restore
  /// orchestrator to find the file to replay through libghostty
  /// BEFORE the new session starts capturing into the same file.
  public func transcriptURL(forTabId tabId: String) -> URL {
    store.transcriptURL(forTabId: tabId)
  }

  /// Attach a fresh `TranscriptWriter` to the session, wiring the C
  /// persistence callback so PTY output bytes flow into the writer's
  /// ring buffer. If a writer already exists for this tab (re-attach
  /// after restore), it is flushed and replaced — the new writer
  /// continues to append to the same `.bin` file, so the on-disk
  /// transcript carries across the restore boundary.
  ///
  /// - Parameter suppressInitialOutputFor: when non-zero, the
  ///   writer drops bytes for the given interval after attach.
  ///   Restored tabs pass ~500ms here so the new shell's spawn-time
  ///   prompt sequences don't get appended to the prior session's
  ///   `.bin` — otherwise every quit-then-restore cycle pads the
  ///   transcript with another stacked prompt that shows up on the
  ///   next restore. Fresh tabs leave this at zero so their full
  ///   initial prompt is captured.
  public func attachTranscriptWriter(
    to session: Session,
    tabId: String,
    suppressInitialOutputFor: DispatchTimeInterval = .never
  ) {
    let writer = TranscriptWriter(
      tabId: tabId,
      fileURL: transcriptURL(forTabId: tabId),
      isEnabled: isEnabled)
    if case .never = suppressInitialOutputFor {
      // No suppression.
    } else {
      writer.suppressCapture(forNext: suppressInitialOutputFor)
    }
    let bridge = TranscriptWriterBridge(writer: writer)
    lock.lock()
    let priorBridge = bridges[tabId]
    let priorWriter = writersByTab[tabId]
    writersByTab[tabId] = writer
    bridges[tabId] = Unmanaged.passRetained(bridge)
    lock.unlock()
    priorWriter?.flushSync()
    priorBridge?.release()
    let userdata = UnsafeMutableRawPointer(Unmanaged.passUnretained(bridge).toOpaque())
    _ = session.setPersistenceCallback(transcriptBridgeCallback, userdata: userdata)
  }

  /// Detach and flush the writer for `tabId`. Called from
  /// `AppModel.closeTab`. The on-disk `.bin` file is left in place so
  /// a later restore (or manual inspection) can read it.
  public func detachTranscriptWriter(forTabId tabId: String, in session: Session?) {
    lock.lock()
    let writer = writersByTab.removeValue(forKey: tabId)
    let bridge = bridges.removeValue(forKey: tabId)
    lock.unlock()
    if let session {
      _ = session.setPersistenceCallback(nil, userdata: nil)
    }
    writer?.flushSync()
    bridge?.release()
  }

  /// Replace `tabId`'s `.bin` file with a plain-text snapshot of the
  /// session's current libghostty grid (scrollback + visible).
  /// Called from `flushSync` at quit time so the persisted
  /// transcript always represents "what was on screen" rather than
  /// the raw byte stream of the session.
  ///
  /// Why this matters: prior implementations appended raw PTY bytes
  /// to the .bin during the live session. Each restore cycle
  /// captured the new shell's prompt setup (including zsh's
  /// PROMPT_SP `%` marker) as raw bytes. On the next restore those
  /// bytes replayed, painting stale prompts in scrollback that
  /// stacked across cycles. Snapshotting the rendered grid as
  /// plain text instead means every quit produces a clean
  /// idempotent file — no escape codes, no stacked prompts, no
  /// drift across restore cycles.
  ///
  /// Trade-off: color and SGR styles are lost across restart.
  /// Within a live session the user still has full fidelity (the
  /// grid is alive in libghostty); the lossy step is only the
  /// at-quit serialization.
  public func captureGridSnapshot(forTabId tabId: String, session: Session) {
    guard isEnabled() else { return }
    guard let snap = session.snapshot() else { return }
    defer { laban_snapshot_destroy(snap) }
    let text = TerminalSnapshotText.visibleText(
      from: UnsafePointer(snap),
      mode: .fullGrid)
    // Trim trailing whitespace rows so the file doesn't carry pages
    // of empty padding from libghostty's grid dimensions, then
    // re-join with CR+LF. libghostty's VT parser treats bare \n as
    // "advance to next row at current column" (LF) but does NOT
    // return to column 0. Without a CR, the second row's text
    // ends up indented by the prior row's column position, which
    // produces visibly mangled scrollback on replay.
    let nonEmptyRows = text
      .split(separator: "\n", omittingEmptySubsequences: false)
      .reversed()
      .drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
      .reversed()
      .map(String.init)
    // Ensure trailing CR+LF so the live shell starts on a fresh
    // row with no PROMPT_SP firing.
    let body = nonEmptyRows.isEmpty ? "" : nonEmptyRows.joined(separator: "\r\n") + "\r\n"
    let url = transcriptURL(forTabId: tabId)
    let dir = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(
      at: dir, withIntermediateDirectories: true)
    let staging = dir.appendingPathComponent(
      "\(url.lastPathComponent).snapshot-\(UUID().uuidString)")
    do {
      try body.data(using: .utf8)?.write(to: staging, options: .atomic)
      if FileManager.default.fileExists(atPath: url.path) {
        _ = try FileManager.default.replaceItemAt(url, withItemAt: staging)
      } else {
        try FileManager.default.moveItem(at: staging, to: url)
      }
    } catch {
      try? FileManager.default.removeItem(at: staging)
    }
  }

  /// Flush every writer the host currently owns. Called from
  /// `applicationWillTerminate` so quit does not lose the last few
  /// hundred ms of PTY output queued in the ring buffers.
  public func flushAll() {
    let snapshot: [TranscriptWriter] = {
      lock.lock()
      defer { lock.unlock() }
      return Array(writersByTab.values)
    }()
    for writer in snapshot {
      writer.flushSync()
    }
  }

  /// Test/diagnostic accessor — returns the writer for a tab, if any.
  public func writer(forTabId tabId: String) -> TranscriptWriter? {
    lock.lock()
    defer { lock.unlock() }
    return writersByTab[tabId]
  }
}

/// Pinned wrapper around a `TranscriptWriter` so the C callback's
/// userdata can be an `UnsafeMutableRawPointer` pointing at a stable
/// Swift object. `TranscriptHost` owns the lifetime via the
/// `Unmanaged<TranscriptWriterBridge>` table.
final class TranscriptWriterBridge {
  let writer: TranscriptWriter
  init(writer: TranscriptWriter) { self.writer = writer }
}

/// The C entry point. Memcpy-only by contract — see ExecPlan Decision
/// Log on PTY-byte-callback IO discipline.
private let transcriptBridgeCallback:
  @convention(c) (
    UnsafeMutableRawPointer?,
    OpaquePointer?,
    UnsafePointer<UInt8>?,
    Int
  ) -> Void = { userdata, _, bytes, len in
    guard let userdata, let bytes, len > 0 else { return }
    let bridge = Unmanaged<TranscriptWriterBridge>.fromOpaque(userdata).takeUnretainedValue()
    bridge.writer.writeChunk(bytes: bytes, count: len)
  }

public protocol TranscriptHostDelegate: AnyObject {
  func attachTranscriptWriter(
    to session: Session,
    tabId: String,
    suppressInitialOutputFor: DispatchTimeInterval)
  func detachTranscriptWriter(forTabId tabId: String, in session: Session?)
  func transcriptURL(forTabId tabId: String) -> URL
}

extension TranscriptHostDelegate {
  /// Convenience: fresh-tab attach (no suppression).
  public func attachTranscriptWriter(to session: Session, tabId: String) {
    attachTranscriptWriter(
      to: session, tabId: tabId, suppressInitialOutputFor: .never)
  }
}

extension TranscriptHost: TranscriptHostDelegate {}
