import LabanTerminalCore
import XCTest

@testable import LabanCore

/// Replays a REAL captured Claude Code PTY stream through a Session, chunked at
/// synchronized-output boundaries (the way a PTY poll splits a burst), and hunts
/// the render-side stall seam: a feed that advances the dirty generation (content
/// changed) while `renderDirty()` reports FALSE (the render loop would see
/// "nothing to draw" and park). That is the "progress bar freezes until I scroll"
/// signature, since scroll forces DIRTY_FULL and reveals the already-present text.
///
/// Set LABAN_TRACE to a pty-output.bin to replay; skips cleanly if absent so CI
/// without the capture stays green.
final class SyncTraceReplayProbeTests: XCTestCase {

  /// Split the stream into chunks that each END at a sync-output toggle, so the
  /// replay exercises both "ends mid-burst (2026h, no 2026l)" and "ends after
  /// 2026l" boundaries — the two ways a real PTY read can bisect Claude's frame.
  private func chunkAtSyncToggles(_ data: [UInt8]) -> [[UInt8]] {
    let h: [UInt8] = Array("\u{1b}[?2026h".utf8)
    let l: [UInt8] = Array("\u{1b}[?2026l".utf8)
    var chunks: [[UInt8]] = []
    var cur: [UInt8] = []
    var i = 0
    func matches(_ pat: [UInt8]) -> Bool {
      guard i + pat.count <= data.count else { return false }
      for k in 0..<pat.count where data[i + k] != pat[k] { return false }
      return true
    }
    while i < data.count {
      if matches(h) {
        cur.append(contentsOf: h)
        i += h.count
        chunks.append(cur)
        cur = []  // boundary AFTER begin-sync: ends mid-burst
      } else if matches(l) {
        cur.append(contentsOf: l)
        i += l.count
        chunks.append(cur)
        cur = []  // boundary AFTER end-sync
      } else {
        cur.append(data[i])
        i += 1
      }
    }
    if !cur.isEmpty { chunks.append(cur) }
    return chunks
  }

  func testReplayRealTraceHuntsDirtyMiss() throws {
    guard let path = ProcessInfo.processInfo.environment["LABAN_TRACE"],
      let data = FileManager.default.contents(atPath: path)
    else {
      throw XCTSkip("set LABAN_TRACE to a pty-output.bin to run the replay probe")
    }
    let bytes = [UInt8](data)
    var size = LabanTerminalSize()
    size.rows = 40
    size.cols = 108
    let s = try Session.fixture(size: size)

    let chunks = chunkAtSyncToggles(bytes)
    var prevGen = s.dirtyGeneration()
    var dirtyMissChunks = 0
    var stuckMidSyncEndingsThatStayedDirty = 0
    var firstMiss: (Int, UInt64, UInt64)? = nil

    // Model the loop's render opportunity: a render lands when sync is inactive
    // (or the 1s watchdog would reset it) and the frame is dirty. We mark-render
    // at every chunk where sync is inactive — the most GENEROUS render schedule.
    // Anything still mis-tracked under this generous schedule is a true seam.
    for (idx, chunk) in chunks.enumerated() {
      s.write(chunk)
      let gen = s.dirtyGeneration()
      let dirty = s.renderDirty()
      let sync = s.synchronizedOutputActive
      let genAdvanced = gen != prevGen
      if genAdvanced && !dirty && !sync {
        // content changed, sync NOT active, yet the visible frame is clean:
        // the render loop would park and never draw this update.
        dirtyMissChunks += 1
        if firstMiss == nil { firstMiss = (idx, prevGen, gen) }
      }
      if sync && dirty { stuckMidSyncEndingsThatStayedDirty += 1 }
      // Generous render: whenever sync is inactive, take the frame.
      if !sync { s.markRendered() }
      prevGen = gen
    }

    print(
      "[REPLAY] chunks=\(chunks.count)"
        + " dirtyMissChunks(genUp,!dirty,!sync)=\(dirtyMissChunks)"
        + " midSyncDirtyChunks=\(stuckMidSyncEndingsThatStayedDirty)"
    )
    if let firstMiss {
      print(
        "[REPLAY] first dirty-miss at chunk \(firstMiss.0) gen \(firstMiss.1)->\(firstMiss.2)"
      )
    }
    let finalDirty = s.renderDirty()
    let finalSync = s.synchronizedOutputActive
    print("[REPLAY] final: renderDirty=\(finalDirty) synchronizedOutputActive=\(finalSync)")

    // This probe is diagnostic; it should not fail the suite. It reports.
    XCTAssertGreaterThan(chunks.count, 0)
  }
}
