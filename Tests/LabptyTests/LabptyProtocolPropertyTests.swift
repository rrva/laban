import Foundation
import XCTest

@testable import LabanCore

/// Property-based tests for the labpty wire protocol. Generators emit
/// valid randomized messages (and arbitrary byte buffers) so the suite
/// exercises shape variation the hand-written golden tests in
/// `LabptyProtocolTests` cannot. Each property fixes a seed in code so
/// CI failures reproduce deterministically — bump the seed when adding
/// or rebalancing generators.
final class LabptyProtocolPropertyTests: XCTestCase {
  private static let propertyIterations = 256
  private static let fuzzIterations = 512

  // MARK: - Roundtrip

  func testHelloRequestRoundtripProperty() throws {
    var rng = SplitMix64(seed: 0xA1B2_C3D4_E5F6_0701)
    for _ in 0..<Self.propertyIterations {
      let message = LabptyHelloRequest(
        protocolMajor: rng.nextUInt16(),
        protocolMinor: rng.nextUInt16(),
        clientId: rng.nextString(maxBytes: LabptyProtocolLimits.maxClientIdBytes),
        capabilities: rng.nextStringArray(
          maxCount: LabptyProtocolLimits.maxCapabilityCount,
          maxBytesPerEntry: LabptyProtocolLimits.maxCapabilityBytes))
      let decoded = try LabptyHelloRequest.decode(from: try message.encode())
      XCTAssertEqual(decoded, message, "seed-derived hello did not round-trip: \(message)")
    }
  }

  func testHelloResponseRoundtripProperty() throws {
    var rng = SplitMix64(seed: 0xA1B2_C3D4_E5F6_0702)
    for _ in 0..<Self.propertyIterations {
      let message = LabptyHelloResponse(
        protocolMajor: rng.nextUInt16(),
        protocolMinor: rng.nextUInt16(),
        capabilities: rng.nextStringArray(
          maxCount: LabptyProtocolLimits.maxCapabilityCount,
          maxBytesPerEntry: LabptyProtocolLimits.maxCapabilityBytes),
        daemonMonoNs: rng.nextUInt64())
      let decoded = try LabptyHelloResponse.decode(from: try message.encode())
      XCTAssertEqual(decoded, message)
    }
  }

  func testOpenSessionRoundtripProperty() throws {
    var rng = SplitMix64(seed: 0xA1B2_C3D4_E5F6_0703)
    for _ in 0..<Self.propertyIterations {
      let message = LabptyOpenSessionRequest(
        rows: rng.nextUInt32(),
        cols: rng.nextUInt32(),
        outputRingCapacity: rng.nextUInt64(),
        argv: rng.nextStringArray(
          maxCount: LabptyProtocolLimits.maxArgvCount,
          maxBytesPerEntry: min(LabptyProtocolLimits.maxArgvEntryBytes, 64)),
        envp: rng.nextStringArray(
          maxCount: LabptyProtocolLimits.maxEnvpCount,
          maxBytesPerEntry: min(LabptyProtocolLimits.maxEnvpEntryBytes, 64)),
        cwd: rng.nextString(maxBytes: min(LabptyProtocolLimits.maxCwdBytes, 128)),
        logicalSessionId: rng.nextString(maxBytes: LabptyProtocolLimits.maxLogicalSessionIdBytes))
      let decoded = try LabptyOpenSessionRequest.decode(from: try message.encode())
      XCTAssertEqual(decoded, message)
    }
  }

  func testSessionDescriptorRoundtripProperty() throws {
    var rng = SplitMix64(seed: 0xA1B2_C3D4_E5F6_0704)
    for _ in 0..<Self.propertyIterations {
      let message = rng.nextSessionDescriptor()
      let decoded = try LabptySessionDescriptor.decode(from: try message.encode())
      XCTAssertEqual(decoded, message)
    }
  }

