import LabanCore
import ProfileRecorder
import XCTest

@testable import LabanApp

final class ProfileCaptureTests: XCTestCase {

  func testControlActionReturnsInternalSamplerData() {
    let expected = Data("profile-action-data\n".utf8)
    let router = LiveIntentRouter(
      model: nil,
      profileCaptureHandler: { samples, intervalMilliseconds in
        XCTAssertEqual(samples, 7)
        XCTAssertEqual(intervalMilliseconds, 3)
        return expected
      })
    let body = Data(
      #"{"action":"captureProfile","samples":7,"intervalMilliseconds":3}"#.utf8)

    let response = router.route(
      .legacyDebugAction(
        LegacyDebugActionInput(
          intentID: "profile.capture",
          action: "captureProfile",
          body: body)))

    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.contentType, "application/json")
    let decoded = try? JSONDecoder().decode(CaptureProfileActionResponse.self, from: response.body)
    XCTAssertEqual(decoded?.format, "perf-script")
    XCTAssertEqual(decoded?.byteCount, expected.count)
    XCTAssertEqual(Data(base64Encoded: decoded?.profileBase64 ?? ""), expected)
  }

  func testControlActionRejectsUnboundedCaptureBeforeSampling() {
    var sampled = false
    let router = LiveIntentRouter(
      model: nil,
      profileCaptureHandler: { _, _ in
        sampled = true
        return Data()
      })
    let body = Data(
      #"{"action":"captureProfile","samples":1200,"intervalMilliseconds":1000}"#.utf8)

    let response = router.route(
      .legacyDebugAction(
        LegacyDebugActionInput(
          intentID: "profile.capture",
          action: "captureProfile",
          body: body)))

    XCTAssertEqual(response.status, 400)
    XCTAssertFalse(sampled)
  }

  func testControlActionRejectsChangedTargetPIDBeforeSampling() {
    var sampled = false
    let router = LiveIntentRouter(
      model: nil,
      profileCaptureHandler: { _, _ in
        sampled = true
        return Data("unexpected".utf8)
      })
    let body = Data(
      #"{"action":"captureProfile","samples":1,"intervalMilliseconds":1,"expectedPID":1}"#
        .utf8)

    let response = router.route(
      .legacyDebugAction(
        LegacyDebugActionInput(
          intentID: "profile.capture",
          action: "captureProfile",
          body: body)))

    XCTAssertEqual(response.status, 409)
    XCTAssertFalse(sampled)
  }

  func testInternalSamplerRejectsConcurrentCapture() async throws {
    guard ProfileRecorderSampler.isSupportedPlatform else { return }
    let started = expectation(description: "first sampler started")
    let release = ProfileCaptureTestGate()
    let first = Task.detached {
      try await ProfileSamplerCapture.capture(
        sampleCount: 1,
        intervalMilliseconds: 1,
        sampler: { _, _ in
          started.fulfill()
          await release.wait()
          return Data("first".utf8)
        })
    }
    await fulfillment(of: [started], timeout: 2)

    do {
      _ = try await ProfileSamplerCapture.capture(
        sampleCount: 1,
        intervalMilliseconds: 1,
        sampler: { _, _ in Data("second".utf8) })
      XCTFail("concurrent profile capture unexpectedly started")
    } catch ProfileCaptureError.captureAlreadyInProgress {
      // Expected: the second capture never enters the raw sampler.
    }

    await release.open()
    let firstResult = try await first.value
    XCTAssertEqual(firstResult, Data("first".utf8))
  }

  func testInternalSamplerProducesPerfData() async throws {
    guard ProfileRecorderSampler.isSupportedPlatform else { return }

    let data = try await ProfileSamplerCapture.capture(
      sampleCount: 3, intervalMilliseconds: 1)

    XCTAssertFalse(data.isEmpty)
  }

  func testOneShotCaptureUsesInternalSamplerResult() throws {
    let expected = Data("internal-profile-data".utf8)
    let actual = try ProfileCapture.sampleData(
      samples: 7,
      intervalMilliseconds: 3,
      sampler: { samples, intervalMilliseconds in
        XCTAssertEqual(samples, 7)
        XCTAssertEqual(intervalMilliseconds, 3)
        return expected
      })

    XCTAssertEqual(actual, expected)
  }

  func testLabanAppDoesNotLinkOrStartProfileRecorderServer() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let package = try String(
      contentsOf: repositoryRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
    let main = try String(
      contentsOf: repositoryRoot.appendingPathComponent("Sources/LabanApp/main.swift"),
      encoding: .utf8)

    XCTAssertFalse(package.contains("ProfileRecorderServer"))
    XCTAssertFalse(main.contains("ProfileRecorderServer"))
    XCTAssertFalse(main.contains("withProfileRecordingServer"))
  }

  private func runRespondWithProfile(
    request: String, fileData: Data = Data("test-profile-data".utf8)
  ) throws -> String {
    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
      XCTFail("Failed to create socketpair")
      return ""
    }
    defer {
      close(fds[0])
      close(fds[1])
    }

    // Write request to fds[0]
    let requestData = Data(request.utf8)
    _ = requestData.withUnsafeBytes { ptr in
      write(fds[0], ptr.baseAddress, requestData.count)
    }

    // Call respondWithProfile on fds[1]
    ProfileCapture.respondWithProfile(clientFD: fds[1], fileName: "test.perf", fileData: fileData)
    close(fds[1])

    // Read response from fds[0]
    var responseData = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
      let n = read(fds[0], &buf, buf.count)
      if n <= 0 { break }
      responseData.append(buf, count: n)
    }

    return String(data: responseData, encoding: .utf8) ?? ""
  }

  func testRespondWithProfileMatchesTrustedOrigin() throws {
    let request = "GET /test.perf HTTP/1.1\r\nOrigin: https://www.speedscope.app\r\n\r\n"
    let response = try runRespondWithProfile(request: request)
    XCTAssertTrue(response.contains("Access-Control-Allow-Origin: https://www.speedscope.app\r\n"))
    XCTAssertTrue(response.contains("test-profile-data"))
  }

  func testRespondWithProfileMatchesFirefoxProfilerOrigin() throws {
    let request = "GET /test.perf HTTP/1.1\r\nOrigin: https://profiler.firefox.com\r\n\r\n"
    let response = try runRespondWithProfile(request: request)
    XCTAssertTrue(
      response.contains("Access-Control-Allow-Origin: https://profiler.firefox.com\r\n"))
  }

  func testRespondWithProfileDefaultsTrustedOriginForUntrustedOrigin() throws {
    let request = "GET /test.perf HTTP/1.1\r\nOrigin: https://evil.com\r\n\r\n"
    let response = try runRespondWithProfile(request: request)
    XCTAssertTrue(response.contains("Access-Control-Allow-Origin: https://www.speedscope.app\r\n"))
    XCTAssertFalse(response.contains("Access-Control-Allow-Origin: https://evil.com"))
  }

  func testRespondWithProfileDefaultsTrustedOriginForNoOrigin() throws {
    let request = "GET /test.perf HTTP/1.1\r\n\r\n"
    let response = try runRespondWithProfile(request: request)
    XCTAssertTrue(response.contains("Access-Control-Allow-Origin: https://www.speedscope.app\r\n"))
  }
}

private actor ProfileCaptureTestGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var isOpen = false

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func open() {
    isOpen = true
    continuation?.resume()
    continuation = nil
  }
}
