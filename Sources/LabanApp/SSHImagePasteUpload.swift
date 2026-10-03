import AppKit
import Darwin
import Foundation
import LabanCore

/// AppKit/process half of "paste a clipboard image into an SSH session"
/// (ADR 0039). The pure parts — argv parsing, the remote script, the reply
/// validation, the paste decision, and the consent store — live in
/// `LabanCore/SSHImageUpload.swift`.
enum SSHImagePasteUpload {
  static let timeout: TimeInterval = 30

  /// The foreground ssh process of a pane, read fresh from the kernel at paste
  /// time. The tab metadata's `foregroundArguments` is unusable here: it is
  /// capped at 16 elements and each element is title-sanitized (whitespace
  /// collapsed, 256-scalar cap), which can silently change an option value.
  struct ForegroundSSH {
    var executable: URL
    var commandLine: SSHCommandLine
    /// `SSH_AUTH_SOCK` of the running ssh, so the upload uses the same agent.
    var authSocket: String?
  }

  /// Resolve `pid` to a parseable ssh command line, or `nil` when the process
  /// is gone, is not ssh, or its argv is refused by `SSHCommandLine.parse`.
  static func foregroundSSH(pid: Int?) -> ForegroundSSH? {
    guard let pid, pid > 0 else { return nil }
    let introspector = LibprocIntrospector()
    let argv = introspector.arguments(of: pid_t(pid))
    guard let commandLine = SSHCommandLine.parse(argv) else { return nil }
    let executable = executablePath(of: pid_t(pid)).flatMap { path -> URL? in
      SSHCommandLine.isSSHExecutable(path) ? URL(fileURLWithPath: path) : nil
    }
    // Guard pid reuse: the binary itself must be ssh, not just argv[0].
    guard let executable else { return nil }
    let authSocket = introspector.environment(of: pid_t(pid))["SSH_AUTH_SOCK"]
    return ForegroundSSH(executable: executable, commandLine: commandLine, authSocket: authSocket)
  }

  private static func executablePath(of pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let length = buffer.withUnsafeMutableBufferPointer {
      proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
    }
    guard length > 0 else { return nil }
    return String(cString: buffer)
  }

  // MARK: - Image

  enum ImageRead: Equatable {
    case png(Data)
    case tooLarge(Int)
    case unavailable
  }

  /// The pasteboard image as PNG bytes: the `.png` representation when one is
  /// on the pasteboard, otherwise the TIFF (or any `NSImage`) re-encoded.
  static func pngData(
    from pasteboard: NSPasteboard, limit: Int = SSHImageUploadScript.maxImageBytes
  ) -> ImageRead {
    let png: Data?
    if let data = pasteboard.data(forType: .png) {
      png = data
    } else if let tiff = pasteboard.data(forType: .tiff)
      ?? (NSImage(pasteboard: pasteboard)?.tiffRepresentation)
    {
      png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    } else {
      png = nil
    }
    guard let png, !png.isEmpty else { return .unavailable }
    return png.count > limit ? .tooLarge(png.count) : .png(png)
  }

  // MARK: - Consent

  /// Ask once per destination; "Upload" is remembered in `store`.
  @MainActor
  static func confirmUpload(
    to commandLine: SSHCommandLine, store: SSHImageUploadConsentStore,
    prompt: @MainActor (SSHCommandLine) -> Bool = runConsentAlert
  ) -> Bool {
    if store.isApproved(commandLine.consentKey) { return true }
    guard prompt(commandLine) else { return false }
    store.approve(commandLine.consentKey)
    return true
  }

