import AppKit
import CoreGraphics
import LabanCore
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanApp

final class TerminalCaptureIndicatorTests: XCTestCase {
  func testMenuTitleFlipsWithCaptureState() {
    XCTAssertEqual(TerminalCaptureIndicator.menuTitle(active: false), "Start PTY Capture")
    XCTAssertEqual(TerminalCaptureIndicator.menuTitle(active: true), "Stop PTY Capture")
  }

  func testWindowTitleSuffixOnlyAppearsWhileCapturing() {
    XCTAssertEqual(TerminalCaptureIndicator.windowTitleSuffix(active: false), "")
    XCTAssertEqual(TerminalCaptureIndicator.windowTitleSuffix(active: true), " — ● REC")
  }

  func testPillTextIsVisibleRecordingMarker() {
    XCTAssertEqual(TerminalCaptureIndicator.pillText, "● REC")
  }

  func testValidateMenuItemMutatesTitleForToggleAction() {
    let item = NSMenuItem(
      title: "placeholder",
      action: #selector(TerminalBitmapView.toggleCapture(_:)),
      keyEquivalent: "r")
    // Drives off TerminalCaptureIndicator.menuTitle(active:), the same source
    // of truth the pill and window-title suffix use, so they cannot disagree.
    item.title = TerminalCaptureIndicator.menuTitle(active: false)
    XCTAssertEqual(item.title, "Start PTY Capture")
    item.title = TerminalCaptureIndicator.menuTitle(active: true)
    XCTAssertEqual(item.title, "Stop PTY Capture")
  }

  func testIndicatorViewRendersRecMarker() {
    let view = TerminalCaptureIndicatorView(frame: .zero)
    let label = view.subviews.compactMap { $0 as? NSTextField }.first
    XCTAssertEqual(label?.stringValue, "● REC")
    // Decorative overlay: clicks fall through to the terminal beneath.
    XCTAssertNil(view.hitTest(NSPoint(x: 1, y: 1)))
  }

  func testToggleCaptureFlipsMenuTitleAndShowsRecPill() throws {
    let oldRenderer = getenv("LABAN_RENDERER").map { String(cString: $0) }
    setenv("LABAN_RENDERER", "software", 1)
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-capture-indicator-\(UUID().uuidString)")
    let oldCaptureDir = getenv("LABAN_CAPTURE_DIR").map { String(cString: $0) }
    setenv("LABAN_CAPTURE_DIR", tempDir.path, 1)
    defer {
      if let oldRenderer { setenv("LABAN_RENDERER", oldRenderer, 1) }
      else { unsetenv("LABAN_RENDERER") }
      if let oldCaptureDir { setenv("LABAN_CAPTURE_DIR", oldCaptureDir, 1) }
      else { unsetenv("LABAN_CAPTURE_DIR") }
      try? FileManager.default.removeItem(at: tempDir)
    }

    var size = LabanTerminalSize()
    size.rows = 5
    size.cols = 40
    let model = try AppModel(initialSize: size) { try Session.fixture(size: $0) }

    let fontAtlas = FontAtlas(pointSize: 14)
    let sidebarFontAtlas = FontAtlas(pointSize: 11)
    let cellSize = fontAtlas.cellSize
    let insets = TerminalBitmapView.contentInsets
    let viewWidth =
      SidebarLayout.defaultWidth + insets.left + CGFloat(size.cols) * cellSize.width + insets.right
    let viewHeight = insets.top + CGFloat(size.rows) * cellSize.height + insets.bottom

    let view = TerminalBitmapView(
      model: model,
      fontAtlas: fontAtlas,
      sidebarFontAtlas: sidebarFontAtlas,
      cellWidth: Int(cellSize.width),
      cellHeight: Int(cellSize.height)
    )
    view.frame = NSRect(x: 0, y: 0, width: viewWidth, height: viewHeight)

    let menuItem = NSMenuItem(
      title: "placeholder",
      action: #selector(TerminalBitmapView.toggleCapture(_:)),
      keyEquivalent: "r")

    // Idle: menu says "Start", no pill on the surface.
    XCTAssertFalse(view.isCaptureActive)
    XCTAssertTrue(view.validateMenuItem(menuItem))
    XCTAssertEqual(menuItem.title, "Start PTY Capture")
    XCTAssertFalse(view.subviews.contains { $0 is TerminalCaptureIndicatorView })

    // Start capture: menu flips to "Stop", a "● REC" pill appears.
    view.toggleCapture(nil)
    XCTAssertTrue(view.isCaptureActive)
    XCTAssertTrue(view.validateMenuItem(menuItem))
    XCTAssertEqual(menuItem.title, "Stop PTY Capture")
    XCTAssertTrue(view.subviews.contains { $0 is TerminalCaptureIndicatorView })

    // Stop capture: menu returns to "Start", the pill is removed.
    view.toggleCapture(nil)
    XCTAssertFalse(view.isCaptureActive)
    XCTAssertTrue(view.validateMenuItem(menuItem))
    XCTAssertEqual(menuItem.title, "Start PTY Capture")
    XCTAssertFalse(view.subviews.contains { $0 is TerminalCaptureIndicatorView })
  }
}
