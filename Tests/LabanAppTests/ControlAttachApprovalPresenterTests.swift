import LabanControl
import LabanCore
import XCTest

@testable import LabanApp

/// Covers review-gate finding 3: proves the "Always Allow" button is present
/// only when `request.canPersist`, across the principal families the design
/// calls out (signed non-generic, generic interpreters, package runners,
/// unsigned/ad-hoc binaries, and the bundled Laban helper).
///
/// `NSAlert` construction itself is not driven here; `ControlAttachApprovalPresenter.buttonTitles(for:)`
/// is a pure function factored out of `presentOnMain` specifically so the
/// button set is unit-testable without an interactive alert.
final class ControlAttachApprovalPresenterTests: XCTestCase {

  func testAlwaysAllowButtonPresentForSignedNonGenericPrincipal() {
    let request = makeRequest(canPersist: true)
    let titles = ControlAttachApprovalPresenter.buttonTitles(for: request)
    XCTAssertEqual(titles, ["Allow Once", "Always Allow", "Deny"])
  }

  func testAlwaysAllowButtonAbsentForZsh() {
    assertButtonAbsent(principalPath: "/bin/zsh", displayName: "zsh")
  }

  func testAlwaysAllowButtonAbsentForPython3() {
    assertButtonAbsent(principalPath: "/usr/bin/python3", displayName: "python3")
  }

  func testAlwaysAllowButtonAbsentForPackageRunner() {
    assertButtonAbsent(principalPath: "/usr/local/bin/npm", displayName: "npm")
  }

  func testAlwaysAllowButtonAbsentForUnsignedOrAdHocBinary() {
    let request = makeRequest(
      canPersist: false,
      principalDisplayName: "myagent",
      principalPath: "/usr/local/bin/myagent",
      principalIsVerified: false,
      persistenceDisabledReason: "This app is not a stable signed application.")
    let titles = ControlAttachApprovalPresenter.buttonTitles(for: request)
    XCTAssertEqual(titles, ["Allow Once", "Deny"])
  }

  func testAlwaysAllowButtonAbsentForBundledLabanHelper() {
    let request = makeRequest(
      canPersist: false,
      principalDisplayName: "laban",
      principalPath: "/Applications/Laban.app/Contents/MacOS/laban",
      principalIsVerified: false,
      persistenceDisabledReason: "This app is not a stable signed application.")
    let titles = ControlAttachApprovalPresenter.buttonTitles(for: request)
    XCTAssertEqual(titles, ["Allow Once", "Deny"])
    XCTAssertNotNil(request.persistenceDisabledReason)
  }

  // MARK: - Helpers

  private func assertButtonAbsent(principalPath: String, displayName: String) {
    let request = makeRequest(
      canPersist: false,
      principalDisplayName: displayName,
      principalPath: principalPath,
      principalIsVerified: false,
      persistenceDisabledReason: "This app is not a stable signed application.")
    let titles = ControlAttachApprovalPresenter.buttonTitles(for: request)
    XCTAssertEqual(titles, ["Allow Once", "Deny"])
  }

  private func makeRequest(
    canPersist: Bool,
    principalDisplayName: String = "Codex",
    principalPath: String = "/Applications/Codex.app/Contents/MacOS/Codex",
    principalIsVerified: Bool = true,
    persistenceDisabledReason: String? = nil
  ) -> ControlAttachApprovalRequest {
    ControlAttachApprovalRequest(
      id: "approval-1",
      principalDisplayName: principalDisplayName,
      principalIsVerified: principalIsVerified,
      helperChainSummary: "zsh -> \(principalDisplayName)",
      principalPath: principalPath,
      sessionDisplay: "1234",
      operationSummary: "Read app state.",
      dataSensitivity: "nonSensitiveState",
      capabilities: ["observe"],
      canPersist: canPersist,
      persistenceDisabledReason: persistenceDisabledReason)
  }
}
