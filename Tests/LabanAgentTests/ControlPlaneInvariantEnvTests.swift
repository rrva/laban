import Foundation
import LabanCore
import XCTest

@testable import LabanAgent

/// I6 from `docs/process/control-plane-threat-model.md`: no long-lived
/// bearer in any child environment. This is one of the 11 named invariant
/// tests the threat model requires, but it lives here rather than in
/// `Tests/LabanControlTests/ControlPlaneInvariantTests.swift` because the
/// child-environment builder (`ChildLauncher`) is defined in the `LabanAgent`
/// module, and `LabanControlTests` only depends on `LabanControl`/`LabanCore`
/// (see the `LabanControlTests` target in `Package.swift`), so it cannot
/// `@testable import LabanAgent`. This is a deliberate, documented deviation
/// from having all 11 invariant tests in one file; see the threat model's I6
/// entry and `ControlPlaneInvariantTests.swift`'s header comment.
final class ControlPlaneInvariantEnvTests: XCTestCase {
  func testNoBearerTokenEnvironmentKeysInChildEnvBuilder() throws {
    let config = try ChildLauncher.prepareConfiguration(
      command: ["env"],
      inheritedEnvironment: [
        ControlEnvironmentKeys.controlURL: "keep",
        ControlEnvironmentKeys.sessionAttach: "one-shot-bootstrap-must-not-leak",
        ControlEnvironmentKeys.attachEnvOptIn: "1",
        "PATH": "/usr/bin:/bin",
      ],
      agentControlURL: "unix:///proxy.sock")

    // The broker child environment must carry the session-scoped proxy URL...
    XCTAssertEqual(
      config.environment[ControlEnvironmentKeys.agentControlURL], "unix:///proxy.sock")
    // ...and preserve the app control URL for descendant discovery/health...
    XCTAssertEqual(config.environment[ControlEnvironmentKeys.controlURL], "keep")
    // ...but never the one-shot C14 bootstrap value (contract C14: it is
    // spent on first redemption, not handed to every descendant)...
    XCTAssertNil(config.environment[ControlEnvironmentKeys.sessionAttach])
    // ...and never the explicit-opt-in flag that would let a descendant
    // re-request env-based attach.
    XCTAssertNil(config.environment[ControlEnvironmentKeys.attachEnvOptIn])

    // No key in the resulting environment contains a raw bearer/bootstrap
    // value under any name: the only control-plane keys present at all are
    // the two explicitly allowed above.
    let controlPlaneKeys: Set<String> = [
      ControlEnvironmentKeys.controlURL,
      ControlEnvironmentKeys.sessionAttach,
      ControlEnvironmentKeys.agentControlURL,
      ControlEnvironmentKeys.controlServerForceDisable,
      ControlEnvironmentKeys.attachEnvOptIn,
      ControlEnvironmentKeys.agentAttachedSessionAtLaunch,
    ]
    let presentControlPlaneKeys = Set(config.environment.keys).intersection(controlPlaneKeys)
    XCTAssertEqual(
      presentControlPlaneKeys,
      [ControlEnvironmentKeys.controlURL, ControlEnvironmentKeys.agentControlURL],
      "the child environment must contain exactly the app control URL and the agent proxy "
        + "URL among control-plane keys, never a bootstrap or opt-in flag")
  }
}
