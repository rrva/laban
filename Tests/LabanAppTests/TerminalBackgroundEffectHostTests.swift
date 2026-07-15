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
    XCTAssertEqual(host.backdropSubviewKind, .none)
    XCTAssertTrue(host.subviews.isEmpty)
    XCTAssertFalse(host.supportsBehindWindowBlur)

    host.apply(.systemBlur)

    let effectView = try XCTUnwrap(host.subviews.first as? NSVisualEffectView)
    XCTAssertFalse(host.isHidden)
    XCTAssertEqual(host.appliedStyle, .systemBlur)
    XCTAssertEqual(host.backdropSubviewCount, 1)
    XCTAssertEqual(host.backdropSubviewKind, .systemBlur)
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
    XCTAssertEqual(host.backdropSubviewKind, .none)
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

  func testBlurImageAndNoneAreMutuallyExclusiveSemanticChildren() throws {
    let host = TerminalBackgroundEffectHost(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
    let asset = makeAsset(image: makeSolidImage(width: 2, height: 2, color: (255, 0, 0, 255)))

    host.apply(.systemBlur)
    let effectView = try XCTUnwrap(host.subviews.first as? NSVisualEffectView)
    XCTAssertEqual(host.backdropSubviewKind, .systemBlur)

    host.apply(.image, imageAsset: asset, imageScaling: .fit)
    let imageView = try XCTUnwrap(host.imageView)
    XCTAssertNil(effectView.superview)
    XCTAssertTrue(host.subviews.first === imageView)
    XCTAssertEqual(host.subviews.count, 1)
    XCTAssertEqual(host.backdropSubviewCount, 1)
    XCTAssertEqual(host.backdropSubviewKind, .image)
    XCTAssertEqual(host.constraints.filter(\.isActive).count, 4)

    host.apply(.systemBlur)
    XCTAssertNil(imageView.superview)
    XCTAssertEqual(host.subviews.count, 1)
    XCTAssertEqual(host.backdropSubviewCount, 1)
    XCTAssertEqual(host.backdropSubviewKind, .systemBlur)
    XCTAssertEqual(host.constraints.filter(\.isActive).count, 4)

    host.apply(.none)
    XCTAssertTrue(host.subviews.isEmpty)
    XCTAssertEqual(host.constraints.filter(\.isActive).count, 0)
    XCTAssertEqual(host.backdropSubviewCount, 0)
    XCTAssertEqual(host.backdropSubviewKind, .none)
  }

  func testUnavailableImageFailsClosedWithHonestChildState() {
    let host = TerminalBackgroundEffectHost(frame: NSRect(x: 0, y: 0, width: 320, height: 180))

    host.apply(.image, imageAsset: nil)

    XCTAssertTrue(host.isHidden)
    XCTAssertEqual(host.appliedStyle, .none)
    XCTAssertEqual(host.backdropSubviewKind, .none)
    XCTAssertEqual(host.backdropSubviewCount, 0)
  }

  func testUnchangedImageConfigurationReusesDecodedImageAndScalingChangeRedraws() throws {
    let host = TerminalBackgroundEffectHost(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
    let asset = makeAsset(image: makeSolidImage(width: 4, height: 2, color: (0, 255, 0, 255)))

    host.apply(.image, imageAsset: asset, imageScaling: .fill)
    let imageView = try XCTUnwrap(host.imageView)
    XCTAssertEqual(imageView.configurationApplyCount, 1)

    host.apply(.image, imageAsset: asset, imageScaling: .fill)
    XCTAssertTrue(host.imageView === imageView)
    XCTAssertEqual(imageView.configurationApplyCount, 1)

    host.apply(.image, imageAsset: asset, imageScaling: .fit)
    XCTAssertTrue(host.imageView === imageView)
    XCTAssertEqual(imageView.configurationApplyCount, 2)
    XCTAssertEqual(imageView.scaling, .fit)
  }

  func testResizeReusesImageChildAndUpdatesDestinationGeometry() throws {
    let host = TerminalBackgroundEffectHost(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    let asset = makeAsset(image: makeSolidImage(width: 1, height: 1, color: (0, 0, 255, 255)))
    host.apply(.image, imageAsset: asset, imageScaling: .fit)
    host.layoutSubtreeIfNeeded()
    let imageView = try XCTUnwrap(host.imageView)
    let firstRect = imageView.imageDestinationRect
    let resizeInvalidationCount = imageView.resizeInvalidationCount

    host.setFrameSize(NSSize(width: 300, height: 300))
    host.layoutSubtreeIfNeeded()

    XCTAssertTrue(host.imageView === imageView)
    XCTAssertEqual(imageView.configurationApplyCount, 1)
    XCTAssertNotEqual(imageView.imageDestinationRect, firstRect)
    XCTAssertEqual(imageView.imageDestinationRect, CGRect(x: 0, y: 0, width: 300, height: 300))
    XCTAssertGreaterThan(imageView.resizeInvalidationCount, resizeInvalidationCount)
  }

  func testFitLetterboxAndTransparentPixelsRenderOpaqueBlack() throws {
    let opaqueRed = makeAsset(
      image: makeSolidImage(width: 2, height: 2, color: (255, 0, 0, 255)))
    let fitView = TerminalBackgroundImageView(frame: NSRect(x: 0, y: 0, width: 6, height: 2))
    fitView.configure(asset: opaqueRed, scaling: .fit)
    let fitBitmap = try render(fitView)

    assertColor(fitBitmap.colorAt(x: 0, y: 1), equals: (0, 0, 0, 255))
    assertColor(fitBitmap.colorAt(x: 3, y: 1), equals: (255, 0, 0, 255))
    assertColor(fitBitmap.colorAt(x: 5, y: 1), equals: (0, 0, 0, 255))

    let transparentRed = makeAsset(
      image: makeSolidImage(width: 1, height: 1, color: (255, 0, 0, 0)))
    let alphaView = TerminalBackgroundImageView(frame: NSRect(x: 0, y: 0, width: 2, height: 2))
    alphaView.configure(asset: transparentRed, scaling: .stretch)
    let alphaBitmap = try render(alphaView)

    assertColor(alphaBitmap.colorAt(x: 1, y: 1), equals: (0, 0, 0, 255))
  }

  private func makeAsset(image: CGImage) -> TerminalResolvedBackgroundImage {
    TerminalResolvedBackgroundImage(
      managedImage: TerminalManagedBackgroundImage(
        identifier: "image-test.png", displayName: "test.png")!,
      fileURL: URL(fileURLWithPath: "/managed/image-test.png"),
      image: image)
  }

  private func makeSolidImage(
    width: Int,
    height: Int,
    color: (UInt8, UInt8, UInt8, UInt8)
  ) -> CGImage {
    let bytes = Array(repeating: [color.0, color.1, color.2, color.3], count: width * height)
      .flatMap { $0 }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent)!
  }

  private func render(_ view: TerminalBackgroundImageView) throws -> NSBitmapImageRep {
    let width = Int(view.bounds.width)
    let height = Int(view.bounds.height)
    let bitmap = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: width * 4,
        bitsPerPixel: 32))
    let graphicsContext = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    view.draw(view.bounds)
    graphicsContext.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
  }

  private func assertColor(
    _ color: NSColor?,
    equals expected: (CGFloat, CGFloat, CGFloat, CGFloat),
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard let color = color?.usingColorSpace(.deviceRGB) else {
      XCTFail("Missing device RGB color", file: file, line: line)
      return
    }
    XCTAssertEqual(color.redComponent * 255, expected.0, accuracy: 1, file: file, line: line)
    XCTAssertEqual(color.greenComponent * 255, expected.1, accuracy: 1, file: file, line: line)
    XCTAssertEqual(color.blueComponent * 255, expected.2, accuracy: 1, file: file, line: line)
    XCTAssertEqual(color.alphaComponent * 255, expected.3, accuracy: 1, file: file, line: line)
  }
}

