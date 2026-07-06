import Foundation
import LabanControl

/// UDS request helpers that avoid main-thread deadlock when the router hops to main.
enum ControlUDSTestSupport {
  static func requestFromBackgroundThread(
    socketPath: String,
    path: String,
    method: String = "GET",
    token: String? = nil,
    body: Data? = nil
  ) throws -> (Int, Data) {
    final class ResultBox: @unchecked Sendable {
      var value: Result<(Int, Data), Error>?
    }
    let box = ResultBox()
    let semaphore = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      box.value = Result {
        try ControlUDSClient.request(
          socketPath: socketPath,
          method: method,
          path: path,
          token: token,
          body: body)
      }
      semaphore.signal()
    }
    while semaphore.wait(timeout: .now()) == .timedOut {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return try box.value!.get()
  }
}
