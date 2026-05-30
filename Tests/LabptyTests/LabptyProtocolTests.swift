import Foundation
import XCTest

@testable import LabanCore

final class LabptyProtocolTests: XCTestCase {
  func testLabptyProtocolRoundTrip() throws {
    let hello = LabptyHelloRequest(
      clientId: "test-client",
      capabilities: LabptyCapabilities.phase1)
    XCTAssertEqual(try LabptyHelloRequest.decode(from: hello.encode()), hello)

    let open = LabptyOpenSessionRequest(
      rows: 30,
      cols: 120,
      argv: ["/bin/sh", "-c", "printf STARTED"],
      envp: ["TERM=xterm-256color"],
      cwd: "/tmp",
      logicalSessionId: "logical-1")
    XCTAssertEqual(try LabptyOpenSessionRequest.decode(from: open.encode()), open)

    let descriptor = LabptySessionDescriptor(
      ptyHandle: 42,
      childPid: 1234,
      rows: 30,
      cols: 120,
      alive: true,
      logicalSessionId: "logical-1",
      byteRingShmPath: "/tmp/labpty-ring",
      outputRingCapacity: UInt64(LabptyByteRingLayout.defaultOutputRingCapacity))
    XCTAssertEqual(try LabptySessionDescriptor.decode(from: descriptor.encode()), descriptor)

    let list = LabptyListSessionsResponse(sessions: [descriptor])
    XCTAssertEqual(try LabptyListSessionsResponse.decode(from: list.encode()), list)

    let resize = LabptyResizeSessionRequest(ptyHandle: 42, rows: 40, cols: 132)
    XCTAssertEqual(try LabptyResizeSessionRequest.decode(from: resize.encode()), resize)

    let signal = LabptySignalSessionRequest(ptyHandle: 42, signal: 2)
    XCTAssertEqual(try LabptySignalSessionRequest.decode(from: signal.encode()), signal)

    let terminate = LabptyTerminateSessionRequest(ptyHandle: 42)
    XCTAssertEqual(try LabptyTerminateSessionRequest.decode(from: terminate.encode()), terminate)

    let write = LabptyWriteInputRequest(ptyHandle: 42, bytes: Data("ping\n".utf8))
    XCTAssertEqual(try LabptyWriteInputRequest.decode(from: write.encode()), write)

    let ping = LabptyPingResponse(daemonMonoNs: 999)
    XCTAssertEqual(try LabptyPingResponse.decode(from: ping.encode()), ping)
  }

  func testFixedShapePayloadDecodersTolerateTrailingAdditiveBytes() throws {
    let additiveTail = Data([0xA5, 0x5A, 0xC3, 0x3C])
    func payloadWithTail(_ payload: Data) -> Data {
      var payload = payload
      payload.append(additiveTail)
      return payload
    }

    let hello = LabptyHelloRequest(
      clientId: "test-client",
      capabilities: LabptyCapabilities.phase1)
    XCTAssertEqual(try LabptyHelloRequest.decode(from: payloadWithTail(try hello.encode())), hello)

    let helloResponse = LabptyHelloResponse(
      capabilities: LabptyCapabilities.phase1,
      daemonMonoNs: 0x0102_0304_0506_0708)
    XCTAssertEqual(
      try LabptyHelloResponse.decode(from: payloadWithTail(try helloResponse.encode())),
      helloResponse)

    let open = LabptyOpenSessionRequest(
      rows: 30,
      cols: 120,
      argv: ["/bin/sh", "-c", "printf STARTED"],
      envp: ["TERM=xterm-256color"],
      cwd: "/tmp",
      logicalSessionId: "logical-1")
    XCTAssertEqual(try LabptyOpenSessionRequest.decode(from: payloadWithTail(try open.encode())), open)

    let descriptor = LabptySessionDescriptor(
      ptyHandle: 42,
      childPid: 1234,
      rows: 30,
      cols: 120,
      alive: true,
      logicalSessionId: "logical-1",
      byteRingShmPath: "/tmp/labpty-ring",
      outputRingCapacity: UInt64(LabptyByteRingLayout.defaultOutputRingCapacity))
    XCTAssertEqual(
      try LabptySessionDescriptor.decode(from: payloadWithTail(try descriptor.encode())),
      descriptor)

    let list = LabptyListSessionsResponse(sessions: [descriptor])
    XCTAssertEqual(
      try LabptyListSessionsResponse.decode(from: payloadWithTail(try list.encode())),
      list)

    let resize = LabptyResizeSessionRequest(ptyHandle: 42, rows: 40, cols: 132)
    XCTAssertEqual(try LabptyResizeSessionRequest.decode(from: payloadWithTail(resize.encode())), resize)

    let signal = LabptySignalSessionRequest(ptyHandle: 42, signal: 2)
    XCTAssertEqual(try LabptySignalSessionRequest.decode(from: payloadWithTail(signal.encode())), signal)

    let terminate = LabptyTerminateSessionRequest(ptyHandle: 42)
    XCTAssertEqual(
      try LabptyTerminateSessionRequest.decode(from: payloadWithTail(terminate.encode())),
      terminate)

    let ping = LabptyPingResponse(daemonMonoNs: 999)
    XCTAssertEqual(try LabptyPingResponse.decode(from: payloadWithTail(ping.encode())), ping)
  }

