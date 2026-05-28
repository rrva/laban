import Foundation

public enum LabptyProtocolError: Error, Equatable, CustomStringConvertible {
  case truncatedFrame
  case oversizeFrame
  case versionMismatch
  case badMagic
  case invalidOperation(UInt16)
  case invalidResponseOperation
  case payloadTooLarge(String)
  case invalidBoolean(UInt8)
  case invalidUTF8

  public var description: String {
    switch self {
    case .truncatedFrame:
      return "truncated labpty frame"
    case .oversizeFrame:
      return "oversize labpty frame"
    case .versionMismatch:
      return "labpty ABI version mismatch"
    case .badMagic:
      return "invalid labpty frame magic"
    case .invalidOperation(let raw):
      return "invalid labpty operation: \(raw)"
    case .invalidResponseOperation:
      return "response operation is not valid in a request"
    case .payloadTooLarge(let field):
      return "labpty payload field too large: \(field)"
    case .invalidBoolean(let raw):
      return "invalid labpty boolean: \(raw)"
    case .invalidUTF8:
      return "invalid labpty UTF-8 payload"
    }
  }
}

public enum LabptyOperation: UInt16, CaseIterable, Sendable {
  case hello = 0x0001
  case openSession = 0x0002
  case listSessions = 0x0003
  case resizeSession = 0x0004
  case signalSession = 0x0005
  case terminateSession = 0x0006
  case writeInput = 0x0007
  case ping = 0x0008
  case attachSession = 0x0009
  case detachSession = 0x000A
}

public enum LabptyErrorCode: UInt16, Equatable, Sendable {
  case ok = 0x0000
  case sessionNotFound = 0x0001
  case sessionIdInUse = 0x0002
  case ptyOpenFailed = 0x0003
  case ringMapFailed = 0x0004
  case capabilityRequired = 0x0005
  case versionMismatch = 0x0006
  case permissionDenied = 0x0007
  case payloadTooLarge = 0x0008
  case truncatedFrame = 0x0009
  case oversizeFrame = 0x000A
  case internalError = 0x000B
  case shuttingDown = 0x000C
  case unknownOperation = 0x000D
  /// Cooked-mode write rejected because the slave's line discipline
  /// cannot atomically absorb the payload. Externally atomic: no byte
  /// reached the master. See docs/adr/0008.
  case inputBackpressure = 0x000E
}

public struct LabptyFrameHeader: Equatable, Sendable {
  public static let magic = [UInt8]("LPCT".utf8)
  public static let headerByteCount = 24
  public static let responseOperation: UInt16 = 0xFFFF
  public static let maxFrameBytes = 128 * 1024
  public static let abiMajor: UInt16 = 1
  public static let abiMinor: UInt16 = 0

  public var abiMajor: UInt16
  public var abiMinor: UInt16
  public var frameLength: UInt32
  public var operationRaw: UInt16
  public var codeRaw: UInt16
  public var sequence: UInt64

  public init(
    abiMajor: UInt16 = Self.abiMajor,
    abiMinor: UInt16 = Self.abiMinor,
    frameLength: UInt32,
    operationRaw: UInt16,
    codeRaw: UInt16,
    sequence: UInt64
  ) {
    self.abiMajor = abiMajor
    self.abiMinor = abiMinor
    self.frameLength = frameLength
    self.operationRaw = operationRaw
    self.codeRaw = codeRaw
    self.sequence = sequence
  }

  public var operation: LabptyOperation? {
    LabptyOperation(rawValue: operationRaw)
  }

  public var responseCode: LabptyErrorCode? {
    LabptyErrorCode(rawValue: codeRaw)
  }
}

public struct LabptyFrame: Equatable, Sendable {
  public var header: LabptyFrameHeader
  public var payload: Data

  public init(header: LabptyFrameHeader, payload: Data) {
    self.header = header
    self.payload = payload
  }
}

public enum LabptyFraming {
  public static func encodeRequest(
    operation: LabptyOperation,
    sequence: UInt64,
    payload: Data = Data()
  ) throws -> Data {
    try encode(
      operationRaw: operation.rawValue,
      code: .ok,
      sequence: sequence,
      payload: payload)
  }

