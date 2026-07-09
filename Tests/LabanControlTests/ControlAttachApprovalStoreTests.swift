import Foundation
import LabanControl
import LabanCore
import XCTest

final class ControlAttachApprovalStoreTests: XCTestCase {

  private let signer = ControlAttachApprovalRecordHMACSigner(key: Data("test-approval-key".utf8))

  func testAddAndRevoke() {
    let (_, store) = makeStore()

    let record = makeRecord(id: "r1", displayName: "Codex", sessionID: "s1")
    store.add(record)
    XCTAssertEqual(store.loadAll().count, 1)

    store.revoke(id: "r1")
    XCTAssertTrue(store.loadAll().first?.isRevoked == true)
  }

  func testFindMatchingRequiresSessionAndShell() {
    let (_, store) = makeStore()

    let record = makeRecord(
      id: "r1",
      displayName: "Codex",
      sessionID: "s1",
      shellIdentityFingerprint: "fingerprint-a",
      allowedRouteIDs: ["GET /debug/state"],
      allowedIntentIDs: ["app.state"])
    store.add(record)

    let principal = makePrincipal(path: "/Applications/Codex.app/Contents/MacOS/Codex")
    let match = store.findMatching(
      principal: principal,
      sessionID: "s1",
      shellIdentityFingerprint: "fingerprint-a",
      routeID: "GET /debug/state",
      intentID: "app.state",
      capabilities: Set([.observe]),
      dataSensitivity: "nonSensitiveState",
      sideEffectClass: "read")
    XCTAssertEqual(match?.id, "r1")

    let noMatch = store.findMatching(
      principal: principal,
      sessionID: "s2",
      shellIdentityFingerprint: "fingerprint-a",
      routeID: "GET /debug/state",
      intentID: "app.state",
      capabilities: Set([.observe]),
      dataSensitivity: "nonSensitiveState",
      sideEffectClass: "read")
    XCTAssertNil(noMatch)
  }

  func testFindMatchingRejectsDifferentRouteOrIntent() {
    let (_, store) = makeStore()

    let record = makeRecord(
      id: "r1",
      displayName: "Codex",
      allowedRouteIDs: ["GET /debug/state"],
      allowedIntentIDs: ["app.state"],
      maxDataSensitivity: "nonSensitiveState",
      allowedSideEffectClasses: ["read"])
    store.add(record)

    let principal = makePrincipal()
    let match = store.findMatching(
      principal: principal,
      sessionID: "s1",
      shellIdentityFingerprint: "f1",
      routeID: "POST /debug/actions",
      intentID: "command.propose",
      capabilities: Set([.propose]),
      dataSensitivity: "nonSensitiveState",
      sideEffectClass: "write")
    XCTAssertNil(match)
  }

  func testRevokedRecordNotAutoApproved() {
    let (_, store) = makeStore()

    let record = makeRecord(id: "r1", displayName: "Codex")
    store.add(record)
    store.revoke(id: "r1")

    let principal = makePrincipal()
    let match = store.findMatching(
      principal: principal,
      sessionID: "s1",
      shellIdentityFingerprint: "f1",
      routeID: "GET /debug/state",
      intentID: "app.state",
      capabilities: Set([.observe]),
      dataSensitivity: "nonSensitiveState",
      sideEffectClass: "read")
    XCTAssertNil(match)
  }

  func testTamperedRecordIsRejected() throws {
    let (defaults, store) = makeStore()

    let record = makeRecord(id: "r1", displayName: "Codex")
    store.add(record)

    guard let data = defaults.data(forKey: ControlAttachApprovalStore.defaultsKey) else {
      XCTFail("missing stored data")
      return
    }
    var records = try JSONDecoder().decode([ControlAttachApprovalRecord].self, from: data)
    records[0].sessionID = "tampered"
    let tamperedData = try JSONEncoder().encode(records)
    defaults.set(tamperedData, forKey: ControlAttachApprovalStore.defaultsKey)

    XCTAssertEqual(store.loadAll().count, 0)
  }

  func testDefaultSignerUsesFileBackedSigner() throws {
    let dir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    setenv("LABAN_CONTROL_DIR", dir.path, 1)
    defer { unsetenv("LABAN_CONTROL_DIR") }

    let signer = try XCTUnwrap(ControlAttachApprovalStore.defaultSigner())
    XCTAssertTrue(signer is ControlAttachApprovalRecordFileSigner)
    #if canImport(Security)
      XCTAssertFalse(signer is ControlAttachApprovalRecordKeychainSigner)
    #endif
  }