  func testListSessionsRoundtripProperty() throws {
    var rng = SplitMix64(seed: 0xA1B2_C3D4_E5F6_0705)
    for _ in 0..<Self.propertyIterations {
      let count = Int(rng.nextUInt32(below: UInt32(LabptyProtocolLimits.maxSessionDescriptorCount + 1)))
      let sessions = (0..<count).map { _ in rng.nextSessionDescriptor() }
      let message = LabptyListSessionsResponse(sessions: sessions)
      let decoded = try LabptyListSessionsResponse.decode(from: try message.encode())
      XCTAssertEqual(decoded, message)
    }
  }

  func testResizeSignalTerminateRoundtripProperty() throws {
    var rng = SplitMix64(seed: 0xA1B2_C3D4_E5F6_0706)
    for _ in 0..<Self.propertyIterations {
      let handle = rng.nextUInt64()
      let resize = LabptyResizeSessionRequest(
        ptyHandle: handle,
        rows: rng.nextUInt32(),
        cols: rng.nextUInt32())
      XCTAssertEqual(try LabptyResizeSessionRequest.decode(from: resize.encode()), resize)

      let signal = LabptySignalSessionRequest(
        ptyHandle: handle,
        signal: Int32(bitPattern: rng.nextUInt32()))
      XCTAssertEqual(try LabptySignalSessionRequest.decode(from: signal.encode()), signal)

      let terminate = LabptyTerminateSessionRequest(ptyHandle: handle)
      XCTAssertEqual(try LabptyTerminateSessionRequest.decode(from: terminate.encode()), terminate)
    }
  }

  func testWriteInputRoundtripProperty() throws {
    var rng = SplitMix64(seed: 0xA1B2_C3D4_E5F6_0707)
    for _ in 0..<Self.propertyIterations {
      let len = Int(rng.nextUInt32(below: 4_096))
      let message = LabptyWriteInputRequest(
        ptyHandle: rng.nextUInt64(),
        bytes: rng.nextRawBytes(count: len))
      let decoded = try LabptyWriteInputRequest.decode(from: try message.encode())
      XCTAssertEqual(decoded, message)
    }
  }

  func testPingResponseRoundtripProperty() throws {
    var rng = SplitMix64(seed: 0xA1B2_C3D4_E5F6_0708)
    for _ in 0..<Self.propertyIterations {
      let message = LabptyPingResponse(daemonMonoNs: rng.nextUInt64())
      XCTAssertEqual(try LabptyPingResponse.decode(from: message.encode()), message)
    }
  }

  // MARK: - Additive-trailer tolerance (ADR 0007)

