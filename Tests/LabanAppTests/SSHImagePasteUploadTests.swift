import AppKit
import LabanCore
import XCTest

@testable import LabanApp

final class SSHImagePasteUploadTests: XCTestCase {
  private let onePixelPNG = Data(
    base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
  )!

  // MARK: PNG conversion

  func testPNGRepresentationIsUsedVerbatim() {
    let pasteboard = NSPasteboard.withUniqueName()
    pasteboard.declareTypes([.png], owner: nil)
    pasteboard.setData(onePixelPNG, forType: .png)
    XCTAssertEqual(SSHImagePasteUpload.pngData(from: pasteboard), .png(onePixelPNG))
  }

  func testTIFFOnlyPasteboardIsReencodedAsPNG() throws {
    let rep = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
        bitsPerPixel: 0))
    let tiff = try XCTUnwrap(rep.tiffRepresentation)
    let pasteboard = NSPasteboard.withUniqueName()
    pasteboard.declareTypes([.tiff], owner: nil)
    pasteboard.setData(tiff, forType: .tiff)

    guard case .png(let png) = SSHImagePasteUpload.pngData(from: pasteboard) else {
      return XCTFail("expected PNG")
    }
    XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    XCTAssertEqual(NSBitmapImageRep(data: png)?.pixelsWide, 1)
  }

  func testNoImageAndOversizedImage() {
    let empty = NSPasteboard.withUniqueName()
    XCTAssertEqual(SSHImagePasteUpload.pngData(from: empty), .unavailable)

    let pasteboard = NSPasteboard.withUniqueName()
    pasteboard.declareTypes([.png], owner: nil)
    pasteboard.setData(onePixelPNG, forType: .png)
    XCTAssertEqual(
      SSHImagePasteUpload.pngData(from: pasteboard, limit: 10), .tooLarge(onePixelPNG.count))
  }

  // MARK: Consent

  private final class MemoryConsentStore: SSHImageUploadConsentStore {
    var approved: Set<String> = []
    func isApproved(_ consentKey: String) -> Bool { approved.contains(consentKey) }
    func approve(_ consentKey: String) { approved.insert(consentKey) }
  }

  @MainActor
  func testConsentAsksOncePerDestinationAndRemembersUpload() throws {
    let store = MemoryConsentStore()
    let host = try XCTUnwrap(SSHCommandLine.parse(["ssh", "host"]))
    let other = try XCTUnwrap(SSHCommandLine.parse(["ssh", "-p", "2", "host"]))
    var prompts = 0

    XCTAssertFalse(
      SSHImagePasteUpload.confirmUpload(to: host, store: store) { _ in
        prompts += 1
        return false
      })
    XCTAssertTrue(store.approved.isEmpty, "Cancel is not remembered")
    XCTAssertTrue(
      SSHImagePasteUpload.confirmUpload(to: host, store: store) { _ in
        prompts += 1
        return true
      })
    XCTAssertTrue(
      SSHImagePasteUpload.confirmUpload(to: host, store: store) { _ in
        prompts += 1
        return false
      })
    XCTAssertEqual(prompts, 2, "an approved destination is not asked again")
    XCTAssertFalse(
      SSHImagePasteUpload.confirmUpload(to: other, store: store) { _ in
        prompts += 1
        return false
      })
    XCTAssertEqual(prompts, 3, "a different port is a different destination")
  }

  // MARK: Process + reply

  func testRunProcessPipesStdinAndCapturesOutput() throws {
    let payload = Data((0..<200_000).map { UInt8($0 % 251) })
    let outcome = try SSHImagePasteUpload.runProcess(
      executable: URL(fileURLWithPath: "/bin/cat"), arguments: [],
      environment: ProcessInfo.processInfo.environment, input: payload,
      timeout: 10)
    XCTAssertEqual(outcome.status, 0)
    XCTAssertFalse(outcome.timedOut)
    XCTAssertEqual(outcome.stdout, payload)
  }

  func testRunProcessTimesOut() throws {
    let start = Date()
    let outcome = try SSHImagePasteUpload.runProcess(
      executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
      environment: ProcessInfo.processInfo.environment,
      input: Data("x".utf8), timeout: 0.3)
    XCTAssertTrue(outcome.timedOut)
    XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    XCTAssertEqual(SSHImagePasteUpload.interpret(outcome, fileName: "a.png"), .failure(.timedOut))
  }

  /// A ProxyCommand-like child that ignores TERM/HUP and holds stderr must not
  /// stretch the wait past timeout + grace periods.
  /// GCD workers block SIGTERM; the spawned process must not inherit that, or
  /// the timeout's SIGTERM is ignored and only the SIGKILL fallback ends it.
  func testTimeoutSIGTERMReachesProcessSpawnedFromAGlobalQueue() throws {
    var result: Result<SSHImagePasteUpload.ProcessOutcome, Error>?
    let done = expectation(description: "runProcess")
    DispatchQueue.global().async {
      result = Result {
        try SSHImagePasteUpload.runProcess(
          executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
          environment: ProcessInfo.processInfo.environment, input: Data(), timeout: 0.3)
      }
      done.fulfill()
    }
    wait(for: [done], timeout: 10)
    let outcome = try XCTUnwrap(result).get()
    XCTAssertTrue(outcome.timedOut)
    XCTAssertEqual(outcome.status, 128 + SIGTERM, "ended by SIGTERM, not the SIGKILL fallback")
  }

  func testUploadPipesAreCloseOnExec() throws {
    let fds = try SSHImagePasteUpload.makePipe()
    defer { fds.forEach { close($0) } }
    for fd in fds {
      XCTAssertNotEqual(fcntl(fd, F_GETFD) & FD_CLOEXEC, 0, "fd \(fd)")
    }
  }

  func testTimeoutBoundsTheWaitEvenWhenAChildIgnoresTerm() throws {
    let start = Date()
    let outcome = try SSHImagePasteUpload.runProcess(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "(trap '' TERM HUP; sleep 20) & exec sleep 100"],
      environment: ProcessInfo.processInfo.environment, input: Data(), timeout: 0.5)
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertTrue(outcome.timedOut)
    XCTAssertLessThan(
      elapsed,
      0.5 + SSHImagePasteUpload.terminateGrace + SSHImagePasteUpload.drainGrace + 1.5)
  }

  /// ssh exited fine but a straggler still holds stderr: return after the
  /// drain grace with what was read, not when the straggler exits.
  func testExitedProcessWithStragglerHoldingStderrReturnsPromptly() throws {
    let start = Date()
    let outcome = try SSHImagePasteUpload.runProcess(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "(trap '' TERM HUP; sleep 20) >/dev/null & printf ok"],
      environment: ProcessInfo.processInfo.environment, input: Data(), timeout: 10)
    XCTAssertLessThan(Date().timeIntervalSince(start), SSHImagePasteUpload.drainGrace + 2)
    XCTAssertFalse(outcome.timedOut)
    XCTAssertEqual(outcome.status, 0)
    XCTAssertEqual(outcome.stdout, Data("ok".utf8))
  }

  func testUploadUsesTheRunningSSHsAgentOrNone() {
    let base = ["SSH_AUTH_SOCK": "/laban/agent", "HOME": "/h"]
    XCTAssertEqual(
      SSHImagePasteUpload.uploadEnvironment(base: base, authSocket: "/ssh/agent"),
      ["SSH_AUTH_SOCK": "/ssh/agent", "HOME": "/h"])
    XCTAssertEqual(
      SSHImagePasteUpload.uploadEnvironment(base: base, authSocket: nil), ["HOME": "/h"])
  }

  func testRemotePathIsQuotedLikeADroppedFile() {
    XCTAssertEqual(
      TerminalDropText.format(paths: ["/home/a b/.cache/laban/paste/x.png"]),
      "'/home/a b/.cache/laban/paste/x.png' ")
  }

  func testEarlyExitDoesNotKillTheAppWithSIGPIPE() throws {
    let outcome = try SSHImagePasteUpload.runProcess(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "echo 'Permission denied (publickey).' >&2; exit 255"],
      environment: ProcessInfo.processInfo.environment,
      input: Data(count: 4 * 1024 * 1024), timeout: 10)
    XCTAssertEqual(
      SSHImagePasteUpload.interpret(outcome, fileName: "a.png"),
      .failure(.exit(status: 255, stderr: "Permission denied (publickey).")))
  }

  func testInterpretValidatesThePrintedPath() {
    let name = SSHImageUploadScript.makeFileName()
    let ok = SSHImagePasteUpload.ProcessOutcome(
      status: 0, stdout: Data("/home/u/.cache/laban/paste/\(name)".utf8), stderr: Data(),
      timedOut: false)
    XCTAssertEqual(
      SSHImagePasteUpload.interpret(ok, fileName: name),
      .success("/home/u/.cache/laban/paste/\(name)"))
    var wrong = ok
    wrong.stdout = Data("/tmp/someone-else.png".utf8)
    XCTAssertEqual(SSHImagePasteUpload.interpret(wrong, fileName: name), .failure(.unexpectedReply))
  }

  func testFailureReasonIsShortAndClean() {
    XCTAssertEqual(
      SSHImagePasteUpload.lastLine(of: Data("debug\nssh: bad\u{1b}[31m thing\n\n".utf8)),
      "ssh: bad[31m thing")
    XCTAssertEqual(
      SSHImagePasteUpload.lastLine(of: Data(String(repeating: "x", count: 500).utf8)).count, 120)
    XCTAssertFalse(SSHImagePasteUpload.Failure.exit(status: 255, stderr: "").reason.contains("%d"))
  }

  func testForegroundSSHIgnoresANonSSHProcess() {
    XCTAssertNil(SSHImagePasteUpload.foregroundSSH(pid: Int(getpid())))
    XCTAssertNil(SSHImagePasteUpload.foregroundSSH(pid: nil))
  }

  /// Real round trip through `/usr/bin/ssh`; opt-in because it needs Remote
  /// Login and key auth: `LABAN_SSH_E2E_HOST=localhost swift test …`.
  func testRealUploadRoundTripWhenHostConfigured() throws {
    guard let host = ProcessInfo.processInfo.environment["LABAN_SSH_E2E_HOST"] else {
      throw XCTSkip("set LABAN_SSH_E2E_HOST to run")
    }
    let commandLine = try XCTUnwrap(SSHCommandLine.parse(["ssh", "-t", host, "tmux", "attach"]))
    let ssh = SSHImagePasteUpload.ForegroundSSH(
      executable: URL(fileURLWithPath: "/usr/bin/ssh"), commandLine: commandLine,
      authSocket: ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"])
    let path = try SSHImagePasteUpload.upload(onePixelPNG, via: ssh).get()
    XCTAssertTrue(path.hasSuffix(".png"), path)
    if host == "localhost" {
      XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), onePixelPNG)
      try FileManager.default.removeItem(atPath: path)
    }
  }

  // MARK: Toast

  func testUploadToastMessages() {
    XCTAssertTrue(ClipboardCopyToastView.uploadingImageMessage(destination: "dev").contains("dev"))
    let failed = ClipboardCopyToastView.imageUploadFailedMessage(reason: "timed out")
    XCTAssertTrue(failed.contains("timed out"))
    XCTAssertFalse(failed.contains("%@"))
  }

  @MainActor
  func testToastNeverOutgrowsTheTerminal() {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
    let toast = ClipboardCopyToastView(frame: .zero)
    container.addSubview(toast)
    toast.show(
      message: String(repeating: "long reason ", count: 40), in: container.bounds, duration: 1)
    XCTAssertLessThanOrEqual(toast.frame.width, 300 - 32)
    toast.hide()
  }
}
