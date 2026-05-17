import Foundation

/// Observes AppModel changes and writes `workspace.json` through
/// `PersistenceStore` on a 200ms debounce. The coordinator is the single
/// entry point the rest of the app uses to keep on-disk state in sync;
/// it owns the queue, the timer, and the gating through
/// `RestoreOnLaunchSettings.isEnabled`.
///
/// Lifecycle:
///   - `attach(_:)` registers as the model's `onWorkspaceMutation`
///     subscriber. Subsequent mutations call `scheduleSave()`.
///   - `flushSync()` is called from `applicationWillTerminate` so quit
///     drains any in-flight debounce.
///   - `detach()` clears the subscription so the model can be torn down.
public final class PersistenceCoordinator {

  public let store: PersistenceStore
  public let windowId: String

  /// Per-tab transcript writer registry. Optional so headless test
  /// configurations can leave it nil and skip the transcript path.
  public var transcriptHost: TranscriptHost?

  private weak var model: AppModel?

  private let queue: DispatchQueue
  private let debounceInterval: DispatchTimeInterval
  private let isEnabled: () -> Bool

  private let lock = NSLock()
  private var pendingTimer: DispatchSourceTimer?

  public init(
    store: PersistenceStore = .shared,
    windowId: String = "main-window",
    debounceInterval: DispatchTimeInterval = .milliseconds(200),
    isEnabled: @escaping () -> Bool = { RestoreOnLaunchSettings.isEnabled }
  ) {
    self.store = store
    self.windowId = windowId
    self.debounceInterval = debounceInterval
    self.isEnabled = isEnabled
    self.queue = DispatchQueue(label: "laban.persistence", qos: .utility)
  }

  /// Wire the coordinator into the model. The model fires
  /// `onWorkspaceMutation` after each lock-protected mutation; the
  /// coordinator debounces those into one save per 200ms.
  public func attach(_ model: AppModel) {
    self.model = model
    model.onWorkspaceMutation = { [weak self] in
      self?.scheduleSave()
    }
  }

  public func detach() {
    model?.onWorkspaceMutation = nil
    model = nil
    cancelPending()
  }

  /// Snapshot the model under its own lock and schedule a debounced save.
  /// Safe to call from any thread. No-op when the toggle is off.
  public func scheduleSave() {
    guard isEnabled() else {
      cancelPending()
      return
    }
    lock.lock()
    pendingTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + debounceInterval)
    timer.setEventHandler { [weak self] in
      self?.performSave()
    }
    pendingTimer = timer
    lock.unlock()
    timer.resume()
  }

  /// Load the most-recent `WorkspaceState` from disk through the
  /// underlying `PersistenceStore`. Returns nil when the toggle is off
  /// (so the launch path treats it as "nothing to restore" and starts
  /// fresh), when no workspace file exists, or when the file is
  /// corrupt. Both `save(_:)` and `load()` go through this coordinator
  /// — never call `PersistenceStore.load()` from launch paths directly,
  /// or the kill switch will be bypassed.
  public func load() -> WorkspaceState? {
    guard isEnabled() else { return nil }
    return store.load()
  }

  /// Drain any pending debounce immediately. Called from
  /// `applicationWillTerminate` so quit does not lose the last few
  /// hundred milliseconds of state. No-op when the toggle is off.
  public func flushSync() {
    guard isEnabled() else {
      cancelPending()
      return
    }
    cancelPending()
    // Hop to the persistence queue synchronously so save() and the
    // calling thread see a happens-before relationship.
    queue.sync {
      self.performSave()
    }
    // Drain any in-flight ring buffer state FIRST so the writers
    // are quiescent before we replace their files. If we
    // snapshotted before flushing, the subsequent drain would
    // append the just-flushed bytes AFTER the snapshot, doubling
    // the content on disk.
    transcriptHost?.flushAll()
    // Replace every live tab's transcript file with a plain-text
    // snapshot of its current libghostty grid. This is the source
    // of truth for "what should the user see on next restore" —
    // not the raw byte stream from this session. Without this
    // step, each restore cycle accumulates the new shell's
    // startup prompts in the .bin file, eventually painting
    // stacked ghost prompts in the next restore's scrollback.
    if let model, let host = transcriptHost {
      for (tab, session) in model.allSessions() {
        host.captureGridSnapshot(forTabId: tab.id, session: session)
      }
    }
  }

  private func cancelPending() {
    lock.lock()
    pendingTimer?.cancel()
    pendingTimer = nil
    lock.unlock()
  }

  private func performSave() {
    guard isEnabled() else { return }
    guard let model = self.model else { return }
    let state = model.snapshotForPersistence(windowId: windowId)
    do {
      try store.save(state)
    } catch {
      // Saves fail silently — the next debounce tick retries. We do not
      // surface persistence errors to the user; the toggle is the only
      // user-facing affordance for the subsystem.
    }
  }
}
