import Foundation
import XCTest

@testable import LabanCore

final class SSHCommandLineTests: XCTestCase {
  private func upload(_ argv: [String]) -> [String]? {
    SSHCommandLine.parse(argv)?.uploadArguments(remoteCommand: "CMD")
  }

  private let forced = SSHCommandLine.forcedOptions

  func testPlainHost() {
    XCTAssertEqual(upload(["ssh", "host"]), forced + ["host", "CMD"])
  }

  func testAbsoluteExecutablePathIsAccepted() {
    XCTAssertEqual(upload(["/opt/homebrew/bin/ssh", "u@h"]), forced + ["u@h", "CMD"])
  }

  func testNonSSHExecutableIsRefused() {
    XCTAssertNil(SSHCommandLine.parse(["mosh", "host"]))
    XCTAssertNil(SSHCommandLine.parse(["/usr/bin/sshd", "host"]))
    XCTAssertNil(SSHCommandLine.parse([]))
  }

  func testRemoteCommandIsDropped() {
    XCTAssertEqual(upload(["ssh", "host", "tmux", "attach", "-t", "0"]), forced + ["host", "CMD"])
  }

  func testOptionsAfterDestinationAreKeptLikeOpenSSH() {
    XCTAssertEqual(
      upload(["ssh", "host", "-p", "2222", "-t", "claude", "--resume"]),
      forced + ["-p", "2222", "host", "CMD"])
  }

  func testDoubleDashEndsOptions() {
    XCTAssertEqual(upload(["ssh", "--", "host", "-x"]), forced + ["host", "CMD"])
    XCTAssertEqual(upload(["ssh", "host", "--", "-p", "9"]), forced + ["host", "CMD"])
  }

  func testJumpHostAndIdentityAndConfig() {
    XCTAssertEqual(
      upload([
        "ssh", "-J", "bastion", "-i", "/Users/me/.ssh/id ed", "-F", "/tmp/cfg", "dev",
      ]),
      forced + ["-J", "bastion", "-i", "/Users/me/.ssh/id ed", "-F", "/tmp/cfg", "dev", "CMD"])
  }

  func testJoinedArgumentFormsAreSplit() {
    XCTAssertEqual(
      upload(["ssh", "-p22", "-oProxyJump=bastion", "-lroot", "host"]),
      forced + ["-p", "22", "-o", "ProxyJump=bastion", "-l", "root", "host", "CMD"])
  }

  func testOptionValueWithSpacesSurvivesAsOneToken() {
    XCTAssertEqual(
      upload(["ssh", "-o", "ProxyCommand ssh -W %h:%p bastion", "host"]),
      forced + ["-o", "ProxyCommand ssh -W %h:%p bastion", "host", "CMD"])
  }

  func testBundledFlagsAreExpandedAndSessionFlagsStripped() {
    // -A agent forwarding and -t tty are stripped; -C compression is kept.
    XCTAssertEqual(upload(["ssh", "-AtC", "host"]), forced + ["-C", "host", "CMD"])
    XCTAssertEqual(upload(["ssh", "-tt", "host"]), forced + ["host", "CMD"])
    XCTAssertEqual(
      upload(["ssh", "-qp2200", "host"]), forced + ["-q", "-p", "2200", "host", "CMD"])
  }

  func testStdinAndBackgroundAndVerbosityFlagsAreStripped() {
    XCTAssertEqual(
      upload(["ssh", "-n", "-f", "-T", "-v", "-M", "-X", "-Y", "host"]),
      forced + ["host", "CMD"])
  }

  func testForwardOnlyAndNoStdinSessionsAreRefused() {
    for argv in [
      ["ssh", "-N", "-L", "8080:localhost:80", "host"],
      ["ssh", "-fN", "host"],
      ["ssh", "-o", "SessionType=none", "host"],
      ["ssh", "-oSessionType none", "host"],
      ["ssh", "-o", "sessiontype=subsystem", "host"],
      ["ssh", "-o", "StdinNull=yes", "host"],
      ["ssh", "host", "-o", "stdinnull yes"],
    ] {
      XCTAssertNil(SSHCommandLine.parse(argv), "\(argv)")
    }
    XCTAssertNotNil(SSHCommandLine.parse(["ssh", "-o", "SessionType=default", "host"]))
    XCTAssertNotNil(SSHCommandLine.parse(["ssh", "-o", "StdinNull=no", "host"]))
  }