  func testPayloadReaderHandlesSlicedData() throws {
    // L7: LabptyPayloadReader indexed its backing Data absolutely, so a
    // slice (Data.SubSequence == Data keeps a non-zero startIndex) trapped
    // on the first byte. It must now read a slice correctly.
    let prefixed = Data([0xAA, 0xBB]) + Data([0x01, 0x02, 0x03, 0x04])
    var reader = LabptyPayloadReader(prefixed.dropFirst(2))  // startIndex == 2
    XCTAssertEqual(reader.remainingCount, 4)
    XCTAssertEqual(try reader.readUInt8(), 0x01)
    XCTAssertEqual(try reader.readUInt8(), 0x02)
    XCTAssertEqual(try reader.readUInt16(), 0x0403)  // little-endian 03 04
    XCTAssertEqual(reader.remainingCount, 0)
  }

  func testFrameRoundTrip() throws {
    let payload = try LabptyWriteInputRequest(ptyHandle: 7, bytes: Data([1, 2, 3])).encode()
    let encoded = try LabptyFraming.encodeRequest(
      operation: .writeInput,
      sequence: 123,
      payload: payload)
    let decoded = try LabptyFraming.decodeClientRequest(encoded)

    XCTAssertEqual(decoded.header.operation, .writeInput)
    XCTAssertEqual(decoded.header.responseCode, .ok)
    XCTAssertEqual(decoded.header.sequence, 123)
    XCTAssertEqual(decoded.header.frameLength, UInt32(LabptyFrameHeader.headerByteCount + payload.count))
    XCTAssertEqual(try LabptyWriteInputRequest.decode(from: decoded.payload).bytes, Data([1, 2, 3]))
  }

  func testFrameHeaderGoldenBytes() throws {
    let encoded = try LabptyFraming.encodeRequest(
      operation: .hello,
      sequence: 0x0102_0304_0506_0708,
      payload: Data([0xAA, 0xBB]))

    XCTAssertEqual(
      [UInt8](encoded),
      [
        0x4C, 0x50, 0x43, 0x54,  // LPCT
        0x01, 0x00,  // ABI major
        0x00, 0x00,  // ABI minor
        0x1A, 0x00, 0x00, 0x00,  // 24-byte header + 2-byte payload
        0x01, 0x00,  // hello
        0x00, 0x00,  // ok
        0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
        0xAA, 0xBB,
      ])
  }

  func testHelloPayloadGoldenBytes() throws {
    XCTAssertEqual(
      [UInt8](try LabptyHelloRequest(clientId: "c", capabilities: []).encode()),
      [
        0x01, 0x00,
        0x00, 0x00,
        0x01, 0x00, 0x00, 0x00, 0x63,
        0x00, 0x00, 0x00, 0x00,
      ])

    XCTAssertEqual(
      [UInt8](
        try LabptyHelloResponse(
          capabilities: [],
          daemonMonoNs: 0x0102_0304_0506_0708).encode()),
      [
        0x01, 0x00,
        0x00, 0x00,
        0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
        0x00, 0x00, 0x00, 0x00,
      ])
  }

  func testSequenceNumberEcho() throws {
    let response = try LabptyFraming.encodeResponse(
      sequence: 88,
      code: .ok,
      payload: LabptyPingResponse(daemonMonoNs: 100).encode())
    let decoded = try LabptyFraming.decode(response)

    XCTAssertEqual(decoded.header.operationRaw, LabptyFrameHeader.responseOperation)
    XCTAssertEqual(decoded.header.responseCode, .ok)
    XCTAssertEqual(decoded.header.sequence, 88)
  }

  func testFrameMagicRequired() throws {
    var encoded = try LabptyFraming.encodeRequest(operation: .ping, sequence: 1)
    encoded[0] = 0

    XCTAssertThrowsError(try LabptyFraming.decode(encoded)) { error in
      XCTAssertEqual(error as? LabptyProtocolError, .badMagic)
    }
  }

  func testFrameDecoderRejectsOversizeFrame() throws {
    var encoded = try LabptyFraming.encodeRequest(operation: .ping, sequence: 1)
    encoded[8] = 0x01
    encoded[9] = 0x00
    encoded[10] = 0x03
    encoded[11] = 0x00

    XCTAssertThrowsError(try LabptyFraming.decode(encoded)) { error in
      XCTAssertEqual(error as? LabptyProtocolError, .oversizeFrame)
    }
  }

