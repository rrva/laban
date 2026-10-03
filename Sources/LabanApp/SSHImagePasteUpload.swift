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

  /// Run `executable arguments` with `input` on stdin, killing it after
  /// `timeout`. Blocking — call off the main thread.
  static func runProcess(
    executable: URL, arguments: [String], environment: [String: String]?, input: Data,
    timeout: TimeInterval
  ) throws -> ProcessOutcome {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    if let environment { process.environment = environment }
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    // ssh exits without draining stdin on failure; a write to the closed pipe
    // must be an EPIPE error, not an app-killing SIGPIPE.
    _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    try process.run()

    let timedOut = LockedFlag()
    let killer = DispatchWorkItem {
      timedOut.set()
      process.terminate()
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

    let group = DispatchGroup()
    var out = Data()
    var err = Data()
    DispatchQueue.global().async(group: group) {
      try? stdin.fileHandleForWriting.write(contentsOf: input)
      try? stdin.fileHandleForWriting.close()
    }
    DispatchQueue.global().async(group: group) {
      out = stdout.fileHandleForReading.readDataToEndOfFile()
    }
    DispatchQueue.global().async(group: group) {
      err = stderr.fileHandleForReading.readDataToEndOfFile()
    }
    process.waitUntilExit()
    killer.cancel()
    group.wait()
    return ProcessOutcome(
      status: process.terminationStatus, stdout: out, stderr: err, timedOut: timedOut.value)
  }

  /// Upload `png` to the foreground ssh's host and return the remote path.
  /// Blocking — call off the main thread.
  static func upload(_ png: Data, via ssh: ForegroundSSH, timeout: TimeInterval = timeout)
    -> Result<String, Failure>
  {
    let fileName = SSHImageUploadScript.makeFileName()
    let arguments = ssh.commandLine.uploadArguments(
      remoteCommand: SSHImageUploadScript.remoteCommand(fileName: fileName))
    var environment = ProcessInfo.processInfo.environment
    if let authSocket = ssh.authSocket { environment["SSH_AUTH_SOCK"] = authSocket }
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

private final class LockedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var flag = false
  var value: Bool { lock.withLock { flag } }
  func set() { lock.withLock { flag = true } }
}
