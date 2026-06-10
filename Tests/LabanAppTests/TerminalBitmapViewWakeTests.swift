import AppKit
import Darwin
import LabanCore
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanApp

/// Wake-source coverage for the fully parked display link (the display-link
/// full-park ExecPlan, Milestone 2). Each test fails if its wake is removed:
/// with no idle 8 Hz floor, an input or model mutation that does not call
/// `advanceFrame(wake:)` (directly or through the kick coalescer) leaves a
/// permanently stale frame — the frozen-frame bug class. The assertions read
/// `advanceFrameCallCountForTesting`, stamped at the top of every
/// `advanceFrame(wake:)` entry, so they hold without a window or display.
final class TerminalBitmapViewWakeTests: XCTestCase {

  private var savedRenderer: String?

  override func setUp() {
    super.setUp()
    savedRenderer = getenv("LABAN_RENDERER").map { String(cString: $0) }
    setenv("LABAN_RENDERER", "software", 1)
  }

  override func tearDown() {
    if let savedRenderer {
      setenv("LABAN_RENDERER", savedRenderer, 1)
    } else {
      unsetenv("LABAN_RENDERER")
    }
    super.tearDown()
  }

  private struct Harness {
    let model: AppModel
    let view: TerminalBitmapView
    let cellWidth: Int
    let cellHeight: Int
  }

  private func makeHarness(rows: Int32 = 4, cols: Int32 = 40) throws -> Harness {
    var size = LabanTerminalSize()
    size.rows = rows
    size.cols = cols
    let model = try AppModel(initialSize: size) { try Session.fixture(size: $0) }

    let fontAtlas = FontAtlas(pointSize: 14)
    let sidebarFontAtlas = FontAtlas(pointSize: 11)
    let cellSize = fontAtlas.cellSize
    let cellWidth = Int(cellSize.width)
    let cellHeight = Int(cellSize.height)
    let insets = TerminalBitmapView.contentInsets
    let viewWidth =
      SidebarLayout.defaultWidth + insets.left + CGFloat(cols) * CGFloat(cellWidth) + insets.right
    let viewHeight =
      TerminalBitmapView.titlebarReservedHeight + insets.top + CGFloat(rows) * CGFloat(cellHeight)
      + insets.bottom

    let view = TerminalBitmapView(
      model: model,
      fontAtlas: fontAtlas,
      sidebarFontAtlas: sidebarFontAtlas,
      cellWidth: cellWidth,
      cellHeight: cellHeight
    )
    view.frame = NSRect(x: 0, y: 0, width: viewWidth, height: viewHeight)
    return Harness(model: model, view: view, cellWidth: cellWidth, cellHeight: cellHeight)
  }

  /// Spin the main run loop until `condition` holds or `timeout` elapses.
  /// Used for wakes that hop through the display-kick coalescer (a
  /// main-actor task) or `scheduleRenderRetry` (a main-queue async block).
  private func drainMainQueue(
    timeout: TimeInterval = 2.0,
    until condition: () -> Bool
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return condition()
  }

  // MARK: - Row 3: keyboard

