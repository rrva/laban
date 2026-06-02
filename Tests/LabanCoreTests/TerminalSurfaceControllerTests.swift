import CoreGraphics
import Foundation
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanCore

final class TerminalSurfaceControllerTests: XCTestCase {
  private final class RecordingSurfaceCaptureSink: TerminalSurfaceCaptureSink {
    var events: [CaptureTimelineEvent] = []
    var frameCommands: [[FrameCommand]] = []

    func nextSequence() -> Int { events.count + 1 }

    func record(_ event: CaptureTimelineEvent) {
      events.append(event)
    }

    func recordBytes(
      direction: CaptureByteDirection,
      sessionId: Session.ID?,
      frame: Int,
      bytes: UnsafeRawBufferPointer,
      preview: String?
    ) -> CaptureByteRef? {
      nil
    }

    func recordTerminalSnapshot(
      frame: Int,
      tabId: String?,
      sessionId: String?,
      snapshot: UnsafePointer<LabanSnapshot>
    ) -> String? {
      nil
    }

    func recordFrameCommands(
      frame: Int,
      commands: [FrameCommand],
      surfaceWidth: Int,
      surfaceHeight: Int,
      scale: Double,
      backend: String
    ) -> CaptureFrameRef? {
      frameCommands.append(commands)
      return nil
    }
  }

