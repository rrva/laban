import Foundation

/// Protocol the `AgentObserverHost` uses to drive snapshots — lets
/// tests substitute a recording double without subclassing
/// `AgentJSONLMirror`. Production wires the host directly to
/// `AgentJSONLMirror`.
public protocol JSONLMirroring: AnyObject {
  func track(tabId: String, jsonlPath: String)
  func untrack(tabId: String, finalSnapshot: Bool)
  func snapshotAll()
}

/// Per-tab JSONL snapshotter. Copies the agent's session JSONL to
/// `~/Library/Application Support/Laban/agent-mirror/<tab-id>.jsonl`
/// on three lifecycle events — agent exit, tab close, app quit — and
/// on a 5-minute periodic timer while the agent is observed alive.
///
/// The 5-minute timer bounds mid-session loss: Anthropic issue #54907
/// documents JSONL files disappearing after macOS reboot in some
/// setups; the periodic snapshot keeps a recoverable copy under our
/// own roof. The mirror is best-effort diagnostics only — the
/// supported restore path remains `claude --resume` /
/// `codex resume`. Auto-restore from the mirror is deferred to
/// M2.5.
public final class AgentJSONLMirror: JSONLMirroring {

  public let store: PersistenceStore
  public let periodicInterval: DispatchTimeInterval
  public let queue: DispatchQueue
  public let isEnabled: () -> Bool

  private let lock = NSLock()
  private var timersByTab: [String: DispatchSourceTimer] = [:]
  private var jsonlPathByTab: [String: String] = [:]

  public init(
    store: PersistenceStore = .shared,
    periodicInterval: DispatchTimeInterval = .seconds(300),
    queue: DispatchQueue = DispatchQueue(label: "laban.agentmirror", qos: .utility),
    isEnabled: @escaping () -> Bool = { RestoreOnLaunchSettings.isEnabled }
  ) {
    self.store = store
    self.periodicInterval = periodicInterval
    self.queue = queue
    self.isEnabled = isEnabled
  }

  /// Begin tracking `tabId` with the given JSONL path. Starts a
  /// 5-minute periodic snapshot timer. Idempotent: a second call for
  /// the same tab just updates the tracked path and resets the
  /// periodic timer.
  public func track(tabId: String, jsonlPath: String) {
    lock.lock()
    jsonlPathByTab[tabId] = jsonlPath
    timersByTab[tabId]?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + periodicInterval, repeating: periodicInterval)
    timer.setEventHandler { [weak self] in
      self?.snapshot(tabId: tabId)
    }
    timersByTab[tabId] = timer
    lock.unlock()
    timer.resume()
    snapshot(tabId: tabId)
  }

  /// Stop the periodic timer for `tabId` and perform one final
  /// snapshot. Called when the agent process exits (so we capture
  /// the final state of the conversation) and when the tab closes.
  public func untrack(tabId: String, finalSnapshot: Bool = true) {
    lock.lock()
    let timer = timersByTab.removeValue(forKey: tabId)
    let path = jsonlPathByTab[tabId]
    if !finalSnapshot {
      jsonlPathByTab.removeValue(forKey: tabId)
    }
    lock.unlock()
    timer?.cancel()
    if finalSnapshot, path != nil {
      snapshot(tabId: tabId)
    }
    lock.lock()
    if finalSnapshot {
      jsonlPathByTab.removeValue(forKey: tabId)
    }
    lock.unlock()
  }

  /// Snapshot every currently-tracked tab. Called from
  /// `applicationWillTerminate` so quit captures the final JSONL
  /// state of every active agent conversation.
  public func snapshotAll() {
    let snapshotTabs: [String] = {
      lock.lock()
      defer { lock.unlock() }
      return Array(jsonlPathByTab.keys)
    }()
    for tabId in snapshotTabs {
      snapshot(tabId: tabId)
    }
  }

  /// Copy the current JSONL state for `tabId` into the mirror
  /// directory. Atomic via `FileManager.replaceItemAt` so a partial
  /// copy never overwrites a complete prior snapshot. Skipped if the
  /// source path no longer exists (the agent removed its session
  /// file, or the JSONL path was never tracked) or when the
  /// kill-switch toggle has been flipped off mid-session — periodic
  /// ticks become no-ops as soon as the gate is closed.
  public func snapshot(tabId: String) {
    guard isEnabled() else { return }
    let sourcePath: String? = {
      lock.lock()
      defer { lock.unlock() }
      return jsonlPathByTab[tabId]
    }()
    guard let sourcePath else { return }
    let fm = FileManager.default
    let source = URL(fileURLWithPath: sourcePath)
    guard fm.fileExists(atPath: source.path) else { return }
    let dest = store.agentMirrorURL(forTabId: tabId)
    let stagingDir = dest.deletingLastPathComponent()
    do {
      try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
    } catch {
      return
    }
    let staging = stagingDir.appendingPathComponent(
      "\(dest.lastPathComponent).staging-\(UUID().uuidString)")
    do {
      if fm.fileExists(atPath: staging.path) {
        try fm.removeItem(at: staging)
      }
      try fm.copyItem(at: source, to: staging)
      if fm.fileExists(atPath: dest.path) {
        _ = try fm.replaceItemAt(dest, withItemAt: staging)
      } else {
        try fm.moveItem(at: staging, to: dest)
      }
    } catch {
      try? fm.removeItem(at: staging)
    }
  }
}
