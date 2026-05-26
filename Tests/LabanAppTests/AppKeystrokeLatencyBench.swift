import AppKit
import Darwin
import LabanCore
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanApp

final class AppKeystrokeLatencyBench: XCTestCase {
  func testCompareLocalAndBackgroundInputToRenderedFrame() throws {
    guard ProcessInfo.processInfo.environment["LABAN_RUN_APP_LATENCY_BENCH"] == "1" else {
      return
    }

    let oldRenderer = getenv("LABAN_RENDERER").map { String(cString: $0) }
    setenv("LABAN_RENDERER", "software", 1)
    defer {
      if let oldRenderer {
        setenv("LABAN_RENDERER", oldRenderer, 1)
      } else {
        unsetenv("LABAN_RENDERER")
      }
    }

    let samples = 80
    let warmup = 10
    let local = try measureLocal(samples: samples, warmup: warmup)
    let background = try measureBackground(samples: samples, warmup: warmup)
    printSummary(local: local, background: background)

    XCTAssertEqual(local.verified, samples)
    XCTAssertEqual(background.verified, samples)
    XCTAssertLessThanOrEqual(
      background.p95,
      local.p95 + 5,
      "background input-to-render p95 should stay close to local")
  }

  private func measureLocal(samples: Int, warmup: Int) throws -> BenchReport {
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 200
    let model = try AppModel(initialSize: size) { try Self.makeCatSession(size: $0) }
    defer { model.closeAllSessions() }
    let view = makeView(model: model, size: size)
    guard let tab = model.activeTab, let session = model.session(forTab: tab.id) else {
      throw BenchError.missingSession
    }
    return try measure(
      name: "local",
      samples: samples,
      warmup: warmup,
      view: view,
      visibleText: {
        guard let snapshot = session.snapshot() else { return "" }
        defer { laban_snapshot_destroy(snapshot) }
        return TerminalSnapshotText.visibleText(
          from: UnsafePointer(snapshot),
          mode: .trimmedNonEmptyRows)
      })
  }