  public static func encodeResponse(
    sequence: UInt64,
    code: LabptyErrorCode,
    payload: Data = Data()
  ) throws -> Data {
    try encode(
      operationRaw: LabptyFrameHeader.responseOperation,
      code: code,
      sequence: sequence,
      payload: payload)
  }

  public static func decode(_ data: Data) throws -> LabptyFrame {
    guard data.count >= LabptyFrameHeader.headerByteCount else {
      throw LabptyProtocolError.truncatedFrame
    }

    var reader = LabptyPayloadReader(data)
    let magic = try reader.readBytes(count: 4)
    guard Array(magic) == LabptyFrameHeader.magic else {
      throw LabptyProtocolError.badMagic
    }

    let abiMajor = try reader.readUInt16()
    let abiMinor = try reader.readUInt16()
    guard abiMajor == LabptyFrameHeader.abiMajor else {
      throw LabptyProtocolError.versionMismatch
    }
    _ = abiMinor

    let frameLength = try reader.readUInt32()
    guard frameLength >= UInt32(LabptyFrameHeader.headerByteCount) else {
      throw LabptyProtocolError.truncatedFrame
    }
    guard frameLength <= UInt32(LabptyFrameHeader.maxFrameBytes) else {
      throw LabptyProtocolError.oversizeFrame
    }
    guard Int(frameLength) == data.count else {
      throw LabptyProtocolError.truncatedFrame
    }

    let opRaw = try reader.readUInt16()
    let codeRaw = try reader.readUInt16()
    let sequence = try reader.readUInt64()
    let payload = try reader.readBytes(count: data.count - LabptyFrameHeader.headerByteCount)

    return LabptyFrame(
      header: LabptyFrameHeader(
        abiMajor: abiMajor,
        abiMinor: abiMinor,
        frameLength: frameLength,
        operationRaw: opRaw,
        codeRaw: codeRaw,
        sequence: sequence),
      payload: payload)
  }

  public static func decodeClientRequest(_ data: Data) throws -> LabptyFrame {
    let frame = try decode(data)
    if frame.header.operationRaw == LabptyFrameHeader.responseOperation {
      throw LabptyProtocolError.invalidResponseOperation
    }
    guard frame.header.operation != nil else {
      throw LabptyProtocolError.invalidOperation(frame.header.operationRaw)
    }
    return frame
  }

  private static func encode(
    operationRaw: UInt16,
    code: LabptyErrorCode,
    sequence: UInt64,
    payload: Data
  ) throws -> Data {
    let frameLength = LabptyFrameHeader.headerByteCount + payload.count
    guard frameLength <= LabptyFrameHeader.maxFrameBytes else {
      throw LabptyProtocolError.oversizeFrame
    }

    var data = Data()
    data.reserveCapacity(frameLength)
    data.append(contentsOf: LabptyFrameHeader.magic)
    data.appendUInt16(LabptyFrameHeader.abiMajor)
    data.appendUInt16(LabptyFrameHeader.abiMinor)
    data.appendUInt32(UInt32(frameLength))
    data.appendUInt16(operationRaw)
    data.appendUInt16(code.rawValue)
    data.appendUInt64(sequence)
    data.append(payload)
    return data
  }
}

public struct LabptyPayloadReader {
  public private(set) var offset: Int = 0
  private let data: Data

  public init(_ data: Data) {
    self.data = data
  }

  public var remainingCount: Int {
    data.count - offset
  }

  public mutating func readUInt8() throws -> UInt8 {
    guard offset + 1 <= data.count else {
      throw LabptyProtocolError.truncatedFrame
    }
    let value = data[offset]
    offset += 1
    return value
  }

  public mutating func readBool() throws -> Bool {
    let value = try readUInt8()
    switch value {
    case 0: return false
    case 1: return true
    default: throw LabptyProtocolError.invalidBoolean(value)
    }
  }

  public mutating func readUInt16() throws -> UInt16 {
    let bytes = try readFixedBytes(count: 2)
    return UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
  }

  public mutating func readUInt32() throws -> UInt32 {
    let bytes = try readFixedBytes(count: 4)
    return UInt32(bytes[0])
      | (UInt32(bytes[1]) << 8)
      | (UInt32(bytes[2]) << 16)
      | (UInt32(bytes[3]) << 24)
  }

