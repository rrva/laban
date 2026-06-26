import CoreGraphics
import Foundation
import ImageIO
import Metal
import XCTest

@testable import LabanRenderer

final class RendererFidelityReportTests: XCTestCase {
  private let environmentKey = "LABAN_RENDERER_FIDELITY_ARTIFACTS"
  private let pixelWidth = 920
  private let pixelHeight = 228
  private let scale: CGFloat = 2
  private let pointSize: CGFloat = 18
  private let background = RGB(r: 0xF6, g: 0xEE, b: 0xDB)
  private let foreground = RGB(r: 0x18, g: 0x22, b: 0x2A)
  private let vectorConvergenceFrames = 130
  private let lineSpacing: CGFloat = 24
  private let firstBaselineY: CGFloat = 16
  private let firstBaselineX: CGFloat = 12
  private let probeLines = [
    "illili |||| HHHH WWWM",
    "0123456789 abcdef ABCDEF",
    "Subpixel AA: rgb stripe test",
    "sharp stems: nmw I1l |",
  ]

  override func tearDown() {
    MetalRenderer.useGPUCellPath = false
    super.tearDown()
  }

  func testWritesCalibrationArtifact() throws {
    guard let artifactPath = ProcessInfo.processInfo.environment[environmentKey],
      !artifactPath.isEmpty
    else {
      throw XCTSkip("set \(environmentKey) to write renderer calibration artifacts")
    }
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device available")
    }

    let root = URL(fileURLWithPath: artifactPath, isDirectory: true)
    let imageRoot = root.appendingPathComponent("images", isDirectory: true)
    let diffRoot = root.appendingPathComponent("diffs", isDirectory: true)
    try FileManager.default.createDirectory(at: imageRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: diffRoot, withIntermediateDirectories: true)

    let crop = CGRect(x: 24, y: 18, width: 872, height: 188)
    let variants = try renderVariants(imageRoot: imageRoot, crop: crop)
    XCTAssertGreaterThanOrEqual(variants.count, 8, "calibration must render all comparators")

    var pairReports: [PairReport] = []
    let pairLabels = [
      ("classic-vs-gpuDriven", "metal-classic", "metal-gpuDriven"),
      ("classic-vs-vector-grayscale", "metal-classic", "vector-grayscale"),
      ("classic-vs-vector-rgbStripe", "metal-classic", "vector-rgbStripe"),
      ("gpuDriven-vs-vector-grayscale", "metal-gpuDriven", "vector-grayscale"),
      ("gpuDriven-vs-vector-rgbStripe", "metal-gpuDriven", "vector-rgbStripe"),
      ("vector-grayscale-vs-rgbStripe", "vector-grayscale", "vector-rgbStripe"),
      ("vector-rgbStripe-vs-bgrStripe", "vector-rgbStripe", "vector-bgrStripe"),
      ("vector-rgbQuarter-vs-rgbStripe", "vector-rgbQuarter", "vector-rgbStripe"),
      ("vector-rgbStripe-vs-rgbHalf", "vector-rgbStripe", "vector-rgbHalf"),
    ]
    for (label, lhsLabel, rhsLabel) in pairLabels {
      guard
        let lhs = variants.first(where: { $0.label == lhsLabel }),
        let rhs = variants.first(where: { $0.label == rhsLabel })
      else { continue }
      let diffURL = diffRoot.appendingPathComponent("\(label).png")
      let diffPNG = try diffPNG(lhs: lhs.image, rhs: rhs.image)
      try diffPNG.write(to: diffURL)
      pairReports.append(
        PairReport(
          label: label,
          lhs: lhsLabel,
          rhs: rhsLabel,
          diffPath: relativePath(diffURL, root: root),
          metrics: pairMetrics(lhs: lhs.image, rhs: rhs.image, crop: crop)))
    }

    let fractional = [
      fractionalStability(prefix: "vector-grayscale", variants: variants),
      fractionalStability(prefix: "vector-rgbStripe", variants: variants),
    ]