  /// `ssh -G` resolves the effective configuration without connecting: the
  /// forced options must win over a user's conflicting `-o` (first value wins).
  func testForcedOptionsWinInOpenSSHEffectiveConfig() throws {
    let ssh = "/usr/bin/ssh"
    guard FileManager.default.isExecutableFile(atPath: ssh) else {
      throw XCTSkip("no /usr/bin/ssh")
    }
    let parsed = try XCTUnwrap(
      SSHCommandLine.parse([
        "ssh", "-A", "-X", "-t", "-o", "BatchMode=no", "-o", "ForkAfterAuthentication=yes",
        "-o", "ForwardAgent=yes", "-o", "ForwardX11=yes", "-o", "RemoteCommand=tmux",
        "-o", "ControlMaster=yes", "-o", "PermitLocalCommand=yes", "-o", "ConnectTimeout=99",
        "-o", "ClearAllForwardings=no", "-o", "RequestTTY=force", "-F", "/dev/null", "host",
      ]))
    var arguments = parsed.uploadArguments(remoteCommand: "true")
    arguments.removeLast()  // -G takes no remote command
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ssh)
    process.arguments = ["-G"] + arguments
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    var config: [String: String] = [:]
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
      let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
      if parts.count == 2 { config[parts[0]] = parts[1] }
    }
    XCTAssertEqual(config["batchmode"], "yes")
    XCTAssertEqual(config["connecttimeout"], "10")
    XCTAssertEqual(config["clearallforwardings"], "yes")
    XCTAssertEqual(config["controlmaster"], "false")
    XCTAssertEqual(config["permitlocalcommand"], "no")
    XCTAssertNil(config["remotecommand"])
    XCTAssertEqual(config["requesttty"], "false")
    XCTAssertEqual(config["stdinnull"], "no")
    XCTAssertEqual(config["sessiontype"], "default")
    XCTAssertEqual(config["forkafterauthentication"], "no")
    XCTAssertEqual(config["forwardagent"], "no")
    XCTAssertEqual(config["forwardx11"], "no")
  }

  func testForwardsAreStripped() {
    XCTAssertEqual(
      upload([
        "ssh", "-L", "8080:localhost:80", "-R9000:localhost:9000", "-D", "1080", "-w", "0:1", "-4",
        "host",
      ]),
      forced + ["-4", "host", "CMD"])
  }

  func testRefusedOptions() {
    for argv in [
      ["ssh", "-O", "check", "host"],
      ["ssh", "-W", "h:22", "host"],
      ["ssh", "-Q", "cipher"],
      ["ssh", "-G", "host"],
      ["ssh", "-V"],
      ["ssh", "-s", "host", "sftp"],
      ["ssh", "-vG", "host"],
    ] {
      XCTAssertNil(SSHCommandLine.parse(argv), "\(argv)")
    }
  }

  func testMissingDestinationOrArgumentIsRefused() {
    XCTAssertNil(SSHCommandLine.parse(["ssh"]))
    XCTAssertNil(SSHCommandLine.parse(["ssh", "-p", "22"]))
    XCTAssertNil(SSHCommandLine.parse(["ssh", "host", "-p"]))
    XCTAssertNil(SSHCommandLine.parse(["ssh", "-i"]))
    XCTAssertNil(SSHCommandLine.parse(["ssh", "-"]))
  }

  func testUnknownOptionIsRefused() {
    XCTAssertNil(SSHCommandLine.parse(["ssh", "-Z", "host"]))
    XCTAssertNil(SSHCommandLine.parse(["ssh", "--verbose", "host"]))
  }

  func testDestinationWithWhitespaceOrControlIsRefused() {
    XCTAssertNil(SSHCommandLine.parse(["ssh", "--", "a b"]))
    XCTAssertNil(SSHCommandLine.parse(["ssh", "host\u{1b}"]))
  }

  func testURIDestination() {
    XCTAssertEqual(upload(["ssh", "ssh://me@host:2222"]), forced + ["ssh://me@host:2222", "CMD"])
  }

  func testForcedOptionsComeFirstSoTheyWin() {
    let args = try? XCTUnwrap(upload(["ssh", "-o", "BatchMode=no", "host"]))
    XCTAssertEqual(args?.prefix(forced.count).map { $0 }, forced)
    XCTAssertEqual(args?.firstIndex(of: "BatchMode=yes"), 2)
    XCTAssertTrue(forced.contains("ClearAllForwardings=yes"))
    XCTAssertTrue(forced.contains("ConnectTimeout=10"))
    XCTAssertEqual(forced.first, "-T")
  }

  func testConsentKeyIncludesLoginAndPort() {
    XCTAssertEqual(SSHCommandLine.parse(["ssh", "host"])?.consentKey, "d=host&l=-&p=-")
    XCTAssertEqual(
      SSHCommandLine.parse(["ssh", "-p", "2", "-l", "bob", "host"])?.consentKey, "d=host&l=bob&p=2")
    XCTAssertNotEqual(
      SSHCommandLine.parse(["ssh", "-p", "2", "host:1"])?.consentKey,
      SSHCommandLine.parse(["ssh", "-p", "1:2", "host"])?.consentKey)
    XCTAssertNotEqual(
      SSHCommandLine.parse(["ssh", "-l", "a&p=2", "host"])?.consentKey,
      SSHCommandLine.parse(["ssh", "-l", "a", "-p", "2", "host"])?.consentKey)
    XCTAssertNotEqual(
      SSHCommandLine.parse(["ssh", "-l", "", "host"])?.consentKey,
      SSHCommandLine.parse(["ssh", "host"])?.consentKey)
    XCTAssertEqual(SSHCommandLine.parse(["ssh", "-p1", "-p2", "host"])?.port, "2")
    XCTAssertEqual(
      SSHCommandLine.parse(["ssh", "-p", "2", "host"])?.displayDestination, "host -p 2")
  }
}

