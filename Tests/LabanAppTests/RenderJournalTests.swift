import Foundation
import CoreGraphics
import LabanRenderer
import XCTest

@testable import LabanApp

final class RenderJournalTests: XCTestCase {
  func testRenderJournalIsDisabledByDefault() {
    let suiteName = "RenderJournalTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    XCTAssertFalse(RenderJournal.isEnabled(defaults: defaults, environment: [:]))
  }

  func testRenderJournalCanBeEnabledByDefaultsOrEnvironment() {
    let suiteName = "RenderJournalTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set(true, forKey: RenderJournal.enabledDefaultKey)
    XCTAssertTrue(RenderJournal.isEnabled(defaults: defaults, environment: [:]))
    XCTAssertTrue(
      RenderJournal.isEnabled(
        defaults: defaults,
        environment: [RenderJournal.enabledEnvironmentKey: "1"]))
    XCTAssertFalse(
      RenderJournal.isEnabled(
        defaults: defaults,
        environment: [RenderJournal.enabledEnvironmentKey: "0"]))
  }

  func testRingKeepsNewestEntriesAndDumpsArtifacts() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-render-journal-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
    let journal = RenderJournal(capacity: 2, dumpRoot: root, clock: { fixedDate })
    journal.record(journal.makeEntry(event: .rendered, frame: 1, tabId: "tab", sessionId: "s"))
    journal.record(journal.makeEntry(event: .rendered, frame: 2, tabId: "tab", sessionId: "s"))
    journal.record(journal.makeEntry(event: .renderFailed, frame: 3, tabId: "tab", sessionId: "s"))

    let entries = journal.snapshot()
    XCTAssertEqual(entries.map(\.frame), [2, 3])
    XCTAssertEqual(entries.last?.event, .renderFailed)

    let url = try journal.dump(currentPNG: Data([0x89, 0x50, 0x4E, 0x47]))
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("summary.json").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("entries.jsonl").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("current-frame.png").path))

    let summaryData = try Data(contentsOf: url.appendingPathComponent("summary.json"))
    let summary = try JSONDecoder.iso8601.decode(RenderJournal.DumpSummary.self, from: summaryData)
    XCTAssertEqual(summary.entryCount, 2)
    XCTAssertEqual(summary.firstFrame, 2)
    XCTAssertEqual(summary.lastFrame, 3)
    XCTAssertEqual(summary.pngFilename, "current-frame.png")

    let jsonl = try String(contentsOf: url.appendingPathComponent("entries.jsonl"), encoding: .utf8)
    XCTAssertEqual(jsonl.split(separator: "\n").count, 2)
  }

  func testCommandCountsClassifyFrameCommands() {
    let counts = RenderJournal.commandCounts(
      commands: [
        .rect(.zero, color: 0, source: .terminal),
        .glyphRun(
          origin: .zero,
          text: "A",
          foreground: 0,
          background: 0,
          attributes: [],
          source: .terminal),
        .cursor(.zero, color: 0),
      ],
      overlayCommands: [
        .selection(.zero, color: 0),
        .findSelected(.zero, color: 0),
      ])

    XCTAssertEqual(counts.total, 5)
    XCTAssertEqual(counts.overlay, 2)
    XCTAssertEqual(counts.rects, 1)
    XCTAssertEqual(counts.glyphRuns, 1)
    XCTAssertEqual(counts.cursors, 1)
    XCTAssertEqual(counts.selections, 1)
    XCTAssertEqual(counts.findMatches, 1)
  }
}

private extension JSONDecoder {
  static var iso8601: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
