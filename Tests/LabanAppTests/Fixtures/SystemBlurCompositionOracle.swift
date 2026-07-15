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
  var schemaVersion = 2
  var directSourceCorrelation: Double
  var blurSourceCorrelation: Double
  var directSourceAmplitude: Double
  var blurSourceAmplitude: Double
  var directEdgeEnergy: Double
  var blurEdgeEnergy: Double
  var directNormalizedEdgeSharpness: Double
  var blurNormalizedEdgeSharpness: Double
  var blurToDirectNormalizedEdgeRatio: Double
  var terminalSampleWidth: Int
  var terminalSampleHeight: Int
  var passed: Bool
  var failures: [String]
}

private struct CaptureMetadata: Codable, Equatable {
  var schemaVersion = 1
  var captureKind = "fullDisplayCroppedInMemory"
  var sampleOriginXPoints: Double
  var sampleOriginYPoints: Double
  var captureScale: Double
  var terminalSampleWidth: Int
  var terminalSampleHeight: Int
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
private func captureFullDisplay(to path: String, labanPID: pid_t) {
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

  guard let screen = NSScreen.main, screen.frame.origin == .zero else {
    fail("the main screen must have a zero origin for deterministic capture")
  }
  let scaleX = Double(image.width) / screen.frame.width
  let scaleY = Double(image.height) / screen.frame.height
  guard abs(scaleX - scaleY) < 0.01, scaleX >= 1 else {
    fail("full-display capture dimensions do not match the main screen")
  }
  let window = labanWindowBounds(pid: labanPID)
  let sampleMinX = Int(((window.minX + 220) * scaleX).rounded(.up))
  let sampleMaxX = Int(((window.maxX - 30) * scaleX).rounded(.down))
  let sampleMinY = Int(((window.minY + 90) * scaleY).rounded(.up))
  let sampleMaxY = Int(((window.maxY - 60) * scaleY).rounded(.down))
  let cropRect = CGRect(
    x: sampleMinX,
    y: sampleMinY,
    width: sampleMaxX - sampleMinX,
    height: sampleMaxY - sampleMinY)
  guard cropRect.minX >= 0, cropRect.minY >= 0,
    cropRect.maxX <= CGFloat(image.width), cropRect.maxY <= CGFloat(image.height),
    cropRect.width >= 320, cropRect.height >= 100,
    let cropped = image.cropping(to: cropRect)
  else { fail("live Laban window does not provide a valid terminal crop") }

  // The complete display exists only in this process's memory. Persist only
  // the deterministic terminal crop so unrelated desktop content cannot enter
  // the evidence bundle.
  let bitmap = NSBitmapImageRep(cgImage: cropped)
  guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fail("could not encode the in-memory terminal crop")
  }
  do {
    try png.write(to: URL(fileURLWithPath: path), options: .atomic)
  } catch {
    fail("could not write the in-memory terminal crop: \(error)")
  }
  let metadata = CaptureMetadata(
    sampleOriginXPoints: Double(sampleMinX) / scaleX,
    sampleOriginYPoints: Double(sampleMinY) / scaleY,
    captureScale: scaleX,
    terminalSampleWidth: cropped.width,
    terminalSampleHeight: cropped.height)
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  FileHandle.standardOutput.write(try! encoder.encode(metadata))
  FileHandle.standardOutput.write(Data("\n".utf8))
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

private func sourceAmplitude(_ values: [Double], _ expected: [Double]) -> Double {
  var lowSum = 0.0
  var lowCount = 0
  var highSum = 0.0
  var highCount = 0
  for (value, target) in zip(values, expected) {
    if target < 0.5 {
      lowSum += value
      lowCount += 1
    } else {
      highSum += value
      highCount += 1
    }
  }
  guard lowCount > 0, highCount > 0 else { return 0 }
  return abs(highSum / Double(highCount) - lowSum / Double(lowCount))
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

private func evaluate(
  directProfile: [Double],
  blurProfile: [Double],
  expected: [Double],
  captureScale: Double,
  sampleOriginX: Int,
  stripeWidthPoints: Double
) -> Analysis {
  let directCorrelation = correlation(directProfile, expected)
  let blurCorrelation = correlation(blurProfile, expected)
  let directAmplitude = sourceAmplitude(directProfile, expected)
  let blurAmplitude = sourceAmplitude(blurProfile, expected)
  let directEdges = edgeEnergy(
    profile: directProfile,
    captureScale: captureScale,
    sampleOriginX: sampleOriginX,
    stripeWidthPoints: stripeWidthPoints)
  let blurEdges = edgeEnergy(
    profile: blurProfile,
    captureScale: captureScale,
    sampleOriginX: sampleOriginX,
    stripeWidthPoints: stripeWidthPoints)
  let directSharpness = directAmplitude > 0 ? directEdges / directAmplitude : .infinity
  let blurSharpness = blurAmplitude > 0 ? blurEdges / blurAmplitude : .infinity
  let normalizedRatio = directSharpness > 0 ? blurSharpness / directSharpness : .infinity

  var failures: [String] = []
  if directCorrelation < 0.50 {
    failures.append(
      String(format: "direct source correlation %.3f is below 0.50", directCorrelation))
  }
  if blurCorrelation < 0.10 {
    failures.append(String(format: "blur source correlation %.3f is below 0.10", blurCorrelation))
  }
  if directAmplitude < 20 {
    failures.append(String(format: "direct source amplitude %.3f is below 20.0", directAmplitude))
  }
  if blurAmplitude < 1 {
    failures.append(String(format: "blur source amplitude %.3f is below 1.0", blurAmplitude))
  }
  if directSharpness < 0.50 {
    failures.append(
      String(format: "direct normalized edge sharpness %.3f is below 0.50", directSharpness))
  }
  if normalizedRatio > 0.60 {
    failures.append(
      String(format: "blur/direct normalized edge ratio %.3f exceeds 0.60", normalizedRatio))
  }

  return Analysis(
    directSourceCorrelation: directCorrelation,
    blurSourceCorrelation: blurCorrelation,
    directSourceAmplitude: directAmplitude,
    blurSourceAmplitude: blurAmplitude,
    directEdgeEnergy: directEdges,
    blurEdgeEnergy: blurEdges,
    directNormalizedEdgeSharpness: directSharpness,
    blurNormalizedEdgeSharpness: blurSharpness,
    blurToDirectNormalizedEdgeRatio: normalizedRatio,
    terminalSampleWidth: directProfile.count,
    terminalSampleHeight: 0,
    passed: failures.isEmpty,
    failures: failures)
}

private func analyze(arguments: [String]) {
  guard arguments.count == 6,
    let sampleOriginXPoints = Double(arguments[2]),
    let captureScale = Double(arguments[3]),
    let sampleHeight = Int(arguments[4]),
    let stripeWidthPoints = Double(arguments[5]),
    sampleOriginXPoints >= 0,
    captureScale >= 1,
    sampleHeight >= 100,
    stripeWidthPoints > 0
  else {
    fail(
      "analyze expects DIRECT_CROP BLUR_CROP SAMPLE_ORIGIN_X CAPTURE_SCALE SAMPLE_HEIGHT STRIPE_WIDTH"
    )
  }

  let direct = bitmap(at: arguments[0])
  let blur = bitmap(at: arguments[1])
  guard direct.pixelsWide == blur.pixelsWide, direct.pixelsHigh == blur.pixelsHigh else {
    fail("direct and blur captures have different dimensions")
  }
  guard direct.pixelsHigh == sampleHeight,
    direct.pixelsWide >= Int(4 * stripeWidthPoints * captureScale)
  else { fail("terminal crop dimensions do not match capture metadata") }

  let xRange = 0..<direct.pixelsWide
  let yRange = 0..<direct.pixelsHigh
  let directProfile = columnProfile(direct, xRange: xRange, yRange: yRange)
  let blurProfile = columnProfile(blur, xRange: xRange, yRange: yRange)
  let expected = xRange.map { x -> Double in
    let pointX = sampleOriginXPoints + Double(x) / captureScale
    return Int(floor(pointX / stripeWidthPoints)).isMultiple(of: 2) ? 0 : 1
  }
  var result = evaluate(
    directProfile: directProfile,
    blurProfile: blurProfile,
    expected: expected,
    captureScale: captureScale,
    sampleOriginX: Int((sampleOriginXPoints * captureScale).rounded()),
    stripeWidthPoints: stripeWidthPoints)
  result.terminalSampleHeight = direct.pixelsHigh
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  FileHandle.standardOutput.write(try! encoder.encode(result))
  FileHandle.standardOutput.write(Data("\n".utf8))
  if !result.failures.isEmpty { exit(1) }
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
  let valid = evaluate(
    directProfile: direct,
    blurProfile: blurred,
    expected: expected,
    captureScale: scale,
    sampleOriginX: 0,
    stripeWidthPoints: Double(stripeWidth))
  guard valid.passed else { fail("synthetic blur metric self-test failed") }

  // A sharp affine low-contrast copy has tiny raw edge energy but no blur.
  // Normalizing edge energy by retained source amplitude must reject it.
  let sharpTint = direct.map { 110 + 0.05 * $0 }
  let invalid = evaluate(
    directProfile: direct,
    blurProfile: sharpTint,
    expected: expected,
    captureScale: scale,
    sampleOriginX: 0,
    stripeWidthPoints: Double(stripeWidth))
  guard !invalid.passed,
    invalid.failures.contains(where: { $0.contains("normalized edge ratio") })
  else { fail("sharp low-contrast no-blur negative self-test was accepted") }
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
  guard CommandLine.arguments.count == 4,
    let pid = pid_t(CommandLine.arguments[3])
  else { fail("capture expects OUTPUT_PNG LABAN_PID") }
  if #available(macOS 14.0, *) {
    captureFullDisplay(to: CommandLine.arguments[2], labanPID: pid)
  } else {
    fail("full-display ScreenCaptureKit capture requires macOS 14 or newer")
  }
case "self-test":
  selfTest()
default:
  fail("expected backdrop, capture, analyze, or self-test")
}
