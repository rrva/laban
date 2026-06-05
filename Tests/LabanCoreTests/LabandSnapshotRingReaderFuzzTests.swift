import Foundation
import LabanTerminalCore
import XCTest

@testable import LabanCore

/// The `laband` snapshot ring is the sibling of the labpty byte ring: a reader
/// parses geometry and per-cell offsets out of shared memory a *separate*
/// process wrote. That is the exact untrusted-parse class where labpty's two
/// recent Swift bugs lived — a `Data`-slice trap (91e2676) and a misaligned
/// atomic-load SIGBUS (1efadf3). Both are uncatchable: a trap or SIGBUS kills
/// the process, so the only proof is to drive malformed input through the real
/// reader and require it never crashes.
///
/// Two harnesses, mirroring the labpty byte-ring tests:
///   - a broad seeded fuzz over byte mutations (regression net), and
///   - a structured-geometry test with teeth: a misaligned slot stride, a file
///     shorter than its map, and a file shorter than its slot span must each be
///     rejected *before* the reader dereferences a slot. Each case attaches and,
///     if the reader accepts, performs the read the guard was protecting, then
///     fails. Dropping the alignment guard makes that read a misaligned LDAR
///     that SIGBUSes (verified: signal 10); dropping a file-size guard lets the
///     reader accept a map it cannot fully back — a guaranteed SIGBUS on a
///     page-aligned ring, and the explicit failure here on this small one.
final class LabandSnapshotRingReaderFuzzTests: XCTestCase {

  // MARK: - Building a valid ring

  /// A real published ring: a session fixture, one snapshot, written through the
  /// production writer. Returns the writer's attachment and the file's bytes so
  /// callers can mutate a copy without touching the original mapping.
  private func validRing(rows: Int = 6, cols: Int = 24) throws -> (
    attachment: LabandSnapshotRingAttachment, bytes: [UInt8]
  ) {
    var size = LabanTerminalSize()
    size.rows = Int32(rows)
    size.cols = Int32(cols)
    let session = try Session.fixture(size: size)
    _ = session.write(Array("hello \u{1b}[31mworld\u{1b}[0m wide".utf8))
    _ = session.poll()
    let snap = try XCTUnwrap(session.snapshot())
    defer { laban_snapshot_destroy(snap) }

    let dir = ".tmp/laband-ring-fuzz-src-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: dir)) }
    let path = "\(dir)/ring.bin"
    let writer = try LabandSnapshotRingWriter(
      path: path,
      logicalSessionId: "fuzz",
      incarnationId: "inc",
      maxRows: rows,
      maxCols: cols)
    try writer.publish(snapshot: snap)
    let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
    return (writer.attachment, bytes)
  }

  /// Write `bytes` to a scratch file, attach a reader against `attachment` (path
  /// overridden to the scratch file), and drive every read entry point. Thrown
  /// errors are swallowed — rejection is a valid outcome; a crash is not. Returns
  /// true iff the reader attached (so callers can assert the fuzz is not vacuous).
  @discardableResult
  private func exercise(
    bytes: [UInt8],
    attachment base: LabandSnapshotRingAttachment,
    scratch path: String
  ) -> Bool {
    guard (try? Data(bytes).write(to: URL(fileURLWithPath: path))) != nil else { return false }
    var attachment = base
    attachment.path = path
    guard
      let reader = try? LabandSnapshotRingReader(
        attachment: attachment, logicalSessionId: "fuzz", incarnationId: "inc")
    else {
      return false
    }
    _ = try? reader.latestSnapshotFrame()
    _ = reader.generation()
    for row in 0..<3 {
      for col in 0..<3 {
        _ = try? reader.cell(row: row, col: col)
      }
    }
    return true
  }

  // MARK: - Reconnect / first-frame full repaint

