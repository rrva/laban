import AppKit
import Darwin
import Foundation

enum ProfileCaptureError: LocalizedError {
  case profilerNotRunning
  case captureAlreadyInProgress
  case captureFailed(String)
  case viewerServerFailed(String)
  case nothingToExport

  var errorDescription: String? {
    switch self {
    case .profilerNotRunning:
      return
        "CPU sampling is disabled. Enable it in Settings or use --profile-recorder."
    case .captureAlreadyInProgress:
      return "A CPU profile capture is already in progress."
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
    samples: Int = 1000,
    intervalMilliseconds: Int64 = 10
  ) throws -> URL {
    guard ProfileRecorderSettings.resolve().isEnabled else {
      throw ProfileCaptureError.profilerNotRunning
    }
    let data = try sampleData(
      samples: samples, intervalMilliseconds: intervalMilliseconds)
    let outURL = try newExportURL()
    try data.write(to: outURL)
    return outURL
  }

  static func sampleData(
    samples: Int,
    intervalMilliseconds: Int64,
    sampler: @escaping ProfileSamplerCapture.Sampler = ProfileSamplerCapture.liveSampler
  ) throws -> Data {
    try ProfileSamplerCapture.captureBlocking(
      sampleCount: samples,
      intervalMilliseconds: intervalMilliseconds,
      sampler: sampler)
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
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
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

  static func respondWithProfile(clientFD: Int32, fileName: String, fileData: Data) {
    var raw = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while raw.count < 16 * 1024 {
      let n = recv(clientFD, &buf, buf.count, 0)
      if n <= 0 { break }
      raw.append(buf, count: n)
      if raw.range(of: Data("\r\n\r\n".utf8)) != nil { break }
    }

    let requestStr = String(data: raw, encoding: .utf8) ?? ""
    var allowedOrigin = "https://www.speedscope.app"
    let lines = requestStr.split(separator: "\r\n")
    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.lowercased().hasPrefix("origin:") {
        let parts = trimmed.split(separator: ":", maxSplits: 1)
        if parts.count == 2 {
          let originValue = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
          if originValue == "https://www.speedscope.app"
            || originValue == "https://profiler.firefox.com"
          {
            allowedOrigin = originValue
          }
        }
      }
    }

    let body = fileData
    let header = """
      HTTP/1.1 200 OK\r
      Access-Control-Allow-Origin: \(allowedOrigin)\r
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