@MainActor
final class TerminalBackgroundImageScalingTests: XCTestCase {
  func testPortraitAndLandscapeGeometryIsCenteredForFillFitAndStretch() {
    let bounds = CGRect(x: 10, y: 20, width: 200, height: 100)

    XCTAssertEqual(
      TerminalBackgroundImageView.destinationRect(
        imageSize: CGSize(width: 100, height: 100), in: bounds, scaling: .fill),
      CGRect(x: 10, y: -30, width: 200, height: 200))
    XCTAssertEqual(
      TerminalBackgroundImageView.destinationRect(
        imageSize: CGSize(width: 100, height: 100), in: bounds, scaling: .fit),
      CGRect(x: 60, y: 20, width: 100, height: 100))
    XCTAssertEqual(
      TerminalBackgroundImageView.destinationRect(
        imageSize: CGSize(width: 100, height: 100), in: bounds, scaling: .stretch),
      bounds)

    XCTAssertEqual(
      TerminalBackgroundImageView.destinationRect(
        imageSize: CGSize(width: 400, height: 100), in: bounds, scaling: .fill),
      CGRect(x: -90, y: 20, width: 400, height: 100))
    XCTAssertEqual(
      TerminalBackgroundImageView.destinationRect(
        imageSize: CGSize(width: 400, height: 100), in: bounds, scaling: .fit),
      CGRect(x: 10, y: 45, width: 200, height: 50))
    XCTAssertEqual(
      TerminalBackgroundImageView.destinationRect(
        imageSize: CGSize(width: 400, height: 100), in: bounds, scaling: .stretch),
      bounds)
  }
}
