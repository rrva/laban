import AppKit
import LabanCore
import XCTest

@testable import LabanApp

@MainActor
final class TerminalBackgroundEffectHostTests: XCTestCase {
  func testSystemBlurOwnsExactlyOneStandardBehindWindowMaterial() throws {
    let host = TerminalBackgroundEffectHost(frame: NSRect(x: 0, y: 0, width: 640, height: 360))

    XCTAssertTrue(host.isHidden)
    XCTAssertEqual(host.appliedStyle, .none)
    XCTAssertEqual(host.backdropSubviewCount, 0)
    XCTAssertTrue(host.subviews.isEmpty)
    XCTAssertFalse(host.supportsBehindWindowBlur)

    host.apply(.systemBlur)

    let effectView = try XCTUnwrap(host.subviews.first as? NSVisualEffectView)
    XCTAssertFalse(host.isHidden)
    XCTAssertEqual(host.appliedStyle, .systemBlur)
    XCTAssertEqual(host.backdropSubviewCount, 1)
    XCTAssertEqual(host.subviews.count, 1)
    XCTAssertEqual(effectView.material, .underWindowBackground)
    XCTAssertEqual(effectView.blendingMode, .behindWindow)
    XCTAssertEqual(effectView.state, .active)

    host.apply(.systemBlur)

    XCTAssertTrue(host.subviews.first === effectView)
    XCTAssertEqual(host.backdropSubviewCount, 1)
    XCTAssertEqual(host.subviews.count, 1)

    host.apply(.none)

    XCTAssertTrue(host.isHidden)
    XCTAssertEqual(host.appliedStyle, .none)
    XCTAssertEqual(host.backdropSubviewCount, 0)
    XCTAssertTrue(host.subviews.isEmpty)
    XCTAssertNil(effectView.superview)
  }

  func testPlacementExcludesOpaqueSidebarAndTracksContainerResize() {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 500))
    let host = TerminalBackgroundEffectHost(frame: .zero)
    host.install(in: container, terminalLeadingInset: SidebarLayout.defaultWidth)

    container.layoutSubtreeIfNeeded()

    XCTAssertTrue(host.supportsBehindWindowBlur)
    XCTAssertEqual(host.frame.minX, SidebarLayout.defaultWidth, accuracy: 0.001)
    XCTAssertEqual(host.frame.minY, 0, accuracy: 0.001)
    XCTAssertEqual(host.frame.width, 1_000 - SidebarLayout.defaultWidth, accuracy: 0.001)
    XCTAssertEqual(host.frame.height, 500, accuracy: 0.001)

    container.frame.size = NSSize(width: 1_200, height: 720)
    container.layoutSubtreeIfNeeded()

    XCTAssertEqual(host.frame.minX, SidebarLayout.defaultWidth, accuracy: 0.001)
    XCTAssertEqual(host.frame.width, 1_200 - SidebarLayout.defaultWidth, accuracy: 0.001)
    XCTAssertEqual(host.frame.height, 720, accuracy: 0.001)
  }

  func testAppearanceChangesReuseThemeNeutralMaterialChild() throws {
    let host = TerminalBackgroundEffectHost(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
    host.appearance = NSAppearance(named: .aqua)
    host.apply(.systemBlur)
    let effectView = try XCTUnwrap(host.subviews.first as? NSVisualEffectView)

    host.appearance = NSAppearance(named: .darkAqua)
    host.layoutSubtreeIfNeeded()

    XCTAssertTrue(host.subviews.first === effectView)
    XCTAssertEqual(effectView.material, .underWindowBackground)
    XCTAssertEqual(effectView.blendingMode, .behindWindow)
    XCTAssertEqual(effectView.state, .active)
    XCTAssertEqual(host.subviews.count, 1)
  }
}