  private func commandKey(_ command: FrameCommand) -> String {
    func rectKey(_ rect: CGRect) -> String {
      String(
        format: "%.4f,%.4f,%.4f,%.4f", rect.origin.x, rect.origin.y, rect.width, rect.height)
    }
    func pointKey(_ point: CGPoint) -> String {
      String(format: "%.4f,%.4f", point.x, point.y)
    }
    switch command {
    case .rect(let rect, let color, let source):
      return "rect|\(rectKey(rect))|\(color)|\(source.rawValue)"
    case .glyphRun(
      let origin, let text, let foreground, let background, let attributes, let source,
      let underlineStyle, let underlineColor, let hyperlink):
      let scalars = text.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: ".")
      return
        "glyph|\(pointKey(origin))|chars=\(text.count)|scalars=\(scalars)|fg=\(foreground)"
        + "|bg=\(background)|attrs=\(attributes.rawValue)|src=\(source.rawValue)"
        + "|us=\(underlineStyle.rawValue)|uc=\(underlineColor.map(String.init) ?? "nil")"
        + "|link=\(hyperlink ?? "nil")"
    case .cursor(let rect, let color):
      return "cursor|\(rectKey(rect))|\(color)"
    case .selection(let rect, let color):
      return "selection|\(rectKey(rect))|\(color)"
    case .findMatch(let rect, let color):
      return "findMatch|\(rectKey(rect))|\(color)"
    case .findSelected(let rect, let color):
      return "findSelected|\(rectKey(rect))|\(color)"
    case .clip(let rect):
      return "clip|\(rectKey(rect))"
    case .texturedQuad(let rect, let resourceId, let source):
      return "texturedQuad|\(rectKey(rect))|\(resourceId)|\(source.rawValue)"
    }
  }

  private func commandKeys(_ commands: [FrameCommand]) -> [String] {
    commands.map(commandKey)
  }

  func testBuildsSidebarAndTerminalFrameCommands() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let model = try AppModel(initialSize: size)
    guard let tab = model.activeTab,
      let session = model.session(forTab: tab.id)
    else {
      XCTFail("missing active fixture session")
      return
    }

    _ = session.write(Array("hello".utf8))
    _ = session.poll()

    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)
    let frame = controller.makeFrame(
      TerminalSurfaceFrameRequest(
        frame: 1,
        viewportWidth: 360,
        viewportHeight: 64,
        requireActiveSnapshot: true,
        surfaceWidth: 360,
        surfaceHeight: 64,
        surfaceScale: 1))

    guard let frame else {
      XCTFail("expected a frame from the active snapshot")
      return
    }

    XCTAssertEqual(frame.tabId, tab.id)
    XCTAssertEqual(frame.sessionId, session.id)
    XCTAssertEqual(frame.rows, 4)
    XCTAssertEqual(frame.cols, 20)
    let hasSidebarRect = frame.commands.contains { command in
      if case .rect(_, _, let source) = command { return source == .sidebar }
      return false
    }
    XCTAssertTrue(hasSidebarRect)

    let terminalText = frame.commands.compactMap { command -> String? in
      if case .glyphRun(_, let text, _, _, _, let source, _, _, _) = command,
        source == .terminal
      {
        return text
      }
      return nil
    }.joined()
    XCTAssertTrue(terminalText.contains("hello"), "got terminal text \(terminalText)")
  }

  func testCellPayloadModeSkipsTerminalCommandsWhenCompatible() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let model = try AppModel(initialSize: size)
    let tab = try XCTUnwrap(model.activeTab)
    let session = try XCTUnwrap(model.session(forTab: tab.id))

    _ = session.write(Array("hello".utf8))
    _ = session.poll()

    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)
    let frame = try XCTUnwrap(
      controller.makeFrame(
        TerminalSurfaceFrameRequest(
          frame: 1,
          viewportWidth: 360,
          viewportHeight: 64,
          requireActiveSnapshot: true,
          surfaceWidth: 360,
          surfaceHeight: 64,
          surfaceScale: 1,
          contentMode: .cellPayloadPreferred)))

    XCTAssertEqual(frame.tabId, tab.id)
    let payload = try XCTUnwrap(frame.cellPayload)
    XCTAssertNil(payload.fallbackReason)
    XCTAssertTrue(payload.glyphs.contains { $0.scalarValue == Character("h").unicodeScalars.first?.value })
    let terminalGlyphCommands = frame.commands.filter { command in
      if case .glyphRun(_, _, _, _, _, let source, _, _, _) = command {
        return source == .terminal
      }
      return false
    }
    XCTAssertTrue(terminalGlyphCommands.isEmpty)
  }

  func testBottomFollowOutputForcesFullDamageWhenViewportOffsetChanges() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 28
    let model = try AppModel(initialSize: size)
    let tab = try XCTUnwrap(model.activeTab)
    let session = try XCTUnwrap(model.session(forTab: tab.id))
    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 0)

    func makeFrame(_ frame: Int, forceFull: Bool) throws -> TerminalSurfaceFrame {
      try XCTUnwrap(
        controller.makeFrame(
          TerminalSurfaceFrameRequest(
            frame: frame,
            viewportWidth: 224,
            viewportHeight: 64,
            requireActiveSnapshot: true,
            forceFullDamage: forceFull,
            surfaceWidth: 224,
            surfaceHeight: 64,
            surfaceScale: 1,
            contentMode: .cellPayloadPreferred)))
    }

    let initialOutput = (1...8).map { "old-\($0)" }.joined(separator: "\r\n") + "\r\n"
    XCTAssertEqual(session.feedOutput(Array(initialOutput.utf8)), 0)
    _ = try makeFrame(1, forceFull: true)
    XCTAssertEqual(session.markRendered(), 0)
    let before = try XCTUnwrap(session.viewportState()).viewportOffset

    XCTAssertEqual(session.feedOutput(Array("new-bottom-line\r\n".utf8)), 0)
    let next = try makeFrame(2, forceFull: false)
    let after = try XCTUnwrap(session.viewportState()).viewportOffset
    XCTAssertGreaterThan(after, before, "test setup must move the bottom-following viewport")

    guard case .full = next.damage else {
      XCTFail("viewport offset changes must force full damage, got \(next.damage)")
      return
    }
    XCTAssertEqual(next.cellPayload?.dirtyRows, Array(0..<Int(size.rows)))
  }

  func testCaptureCommandStreamIgnoresCellPayloadPreference() throws {
    func capturedCommands(
      contentMode: TerminalSurfaceFrameContentMode
    ) throws -> (commands: [String], returnedPayload: TerminalCellPayload?) {
      var size = LabanTerminalSize()
      size.rows = 4
      size.cols = 40
      let model = try AppModel(initialSize: size)
      let tab = try XCTUnwrap(model.activeTab)
      let session = try XCTUnwrap(model.session(forTab: tab.id))

      _ = session.write(Array("\u{1B}[4mhello\u{1B}[0m capture\r\n".utf8))
      _ = session.poll()

      let sink = RecordingSurfaceCaptureSink()
      let controller = TerminalSurfaceController(
        model: model,
        cellWidth: 8,
        cellHeight: 16,
        sidebarWidth: 200,
        captureSink: sink)
      let frame = try XCTUnwrap(
        controller.makeFrame(
          TerminalSurfaceFrameRequest(
            frame: 1,
            viewportWidth: 520,
            viewportHeight: 64,
            now: Date(timeIntervalSince1970: 1_234),
            reduceMotion: true,
            requireActiveSnapshot: true,
            surfaceWidth: 520,
            surfaceHeight: 64,
            surfaceScale: 1,
            contentMode: contentMode)))

      XCTAssertEqual(sink.frameCommands.count, 1)
      return (commandKeys(try XCTUnwrap(sink.frameCommands.first)), frame.cellPayload)
    }

    let classic = try capturedCommands(contentMode: .commands)
    let payloadPreferred = try capturedCommands(contentMode: .cellPayloadPreferred)

    XCTAssertNil(classic.returnedPayload)
    XCTAssertNil(payloadPreferred.returnedPayload)
    XCTAssertEqual(payloadPreferred.commands, classic.commands)
  }

  func testCellPayloadModeKeepsTextDecorationsOnPayloadPath() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 80
    let model = try AppModel(initialSize: size)
    let tab = try XCTUnwrap(model.activeTab)
    let session = try XCTUnwrap(model.session(forTab: tab.id))

    let line =
      "\u{1B}[4mUL\u{1B}[0m "
      + "\u{1B}[9mSTRK\u{1B}[0m "
      + "\u{1B}[53mOVR\u{1B}[0m\r\n"
    _ = session.write(Array(line.utf8))
    _ = session.poll()

    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)
    let frame = try XCTUnwrap(
      controller.makeFrame(
        TerminalSurfaceFrameRequest(
          frame: 1,
          viewportWidth: 840,
          viewportHeight: 64,
          requireActiveSnapshot: true,
          surfaceWidth: 840,
          surfaceHeight: 64,
          surfaceScale: 1,
          contentMode: .cellPayloadPreferred)))

    let payload = try XCTUnwrap(frame.cellPayload)
    XCTAssertNil(payload.fallbackReason)
    XCTAssertTrue(payload.glyphs.contains { $0.attributes.contains(.underline) })
    XCTAssertTrue(payload.glyphs.contains { $0.attributes.contains(.strikethrough) })
    XCTAssertTrue(payload.glyphs.contains { $0.attributes.contains(.overline) })
    let terminalGlyphCommands = frame.commands.filter { command in
      if case .glyphRun(_, _, _, _, _, let source, _, _, _) = command {
        return source == .terminal
      }
      return false
    }
    XCTAssertTrue(terminalGlyphCommands.isEmpty)
  }

  func testCellPayloadModeKeepsProceduralCellsOnPayloadPath() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 40
    let model = try AppModel(initialSize: size)
    let tab = try XCTUnwrap(model.activeTab)
    let session = try XCTUnwrap(model.session(forTab: tab.id))

    _ = session.write(Array("█▀▄▌▐░▓▖▚▟◢◣◤◥".utf8))
    _ = session.poll()

    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)
    let frame = try XCTUnwrap(
      controller.makeFrame(
        TerminalSurfaceFrameRequest(
          frame: 1,
          viewportWidth: 520,
          viewportHeight: 64,
          requireActiveSnapshot: true,
          surfaceWidth: 520,
          surfaceHeight: 64,
          surfaceScale: 1,
          contentMode: .cellPayloadPreferred)))

    let payload = try XCTUnwrap(frame.cellPayload)
    XCTAssertNil(payload.fallbackReason)
    XCTAssertFalse(payload.proceduralCells.isEmpty)
    let terminalCommands = frame.commands.filter { command in
      switch command {
      case .rect(_, _, let source),
        .glyphRun(_, _, _, _, _, let source, _, _, _):
        return source == .terminal
      default:
        return false
      }
    }
    XCTAssertTrue(terminalCommands.isEmpty)
  }

  func testCellPayloadModeKeepsHyperlinksOnPayloadPath() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 80
    let model = try AppModel(initialSize: size)
    let tab = try XCTUnwrap(model.activeTab)
    let session = try XCTUnwrap(model.session(forTab: tab.id))

    let esc = "\u{1b}"
    let st = "\u{1b}\\"
    let bytes =
      "go "
      + "\(esc)]8;;https://example.com\(st)example.com\(esc)]8;;\(st)"
      + " done\r\n"
    _ = session.write(Array(bytes.utf8))
    _ = session.poll()

    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)
    let frame = try XCTUnwrap(
      controller.makeFrame(
        TerminalSurfaceFrameRequest(
          frame: 1,
          viewportWidth: 840,
          viewportHeight: 64,
          requireActiveSnapshot: true,
          surfaceWidth: 840,
          surfaceHeight: 64,
          surfaceScale: 1,
          contentMode: .cellPayloadPreferred)))

    let payload = try XCTUnwrap(frame.cellPayload)
    XCTAssertNil(payload.fallbackReason)
    XCTAssertTrue(payload.glyphs.contains { $0.hasHyperlink })
    XCTAssertTrue(payload.glyphs.contains { $0.hasHyperlink && $0.attributes.contains(.underline) })
    let terminalCommands = frame.commands.filter { command in
      if case .glyphRun(_, _, _, _, _, let source, _, _, _) = command {
        return source == .terminal
      }
      return false
    }
    XCTAssertTrue(terminalCommands.isEmpty)
  }

  func testCellPayloadModeReusesWarmCapacity() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let model = try AppModel(initialSize: size)
    let session = try XCTUnwrap(model.activeTab.flatMap { model.session(forTab: $0.id) })

    _ = session.write(Array("hello".utf8))
    _ = session.poll()

    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)
    let request = TerminalSurfaceFrameRequest(
      frame: 1,
      viewportWidth: 360,
      viewportHeight: 64,
      requireActiveSnapshot: true,
      surfaceWidth: 360,
      surfaceHeight: 64,
      surfaceScale: 1,
      contentMode: .cellPayloadPreferred)

    _ = try XCTUnwrap(controller.makeFrame(request))
    let warmed = controller.cellPayloadCapacitySnapshotForTesting
    _ = try XCTUnwrap(controller.makeFrame(request))
    XCTAssertEqual(controller.cellPayloadCapacitySnapshotForTesting, warmed)
  }

  func testCellPayloadModeDecodesSingleUTF8ScalarWithoutTextMaterialization() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let model = try AppModel(initialSize: size)
    let session = try XCTUnwrap(model.activeTab.flatMap { model.session(forTab: $0.id) })

    _ = session.write(Array("é".utf8))
    _ = session.poll()

    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)
    let frame = try XCTUnwrap(
      controller.makeFrame(
        TerminalSurfaceFrameRequest(
          frame: 1,
          viewportWidth: 360,
          viewportHeight: 64,
          requireActiveSnapshot: true,
          surfaceWidth: 360,
          surfaceHeight: 64,
          surfaceScale: 1,
          contentMode: .cellPayloadPreferred)))

    let glyph = try XCTUnwrap(frame.cellPayload?.glyphs.first { $0.scalarValue == 0xE9 })
    XCTAssertEqual(glyph.text, "")
    XCTAssertNil(frame.cellPayload?.fallbackReason)
  }

  func testCellPayloadKeepsClusterTextInUTF8SlabOnPayloadPath() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let session = try Session.fixture(size: size)
    defer { session.close() }

    _ = session.write(Array("👩‍💻".utf8))
    _ = session.poll()
    let snap = try XCTUnwrap(session.snapshot())
    defer { laban_snapshot_destroy(snap) }

    let producer = FrameProducer(cellWidth: 8, cellHeight: 16, originX: 0, originY: 0)
    let payload = try XCTUnwrap(
      producer.terminalCellPayload(
        from: UnsafePointer(snap),
        includedRows: [0],
        cursorBlinkVisible: false))

    XCTAssertNil(payload.fallbackReason)
    XCTAssertFalse(payload.utf8Bytes.isEmpty)
    let clusterTexts = payload.glyphs.compactMap { glyph -> String? in
      guard let range = glyph.utf8Range else { return nil }
      return String(decoding: payload.utf8Bytes[range], as: UTF8.self)
    }
    XCTAssertTrue(clusterTexts.contains("👩‍💻"), "got cluster payloads \(clusterTexts)")
  }

  func testCellPayloadModeKeepsWideGlyphsOnPayloadPath() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let model = try AppModel(initialSize: size)
    let session = try XCTUnwrap(model.activeTab.flatMap { model.session(forTab: $0.id) })

    _ = session.write(Array("中文A\r\n".utf8))
    _ = session.poll()

    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)
    let frame = try XCTUnwrap(
      controller.makeFrame(
        TerminalSurfaceFrameRequest(
          frame: 1,
          viewportWidth: 360,
          viewportHeight: 64,
          requireActiveSnapshot: true,
          surfaceWidth: 360,
          surfaceHeight: 64,
          surfaceScale: 1,
          contentMode: .cellPayloadPreferred)))

    let payload = try XCTUnwrap(frame.cellPayload)
    XCTAssertNil(payload.fallbackReason)
    XCTAssertTrue(payload.glyphs.contains { $0.wide == UInt8(LABAN_CELL_WIDE_WIDE) })
    let terminalGlyphCommands = frame.commands.filter { command in
      if case .glyphRun(_, _, _, _, _, let source, _, _, _) = command {
        return source == .terminal
      }
      return false
    }
    XCTAssertTrue(terminalGlyphCommands.isEmpty)
  }

  func testCellPayloadModePreservesContentYOffsetOnPayloadPath() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let model = try AppModel(initialSize: size)
    let session = try XCTUnwrap(model.activeTab.flatMap { model.session(forTab: $0.id) })

    _ = session.write(Array("hello\r\n".utf8))
    _ = session.poll()

    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)
    let frame = try XCTUnwrap(
      controller.makeFrame(
        TerminalSurfaceFrameRequest(
          frame: 1,
          viewportWidth: 360,
          viewportHeight: 64,
          contentYOffset: 3.5,
          requireActiveSnapshot: true,
          surfaceWidth: 360,
          surfaceHeight: 64,
          surfaceScale: 1,
          contentMode: .cellPayloadPreferred)))

    let payload = try XCTUnwrap(frame.cellPayload)
    XCTAssertNil(payload.fallbackReason)
    XCTAssertEqual(payload.contentYOffset, 3.5)
  }

  func testCellPayloadModeKeepsSelectionOverlayOnPayloadPath() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let model = try AppModel(initialSize: size)
    let session = try XCTUnwrap(model.activeTab.flatMap { model.session(forTab: $0.id) })

    _ = session.write(Array("hello".utf8))
    _ = session.poll()

    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)
    let selection = TerminalSelection(
      sessionId: session.id,
      anchor: .init(row: 0, col: 0),
      focus: .init(row: 0, col: 2))
    let frame = try XCTUnwrap(
      controller.makeFrame(
        TerminalSurfaceFrameRequest(
          frame: 1,
          viewportWidth: 360,
          viewportHeight: 64,
          selection: selection,
          requireActiveSnapshot: true,
          surfaceWidth: 360,
          surfaceHeight: 64,
          surfaceScale: 1,
          contentMode: .cellPayloadPreferred)))

    let payload = try XCTUnwrap(frame.cellPayload)
    XCTAssertNil(payload.fallbackReason)
    XCTAssertTrue(payload.cursorRects.isEmpty)
    XCTAssertTrue(frame.overlayCommands.contains { command in
      if case .selection = command { return true }
      return false
    })
    XCTAssertTrue(frame.overlayCommands.contains { command in
      if case .cursor = command { return true }
      return false
    })
    let terminalCommands = frame.commands.filter { command in
      switch command {
      case .rect(_, _, let source),
        .glyphRun(_, _, _, _, _, let source, _, _, _):
        return source == .terminal
      default:
        return false
      }
    }
    XCTAssertTrue(terminalCommands.isEmpty)
  }

  func testCellPayloadModeKeepsFindOverlayOnPayloadPath() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 32
    let model = try AppModel(initialSize: size)
    let session = try XCTUnwrap(model.activeTab.flatMap { model.session(forTab: $0.id) })

    _ = session.write(Array("apple banana apple\r\n".utf8))
    _ = session.poll()
    XCTAssertNotNil(model.startFind(sessionID: session.id, needle: "apple"))

    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)
    let frame = try XCTUnwrap(
      controller.makeFrame(
        TerminalSurfaceFrameRequest(
          frame: 1,
          viewportWidth: 456,
          viewportHeight: 64,
          requireActiveSnapshot: true,
          surfaceWidth: 456,
          surfaceHeight: 64,
          surfaceScale: 1,
          contentMode: .cellPayloadPreferred)))

    let payload = try XCTUnwrap(frame.cellPayload)
    XCTAssertNil(payload.fallbackReason)
    XCTAssertTrue(frame.overlayCommands.contains { command in
      if case .findMatch = command { return true }
      return false
    })
    XCTAssertTrue(frame.overlayCommands.contains { command in
      if case .findSelected = command { return true }
      return false
    })
    let terminalGlyphCommands = frame.commands.filter { command in
      if case .glyphRun(_, _, _, _, _, let source, _, _, _) = command {
        return source == .terminal
      }
      return false
    }
    XCTAssertTrue(terminalGlyphCommands.isEmpty)
  }

  func testSyncSessionsReportsDirtySessionsAndMarksOnlyInactiveRendered() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let model = try AppModel(initialSize: size)
    let firstTab = try XCTUnwrap(model.activeTab)
    _ = try model.createTab()
    let secondTab = try XCTUnwrap(model.activeTab)
    model.selectTab(firstTab.id)

    let firstSession = try XCTUnwrap(model.session(forTab: firstTab.id))
    let secondSession = try XCTUnwrap(model.session(forTab: secondTab.id))
    _ = firstSession.markRendered()
    _ = secondSession.markRendered()

    _ = firstSession.feedOutput(Array("active".utf8))
    _ = secondSession.feedOutput(Array("inactive".utf8))

    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)
    let now = Date(timeIntervalSince1970: 42)
    let result = controller.syncSessions(
      captureFrame: 2,
      polling: .none,
      markInactiveDirtyRendered: true,
      noteOutputOnDirty: true,
      recordTitleChanges: false,
      now: now)

    XCTAssertEqual(result.activeTabId, firstTab.id)
    XCTAssertEqual(result.activeSessionId, firstSession.id)
    XCTAssertTrue(result.activeTerminalDirty)
    XCTAssertEqual(result.dirtySessionIds, Set([firstSession.id, secondSession.id]))
    XCTAssertTrue(result.modelChanged)
    XCTAssertTrue(firstSession.renderDirty(), "active session remains dirty for rendering")
    XCTAssertFalse(secondSession.renderDirty(), "inactive dirty session is marked rendered")

    let updatedSecond = try XCTUnwrap(model.tabs.first { $0.id == secondTab.id })
    XCTAssertEqual(updatedSecond.titleMetadata.lastOutputAt, now)
    XCTAssertTrue(updatedSecond.titleMetadata.unseenOutput)
    XCTAssertEqual(updatedSecond.titleMetadata.activityState, .unseenOutput)
  }

  func testSyncSessionsRecordsResolvedTerminalTitleChanges() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let model = try AppModel(initialSize: size)
    let tab = try XCTUnwrap(model.activeTab)
    let session = try XCTUnwrap(model.session(forTab: tab.id))
    let sink = RecordingSurfaceCaptureSink()
    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200,
      captureSink: sink)

    _ = session.feedOutput(Array("\u{1B}]0;vim\u{07}".utf8))
    let result = controller.syncSessions(
      captureFrame: 3,
      polling: .none,
      markInactiveDirtyRendered: false,
      noteOutputOnDirty: false)

    XCTAssertTrue(result.modelChanged)
    XCTAssertEqual(model.tabs.first?.title, "vim")
    XCTAssertEqual(model.tabs.first?.titleMetadata.titleSource, .terminal)
    XCTAssertEqual(sink.events.count, 1)
    XCTAssertEqual(sink.events.first?.kind, CaptureEventKind.appState.rawValue)
    XCTAssertEqual(sink.events.first?.tabId, tab.id)
    XCTAssertEqual(sink.events.first?.sessionId, session.id)
    XCTAssertEqual(sink.events.first?.title, "vim")
  }

  func testVisibleTextSupportsTrimmedAndFullGridModes() throws {
    var size = LabanTerminalSize()
    size.rows = 2
    size.cols = 5
    let session = try Session.fixture(size: size)
    defer { session.close() }

    _ = session.write(Array("hi".utf8))
    _ = session.poll()

    guard let snap = session.snapshot() else {
      XCTFail("missing snapshot")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    XCTAssertEqual(
      TerminalSnapshotText.visibleText(from: UnsafePointer(snap), mode: .trimmedNonEmptyRows),
      "hi")

    let fullGrid = TerminalSnapshotText.visibleText(from: UnsafePointer(snap), mode: .fullGrid)
    let lines = fullGrid.components(separatedBy: "\n")
    XCTAssertEqual(lines.count, 2)
    XCTAssertEqual(lines.first, "hi   ")
    XCTAssertEqual(lines.last, "     ")
  }

  func testDirtyRowDamageMapsTopDownRowsToBottomUpYRanges() {
    let dirtyRows: [UInt8] = [0, 1, 1, 0]
    var snapshot = LabanSnapshot()
    snapshot.rows = 4
    snapshot.dirty_row_count = 4

    let damage = dirtyRows.withUnsafeBufferPointer { buffer -> RenderDamage in
      snapshot.dirty_rows = buffer.baseAddress
      return withUnsafePointer(to: &snapshot) { ptr in
        TerminalSurfaceController.damage(
          snapshot: ptr,
          forceFull: false,
          cellHeight: 5,
          originY: 10)
      }
    }

    XCTAssertEqual(damage, .partial(yRanges: [DirtyYRange(y: 15, height: 10)]))
  }

  func testRemoteDirtyRangesMapTopDownRowsToBottomUpYRanges() {
    let damage = TerminalSurfaceController.damage(
      rows: 5,
      dirtyRanges: [
        LabandSnapshotDirtyRange(startRow: 1, endRow: 3),
        LabandSnapshotDirtyRange(startRow: 4, endRow: 5),
      ],
      forceFull: false,
      cellHeight: 6,
      originY: 10)

    XCTAssertEqual(
      damage,
      .partial(yRanges: [
        DirtyYRange(y: 22, height: 12),
        DirtyYRange(y: 10, height: 6),
      ]))
  }
}
