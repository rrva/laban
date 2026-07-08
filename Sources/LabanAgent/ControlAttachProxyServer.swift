import Darwin
import Dispatch
import Foundation
import LabanControl
import LabanCore

/// JSONL request shape accepted by the `laban-agent` session proxy.
struct LiveControlAttachRequest: Decodable {
  var method: String?
  var path: String
  var body: String?
}

/// JSONL response shape returned by the `laban-agent` session proxy.
struct LiveControlAttachResponse: Codable {
  var path: String
  var status: Int
  var body: String
}

/// Injectable limits for `ControlAttachProxyServer`. Production defaults are
/// immutable; tests may construct smaller values to exercise edge cases quickly.
struct ProxyLimits: Equatable {
  let maxLineBytes: Int
  let maxBodyBytes: Int
  let maxConcurrentClients: Int
  let maxQueueDepth: Int
  let clientIdleSeconds: TimeInterval
  let heartbeatIntervalSeconds: TimeInterval

  static let production = ProxyLimits(
    maxLineBytes: 64 * 1024,
    maxBodyBytes: 32 * 1024,
    maxConcurrentClients: 16,
    maxQueueDepth: 64,
    clientIdleSeconds: 60,
    heartbeatIntervalSeconds: 30)
}

/// A small, hardened Unix-domain proxy that exposes the held app-control/C14
/// connection to descendants of a launched agent child.
///
/// Security properties:
/// - The socket lives in a per-process `0700` temp directory.
/// - Listener, accepted, and upstream file descriptors are close-on-exec.
/// - Peers are required to have the same uid.
/// - When an allowed root pid is configured, peers must be that pid or a
///   descendant of it.
/// - Requests are bounded in line/body size and queued; forwarded requests are
///   serialized over the single held upstream connection.
final class ControlAttachProxyServer {
  let socketPath: String
  let upstreamFD: Int32

  private let tempDirectory: URL
  #if DEBUG
    var testTempDirectory: URL { tempDirectory }
    var testListenerFD: Int32 { listenerFD }
  #endif

  private let allowedRootPIDLock = NSLock()
  private var allowedRootPID: pid_t?
  private var listenerFD: Int32 = -1
  private var acceptThread: Thread?

  private let forwardQueue = DispatchQueue(label: "com.laban.agent.proxy.forward")
  private let stateLock = NSLock()
  private var activeClients = 0
  private var queuedRequests = 0
  private var stopped = false
  private var heartbeatTimer: DispatchSourceTimer?
  private var upstreamLost = false
  var onUpstreamLost: (() -> Void)?

  // MARK: - Limits

  static let maxLineBytes = 64 * 1024
  // Body cap is intentionally below the line cap so a line can carry a body
  // that is rejected specifically as an oversized body (413) rather than only
  // as an oversized line.
  static let maxBodyBytes = 32 * 1024
  static let maxConcurrentClients = 16
  static let maxQueueDepth = 64
  static let clientIdleSeconds: TimeInterval = 60
  static let heartbeatIntervalSeconds: TimeInterval = 30

  private let limits: ProxyLimits

  #if DEBUG
    var testClientAcceptedHandler: ((Int32) -> Void)?
  #endif

  // MARK: - Lifecycle

