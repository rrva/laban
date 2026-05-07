import CoreGraphics
import Foundation
import LabanCore
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanDebug

final class CaptureReplayTests: XCTestCase {
  func testDeterministicCaptureReplays() throws {
    let capture = try makeCapture(name: "replay-pass")
    let report = try CaptureReplayRunner(captureURL: capture, mode: .both).run()
    XCTAssertEqual(report.terminalReplay, "passed")
    XCTAssertEqual(report.rendererReplay, "passed")
    XCTAssertGreaterThan(report.framesCompared, 0)
    XCTAssertTrue(report.mismatches.isEmpty)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: capture.appendingPathComponent("replay/report.json").path))
  }

  func testReplayReportsFrameCommandHashMismatch() throws {
    let capture = try makeCapture(name: "replay-fail")
    let timelineURL = capture.appendingPathComponent("timeline.ndjson")
    var lines = try String(contentsOf: timelineURL, encoding: .utf8).split(separator: "\n").map(
      String.init)
    for i in lines.indices {
      if lines[i].contains(#""kind":"frame.commands""#) {
        var obj = try JSONSerialization.jsonObject(with: Data(lines[i].utf8)) as! [String: Any]
        obj["sha256"] = "bad-hash"
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        lines[i] = String(data: data, encoding: .utf8)!
        break
      }
    }
    try lines.joined(separator: "\n").appending("\n").write(
      to: timelineURL, atomically: true, encoding: .utf8)

    let report = try CaptureReplayRunner(captureURL: capture, mode: .terminal).run()
    XCTAssertEqual(report.terminalReplay, "failed")
    XCTAssertTrue(report.mismatches.contains { $0.kind == "frameCommandsHash" })
  }

  func testReplayRejectsMalformedTimelineLine() throws {
    let capture = try makeCapture(name: "replay-malformed")
    let timelineURL = capture.appendingPathComponent("timeline.ndjson")
    let text = try String(contentsOf: timelineURL, encoding: .utf8)
      .appending("{not-json}\n")
    try text.write(to: timelineURL, atomically: true, encoding: .utf8)

    XCTAssertThrowsError(try CaptureReplayRunner(captureURL: capture, mode: .terminal).run()) {
      error in
      guard case CaptureReplayError.malformedTimelineLine = error else {
        XCTFail("expected malformedTimelineLine, got \(error)")
        return
      }
    }
  }

  func testReplayAppliesTabClosedBeforeLaterSelectionEvents() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-replay-tab-closed-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    var size = LabanTerminalSize()
    size.rows = 6
    size.cols = 30
    let model = try AppModel(initialSize: size)
    let recorder = try CaptureRecorder(artifactRoot: root, name: "tab-closed")
    model.captureSink = recorder
    model.recordExistingStateForCapture()

    guard let firstTab = model.activeTab,
      let firstSession = model.session(forTab: firstTab.id)
    else {
      XCTFail("missing first session")
      return
    }
    _ = firstSession.replayPtyOutput(Array("first tab survives\r\n".utf8))

    let secondTab = try model.createTab()
    guard let secondSession = model.session(forTab: secondTab.id) else {
      XCTFail("missing second session")
      return
    }
    _ = secondSession.replayPtyOutput(Array("closed tab\r\n".utf8))

    try model.closeTab(secondTab.id)
    recorder.record(
      CaptureTimelineEvent(
        kind: .tabSelected,
        tabId: secondTab.id,
        sessionId: secondTab.sessionId
      ))
    recorder.record(
      CaptureTimelineEvent(
        input: InputEventEnvelope(
          inputId: "stale-selection-after-close",
          source: "appkit",
          kind: "mouse",
          route: "local",
          frameBefore: 1,
          tabId: secondTab.id,
          sessionId: secondTab.sessionId,
          command: "setSelection",
          anchorRow: 0,
          anchorCol: 0,
          focusRow: 0,
          focusCol: 5
        )))
    try recordAppKitFrame(frame: 1, model: model, recorder: recorder)

    _ = try recorder.finish()
    let report = try CaptureReplayRunner(
      captureURL: root.appendingPathComponent("tab-closed"),
      mode: .terminal
    ).run()
    XCTAssertEqual(report.terminalReplay, "passed")
    XCTAssertTrue(report.mismatches.isEmpty)
  }

  func testReplayHandlesAppKitMidSessionCaptureAndLegacyScroll() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-replay-appkit-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    var size = LabanTerminalSize()
    size.rows = 6
    size.cols = 30
    let model = try AppModel(initialSize: size)
    guard let tab = model.activeTab, let session = model.session(forTab: tab.id) else {
      XCTFail("missing active session")
      return
    }

    _ = session.replayPtyOutput(Array("~$ ".utf8))

    let recorder = try CaptureRecorder(artifactRoot: root, name: "appkit-mid-session")
    model.captureSink = recorder
    model.recordExistingStateForCapture()
    try recordAppKitFrame(frame: 1, model: model, recorder: recorder)

    let output = (1...40).map { "\($0)\r\n" }.joined()
    let outputBytes = Data(output.utf8)
    outputBytes.withUnsafeBytes {
      _ = recorder.recordBytes(
        direction: .ptyOutput,
        sessionId: session.id,
        frame: 2,
        bytes: $0,
        preview: nil
      )
    }
    _ = session.replayPtyOutput(Array(outputBytes))
    try recordAppKitFrame(frame: 2, model: model, recorder: recorder)

    _ = session.scrollViewport(deltaRows: -8)
    try recordAppKitFrame(frame: 3, model: model, recorder: recorder)

    _ = try recorder.finish()
    let report = try CaptureReplayRunner(
      captureURL: root.appendingPathComponent("appkit-mid-session")
    ).run()
    XCTAssertEqual(report.terminalReplay, "passed")
    XCTAssertEqual(report.rendererReplay, "passed")
    XCTAssertTrue(report.mismatches.isEmpty)
  }

  private func makeCapture(name: String) throws -> URL {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-replay-\(name)-\(UUID().uuidString)")
    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: name,
      captureName: name,
      captureScreenshots: .final
    )
    _ = runtime.applyAction(#"{"action":"typeText","text":"hello replay"}"#.data(using: .utf8)!)
    let stop = runtime.stopCapture()
    XCTAssertEqual(stop.status, 200)
    let obj = try JSONSerialization.jsonObject(with: stop.body) as! [String: Any]
    let dir = obj["directory"] as! String
    return URL(fileURLWithPath: dir)
  }

  private func recordAppKitFrame(
    frame: Int,
    model: AppModel,
    recorder: CaptureRecorder
  ) throws {
    let fontAtlas = FontAtlas(pointSize: 14)
    let cellSize = fontAtlas.cellSize
    let cellWidth = Int(cellSize.width)
    let cellHeight = Int(cellSize.height)
    let sidebarWidth: CGFloat = 200
    let leftInset: CGFloat = 14
    let rightInset: CGFloat = 8
    let bottomInset: CGFloat = 8
    let topInset: CGFloat = 8
    let scale = 2.0

    guard let activeTab = model.activeTab,
      let session = model.session(forTab: activeTab.id),
      let snap = session.snapshot()
    else {
      XCTFail("missing snapshot")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    let rows = CGFloat(snap.pointee.rows)
    let cols = CGFloat(snap.pointee.cols)
    let logicalWidth = sidebarWidth + leftInset + cols * CGFloat(cellWidth) + rightInset
    let logicalHeight = topInset + rows * CGFloat(cellHeight) + bottomInset

    recorder.record(CaptureTimelineEvent(kind: .frameBegin, frame: frame))
    recorder.recordTerminalSnapshot(
      frame: frame,
      tabId: activeTab.id,
      sessionId: session.id,
      snapshot: UnsafePointer(snap)
    )

    let sidebar = SidebarProducer(
      sidebarWidth: sidebarWidth,
      cellWidth: CGFloat(cellWidth),
      cellHeight: CGFloat(cellHeight)
    )
    var commands = sidebar.commands(
      tabs: model.tabs,
      activeTabId: activeTab.id,
      height: logicalHeight
    )
    commands.append(
      .rect(
        CGRect(
          x: sidebarWidth,
          y: 0,
          width: logicalWidth - sidebarWidth,
          height: logicalHeight
        ),
        color: snap.pointee.default_background_rgba,
        source: .terminal
      ))
    commands += FrameProducer(
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      originX: sidebarWidth + leftInset,
      originY: bottomInset
    ).commands(from: UnsafePointer(snap))

    recorder.recordFrameCommands(
      frame: frame,
      commands: commands,
      surfaceWidth: Int(logicalWidth * scale),
      surfaceHeight: Int(logicalHeight * scale),
      scale: scale
    )
  }
}