  /// A future client may append optional fields after the known payload.
  /// Every decoder of an additive operation must reconstruct the original
  /// message regardless of the trailer's length or contents.
  func testAdditiveTrailerToleranceProperty() throws {
    var rng = SplitMix64(seed: 0xA1B2_C3D4_E5F6_0709)
    for _ in 0..<Self.propertyIterations {
      let trailer = rng.nextRawBytes(count: Int(rng.nextUInt32(below: 64)))

      let hello = LabptyHelloRequest(
        clientId: rng.nextString(maxBytes: LabptyProtocolLimits.maxClientIdBytes),
        capabilities: rng.nextStringArray(
          maxCount: LabptyProtocolLimits.maxCapabilityCount,
          maxBytesPerEntry: LabptyProtocolLimits.maxCapabilityBytes))
      XCTAssertEqual(
        try LabptyHelloRequest.decode(from: try hello.encode() + trailer),
        hello)

      let helloResp = LabptyHelloResponse(
        capabilities: rng.nextStringArray(
          maxCount: LabptyProtocolLimits.maxCapabilityCount,
          maxBytesPerEntry: LabptyProtocolLimits.maxCapabilityBytes),
        daemonMonoNs: rng.nextUInt64())
      XCTAssertEqual(
        try LabptyHelloResponse.decode(from: try helloResp.encode() + trailer),
        helloResp)

      let open = LabptyOpenSessionRequest(
        rows: rng.nextUInt32(),
        cols: rng.nextUInt32(),
        outputRingCapacity: rng.nextUInt64(),
        argv: rng.nextStringArray(maxCount: 4, maxBytesPerEntry: 32),
        envp: rng.nextStringArray(maxCount: 4, maxBytesPerEntry: 32),
        cwd: rng.nextString(maxBytes: 64),
        logicalSessionId: rng.nextString(maxBytes: 64))
      XCTAssertEqual(
        try LabptyOpenSessionRequest.decode(from: try open.encode() + trailer),
        open)

      let descriptor = rng.nextSessionDescriptor()
      XCTAssertEqual(
        try LabptySessionDescriptor.decode(from: try descriptor.encode() + trailer),
        descriptor)

      let resize = LabptyResizeSessionRequest(
        ptyHandle: rng.nextUInt64(),
        rows: rng.nextUInt32(),
        cols: rng.nextUInt32())
      XCTAssertEqual(
        try LabptyResizeSessionRequest.decode(from: resize.encode() + trailer),
        resize)

      let signal = LabptySignalSessionRequest(
        ptyHandle: rng.nextUInt64(),
        signal: Int32(bitPattern: rng.nextUInt32()))
      XCTAssertEqual(
        try LabptySignalSessionRequest.decode(from: signal.encode() + trailer),
        signal)

      let terminate = LabptyTerminateSessionRequest(ptyHandle: rng.nextUInt64())
      XCTAssertEqual(
        try LabptyTerminateSessionRequest.decode(from: terminate.encode() + trailer),
        terminate)

      let write = LabptyWriteInputRequest(
        ptyHandle: rng.nextUInt64(),
        bytes: rng.nextRawBytes(count: Int(rng.nextUInt32(below: 256))))
      XCTAssertEqual(
        try LabptyWriteInputRequest.decode(from: try write.encode() + trailer),
        write)

      let ping = LabptyPingResponse(daemonMonoNs: rng.nextUInt64())
      XCTAssertEqual(
        try LabptyPingResponse.decode(from: ping.encode() + trailer),
        ping)
    }
  }

  /// A descriptor record inside a list response is length-delimited, so
  /// per-record trailers must not bleed into the next descriptor.
  func testListSessionsTrailerOnEachRecordProperty() throws {
    var rng = SplitMix64(seed: 0xA1B2_C3D4_E5F6_070A)
    for _ in 0..<Self.propertyIterations {
      let count = Int(rng.nextUInt32(below: 8))
      let sessions = (0..<count).map { _ in rng.nextSessionDescriptor() }

      var writer = LabptyPayloadWriter()
      writer.appendUInt32(UInt32(sessions.count))
      for session in sessions {
        let record = try session.encode() + rng.nextRawBytes(count: Int(rng.nextUInt32(below: 32)))
        writer.appendUInt32(UInt32(record.count))
        writer.appendBytes(record)
      }

      let decoded = try LabptyListSessionsResponse.decode(from: writer.data)
      XCTAssertEqual(decoded.sessions, sessions)
    }
  }

  // MARK: - Frame layer

  func testFrameRoundtripProperty() throws {
    var rng = SplitMix64(seed: 0xA1B2_C3D4_E5F6_070B)
    let ops = LabptyOperation.allCases
    for _ in 0..<Self.propertyIterations {
      let op = ops[Int(rng.nextUInt32(below: UInt32(ops.count)))]
      let sequence = rng.nextUInt64()
      let payloadLen = Int(rng.nextUInt32(below: 4_096))
      let payload = rng.nextRawBytes(count: payloadLen)

      let encoded = try LabptyFraming.encodeRequest(
        operation: op,
        sequence: sequence,
        payload: payload)
      let decoded = try LabptyFraming.decodeClientRequest(encoded)
      XCTAssertEqual(decoded.header.operation, op)
      XCTAssertEqual(decoded.header.sequence, sequence)
      XCTAssertEqual(decoded.header.responseCode, .ok)
      XCTAssertEqual(
        decoded.header.frameLength,
        UInt32(LabptyFrameHeader.headerByteCount + payload.count))
      XCTAssertEqual(decoded.payload, payload)
    }
  }