final class SSHImageUploadScriptTests: XCTestCase {
  private let fileName = "0a1b2c3d-0000-4000-8000-00000000abcd.png"

  func testFileNameIsLowercaseUUIDPng() {
    let name = SSHImageUploadScript.makeFileName()
    XCTAssertTrue(SSHImageUploadScript.isSafeFileName(name), name)
    XCTAssertEqual(name.count, 40)
  }

  func testRemoteCommandShape() {
    let command = SSHImageUploadScript.remoteCommand(fileName: fileName)
    XCTAssertTrue(command.hasPrefix("sh -c '"))
    XCTAssertTrue(command.hasSuffix("'"))
    XCTAssertEqual(command.filter { $0 == "'" }.count, 2, "exactly one single-quoted script")
    XCTAssertTrue(command.contains("umask 077"))
    XCTAssertTrue(command.contains(fileName))
  }

  func testRemotePathValidation() {
    let ok = "/home/me/.cache/laban/paste/\(fileName)"
    XCTAssertEqual(
      SSHImageUploadScript.remotePath(fromStdout: Data(ok.utf8), fileName: fileName), ok)
    XCTAssertEqual(
      SSHImageUploadScript.remotePath(
        fromStdout: Data("motd noise\n\(ok)".utf8), fileName: fileName),
      ok, "noise printed by shell startup files before the path is tolerated")
    XCTAssertEqual(
      SSHImageUploadScript.remotePath(fromStdout: Data("\(ok)\r\n".utf8), fileName: fileName), ok)
    for bad in [
      "", "relative/\(fileName)", "/tmp/other.png", "/tmp/\(fileName).txt",
      "/tmp/\u{1b}]0;x/\(fileName)", "\(ok)\ntrailing",
    ] {
      XCTAssertNil(
        SSHImageUploadScript.remotePath(fromStdout: Data(bad.utf8), fileName: fileName), bad)
    }
    XCTAssertNil(
      SSHImageUploadScript.remotePath(fromStdout: Data([0xFF, 0xFE]), fileName: fileName))
  }

