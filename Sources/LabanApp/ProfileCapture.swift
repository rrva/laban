import AppKit
import Darwin
import Foundation

enum ProfileCaptureError: LocalizedError {
  case profilerNotRunning
  case captureFailed(String)
  case viewerServerFailed(String)
  case nothingToExport

  var errorDescription: String? {
    switch self {
    case .profilerNotRunning:
      return "The sampling profiler is not running. Enable it in Settings and relaunch, or use --profile-recorder."
    case .captureFailed(let detail):
      return "Profile capture failed: \(detail)"
    case .viewerServerFailed(let detail):
      return "Could not serve the profile to the browser: \(detail)"
    case .nothingToExport:
      return "No CPU profile has been recorded yet. Start CPU Recording first."
    }
  }
}

/// Captures in-process CPU samples and opens them in a web flame-graph viewer.
enum ProfileCapture {
  private static let viewerLifetimeSeconds: TimeInterval = 600
  private static var viewerServerFD: Int32 = -1
  private static let viewerLock = NSLock()

  static func capture(
    socketPath: String? = ProfileRecorderSettings.findProfilerSocket(),
    samples: Int = 1000,
    interval: String = "10 ms"
  ) throws -> URL {
    let data = try sampleData(socketPath: socketPath, samples: samples, interval: interval)
    let outURL = try newExportURL()
    try data.write(to: outURL)
    return outURL
  }

  static func sampleData(
    socketPath: String? = ProfileRecorderSettings.findProfilerSocket(),
    samples: Int,
    interval: String
  ) throws -> Data {
    guard let socketPath else { throw ProfileCaptureError.profilerNotRunning }

    let pipe = Pipe()
    let outPipe = Pipe()

    let demangle = Process()
    demangle.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
    demangle.arguments = ["demangle", "--compact"]
    demangle.standardInput = pipe
    demangle.standardOutput = outPipe

    let curl = Process()
    curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    curl.arguments = [
      "--fail", "--silent", "--show-error",
      "--unix-socket", socketPath,
      "-d", "{\"numberOfSamples\":\(samples),\"timeInterval\":\"\(interval)\"}",
      "http://localhost/sample",
    ]
    curl.standardOutput = pipe

    let stderrPipe = Pipe()
    curl.standardError = stderrPipe

    try demangle.run()
    try curl.run()
    curl.waitUntilExit()
    demangle.waitUntilExit()

    guard curl.terminationStatus == 0, demangle.terminationStatus == 0 else {
      let detail = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw ProfileCaptureError.captureFailed(detail?.isEmpty == false ? detail! : "curl or demangle failed")
    }
    return outPipe.fileHandleForReading.readDataToEndOfFile()
  }

  static func newExportURL(prefix: String = "") throws -> URL {
    let outDir = ProfileRecorderSettings.profilesDirectory
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter().string(from: Date())
      .replacingOccurrences(of: ":", with: "-")
    let name = prefix.isEmpty ? "\(stamp).perf" : "\(prefix)-\(stamp).perf"
    return outDir.appendingPathComponent(name)
  }

  static func openInSpeedscope(fileURL: URL) throws {
    let port = try startViewerServer(for: fileURL)
    let profileURL = "http://127.0.0.1:\(port)/\(fileURL.lastPathComponent)"
    let viewerURL =
      "https://www.speedscope.app/#profileURL=\(encodeURIComponent(profileURL))"
    NSWorkspace.shared.open(URL(string: viewerURL)!)
  }

  static func openInFirefoxProfiler(fileURL: URL) throws {
    let port = try startViewerServer(for: fileURL)
    let profileURL = "http://127.0.0.1:\(port)/\(fileURL.lastPathComponent)"
    let viewerURL =
      "https://profiler.firefox.com/from-url/\(encodeURIComponent(profileURL))"
    NSWorkspace.shared.open(URL(string: viewerURL)!)
  }

  private static func encodeURIComponent(_ value: String) -> String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }

  private static func startViewerServer(for fileURL: URL) throws -> UInt16 {
    let fileData: Data
    do {
      fileData = try Data(contentsOf: fileURL)
    } catch {
      throw ProfileCaptureError.viewerServerFailed("\(error)")
    }

    viewerLock.lock()
    defer { viewerLock.unlock() }
    stopViewerServerLocked()

    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else {
      throw ProfileCaptureError.viewerServerFailed(String(cString: strerror(errno)))
    }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
    let bindResult = withUnsafeBytes(of: &addr) { ptr in
      Darwin.bind(
        fd, ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self),
        socklen_t(MemoryLayout<sockaddr_in>.size))
    }
    guard bindResult == 0 else {
      let err = errno
      Darwin.close(fd)
      throw ProfileCaptureError.viewerServerFailed(String(cString: strerror(err)))
    }
    guard listen(fd, 8) == 0 else {
      let err = errno
      Darwin.close(fd)
      throw ProfileCaptureError.viewerServerFailed(String(cString: strerror(err)))
    }

    var bound = sockaddr_in()
    var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutableBytes(of: &bound) { ptr in
      getsockname(fd, ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self), &boundLen)
    }
    let port = CFSwapInt16BigToHost(bound.sin_port)
    viewerServerFD = fd

    let fileName = fileURL.lastPathComponent
    let thread = Thread {
      serveViewerLoop(
        listenFD: fd,
        fileName: fileName,
        fileData: fileData,
        lifetimeSeconds: viewerLifetimeSeconds)
    }
    thread.name = "profile-viewer-serve"
    thread.start()
    return port
  }

  private static func stopViewerServerLocked() {
    let fd = viewerServerFD
    viewerServerFD = -1
    if fd >= 0 { Darwin.close(fd) }
  }

  private static func serveViewerLoop(
    listenFD: Int32,
    fileName: String,
    fileData: Data,
    lifetimeSeconds: TimeInterval
  ) {
    let deadline = Date().addingTimeInterval(lifetimeSeconds)
    while Date() < deadline {
      viewerLock.lock()
      let active = viewerServerFD == listenFD && listenFD >= 0
      viewerLock.unlock()
      guard active else { break }

      var clientAddr = sockaddr_in()
      var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
      let clientFD = withUnsafeMutableBytes(of: &clientAddr) { ptr in
        accept(listenFD, ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self), &clientLen)
      }
      guard clientFD >= 0 else {
        if errno == EINTR || errno == ECONNABORTED { continue }
        break
      }
      respondWithProfile(clientFD: clientFD, fileName: fileName, fileData: fileData)
      Darwin.close(clientFD)
    }
    viewerLock.lock()
    if viewerServerFD == listenFD { stopViewerServerLocked() }
    viewerLock.unlock()
  }

  private static func respondWithProfile(clientFD: Int32, fileName: String, fileData: Data) {
    var raw = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while raw.count < 16 * 1024 {
      let n = recv(clientFD, &buf, buf.count, 0)
      if n <= 0 { break }
      raw.append(buf, count: n)
      if raw.range(of: Data("\r\n\r\n".utf8)) != nil { break }
    }

    let body = fileData
    let header = """
      HTTP/1.1 200 OK\r
      Access-Control-Allow-Origin: *\r
      Content-Type: application/octet-stream\r
      Content-Disposition: inline; filename="\(fileName)"\r
      Connection: close\r
      Content-Length: \(body.count)\r
      \r
      
      """
    var response = Data(header.utf8)
    response.append(body)
    _ = response.withUnsafeBytes { ptr in
      send(clientFD, ptr.baseAddress, response.count, 0)
    }
  }
}
