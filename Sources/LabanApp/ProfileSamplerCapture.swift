import Foundation
import Logging
import NIO
import ProfileRecorder
import _ProfileRecorderSampleConversion

/// Shared in-process CPU sampling path for one-shot and session captures.
///
/// This deliberately uses the low-level sampler rather than
/// `ProfileRecorderServer`: Laban does not need an HTTP listener to call code
/// that already lives in the same process.
enum ProfileSamplerCapture {
  typealias Sampler = @Sendable (Int, Int64) async throws -> Data

  private static let logger = Logging.Logger(label: "laban.profile-sampler")
  static let liveSampler: Sampler = { sampleCount, intervalMilliseconds in
    try await capture(
      sampleCount: sampleCount, intervalMilliseconds: intervalMilliseconds)
  }

  static func capture(sampleCount: Int, intervalMilliseconds: Int64) async throws -> Data {
    guard ProfileRecorderSampler.isSupportedPlatform else {
      throw ProfileCaptureError.profilerNotRunning
    }
    guard sampleCount > 0, intervalMilliseconds > 0 else {
      throw ProfileCaptureError.captureFailed("sample count and interval must be positive")
    }

    return try await ProfileRecorderSampler.sharedInstance
      .withSymbolizedSamplesInPerfScriptFormat(
        sampleCount: sampleCount,
        timeBetweenSamples: .milliseconds(intervalMilliseconds),
        logger: logger
      ) { path in
        try demangleProfileFile(at: URL(fileURLWithPath: path))
      }
  }

  static func captureBlocking(
    sampleCount: Int,
    intervalMilliseconds: Int64,
    sampler: @escaping Sampler = liveSampler
  ) throws -> Data {
    let box = ProfileSampleResultBox()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached(priority: .utility) {
      do {
        box.set(
          .success(
            try await sampler(sampleCount, intervalMilliseconds)))
      } catch {
        box.set(.failure(error))
      }
      semaphore.signal()
    }
    semaphore.wait()
    return try box.get().get()
  }

  private static func demangleProfileFile(at inputURL: URL) throws -> Data {
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-profile-\(UUID().uuidString).perf")
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
}

private final class ProfileSampleResultBox: @unchecked Sendable {
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
    return result ?? .failure(ProfileCaptureError.captureFailed("profile sample did not finish"))
  }
}
