import CoreGraphics
import Foundation
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

  func testGPUFreezeAutoDumpCanBeEnabledByDefaultsOrEnvironment() {
    let suiteName = "RenderJournalTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    XCTAssertFalse(RenderJournal.gpuFreezeAutoDumpEnabled(defaults: defaults, environment: [:]))

    defaults.set(true, forKey: RenderJournal.gpuFreezeAutoDumpDefaultKey)
    XCTAssertTrue(RenderJournal.gpuFreezeAutoDumpEnabled(defaults: defaults, environment: [:]))
    XCTAssertTrue(
      RenderJournal.gpuFreezeAutoDumpEnabled(
        defaults: defaults,
        environment: [RenderJournal.gpuFreezeAutoDumpEnvironmentKey: "1"]))
    XCTAssertFalse(
      RenderJournal.gpuFreezeAutoDumpEnabled(
        defaults: defaults,
        environment: [RenderJournal.gpuFreezeAutoDumpEnvironmentKey: "0"]))
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
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: url.appendingPathComponent("summary.json").path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: url.appendingPathComponent("entries.jsonl").path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: url.appendingPathComponent("current-frame.png").path))

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

  func testRenderFailedEntryCarriesRenderFailureReasonThroughSerialization() throws {
    let journal = RenderJournal()
    let entry = journal.makeEntry(
      event: .renderFailed,
      frame: 7,
      tabId: "tab",
      sessionId: "s",
      renderFailureReason: .fullRedrawProducedNoContent)
    XCTAssertEqual(entry.renderFailureReason, .fullRedrawProducedNoContent)

    // The dump path serializes entries as JSONL, so the reason must round-trip.
    let encoded = try JSONEncoder().encode(entry)
    let decoded = try JSONDecoder().decode(RenderJournal.Entry.self, from: encoded)
    XCTAssertEqual(decoded.renderFailureReason, .fullRedrawProducedNoContent)
  }

  func testFreezeDetectedEntryCarriesDetectorSnapshotThroughSerialization() throws {
    let journal = RenderJournal()
    let freeze = RenderJournal.FreezeSnapshot(
      reason: GPURenderFreezeDetector.Reason.gpuFrameCompletionStalled.rawValue,
      noProgressStreak: 12,
      terminalDirty: true,
      activeTerminalDirty: true,
      renderInvalidated: false,
      tabChanged: false,
      scrollAnimating: false,
      rendered: false,
      renderFailureReason: .previousFrameInFlight,
      metalFrameCompletions: 3,
      lastAcceptedFrame: 41,
      completionCountAtLastAcceptedFrame: 3)
    let entry = journal.makeEntry(
      event: .freezeDetected,
      frame: 53,
      tabId: "tab",
      sessionId: "s",
      reason: freeze.reason,
      renderFailureReason: .previousFrameInFlight,
      freeze: freeze,
      rendered: false)
    XCTAssertEqual(entry.freeze, freeze)

    let encoded = try JSONEncoder().encode(entry)
    let decoded = try JSONDecoder().decode(RenderJournal.Entry.self, from: encoded)
    XCTAssertEqual(decoded.event, .freezeDetected)
    XCTAssertEqual(
      decoded.reason,
      GPURenderFreezeDetector.Reason.gpuFrameCompletionStalled.rawValue)
    XCTAssertEqual(decoded.freeze, freeze)
  }

  func testGPUFreezeDetectorIgnoresClassicAndCursorOnlyFailures() {
    let detector = GPURenderFreezeDetector(noProgressThreshold: 1)

    XCTAssertNil(
      detector.sample(
        freezeSample(
          gpuDriven: false,
          terminalDirty: true,
          rendered: false,
          renderFailureReason: .previousFrameInFlight)))
    XCTAssertNil(
      detector.sample(
        freezeSample(
          gpuDriven: true,
          terminalDirty: false,
          activeTerminalDirty: false,
          renderInvalidated: false,
          tabChanged: false,
          scrollAnimating: false,
          rendered: false,
          renderFailureReason: .previousFrameInFlight)))
  }

  func testGPUFreezeDetectorFiresAfterCompletionStalledThresholdAndThrottles() {
    let detector = GPURenderFreezeDetector(noProgressThreshold: 3, duplicateThrottleSeconds: 60)
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    XCTAssertNil(
      detector.sample(
        freezeSample(frame: 10, rendered: true, renderFailureReason: nil, now: start)))
    XCTAssertNil(
      detector.sample(
        freezeSample(
          frame: 11, rendered: false, renderFailureReason: .previousFrameInFlight,
          now: start.addingTimeInterval(1))))
    XCTAssertNil(
      detector.sample(
        freezeSample(
          frame: 12, rendered: false, renderFailureReason: .previousFrameInFlight,
          now: start.addingTimeInterval(2))))

    let detection = detector.sample(
      freezeSample(
        frame: 13, rendered: false, renderFailureReason: .previousFrameInFlight,
        now: start.addingTimeInterval(3)))
    XCTAssertEqual(
      detection?.freeze.reason,
      GPURenderFreezeDetector.Reason.gpuFrameCompletionStalled.rawValue)
    XCTAssertEqual(detection?.freeze.noProgressStreak, 3)
    XCTAssertEqual(detection?.freeze.lastAcceptedFrame, 10)

    XCTAssertNil(
      detector.sample(
        freezeSample(
          frame: 14, rendered: false, renderFailureReason: .previousFrameInFlight,
          now: start.addingTimeInterval(4))),
      "duplicate dumps for the same tab/session/reason are throttled")
  }

  func testGPUFreezeDetectorResetsStalledFrameAfterCompletion() {
    let detector = GPURenderFreezeDetector(noProgressThreshold: 2, duplicateThrottleSeconds: 60)
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    XCTAssertNil(
      detector.sample(
        freezeSample(frame: 20, rendered: true, renderFailureReason: nil, now: start)))
    detector.noteMetalFrameCompleted(completionCount: 1)
    XCTAssertNil(
      detector.sample(
        freezeSample(
          frame: 21, rendered: false, renderFailureReason: .previousFrameInFlight,
          metalFrameCompletions: 1,
          now: start.addingTimeInterval(1))))

    let detection = detector.sample(
      freezeSample(
        frame: 22, rendered: false, renderFailureReason: .previousFrameInFlight,
        metalFrameCompletions: 1,
        now: start.addingTimeInterval(2)))
    XCTAssertEqual(
      detection?.freeze.reason,
      GPURenderFreezeDetector.Reason.gpuRenderNoProgress.rawValue)
    XCTAssertNil(detection?.freeze.lastAcceptedFrame)

    let resetDetector = GPURenderFreezeDetector(
      noProgressThreshold: 1,
      duplicateThrottleSeconds: 60)
    resetDetector.noteMetalFrameCompleted(completionCount: 10)
    resetDetector.reset()
    XCTAssertNil(
      resetDetector.sample(
        freezeSample(
          frame: 30, rendered: true, renderFailureReason: nil, metalFrameCompletions: 0,
          now: start.addingTimeInterval(3))))
    resetDetector.noteMetalFrameCompleted(completionCount: 1)
    let resetDetection = resetDetector.sample(
      freezeSample(
        frame: 31, rendered: false, renderFailureReason: .previousFrameInFlight,
        metalFrameCompletions: 1,
        now: start.addingTimeInterval(4)))
    XCTAssertNil(resetDetection?.freeze.lastAcceptedFrame)
  }

  func testPayloadFailureThenCommandRetryChainIsCapturedInJournal() throws {
    let journal = RenderJournal(capacity: 8)
    let bgRect = FrameCommand.rect(
      CGRect(x: 0, y: 0, width: 72, height: 76), color: 0x10_20_30_FF, source: .terminal)
    let terminalGlyph = FrameCommand.glyphRun(
      origin: .zero, text: "A", foreground: 0xFF_FF_FF_FF, background: 0x10_20_30_FF,
      attributes: [], source: .terminal)
    let payload = TerminalCellPayload(
      rows: 4, cols: 8, origin: .zero, cellSize: CGSize(width: 9, height: 19),
      contentYOffset: 0, defaultBackground: 0x10_20_30_FF, dirtyRows: [0])
    let failure = MetalRenderer.GPUCellPayloadBuildFailure(
      reason: "missingGlyphText", row: 0, col: 0, scalarValue: nil, textPreview: nil,
      utf8RangeLowerBound: nil, utf8RangeUpperBound: nil, utf8ByteCount: 0,
      wide: 0, attributesRawValue: 0)

    // Frame N: a payload-compatible frame skips the per-cell terminal glyph
    // commands, then the Metal payload build fails. The journal must capture the
    // payload it tried to build, why it failed, the typed render-failure reason,
    // that terminal glyph commands were skipped (count 0), and that nothing was
    // presented.
    journal.record(
      journal.makeEntry(
        event: .renderFailed, frame: 1, tabId: "t", sessionId: "s",
        damage: .full,
        commands: [bgRect],
        payload: payload,
        gpuCellPayloadFailure: failure,
        renderFailureReason: .fullRedrawProducedNoContent,
        rendered: false))

    // Frame N+1: the command fallback re-emits the terminal glyph commands, runs
    // with no payload, flags the fallback-pending retry state, and repaints full.
    journal.record(
      journal.makeEntry(
        event: .rendered, frame: 2, tabId: "t", sessionId: "s",
        frameState: RenderJournal.FrameStateSnapshot(
          terminalDirty: true, activeTerminalDirty: true, renderInvalidated: true,
          tabChanged: false, cursorBlinkFrame: false, attentionAnimating: false,
          scrollAnimating: false, renderingResizeFrame: false, usingRemoteSnapshots: false,
          gpuCellRequested: true, cellPayloadRequested: false,
          gpuCellCommandFallbackPending: true),
        damage: .full,
        commands: [bgRect, terminalGlyph],
        payload: nil,
        rendered: true))

    let entries = journal.snapshot()
    XCTAssertEqual(entries.map(\.event), [.renderFailed, .rendered])

    let failed = entries[0]
    XCTAssertNotNil(
      failed.payload, "the failed payload frame must record the payload it tried to build")
    XCTAssertEqual(failed.renderFailureReason, .fullRedrawProducedNoContent)
    XCTAssertEqual(failed.gpuCellPayloadFailure?.reason, "missingGlyphText")
    XCTAssertEqual(
      failed.commandCounts?.glyphRuns, 0,
      "terminal glyph commands are skipped on a payload frame, so a blank-frame report shows 0")
    XCTAssertEqual(failed.rendered, false)

    let retry = entries[1]
    XCTAssertNil(retry.payload, "the command fallback frame carries no payload")
    XCTAssertGreaterThan(
      retry.commandCounts?.glyphRuns ?? 0, 0, "the fallback re-emits terminal glyph commands")
    XCTAssertEqual(retry.damage?.kind, "full", "the fallback repaints the whole target")
    XCTAssertEqual(retry.frameState?.gpuCellCommandFallbackPending, true)

    // The whole chain must survive the JSONL dump path the journal writes.
    for entry in entries {
      let encoded = try JSONEncoder().encode(entry)
      let decoded = try JSONDecoder().decode(RenderJournal.Entry.self, from: encoded)
      XCTAssertEqual(decoded.event, entry.event)
      XCTAssertEqual(decoded.renderFailureReason, entry.renderFailureReason)
    }
  }
}

extension JSONDecoder {
  fileprivate static var iso8601: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

private func freezeSample(
  frame: Int = 1,
  tabId: String = "tab",
  sessionId: String = "session",
  gpuDriven: Bool = true,
  terminalDirty: Bool = true,
  activeTerminalDirty: Bool = true,
  renderInvalidated: Bool = false,
  tabChanged: Bool = false,
  scrollAnimating: Bool = false,
  rendered: Bool,
  renderFailureReason: MetalRenderer.RenderFailureReason?,
  metalFrameCompletions: Int = 0,
  now: Date = Date(timeIntervalSince1970: 1_800_000_000)
) -> GPURenderFreezeDetector.Sample {
  GPURenderFreezeDetector.Sample(
    frame: frame,
    tabId: tabId,
    sessionId: sessionId,
    gpuDriven: gpuDriven,
    terminalDirty: terminalDirty,
    activeTerminalDirty: activeTerminalDirty,
    renderInvalidated: renderInvalidated,
    tabChanged: tabChanged,
    scrollAnimating: scrollAnimating,
    rendered: rendered,
    renderFailureReason: renderFailureReason,
    metalFrameCompletions: metalFrameCompletions,
    now: now)
}
