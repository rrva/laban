import Foundation

public enum LabptyProtocolLimits {
  public static let maxFrameBytes = LabptyFrameHeader.maxFrameBytes
  public static let maxArgvCount = 64
  public static let maxArgvEntryBytes = 4_096
  public static let maxEnvpCount = 256
  public static let maxEnvpEntryBytes = 4_352
  public static let maxCwdBytes = 4_096
  public static let maxLogicalSessionIdBytes = 256
  public static let maxByteRingPathBytes = 1_024
  public static let maxWriteInputBytes = 64 * 1024
  public static let maxClientIdBytes = 256
  public static let maxCapabilityBytes = 64
  public static let maxCapabilityCount = 64
  public static let maxSessionDescriptorCount = 64
}

public enum LabptyCapabilities {
  public static let byteRingV1 = "byte-ring/v1"
  public static let writeInputRpcV1 = "write-input-rpc/v1"
  public static let heartbeatShmV1 = "heartbeat-shm/v1"
  public static let sessionIdPinningV1 = "session-id-pinning/v1"

  public static let phase1: [String] = [
    byteRingV1,
    writeInputRpcV1,
    heartbeatShmV1,
    sessionIdPinningV1,
  ]
}

public struct LabptyHelloRequest: Equatable, Sendable {
  public var protocolMajor: UInt16
  public var protocolMinor: UInt16
  public var clientId: String
  public var capabilities: [String]

  public init(
    protocolMajor: UInt16 = LabptyFrameHeader.abiMajor,
    protocolMinor: UInt16 = LabptyFrameHeader.abiMinor,
    clientId: String,
    capabilities: [String] = LabptyCapabilities.phase1
  ) {
    self.protocolMajor = protocolMajor
    self.protocolMinor = protocolMinor
    self.clientId = clientId
    self.capabilities = capabilities
  }

  public func encode() throws -> Data {
    var writer = LabptyPayloadWriter()
    writer.appendUInt16(protocolMajor)
    writer.appendUInt16(protocolMinor)
    try writer.appendString(clientId)
    try writer.appendStringArray(capabilities)
    return writer.data
  }

  public static func decode(from payload: Data) throws -> LabptyHelloRequest {
    var reader = LabptyPayloadReader(payload)
    let major = try reader.readUInt16()
    let minor = try reader.readUInt16()
    let clientId = try reader.readString(
      maxBytes: LabptyProtocolLimits.maxClientIdBytes,
      field: "client_id")
    let capabilities = try reader.readStringArray(
      maxCount: LabptyProtocolLimits.maxCapabilityCount,
      maxBytesPerEntry: LabptyProtocolLimits.maxCapabilityBytes,
      field: "capabilities")
    return LabptyHelloRequest(
      protocolMajor: major,
      protocolMinor: minor,
      clientId: clientId,
      capabilities: capabilities)
  }
}

public struct LabptyHelloResponse: Equatable, Sendable {
  public var protocolMajor: UInt16
  public var protocolMinor: UInt16
  public var capabilities: [String]
  public var daemonMonoNs: UInt64

  public init(
    protocolMajor: UInt16 = LabptyFrameHeader.abiMajor,
    protocolMinor: UInt16 = LabptyFrameHeader.abiMinor,
    capabilities: [String] = LabptyCapabilities.phase1,
    daemonMonoNs: UInt64 = 0
  ) {
    self.protocolMajor = protocolMajor
    self.protocolMinor = protocolMinor
    self.capabilities = capabilities
    self.daemonMonoNs = daemonMonoNs
  }

  public func encode() throws -> Data {
    var writer = LabptyPayloadWriter()
    writer.appendUInt16(protocolMajor)
    writer.appendUInt16(protocolMinor)
    writer.appendUInt64(daemonMonoNs)
    try writer.appendStringArray(capabilities)
    return writer.data
  }