  func testKeyDownWakesFrameLoop() throws {
    let harness = try makeHarness()
    let baseline = harness.view.advanceFrameCallCountForTesting

    let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
    let event = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.function, .numericPad],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        characters: down,
        charactersIgnoringModifiers: down,
        isARepeat: false,
        keyCode: 125))
    harness.view.keyDown(with: event)

    XCTAssertGreaterThan(
      harness.view.advanceFrameCallCountForTesting,
      baseline,
      "keyDown must synchronously wake the frame loop; a parked link gets no echo repaint otherwise"
    )
  }

  // MARK: - Row 4: scroll wheel

  func testScrollWheelWakesFrameLoop() throws {
    let harness = try makeHarness()
    // Land inside the terminal content area: right of the sidebar, below the
    // titlebar strip, so none of the chrome guards swallow the event.
    let pt = NSPoint(
      x: SidebarLayout.defaultWidth + 40,
      y: harness.view.bounds.height - TerminalBitmapView.titlebarReservedHeight - 20)
    let baseline = harness.view.advanceFrameCallCountForTesting

    harness.view.scrollWheel(
      with: TestScrollWheelEvent(locationInWindow: pt, deltaY: 2))

    XCTAssertGreaterThan(
      harness.view.advanceFrameCallCountForTesting,
      baseline,
      "scrollWheel must synchronously wake the frame loop; the first frame starts the glide and un-parks the link"
    )
  }

  // MARK: - Rows 5 + 9: model mutations through onSurfaceStateChanged

  func testTabMutationWakesFrameLoopThroughCoalescer() throws {
    let harness = try makeHarness()
    // Creating a tab is a workspace mutation; AppModel fires
    // onSurfaceStateChanged, which the view subscribes through the
    // display-kick coalescer. The wake must produce a RENDERED frame, not
    // just an advanceFrame call (M2-5 review finding F1).
    let wakeBaseline = harness.view.advanceFrameCallCountForTesting
    let renderBaseline = harness.view.renderedFrameCountForTests
    _ = try harness.model.createTab()

    XCTAssertTrue(
      drainMainQueue { harness.view.advanceFrameCallCountForTesting > wakeBaseline },
      "a tab mutation must wake the frame loop via onSurfaceStateChanged -> coalescer -> advanceFrame"
    )
    XCTAssertTrue(
      drainMainQueue { harness.view.renderedFrameCountForTests > renderBaseline },
      "the model-mutation wake must repaint, not just call advanceFrame"
    )
  }

  func testSurfaceSignalsWakeFrameLoopThroughCoalescer() throws {
    let harness = try makeHarness()
    let tab = try XCTUnwrap(harness.model.activeTab)

    // Render to a quiescent baseline first: the next advanceFrame must
    // early-return (no dirty output, no invalidation), proving any later
    // render is attributable to the surface-signals wake alone. This is the
    // F1 repaint proof: applySurfaceSignals bumps NO dirty generation, so
    // the woken frame's gated syncSessions reports the tab unchanged — only
    // the subscriber's own renderInvalidated can make that frame paint.
    harness.view.advanceFrame()
    let renderBaseline = harness.view.renderedFrameCountForTests
    XCTAssertGreaterThan(renderBaseline, 0, "baseline frame must render")
    harness.view.advanceFrame()
    XCTAssertEqual(
      harness.view.renderedFrameCountForTests, renderBaseline,
      "harness must be quiescent before the mutation so the render delta is attributable")

    let signals = TabSurfaceSignals(titleDirty: true, titleRaw: "daemon title")
    let wakeBaseline = harness.view.advanceFrameCallCountForTesting
    XCTAssertTrue(harness.model.applySurfaceSignals(signals, forTab: tab.id))

    XCTAssertTrue(
      drainMainQueue { harness.view.advanceFrameCallCountForTesting > wakeBaseline },
      "daemon surface signals change pixels with no terminal bytes; the model-level hook is the only wake"
    )
    XCTAssertTrue(
      drainMainQueue { harness.view.renderedFrameCountForTests > renderBaseline },
      "a wake that never repaints is still a frozen screen: the woken frame must paint the signal change"
    )
  }

  // MARK: - Row 13: Reduce Motion

  func testReduceMotionChangeWakesFrameLoop() throws {
    let harness = try makeHarness()
    let baseline = harness.view.advanceFrameCallCountForTesting

    NSWorkspace.shared.notificationCenter.post(
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: NSWorkspace.shared)

    XCTAssertTrue(
      drainMainQueue { harness.view.advanceFrameCallCountForTesting > baseline },
      "a Reduce Motion flip must schedule a frame; invalidation alone never paints on a parked link"
    )
  }
}
