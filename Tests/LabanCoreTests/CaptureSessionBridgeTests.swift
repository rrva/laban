import Foundation
import LabanTerminalCore
import XCTest

@testable import LabanCore

final class CaptureSessionBridgeTests: XCTestCase {
  func testFixtureOutputBytesReachCaptureSink() throws {
    let sink = TestCaptureSink()
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let session = try Session.fixture(size: size)
    defer { session.close() }
    session.captureSink = sink
    session.setCaptureFrame(7)

    XCTAssertEqual(session.feedOutput(Array("abc".utf8)), 0)

    XCTAssertEqual(sink.byteEvents.count, 1)
    XCTAssertEqual(sink.byteEvents[0].direction, .ptyOutput)
    XCTAssertEqual(sink.byteEvents[0].sessionId, session.id)
    XCTAssertEqual(sink.byteEvents[0].frame, 7)
    XCTAssertEqual(sink.byteEvents[0].bytes, Array("abc".utf8))
  }

  func testCaptureCallbackStopsAfterSinkIsCleared() throws {
    let sink = TestCaptureSink()
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let session = try Session.fixture(size: size)
    defer { session.close() }

    session.captureSink = sink
    XCTAssertEqual(session.feedOutput(Array("a".utf8)), 0)
    XCTAssertEqual(sink.byteEvents.count, 1)

    session.captureSink = nil
    XCTAssertEqual(session.feedOutput(Array("b".utf8)), 0)
    XCTAssertEqual(sink.byteEvents.count, 1)
  }

  func testTabStatusCallbackStopsAfterHandlerIsCleared() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let session = try Session.fixture(size: size)
    defer { session.close() }

    var updates: [Session.TabStatusUpdate] = []
    session.onTabStatus = { updates.append($0) }
    XCTAssertEqual(session.feedOutput(Array("\u{1B}]21337;status=ok\u{07}".utf8)), 0)
    XCTAssertEqual(updates.map(\.status), ["ok"])

    session.onTabStatus = nil
    XCTAssertEqual(session.feedOutput(Array("\u{1B}]21337;status=stale\u{07}".utf8)), 0)
    XCTAssertEqual(updates.map(\.status), ["ok"])
  }

  func testRealPtyInputBytesReachCaptureSinkAfterWrite() throws {
    let sink = TestCaptureSink()
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let session: Session = try "/bin/cat".withCString { exe in
      var config = LabanLaunchConfig()
      config.fixture_mode = 0
      config.executable = exe
      return try Session(config: &config, size: size)
    }
    defer { session.close() }
    session.captureSink = sink
    session.setCaptureFrame(2)

    XCTAssertEqual(session.write(Array("x".utf8)), 0)
    for _ in 0..<20 {
      _ = session.poll()
      if sink.byteEvents.contains(where: { $0.direction == .ptyOutput }) { break }
      usleep(10_000)
    }

    XCTAssertTrue(
      sink.byteEvents.contains { $0.direction == .ptyInput && $0.bytes == Array("x".utf8) })
    XCTAssertTrue(sink.byteEvents.contains { $0.direction == .ptyOutput })
  }
}

private final class TestCaptureSink: CaptureSink {
  struct ByteEvent {
    var direction: CaptureByteDirection
    var sessionId: Session.ID?
    var frame: Int
    var bytes: [UInt8]
  }

  var sequence = 0
  var events: [CaptureTimelineEvent] = []
  var byteEvents: [ByteEvent] = []

  func nextSequence() -> Int {
    defer { sequence += 1 }
    return sequence
  }

  func record(_ event: CaptureTimelineEvent) {
    events.append(event)
  }

  func recordBytes(
    direction: CaptureByteDirection,
    sessionId: Session.ID?,
    frame: Int,
    bytes: UnsafeRawBufferPointer,
    preview: String?
  ) -> CaptureByteRef? {
    let array = bytes.bindMemory(to: UInt8.self).map { $0 }
    byteEvents.append(
      ByteEvent(direction: direction, sessionId: sessionId, frame: frame, bytes: array))
    return CaptureByteRef(
      stream: direction.rawValue,
      path: "streams/\(direction.streamFileName)",
      offset: 0,
      length: array.count,
      sha256: ""
    )
  }
}