  public static func decode(from payload: Data) throws -> LabptyHelloResponse {
    var reader = LabptyPayloadReader(payload)
    let major = try reader.readUInt16()
    let minor = try reader.readUInt16()
    let monoNs = try reader.readUInt64()
    let capabilities = try reader.readStringArray(
      maxCount: LabptyProtocolLimits.maxCapabilityCount,
      maxBytesPerEntry: LabptyProtocolLimits.maxCapabilityBytes,
      field: "capabilities")
    return LabptyHelloResponse(
      protocolMajor: major,
      protocolMinor: minor,
      capabilities: capabilities,
      daemonMonoNs: monoNs)
  }
}

public struct LabptyOpenSessionRequest: Equatable, Sendable {
  public var rows: UInt32
  public var cols: UInt32
  public var outputRingCapacity: UInt64
  public var argv: [String]
  public var envp: [String]
  public var cwd: String
  public var logicalSessionId: String

  public init(
    rows: UInt32,
    cols: UInt32,
    outputRingCapacity: UInt64 = UInt64(LabptyByteRingLayout.defaultOutputRingCapacity),
    argv: [String],
    envp: [String] = [],
    cwd: String = "",
    logicalSessionId: String = ""
  ) {
    self.rows = rows
    self.cols = cols
    self.outputRingCapacity = outputRingCapacity
    self.argv = argv
    self.envp = envp
    self.cwd = cwd
    self.logicalSessionId = logicalSessionId
  }

  public func encode() throws -> Data {
    var writer = LabptyPayloadWriter()
    writer.appendUInt32(rows)
    writer.appendUInt32(cols)
    writer.appendUInt64(outputRingCapacity)
    try writer.appendStringArray(argv)
    try writer.appendStringArray(envp)
    try writer.appendString(cwd)
    try writer.appendString(logicalSessionId)
    return writer.data
  }

  public static func decode(from payload: Data) throws -> LabptyOpenSessionRequest {
    var reader = LabptyPayloadReader(payload)
    let rows = try reader.readUInt32()
    let cols = try reader.readUInt32()
    let outputRingCapacity = try reader.readUInt64()
    let argv = try reader.readStringArray(
      maxCount: LabptyProtocolLimits.maxArgvCount,
      maxBytesPerEntry: LabptyProtocolLimits.maxArgvEntryBytes,
      field: "argv")
    let envp = try reader.readStringArray(
      maxCount: LabptyProtocolLimits.maxEnvpCount,
      maxBytesPerEntry: LabptyProtocolLimits.maxEnvpEntryBytes,
      field: "envp")
    let cwd = try reader.readString(
      maxBytes: LabptyProtocolLimits.maxCwdBytes,
      field: "cwd")
    let logicalSessionId = try reader.readString(
      maxBytes: LabptyProtocolLimits.maxLogicalSessionIdBytes,
      field: "logical_session_id")
    return LabptyOpenSessionRequest(
      rows: rows,
      cols: cols,
      outputRingCapacity: outputRingCapacity,
      argv: argv,
      envp: envp,
      cwd: cwd,
      logicalSessionId: logicalSessionId)
  }
}

public struct LabptySessionDescriptor: Equatable, Sendable {
  // labpty deliberately does not carry foreground-process metadata.
  // Darwin's TIOCGPGRP requires `isctty(p, tp)` — the daemon, holding
  // only the master fd, has never claimed the PTY as its controlling
  // terminal, so any tcgetpgrp(master_fd) call there would return
  // ENOTTY. Consumers that need the foreground process derive it from
  // the child pid through libproc (see LabanTerminalCore/process_metadata.c).
  public var ptyHandle: UInt64
  public var childPid: Int32
  public var rows: UInt32
  public var cols: UInt32
  public var alive: Bool
  public var logicalSessionId: String
  public var byteRingShmPath: String
  public var outputRingCapacity: UInt64
  public var inputRingCapacity: UInt64

  public init(
    ptyHandle: UInt64,
    childPid: Int32,
    rows: UInt32,
    cols: UInt32,
    alive: Bool,
    logicalSessionId: String,
    byteRingShmPath: String,
    outputRingCapacity: UInt64,
    inputRingCapacity: UInt64 = 0
  ) {
    self.ptyHandle = ptyHandle
    self.childPid = childPid
    self.rows = rows
    self.cols = cols
    self.alive = alive
    self.logicalSessionId = logicalSessionId
    self.byteRingShmPath = byteRingShmPath
    self.outputRingCapacity = outputRingCapacity
    self.inputRingCapacity = inputRingCapacity
  }