  func testResponseFrameRoundtripProperty() throws {
    var rng = SplitMix64(seed: 0xA1B2_C3D4_E5F6_070C)
    let codes: [LabptyErrorCode] = [
      .ok, .sessionNotFound, .sessionIdInUse, .ptyOpenFailed,
      .ringMapFailed, .capabilityRequired, .versionMismatch,
      .permissionDenied, .payloadTooLarge, .truncatedFrame,
      .oversizeFrame, .internalError, .shuttingDown,
      .unknownOperation, .inputBackpressure,
    ]
    for _ in 0..<Self.propertyIterations {
      let code = codes[Int(rng.nextUInt32(below: UInt32(codes.count)))]
      let sequence = rng.nextUInt64()
      let payload = rng.nextRawBytes(count: Int(rng.nextUInt32(below: 1_024)))

      let encoded = try LabptyFraming.encodeResponse(
        sequence: sequence,
        code: code,
        payload: payload)
      let decoded = try LabptyFraming.decode(encoded)
      XCTAssertEqual(decoded.header.operationRaw, LabptyFrameHeader.responseOperation)
      XCTAssertEqual(decoded.header.responseCode, code)
      XCTAssertEqual(decoded.header.sequence, sequence)
      XCTAssertEqual(decoded.payload, payload)

      // The client-request decoder must reject response frames.
      XCTAssertThrowsError(try LabptyFraming.decodeClientRequest(encoded)) { error in
        XCTAssertEqual(error as? LabptyProtocolError, .invalidResponseOperation)
      }
    }
  }

  // MARK: - Fuzz: arbitrary bytes never trap

  /// The decoders sit at the daemon's trust boundary; arbitrary bytes
  /// must either decode or surface as `LabptyProtocolError`. Any other
  /// failure mode (precondition trap, fatalError, integer overflow) is
  /// a remote-input crash.
  func testDecodersTolerateArbitraryBytesWithoutTrapping() {
    var rng = SplitMix64(seed: 0xA1B2_C3D4_E5F6_070D)
    for _ in 0..<Self.fuzzIterations {
      let len = Int(rng.nextUInt32(below: 4_096))
      let blob = rng.nextRawBytes(count: len)

      assertDoesNotTrapOrThrowsProtocolError { _ = try LabptyHelloRequest.decode(from: blob) }
      assertDoesNotTrapOrThrowsProtocolError { _ = try LabptyHelloResponse.decode(from: blob) }
      assertDoesNotTrapOrThrowsProtocolError { _ = try LabptyOpenSessionRequest.decode(from: blob) }
      assertDoesNotTrapOrThrowsProtocolError { _ = try LabptySessionDescriptor.decode(from: blob) }
      assertDoesNotTrapOrThrowsProtocolError { _ = try LabptyListSessionsResponse.decode(from: blob) }
      assertDoesNotTrapOrThrowsProtocolError { _ = try LabptyResizeSessionRequest.decode(from: blob) }
      assertDoesNotTrapOrThrowsProtocolError { _ = try LabptySignalSessionRequest.decode(from: blob) }
      assertDoesNotTrapOrThrowsProtocolError { _ = try LabptyTerminateSessionRequest.decode(from: blob) }
      assertDoesNotTrapOrThrowsProtocolError { _ = try LabptyWriteInputRequest.decode(from: blob) }
      assertDoesNotTrapOrThrowsProtocolError { _ = try LabptyPingResponse.decode(from: blob) }
      assertDoesNotTrapOrThrowsProtocolError { _ = try LabptyFraming.decode(blob) }
      assertDoesNotTrapOrThrowsProtocolError { _ = try LabptyFraming.decodeClientRequest(blob) }
    }
  }