    let report = FidelityReport(
      version: 1,
      generatedAt: ISO8601DateFormatter().string(from: Date()),
      gitCommit: gitCommit(),
      host: HostReport(
        osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        metalDevice: device.name),
      probe: ProbeReport(
        pointSize: Double(pointSize),
        scale: Double(scale),
        surfacePx: SizeReport(width: pixelWidth, height: pixelHeight),
        cropPx: RectReport(crop),
        backgroundRGB: background.hex,
        foregroundRGB: foreground.hex,
        vectorConvergenceFrames: vectorConvergenceFrames,
        note:
          "Comparators are evidence, not golden masters. Higher gradient and lower edge spread indicate acuity; higher RGB coverage spread indicates color fringing."
      ),
      variants: variants.map { $0.report(relativeTo: root) },
      pairs: pairReports,
      fractionalStability: fractional)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(report)
      .write(to: root.appendingPathComponent("renderer-fidelity-report.json"))
    try markdown(report: report)
      .write(
        to: root.appendingPathComponent("renderer-fidelity-report.md"),
        atomically: true,
        encoding: .utf8)
  }

  private func renderVariants(
    imageRoot: URL,
    crop: CGRect
  ) throws -> [RenderedVariant] {
    let atlas = FontAtlas(pointSize: pointSize)
    var variants: [RenderedVariant] = []

    let baseCommands = probeCommands(xShiftPoints: 0)
    let gpuPayload = gpuCellPayload(atlas: atlas, xShiftPoints: 0)
    variants.append(
      try renderMetal(
        label: "metal-classic",
        atlas: atlas,
        commands: baseCommands,
        gpuDriven: false,
        imageRoot: imageRoot,
        crop: crop))
    variants.append(
      try renderMetal(
        label: "metal-gpuDriven",
        atlas: atlas,
        commands: baseCommands,
        gpuDriven: true,
        cellPayload: gpuPayload,
        imageRoot: imageRoot,
        crop: crop))

    let layouts: [(label: String, layout: VectorSubpixelLayout)] = [
      ("vector-grayscale", .grayscale),
      (
        "vector-rgbQuarter",
        VectorSubpixelLayout(name: "rgbQuarter", offsets: SIMD3(-0.25, 0, 0.25))
      ),
      ("vector-rgbStripe", .rgbStripe),
      ("vector-rgbHalf", VectorSubpixelLayout(name: "rgbHalf", offsets: SIMD3(-0.5, 0, 0.5))),
      ("vector-bgrStripe", .bgrStripe),
    ]
    for (label, layout) in layouts {
      variants.append(
        try renderVector(
          label: label,
          layout: layout,
          atlas: atlas,
          commands: baseCommands,
          xShiftPixels: 0,
          imageRoot: imageRoot,
          crop: crop))
    }

    let shiftedLayouts: [(prefix: String, layout: VectorSubpixelLayout)] = [
      ("vector-grayscale", .grayscale),
      ("vector-rgbStripe", .rgbStripe),
    ]
    for (prefix, layout) in shiftedLayouts {
      for shiftPixels in [0.25, 0.50, 0.75] {
        let commands = probeCommands(xShiftPoints: CGFloat(shiftPixels) / scale)
        variants.append(
          try renderVector(
            label: "\(prefix)-shift-\(shiftLabel(shiftPixels))px",
            layout: layout,
            atlas: atlas,
            commands: commands,
            xShiftPixels: shiftPixels,
            imageRoot: imageRoot,
            crop: crop))
      }
    }

    return variants
  }

  private func renderMetal(
    label: String,
    atlas: FontAtlas,
    commands: [FrameCommand],
    gpuDriven: Bool,
    cellPayload: TerminalCellPayload? = nil,
    imageRoot: URL,
    crop: CGRect
  ) throws -> RenderedVariant {
    let previous = MetalRenderer.useGPUCellPath
    MetalRenderer.useGPUCellPath = gpuDriven
    defer { MetalRenderer.useGPUCellPath = previous }

    let renderer = try XCTUnwrap(
      MetalRenderer(
        fontAtlas: atlas,
        sidebarFontAtlas: atlas,
        scale: scale,
        rendererMode: gpuDriven ? .gpuDriven : .classic),
      "\(label): MetalRenderer.init returned nil")
    renderer.captureMode = true
    renderer.waitForFrameCompletion = true
    renderer.resize(pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: scale)
    XCTAssertTrue(
      renderer.render(commands, cellPayload: cellPayload, damage: .full),
      "\(label): render failed")
    renderer.waitForLastFrame()
    let png = try XCTUnwrap(renderer.pngData, "\(label): renderer did not produce pngData")
    let image = try decodeRGBA(png)
    let url = imageRoot.appendingPathComponent("\(label).png")
    try png.write(to: url)
    return RenderedVariant(
      label: label,
      rendererKind: gpuDriven ? "metal-gpuDriven-requested" : "metal-classic",
      subpixelLayout: nil,
      xShiftPixels: 0,
      status: renderer.rendererStatus,
      instanceCounts: InstanceCounts(renderer.lastInstanceCounts),
      imagePath: url,
      image: image,
      metrics: textMetrics(image: image, crop: crop))
  }

  private func renderVector(
    label: String,
    layout: VectorSubpixelLayout,
    atlas: FontAtlas,
    commands: [FrameCommand],
    xShiftPixels: Double,
    imageRoot: URL,
    crop: CGRect
  ) throws -> RenderedVariant {
    let renderer = try XCTUnwrap(
      VectorGlyphRenderer(
        fontAtlas: atlas,
        sidebarFontAtlas: atlas,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        scale: scale),
      "\(label): VectorGlyphRenderer.init returned nil")
    renderer.setSubpixelLayout(layout)
    for frame in 0..<vectorConvergenceFrames {
      XCTAssertTrue(renderer.render(commands, damage: .full), "\(label): frame \(frame) failed")
    }
    let png = try XCTUnwrap(renderer.pngData, "\(label): renderer did not produce pngData")
    let image = try decodeRGBA(png)
    let url = imageRoot.appendingPathComponent("\(label).png")
    try png.write(to: url)
    return RenderedVariant(
      label: label,
      rendererKind: "vectorGlyph",
      subpixelLayout: layout.name,
      xShiftPixels: xShiftPixels,
      status: renderer.rendererStatus,
      instanceCounts: nil,
      imagePath: url,
      image: image,
      metrics: textMetrics(image: image, crop: crop))
  }

  private func probeCommands(xShiftPoints: CGFloat) -> [FrameCommand] {
    let widthPt = CGFloat(pixelWidth) / scale
    let heightPt = CGFloat(pixelHeight) / scale
    let x = firstBaselineX + xShiftPoints
    var commands: [FrameCommand] = [
      .rect(
        CGRect(x: 0, y: 0, width: widthPt, height: heightPt),
        color: 0xF6_EE_DB_FF,
        source: .terminal)
    ]
    for (lineIndex, line) in probeLines.enumerated() {
      commands.append(
        .glyphRun(
          origin: CGPoint(x: x, y: firstBaselineY + CGFloat(lineIndex) * lineSpacing),
          text: line,
          foreground: 0x18_22_2A_FF,
          background: 0xF6_EE_DB_FF,
          attributes: [],
          source: .terminal))
    }
    return commands
  }

  private func gpuCellPayload(atlas: FontAtlas, xShiftPoints: CGFloat) -> TerminalCellPayload {
    let rows = probeLines.count
    let cols = probeLines.map(\.count).max() ?? 0
    var payload = TerminalCellPayload(
      rows: rows,
      cols: cols,
      origin: CGPoint(x: firstBaselineX + xShiftPoints, y: firstBaselineY),
      cellSize: CGSize(width: atlas.cellSize.width, height: lineSpacing),
      contentYOffset: 0,
      defaultBackground: 0xF6_EE_DB_FF,
      dirtyRows: Array(0..<rows))
    for lineIndex in probeLines.indices {
      let payloadRow = rows - 1 - lineIndex
      payload.backgroundRuns.append(
        .init(
          row: payloadRow,
          startCol: 0,
          colCount: cols,
          color: 0xF6_EE_DB_FF))
      for (col, character) in probeLines[lineIndex].enumerated()
      where character != " " {
        payload.appendGlyph(
          row: payloadRow,
          col: col,
          cluster: String(character),
          foreground: 0x18_22_2A_FF,
          background: 0xF6_EE_DB_FF,
          attributes: [])
      }
    }
    return payload
  }

  private func textMetrics(image: RGBAImage, crop: CGRect) -> TextMetrics {
    let bounds = clampedCrop(crop, image: image)
    let bgLum = luminance(background)
    let fgLum = luminance(foreground)
    let maxInk = max(1, bgLum - fgLum)
    var inkMass = 0.0
    var inkPixels = 0
    var edgePixels = 0
    var solidPixels = 0
    var gradients: [Double] = []
    var spreads: [Double] = []

    func inkAt(x: Int, y: Int) -> Double {
      let pixel = image.pixel(x: x, y: y)
      return max(0, min(maxInk, bgLum - luminance(pixel)))
    }

    for y in bounds.minY..<bounds.maxY {
      for x in bounds.minX..<bounds.maxX {
        let pixel = image.pixel(x: x, y: y)
        let ink = inkAt(x: x, y: y)
        let coverage = ink / maxInk
        inkMass += ink
        if coverage > 0.01 {
          inkPixels += 1
          let spread = coverageSpread(pixel)
          spreads.append(spread)
          if coverage < 0.85 {
            edgePixels += 1
          } else {
            solidPixels += 1
          }
        }
        if x + 1 < bounds.maxX {
          let gradient = abs(ink - inkAt(x: x + 1, y: y))
          if gradient > 1 {
            gradients.append(gradient)
          }
        }
      }
    }

    return TextMetrics(
      inkMass: inkMass,
      inkPixels: inkPixels,
      edgePixels: edgePixels,
      edgePixelRatio: inkPixels == 0 ? 0 : Double(edgePixels) / Double(inkPixels),
      solidPixelRatio: inkPixels == 0 ? 0 : Double(solidPixels) / Double(inkPixels),
      meanGradient: mean(gradients),
      p95Gradient: percentile(gradients, 0.95),
      p99Gradient: percentile(gradients, 0.99),
      meanCoverageSpread: mean(spreads),
      p95CoverageSpread: percentile(spreads, 0.95),
      p99CoverageSpread: percentile(spreads, 0.99))
  }

  private func pairMetrics(lhs: RGBAImage, rhs: RGBAImage, crop: CGRect) -> PairMetrics {
    precondition(lhs.width == rhs.width && lhs.height == rhs.height)
    let bounds = clampedCrop(crop, image: lhs)
    var channelDeltas: [Double] = []
    var changedPixelDeltas: [Double] = []
    var lumaDeltas: [Double] = []
    var changedPixels = 0

    for y in bounds.minY..<bounds.maxY {
      for x in bounds.minX..<bounds.maxX {
        let lhsPixel = lhs.pixel(x: x, y: y)
        let rhsPixel = rhs.pixel(x: x, y: y)
        let deltas = [
          abs(Double(lhsPixel.r) - Double(rhsPixel.r)),
          abs(Double(lhsPixel.g) - Double(rhsPixel.g)),
          abs(Double(lhsPixel.b) - Double(rhsPixel.b)),
        ]
        channelDeltas.append(contentsOf: deltas)
        let pixelDelta = deltas.max() ?? 0
        if pixelDelta > 0 {
          changedPixels += 1
          changedPixelDeltas.append(contentsOf: deltas)
        }
        lumaDeltas.append(abs(luminance(lhsPixel) - luminance(rhsPixel)))
      }
    }

    return PairMetrics(
      meanAbsRGB: mean(channelDeltas),
      changedMeanAbsRGB: mean(changedPixelDeltas),
      p95AbsRGB: percentile(channelDeltas, 0.95),
      p99AbsRGB: percentile(channelDeltas, 0.99),
      maxAbsRGB: channelDeltas.max() ?? 0,
      changedPixels: changedPixels,
      comparedPixels: bounds.pixelCount,
      meanAbsLuma: mean(lumaDeltas),
      p99AbsLuma: percentile(lumaDeltas, 0.99),
      lumaSSIM: lumaSSIM(lhs: lhs, rhs: rhs, bounds: bounds))
  }

  private func fractionalStability(
    prefix: String,
    variants: [RenderedVariant]
  ) -> FractionalStabilityReport {
    let samples =
      variants
      .filter { $0.label == prefix || $0.label.hasPrefix("\(prefix)-shift-") }
      .sorted { $0.xShiftPixels < $1.xShiftPixels }
    guard let base = samples.first(where: { $0.xShiftPixels == 0 }) else {
      return FractionalStabilityReport(
        rendererPrefix: prefix,
        samples: [],
        maxRelativeInkMassDelta: 0,
        maxRelativeMeanGradientDelta: 0,
        maxRelativeP99GradientDelta: 0)
    }
    let sampleReports = samples.map { sample in
      FractionalSampleReport(
        label: sample.label,
        xShiftPixels: sample.xShiftPixels,
        inkMass: sample.metrics.inkMass,
        relativeInkMassDelta: relativeDelta(sample.metrics.inkMass, base.metrics.inkMass),
        meanGradient: sample.metrics.meanGradient,
        relativeMeanGradientDelta: relativeDelta(
          sample.metrics.meanGradient,
          base.metrics.meanGradient),
        p99Gradient: sample.metrics.p99Gradient,
        relativeP99GradientDelta: relativeDelta(
          sample.metrics.p99Gradient,
          base.metrics.p99Gradient))
    }
    return FractionalStabilityReport(
      rendererPrefix: prefix,
      samples: sampleReports,
      maxRelativeInkMassDelta: sampleReports.map(\.relativeInkMassDelta).max() ?? 0,
      maxRelativeMeanGradientDelta: sampleReports.map(\.relativeMeanGradientDelta).max() ?? 0,
      maxRelativeP99GradientDelta: sampleReports.map(\.relativeP99GradientDelta).max() ?? 0)
  }

  private func coverageSpread(_ pixel: RGB) -> Double {
    let coverages = [
      channelCoverage(value: pixel.r, background: background.r, foreground: foreground.r),
      channelCoverage(value: pixel.g, background: background.g, foreground: foreground.g),
      channelCoverage(value: pixel.b, background: background.b, foreground: foreground.b),
    ]
    return (coverages.max() ?? 0) - (coverages.min() ?? 0)
  }

  private func channelCoverage(value: UInt8, background: UInt8, foreground: UInt8) -> Double {
    let range = Double(background) - Double(foreground)
    guard abs(range) > 0.0001 else { return 0 }
    return max(0, min(1, (Double(background) - Double(value)) / range))
  }

  private func lumaSSIM(lhs: RGBAImage, rhs: RGBAImage, bounds: CropBounds) -> Double {
    var lhsLuma: [Double] = []
    var rhsLuma: [Double] = []
    lhsLuma.reserveCapacity(bounds.pixelCount)
    rhsLuma.reserveCapacity(bounds.pixelCount)
    for y in bounds.minY..<bounds.maxY {
      for x in bounds.minX..<bounds.maxX {
        lhsLuma.append(luminance(lhs.pixel(x: x, y: y)))
        rhsLuma.append(luminance(rhs.pixel(x: x, y: y)))
      }
    }
    guard !lhsLuma.isEmpty, lhsLuma.count == rhsLuma.count else { return 1 }
    let lhsMean = mean(lhsLuma)
    let rhsMean = mean(rhsLuma)
    var lhsVariance = 0.0
    var rhsVariance = 0.0
    var covariance = 0.0
    for index in lhsLuma.indices {
      let lhsDelta = lhsLuma[index] - lhsMean
      let rhsDelta = rhsLuma[index] - rhsMean
      lhsVariance += lhsDelta * lhsDelta
      rhsVariance += rhsDelta * rhsDelta
      covariance += lhsDelta * rhsDelta
    }
    let n = Double(lhsLuma.count)
    lhsVariance /= n
    rhsVariance /= n
    covariance /= n
    let k1 = 0.01 * 255.0
    let k2 = 0.03 * 255.0
    let c1 = k1 * k1
    let c2 = k2 * k2
    let numerator = (2.0 * lhsMean * rhsMean + c1) * (2.0 * covariance + c2)
    let denominator =
      (lhsMean * lhsMean + rhsMean * rhsMean + c1)
      * (lhsVariance + rhsVariance + c2)
    guard denominator > 0 else { return 1 }
    return numerator / denominator
  }

  private func diffPNG(lhs: RGBAImage, rhs: RGBAImage) throws -> Data {
    guard lhs.width == rhs.width, lhs.height == rhs.height else {
      throw TestFailure("diff image dimensions differ")
    }
    var rgba = [UInt8](repeating: 0, count: lhs.width * lhs.height * 4)
    for pixel in 0..<(lhs.width * lhs.height) {
      let offset = pixel * 4
      let delta = max(
        abs(Int(lhs.bytes[offset]) - Int(rhs.bytes[offset])),
        abs(Int(lhs.bytes[offset + 1]) - Int(rhs.bytes[offset + 1])),
        abs(Int(lhs.bytes[offset + 2]) - Int(rhs.bytes[offset + 2])))
      let boosted = UInt8(min(255, delta * 4))
      rgba[offset] = boosted
      rgba[offset + 1] = boosted
      rgba[offset + 2] = boosted
      rgba[offset + 3] = 255
    }
    return try makePNG(width: lhs.width, height: lhs.height, rgba: rgba)
  }

  private func decodeRGBA(_ png: Data) throws -> RGBAImage {
    guard let source = CGImageSourceCreateWithData(png as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      throw TestFailure("failed to decode renderer PNG")
    }
    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let bitmapInfo =
      CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    bytes.withUnsafeMutableBytes { raw in
      guard
        let context = CGContext(
          data: raw.baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: bitmapInfo)
      else { return }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return RGBAImage(width: width, height: height, bytes: bytes)
  }

  private func makePNG(width: Int, height: Int, rgba: [UInt8]) throws -> Data {
    var bytes = rgba
    var image: CGImage?
    let bitmapInfo =
      CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    bytes.withUnsafeMutableBytes { raw in
      guard
        let context = CGContext(
          data: raw.baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: bitmapInfo)
      else { return }
      image = context.makeImage()
    }
    guard let image, let png = PNGEncoder.encode(image) else {
      throw TestFailure("failed to encode PNG")
    }
    return png
  }

  private func markdown(report: FidelityReport) -> String {
    var lines: [String] = []
    lines.append("# Renderer Fidelity Calibration")
    lines.append("")
    lines.append("- Generated: \(report.generatedAt)")
    lines.append("- Commit: \(report.gitCommit ?? "unknown")")
    lines.append("- Metal device: \(report.host.metalDevice)")
    lines.append(
      "- Probe: \(report.probe.surfacePx.width)x\(report.probe.surfacePx.height) px, \(format(report.probe.pointSize)) pt @ \(format(report.probe.scale))x"
    )
    lines.append("")
    lines.append(
      "The classic and GPU-driven renderers are comparators, not golden references. Use the numbers to make tradeoffs explicit: high gradients indicate edge acuity, low edge-pixel ratio indicates less blur spread, and high RGB coverage spread indicates more potential color fringing."
    )
    lines.append("")
    lines.append("## Variant Metrics")
    lines.append("")
    lines.append(
      "| Variant | Ink mass | Edge ratio | Mean grad | P99 grad | Mean RGB spread | P99 RGB spread | Image |"
    )
    lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |")
    for variant in report.variants {
      lines.append(
        "| \(variant.label) | \(format(variant.metrics.inkMass)) | \(format(variant.metrics.edgePixelRatio)) | \(format(variant.metrics.meanGradient)) | \(format(variant.metrics.p99Gradient)) | \(format(variant.metrics.meanCoverageSpread)) | \(format(variant.metrics.p99CoverageSpread)) | \(variant.imagePath) |"
      )
    }
    lines.append("")
    lines.append("## Pairwise Deltas")
    lines.append("")
    lines.append(
      "| Pair | Mean RGB | Changed mean RGB | P99 RGB | Max RGB | Changed px | Luma SSIM | Diff |")
    lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |")
    for pair in report.pairs {
      lines.append(
        "| \(pair.label) | \(format(pair.metrics.meanAbsRGB)) | \(format(pair.metrics.changedMeanAbsRGB)) | \(format(pair.metrics.p99AbsRGB)) | \(format(pair.metrics.maxAbsRGB)) | \(pair.metrics.changedPixels)/\(pair.metrics.comparedPixels) | \(format(pair.metrics.lumaSSIM)) | \(pair.diffPath) |"
      )
    }
    lines.append("")
    lines.append("## Fractional X Stability")
    lines.append("")
    lines.append("| Renderer | Max ink delta | Max mean-gradient delta | Max P99-gradient delta |")
    lines.append("| --- | ---: | ---: | ---: |")
    for stability in report.fractionalStability {
      lines.append(
        "| \(stability.rendererPrefix) | \(format(stability.maxRelativeInkMassDelta)) | \(format(stability.maxRelativeMeanGradientDelta)) | \(format(stability.maxRelativeP99GradientDelta)) |"
      )
    }
    lines.append("")
    return lines.joined(separator: "\n")
  }

  private func gitCommit() -> String? {
    guard var commit = runGit(["rev-parse", "--short", "HEAD"]) else { return nil }
    if let status = runGit(["status", "--porcelain"]), !status.isEmpty {
      commit += "+dirty"
    }
    return commit
  }

  private func runGit(_ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { return nil }
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
      return nil
    }
  }

  private func clampedCrop(_ crop: CGRect, image: RGBAImage) -> CropBounds {
    let minX = max(0, Int(floor(crop.minX)))
    let maxX = min(image.width, Int(ceil(crop.maxX)))
    let minY = max(0, Int(floor(crop.minY)))
    let maxY = min(image.height, Int(ceil(crop.maxY)))
    return CropBounds(minX: minX, maxX: maxX, minY: minY, maxY: maxY)
  }

  private func luminance(_ rgb: RGB) -> Double {
    0.2126 * Double(rgb.r) + 0.7152 * Double(rgb.g) + 0.0722 * Double(rgb.b)
  }

  private func mean(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    return values.reduce(0, +) / Double(values.count)
  }

  private func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
    return sorted[index]
  }

  private func relativeDelta(_ value: Double, _ baseline: Double) -> Double {
    guard abs(baseline) > 0.000001 else { return value == baseline ? 0 : 1 }
    return abs(value - baseline) / abs(baseline)
  }

  private func relativePath(_ url: URL, root: URL) -> String {
    let rootPath = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    if path.hasPrefix(rootPath + "/") {
      return String(path.dropFirst(rootPath.count + 1))
    }
    return path
  }

  private func shiftLabel(_ value: Double) -> String {
    String(format: "%.2f", value).replacingOccurrences(of: ".", with: "_")
  }

  private func format(_ value: Double) -> String {
    String(format: "%.4f", value)
  }

  private struct RenderedVariant {
    var label: String
    var rendererKind: String
    var subpixelLayout: String?
    var xShiftPixels: Double
    var status: RendererStatus
    var instanceCounts: InstanceCounts?
    var imagePath: URL
    var image: RGBAImage
    var metrics: TextMetrics

    func report(relativeTo root: URL) -> VariantReport {
      let rootPath = root.standardizedFileURL.path
      let path = imagePath.standardizedFileURL.path
      let relative =
        path.hasPrefix(rootPath + "/")
        ? String(path.dropFirst(rootPath.count + 1))
        : path
      return VariantReport(
        label: label,
        rendererKind: rendererKind,
        subpixelLayout: subpixelLayout,
        xShiftPixels: xShiftPixels,
        status: status,
        instanceCounts: instanceCounts,
        imagePath: relative,
        metrics: metrics)
    }
  }

  private struct RGBAImage {
    var width: Int
    var height: Int
    var bytes: [UInt8]

    func pixel(x: Int, y: Int) -> RGB {
      let offset = (y * width + x) * 4
      return RGB(r: bytes[offset], g: bytes[offset + 1], b: bytes[offset + 2])
    }
  }

  private struct RGB {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    var hex: String {
      String(format: "#%02X%02X%02X", r, g, b)
    }
  }

  private struct CropBounds {
    var minX: Int
    var maxX: Int
    var minY: Int
    var maxY: Int

    var pixelCount: Int {
      max(0, maxX - minX) * max(0, maxY - minY)
    }
  }

  private struct TestFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) {
      self.description = description
    }
  }

  private struct FidelityReport: Encodable {
    var version: Int
    var generatedAt: String
    var gitCommit: String?
    var host: HostReport
    var probe: ProbeReport
    var variants: [VariantReport]
    var pairs: [PairReport]
    var fractionalStability: [FractionalStabilityReport]
  }

  private struct HostReport: Encodable {
    var osVersion: String
    var metalDevice: String
  }

  private struct ProbeReport: Encodable {
    var pointSize: Double
    var scale: Double
    var surfacePx: SizeReport
    var cropPx: RectReport
    var backgroundRGB: String
    var foregroundRGB: String
    var vectorConvergenceFrames: Int
    var note: String
  }

  private struct SizeReport: Encodable {
    var width: Int
    var height: Int
  }

  private struct RectReport: Encodable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
      x = Double(rect.origin.x)
      y = Double(rect.origin.y)
      width = Double(rect.width)
      height = Double(rect.height)
    }
  }

  private struct VariantReport: Encodable {
    var label: String
    var rendererKind: String
    var subpixelLayout: String?
    var xShiftPixels: Double
    var status: RendererStatus
    var instanceCounts: InstanceCounts?
    var imagePath: String
    var metrics: TextMetrics
  }

  private struct InstanceCounts: Encodable {
    var solids: Int
    var glyphs: Int
    var sidebarGlyphs: Int
    var cellGlyphs: Int
    var cursors: Int

    init(_ counts: MetalRenderer.RenderInstanceCounts) {
      solids = counts.solids
      glyphs = counts.glyphs
      sidebarGlyphs = counts.sidebarGlyphs
      cellGlyphs = counts.cellGlyphs
      cursors = counts.cursors
    }
  }

  private struct TextMetrics: Encodable {
    var inkMass: Double
    var inkPixels: Int
    var edgePixels: Int
    var edgePixelRatio: Double
    var solidPixelRatio: Double
    var meanGradient: Double
    var p95Gradient: Double
    var p99Gradient: Double
    var meanCoverageSpread: Double
    var p95CoverageSpread: Double
    var p99CoverageSpread: Double
  }

  private struct PairReport: Encodable {
    var label: String
    var lhs: String
    var rhs: String
    var diffPath: String
    var metrics: PairMetrics
  }

  private struct PairMetrics: Encodable {
    var meanAbsRGB: Double
    var changedMeanAbsRGB: Double
    var p95AbsRGB: Double
    var p99AbsRGB: Double
    var maxAbsRGB: Double
    var changedPixels: Int
    var comparedPixels: Int
    var meanAbsLuma: Double
    var p99AbsLuma: Double
    var lumaSSIM: Double
  }

  private struct FractionalStabilityReport: Encodable {
    var rendererPrefix: String
    var samples: [FractionalSampleReport]
    var maxRelativeInkMassDelta: Double
    var maxRelativeMeanGradientDelta: Double
    var maxRelativeP99GradientDelta: Double
  }

  private struct FractionalSampleReport: Encodable {
    var label: String
    var xShiftPixels: Double
    var inkMass: Double
    var relativeInkMassDelta: Double
    var meanGradient: Double
    var relativeMeanGradientDelta: Double
    var p99Gradient: Double
    var relativeP99GradientDelta: Double
  }
}
