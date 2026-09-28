import Foundation
import LabanCore
import XCTest

@testable import LabanDebug

final class DebugRuntimeLogsTests: XCTestCase {
  func testEventsAndInputsAssignSequencesAndFilterBySince() {
    var logs = DebugRuntimeLogStore()

    logs.appendEvent(EventEntry(kind: "first"))
    logs.appendEvent(EventEntry(kind: "second", tabId: "tab-2"))

    let events = logs.eventsResponse(since: 1)
    XCTAssertEqual(events.next, 2)
    XCTAssertEqual(events.events.map(\.kind), ["second"])
    XCTAssertEqual(events.events.first?.tabId, "tab-2")

    let recorded = logs.appendInputEnvelope(
      InputEventEnvelope(
        inputId: "input-1",
        source: "debug",
        kind: "text",
        route: "terminal",
        frameBefore: 3,
        text: "hello"
      ))
    XCTAssertEqual(recorded.seq, 0)

    let inputs = logs.inputLogResponse(since: 0)
    XCTAssertEqual(inputs.next, 1)
    XCTAssertEqual(inputs.events.first?.seq, 0)
    XCTAssertEqual(inputs.events.first?.text, "hello")
  }

  func testTerminalLogTracksByteCountersAndSessionFiltering() {
    var logs = DebugRuntimeLogStore()

    logs.appendTerminalLog(sessionId: "s1", direction: "input", bytes: [0x1B, 0x41], frame: 7)
    logs.appendTerminalLog(sessionId: "s2", direction: "output", bytes: Array("ok".utf8), frame: 8)

    XCTAssertEqual(logs.terminalBytes.input, 2)
    XCTAssertEqual(logs.terminalBytes.output, 2)

    let filtered = logs.terminalLogResponse(query: ["sessionId": "s1"], defaultSessionId: nil)
    XCTAssertEqual(filtered.next, 2)
    XCTAssertEqual(filtered.events.count, 1)
    XCTAssertEqual(filtered.events.first?.sessionId, "s1")
    XCTAssertEqual(filtered.events.first?.escaped, "\\eA")
  }

  func testErrorsAssignSequences() {
    var logs = DebugRuntimeLogStore()

    logs.appendError(kind: "fixture.load", message: "bad path", tabId: "tab-1")

    let errors = logs.errorsResponse(since: 0)
    XCTAssertEqual(errors.next, 1)
    XCTAssertEqual(errors.errors.first?.seq, 0)
    XCTAssertEqual(errors.errors.first?.kind, "fixture.load")
    XCTAssertEqual(errors.errors.first?.tabId, "tab-1")
  }
}
