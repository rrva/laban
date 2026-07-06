import Foundation

public struct ControlJSONResponse: Sendable {
  public var status: Int
  public var body: Data

  public init(status: Int = 200, body: Data) {
    self.status = status
    self.body = body
  }
}

public func controlJSONEncode<T: Encodable>(_ value: T, status: Int = 200) -> ControlJSONResponse {
  let enc = JSONEncoder()
  enc.dateEncodingStrategy = .iso8601
  enc.outputFormatting = .sortedKeys
  guard let data = try? enc.encode(value) else {
    return ControlJSONResponse(
      status: 500, body: #"{"error":"encoding failed"}"#.data(using: .utf8)!)
  }
  return ControlJSONResponse(status: status, body: data)
}

public func controlJSONError(_ message: String, status: Int = 400) -> ControlJSONResponse {
  let escaped =
    message
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
  let body = "{\"error\":\"\(escaped)\"}"
  return ControlJSONResponse(status: status, body: body.data(using: .utf8)!)
}