  /// Bit-mutate well-formed frames to reach paths the random fuzzer
  /// rarely hits (valid magic + valid lengths + invalid op codes,
  /// truncated payloads, oversize length fields).
  func testFrameDecoderMutationFuzz() throws {
    var rng = SplitMix64(seed: 0xA1B2_C3D4_E5F6_070E)
    for _ in 0..<Self.fuzzIterations {
      let payload = rng.nextRawBytes(count: Int(rng.nextUInt32(below: 256)))
      var encoded = try LabptyFraming.encodeRequest(
        operation: .ping,
        sequence: rng.nextUInt64(),
        payload: payload)

      let flipCount = Int(rng.nextUInt32(below: 4)) + 1
      for _ in 0..<flipCount {
        let index = Int(rng.nextUInt32(below: UInt32(encoded.count)))
        encoded[index] ^= UInt8(rng.nextUInt32(below: 256))
      }

      assertDoesNotTrapOrThrowsProtocolError { _ = try LabptyFraming.decode(encoded) }
      assertDoesNotTrapOrThrowsProtocolError {
        _ = try LabptyFraming.decodeClientRequest(encoded)
      }
    }
  }

  // MARK: - Encoder limit enforcement

  func testEncoderRejectsOversizeWriteInput() {
    let oversize = Data(repeating: 0xCD, count: LabptyProtocolLimits.maxWriteInputBytes + 1)
    XCTAssertThrowsError(
      try LabptyWriteInputRequest(ptyHandle: 1, bytes: oversize).encode()
    ) { error in
      XCTAssertEqual(error as? LabptyProtocolError, .payloadTooLarge("write_input"))
    }
  }

  func testEncoderRejectsOversizeSessionList() {
    let descriptor = LabptySessionDescriptor(
      ptyHandle: 1, childPid: 1, rows: 24, cols: 80, alive: true,
      logicalSessionId: "x", byteRingShmPath: "/tmp/x",
      outputRingCapacity: 4096)
    let oversize = LabptyListSessionsResponse(
      sessions: Array(
        repeating: descriptor,
        count: LabptyProtocolLimits.maxSessionDescriptorCount + 1))
    XCTAssertThrowsError(try oversize.encode()) { error in
      XCTAssertEqual(error as? LabptyProtocolError, .payloadTooLarge("sessions"))
    }
  }

  func testFrameEncoderRejectsOversizePayload() {
    let oversize = Data(
      repeating: 0xAA,
      count: LabptyFrameHeader.maxFrameBytes - LabptyFrameHeader.headerByteCount + 1)
    XCTAssertThrowsError(
      try LabptyFraming.encodeRequest(operation: .ping, sequence: 0, payload: oversize)
    ) { error in
      XCTAssertEqual(error as? LabptyProtocolError, .oversizeFrame)
    }
  }

  // MARK: - Bounds sweep

  /// Hand-picked extremes that random generators rarely hit cleanly:
  /// zero-length, one-byte, near-limit values. Catches off-by-one in
  /// length prefixes without paying for a 10k-iteration random pass.
  func testWriteInputBoundsSweep() throws {
    let handles: [UInt64] = [0, 1, UInt64.max]
    let sizes: [Int] = [0, 1, 4_095, LabptyProtocolLimits.maxWriteInputBytes]
    for handle in handles {
      for size in sizes {
        let message = LabptyWriteInputRequest(
          ptyHandle: handle,
          bytes: Data(repeating: 0x55, count: size))
        let decoded = try LabptyWriteInputRequest.decode(from: try message.encode())
        XCTAssertEqual(decoded, message, "handle=\(handle) size=\(size)")
      }
    }
  }

  func testResizeBoundsSweep() throws {
    let extremes: [UInt32] = [0, 1, 24, 4_096, UInt32.max]
    for rows in extremes {
      for cols in extremes {
        let message = LabptyResizeSessionRequest(ptyHandle: 7, rows: rows, cols: cols)
        XCTAssertEqual(try LabptyResizeSessionRequest.decode(from: message.encode()), message)
      }
    }
  }