  func testFrameDecoderRejectsTruncatedPayload() throws {
    var encoded = try LabptyFraming.encodeRequest(operation: .ping, sequence: 1)
    encoded.append(0)

    XCTAssertThrowsError(try LabptyFraming.decode(encoded)) { error in
      XCTAssertEqual(error as? LabptyProtocolError, .truncatedFrame)
    }
  }

  func testClientCannotSendResponseOp() throws {
    let encoded = try LabptyFraming.encodeResponse(sequence: 1, code: .ok)

    XCTAssertThrowsError(try LabptyFraming.decodeClientRequest(encoded)) { error in
      XCTAssertEqual(error as? LabptyProtocolError, .invalidResponseOperation)
    }
  }

  func testByteRingHeaderConstants() {
    XCTAssertEqual(LabptyByteRingLayout.magic, Array("LBPTY-BR".utf8))
    XCTAssertEqual(LabptyByteRingLayout.headerBytes, 128)
    XCTAssertEqual(LabptyByteRingLayout.countersOffset, 128)
    XCTAssertEqual(LabptyByteRingLayout.readerSlotOffset, 256)
    XCTAssertEqual(LabptyByteRingLayout.readerSlotBytes, 64)
    XCTAssertEqual(LabptyByteRingLayout.readerSlotCount, 8)
    XCTAssertEqual(LabptyByteRingLayout.inputRingOffset, 768)
    XCTAssertEqual(LabptyByteRingLayout.phase1InputRingCapacity, 0)
    XCTAssertTrue(
      LabptyByteRingLayout.validateOutputCapacity(
        UInt64(LabptyByteRingLayout.defaultOutputRingCapacity)))
    XCTAssertFalse(LabptyByteRingLayout.validateOutputCapacity(12345))
  }

  func testWriteInputPayloadFromFrameLen() throws {
    let payload = try LabptyWriteInputRequest(ptyHandle: 42, bytes: Data("abc".utf8)).encode()

    // u64 handle + u32 input_len + bytes — the input_len prefix
    // gates the additive trailer per ADR 0007.
    XCTAssertEqual(payload.count, 8 + 4 + 3)
    XCTAssertEqual(try LabptyWriteInputRequest.decode(from: payload).bytes, Data("abc".utf8))
  }

  func testListSessionsRecordIgnoresAdditiveTrailer() throws {
    // Two real descriptors back-to-back. The first carries a
    // hypothetical future trailer inside its record_len; the
    // decoder must read only the known descriptor bytes and skip
    // the trailer, leaving the second descriptor's framing intact.
    let first = LabptySessionDescriptor(
      ptyHandle: 1,
      childPid: 100,
      rows: 24,
      cols: 80,
      alive: true,
      logicalSessionId: "a",
      byteRingShmPath: "/tmp/a.br",
      outputRingCapacity: 4096,
      inputRingCapacity: 4096)
    let second = LabptySessionDescriptor(
      ptyHandle: 2,
      childPid: 101,
      rows: 24,
      cols: 80,
      alive: true,
      logicalSessionId: "b",
      byteRingShmPath: "/tmp/b.br",
      outputRingCapacity: 4096,
      inputRingCapacity: 4096)

    var payload = LabptyPayloadWriter()
    payload.appendUInt32(2)

    let firstRecord = try first.encode()
    var firstFuture = LabptyPayloadWriter()
    firstFuture.appendUInt64(0xfeed_face_cafe_beef)
    let firstAugmented = firstRecord + firstFuture.data
    payload.appendUInt32(UInt32(firstAugmented.count))
    payload.appendBytes(firstAugmented)

    let secondRecord = try second.encode()
    payload.appendUInt32(UInt32(secondRecord.count))
    payload.appendBytes(secondRecord)

    let decoded = try LabptyListSessionsResponse.decode(from: payload.data)
    XCTAssertEqual(decoded.sessions.map(\.ptyHandle), [1, 2])
    XCTAssertEqual(decoded.sessions[0].logicalSessionId, "a")
    XCTAssertEqual(decoded.sessions[1].logicalSessionId, "b")
  }

  func testWriteInputDecoderIgnoresAdditiveTail() throws {
    // Encode a normal request, then append a hypothetical future
    // field (a u32 + a 4-byte tag) after the payload. The decoder
    // must reconstruct the original byte payload and drop the
    // trailer — the property that makes WRITE_INPUT additive.
    let original = try LabptyWriteInputRequest(
      ptyHandle: 99, bytes: Data("typed\n".utf8)).encode()

    var future = original
    var trailer = LabptyPayloadWriter()
    trailer.appendUInt32(4)
    trailer.appendBytes(Data("META".utf8))
    future.append(trailer.data)

    let decoded = try LabptyWriteInputRequest.decode(from: future)
    XCTAssertEqual(decoded.ptyHandle, 99)
    XCTAssertEqual(decoded.bytes, Data("typed\n".utf8))
  }

  func testTerminatePayloadShape() {
    XCTAssertEqual(LabptyTerminateSessionRequest(ptyHandle: 42).encode().count, 8)
  }
}
