import Foundation
import XCTest

final class TerminalWidthPolicyGuardTests: XCTestCase {

  private var repoRoot: URL {
    // Resolve from test source up to repository root (directory containing `.git`).
    var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while !FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) {
      current = current.deletingLastPathComponent()
    }
    return current
  }

  func testTerminalDisplayWidthUsageIsIsolatedToDocumentedFallbackSites() throws {
    let sourcesRoot = repoRoot.appendingPathComponent("Sources")
    let allowedSites: [String: [String]] = [
      "LabanCore/FrameProducer.swift": ["TerminalDisplayWidth.cells(of:"],
      "LabanCore/TerminalFind.swift": ["TerminalDisplayWidth.cells(of:"],
      "LabanCore/TerminalSelection.swift": ["TerminalDisplayWidth.cells(of:"],
      "LabanApp/TerminalBitmapView.swift": ["TerminalDisplayWidth.cells(of:"],
      "LabanApp/TerminalSelectionInput.swift": ["TerminalDisplayWidth.isWide("],
    ]

    var matchedFiles = Set<String>()
    var observed = [(file: String, line: Int, text: String)]()

    guard
      let enumerator = FileManager.default.enumerator(
        at: sourcesRoot,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else {
      XCTFail("Failed to enumerate Sources directory at \(sourcesRoot.path)")
      return
    }

    for case let fileURL as URL in enumerator {
      guard fileURL.pathExtension == "swift" else { continue }
      let isRegularFile =
        try fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
      if !isRegularFile { continue }

      let rel = fileURL.path.replacingOccurrences(of: sourcesRoot.path + "/", with: "")
      let contents = try String(contentsOf: fileURL)
      let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

      for (index, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("TerminalDisplayWidth.") { continue }
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*/") {
          continue
        }

        let expectedPatterns = allowedSites[rel]
        let isKnownCaller = expectedPatterns?.contains(where: { trimmed.contains($0) }) ?? false

        if !isKnownCaller {
          observed.append((file: rel, line: index + 1, text: trimmed))
        } else {
          matchedFiles.insert(rel)
        }
      }
    }

    XCTAssertTrue(
      observed.isEmpty,
      "TerminalDisplayWidth usage must remain confined to documented fallback sites: "
        + observed.map { "\($0.file):\($0.line): \($0.text)" }.joined(separator: ", "))

    for rel in allowedSites.keys.sorted() {
      XCTAssertTrue(
        matchedFiles.contains(rel),
        "Expected fallback-site usage not found in \(rel): update this guard if policy intentionally changed"
      )
    }
  }
}
