import CoreGraphics
import Foundation
import LabanCore
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

  func testEnablementAdviceNamesCurrentDefaultsDomainAndEnvironmentOverride() {
    let advice = RenderJournal.enablementAdvice(bundleIdentifier: "com.example.Laban")

    XCTAssertTrue(
      advice.contains(
        "defaults write com.example.Laban \(RenderJournal.enabledDefaultKey) -bool YES"))
    XCTAssertTrue(advice.contains(RenderJournal.enabledEnvironmentKey))
    XCTAssertTrue(advice.contains("relaunch Laban"))
    XCTAssertTrue(advice.contains("different bundle domain"))
  }

  func testRingKeepsNewestEntriesAndDumpsArtifacts() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-render-journal-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
    let process = RenderJournal.ProcessSnapshot(
      processID: 42_424,
      processStartedAt: fixedDate.addingTimeInterval(-120),
      executablePath: "/tmp/Laban.app/Contents/MacOS/LabanApp",
      executableDevice: 1,
      executableInode: 99,
      buildCommit: "abc123+dirty")
    let journal = RenderJournal(
      capacity: 2, dumpRoot: root, clock: { fixedDate }, processID: 42_424,
      process: process)
    journal.record(journal.makeEntry(event: .rendered, frame: 1, tabId: "tab", sessionId: "s"))
    journal.record(journal.makeEntry(event: .rendered, frame: 2, tabId: "tab", sessionId: "s"))
    journal.record(journal.makeEntry(event: .renderFailed, frame: 3, tabId: "tab", sessionId: "s"))

    let entries = journal.snapshot()
    XCTAssertEqual(entries.map(\.frame), [2, 3])
    XCTAssertEqual(entries.last?.event, .renderFailed)
    XCTAssertEqual(entries.map(\.processID), [42_424, 42_424])

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
    XCTAssertEqual(summary.processID, 42_424)
    XCTAssertEqual(summary.process, process)
    XCTAssertEqual(summary.firstFrame, 2)
    XCTAssertEqual(summary.lastFrame, 3)
    XCTAssertEqual(summary.pngFilename, "current-frame.png")

    let jsonl = try String(contentsOf: url.appendingPathComponent("entries.jsonl"), encoding: .utf8)
    XCTAssertEqual(jsonl.split(separator: "\n").count, 2)
    XCTAssertTrue(jsonl.contains(#""processID":42424"#))
  }

  func testGlyphEffectStampDiagnosticsRoundTripInJournalEntry() throws {
    let journal = RenderJournal()
    let stamp = GlyphEffectStampDiagnostics(
      mode: .cellDiff,
      dirtyRows: [31],
      stripColMin: 43,
      stripColMax: 43,
      changedCells: 1,
      stampedRuns: 1,
      stampedGlyphs: 1,
      stampAgeMs: 0,
      generation: 12,
      liveCount: 1,
      animatingRemainingMs: 210)
    let entry = journal.makeEntry(
      event: .rendered,
      frame: 9,
      tabId: "tab",
      sessionId: "s",
      glyphEffect: stamp)
    XCTAssertEqual(entry.glyphEffect, stamp)

    let data = try JSONEncoder().encode(entry)
    let decoded = try JSONDecoder().decode(RenderJournal.Entry.self, from: data)
    XCTAssertEqual(decoded.glyphEffect?.mode, .cellDiff)
    XCTAssertEqual(decoded.glyphEffect?.stripColMin, 43)
    XCTAssertEqual(decoded.glyphEffect?.stampedGlyphs, 1)
    XCTAssertEqual(decoded.glyphEffect?.liveCount, 1)

    // Older dumps without the field still decode.
    let legacy = journal.makeEntry(event: .rendered, frame: 10, tabId: "tab", sessionId: "s")
    let legacyData = try JSONEncoder().encode(legacy)
    let legacyDecoded = try JSONDecoder().decode(RenderJournal.Entry.self, from: legacyData)
    XCTAssertNil(legacyDecoded.glyphEffect)
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
    let drawableAcquire = MetalDrawableAcquireDiagnostic(
      outcome: .timedOut,
      budgetMs: 8,
      elapsedMs: 8.5,
      drawableRequestActiveBefore: false,
      drawableRequestActiveAfter: true,
      pendingDrawablePresentBefore: false,
      pendingDrawablePresentAfter: false,
      layerMaximumDrawableCount: 3,
      layerAllowsNextDrawableTimeout: true)
    let window = RenderJournal.WindowSnapshot(
      isVisible: true,
      isKeyWindow: true,
      isMainWindow: true,
      isMiniaturized: false,
      occlusionVisible: true,
      visibleToUser: true,
      backingScaleFactor: 2,
      screenName: "Built-in Display")
    let displayLink = RenderJournal.DisplayLinkSnapshot(
      kind: "caDisplayLink",
      paused: false,
      preferredFramesPerSecond: 60,
      minimumFramesPerSecond: 8,
      maximumFramesPerSecond: 120,
      reason: "terminalOutputActive",
      terminalOutputActive: true,
      attentionAnimating: false,
      scrollAnimating: false,
      lastTickIntervalMs: 16.7)
    let entry = journal.makeEntry(
      event: .renderFailed,
      frame: 7,
      tabId: "tab",
      sessionId: "s",
      window: window,
      displayLink: displayLink,
      drawableAcquire: drawableAcquire,
      renderFailureReason: .fullRedrawProducedNoContent)
    XCTAssertEqual(entry.renderFailureReason, .fullRedrawProducedNoContent)
    XCTAssertEqual(entry.drawableAcquire, drawableAcquire)
    XCTAssertEqual(entry.window, window)
    XCTAssertEqual(entry.displayLink, displayLink)

    // The dump path serializes entries as JSONL, so the reason must round-trip.
    let encoded = try JSONEncoder().encode(entry)
    let decoded = try JSONDecoder().decode(RenderJournal.Entry.self, from: encoded)
    XCTAssertEqual(decoded.renderFailureReason, .fullRedrawProducedNoContent)
    XCTAssertEqual(decoded.drawableAcquire, drawableAcquire)
    XCTAssertEqual(decoded.window, window)
    XCTAssertEqual(decoded.displayLink, displayLink)
  }

  func testWakeSourceRoundTripsAndOldDumpsWithoutItStillDecode() throws {
    let journal = RenderJournal()

    // The full-park forensic field round-trips through the JSONL dump path.
    let entry = journal.makeEntry(
      event: .rendered,
      frame: 1,
      tabId: "tab",
      sessionId: "s",
      wakeSource: "keyboard")
    XCTAssertEqual(entry.wakeSource, "keyboard")
    let encoded = try JSONEncoder().encode(entry)
    let decoded = try JSONDecoder().decode(RenderJournal.Entry.self, from: encoded)
    XCTAssertEqual(decoded.wakeSource, "keyboard")

    // Pre-M2 dumps have no wakeSource key; they must keep decoding (the
    // field is optional, mirroring the modelChanged precedent).
    let legacy = journal.makeEntry(event: .rendered, frame: 2, tabId: "tab", sessionId: "s")
    XCTAssertNil(legacy.wakeSource)
    var legacyJSON = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
    legacyJSON.removeValue(forKey: "wakeSource")
    let legacyData = try JSONSerialization.data(withJSONObject: legacyJSON)
    let legacyDecoded = try JSONDecoder().decode(RenderJournal.Entry.self, from: legacyData)
    XCTAssertNil(legacyDecoded.wakeSource)
    XCTAssertEqual(legacyDecoded.frame, 2)
  }

  func testSkippedEntryDropsCarriedDrawableAcquireDiagnostic() {
    let journal = RenderJournal()
    let diagnostic = MetalDrawableAcquireDiagnostic(
      outcome: .timedOut,
      budgetMs: 8,
      elapsedMs: 8.5,
      drawableRequestActiveBefore: false,
      drawableRequestActiveAfter: true,
      pendingDrawablePresentBefore: false,
      pendingDrawablePresentAfter: false,
      layerMaximumDrawableCount: 3,
      layerAllowsNextDrawableTimeout: true)

    // A skipped frame never reached `render()`, so even though the renderer
    // still carries the last rendered frame's acquire diagnostic, the journal
    // entry must not misattribute it to the skip.
    let skipped = journal.makeEntry(
      event: .skipped, frame: 9, tabId: "tab", sessionId: "s",
      drawableAcquire: diagnostic)
    XCTAssertNil(skipped.drawableAcquire)

    // Render-bearing events did acquire (or attempt to acquire) a drawable, so
    // they keep the diagnostic.
    for event in [RenderJournal.Event.rendered, .renderFailed, .freezeDetected] {
      let entry = journal.makeEntry(
        event: event, frame: 9, tabId: "tab", sessionId: "s",
        drawableAcquire: diagnostic)
      XCTAssertEqual(entry.drawableAcquire, diagnostic, "\(event) must keep the diagnostic")
    }
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

  func testGPUFreezeDetectorIgnoresSoftwareAndCursorOnlyFailures() {
    let detector = GPURenderFreezeDetector(noProgressThreshold: 1)

    XCTAssertNil(
      detector.sample(
        freezeSample(
          gpuBackend: false,
          terminalDirty: true,
          rendered: false,
          renderFailureReason: .previousFrameInFlight)))
    XCTAssertNil(
      detector.sample(
        freezeSample(
          gpuBackend: true,
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

/// The detector used to be gated on the opt-in `gpuDriven` renderer mode, which
/// left the no-progress retry loop undetectable on `vectorGlyph` — the backend
/// existing installs actually run, and where the loop was observed in
/// production (291 consecutive refusals of one frame across five seconds,
/// 2026-08-24). The gate is now "any GPU backend", so a non-`gpuDriven` Metal
/// backend reaches the same detection.
final class GPURenderFreezeDetectorBackendCoverageTests: XCTestCase {

  func testNonGPUDrivenMetalBackendStillReachesDetection() {
    let detector = GPURenderFreezeDetector(noProgressThreshold: 2, duplicateThrottleSeconds: 60)
    // Two consecutive refusals of a frame that still has visible work pending —
    // the vector-backend signature, on a backend that is not `gpuDriven`.
    XCTAssertNil(
      detector.sample(
        freezeSample(
          gpuBackend: true,
          terminalDirty: true,
          rendered: false,
          renderFailureReason: .previousFrameInFlight)))
    let detection = detector.sample(
      freezeSample(
        gpuBackend: true,
        terminalDirty: true,
        rendered: false,
        renderFailureReason: .previousFrameInFlight))
    XCTAssertNotNil(detection)
    XCTAssertEqual(detection?.freeze.noProgressStreak, 2)
    XCTAssertEqual(detection?.freeze.renderFailureReason, .previousFrameInFlight)
  }

  /// A rendered frame is progress: it must clear the streak so ordinary
  /// drop-and-repaint cadence never accumulates toward a false dump.
  func testRenderedFrameClearsTheStreak() {
    let detector = GPURenderFreezeDetector(noProgressThreshold: 2, duplicateThrottleSeconds: 60)
    XCTAssertNil(
      detector.sample(
        freezeSample(
          gpuBackend: true, terminalDirty: true, rendered: false,
          renderFailureReason: .previousFrameInFlight)))
    XCTAssertNil(
      detector.sample(
        freezeSample(
          gpuBackend: true, terminalDirty: true, rendered: true,
          renderFailureReason: nil)))
    XCTAssertNil(
      detector.sample(
        freezeSample(
          gpuBackend: true, terminalDirty: true, rendered: false,
          renderFailureReason: .previousFrameInFlight)))
  }
}

private func freezeSample(
  frame: Int = 1,
  tabId: String = "tab",
  sessionId: String = "session",
  gpuBackend: Bool = true,
  terminalDirty: Bool = true,
  activeTerminalDirty: Bool = true,
  renderInvalidated: Bool = false,
  tabChanged: Bool = false,
  scrollAnimating: Bool = false,
  rendered: Bool,
  renderFailureReason: RenderFailureReason?,
  metalFrameCompletions: Int = 0,
  now: Date = Date(timeIntervalSince1970: 1_800_000_000)
) -> GPURenderFreezeDetector.Sample {
  GPURenderFreezeDetector.Sample(
    frame: frame,
    tabId: tabId,
    sessionId: sessionId,
    gpuBackend: gpuBackend,
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