  // MARK: - Helpers

  private func assertDoesNotTrapOrThrowsProtocolError(
    file: StaticString = #file,
    line: UInt = #line,
    _ body: () throws -> Void
  ) {
    do {
      try body()
    } catch is LabptyProtocolError {
      // Expected: structured rejection.
    } catch {
      XCTFail("decoder threw non-protocol error \(type(of: error)): \(error)", file: file, line: line)
    }
  }
}

// MARK: - Deterministic generator

/// Minimal SplitMix64 PRNG so property tests reproduce from a fixed
/// seed without pulling in a test dependency. Not cryptographic.
private struct SplitMix64: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    self.state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z &>> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z &>> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z &>> 31)
  }

  mutating func nextUInt16() -> UInt16 { UInt16(truncatingIfNeeded: next()) }
  mutating func nextUInt32() -> UInt32 { UInt32(truncatingIfNeeded: next()) }
  mutating func nextUInt64() -> UInt64 { next() }

  /// Uniform-ish in [0, bound). `bound` must be > 0.
  mutating func nextUInt32(below bound: UInt32) -> UInt32 {
    precondition(bound > 0)
    return UInt32(truncatingIfNeeded: next() % UInt64(bound))
  }

  mutating func nextRawBytes(count: Int) -> Data {
    var data = Data(count: count)
    data.withUnsafeMutableBytes { buffer in
      guard let base = buffer.baseAddress else { return }
      var index = 0
      while index + 8 <= count {
        var word = next()
        _ = withUnsafeBytes(of: &word) { wordBytes in
          memcpy(base.advanced(by: index), wordBytes.baseAddress, 8)
        }
        index += 8
      }
      if index < count {
        var word = next()
        _ = withUnsafeBytes(of: &word) { wordBytes in
          memcpy(base.advanced(by: index), wordBytes.baseAddress, count - index)
        }
      }
    }
    return data
  }

  /// Valid UTF-8 string with bounded byte length. ASCII-only so the
  /// generator can guarantee byte-length budget regardless of how
  /// multi-byte boundaries fall; the C-side decoders' UTF-8 validator
  /// rejects more than the Swift decoder does, so Swift-only property
  /// tests stay in the ASCII intersection.
  mutating func nextString(maxBytes: Int) -> String {
    guard maxBytes > 0 else { return "" }
    let len = Int(nextUInt32(below: UInt32(min(maxBytes, 32) + 1)))
    if len == 0 { return "" }
    var bytes = [UInt8]()
    bytes.reserveCapacity(len)
    for _ in 0..<len {
      // Printable ASCII excluding NUL — Swift accepts embedded NUL but
      // the daemon's C decoder rejects it via memchr, so the safe
      // intersection is printable ASCII.
      let value = UInt8(0x20 + Int(nextUInt32(below: 0x5F)))
      bytes.append(value)
    }
    return String(decoding: bytes, as: UTF8.self)
  }

  mutating func nextStringArray(maxCount: Int, maxBytesPerEntry: Int) -> [String] {
    guard maxCount > 0 else { return [] }
    let count = Int(nextUInt32(below: UInt32(min(maxCount, 8) + 1)))
    return (0..<count).map { _ in nextString(maxBytes: maxBytesPerEntry) }
  }

  mutating func nextSessionDescriptor() -> LabptySessionDescriptor {
    LabptySessionDescriptor(
      ptyHandle: nextUInt64(),
      childPid: Int32(bitPattern: nextUInt32()),
      rows: nextUInt32(),
      cols: nextUInt32(),
      alive: (next() & 1) == 1,
      logicalSessionId: nextString(maxBytes: LabptyProtocolLimits.maxLogicalSessionIdBytes),
      byteRingShmPath: nextString(maxBytes: min(LabptyProtocolLimits.maxByteRingPathBytes, 128)),
      outputRingCapacity: nextUInt64(),
      inputRingCapacity: nextUInt64())
  }
}
