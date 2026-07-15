import AppKit
import CoreGraphics
import ScreenCaptureKit

private let stripeWidth: CGFloat = 80

private func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("system-blur-composition-oracle: \(message)\n".utf8))
  exit(1)
}

private final class StripeView: NSView {
  override var isOpaque: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    let first = Int(floor(dirtyRect.minX / stripeWidth))
    let last = Int(floor(dirtyRect.maxX / stripeWidth))
    for index in first...last {
      (index.isMultiple(of: 2) ? NSColor.black : NSColor.white).setFill()
      NSRect(
        x: CGFloat(index) * stripeWidth,
        y: dirtyRect.minY,
        width: stripeWidth,
        height: dirtyRect.height
      ).fill()
    }
  }
}

private final class BackdropDelegate: NSObject, NSApplicationDelegate {
  private var window: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard let screen = NSScreen.main else { fail("no main screen") }
    guard screen.frame.origin == .zero else {
      fail("the main screen must have a zero origin for deterministic capture")
    }
    let window = NSWindow(
      contentRect: screen.frame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false)
    window.level = .normal
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.contentView = StripeView(frame: NSRect(origin: .zero, size: screen.frame.size))
    window.orderFrontRegardless()
    self.window = window

    let ready: [String: Any] = [
      "ready": true,
      "screenWidth": screen.frame.width,
      "screenHeight": screen.frame.height,
      "stripeWidth": stripeWidth,
    ]
    let data = try! JSONSerialization.data(withJSONObject: ready, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
  }
}

private struct Analysis: Codable {
  var schemaVersion = 1
  var directSourceCorrelation: Double
  var blurSourceCorrelation: Double
  var directEdgeEnergy: Double
  var blurEdgeEnergy: Double
  var blurToDirectEdgeEnergyRatio: Double
  var windowX: Double
  var windowY: Double
  var windowWidth: Double
  var windowHeight: Double
  var terminalSampleX: Int
  var terminalSampleY: Int
  var terminalSampleWidth: Int
  var terminalSampleHeight: Int
  var passed: Bool
  var failures: [String]
}

private final class ShareableContentBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value: SCShareableContent?
  private var failure: Error?

  func set(_ content: SCShareableContent?, error: Error?) {
    lock.lock()
    value = content
    failure = error
    lock.unlock()
  }

  func get() -> (SCShareableContent?, Error?) {
    lock.lock()
    defer { lock.unlock() }
    return (value, failure)
  }
}

private final class CaptureBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value: CGImage?
  private var failure: Error?

  func set(_ image: CGImage?, error: Error?) {
    lock.lock()
    value = image
    failure = error
    lock.unlock()
  }

  func get() -> (CGImage?, Error?) {
    lock.lock()
    defer { lock.unlock() }
    return (value, failure)
  }
}

/// Capture the complete main display through a display content filter. A
/// window-only ScreenCaptureKit filter suppresses behind-window composition,
/// so substituting an app/window screenshot would invalidate this oracle.
@available(macOS 14.0, *)
private func captureFullDisplay(to path: String) {
  guard CGPreflightScreenCaptureAccess() else {
    fail("Screen Recording access is required for full-display capture")
  }

  let shareableBox = ShareableContentBox()
  let shareableSemaphore = DispatchSemaphore(value: 0)
  SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) {
    content, error in
    shareableBox.set(content, error: error)
    shareableSemaphore.signal()
  }
  guard shareableSemaphore.wait(timeout: .now() + 10) == .success else {
    fail("timed out enumerating full-display capture content")
  }
  let (content, contentError) = shareableBox.get()
  guard contentError == nil, let content else {
    fail("could not enumerate full-display capture content: \(String(describing: contentError))")
  }
  guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
    fail("main display is absent from ScreenCaptureKit shareable content")
  }

  let filter = SCContentFilter(display: display, excludingWindows: [])
  let configuration = SCStreamConfiguration()
  configuration.width = display.width
  configuration.height = display.height
  configuration.showsCursor = false

  let captureBox = CaptureBox()
  let captureSemaphore = DispatchSemaphore(value: 0)
  SCScreenshotManager.captureImage(
    contentFilter: filter,
    configuration: configuration
  ) { image, error in
    captureBox.set(image, error: error)
    captureSemaphore.signal()
  }
  guard captureSemaphore.wait(timeout: .now() + 10) == .success else {
    fail("timed out capturing the full main display")
  }
  let (image, captureError) = captureBox.get()
  guard captureError == nil, let image else {
    fail("full-display ScreenCaptureKit capture failed: \(String(describing: captureError))")
  }
  let bitmap = NSBitmapImageRep(cgImage: image)
  guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fail("could not encode the full-display capture")
  }
  do {
    try png.write(to: URL(fileURLWithPath: path), options: .atomic)
  } catch {
    fail("could not write the full-display capture: \(error)")
  }
}

