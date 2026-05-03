import XCTest
import CoreGraphics
import LabanTerminalCore
@testable import LabanCore
import LabanRenderer

// Escape-sequence bytes for the colored-boxes fixture lines:
//   ESC[38;2;255;204;0m┌────────────┐ESC[0m\r\n
//   ESC[38;2;116;199;236m│ hello mvp  │ESC[0m\r\n
//   ESC[38;2;255;204;0m└────────────┘ESC[0m\r\n
private let coloredBoxesString =
    "\u{1B}[38;2;255;204;0m┌────────────┐\u{1B}[0m\r\n" +
    "\u{1B}[38;2;116;199;236m│ hello mvp  │\u{1B}[0m\r\n" +
    "\u{1B}[38;2;255;204;0m└────────────┘\u{1B}[0m\r\n"
private let coloredBoxesBytes: [UInt8] = Array(coloredBoxesString.utf8)

final class FrameProducerTests: XCTestCase {

    // MARK: - hello mvp fixture

    func testFixtureSessionWithHelloMvpProducesGlyphCommands() throws {
        var size = LabanTerminalSize(); size.rows = 24; size.cols = 80
        let session = try Session.fixture(size: size)
        defer { session.close() }

        session.write(coloredBoxesBytes)
        session.poll()

        let snap = session.snapshot()
        defer { laban_snapshot_destroy(snap) }
        guard let snap else { XCTFail("snapshot must be non-nil"); return }

        let producer = FrameProducer(cellWidth: 8, cellHeight: 16)
        let cmds = producer.commands(from: UnsafePointer(snap))

        let glyphCmds = cmds.compactMap { cmd -> String? in
            if case let .glyphRun(_, text, _, _, src) = cmd, src == .terminal {
                return text
            }
            return nil
        }

        XCTAssertFalse(glyphCmds.isEmpty, "fixture session must produce at least one terminal glyph command")

        let allText = glyphCmds.joined()
        XCTAssertTrue(allText.contains("h") && allText.contains("e"),
            "glyph commands must contain characters from 'hello mvp'; got: \(allText.prefix(80))")
    }

    func testFixtureSessionProducesTerminalSourceCommands() throws {
        var size = LabanTerminalSize(); size.rows = 24; size.cols = 80
        let session = try Session.fixture(size: size)
        defer { session.close() }

        session.write(coloredBoxesBytes)

        guard let snap = session.snapshot() else { XCTFail("snapshot must be non-nil"); return }
        defer { laban_snapshot_destroy(snap) }

        let cmds = FrameProducer().commands(from: UnsafePointer(snap))
        let terminalCmds = cmds.filter {
            if case .rect(_, _, let src) = $0 { return src == .terminal }
            if case .glyphRun(_, _, _, _, let src) = $0 { return src == .terminal }
            return false
        }
        XCTAssertFalse(terminalCmds.isEmpty, "commands must include terminal-sourced commands")
    }

    // MARK: - Box-drawing

    func testBoxDrawingFixtureProducesNonEmptyGlyphCommandsWithoutTextReplacement() throws {
        var size = LabanTerminalSize(); size.rows = 24; size.cols = 80
        let session = try Session.fixture(size: size)
        defer { session.close() }

        session.write(coloredBoxesBytes)

        guard let snap = session.snapshot() else { XCTFail("snapshot must be non-nil"); return }
        defer { laban_snapshot_destroy(snap) }

        let cmds = FrameProducer().commands(from: UnsafePointer(snap))

        let glyphTexts = cmds.compactMap { cmd -> String? in
            if case let .glyphRun(_, text, _, _, src) = cmd, src == .terminal {
                return text
            }
            return nil
        }

        XCTAssertFalse(glyphTexts.isEmpty, "box-drawing fixture must produce glyph commands")

        // Producer must not replace the box-drawing characters with substitute text
        let boxChars: [Character] = ["┌", "─", "┐", "│", "└", "┘"]
        for ch in boxChars {
            let found = glyphTexts.contains { $0.unicodeScalars.contains { Unicode.Scalar($0.value) == ch.unicodeScalars.first } }
            XCTAssertTrue(found, "box-drawing character '\(ch)' must appear verbatim in glyph commands")
        }
    }

    // MARK: - Command structure

    func testFrameProducerIncludesBackgroundRectAndCursor() throws {
        var size = LabanTerminalSize(); size.rows = 5; size.cols = 10
        let session = try Session.fixture(size: size)
        defer { session.close() }

        guard let snap = session.snapshot() else { XCTFail("snapshot nil"); return }
        defer { laban_snapshot_destroy(snap) }

        let producer = FrameProducer(cellWidth: 8, cellHeight: 16)
        let cmds = producer.commands(from: UnsafePointer(snap))

        let hasTerminalRect = cmds.contains {
            if case .rect(_, _, let src) = $0 { return src == .terminal }
            return false
        }
        XCTAssertTrue(hasTerminalRect, "must contain at least one terminal rect command")

        // Cursor is emitted when cursor_visible is set (libghostty defaults to visible)
        let hasCursor = cmds.contains { if case .cursor = $0 { return true }; return false }
        XCTAssertTrue(hasCursor, "must include cursor command for fresh session")
    }

    func testFrameProducerTexturedQuadTypeIsSupported() {
        // Verify the texturedQuad case compiles and can be pattern-matched.
        let cmd: FrameCommand = .texturedQuad(
            rect: CGRect(x: 0, y: 0, width: 16, height: 16),
            resourceId: 7,
            source: .image
        )
        if case let .texturedQuad(_, rid, src) = cmd {
            XCTAssertEqual(rid, 7)
            XCTAssertEqual(src, .image)
        } else {
            XCTFail("texturedQuad must match")
        }
    }

    // MARK: - Large snapshot smoke (diagnostic)

    func testLargeSnapshotFrameCommandCount() throws {
        var size = LabanTerminalSize(); size.rows = 50; size.cols = 220
        let session = try Session.fixture(size: size)
        defer { session.close() }

        // Write enough text to fill some rows
        let line = String(repeating: "X", count: 220) + "\r\n"
        let lineBytes = Array(line.utf8)
        for _ in 0..<10 { session.write(lineBytes) }

        guard let snap = session.snapshot() else { XCTFail("snapshot nil"); return }
        defer { laban_snapshot_destroy(snap) }

        let producer = FrameProducer(cellWidth: 8, cellHeight: 16)
        let start = Date()
        let cmds = producer.commands(from: UnsafePointer(snap))
        let elapsed = Date().timeIntervalSince(start)

        let glyphCount = cmds.filter { if case .glyphRun = $0 { return true }; return false }.count
        print("[smoke] large-snapshot: \(cmds.count) total commands, \(glyphCount) glyph commands, " +
              "\(String(format: "%.2f", elapsed * 1000))ms, 220x50 grid")

        // Not a benchmark gate; just verify it completes and produces a plausible count
        XCTAssertGreaterThan(cmds.count, 0)
    }
}
