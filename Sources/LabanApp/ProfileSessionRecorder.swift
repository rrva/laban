import Foundation
import Logging
import NIO
import ProfileRecorder
import _ProfileRecorderSampleConversion

enum ProfileSessionRecorderError: LocalizedError {
  case profilerNotRunning
  case alreadyRecording
  case nothingToExport

  var errorDescription: String? {
    switch self {
    case .profilerNotRunning:
      return ProfileCaptureError.profilerNotRunning.localizedDescription
    case .alreadyRecording:
      return "CPU recording is already running."
    case .nothingToExport:
      return ProfileCaptureError.nothingToExport.localizedDescription
    }
  }
}

/// Background CPU sampling that accumulates into a session file without any
/// on-surface pill. Each chunk is sampled, symbolicated, and appended while
/// the toggle is on.
final class ProfileSessionRecorder: @unchecked Sendable {
  static let shared = ProfileSessionRecorder()

  /// Debug-menu title for the Start/Stop toggle.
  static func menuTitle(recording: Bool) -> String {
    recording ? L10n.tr("Stop CPU Recording") : L10n.tr("Start CPU Recording")
  }

  /// Each chunk is 500 samples at 10 ms (~5 s), then symbolicated and appended
  /// before the next chunk starts.
  private static let chunkSamples = 500
  private static let chunkInterval = TimeAmount.milliseconds(10)
  private static let minimumExportBytes = 64
  private static let profilerLogger = Logging.Logger(label: "laban.profile-session-recorder")

  private let lock = NSLock()
  private let recordingQueue = DispatchQueue(label: "laban.cpu-profile-session", qos: .utility)
  private var recording = false
  private var recordingWorkItem: DispatchWorkItem?
  private var sessionFileURL: URL?
  private var chunkCount = 0

  private init() {}

  var isRecording: Bool {
    lock.lock()
    defer { lock.unlock() }
    return recording
  }

  var hasExportableData: Bool {
    lock.lock()
    defer { lock.unlock() }
    return sessionByteCountLocked() >= Self.minimumExportBytes
  }

  func start() throws {
    guard ProfileRecorderSampler.isSupportedPlatform,
      ProfileRecorderSettings.resolve().pattern != nil
    else {
      throw ProfileSessionRecorderError.profilerNotRunning
    }

    lock.lock()
    if recording {
      lock.unlock()
      throw ProfileSessionRecorderError.alreadyRecording
    }

    let sessionURL = try ProfileCapture.newExportURL(prefix: "session-active")
    FileManager.default.createFile(atPath: sessionURL.path, contents: nil)
    sessionFileURL = sessionURL
    chunkCount = 0
    recording = true
    let workItem = DispatchWorkItem { [weak self] in
      self?.recordingLoop()
    }
    recordingWorkItem = workItem
    lock.unlock()

    AppLog.app.info("CPU session recording started: \(sessionURL.path)")

    recordingQueue.async(execute: workItem)
  }

  func stop() {
    lock.lock()
    guard recording else {
      lock.unlock()
      return
    }
    recording = false
    let workItem = recordingWorkItem
    recordingWorkItem = nil
    let path = sessionFileURL?.path ?? ""
    lock.unlock()

    workItem?.cancel()
    AppLog.app.info("CPU session recording stopped: \(path)")
  }

  /// Copies the accumulated session to a timestamped export file. Holds the
  /// session lock for the copy so export does not race with chunk appends.
  func exportSnapshot() throws -> URL {
    lock.lock()
    defer { lock.unlock() }

    guard let sourceURL = sessionFileURL,
      sessionByteCountLocked() >= Self.minimumExportBytes
    else {
      throw ProfileSessionRecorderError.nothingToExport
    }

    let exportURL = try ProfileCapture.newExportURL(prefix: "session-export")
    try FileManager.default.copyItem(at: sourceURL, to: exportURL)
    AppLog.app.info("CPU session exported: \(exportURL.path)")
    return exportURL
  }

  private func recordingLoop() {
    while true {
      lock.lock()
      let active = recording
      let sessionURL = sessionFileURL
      lock.unlock()
      guard active, let sessionURL else { break }

      do {
        let chunk = try captureChunk()
        guard !chunk.isEmpty else { continue }
        try appendChunk(chunk, to: sessionURL)
        lock.lock()
        chunkCount += 1
        lock.unlock()
      } catch {
        AppLog.app.error("CPU session chunk failed: \(String(describing: error))")
        Thread.sleep(forTimeInterval: 1)
      }
    }
    lock.lock()
    if recordingWorkItem?.isCancelled == false {
      recordingWorkItem = nil
    }
    lock.unlock()
  }

  private func captureChunk() throws -> Data {
    let box = ChunkResultBox()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached(priority: .utility) {
      do {
        let data = try await Self.captureChunkAsync()
        box.set(.success(data))
      } catch {
        box.set(.failure(error))
      }
      semaphore.signal()
    }
    semaphore.wait()
    return try box.get().get()
  }

  private static func captureChunkAsync() async throws -> Data {
    try await ProfileRecorderSampler.sharedInstance.withSymbolizedSamplesInPerfScriptFormat(
      sampleCount: chunkSamples,
      timeBetweenSamples: chunkInterval,
      logger: profilerLogger
    ) { path in
      try demangleProfileFile(at: URL(fileURLWithPath: path))
    }
  }

  private static func demangleProfileFile(at inputURL: URL) throws -> Data {
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-profile-session-\(UUID().uuidString).perf")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: outputURL) }

    let inputHandle = try FileHandle(forReadingFrom: inputURL)
    let outputHandle = try FileHandle(forWritingTo: outputURL)
    defer {
      try? inputHandle.close()
      try? outputHandle.close()
    }

    let demangle = Process()
    demangle.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
    demangle.arguments = ["demangle", "--compact"]
    demangle.standardInput = inputHandle
    demangle.standardOutput = outputHandle

    let stderrPipe = Pipe()
    demangle.standardError = stderrPipe

    try demangle.run()
    demangle.waitUntilExit()

    guard demangle.terminationStatus == 0 else {
      let detail = String(
        data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw ProfileCaptureError.captureFailed(
        detail?.isEmpty == false ? detail! : "swift demangle failed")
    }
    let demangledData = try Data(contentsOf: outputURL)
    return demangledData.isEmpty ? try Data(contentsOf: inputURL) : demangledData
  }

  private func appendChunk(_ chunk: Data, to sessionURL: URL) throws {
    lock.lock()
    defer { lock.unlock() }
    let handle = try FileHandle(forWritingTo: sessionURL)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: chunk)
  }

  private func sessionByteCountLocked() -> Int {
    guard let sessionFileURL else { return 0 }
    let attrs = try? FileManager.default.attributesOfItem(atPath: sessionFileURL.path)
    return attrs?[.size] as? Int ?? 0
  }
}

private final class ChunkResultBox: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<Data, Error>?

  func set(_ result: Result<Data, Error>) {
    lock.lock()
    self.result = result
    lock.unlock()
  }

  func get() -> Result<Data, Error> {
    lock.lock()
    defer { lock.unlock() }
    return result ?? .failure(ProfileCaptureError.captureFailed("profile chunk did not finish"))
  }
}