  init(
    upstreamFD: Int32,
    allowedRootPID: pid_t?,
    limits: ProxyLimits = .production
  ) throws {
    self.limits = limits
    self.upstreamFD = upstreamFD
    self.allowedRootPID = allowedRootPID

    let pid = getpid()
    let dirName = "laban-agent-control.\(pid).\(UUID().uuidString.prefix(8))"
    let dirURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(dirName, isDirectory: true)
    try FileManager.default.createDirectory(
      at: dirURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    self.tempDirectory = dirURL
    self.socketPath = dirURL.appendingPathComponent("proxy.sock").path

    try ControlDirectorySecurity.prepareSocketPath(self.socketPath)
    self.listenerFD = try Self.bindListener(at: self.socketPath)
    try ControlFD.setCloseOnExec(self.listenerFD)
    try ControlFD.setCloseOnExec(self.upstreamFD)
    try ControlFD.setNoSigPipe(self.upstreamFD)

    let thread = Thread { [weak self] in self?.acceptLoop() }
    thread.name = "laban-agent-proxy-accept"
    thread.start()
    self.acceptThread = thread

    startHeartbeat()
  }

  deinit {
    stop()
  }

  func setAllowedRootPID(_ pid: pid_t) {
    allowedRootPIDLock.lock()
    allowedRootPID = pid
    allowedRootPIDLock.unlock()
  }

  func stop() {
    stateLock.lock()
    guard !stopped else {
      stateLock.unlock()
      return
    }
    stopped = true
    stateLock.unlock()

    heartbeatTimer?.cancel()
    heartbeatTimer = nil

    if listenerFD >= 0 {
      let fd = listenerFD
      listenerFD = -1
      Darwin.close(fd)
    }
    unlink(socketPath)
    try? FileManager.default.removeItem(at: tempDirectory)
  }

  // MARK: - Binding

  private static func bindListener(at path: String) throws -> Int32 {
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else {
      throw ControlAttachProxyError.socketFailed
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
      Darwin.close(listener)
      throw ControlAttachProxyError.socketPathTooLong
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { dest in
      for (index, byte) in pathBytes.enumerated() where index < dest.count {
        dest[index] = UInt8(bitPattern: byte)
      }
    }

    let bindResult = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        Darwin.bind(listener, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bindResult == 0 else {
      Darwin.close(listener)
      throw ControlAttachProxyError.bindFailed
    }

    guard listen(listener, 16) == 0 else {
      Darwin.close(listener)
      throw ControlAttachProxyError.listenFailed
    }

    return listener
  }

  // MARK: - Accept loop

  private var isStopped: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return stopped
  }

  private func acceptLoop() {
    while !isStopped {
      // Read listenerFD under lock to avoid racing stop().
      let fd: Int32 = stateLock.withLock { listenerFD }
      guard fd >= 0 else { break }

      var clientAddr = sockaddr_un()
      var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
      let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
        accept(fd, ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }, &clientLen)
      }

      if clientFD >= 0 {
        do {
          try ControlFD.setCloseOnExec(clientFD)
          try ControlFD.setNoSigPipe(clientFD)
        } catch {
          Darwin.close(clientFD)
          continue
        }
        #if DEBUG
          testClientAcceptedHandler?(clientFD)
        #endif
        Thread.detachNewThread { [weak self] in
          self?.handleClient(clientFD)
        }
        continue
      }

      let err = errno
      if isStopped || err == EBADF || err == EINVAL { break }
      if err == EINTR || err == ECONNABORTED { continue }
      if err == EMFILE || err == ENFILE {
        usleep(100_000)
        continue
      }
      break
    }
  }

  // MARK: - Client handling