  private func measureBackground(samples: Int, warmup: Int) throws -> BenchReport {
    let labandURL = URL(fileURLWithPath: ".build/debug/laband")
    guard FileManager.default.isExecutableFile(atPath: labandURL.path) else {
      throw XCTSkip("laband binary is not built")
    }

    let root = URL(
      fileURLWithPath: ".tmp/app-keystroke-latency-\(UUID().uuidString.prefix(8))",
      isDirectory: true)
    let socketPath = root.appendingPathComponent("s.sock").path
    let journalURL = root.appendingPathComponent("journal", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let process = Process()
    process.executableURL = labandURL
    process.arguments = ["--socket", socketPath, "--journal", journalURL.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }

    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 200
    let model = try AppModel(initialSize: size) { try Session.fixture(size: $0) }
    let client = try Self.waitForClient(socketPath: socketPath)
    let coordinator = AppLabandSessionCoordinator(
      client: client,
      shellLaunch: ShellIntegrationLaunch(argv: ["/bin/cat"]),
      cwdByTabId: [:])
    defer { coordinator.detach() }
    let view = makeView(model: model, size: size, labandCoordinator: coordinator)
    guard let tab = model.activeTab else { throw BenchError.missingSession }
    _ = try coordinator.ensureSession(for: tab, size: size)
    coordinator.startSnapshotGenerationMonitor { _, _ in
      DispatchQueue.main.async {
        view.advanceFrame()
      }
    }
    defer { coordinator.stopSnapshotGenerationMonitor() }
    let report = try measure(
      name: "background",
      samples: samples,
      warmup: warmup,
      view: view,
      visibleText: {
        (try? coordinator.snapshot(for: tab, size: size).visibleText) ?? ""
      })

    let cleanupClient = try LabandTerminalSessionClient(socketPath: socketPath)
    _ = try? cleanupClient.terminate(sessionId: tab.id)
    _ = try? cleanupClient.shutdownWhenIdle()
    cleanupClient.close()
    process.waitUntilExit()
    return report
  }

  private func measure(
    name: String,
    samples: Int,
    warmup: Int,
    view: TerminalBitmapView,
    visibleText: () -> String
  ) throws -> BenchReport {
    let total = samples + warmup
    let letters = Array("abcdefghijklmnopqrstuvwxyz")
    var measured: [Double] = []
    measured.reserveCapacity(samples)
    var expected = ""

    view.advanceFrame()
    for index in 0..<total {
      let text = String(letters[index % letters.count])
      expected += text
      let beforeFrame = view.renderedFrameCountForTests
      let start = ContinuousClock.now
      view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
      let deadline = Date().addingTimeInterval(2)
      while Date() < deadline {
        if view.renderedFrameCountForTests > beforeFrame,
          visibleText().contains(expected)
        {
          let elapsed = ContinuousClock.now - start
          if index >= warmup {
            measured.append(Double(elapsed.components.attoseconds) / 1e15)
          }
          break
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
      }
      guard measured.count == max(0, index - warmup + 1) else {
        throw BenchError.timeout(name: name, expected: expected)
      }
    }

    return BenchReport(name: name, samples: measured, verified: measured.count)
  }

  private func makeView(
    model: AppModel,
    size: LabanTerminalSize,
    labandCoordinator: AppLabandSessionCoordinator? = nil
  ) -> TerminalBitmapView {
    let fontAtlas = FontAtlas(pointSize: 14)
    let sidebarFontAtlas = FontAtlas(pointSize: 11)
    let cellSize = fontAtlas.cellSize
    let insets = TerminalBitmapView.contentInsets
    let viewWidth =
      SidebarLayout.defaultWidth + insets.left + CGFloat(size.cols) * cellSize.width
      + insets.right
    let viewHeight = insets.top + CGFloat(size.rows) * cellSize.height + insets.bottom
    let view = TerminalBitmapView(
      model: model,
      fontAtlas: fontAtlas,
      sidebarFontAtlas: sidebarFontAtlas,
      cellWidth: Int(cellSize.width),
      cellHeight: Int(cellSize.height),
      labandCoordinator: labandCoordinator)
    view.frame = NSRect(x: 0, y: 0, width: viewWidth, height: viewHeight)
    return view
  }

  private func printSummary(local: BenchReport, background: BenchReport) {
    for report in [local, background] {
      print(
        String(
          format:
            "app-keystroke-latency %@ n=%d mean=%.2fms p50=%.2fms p95=%.2fms p99=%.2fms max=%.2fms",
          report.name,
          report.verified,
          report.mean,
          report.p50,
          report.p95,
          report.p99,
          report.max))
    }
  }

  private static func makeCatSession(size: LabanTerminalSize) throws -> Session {
    var config = LabanLaunchConfig()
    config.fixture_mode = 0
    let executable = "/bin/cat"
    let argv = ["/bin/cat"]
    return try executable.withCString { exePtr in
      try withCStringArray(argv) { argvPtr in
        config.executable = exePtr
        config.argv = argvPtr
        return try Session(config: &config, size: size)
      }
    }
  }

  private static func withCStringArray<R>(
    _ strings: [String],
    _ body: (UnsafePointer<UnsafePointer<CChar>?>) throws -> R
  ) rethrows -> R {
    let cStrings = strings.map { strdup($0) }
    defer {
      for ptr in cStrings {
        if let ptr { free(ptr) }
      }
    }
    var pointers = cStrings.map { ptr -> UnsafePointer<CChar>? in
      guard let ptr else { return nil }
      return UnsafePointer(ptr)
    }
    pointers.append(nil)
    return try pointers.withUnsafeBufferPointer { buffer in
      try body(buffer.baseAddress!)
    }
  }

  private static func waitForClient(socketPath: String) throws -> LabandTerminalSessionClient {
    let deadline = Date().addingTimeInterval(5)
    var lastError: Error?
    while Date() < deadline {
      do {
        let client = try LabandTerminalSessionClient(socketPath: socketPath)
        _ = try client.hello()
        return client
      } catch {
        lastError = error
        usleep(10_000)
      }
    }
    throw lastError ?? BenchError.missingSession
  }
}

private struct BenchReport {
  var name: String
  var samples: [Double]
  var verified: Int

  var mean: Double {
    samples.reduce(0, +) / Double(Swift.max(samples.count, 1))
  }

  var p50: Double { percentile(0.50) }
  var p95: Double { percentile(0.95) }
  var p99: Double { percentile(0.99) }
  var max: Double { samples.max() ?? 0 }

  private func percentile(_ q: Double) -> Double {
    guard !samples.isEmpty else { return 0 }
    let sorted = samples.sorted()
    let index = min(sorted.count - 1, Int(Double(sorted.count - 1) * q))
    return sorted[index]
  }
}

private enum BenchError: Error {
  case missingSession
  case timeout(name: String, expected: String)
}
