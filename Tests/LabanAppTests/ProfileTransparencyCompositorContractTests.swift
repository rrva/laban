import Foundation
import XCTest

final class ProfileTransparencyCompositorContractTests: XCTestCase {
  func testSelfTestExercisesControlPlaneProfileCaptureCommand() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let process = Process()
    process.executableURL = repositoryRoot.appendingPathComponent(
      "scripts/profile-transparency-compositor")
    process.arguments = ["--self-test"]
    process.currentDirectoryURL = repositoryRoot
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output

    try process.run()
    process.waitUntilExit()
    let text = String(
      decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

    XCTAssertEqual(process.terminationStatus, 0, text)
    XCTAssertTrue(text.contains("profile capture control action passed"), text)
  }
}