  @MainActor
  static func runConsentAlert(_ commandLine: SSHCommandLine) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = String(
      format: L10n.tr("Upload the clipboard image to %@?"), commandLine.displayDestination)
    alert.informativeText = L10n.tr(
      "Laban will copy the image over your SSH connection to a private cache folder on that host and paste its path. You won't be asked again for this host."
    )
    alert.addButton(withTitle: L10n.tr("Upload"))
    alert.addButton(withTitle: L10n.tr("Cancel"))
    return alert.runModal() == .alertFirstButtonReturn
  }

  // MARK: - Upload

  enum Failure: Error, Equatable {
    case launch(String)
    case timedOut
    case exit(status: Int32, stderr: String)
    case unexpectedReply

    /// Short, user-facing reason for the failure toast.
    var reason: String {
      switch self {
      case .launch(let message): return message
      case .timedOut: return L10n.tr("timed out")
      case .exit(let status, let stderr):
        return stderr.isEmpty
          ? String(format: L10n.tr("ssh exited with status %d"), status) : stderr
      case .unexpectedReply: return L10n.tr("unexpected reply from the host")
      }
    }

    /// Stable, non-sensitive kind for the event log.
    var kind: String {
      switch self {
      case .launch: return "launch"
      case .timedOut: return "timeout"
      case .exit: return "exit"
      case .unexpectedReply: return "reply"
      }
    }
  }

  struct ProcessOutcome {
    var status: Int32
    var stdout: Data
    var stderr: Data
    var timedOut: Bool
  }

  /// Bytes of stdout and of stderr kept per upload (the tail); the rest is
  /// read and discarded so the pipes never block ssh. A remote path is at
  /// most 4096 bytes.
  static let outputLimit = 8 * 1024
  /// Grace between SIGTERM and SIGKILL of the process group on timeout.
  static let terminateGrace: TimeInterval = 1
  /// How long to keep reading stdout/stderr after ssh exits. A ProxyCommand
  /// child (or anything else) still holding the pipes must not stall the paste.
  static let drainGrace: TimeInterval = 1

  enum SpawnError: Error, CustomStringConvertible {
    case pipe(Int32)
    case spawn(Int32)
    var description: String {
      switch self {
      case .pipe(let code), .spawn(let code): return String(cString: strerror(code))
      }
    }
  }

  /// Run `executable arguments` with `input` on stdin in its own process
  /// group. Bounded: returns within about `timeout + terminateGrace +
  /// drainGrace` even if the group's processes ignore SIGTERM or a descendant
  /// keeps the output pipes open. Blocking — call off the main thread.
  static func runProcess(
    executable: URL, arguments: [String], environment: [String: String], input: Data,
    timeout: TimeInterval
  ) throws -> ProcessOutcome {
    let stdinFDs = try makePipe()
    let stdoutFDs: [Int32]
    let stderrFDs: [Int32]
    do {
      stdoutFDs = try makePipe()
    } catch {
      for fd in stdinFDs { close(fd) }
      throw error
    }
    do {
      stderrFDs = try makePipe()
    } catch {
      for fd in stdinFDs + stdoutFDs { close(fd) }
      throw error
    }
    // ssh exits without draining stdin on failure; a write to the closed pipe
    // must be an EPIPE error, not an app-killing SIGPIPE.
    _ = fcntl(stdinFDs[1], F_SETNOSIGPIPE, 1)
    // Non-blocking so the writer can give up once the run is over, even if
    // a descendant holds the read end open without reading.
    _ = fcntl(stdinFDs[1], F_SETFL, fcntl(stdinFDs[1], F_GETFL) | O_NONBLOCK)

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, stdinFDs[0], 0)
    posix_spawn_file_actions_adddup2(&actions, stdoutFDs[1], 1)
    posix_spawn_file_actions_adddup2(&actions, stderrFDs[1], 2)
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    // Own process group (so a timeout can kill ssh *and* its ProxyCommand),
    // and no inherited descriptors beyond the three dup2'd above.
    // Reset the signal mask and dispositions: the upload runs on a GCD worker
    // whose mask blocks SIGTERM/SIGHUP/SIGINT, and posix_spawn would hand that
    // mask to ssh and its ProxyCommand, making the timeout's SIGTERM (and ssh's
    // own SIGHUP to its proxy) a no-op.
    posix_spawnattr_setflags(
      &attributes,
      Int16(
        POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK
          | POSIX_SPAWN_SETSIGDEF))
    posix_spawnattr_setpgroup(&attributes, 0)
    var emptyMask = sigset_t()
    sigemptyset(&emptyMask)
    posix_spawnattr_setsigmask(&attributes, &emptyMask)
    var allSignals = sigset_t()
    sigfillset(&allSignals)
    posix_spawnattr_setsigdefault(&attributes, &allSignals)

    let argv = [executable.path] + arguments
    let envp = environment.map { "\($0.key)=\($0.value)" }
    var pid: pid_t = 0
    let spawnResult = withCStringArray(argv) { cArgv in
      withCStringArray(envp) { cEnvp in
        posix_spawn(&pid, executable.path, &actions, &attributes, cArgv, cEnvp)
      }
    }
    close(stdinFDs[0])
    close(stdoutFDs[1])
    close(stderrFDs[1])
    guard spawnResult == 0 else {
      close(stdinFDs[1])
      close(stdoutFDs[0])
      close(stderrFDs[0])
      throw SpawnError.spawn(spawnResult)
    }

    let cancelReads = LockedFlag()
    let stdoutBox = DataBox()
    let stderrBox = DataBox()
    let readers = DispatchGroup()
    let finished = LockedFlag()
    defer { finished.set() }
    DispatchQueue.global().async {
      var offset = 0
      input.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        while offset < raw.count && !finished.value {
          var pollFD = pollfd(fd: stdinFDs[1], events: Int16(POLLOUT), revents: 0)
          let ready = poll(&pollFD, 1, 100)
          if ready < 0 && errno != EINTR { break }
          if ready <= 0 { continue }
          if pollFD.revents & Int16(POLLOUT) == 0 { break }  // POLLHUP / POLLERR
          let written = write(stdinFDs[1], base + offset, raw.count - offset)
          if written < 0 {
            if errno == EINTR || errno == EAGAIN { continue }
            break
          }
          offset += written
        }
      }
      close(stdinFDs[1])
    }
    for (fd, box) in [(stdoutFDs[0], stdoutBox), (stderrFDs[0], stderrBox)] {
      DispatchQueue.global().async(group: readers) {
        drain(fd, into: box, cancel: cancelReads)
        close(fd)
      }
    }

    let exited = DispatchSemaphore(value: 0)
    let statusBox = StatusBox()
    DispatchQueue.global().async {
      var status: Int32 = 0
      var result: pid_t
      var waitErrno: Int32 = 0
      repeat {
        result = waitpid(pid, &status, 0)
        waitErrno = result < 0 ? errno : 0
      } while result < 0 && waitErrno == EINTR
      statusBox.set(exitStatus(waitResult: result, rawStatus: status))
      exited.signal()
    }

    var timedOut = false
    if exited.wait(timeout: .now() + timeout) == .timedOut {
      timedOut = true
      kill(-pid, SIGTERM)
      if exited.wait(timeout: .now() + terminateGrace) == .timedOut {
        kill(-pid, SIGKILL)
        exited.wait()
      }
    }
    if readers.wait(timeout: .now() + drainGrace) == .timedOut {
      // Something left in the group still holds a pipe: kill it and stop reading.
      kill(-pid, SIGKILL)
      cancelReads.set()
      _ = readers.wait(timeout: .now() + 0.5)
    }
    return ProcessOutcome(
      status: statusBox.value, stdout: stdoutBox.value, stderr: stderrBox.value, timedOut: timedOut)
  }

  /// Shell-style exit status from a `waitpid` result: the exit code, `128 +
  /// signal` when killed, or `waitFailedStatus` when `waitpid` itself failed
  /// (the outcome is unknown, so it must never read as success).
  static func exitStatus(waitResult: pid_t, rawStatus: Int32) -> Int32 {
    guard waitResult > 0 else { return waitFailedStatus }
    if rawStatus & 0x7F == 0 { return (rawStatus >> 8) & 0xFF }
    return 128 + (rawStatus & 0x7F)
  }

  /// Status reported when `waitpid` failed with anything but EINTR.
  static let waitFailedStatus: Int32 = -1

  /// A pipe whose both ends are close-on-exec. Laban forks shells in-process
  /// (session_lifecycle.c); a shell spawned mid-upload must not inherit these
  /// ends — a leaked stdin write end would keep the remote `cat` from ever
  /// seeing EOF. posix_spawn's dup2 onto 0/1/2 clears the flag for ssh's copies.
  static func makePipe() throws -> [Int32] {
    var fds: [Int32] = [-1, -1]
    guard pipe(&fds) == 0 else { throw SpawnError.pipe(errno) }
    for fd in fds {
      _ = fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC)
    }
    return fds
  }

  /// Read `fd` to EOF in 100 ms poll slices, stopping early once `cancel` is set.
  private static func drain(_ fd: Int32, into box: DataBox, cancel: LockedFlag) {
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while !cancel.value {
      var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let ready = poll(&pollFD, 1, 100)
      if ready < 0 {
        if errno == EINTR { continue }
        return
      }
      if ready == 0 { continue }
      let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
      if count < 0 {
        if errno == EINTR || errno == EAGAIN { continue }
        return
      }
      if count == 0 { return }
      box.append(buffer[0..<count])
    }
  }

  private static func withCStringArray<R>(
    _ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R
  ) -> R {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer { for pointer in pointers { free(pointer) } }
    return body(pointers)
  }

  /// Upload `png` to the foreground ssh's host and return the remote path.
  /// Blocking — call off the main thread.
  static func upload(_ png: Data, via ssh: ForegroundSSH, timeout: TimeInterval = timeout)
    -> Result<String, Failure>
  {
    let fileName = SSHImageUploadScript.makeFileName()
    let arguments = ssh.commandLine.uploadArguments(
      remoteCommand: SSHImageUploadScript.remoteCommand(fileName: fileName))
    let environment = uploadEnvironment(
      base: ProcessInfo.processInfo.environment, authSocket: ssh.authSocket)
    let outcome: ProcessOutcome
    do {
      outcome = try runProcess(
        executable: ssh.executable, arguments: arguments, environment: environment, input: png,
        timeout: timeout)
    } catch {
      return .failure(.launch(String(describing: error)))
    }
    return interpret(outcome, fileName: fileName)
  }

  /// Laban's environment with the running ssh's agent socket. When that ssh
  /// has no `SSH_AUTH_SOCK`, the upload must not fall back to Laban's own agent.
  static func uploadEnvironment(base: [String: String], authSocket: String?) -> [String: String] {
    var environment = base
    environment["SSH_AUTH_SOCK"] = authSocket
    return environment
  }

  static func interpret(_ outcome: ProcessOutcome, fileName: String) -> Result<String, Failure> {
    if outcome.timedOut { return .failure(.timedOut) }
    guard outcome.status == 0 else {
      return .failure(.exit(status: outcome.status, stderr: lastLine(of: outcome.stderr)))
    }
    guard let path = SSHImageUploadScript.remotePath(fromStdout: outcome.stdout, fileName: fileName)
    else { return .failure(.unexpectedReply) }
    return .success(path)
  }

  /// Last non-empty stderr line, control characters removed, capped for a toast.
  static func lastLine(of data: Data) -> String {
    let text = String(decoding: data, as: UTF8.self)
    let line =
      text.split(whereSeparator: \.isNewline).last.map(String.init)?
      .trimmingCharacters(in: .whitespaces) ?? ""
    let clean = String(
      String.UnicodeScalarView(line.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
    return clean.count > 120 ? String(clean.prefix(119)) + "…" : clean
  }
}

/// Keeps only the last `limit` bytes appended, so a chatty remote cannot grow
/// memory for the whole upload. The tail is what matters: the remote path and
/// ssh's failure reason are both the last line.
final class DataBox: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()
  private let limit: Int

  init(limit: Int = SSHImagePasteUpload.outputLimit) {
    self.limit = limit
  }

  var value: Data { lock.withLock { data } }

  func append(_ bytes: ArraySlice<UInt8>) {
    lock.withLock {
      data.append(contentsOf: bytes.suffix(limit))
      if data.count > limit {
        data = Data(data.suffix(limit))
      }
    }
  }
}

private final class StatusBox: @unchecked Sendable {
  private let lock = NSLock()
  private var status: Int32 = 0
  var value: Int32 { lock.withLock { status } }
  func set(_ value: Int32) { lock.withLock { status = value } }
}

private final class LockedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var flag = false
  var value: Bool { lock.withLock { flag } }
  func set() { lock.withLock { flag = true } }
}
