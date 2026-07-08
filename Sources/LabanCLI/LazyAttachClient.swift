import CryptoKit
import Foundation
import LabanControl

struct LazyAttachRequest: Encodable {
  var clientRequestID: String
  var cliCommand: String
  var intendedRequest: LazyAttachIntendedRequest
}

struct LazyAttachIntendedRequest: Encodable {
  var method: String
  var path: String
  var query: String
  var body: String?
  var bodySHA256: String?
}

struct LazyAttachResponse: Decodable {
  var ok: Bool
  var sessionID: String
  var approval: String
  var downstreamStatus: Int
  var downstreamBody: String
}

enum LazyAttachClientError: Error, CustomStringConvertible {
  case controlPlaneUnavailable
  case denied(String)
  case timeout(String)
  case sessionChanged(String)
  case malformedResponse

  var description: String {
    switch self {
    case .controlPlaneUnavailable:
      return "control plane unavailable"
    case .denied(let reason):
      return "denied: \(reason)"
    case .timeout(let reason):
      return "timeout: \(reason)"
    case .sessionChanged(let reason):
      return "session changed: \(reason)"
    case .malformedResponse:
      return "malformed response"
    }
  }
}

enum LazyAttachClient {
  static let clientRequestIDLength = 16

  static func perform(
    cliCommand: String,
    method: String,
    path: String,
    query: [String: String],
    body: String?
  ) throws -> (status: Int, body: String) {
    let record = try readControlRecord()
    let requestID = makeRequestID()
    let bodyString = body ?? ""
    let bodyData = Data(bodyString.utf8)
    let bodySHA256 = bodyData.isEmpty ? nil : computeSHA256(bodyData)

    let queryString = query.sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }
      .joined(separator: "&")

    let intendedRequest = LazyAttachIntendedRequest(
      method: method,
      path: path,
      query: queryString,
      body: bodyString.isEmpty ? nil : bodyString,
      bodySHA256: bodySHA256)

    let request = LazyAttachRequest(
      clientRequestID: requestID,
      cliCommand: cliCommand,
      intendedRequest: intendedRequest)

    let payload = try JSONEncoder().encode(request)
    let (status, responseData) = try ControlUDSClient.request(
      socketPath: record.url,
      method: "POST",
      path: LabanControlServer.lazyAttachRequestPath,
      token: record.token,
      body: payload,
      timeout: 45)

    guard (200..<300).contains(status) else {
      let message = String(data: responseData, encoding: .utf8) ?? ""
      if status == 408 {
        throw LazyAttachClientError.timeout(message)
      }
      if status == 409 {
        throw LazyAttachClientError.sessionChanged(message)
      }
      if status == 429 {
        throw LazyAttachClientError.timeout(message)
      }
      throw LazyAttachClientError.denied(message)
    }

    guard let response = try? JSONDecoder().decode(LazyAttachResponse.self, from: responseData)
    else {
      throw LazyAttachClientError.malformedResponse
    }
    return (response.downstreamStatus, response.downstreamBody)
  }

  private static func readControlRecord() throws -> ControlAdvertisementRecord {
    do {
      return try ControlDiscovery.read()
    } catch {
      throw LazyAttachClientError.controlPlaneUnavailable
    }
  }

  private static func makeRequestID() -> String {
    let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
    return String((0..<clientRequestIDLength).map { _ in chars.randomElement()! })
  }

  private static func computeSHA256(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
