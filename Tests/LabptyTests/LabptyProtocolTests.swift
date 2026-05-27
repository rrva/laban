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
      foregroundPid: 1234,
      foregroundPgid: 1234,
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
      foregroundPid: 1234,
      foregroundPgid: 1234,
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

    XCTAssertEqual(payload.count, 8 + 3)
    XCTAssertEqual(try LabptyWriteInputRequest.decode(from: payload).bytes, Data("abc".utf8))
  }

  func testTerminatePayloadShape() {
    XCTAssertEqual(LabptyTerminateSessionRequest(ptyHandle: 42).encode().count, 8)
  }
}
