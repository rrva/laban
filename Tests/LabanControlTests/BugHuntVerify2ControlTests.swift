import Darwin
import Foundation
import LabanCore
import XCTest

@testable import LabanControl

/// Bug-hunt 2026-10-05 #17 minors in LabanControl. Correct-behavior assertions
/// are wrapped in `XCTExpectFailure` so the suite stays green while each
/// defect exists and turns red once it is fixed.
final class BugHuntVerify2ControlTests: XCTestCase {

  /// `readHTTPRequest` keeps only `prefix(contentLength)` of the bytes it read
  /// past the header terminator; a second keep-alive request that arrived in
  /// the same segment is discarded, so the next read times out -> 400 + close.
  func testBug17_PipelinedKeepAliveRequestIsDroppedAnd400s() throws {
    let server = LabanControlServer(
      router: OkRouter(), surface: .gui, requestReadTimeout: 1)
    let start = try server.start()
    defer { server.stop() }

    let fd = try ControlUDSClient.connect(socketPath: start.socketPath)
    defer { Darwin.close(fd) }
    try ControlFD.setNoSigPipe(fd)
    let one =
      "GET /debug/state HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(start.appObserveToken)\r\nConnection: keep-alive\r\n\r\n"
    let pipelined = Data((one + one).utf8)
    _ = pipelined.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }

    var raw = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    let deadline = Date().addingTimeInterval(4)
    while Date() < deadline {
      var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let ready = poll(&pfd, 1, Int32(max(0, deadline.timeIntervalSinceNow) * 1000))
      if ready <= 0 { break }
      let n = recv(fd, &buffer, buffer.count, 0)
      if n <= 0 { break }
      raw.append(contentsOf: buffer[0..<n])
    }
    let text = String(data: raw, encoding: .utf8) ?? ""
    let statuses = text.components(separatedBy: "HTTP/1.1 ").dropFirst().map { $0.prefix(3) }

    XCTExpectFailure("bug #17: the second pipelined request is dropped; server answers 200 then 400")
    XCTAssertEqual(statuses, ["200", "200"], "both pipelined requests must be answered")
  }

  /// `ControlAttachApprovalStore.add` appends with no dedupe or cap. Each app
  /// restart / new shell yields a new pid+start-time shell fingerprint, so
  /// records for dead shells are never matched again yet are kept forever.
  func testBug17_AlwaysAllowApprovalRecordsGrowWithoutBound() {
    let suiteName = "test-bughunt-approval-growth-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = ControlAttachApprovalStore(defaults: defaults, signer: nil)

    for restart in 0..<500 {
      store.add(
        ControlAttachApprovalRecord(
          id: "approval-\(restart)",
          displayName: "Codex",
          signing: ControlCodeSigningIdentity(),
          sessionID: "tab-1",
          shellIdentityFingerprint: "session=tab-1;pid=\(1000 + restart);start=\(restart)",
          allowedRouteIDs: ["route"],
          allowedIntentIDs: ["terminal.getText"],
          capabilities: [.observeSensitive],
          maxDataSensitivity: "scrollback",
          allowedSideEffectClasses: ["none"],
          principalIdentityFingerprint: "principal"))
    }
    // Identical re-approval of the live shell is not deduped either.
    let live = store.loadAll().last!
    store.add(live)

    let count = store.loadAll().count
    XCTExpectFailure("bug #17: approval records are append-only (no dedupe, cap, or pruning)")
    XCTAssertLessThanOrEqual(count, 64, "stored approval records must be bounded; got \(count)")
  }
}

private struct OkBody: Encodable { let ok = true }

private final class OkRouter: IntentRouter {
  func route(_ intent: Intent) -> ControlResponse { .json(OkBody()) }
  func query(_ query: Query) -> ControlResponse { .json(OkBody()) }
  func query(_ query: LegacyDebugQueryInput) -> ControlResponse { .json(OkBody()) }
  func control(_ input: LegacyDebugControlInput) -> ControlResponse { .json(OkBody()) }
  func artifact(_ request: ArtifactRequest) -> ControlResponse? { nil }
}