  /// On (re)attach the consumer's persistent target is incoherent with the ring,
  /// whose newest slot carries only a per-publish dirty delta. The reader must
  /// report full damage (nil dirtyRanges) for the first served frame so the whole
  /// restored screen repaints, then resume the slot's incremental ranges.
  func testFreshReaderForcesFullDamageThenResumesIncremental() throws {
    let (base, bytes) = try validRing()
    let dir = ".tmp/laband-ring-firstframe-\(UUID().uuidString)"
    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: dir)) }
    let path = "\(dir)/ring.bin"
    try Data(bytes).write(to: URL(fileURLWithPath: path))
    var attachment = base
    attachment.path = path

    func attach() throws -> LabandSnapshotRingReader {
      try LabandSnapshotRingReader(
        attachment: attachment, logicalSessionId: "fuzz", incarnationId: "inc")
    }

    let reader = try attach()
    let first = try reader.latestSnapshotFrame()
    let second = try reader.latestSnapshotFrame()
    XCTAssertNil(first.dirtyRanges, "first frame after attach must force a full repaint")
    XCTAssertNotNil(
      second.dirtyRanges, "later frames resume the ring's incremental per-publish dirty ranges")
    XCTAssertEqual(
      first.generation, second.generation, "same latest slot — only the reported damage differs")

    // A reader re-created on reconnect/relaunch re-arms the forced full repaint.
    XCTAssertNil(
      try attach().latestSnapshotFrame().dirtyRanges,
      "a reconnect attaches a fresh reader, which must force a full repaint again")
  }

  // MARK: - Broad seeded fuzz (regression net)

  func testSnapshotRingReaderSurvivesAdversarialBytes() throws {
    let (attachment, valid) = try validRing()
    let dir = ".tmp/laband-ring-fuzz-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: dir)) }
    let scratch = "\(dir)/ring.bin"

    var state: UInt64 = 0x9e37_79b9_7f4a_7c15
    func next() -> UInt64 {
      state ^= state << 13
      state ^= state >> 7
      state ^= state << 17
      return state
    }

    var attachedCount = 0
    for _ in 0..<1400 {
      var bytes = valid
      let mutations = 1 + Int(next() % 8)
      for _ in 0..<mutations {
        let offset = Int(next() % UInt64(bytes.count))
        bytes[offset] = UInt8(next() & 0xff)
      }
      if exercise(bytes: bytes, attachment: attachment, scratch: scratch) {
        attachedCount += 1
      }
    }

    // Corruption mostly lands past the 64-byte file header, so most readers
    // attach and run the slot/cell parse — the path the guards protect. Zero
    // here would mean the fuzz is vacuously green (every input rejected at the
    // header before reaching readSlot/readCellText).
    XCTAssertGreaterThan(
      attachedCount, 0, "no mutated ring reached the slot/cell parse path")
  }

  // MARK: - Structured geometry (teeth)

  func testSnapshotRingReaderRejectsMisalignedAndShortGeometry() throws {
    let (attachment, valid) = try validRing()
    let dir = ".tmp/laband-ring-geom-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: dir)) }
    let scratch = "\(dir)/ring.bin"

    let stride = attachment.slotStride
    let slotCount = attachment.slotCount

    // Baseline: the valid ring still reads end to end. A guard that rejected
    // good geometry would surface here, not just in the negative cases.
    do {
      try Data(valid).write(to: URL(fileURLWithPath: scratch))
      var ok = attachment
      ok.path = scratch
      let reader = try LabandSnapshotRingReader(
        attachment: ok, logicalSessionId: "fuzz", incarnationId: "inc")
      let frame = try reader.latestSnapshotFrame()
      XCTAssertGreaterThan(frame.generation ?? 0, 0)
      XCTAssertFalse(frame.snapshot.visibleText.isEmpty)
    }

    // 1) Misaligned slot stride. Slots sit at `64 + index * stride`; 64 is
    // 8-aligned, so a stride of `stride + 4` misaligns slot 1 and the acquire
    // load of its seqlock would SIGBUS. Header field and attachment agree on the
    // bad stride and the file is padded to fit, so only the alignment guard can
    // reject it.
    let badStride = stride + 4
    expectRejectedBeforeRead(
      bytes: rebuiltForStride(valid, stride: badStride, slotCount: slotCount),
      attachment: attachment, scratch: scratch, reason: "misaligned slot stride"
    ) {
      $0.slotStride = badStride
      $0.fileBytes = 64 + slotCount * badStride
    }

    // 2) File shorter than its map. The attachment still claims the full
    // `fileBytes`, but the file on disk is one slot short. mmap succeeds past
    // EOF; a slot read in a page the file does not back SIGBUSes. The fstat
    // guard must refuse to map more than the file backs.
    expectRejectedBeforeRead(
      bytes: Array(valid.prefix(valid.count - stride)),
      attachment: attachment, scratch: scratch, reason: "file shorter than map"
    ) { _ in }

    // 3) File shorter than its slot span. The map covers only `slotCount - 1`
    // slots, but the reader still indexes `slotCount` of them; the last slot
    // read lands past the map. The slot-span guard must reject the inconsistency
    // before the reader trusts a `fileBytes` too small for its own slot count.
    let shortFileBytes = 64 + (slotCount - 1) * stride
    expectRejectedBeforeRead(
      bytes: Array(valid.prefix(shortFileBytes)),
      attachment: attachment, scratch: scratch, reason: "file shorter than slot span"
    ) {
      $0.fileBytes = shortFileBytes
    }
  }

  /// A slot advertises its own string-table size in its header, but the table
  /// only spans `slotStride - stringTableOffset` bytes. A hostile slot can claim
  /// the whole `UInt32` and point a cell far into that imaginary table; the
  /// reader's only bound is that claimed size, so without clamping to the real
  /// capacity the string read leaves the mapping entirely (the labpty 91e2676
  /// out-of-bounds-slice class). This keeps the published slot otherwise valid —
  /// seqlock, generation, rows, cols all intact — so the booby-trapped cell is
  /// actually read.
  func testSnapshotRingReaderClampsLyingStringTable() throws {
    let (attachment, valid) = try validRing()
    let dir = ".tmp/laband-ring-strtab-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: dir)) }
    let scratch = "\(dir)/ring.bin"

    // The published frame is generation 1 -> slot 0, which `latestSnapshotFrame`
    // selects. Poison its string-table size and cell (0,0)'s string pointer.
    let slot0 = 64
    let cell00 = slot0 + LabandSnapshotRingLayout.cellsOffset(maxRows: attachment.maxRows)
    var bytes = valid
    patchU32(
      &bytes, slot0 + LabandSnapshotRingLayout.SlotHeaderOffset.stringTableBytes, 0xFFFF_FFFF)
    patchU32(
      &bytes, cell00 + LabandSnapshotRingLayout.CellOffset.stringOffset, 0x1000_0000)
    patchU16(&bytes, cell00 + LabandSnapshotRingLayout.CellOffset.stringLength, 16)
    try Data(bytes).write(to: URL(fileURLWithPath: scratch))

    var poisoned = attachment
    poisoned.path = scratch
    let reader = try LabandSnapshotRingReader(
      attachment: poisoned, logicalSessionId: "fuzz", incarnationId: "inc")
    // With the clamp, the lying offset fails the (now honest) bound and the cell
    // falls back to its codepoint; the frame reads back without leaving the map.
    // Without the clamp this dereferences ~256 MiB past a 17 KiB mapping -> SIGBUS.
    let frame = try reader.latestSnapshotFrame()
    XCTAssertGreaterThan(frame.generation ?? 0, 0)
  }

  // MARK: - Helpers

  /// A zero-filled buffer sized for `stride`, with the 64-byte file header copied
  /// in and its stride field patched to match. Slot payloads are not relaid out:
  /// the geometry guards must fire before any slot is read.
  private func rebuiltForStride(_ valid: [UInt8], stride: Int, slotCount: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 64 + slotCount * stride)
    for index in 0..<min(64, valid.count) { bytes[index] = valid[index] }
    patchU32(&bytes, LabandSnapshotRingLayout.FileHeaderOffset.slotStride, UInt32(stride))
    return bytes
  }

  /// Attach a reader against deliberately bad geometry and require it to reject
  /// before any unsafe dereference. The read after a successful attach is the
  /// teeth: a guarded build never reaches it. An unguarded build does — and
  /// either SIGBUSes there (misaligned stride) or returns and trips the explicit
  /// failure (a map the reader cannot back, which SIGBUSes on a page-aligned
  /// ring). Either way, removing the guard fails this test.
  private func expectRejectedBeforeRead(
    bytes: [UInt8],
    attachment base: LabandSnapshotRingAttachment,
    scratch path: String,
    reason: String,
    mutate: (inout LabandSnapshotRingAttachment) -> Void
  ) {
    guard (try? Data(bytes).write(to: URL(fileURLWithPath: path))) != nil else {
      XCTFail("scratch write failed for \(reason)")
      return
    }
    var attachment = base
    attachment.path = path
    mutate(&attachment)
    do {
      let reader = try LabandSnapshotRingReader(
        attachment: attachment, logicalSessionId: "fuzz", incarnationId: "inc")
      _ = try? reader.latestSnapshotFrame()
      XCTFail("reader accepted \(reason)")
    } catch is LabandSnapshotRingError {
      // expected: rejected before any misaligned or out-of-range dereference
    } catch {
      XCTFail("unexpected error for \(reason): \(error)")
    }
  }

  private func patchU32(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt32) {
    for index in 0..<4 { bytes[offset + index] = UInt8((value >> (8 * index)) & 0xff) }
  }

  private func patchU16(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt16) {
    for index in 0..<2 { bytes[offset + index] = UInt8((value >> (8 * index)) & 0xff) }
  }
}