  func testFileSignerCreatesPrivateStableKey() throws {
    let dir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let keyURL = dir.appendingPathComponent("approval.key")
    let signer = ControlAttachApprovalRecordFileSigner(keyURL: keyURL)

    let signed = signer.sign(makeRecord(id: "file-key", displayName: "Codex"))

    XCTAssertTrue(signer.isValid(signed))
    XCTAssertTrue(ControlAttachApprovalRecordFileSigner(keyURL: keyURL).isValid(signed))
    XCTAssertEqual(try posixPermissions(at: dir), 0o700)
    XCTAssertEqual(try posixPermissions(at: keyURL), 0o600)
  }

  func testFileSignerRejectsSymlinkedKeyDirectory() throws {
    let base = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let target = base.appendingPathComponent("target", isDirectory: true)
    let link = base.appendingPathComponent("link", isDirectory: true)
    try FileManager.default.createDirectory(
      at: target,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    let record = makeRecord(id: "symlink-key", displayName: "Codex")
    let signed = ControlAttachApprovalRecordFileSigner(
      keyURL: target.appendingPathComponent("approval.key")
    ).sign(record)

    let symlinkSigner = ControlAttachApprovalRecordFileSigner(
      keyURL: link.appendingPathComponent("approval.key"))
    XCTAssertFalse(symlinkSigner.isValid(signed))
    XCTAssertEqual(symlinkSigner.sign(record).hmac, "")
  }

  #if canImport(Security) && DEBUG
    func testKeychainSignerRNGFailureFallbackIsNeverAllZeros() {
      // Regression for a defect where SecRandomCopyBytes failure produced a
      // predictable all-zeros HMAC key. The signer must fall back to
      // arc4random_buf (which cannot fail) instead, so it stays functional
      // without a static, forgeable key. Exercise the fallback path
      // directly since forcing SecRandomCopyBytes to fail is not feasible
      // in this harness.
      for _ in 0..<8 {
        let key = ControlAttachApprovalRecordKeychainSigner.rngFailureFallbackKeyForTests()
        XCTAssertEqual(key.count, 32)
        XCTAssertNotEqual(key, Data(repeating: 0, count: 32))
      }
    }
  #endif

  // MARK: - Helpers

  private func makeStore() -> (UserDefaults, ControlAttachApprovalStore) {
    let suiteName = "test-laban-approval-store-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    return (defaults, ControlAttachApprovalStore(defaults: defaults, signer: signer))
  }

  private func makeTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-approval-store-\(UUID().uuidString)", isDirectory: true)
  }

  private func posixPermissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
    return permissions.intValue
  }

  private func makeRecord(
    id: String,
    displayName: String,
    sessionID: String = "s1",
    shellIdentityFingerprint: String = "f1",
    allowedRouteIDs: [String] = ["GET /debug/state"],
    allowedIntentIDs: [String] = ["app.state"],
    capabilities: [Capability] = [.observe],
    maxDataSensitivity: String = "nonSensitiveState",
    allowedSideEffectClasses: [String] = ["read"],
    principalIdentityFingerprint: String? = nil
  ) -> ControlAttachApprovalRecord {
    let resolvedPrincipalIdentityFingerprint =
      principalIdentityFingerprint ?? makePrincipal().identity.stablePrincipalFingerprint
    return ControlAttachApprovalRecord(
      id: id,
      displayName: displayName,
      signing: ControlCodeSigningIdentity(
        designatedRequirement: "req",
        isAdHocOrUnsigned: false),
      sessionID: sessionID,
      shellIdentityFingerprint: shellIdentityFingerprint,
      allowedRouteIDs: allowedRouteIDs,
      allowedIntentIDs: allowedIntentIDs,
      capabilities: capabilities,
      maxDataSensitivity: maxDataSensitivity,
      allowedSideEffectClasses: allowedSideEffectClasses,
      principalIdentityFingerprint: resolvedPrincipalIdentityFingerprint)
  }

  private func makePrincipal(path: String = "/Applications/Codex.app/Contents/MacOS/Codex")
    -> ControlAttachPrincipal
  {
    ControlAttachPrincipal(
      identity: ControlProcessIdentity(
        pid: 100,
        parentPID: nil,
        startTime: Date(timeIntervalSince1970: 0),
        uid: 0,
        executablePath: path,
        arguments: [],
        signing: ControlCodeSigningIdentity(
          designatedRequirement: "req",
          isAdHocOrUnsigned: false)),
      isGenericInterpreter: false,
      isPersistable: true,
      helperChain: [])
  }
}