  public func encode() throws -> Data {
    var writer = LabptyPayloadWriter()
    writer.appendUInt64(ptyHandle)
    writer.appendInt32(childPid)
    writer.appendUInt32(rows)
    writer.appendUInt32(cols)
    writer.appendBool(alive)
    try writer.appendString(logicalSessionId)
    try writer.appendString(byteRingShmPath)
    writer.appendUInt64(outputRingCapacity)
    writer.appendUInt64(inputRingCapacity)
    return writer.data
  }

  public static func decode(from payload: Data) throws -> LabptySessionDescriptor {
    var reader = LabptyPayloadReader(payload)
    return try decode(from: &reader)
  }

  static func decode(from reader: inout LabptyPayloadReader) throws -> LabptySessionDescriptor {
    let ptyHandle = try reader.readUInt64()
    let childPid = try reader.readInt32()
    let rows = try reader.readUInt32()
    let cols = try reader.readUInt32()
    let alive = try reader.readBool()
    let logicalSessionId = try reader.readString(
      maxBytes: LabptyProtocolLimits.maxLogicalSessionIdBytes,
      field: "logical_session_id")
    let byteRingShmPath = try reader.readString(
      maxBytes: LabptyProtocolLimits.maxByteRingPathBytes,
      field: "byte_ring_shm_path")
    let outputRingCapacity = try reader.readUInt64()
    let inputRingCapacity = try reader.readUInt64()
    return LabptySessionDescriptor(
      ptyHandle: ptyHandle,
      childPid: childPid,
      rows: rows,
      cols: cols,
      alive: alive,
      logicalSessionId: logicalSessionId,
      byteRingShmPath: byteRingShmPath,
      outputRingCapacity: outputRingCapacity,
      inputRingCapacity: inputRingCapacity)
  }
}

public struct LabptyListSessionsResponse: Equatable, Sendable {
  public var sessions: [LabptySessionDescriptor]

  public init(sessions: [LabptySessionDescriptor]) {
    self.sessions = sessions
  }

  public func encode() throws -> Data {
    guard sessions.count <= LabptyProtocolLimits.maxSessionDescriptorCount else {
      throw LabptyProtocolError.payloadTooLarge("sessions")
    }
    var writer = LabptyPayloadWriter()
    writer.appendUInt32(UInt32(sessions.count))
    for session in sessions {
      // Each descriptor is length-delimited so future fields can be
      // appended to a record without breaking the surrounding list
      // shape (ADR 0007). Encoders that append additive trailers
      // include them in the record_len they advertise.
      let descriptor = try session.encode()
      writer.appendUInt32(UInt32(descriptor.count))
      writer.appendBytes(descriptor)
    }
    return writer.data
  }

  public static func decode(from payload: Data) throws -> LabptyListSessionsResponse {
    var reader = LabptyPayloadReader(payload)
    let count = Int(try reader.readUInt32())
    guard count <= LabptyProtocolLimits.maxSessionDescriptorCount else {
      throw LabptyProtocolError.payloadTooLarge("sessions")
    }
    var sessions: [LabptySessionDescriptor] = []
    sessions.reserveCapacity(count)
    for _ in 0..<count {
      let recordLength = Int(try reader.readUInt32())
      guard recordLength <= reader.remainingCount else {
        throw LabptyProtocolError.truncatedFrame
      }
      let recordBytes = try reader.readBytes(count: recordLength)
      var recordReader = LabptyPayloadReader(recordBytes)
      // Trailing bytes inside a record are tolerated as additive
      // fields per ADR 0007; we read what we know about and ignore
      // the rest of the record.
      sessions.append(try LabptySessionDescriptor.decode(from: &recordReader))
    }
    return LabptyListSessionsResponse(sessions: sessions)
  }
}

public struct LabptyResizeSessionRequest: Equatable, Sendable {
  public var ptyHandle: UInt64
  public var rows: UInt32
  public var cols: UInt32

