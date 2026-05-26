import Foundation
import LabanCore
import XCTest

final class LabandProductLaunchAgentTests: XCTestCase {
  func testProductLaunchAgentPlistIsDisposableAndProductScoped() throws {
    guard ProcessInfo.processInfo.environment["LABAN_PRODUCT_LABAND_TESTS"] == "1" else {
      throw XCTSkip("set LABAN_PRODUCT_LABAND_TESTS=1 to run product LaunchAgent checks")
    }

    let base = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("laban-product-agent-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let paths = LabandProductPaths(applicationSupportURL: base)
    try paths.createDirectories()

    let executable = base.appendingPathComponent("laband")
    FileManager.default.createFile(atPath: executable.path, contents: Data())
    let label = "dev.laban.laband.tests.\(UUID().uuidString)"
    let config = LabandLaunchAgentConfiguration(
      label: label,
      machServiceName: "\(label).xpc",
      executableURL: executable,
      paths: paths
    )
    let data = try config.propertyListData()
    let plistURL = base.appendingPathComponent("\(label).plist")
    try data.write(to: plistURL)

    let decoded = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    )
    XCTAssertEqual(decoded["Label"] as? String, label)
    XCTAssertEqual(decoded["RunAtLoad"] as? Bool, true)
    XCTAssertEqual(decoded["KeepAlive"] as? Bool, false)
    XCTAssertTrue(FileManager.default.fileExists(atPath: plistURL.path))
    XCTAssertTrue(config.standardOutputURL.path.hasPrefix(base.path))
    XCTAssertTrue(config.standardErrorURL.path.hasPrefix(base.path))
    XCTAssertTrue(config.programArguments.contains(paths.journalDirectoryURL.path))
  }
}
