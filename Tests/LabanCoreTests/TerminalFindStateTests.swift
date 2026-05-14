import LabanTerminalCore
import XCTest

@testable import LabanCore

final class TerminalFindStateTests: XCTestCase {
  func testStartFindCreatesActiveState() throws {
    let model = try makeModel(rows: 5, cols: 40)
    let session = try XCTUnwrap(model.session(forTab: model.tabs[0].id))
    session.write(Array("apple banana apple\r\n".utf8))
    session.poll()

    let state = try XCTUnwrap(model.startFind(sessionID: session.id, needle: "apple"))

    XCTAssertTrue(state.isActive)
    XCTAssertEqual(state.needle, "apple")
    XCTAssertEqual(state.total, 2)
    XCTAssertEqual(state.selectedIndex, 0)
  }

  func testUpdateNeedleRefreshesMatches() throws {
    let model = try makeModel(rows: 5, cols: 40)
    let session = try XCTUnwrap(model.session(forTab: model.tabs[0].id))
    session.write(Array("apple banana\r\n".utf8))
    session.poll()
    _ = model.startFind(sessionID: session.id, needle: "apple")

    let state = try XCTUnwrap(model.updateFindNeedle(sessionID: session.id, needle: "banana"))

    XCTAssertEqual(state.needle, "banana")
    XCTAssertEqual(state.matches.map(\.startColumn), [6])
  }

  func testPendingNeedleUpdateDefersMatchRefreshUntilStep() throws {
    let model = try makeModel(rows: 5, cols: 40)
    let session = try XCTUnwrap(model.session(forTab: model.tabs[0].id))
    session.write(Array("apple banana\r\n".utf8))
    session.poll()
    _ = model.startFind(sessionID: session.id, needle: "apple")

    let pending = try XCTUnwrap(model.setFindNeedlePending(sessionID: session.id, needle: "banana"))

    XCTAssertEqual(pending.needle, "banana")
    XCTAssertEqual(pending.total, 0)
    XCTAssertNil(pending.selectedIndex)

    let stepped = try XCTUnwrap(model.stepFind(sessionID: session.id, direction: .next))
    XCTAssertEqual(stepped.needle, "banana")
    XCTAssertEqual(stepped.matches.map(\.startColumn), [6])
    XCTAssertEqual(stepped.selectedIndex, 0)
  }

  func testIdleNeedleRefreshSelectsFirstMatchAndScrollsToIt() throws {
    let model = try makeModel(rows: 5, cols: 40)
    let session = try XCTUnwrap(model.session(forTab: model.tabs[0].id))
    var output = "target first\r\n"
    for line in 0..<40 {
      output += "filler \(line)\r\n"
    }
    session.write(Array(output.utf8))
    session.poll()
    let startOffset = try XCTUnwrap(session.viewportState()).viewportOffset
    XCTAssertGreaterThan(startOffset, 0)

    _ = model.startFind(sessionID: session.id)
    _ = model.setFindNeedlePending(sessionID: session.id, needle: "target")
    let state = try XCTUnwrap(
      model.updateFindNeedle(
        sessionID: session.id,
        needle: "target",
        scrollSelectedIntoView: true
      ))

    XCTAssertEqual(state.selectedIndex, 0)
    XCTAssertEqual(state.matches.first?.row, 0)
    XCTAssertEqual(session.viewportState()?.viewportOffset, 0)
  }

  func testStepWrapsInBothDirections() throws {
    let model = try makeModel(rows: 5, cols: 40)
    let session = try XCTUnwrap(model.session(forTab: model.tabs[0].id))
    session.write(Array("apple apple\r\n".utf8))
    session.poll()
    _ = model.startFind(sessionID: session.id, needle: "apple")

    XCTAssertEqual(model.stepFind(sessionID: session.id, direction: .previous)?.selectedIndex, 1)
    XCTAssertEqual(model.stepFind(sessionID: session.id, direction: .next)?.selectedIndex, 0)
  }

  func testStopRestoresViewportOffsetAfterStepScrolls() throws {
    let model = try makeModel(rows: 6, cols: 40)
    let session = try XCTUnwrap(model.session(forTab: model.tabs[0].id))
    var output = ""
    for line in 0..<80 {
      output += line == 1 || line == 79 ? "target \(line)\r\n" : "line \(line)\r\n"
    }
    session.write(Array(output.utf8))
    session.poll()

    let startOffset = try XCTUnwrap(session.viewportState()).viewportOffset
    _ = model.startFind(sessionID: session.id, needle: "target")
    _ = model.stepFind(sessionID: session.id, direction: .next)
    _ = model.stepFind(sessionID: session.id, direction: .previous)
    XCTAssertNotEqual(session.viewportState()?.viewportOffset, startOffset)

    _ = model.stopFind(sessionID: session.id)

    XCTAssertEqual(session.viewportState()?.viewportOffset, startOffset)
    XCTAssertFalse(model.findState(forSession: session.id).isActive)
  }

  func testVisibleRefreshDoesNotRescanNewScrollbackRows() throws {
    let model = try makeModel(rows: 3, cols: 40)
    let session = try XCTUnwrap(model.session(forTab: model.tabs[0].id))
    _ = model.startFind(sessionID: session.id, needle: "newhistory")

    session.write(Array("newhistory\r\nline 1\r\nline 2\r\nline 3\r\nline 4\r\n".utf8))
    session.poll()
    let snapshot = try XCTUnwrap(session.snapshot())
    defer { laban_snapshot_destroy(snapshot) }

    let viewportOffset = try XCTUnwrap(session.viewportState()).viewportOffset
    model.refreshFindVisible(
      sessionID: session.id,
      snapshot: UnsafePointer(snapshot),
      viewportOffset: viewportOffset
    )

    XCTAssertEqual(model.findState(forSession: session.id).total, 0)
  }

  private func makeModel(rows: Int32, cols: Int32) throws -> AppModel {
    var size = LabanTerminalSize()
    size.rows = rows
    size.cols = cols
    return try AppModel(initialSize: size, sessionFactory: Session.fixture)
  }
}
