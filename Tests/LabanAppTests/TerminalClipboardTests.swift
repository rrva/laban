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

  func testMixedTextAndImageClipboardKeepsTextReadable() throws {
    // Regression for H-7: paste(_:) used to short-circuit to an image-read
    // Ctrl+V on any Claude tab whenever the clipboard contained an image,
    // silently dropping co-present text. paste(_:) now reads the string
    // first; this pins the inputs that route a mixed clipboard to the
    // text-paste branch instead of .empty image-forward.
    let pasteboard = NSPasteboard.withUniqueName()
    let png = try XCTUnwrap(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
      ))
    pasteboard.declareTypes([.png, .string], owner: nil)
    XCTAssertTrue(pasteboard.setData(png, forType: .png))
    XCTAssertTrue(pasteboard.setString("hello from a mixed clipboard", forType: .string))

    let claudeTab = Tab(
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

    // Both the image and the Claude heuristic fire — the old short-circuit's
    // exact precondition — yet the text must still be readable, so the
    // string-first paste path delivers it instead of dropping it.
    XCTAssertTrue(TerminalClipboard.containsImage(pasteboard))
    XCTAssertTrue(TerminalClipboard.shouldForwardImagePasteToTerminal(for: claudeTab))
    XCTAssertEqual(
      TerminalClipboard.readString(pasteboard),
      .value("hello from a mixed clipboard", bytes: "hello from a mixed clipboard".utf8.count))
  }

  func testImageOnlyClipboardReadsAsEmpty() throws {
    // Negative control for H-7: an image-only clipboard still reads as
    // .empty so paste(_:) routes to the image-forward branch.
    let pasteboard = NSPasteboard.withUniqueName()
    let png = try XCTUnwrap(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
      ))
    pasteboard.declareTypes([.png], owner: nil)
    XCTAssertTrue(pasteboard.setData(png, forType: .png))

    XCTAssertTrue(TerminalClipboard.containsImage(pasteboard))
    XCTAssertEqual(TerminalClipboard.readString(pasteboard), .empty)
  }
}