  /// Run the remote command through each local shell exactly as sshd would
  /// hand it to a login shell (`$SHELL -c '<command>'`), and check the file is
  /// written byte-exact, mode 0600, and its path printed.
  func testRemoteCommandWritesPrivateFileUnderEachShell() throws {
    let shells = [
      "/bin/sh", "/bin/bash", "/bin/zsh", "/opt/homebrew/bin/fish", "/usr/local/bin/fish",
    ]
    .filter { FileManager.default.isExecutableFile(atPath: $0) }
    XCTAssertFalse(shells.isEmpty)
    for shell in shells {
      let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("laban-ssh-upload-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: home) }
      let name = SSHImageUploadScript.makeFileName()
      let payload = Data((0..<4096).map { UInt8($0 % 256) })

      let process = Process()
      process.executableURL = URL(fileURLWithPath: shell)
      process.arguments = ["-c", SSHImageUploadScript.remoteCommand(fileName: name)]
      process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
      let stdin = Pipe()
      let stdout = Pipe()
      process.standardInput = stdin
      process.standardOutput = stdout
      try process.run()
      stdin.fileHandleForWriting.write(payload)
      try stdin.fileHandleForWriting.close()
      let out = stdout.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      XCTAssertEqual(process.terminationStatus, 0, shell)

      let path = try XCTUnwrap(
        SSHImageUploadScript.remotePath(fromStdout: out, fileName: name), shell)
      XCTAssertEqual(path, home.path + "/.cache/laban/paste/" + name, shell)
      XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), payload, shell)
      let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
      XCTAssertEqual(mode, 0o600, shell)
    }
  }
}

final class ClipboardPasteActionTests: XCTestCase {
  private let ssh = SSHCommandLine(options: [], destination: "host")

  func testTextWinsEvenWithImage() {
    XCTAssertEqual(ClipboardPasteAction.decide(hasText: true, hasImage: true, ssh: ssh), .pasteText)
    XCTAssertEqual(
      ClipboardPasteAction.decide(hasText: true, hasImage: false, ssh: nil), .pasteText)
  }

  func testImageOnlyOverSSHUploads() {
    XCTAssertEqual(
      ClipboardPasteAction.decide(hasText: false, hasImage: true, ssh: ssh), .uploadOverSSH(ssh))
  }

  func testImageOnlyLocallyForwardsControlV() {
    XCTAssertEqual(
      ClipboardPasteAction.decide(hasText: false, hasImage: true, ssh: nil), .forwardControlV)
  }

  func testEmptyPasteboardDoesNothing() {
    XCTAssertEqual(
      ClipboardPasteAction.decide(hasText: false, hasImage: false, ssh: ssh),
      ClipboardPasteAction.none)
  }
}

final class SSHImageUploadConsentStoreTests: XCTestCase {
  func testApprovalIsRememberedPerDestination() throws {
    let suite = "laban.tests.sshconsent.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = UserDefaultsSSHImageUploadConsentStore(defaults: defaults)
    XCTAssertFalse(store.isApproved("host"))
    store.approve("host")
    store.approve("host")
    XCTAssertTrue(store.isApproved("host"))
    XCTAssertFalse(store.isApproved("other"))
    XCTAssertEqual(
      defaults.stringArray(forKey: UserDefaultsSSHImageUploadConsentStore.defaultsKey), ["host"])

    let reopened = UserDefaultsSSHImageUploadConsentStore(defaults: defaults)
    XCTAssertTrue(reopened.isApproved("host"))
  }
}