  public mutating func readInt32() throws -> Int32 {
    Int32(bitPattern: try readUInt32())
  }

  public mutating func readUInt64() throws -> UInt64 {
    let bytes = try readFixedBytes(count: 8)
    var value: UInt64 = 0
    for index in 0..<8 {
      value |= UInt64(bytes[index]) << UInt64(index * 8)
    }
    return value
  }

  public mutating func readString(maxBytes: Int, field: String) throws -> String {
    let length = Int(try readUInt32())
    guard length <= maxBytes else {
      throw LabptyProtocolError.payloadTooLarge(field)
    }
    let bytes = try readBytes(count: length)
    guard let string = String(data: bytes, encoding: .utf8) else {
      throw LabptyProtocolError.invalidUTF8
    }
    return string
  }

  public mutating func readStringArray(
    maxCount: Int,
    maxBytesPerEntry: Int,
    field: String
  ) throws -> [String] {
    let count = Int(try readUInt32())
    guard count <= maxCount else {
      throw LabptyProtocolError.payloadTooLarge(field)
    }
    var strings: [String] = []
    strings.reserveCapacity(count)
    for index in 0..<count {
      strings.append(try readString(maxBytes: maxBytesPerEntry, field: "\(field)[\(index)]"))
    }
    return strings
  }

  public mutating func readBytes(count: Int) throws -> Data {
    let bytes = try readFixedBytes(count: count)
    return Data(bytes)
  }

  public mutating func readRemainingBytes(maxBytes: Int, field: String) throws -> Data {
    guard remainingCount <= maxBytes else {
      throw LabptyProtocolError.payloadTooLarge(field)
    }
    return try readBytes(count: remainingCount)
  }

  private mutating func readFixedBytes(count: Int) throws -> [UInt8] {
    guard count >= 0, offset + count <= data.count else {
      throw LabptyProtocolError.truncatedFrame
    }
    let start = offset
    offset += count
    return Array(data[start..<start + count])
  }
}

public struct LabptyPayloadWriter {
  public private(set) var data = Data()

  public init() {}

  public mutating func appendUInt8(_ value: UInt8) {
    data.append(value)
  }

  public mutating func appendBool(_ value: Bool) {
    data.append(value ? 1 : 0)
  }

  public mutating func appendUInt16(_ value: UInt16) {
    data.appendUInt16(value)
  }

  public mutating func appendUInt32(_ value: UInt32) {
    data.appendUInt32(value)
  }

  public mutating func appendInt32(_ value: Int32) {
    data.appendUInt32(UInt32(bitPattern: value))
  }

  public mutating func appendUInt64(_ value: UInt64) {
    data.appendUInt64(value)
  }

  public mutating func appendString(_ value: String) throws {
    let bytes = Array(value.utf8)
    guard bytes.count <= UInt32.max else {
      throw LabptyProtocolError.payloadTooLarge("string")
    }
    data.appendUInt32(UInt32(bytes.count))
    data.append(contentsOf: bytes)
  }

  public mutating func appendStringArray(_ values: [String]) throws {
    guard values.count <= UInt32.max else {
      throw LabptyProtocolError.payloadTooLarge("string array")
    }
    data.appendUInt32(UInt32(values.count))
    for value in values {
      try appendString(value)
    }
  }

  public mutating func appendBytes(_ bytes: Data) {
    data.append(bytes)
  }
}

extension Data {
  fileprivate mutating func appendUInt16(_ value: UInt16) {
    append(UInt8(value & 0x00FF))
    append(UInt8((value >> 8) & 0x00FF))
  }

  fileprivate mutating func appendUInt32(_ value: UInt32) {
    append(UInt8(value & 0x000000FF))
    append(UInt8((value >> 8) & 0x000000FF))
    append(UInt8((value >> 16) & 0x000000FF))
    append(UInt8((value >> 24) & 0x000000FF))
  }

  fileprivate mutating func appendUInt64(_ value: UInt64) {
    for shift in stride(from: 0, to: 64, by: 8) {
      append(UInt8((value >> UInt64(shift)) & 0x00000000000000FF))
    }
  }
}
