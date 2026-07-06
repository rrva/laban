import XCTest
@testable import LabanApp

final class ProfileCaptureTests: XCTestCase {
  
  private func runRespondWithProfile(request: String, fileData: Data = Data("test-profile-data".utf8)) throws -> String {
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
    XCTAssertTrue(response.contains("Access-Control-Allow-Origin: https://profiler.firefox.com\r\n"))
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