  public init(ptyHandle: UInt64, rows: UInt32, cols: UInt32) {
    self.ptyHandle = ptyHandle
    self.rows = rows
    self.cols = cols
  }

  public func encode() -> Data {
    var writer = LabptyPayloadWriter()
    writer.appendUInt64(ptyHandle)
    writer.appendUInt32(rows)
    writer.appendUInt32(cols)
    return writer.data
  }

  public static func decode(from payload: Data) throws -> LabptyResizeSessionRequest {
    var reader = LabptyPayloadReader(payload)
    let request = LabptyResizeSessionRequest(
      ptyHandle: try reader.readUInt64(),
      rows: try reader.readUInt32(),
      cols: try reader.readUInt32())
    return request
  }
}

public struct LabptySignalSessionRequest: Equatable, Sendable {
  public var ptyHandle: UInt64
  public var signal: Int32

  public init(ptyHandle: UInt64, signal: Int32) {
    self.ptyHandle = ptyHandle
    self.signal = signal
  }

  public func encode() -> Data {
    var writer = LabptyPayloadWriter()
    writer.appendUInt64(ptyHandle)
    writer.appendInt32(signal)
    return writer.data
  }

  public static func decode(from payload: Data) throws -> LabptySignalSessionRequest {
    var reader = LabptyPayloadReader(payload)
    let request = LabptySignalSessionRequest(
      ptyHandle: try reader.readUInt64(),
      signal: try reader.readInt32())
    return request
  }
}

public struct LabptyTerminateSessionRequest: Equatable, Sendable {
  public var ptyHandle: UInt64

  public init(ptyHandle: UInt64) {
    self.ptyHandle = ptyHandle
  }

  public func encode() -> Data {
    var writer = LabptyPayloadWriter()
    writer.appendUInt64(ptyHandle)
    return writer.data
  }

  public static func decode(from payload: Data) throws -> LabptyTerminateSessionRequest {
    var reader = LabptyPayloadReader(payload)
    return LabptyTerminateSessionRequest(ptyHandle: try reader.readUInt64())
  }
}

public struct LabptyWriteInputRequest: Equatable, Sendable {
  public var ptyHandle: UInt64
  public var bytes: Data

  public init(ptyHandle: UInt64, bytes: Data) {
    self.ptyHandle = ptyHandle
    self.bytes = bytes
  }

  public func encode() throws -> Data {
    guard bytes.count <= LabptyProtocolLimits.maxWriteInputBytes else {
      throw LabptyProtocolError.payloadTooLarge("write_input")
    }
    var writer = LabptyPayloadWriter()
    writer.appendUInt64(ptyHandle)
    // Explicit length prefix gates the additive trailer per ADR
    // 0007: a future caller may append optional metadata fields
    // after the byte payload and the daemon will ignore them
    // instead of typing them into the PTY.
    writer.appendUInt32(UInt32(bytes.count))
    writer.appendBytes(bytes)
    return writer.data
  }

  public static func decode(from payload: Data) throws -> LabptyWriteInputRequest {
    var reader = LabptyPayloadReader(payload)
    let ptyHandle = try reader.readUInt64()
    let declaredLength = Int(try reader.readUInt32())
    guard declaredLength <= LabptyProtocolLimits.maxWriteInputBytes else {
      throw LabptyProtocolError.payloadTooLarge("write_input")
    }
    guard declaredLength <= reader.remainingCount else {
      throw LabptyProtocolError.truncatedFrame
    }
    let bytes = try reader.readBytes(count: declaredLength)
    return LabptyWriteInputRequest(ptyHandle: ptyHandle, bytes: bytes)
  }
}

public struct LabptyPingResponse: Equatable, Sendable {
  public var daemonMonoNs: UInt64

  public init(daemonMonoNs: UInt64) {
    self.daemonMonoNs = daemonMonoNs
  }

  public func encode() -> Data {
    var writer = LabptyPayloadWriter()
    writer.appendUInt64(daemonMonoNs)
    return writer.data
  }

  public static func decode(from payload: Data) throws -> LabptyPingResponse {
    var reader = LabptyPayloadReader(payload)
    return LabptyPingResponse(daemonMonoNs: try reader.readUInt64())
  }
}
