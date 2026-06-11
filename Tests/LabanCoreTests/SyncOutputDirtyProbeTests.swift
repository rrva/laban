import LabanTerminalCore
import XCTest

@testable import LabanCore

/// Probe: what does the session report DURING an active synchronized-output
/// burst (DEC mode 2026 begun, not yet ended)? This is the pivotal fact for the
/// "Claude Code progress bar freezes until I scroll" stall. Laban's render loop
/// defers rendering while `synchronizedOutputActive` is true; whether the held
/// frame keeps the display link alive (self-healing at the 1s sync watchdog) or
/// lets it park (frozen until external input) depends entirely on whether
/// `renderDirty()` is true or false in this state.
///
/// These tests only OBSERVE and print; they assert the minimum so the harness
/// fails loudly if the API shape changes.
final class SyncOutputDirtyProbeTests: XCTestCase {

  private func feed(_ s: Session, _ raw: String) {
    s.write(Array(raw.utf8))
  }

  func testRenderDirtyAndSyncStateMidBurst() throws {
    var size = LabanTerminalSize()
    size.rows = 40
    size.cols = 108
    let s = try Session.fixture(size: size)

    // Establish a clean baseline render.
    feed(s, "hello\r\n")
    XCTAssertTrue(s.renderDirty(), "fresh output should be dirty")
    s.markRendered()
    XCTAssertFalse(s.renderDirty(), "after markRendered the frame is clean")
    let genBaseline = s.dirtyGeneration()

    // One real Claude-Code-style spinner tick, but SPLIT: deliver only up to the
    // begin-sync + the visible write, withholding the matching `?2026l`. This is
    // the PTY-chunk-boundary-falls-mid-burst case.
    feed(
      s,
      "\u{1b}[?2026h\u{1b}[?25l\u{1b}[H\r\u{1b}[28B"
        + "\u{1b}[38;2;215;119;87m\u{2722}\u{1b}[3GBoondoggling\u{2026}"
    )

    let dirtyMidSync = s.renderDirty()
    let syncActiveMidSync = s.synchronizedOutputActive
    let genMidSync = s.dirtyGeneration()

    print(
      "[PROBE] mid-sync: renderDirty=\(dirtyMidSync)"
        + " synchronizedOutputActive=\(syncActiveMidSync)"
        + " genAdvanced=\(genMidSync != genBaseline) (\(genBaseline)->\(genMidSync))"
    )

    // Now deliver the matching end-sync in a separate chunk (next poll).
    feed(s, "\u{1b}[39;1H\u{1b}[32;3H\u{1b}[?25h\u{1b}[?2026l")
    let dirtyAfterEnd = s.renderDirty()
    let syncActiveAfterEnd = s.synchronizedOutputActive
    print(
      "[PROBE] after end-sync: renderDirty=\(dirtyAfterEnd)"
        + " synchronizedOutputActive=\(syncActiveAfterEnd)"
    )

    // Minimal invariants that must hold regardless of the dirty answer:
    XCTAssertTrue(syncActiveMidSync, "mode 2026h must register as active sync output")
    XCTAssertFalse(syncActiveAfterEnd, "mode 2026l must clear sync output")
    XCTAssertTrue(genMidSync != genBaseline, "the spinner write must advance the dirty generation")
  }
}
