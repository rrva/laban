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

  // MARK: - detailRows (Milestone 2: dialog-first family wording)

  /// A family grant (`grantsSessionReadFamily: true`) must describe the whole
  /// own-session read family: content-inclusive Data row, the propose grant
  /// named per review NOTE 2, and a "Not included" row (execplans/active/
  /// dialog-first-session-observe.md, Milestone 2).
  func testFamilyRequestDetailRowsDescribeWholeFamily() {
    let request = makeRequest(canPersist: true, grantsSessionReadFamily: true)
    let rows = ControlAttachApprovalPresenter.detailRows(for: request)

    guard let dataRow = rows.first(where: { $0.0 == "Data" }) else {
      return XCTFail("expected a Data row")
    }
    XCTAssertTrue(
      dataRow.1.contains("screen text, scrollback, and selection"),
      "Data row must name terminal content, got: \(dataRow.1)")

    XCTAssertTrue(
      rows.contains { $0.1.contains("suggest commands") },
      "a row must name the propose grant (review NOTE 2)")

    guard let notIncludedRow = rows.first(where: { $0.0 == "Not included" }) else {
      return XCTFail("expected a Not included row for a family grant")
    }
    XCTAssertTrue(
      notIncludedRow.1.contains("No keyboard input"),
      "Not included row must name excluded input, got: \(notIncludedRow.1)")
  }

  /// A non-family (legacy, request-exact) grant keeps the existing
  /// single-sensitivity Data row and has no "Not included" row: unchanged
  /// behavior for callers that never set `grantsSessionReadFamily`.
  func testNonFamilyRequestDetailRowsUnchanged() {
    let request = makeRequest(canPersist: true, grantsSessionReadFamily: false)
    let rows = ControlAttachApprovalPresenter.detailRows(for: request)

    guard let dataRow = rows.first(where: { $0.0 == "Data" }) else {
      return XCTFail("expected a Data row")
    }
    XCTAssertEqual(dataRow.1, "Basic app state")

    XCTAssertFalse(
      rows.contains { $0.0 == "Not included" },
      "a non-family grant must not add a Not included row")
  }

  func testDetailRowsKeepCoreRowsForBothBranches() {
    for grantsFamily in [true, false] {
      let request = makeRequest(canPersist: true, grantsSessionReadFamily: grantsFamily)
      let titles = ControlAttachApprovalPresenter.detailRows(for: request).map(\.0)
      XCTAssertTrue(titles.contains("Operation"))
      XCTAssertTrue(titles.contains("Session"))
      XCTAssertTrue(titles.contains("Requester"))
      XCTAssertTrue(titles.contains("Path"))
      XCTAssertTrue(titles.contains("Chain"))
      XCTAssertTrue(titles.contains("Permission"))
      XCTAssertTrue(titles.contains("Scope"))
    }
  }

  // MARK: - dialogContent (dialog-redesign-brief, 2026-07-11: Adaptive Can/Cannot)

  /// A verified family request hides the forensic rows (Path, Chain,
  /// Operation) behind the disclosure, because the code signature is already
  /// the trust anchor; the Can/Cannot lines carry the decision. The redundant
  /// Requester row is dropped (it duplicated the title).
  func testDialogContentVerifiedFamilyShowsDisclosureAndCanCannot() {
    let request = makeRequest(canPersist: true, grantsSessionReadFamily: true)
    let content = ControlAttachApprovalPresenter.dialogContent(for: request)

    XCTAssertFalse(content.subheadIsWarning)

    XCTAssertEqual(content.canLeadIn, "Can")
    XCTAssertEqual(content.cannotLeadIn, "Cannot")

    XCTAssertTrue(content.can.contains("screen"), "can: \(content.can)")
    XCTAssertTrue(content.can.contains("scrollback"), "can: \(content.can)")
    XCTAssertTrue(content.can.contains("selection"), "can: \(content.can)")
    XCTAssertTrue(content.can.contains("suggest commands"), "can: \(content.can)")
    XCTAssertFalse(content.can.contains("tab"), "can must not mention tabs: \(content.can)")

    XCTAssertTrue(content.cannot.contains("switch tabs"), "cannot: \(content.cannot)")
    XCTAssertTrue(content.cannot.contains("other sessions"), "cannot: \(content.cannot)")

    XCTAssertTrue(content.showsDisclosure)
    XCTAssertTrue(content.detailRows.contains { $0.0 == "Path" })
    XCTAssertTrue(content.detailRows.contains { $0.0 == "Chain" })
    XCTAssertFalse(
      content.detailRows.contains { $0.0 == "Requester" },
      "Requester row duplicates the title and must be dropped")
    XCTAssertFalse(
      content.inlineRows.contains { $0.0 == "Path" },
      "verified principal must hide Path behind disclosure, not show it inline")
  }

  /// An unverified family request shows Path/Chain/Operation inline and
  /// prominent, because there is no signature to anchor trust, so these rows
  /// ARE the decision. The subhead becomes a warning and there is no
  /// disclosure to collapse anything behind.
  func testDialogContentUnverifiedFamilyShowsInlineRowsAndWarning() {
    let request = makeRequest(
      canPersist: false,
      principalIsVerified: false,
      persistenceDisabledReason: "This app is not a stable signed application.",
      grantsSessionReadFamily: true)
    let content = ControlAttachApprovalPresenter.dialogContent(for: request)

    XCTAssertTrue(content.subheadIsWarning)

    XCTAssertTrue(content.inlineRows.contains { $0.0 == "Path" })
    XCTAssertTrue(content.inlineRows.contains { $0.0 == "Chain" })

    XCTAssertFalse(content.showsDisclosure, "unverified has nothing hidden behind a disclosure")
    XCTAssertTrue(content.detailRows.isEmpty)
  }

  /// The tabs contradiction (old Permission row said "Navigate tabs and
  /// viewport" while the old Not-included row said "No tab switching") is
  /// gone for both verified and unverified family requests: `can` never
  /// mentions tabs and `cannot` always says tabs are excluded.
  func testDialogContentTabsContradictionFixedForBothVerifiedStates() {
    for isVerified in [true, false] {
      let reason: String? = isVerified ? nil : "This app is not a stable signed application."
      let request = makeRequest(
        canPersist: isVerified,
        principalIsVerified: isVerified,
        persistenceDisabledReason: reason,
        grantsSessionReadFamily: true)
      let content = ControlAttachApprovalPresenter.dialogContent(for: request)
      XCTAssertFalse(
        content.can.contains("tab"), "verified=\(isVerified) can: \(content.can)")
      XCTAssertTrue(
        content.cannot.contains("tabs"), "verified=\(isVerified) cannot: \(content.cannot)")
    }
  }

  // MARK: - readableCapability (the "navigate" fix)

  /// The family's `.navigate` capability is own-session
  /// `terminal.scrollViewport` only, never tab navigation (invariant I7). The
  /// old wording ("Navigate tabs and viewport") contradicted the family
  /// dialog's own "No tab switching" line; this pins the fix so it cannot
  /// regress.
  func testReadableCapabilityNavigateDoesNotMentionTabs() {
    XCTAssertEqual(
      ControlAttachApprovalPresenter.readableCapability("navigate"),
      "Scroll this session's viewport")
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
    persistenceDisabledReason: String? = nil,
    grantsSessionReadFamily: Bool = false
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
      persistenceDisabledReason: persistenceDisabledReason,
      grantsSessionReadFamily: grantsSessionReadFamily)
  }
}