private func labanWindowBounds(pid: pid_t) -> CGRect {
  guard
    let records = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
  else { fail("could not enumerate on-screen windows") }

  let candidates: [CGRect] = records.compactMap { record in
    guard (record[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
      (record[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
      let dictionary = record[kCGWindowBounds as String] as? NSDictionary,
      let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
      bounds.width >= 400,
      bounds.height >= 300
    else { return nil }
    return bounds
  }
  guard let bounds = candidates.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
    fail("could not locate the live Laban terminal window")
  }
  return bounds
}

private func bitmap(at path: String) -> NSBitmapImageRep {
  guard let image = NSImage(contentsOfFile: path),
    let data = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: data)
  else { fail("could not decode \(path)") }
  return bitmap
}

private func luma(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> Double {
  guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
    fail("could not read capture pixel at \(x),\(y)")
  }
  return 0.2126 * color.redComponent * 255
    + 0.7152 * color.greenComponent * 255
    + 0.0722 * color.blueComponent * 255
}

private func columnProfile(
  _ bitmap: NSBitmapImageRep,
  xRange: Range<Int>,
  yRange: Range<Int>
) -> [Double] {
  let yStride = max(1, yRange.count / 160)
  return xRange.map { x in
    var sum = 0.0
    var count = 0
    for y in Swift.stride(from: yRange.lowerBound, to: yRange.upperBound, by: yStride) {
      sum += luma(bitmap, x: x, y: y)
      count += 1
    }
    return sum / Double(count)
  }
}

private func correlation(_ values: [Double], _ expected: [Double]) -> Double {
  precondition(values.count == expected.count && !values.isEmpty)
  let meanValues = values.reduce(0, +) / Double(values.count)
  let meanExpected = expected.reduce(0, +) / Double(expected.count)
  var numerator = 0.0
  var valuesEnergy = 0.0
  var expectedEnergy = 0.0
  for (value, target) in zip(values, expected) {
    let a = value - meanValues
    let b = target - meanExpected
    numerator += a * b
    valuesEnergy += a * a
    expectedEnergy += b * b
  }
  guard valuesEnergy > 0, expectedEnergy > 0 else { return 0 }
  return numerator / sqrt(valuesEnergy * expectedEnergy)
}

private func edgeEnergy(
  profile: [Double],
  captureScale: Double,
  sampleOriginX: Int,
  stripeWidthPoints: Double
) -> Double {
  let firstScreenX = Double(sampleOriginX) / captureScale
  let lastScreenX = Double(sampleOriginX + profile.count - 1) / captureScale
  let firstBoundary = Int(floor(firstScreenX / stripeWidthPoints)) + 1
  let lastBoundary = Int(floor(lastScreenX / stripeWidthPoints))
  guard firstBoundary <= lastBoundary else { return 0 }

  let radius = max(2, Int((captureScale * 6).rounded()))
  var maxima: [Double] = []
  for boundary in firstBoundary...lastBoundary {
    let screenX = Double(boundary) * stripeWidthPoints
    let local = Int((screenX * captureScale).rounded()) - sampleOriginX
    let lower = max(1, local - radius)
    let upper = min(profile.count - 1, local + radius)
    guard lower <= upper else { continue }
    maxima.append((lower...upper).map { abs(profile[$0] - profile[$0 - 1]) }.max() ?? 0)
  }
  return maxima.reduce(0, +) / Double(maxima.count)
}

private func analyze(arguments: [String]) {
  guard arguments.count == 6,
    let pid = pid_t(arguments[2]),
    let screenWidth = Double(arguments[3]),
    let screenHeight = Double(arguments[4]),
    let stripeWidthPoints = Double(arguments[5]),
    screenWidth > 0,
    screenHeight > 0,
    stripeWidthPoints > 0
  else {
    fail("analyze expects DIRECT_PNG BLUR_PNG PID SCREEN_WIDTH SCREEN_HEIGHT STRIPE_WIDTH")
  }

  let direct = bitmap(at: arguments[0])
  let blur = bitmap(at: arguments[1])
  guard direct.pixelsWide == blur.pixelsWide, direct.pixelsHigh == blur.pixelsHigh else {
    fail("direct and blur captures have different dimensions")
  }
  let scaleX = Double(direct.pixelsWide) / screenWidth
  let scaleY = Double(direct.pixelsHigh) / screenHeight
  guard abs(scaleX - scaleY) < 0.01, scaleX >= 1 else {
    fail("capture dimensions do not match the main screen")
  }

  let window = labanWindowBounds(pid: pid)
  let sampleMinX = Int(((window.minX + 220) * scaleX).rounded(.up))
  let sampleMaxX = Int(((window.maxX - 30) * scaleX).rounded(.down))
  let sampleMinY = Int(((window.minY + 90) * scaleY).rounded(.up))
  let sampleMaxY = Int(((window.maxY - 60) * scaleY).rounded(.down))
  guard sampleMinX >= 0, sampleMinY >= 0,
    sampleMaxX <= direct.pixelsWide, sampleMaxY <= direct.pixelsHigh,
    sampleMaxX - sampleMinX >= Int(4 * stripeWidthPoints * scaleX),
    sampleMaxY - sampleMinY >= 100
  else { fail("live Laban window does not provide a valid terminal sample rectangle") }

  let xRange = sampleMinX..<sampleMaxX
  let yRange = sampleMinY..<sampleMaxY
  let directProfile = columnProfile(direct, xRange: xRange, yRange: yRange)
  let blurProfile = columnProfile(blur, xRange: xRange, yRange: yRange)
  let expected = xRange.map { x -> Double in
    let pointX = Double(x) / scaleX
    return Int(floor(pointX / stripeWidthPoints)).isMultiple(of: 2) ? 0 : 1
  }
  let directCorrelation = correlation(directProfile, expected)
  let blurCorrelation = correlation(blurProfile, expected)
  let directEdges = edgeEnergy(
    profile: directProfile,
    captureScale: scaleX,
    sampleOriginX: sampleMinX,
    stripeWidthPoints: stripeWidthPoints)
  let blurEdges = edgeEnergy(
    profile: blurProfile,
    captureScale: scaleX,
    sampleOriginX: sampleMinX,
    stripeWidthPoints: stripeWidthPoints)
  let ratio = directEdges > 0 ? blurEdges / directEdges : .infinity

  var failures: [String] = []
  if directCorrelation < 0.50 {
    failures.append(
      String(format: "direct source correlation %.3f is below 0.50", directCorrelation))
  }
  if blurCorrelation < 0.10 {
    failures.append(String(format: "blur source correlation %.3f is below 0.10", blurCorrelation))
  }
  if directEdges < 5 {
    failures.append(String(format: "direct edge energy %.3f is below 5.0", directEdges))
  }
  if ratio > 0.85 {
    failures.append(String(format: "blur/direct edge-energy ratio %.3f exceeds 0.85", ratio))
  }

  let result = Analysis(
    directSourceCorrelation: directCorrelation,
    blurSourceCorrelation: blurCorrelation,
    directEdgeEnergy: directEdges,
    blurEdgeEnergy: blurEdges,
    blurToDirectEdgeEnergyRatio: ratio,
    windowX: window.minX,
    windowY: window.minY,
    windowWidth: window.width,
    windowHeight: window.height,
    terminalSampleX: sampleMinX,
    terminalSampleY: sampleMinY,
    terminalSampleWidth: sampleMaxX - sampleMinX,
    terminalSampleHeight: sampleMaxY - sampleMinY,
    passed: failures.isEmpty,
    failures: failures)
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  FileHandle.standardOutput.write(try! encoder.encode(result))
  FileHandle.standardOutput.write(Data("\n".utf8))
  if !failures.isEmpty { exit(1) }
}

private func selfTest() {
  let scale = 1.0
  let width = 640
  let direct = (0..<width).map { index in
    Int(floor(Double(index) / Double(stripeWidth))).isMultiple(of: 2) ? 20.0 : 220.0
  }
  var blurred = direct
  for index in 8..<(width - 8) {
    blurred[index] = direct[(index - 8)...(index + 8)].reduce(0, +) / 17
  }
  let expected = (0..<width).map { index in
    Int(floor(Double(index) / Double(stripeWidth))).isMultiple(of: 2) ? 0.0 : 1.0
  }
  let directCorrelation = correlation(direct, expected)
  let blurCorrelation = correlation(blurred, expected)
  let directEdges = edgeEnergy(
    profile: direct, captureScale: scale, sampleOriginX: 0,
    stripeWidthPoints: Double(stripeWidth))
  let blurEdges = edgeEnergy(
    profile: blurred, captureScale: scale, sampleOriginX: 0,
    stripeWidthPoints: Double(stripeWidth))
  guard directCorrelation > 0.99, blurCorrelation > 0.90,
    directEdges > 100, blurEdges / directEdges < 0.20
  else { fail("synthetic metric self-test failed") }
  print("system-blur-composition-oracle: self-test passed")
}

switch CommandLine.arguments.dropFirst().first {
case "backdrop":
  let app = NSApplication.shared
  app.setActivationPolicy(.accessory)
  let delegate = BackdropDelegate()
  app.delegate = delegate
  app.run()
case "analyze":
  analyze(arguments: Array(CommandLine.arguments.dropFirst(2)))
case "capture":
  guard CommandLine.arguments.count == 3 else { fail("capture expects OUTPUT_PNG") }
  if #available(macOS 14.0, *) {
    captureFullDisplay(to: CommandLine.arguments[2])
  } else {
    fail("full-display ScreenCaptureKit capture requires macOS 14 or newer")
  }
case "self-test":
  selfTest()
default:
  fail("expected backdrop, capture, analyze, or self-test")
}
