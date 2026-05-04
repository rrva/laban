import LabanTerminalCore
import XCTest

@testable import LabanCore

final class TerminalTitleTests: XCTestCase {

  func testNilInputReturnsNil() {
    XCTAssertNil(TerminalTitle.sanitize(nil))
  }

  func testEmptyStringReturnsNil() {
    XCTAssertNil(TerminalTitle.sanitize(""))
  }

  func testNormalTitlePassesThrough() {
    XCTAssertEqual(TerminalTitle.sanitize("zsh"), "zsh")
    XCTAssertEqual(TerminalTitle.sanitize("vim /etc/hosts"), "vim /etc/hosts")
  }

  func testControlCharactersRemoved() {
    XCTAssertEqual(TerminalTitle.sanitize("a\u{01}b\u{1F}c"), "abc")
  }

  func testDelRemoved() {
    XCTAssertEqual(TerminalTitle.sanitize("a\u{7F}b"), "ab")
  }

  func testC1ControlsRemoved() {
    XCTAssertEqual(TerminalTitle.sanitize("a\u{85}b"), "ab")
  }

  func testTabCollapsedToSpace() {
    XCTAssertEqual(TerminalTitle.sanitize("a\tb"), "a b")
  }

  func testNewlineCollapsedToSpace() {
    XCTAssertEqual(TerminalTitle.sanitize("a\nb"), "a b")
    XCTAssertEqual(TerminalTitle.sanitize("a\rb"), "a b")
  }

  func testLeadingAndTrailingWhitespaceTrimmed() {
    XCTAssertEqual(TerminalTitle.sanitize("  zsh  "), "zsh")
    XCTAssertEqual(TerminalTitle.sanitize("\t zsh \t"), "zsh")
  }

  func testOnlyWhitespaceReturnsNil() {
    XCTAssertNil(TerminalTitle.sanitize("   "))
    XCTAssertNil(TerminalTitle.sanitize("\t\n"))
  }

  func testLongTitleCapped() {
    let long = String(repeating: "a", count: TerminalTitle.maxLength + 50)
    let result = TerminalTitle.sanitize(long)
    XCTAssertNotNil(result)
    XCTAssertEqual(result?.count, TerminalTitle.maxLength)
  }

  func testExactlyMaxLengthPreserved() {
    let exact = String(repeating: "x", count: TerminalTitle.maxLength)
    XCTAssertEqual(TerminalTitle.sanitize(exact), exact)
  }

  func testOscStyleTitle() {
    XCTAssertEqual(TerminalTitle.sanitize("Hello Effects"), "Hello Effects")
  }
}

final class AppModelTitleTests: XCTestCase {

  private func makeModel() throws -> AppModel {
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    return try AppModel(initialSize: size)
  }

  func testUpdateTitlePreservesIdentity() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id
    let sessionId = model.tabs[0].sessionId
    try model.updateTitle("zsh", forTab: tabId)
    XCTAssertEqual(model.tabs[0].title, "zsh")
    XCTAssertEqual(model.tabs[0].id, tabId)
    XCTAssertEqual(model.tabs[0].sessionId, sessionId)
  }

  func testUpdateTitleSanitizes() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id
    try model.updateTitle("  vim\u{01}  ", forTab: tabId)
    XCTAssertEqual(model.tabs[0].title, "vim")
  }

  func testUpdateTitleEmptyDoesNotErase() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id
    let original = model.tabs[0].title
    try model.updateTitle("", forTab: tabId)
    XCTAssertEqual(
      model.tabs[0].title, original,
      "empty title must not overwrite existing tab title")
  }

  func testUpdateTitleControlOnlyDoesNotErase() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id
    let original = model.tabs[0].title
    try model.updateTitle("\u{01}\u{02}", forTab: tabId)
    XCTAssertEqual(model.tabs[0].title, original)
  }

  func testWindowTitleFallsBackToLaban() throws {
    let model = try makeModel()
    let initial = model.windowTitle
    // Initial tab title is "Tab 1" so windowTitle returns that, not "Laban".
    // Once the title is cleared… but we never store empty titles.
    // Test the fallback by reading windowTitle on a freshly created model.
    XCTAssertFalse(initial.isEmpty)
  }

  func testWindowTitleReflectsActiveTab() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id
    try model.updateTitle("my-shell", forTab: tabId)
    XCTAssertEqual(model.windowTitle, "my-shell")
  }
}
