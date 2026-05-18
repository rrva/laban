import Foundation
import LabanTerminalCore
import XCTest

@testable import LabanCore

/// End-to-end: bytes pushed through a real Session into the C
/// capture callback must reach both the TranscriptWriter (.bin file)
/// AND the RecentByteRing, with the ring producing a valid asciinema
/// v2 cast on demand.
final class RecentByteRingIntegrationTests: XCTestCase {

  func testPtyOutputFlowsToBothWriterAndRing() throws {
    let baseDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-cast-e2e-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: baseDir) }

    let host = TranscriptHost(
      store: PersistenceStore(baseURL: baseDir),
      isEnabled: { true })

    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let session = try Session.fixture(size: size)
    let tabId = "tab-cast-e2e"
    host.attachTranscriptWriter(to: session, tabId: tabId)

    XCTAssertEqual(session.feedOutput(Array("hello ".utf8)), 0)
    // Small sleep so the second chunk has a measurably later
    // timestamp than the first — asciinema casts care about deltas.
    Thread.sleep(forTimeInterval: 0.02)
    XCTAssertEqual(session.feedOutput(Array("world\r\n".utf8)), 0)

    let ring = try XCTUnwrap(host.recentByteRing(forTabId: tabId))
    let snapshot = ring.snapshot(window: 5)
    XCTAssertEqual(snapshot.count, 2, "two writes should produce two ring entries")
    XCTAssertEqual(snapshot[0].bytes, Array("hello ".utf8))
    XCTAssertEqual(snapshot[1].bytes, Array("world\r\n".utf8))

    let cast = try AsciinemaCast.encode(
      entries: snapshot,
      cols: 80,
      rows: 24,
      title: "e2e",
      startedAtUnixSeconds: 1_716_000_000)
    let lines = String(data: cast, encoding: .utf8)?
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map(String.init) ?? []
    XCTAssertEqual(lines.count, 3, "header + 2 events")

    // Parse the second event and verify its delta reflects the sleep.
    let secondEvent = try JSONSerialization.jsonObject(
      with: Data(lines[2].utf8)) as? [Any]
    let secondDelta = (secondEvent?[0] as? NSNumber)?.doubleValue ?? 0
    XCTAssertGreaterThan(
      secondDelta, 0.01,
      "second event time delta must reflect the 20 ms sleep")
  }

  /// Build a real cast from PTY-driven entries, write it to disk,
  /// and ask the asciinema binary to parse it. Skipped automatically
  /// when asciinema is not installed on the build host.
  func testEmittedCastIsAcceptedByAsciinemaCat() throws {
    let asciinemaPath = ProcessInfo.processInfo.environment["ASCIINEMA_BIN"]
      ?? "/opt/homebrew/bin/asciinema"
    guard FileManager.default.isExecutableFile(atPath: asciinemaPath) else {
      throw XCTSkip("asciinema binary not found at \(asciinemaPath)")
    }

    let baseDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-cast-validate-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: baseDir) }

    let host = TranscriptHost(
      store: PersistenceStore(baseURL: baseDir),
      isEnabled: { true })
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let session = try Session.fixture(size: size)
    let tabId = "tab-validate"
    host.attachTranscriptWriter(to: session, tabId: tabId)

    let prompt = "\u{1B}[1;32mlaban\u{1B}[0m % "
    XCTAssertEqual(session.feedOutput(Array(prompt.utf8)), 0)
    Thread.sleep(forTimeInterval: 0.02)
    XCTAssertEqual(
      session.feedOutput(Array("echo \"é & 🎉\"\r\n".utf8)), 0)
    Thread.sleep(forTimeInterval: 0.02)
    XCTAssertEqual(
      session.feedOutput(Array("é & 🎉\r\n".utf8)), 0)

    let ring = try XCTUnwrap(host.recentByteRing(forTabId: tabId))
    let entries = ring.snapshot(window: 5)
    XCTAssertEqual(entries.count, 3)

    let castData = try AsciinemaCast.encode(
      entries: entries, cols: 80, rows: 24, title: "validate",
      startedAtUnixSeconds: 1_716_000_000)
    let castURL = baseDir.appendingPathComponent("smoke.cast")
    try castData.write(to: castURL)

    // `asciinema cat` re-emits the recorded output verbatim and
    // returns non-zero on a malformed cast file — exactly the
    // validation we want without requiring a TTY.
    let task = Process()
    task.executableURL = URL(fileURLWithPath: asciinemaPath)
    task.arguments = ["cat", castURL.path]
    let stdout = Pipe()
    let stderr = Pipe()
    task.standardOutput = stdout
    task.standardError = stderr
    try task.run()
    task.waitUntilExit()

    let stdoutText = String(
      data: stdout.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8) ?? ""
    let stderrText = String(
      data: stderr.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8) ?? ""
    XCTAssertEqual(
      task.terminationStatus, 0,
      "asciinema cat rejected the cast: stderr=\(stderrText)")
    XCTAssertTrue(
      stdoutText.contains("é & 🎉"),
      "asciinema cat output should contain the recorded multi-byte glyphs; got=\(stdoutText.debugDescription)")
  }

  func testRingSurvivesWriterDetach() throws {
    // Production flow: a tab's writer can be detached and replaced
    // (e.g., when the restore path swaps writers). The recent-byte
    // ring should be re-used across that swap so the user does
    // not lose their export history.
    let baseDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-cast-e2e-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: baseDir) }

    let host = TranscriptHost(
      store: PersistenceStore(baseURL: baseDir),
      isEnabled: { true })

    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let session1 = try Session.fixture(size: size)
    let tabId = "tab-cast-swap"
    host.attachTranscriptWriter(to: session1, tabId: tabId)
    XCTAssertEqual(session1.feedOutput(Array("first ".utf8)), 0)

    let ringBefore = try XCTUnwrap(host.recentByteRing(forTabId: tabId))

    // Re-attach a fresh writer for the same tab id without
    // detaching first (the restore path does this).
    let session2 = try Session.fixture(size: size)
    host.attachTranscriptWriter(to: session2, tabId: tabId)
    XCTAssertEqual(session2.feedOutput(Array("second".utf8)), 0)

    let ringAfter = try XCTUnwrap(host.recentByteRing(forTabId: tabId))
    XCTAssertTrue(
      ringBefore === ringAfter,
      "the ring instance must persist across writer re-attach")

    let snapshot = ringAfter.snapshot(window: 5)
    XCTAssertEqual(snapshot.count, 2)
    XCTAssertEqual(snapshot[0].bytes, Array("first ".utf8))
    XCTAssertEqual(snapshot[1].bytes, Array("second".utf8))
  }
}
