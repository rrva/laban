import CoreGraphics
import Foundation
import ImageIO
import LabanCore
import LabanRenderer
import Metal
import XCTest

@testable import LabanDebug

final class ChineseTransparencyTrustGateTests: XCTestCase {
  private let opacities: [Double] = [0.85, 0.90, 0.95]

  func testTrustGateTransparencySemanticsAcrossEveryRendererAndOpacity() throws {
    let fixtureURL =
      repoRoot
      .appendingPathComponent("fixtures/cjk/trust-gate.fixture.json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixtureURL.path))

    var exercised: [RendererSelection] = []
    var referenceGeometry: [CJKRunGeometry]?

    for selection in RendererSelection.allCases {
      if selection != .software, MTLCreateSystemDefaultDevice() == nil { continue }
      if !selection.isAvailableOnCurrentOS { continue }

      let artifacts = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "laban-chinese-transparency-\(selection.rawValue)-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: artifacts) }

      let runtime = try HeadlessDebugRuntime(
        fixtureURL: fixtureURL,
        artifactsURL: artifacts,
        tempURL: nil,
        deterministic: true,
        runId: "chinese-transparency-\(selection.rawValue)",
        rendererSelection: selection)
      runtime.rendererBackend.waitForFrameCompletion = true

      let render = try object(runtime.renderState())
      XCTAssertEqual(render["configuredRenderer"] as? String, selection.rawValue)
      XCTAssertEqual(
        render["effectiveRenderer"] as? String,
        selection.rawValue,
        "the trust gate must not silently accept a renderer fallback")
      XCTAssertNil(render["fallbackReason"] as? String)

      // Keep the checked-in trust-gate text intact. Add only deterministic
      // semantic cells needed to prove explicit and inverse backgrounds.
      let explicitCells =
        "\u{1B}[15;1H\u{1B}[41m  \u{1B}[0m \u{1B}[7m  \u{1B}[27m"
      XCTAssertEqual(
        runtime.applyAction(
          try JSONSerialization.data(withJSONObject: [
            "action": "feedOutput", "text": explicitCells,
          ])
        ).status,
        200)
      XCTAssertEqual(
        runtime.applyAction(
          try JSONSerialization.data(withJSONObject: [
            "action": "setPreedit", "text": "中文", "caretCells": 4,
          ])
        ).status,
        200)

      for opacity in opacities {
        let action = try JSONSerialization.data(withJSONObject: [
          "action": "setBackgroundTransparency",
          "opacity": opacity,
          "applyToExplicitCellBackgrounds": false,
        ])
        let response = runtime.applyAction(action)
        XCTAssertEqual(response.status, 200, String(data: response.body, encoding: .utf8) ?? "")

        let expectedAlpha = UInt8((opacity * 255).rounded())
        let commands = runtime.lastFrameCommands
        assertBackgroundSemantics(commands, expectedAlpha: expectedAlpha)
        assertPreeditSemantics(commands)

        let geometry = try cjkGeometry(in: commands)
        XCTAssertFalse(geometry.isEmpty)
        if let referenceGeometry {
          XCTAssertEqual(
            geometry, referenceGeometry,
            "CJK grid placement must not change with renderer or opacity")
        } else {
          referenceGeometry = geometry
        }

        let (png, _, _, _) = try runtime.screenshotBytes()
        let histogram = try alphaHistogram(png)
        let translucentPixelCount = (-1...1).reduce(0) { count, delta in
          count + histogram[Int(expectedAlpha) + delta, default: 0]
        }
        XCTAssertGreaterThan(
          translucentPixelCount, 100,
          "\(selection.rawValue) must preserve the \(expectedAlpha) canvas alpha in PNG output")
        XCTAssertGreaterThan(
          histogram[255, default: 0], 100,
          "glyph, preedit, and explicit-background pixels must remain opaque")

        if selection == .slugGlyph {
          XCTAssertGreaterThanOrEqual(
            runtime.rendererBackend.rendererStatus.rasterFallbackGlyphs ?? 0,
            2,
            "Slug must render both adjacent 中文 fallback glyphs")
        }
      }

      exercised.append(selection)
    }

    let expected = RendererSelection.allCases.filter {
      ($0 == .software || MTLCreateSystemDefaultDevice() != nil) && $0.isAvailableOnCurrentOS
    }
    XCTAssertEqual(exercised, expected)
  }

  private func assertBackgroundSemantics(
    _ commands: [FrameCommand],
    expectedAlpha: UInt8,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let terminalRects = commands.compactMap { command -> (CGRect, UInt32, FrameCompositingMode)? in
      guard case .rect(let rect, let color, .terminal, let compositing) = command else {
        return nil
      }
      return (rect, color, compositing)
    }
    XCTAssertTrue(
      terminalRects.contains { UInt8($0.1 & 0xFF) == expectedAlpha && $0.2 == .replace },
      "default/inherited backgrounds must use effective alpha and replace compositing",
      file: file,
      line: line)
    XCTAssertGreaterThanOrEqual(
      terminalRects.filter { UInt8($0.1 & 0xFF) == 255 && $0.2 == .replace }.count,
      2,
      "explicit and inverse cell backgrounds must remain opaque",
      file: file,
      line: line)
  }

  private func assertPreeditSemantics(
    _ commands: [FrameCommand],
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertTrue(
      commands.contains { command in
        guard case .rect(_, let color, .preedit, let compositing) = command else {
          return false
        }
        return UInt8(color & 0xFF) == 255 && compositing == .sourceOver
      },
      "Chinese preedit backing must stay opaque and source-over",
      file: file,
      line: line)
    XCTAssertTrue(
      commands.contains { command in
        guard case .glyphRun(_, let text, _, _, _, .preedit, _, _, _, let cells) = command else {
          return false
        }
        return text == "中文" && cells == 4
      },
      "Chinese preedit must retain its two-cells-per-Hanzi geometry",
      file: file,
      line: line)
  }

  private func cjkGeometry(in commands: [FrameCommand]) throws -> [CJKRunGeometry] {
    let runs = commands.compactMap { command -> CJKRunGeometry? in
      guard
        case .glyphRun(
          let origin, let text, _, _, _, .terminal, _, _, _, let displayCellCount) = command,
        text.contains("中文")
      else { return nil }
      return CJKRunGeometry(
        x: Double(origin.x),
        y: Double(origin.y),
        text: text,
        displayCellCount: displayCellCount ?? TerminalDisplayWidth.cells(of: text))
    }
    XCTAssertTrue(
      runs.contains { run in
        run.displayCellCount == TerminalDisplayWidth.cells(of: run.text)
          && run.displayCellCount >= 4
      }, "the trust-gate Chinese run must retain two-cell geometry")
    return runs
  }

  private func alphaHistogram(_ png: Data) throws -> [Int: Int] {
    guard
      let source = CGImageSourceCreateWithData(png as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      throw TransparencyTestError.pngDecodeFailed
    }
    var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
    guard
      let context = CGContext(
        data: &rgba,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
          | CGImageAlphaInfo.premultipliedLast.rawValue)
    else {
      throw TransparencyTestError.pngDecodeFailed
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    var result: [Int: Int] = [:]
    for index in stride(from: 3, to: rgba.count, by: 4) {
      result[Int(rgba[index]), default: 0] += 1
    }
    return result
  }

  private func object(_ response: DebugResponse) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
  }

  private var repoRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}

private struct CJKRunGeometry: Equatable {
  var x: Double
  var y: Double
  var text: String
  var displayCellCount: Int
}

private enum TransparencyTestError: Error {
  case pngDecodeFailed
}
