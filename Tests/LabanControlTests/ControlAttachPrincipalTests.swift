import Foundation
import LabanControl
import LabanCore
import XCTest

final class ControlAttachPrincipalTests: XCTestCase {

  func testPrincipalInShellAgentLabanChainIsCodex() {
    let chain = ControlAttachProcessChain(entries: [
      identity(400, path: "/Applications/Laban.app/Contents/MacOS/laban"),
      identity(300, path: "/usr/local/bin/node"),
      identity(200, path: "/Applications/Codex.app/Contents/MacOS/Codex"),
      identity(100, path: "/bin/zsh"),
    ])
    let principal = chain.principal
    XCTAssertEqual(principal?.identity.executablePath, "/Applications/Codex.app/Contents/MacOS/Codex")
    XCTAssertEqual(principal?.isGenericInterpreter, false)
    XCTAssertEqual(principal?.isPersistable, false)
    XCTAssertEqual(chain.helperChainSummary, "zsh -> Codex -> node -> laban")
  }

  func testPrincipalSkipsGenericInterpreters() {
    let chain = ControlAttachProcessChain(entries: [
      identity(300, path: "/usr/local/bin/laban"),
      identity(200, path: "/usr/local/bin/python3"),
      identity(100, path: "/bin/zsh"),
    ])
    let principal = chain.principal
    XCTAssertEqual(principal?.identity.executablePath, "/bin/zsh")
    XCTAssertEqual(principal?.isGenericInterpreter, true)
    XCTAssertEqual(principal?.isPersistable, false)
  }

  func testPrincipalCannotPersistForGenericInterpreter() {
    let identity = identity(
      100,
      path: "/bin/zsh",
      signing: ControlCodeSigningIdentity(designatedRequirement: "req", isAdHocOrUnsigned: false))
    XCTAssertFalse(ControlAttachPrincipal.isPersistable(identity))
  }

  func testPrincipalCannotPersistForUnsignedBinary() {
    let identity = identity(
      100,
      path: "/usr/local/bin/myagent",
      signing: ControlCodeSigningIdentity(isAdHocOrUnsigned: true))
    XCTAssertFalse(ControlAttachPrincipal.isPersistable(identity))
  }

  func testPrincipalCanPersistForSignedNonGeneric() {
    let identity = identity(
      100,
      path: "/Applications/Codex.app/Contents/MacOS/Codex",
      signing: ControlCodeSigningIdentity(designatedRequirement: "anchor", isAdHocOrUnsigned: false))
    XCTAssertTrue(ControlAttachPrincipal.isPersistable(identity))
  }

  func testBundledLabanHelperIsNeverPrincipal() {
    let chain = ControlAttachProcessChain(entries: [
      identity(200, path: "/Applications/Laban.app/Contents/MacOS/laban"),
      identity(100, path: "/bin/zsh"),
    ])
    let principal = chain.principal
    XCTAssertEqual(principal?.identity.executablePath, "/bin/zsh")
    XCTAssertEqual(principal?.isGenericInterpreter, true)
    XCTAssertEqual(principal?.isPersistable, false)
  }

  private func identity(
    _ pid: pid_t,
    path: String,
    signing: ControlCodeSigningIdentity? = nil
  ) -> ControlProcessIdentity {
    ControlProcessIdentity(
      pid: pid,
      parentPID: nil,
      startTime: Date(),
      uid: 0,
      executablePath: path,
      arguments: [],
      signing: signing)
  }
}
