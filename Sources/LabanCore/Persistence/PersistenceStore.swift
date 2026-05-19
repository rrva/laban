import Foundation

public enum PersistenceStoreError: Error {
  case encodeFailed(Error)
  case writeFailed(Error)
  case archiveFailed(Error)
}

/// Owns the on-disk persistence directory layout under
/// `~/Library/Application Support/Laban/` (or any caller-provided base
/// URL for tests). Reads and writes are synchronous and atomic; the
/// `PersistenceCoordinator` is the only producer in normal operation
/// and queues calls onto a background queue to avoid blocking callers.
public final class PersistenceStore {

  public static let shared = PersistenceStore()

  public let baseURL: URL
  public let workspaceURL: URL
  public let previousURL: URL
  public let transcriptsURL: URL
  public let agentMirrorURL: URL

  private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()

  private let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()

  public convenience init() {
    let base = PersistenceStore.defaultBaseURL()
    self.init(baseURL: base)
  }

  public init(baseURL: URL) {
    self.baseURL = baseURL
    self.workspaceURL = baseURL.appendingPathComponent("workspace.json", isDirectory: false)
    self.previousURL = baseURL.appendingPathComponent(
      "workspace.json.previous", isDirectory: false)
    self.transcriptsURL = baseURL.appendingPathComponent("transcripts", isDirectory: true)
    self.agentMirrorURL = baseURL.appendingPathComponent("agent-mirror", isDirectory: true)
  }

  /// Default base URL is `~/Library/Application Support/Laban/`. The
  /// Application Support directory is created on demand; callers should
  /// not rely on its prior existence.
  public static func defaultBaseURL() -> URL {
    let fm = FileManager.default
    let support: URL
    do {
      support = try fm.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
    } catch {
      support = fm.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support", isDirectory: true)
    }
    return support.appendingPathComponent("Laban", isDirectory: true)
  }

  /// Ensure the persistence directory layout exists. Safe to call on
  /// every save; FileManager treats existing directories as success.
  public func ensureDirectories() throws {
    let fm = FileManager.default
    try fm.createDirectory(at: baseURL, withIntermediateDirectories: true)
    try fm.createDirectory(at: transcriptsURL, withIntermediateDirectories: true)
    try fm.createDirectory(at: agentMirrorURL, withIntermediateDirectories: true)
  }

  /// Read `workspace.json` from disk. Returns nil when the file is
  /// missing OR when decoding fails — the latter triggers a side-channel
  /// rename to `workspace.json.corrupt-<timestamp>` so a developer can
  /// inspect the bad file. The user sees an empty workspace on the next
  /// launch, not a crash loop.
  public func load() -> WorkspaceState? {
    let fm = FileManager.default
    guard fm.fileExists(atPath: workspaceURL.path) else { return nil }
    let data: Data
    do {
      data = try Data(contentsOf: workspaceURL)
    } catch {
      return nil
    }
    do {
      return try decoder.decode(WorkspaceState.self, from: data)
    } catch {
      let stamp = ISO8601DateFormatter().string(from: Date())
        .replacingOccurrences(of: ":", with: "-")
      let bad = baseURL.appendingPathComponent(
        "workspace.json.corrupt-\(stamp)-\(UUID().uuidString)", isDirectory: false)
      try? fm.moveItem(at: workspaceURL, to: bad)
      return nil
    }
  }

  /// Atomically write `workspace.json` via `Data.write(options: .atomic)`,
  /// which is POSIX write-temp+close+rename. Crash-safe for process
  /// crashes; not power-loss-safe (see ExecPlan's durability discussion).
  public func save(_ state: WorkspaceState) throws {
    try ensureDirectories()
    let data: Data
    do {
      data = try encoder.encode(state)
    } catch {
      throw PersistenceStoreError.encodeFailed(error)
    }
    do {
      try data.write(to: workspaceURL, options: .atomic)
    } catch {
      throw PersistenceStoreError.writeFailed(error)
    }
  }

  /// Move `workspace.json` → `workspace.json.previous`, overwriting any
  /// existing previous archive. Used by the ⇧-at-launch escape hatch.
  /// No-op when there is no current workspace file.
  public func archiveCurrent() throws {
    let fm = FileManager.default
    guard fm.fileExists(atPath: workspaceURL.path) else { return }
    do {
      if fm.fileExists(atPath: previousURL.path) {
        try fm.removeItem(at: previousURL)
      }
      try fm.moveItem(at: workspaceURL, to: previousURL)
    } catch {
      throw PersistenceStoreError.archiveFailed(error)
    }
  }

  public func transcriptURL(forTabId tabId: String) -> URL {
    transcriptsURL.appendingPathComponent("\(tabId).bin", isDirectory: false)
  }

  public func agentMirrorURL(forTabId tabId: String) -> URL {
    agentMirrorURL.appendingPathComponent("\(tabId).jsonl", isDirectory: false)
  }
}
