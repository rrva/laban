import AppKit
import LabanCore
import XCTest

@testable import LabanApp

final class TerminalClipboardTests: XCTestCase {
  func testPasteboardReadPreflightsDataSizeBeforeStringDecode() {
    let pasteboard = NSPasteboard.withUniqueName()
    pasteboard.declareTypes([.string], owner: nil)
    let oversized = Data(
      repeating: UInt8(ascii: "a"), count: TerminalClipboard.hardLimitBytes + 1)
    XCTAssertTrue(pasteboard.setData(oversized, forType: .string))

    XCTAssertEqual(
      TerminalClipboard.readString(pasteboard),
      .tooLarge(TerminalClipboard.hardLimitBytes + 1)
    )
  }

  func testPasteboardContainsImageDetectsPngData() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    XCTAssertFalse(TerminalClipboard.containsImage(pasteboard))

    let data = try XCTUnwrap(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
      ))
    pasteboard.declareTypes([.png], owner: nil)
    XCTAssertTrue(pasteboard.setData(data, forType: .png))

    XCTAssertTrue(TerminalClipboard.containsImage(pasteboard))
  }

  func testClaudeCodeImagePasteForwardingRecognizesClaudeTitleAndCommand() {
    let titled = Tab(
      id: "tab-1",
      position: 1,
      title: "Tab 1",
      isActive: true,
      sessionId: "session-1",
      titleMetadata: TabTitleMetadata(
        terminalTitle: "* Claude Code",
        displayTitle: "* Claude Code",
        titleSource: .terminal
      )
    )
    XCTAssertTrue(TerminalClipboard.shouldForwardImagePasteToTerminal(for: titled))

    let command = Tab(
      id: "tab-2",
      position: 1,
      title: "Tab 1",
      isActive: true,
      sessionId: "session-2",
      titleMetadata: TabTitleMetadata(
        displayTitle: "claude",
        titleSource: .process,
        process: TabProcessMetadata(foregroundCommand: "/opt/homebrew/bin/claude --resume")
      )
    )
    XCTAssertTrue(TerminalClipboard.shouldForwardImagePasteToTerminal(for: command))
  }

  func testClaudeCodeImagePasteForwardingRejectsNonClaudeTab() {
    let tab = Tab(
      id: "tab-1",
      position: 1,
      title: "Tab 1",
      isActive: true,
      sessionId: "session-1",
      titleMetadata: TabTitleMetadata(
        displayTitle: "zsh",
        titleSource: .process,
        process: TabProcessMetadata(
          foregroundProcess: "zsh",
          foregroundCommand: "/bin/zsh"
        )
      )
    )
    XCTAssertFalse(TerminalClipboard.shouldForwardImagePasteToTerminal(for: tab))
  }
}