  private func handleClient(_ clientFD: Int32) {
    var counted = false
    defer {
      Darwin.close(clientFD)
      if counted {
        stateLock.withLock { activeClients = max(0, activeClients - 1) }
      }
    }

    guard LabanControlServer.evaluatePeerCredential(clientFD: clientFD) == .ok else {
      _ = sendErrorResponse(fd: clientFD, path: "", status: 403, message: "forbidden")
      return
    }

    let peer = LabanControlServer.peerPID(clientFD: clientFD)
    let root = allowedRootPIDLock.withLock { allowedRootPID }
    if let root {
      guard let peerPID = peer, peerPID == root || Self.isDescendant(pid: peerPID, of: root) else {
        _ = sendErrorResponse(fd: clientFD, path: "", status: 403, message: "forbidden")
        return
      }
    }

    let acceptedClient = stateLock.withLock { () -> Bool in
      guard activeClients < limits.maxConcurrentClients else { return false }
      activeClients += 1
      return true
    }
    guard acceptedClient else {
      _ = sendErrorResponse(
        fd: clientFD,
        path: "",
        status: 429,
        message: "proxy busy")
      return
    }
    counted = true

    var readBuffer = Data()
    while !isStopped {
      let result = readRequestLine(fd: clientFD, buffer: &readBuffer)

      switch result {
      case .oversized:
        _ = sendErrorResponse(
          fd: clientFD,
          path: "",
          status: 413,
          message: "request line too large")
        return
      case .timeout:
        _ = sendErrorResponse(
          fd: clientFD,
          path: "",
          status: 408,
          message: "request timeout")
        return
      case .eof:
        return
      case .error:
        _ = sendErrorResponse(
          fd: clientFD,
          path: "",
          status: 400,
          message: "transport error")
        return
      case .line(let raw):
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
          _ = sendErrorResponse(
            fd: clientFD,
            path: "",
            status: 400,
            message: "empty request")
          continue
        }

        let request: LiveControlAttachRequest
        do {
          request = try JSONDecoder().decode(
            LiveControlAttachRequest.self,
            from: Data(trimmed.utf8))
        } catch {
          _ = sendErrorResponse(
            fd: clientFD,
            path: "",
            status: 400,
            message: "malformed JSON")
          continue
        }

        let bodySize = request.body?.utf8.count ?? 0
        guard bodySize <= limits.maxBodyBytes else {
          _ = sendErrorResponse(
            fd: clientFD,
            path: request.path,
            status: 413,
            message: "request body too large")
          continue
        }

        let accepted = stateLock.withLock { () -> Bool in
          guard !stopped, queuedRequests < limits.maxQueueDepth else {
            return false
          }
          queuedRequests += 1
          return true
        }
        guard accepted else {
          _ = sendErrorResponse(
            fd: clientFD,
            path: request.path,
            status: 429,
            message: "proxy busy")
          return
        }

        let semaphore = DispatchSemaphore(value: 0)
        forwardQueue.async { [weak self] in
          defer {
            self?.stateLock.withLock {
              self?.queuedRequests = max(0, (self?.queuedRequests ?? 0) - 1)
            }
            semaphore.signal()
          }
          guard let self else { return }
          do {
            let response = try self.forwardRequest(request)
            self.sendResponse(fd: clientFD, response: response)
          } catch {
            self.sendErrorResponse(
              fd: clientFD,
              path: request.path,
              status: 502,
              message: "upstream unavailable")
            self.markUpstreamLost()
          }
        }
        semaphore.wait()
      }
    }
  }

  // MARK: - Forwarding

  private func forwardRequest(_ request: LiveControlAttachRequest) throws
    -> LiveControlAttachResponse
  {
    let body = request.body.flatMap { Data($0.utf8) }
    let (status, responseBody) = try ControlUDSClient.request(
      fd: upstreamFD,
      method: request.method ?? "GET",
      path: request.path,
      body: body,
      keepConnectionOpen: true)
    return LiveControlAttachResponse(
      path: request.path,
      status: status,
      body: String(data: responseBody, encoding: .utf8) ?? "")
  }

  private func markUpstreamLost() {
    var notify = false
    stateLock.withLock {
      if !upstreamLost {
        upstreamLost = true
        notify = true
      }
    }
    if notify {
      onUpstreamLost?()
    }
  }

  // MARK: - Line reading

  private enum ReadLineResult {
    case line(String)
    case oversized
    case timeout
    case eof
    case error
  }

  private func readRequestLine(fd: Int32, buffer: inout Data) -> ReadLineResult {
    // If a previous recv read past the newline, serve the buffered line first.
    if let newline = buffer.firstIndex(of: 0x0A) {
      let lineData = buffer[..<newline]
      buffer.removeSubrange(...newline)
      guard let line = String(data: lineData, encoding: .utf8) else {
        return .error
      }
      return .line(line)
    }

    var recvBuffer = [UInt8](repeating: 0, count: 4096)

    var tv = timeval(
      tv_sec: Int(limits.clientIdleSeconds),
      tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    while buffer.count < limits.maxLineBytes {
      let n = recv(fd, &recvBuffer, recvBuffer.count, 0)
      if n < 0 {
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK {
          return .timeout
        }
        return .error
      }
      if n == 0 { return buffer.isEmpty ? .eof : .error }
      buffer.append(contentsOf: recvBuffer[0..<n])
      if let newline = buffer.firstIndex(of: 0x0A) {
        let lineData = buffer[..<newline]
        buffer.removeSubrange(...newline)
        guard let line = String(data: lineData, encoding: .utf8) else {
          return .error
        }
        return .line(line)
      }
    }
    return .oversized
  }

  // MARK: - I/O helpers

  @discardableResult
  private func sendResponse(fd: Int32, response: LiveControlAttachResponse) -> Bool {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let payload = try? encoder.encode(response),
      let text = String(data: payload, encoding: .utf8)
    else {
      return false
    }
    let line = Data((text + "\n").utf8)
    return sendAll(fd: fd, data: line)
  }

  @discardableResult
  private func sendErrorResponse(fd: Int32, path: String, status: Int, message: String) -> Bool {
    let response = LiveControlAttachResponse(path: path, status: status, body: message)
    return sendResponse(fd: fd, response: response)
  }

  private func sendAll(fd: Int32, data: Data) -> Bool {
    data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return true }
      var sent = 0
      while sent < raw.count {
        let n = Darwin.send(fd, base.advanced(by: sent), raw.count - sent, 0)
        if n < 0 {
          if errno == EINTR { continue }
          return false
        }
        if n == 0 { return false }
        sent += n
      }
      return true
    }
  }

  // MARK: - Heartbeat

  private func startHeartbeat() {
    let timer = DispatchSource.makeTimerSource(queue: forwardQueue)
    timer.schedule(
      deadline: .now() + limits.heartbeatIntervalSeconds,
      repeating: .seconds(Int(limits.heartbeatIntervalSeconds)))
    timer.setEventHandler { [weak self] in
      guard let self, !self.isStopped else { return }
      do {
        _ = try self.forwardRequest(
          LiveControlAttachRequest(method: "GET", path: "/debug/health", body: nil))
      } catch {
        self.markUpstreamLost()
      }
    }
    timer.resume()
    heartbeatTimer = timer
  }

  // MARK: - Process tree

  static func isDescendant(pid: pid_t, of ancestor: pid_t) -> Bool {
    var current = pid
    while current > 1 {
      guard let parent = parentPID(of: current) else { return false }
      if parent == ancestor { return true }
      current = parent
    }
    return false
  }

  private static func parentPID(of pid: pid_t) -> pid_t? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
      size >= MemoryLayout<kinfo_proc>.stride
    else {
      return nil
    }
    let ppid = info.kp_eproc.e_ppid
    return ppid > 0 ? ppid : nil
  }
}

enum ControlAttachProxyError: Error, Equatable {
  case socketFailed
  case bindFailed
  case listenFailed
  case socketPathTooLong
}

extension NSLocking {
  func withLock<T>(_ block: () -> T) -> T {
    lock()
    defer { unlock() }
    return block()
  }
}
