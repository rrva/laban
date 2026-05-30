import Darwin
import Foundation
import LabanTerminalCore

public enum LabandSnapshotRingError: Error, CustomStringConvertible {
  case invalidSlotCount(Int)
  case invalidDimensions(rows: Int, cols: Int)
  case incompatibleHeader(String)
  case fileOpenFailed(String, Int32)
  case fileResizeFailed(String, Int32)
  case mmapFailed(String, Int32)
  case noCompletedSnapshot
  case snapshotExceedsCapacity(rows: Int, cols: Int, maxRows: Int, maxCols: Int)

  public var description: String {
    switch self {
    case .invalidSlotCount(let count):
      return "snapshot ring requires at least three slots, got \(count)"
    case .invalidDimensions(let rows, let cols):
      return "invalid snapshot ring dimensions \(rows)x\(cols)"
    case .incompatibleHeader(let message):
      return "incompatible snapshot ring header: \(message)"
    case .fileOpenFailed(let path, let errnoValue):
      return "failed to open snapshot ring \(path): \(String(cString: strerror(errnoValue)))"
    case .fileResizeFailed(let path, let errnoValue):
      return "failed to resize snapshot ring \(path): \(String(cString: strerror(errnoValue)))"
    case .mmapFailed(let path, let errnoValue):
      return "failed to mmap snapshot ring \(path): \(String(cString: strerror(errnoValue)))"
    case .noCompletedSnapshot:
      return "snapshot ring has no completed snapshot"
    case .snapshotExceedsCapacity(let rows, let cols, let maxRows, let maxCols):
      return "snapshot \(rows)x\(cols) exceeds ring capacity \(maxRows)x\(maxCols)"
    }
  }
}

public enum LabandSnapshotRingLayout {
  public static let magic = "LBNDSS01"
  public static let abiVersion: UInt16 = 1
  public static let byteOrderMarker: UInt32 = 0x0102_0304
  public static let fileHeaderBytes: UInt16 = 64
  public static let slotHeaderBytes: UInt16 = 96
  public static let cellBytes: UInt16 = 32
  public static let minimumSlotCount = 3
  public static let defaultSlotCount = 3
  public static let defaultStringTableBytesPerCell = 8

  public enum FileHeaderOffset {
    public static let magic = 0
    public static let abiVersion = 8
    public static let headerBytes = 10
    public static let slotHeaderBytes = 12
    public static let cellBytes = 14
    public static let slotCount = 16
    public static let maxRows = 18
    public static let maxCols = 20
    public static let byteOrderMarker = 24
    public static let slotStride = 28
    public static let sessionIdHash = 32
    public static let incarnationIdHash = 40
    public static let writerGeneration = 48
    public static let flags = 56
  }

  public enum SlotHeaderOffset {
    public static let seqlock = 0
    public static let generation = 8
    public static let rows = 16
    public static let cols = 18
    public static let cursorRow = 20
    public static let cursorCol = 22
    public static let flags = 24
    public static let dirtyRangeCount = 28
    public static let stringTableBytes = 32
    public static let scrollbackAnchor = 40
    public static let inputSeqApplied = 48
    public static let echoAckSeq = 56
    public static let ptyDrainMonoNs = 64
    public static let snapshotPublishMonoNs = 72
    public static let titleGeneration = 80
  }

  public enum CellOffset {
    public static let codepoint = 0
    public static let stringOffset = 4
    public static let stringLength = 8
    public static let width = 10
    public static let underlineStyle = 11
    public static let flags = 12
    public static let foregroundRGBA = 16
    public static let backgroundRGBA = 20
    public static let hyperlinkIndex = 24
    public static let semanticTokenIndex = 28
  }

  public enum SlotFlag {
    public static let alternateScreen: UInt32 = 1 << 0
    public static let cursorVisible: UInt32 = 1 << 1
    public static let cursorBlink: UInt32 = 1 << 2
    public static let synchronizedOutput: UInt32 = 1 << 3
  }

  public static func align8(_ value: Int) -> Int {
    (value + 7) & ~7
  }

  public static func dirtyRangeBytes(maxRows: Int) -> Int {
    max(0, maxRows) * 4
  }

  public static func cellsOffset(maxRows: Int) -> Int {
    align8(Int(slotHeaderBytes) + dirtyRangeBytes(maxRows: maxRows))
  }

  public static func stringTableOffset(maxRows: Int, maxCols: Int) -> Int {
    cellsOffset(maxRows: maxRows) + maxRows * maxCols * Int(cellBytes)
  }

  public static func slotStride(
    maxRows: Int,
    maxCols: Int,
    stringTableBytes: Int = 0
  ) -> Int {
    align8(stringTableOffset(maxRows: maxRows, maxCols: maxCols) + max(0, stringTableBytes))
  }

  public static func defaultStringTableBytes(maxRows: Int, maxCols: Int) -> Int {
    maxRows * maxCols * defaultStringTableBytesPerCell
  }

  public static func fileBytes(slotCount: Int, slotStride: Int) -> Int {
    Int(fileHeaderBytes) + slotCount * slotStride
  }

  public static func stableHash(_ value: String) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    return hash
  }

  public static func monotonicNanoseconds() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
  }
}

public struct LabandSnapshotRingAttachment: Codable, Equatable, Sendable {
  public var path: String
  public var headerBytes: Int
  public var slotHeaderBytes: Int
  public var cellBytes: Int
  public var slotCount: Int
  public var maxRows: Int
  public var maxCols: Int
  public var slotStride: Int
  public var fileBytes: Int
  public var sessionIdHash: UInt64
  public var incarnationIdHash: UInt64

  public init(
    path: String,
    headerBytes: Int,
    slotHeaderBytes: Int,
    cellBytes: Int,
    slotCount: Int,
    maxRows: Int,
    maxCols: Int,
    slotStride: Int,
    fileBytes: Int,
    sessionIdHash: UInt64,
    incarnationIdHash: UInt64
  ) {
    self.path = path
    self.headerBytes = headerBytes
    self.slotHeaderBytes = slotHeaderBytes
    self.cellBytes = cellBytes
    self.slotCount = slotCount
    self.maxRows = maxRows
    self.maxCols = maxCols
    self.slotStride = slotStride
    self.fileBytes = fileBytes
    self.sessionIdHash = sessionIdHash
    self.incarnationIdHash = incarnationIdHash
  }
}

public struct LabandSnapshotRingCellRead: Equatable, Sendable {
  public var generation: UInt64
  public var rows: Int
  public var cols: Int
  public var row: Int
  public var col: Int
  public var text: String
  public var flags: UInt16
  public var foregroundRGBA: UInt32
  public var backgroundRGBA: UInt32

  public init(
    generation: UInt64,
    rows: Int,
    cols: Int,
    row: Int,
    col: Int,
    text: String,
    flags: UInt16,
    foregroundRGBA: UInt32,
    backgroundRGBA: UInt32
  ) {
    self.generation = generation
    self.rows = rows
    self.cols = cols
    self.row = row
    self.col = col
    self.text = text
    self.flags = flags
    self.foregroundRGBA = foregroundRGBA
    self.backgroundRGBA = backgroundRGBA
  }
}

extension UnsafeRawPointer {
  fileprivate func loadU8(_ offset: Int) -> UInt8 {
    load(fromByteOffset: offset, as: UInt8.self)
  }

  fileprivate func loadU16(_ offset: Int) -> UInt16 {
    UInt16(littleEndian: load(fromByteOffset: offset, as: UInt16.self))
  }

  fileprivate func loadU32(_ offset: Int) -> UInt32 {
    UInt32(littleEndian: load(fromByteOffset: offset, as: UInt32.self))
  }

  fileprivate func loadU64(_ offset: Int) -> UInt64 {
    UInt64(littleEndian: load(fromByteOffset: offset, as: UInt64.self))
  }

  /// Acquire-ordered load of the seqlock word. Pairs with
  /// `storeU64Release` so payload reads after observing an even seqlock
  /// see the writer's payload stores (H-1). Same-host shared memory, so
  /// the native (non-byte-swapped) representation round-trips.
  fileprivate func loadU64Acquire(_ offset: Int) -> UInt64 {
    laban_atomic_load_u64_acquire(advanced(by: offset))
  }
}

extension UnsafeMutableRawPointer {
  fileprivate func storeU8(_ value: UInt8, _ offset: Int) {
    storeBytes(of: value, toByteOffset: offset, as: UInt8.self)
  }

  fileprivate func storeU16(_ value: UInt16, _ offset: Int) {
    storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt16.self)
  }

  fileprivate func storeU32(_ value: UInt32, _ offset: Int) {
    storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt32.self)
  }

  fileprivate func storeU64(_ value: UInt64, _ offset: Int) {
    storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt64.self)
  }

  /// Release-ordered store of the seqlock word (see `loadU64Acquire`).
  fileprivate func storeU64Release(_ value: UInt64, _ offset: Int) {
    laban_atomic_store_u64_release(advanced(by: offset), value)
  }
}

extension NSLock {
  fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}

public struct LabandSnapshotDirtyRange: Equatable, Sendable {
  public var startRow: Int
  public var endRow: Int

  public init(startRow: Int, endRow: Int) {
    self.startRow = startRow
    self.endRow = endRow
  }
}

public struct LabandSnapshotFrame: Equatable, Sendable {
  public var generation: UInt64?
  public var dirtyRanges: [LabandSnapshotDirtyRange]?
  public var ptyDrainMonoNs: UInt64?
  public var snapshotPublishMonoNs: UInt64?
  public var snapshot: LabandSnapshotResponse

  public init(
    generation: UInt64?,
    dirtyRanges: [LabandSnapshotDirtyRange]? = nil,
    ptyDrainMonoNs: UInt64? = nil,
    snapshotPublishMonoNs: UInt64? = nil,
    snapshot: LabandSnapshotResponse
  ) {
    self.generation = generation
    self.dirtyRanges = dirtyRanges
    self.ptyDrainMonoNs = ptyDrainMonoNs
    self.snapshotPublishMonoNs = snapshotPublishMonoNs
    self.snapshot = snapshot
  }

  public func snapshotPublishedAt(
    now: Date = Date(),
    nowMonoNs: UInt64 = LabandSnapshotRingLayout.monotonicNanoseconds()
  ) -> Date? {
    guard let snapshotPublishMonoNs, snapshotPublishMonoNs > 0 else { return nil }
    let elapsedNs = nowMonoNs >= snapshotPublishMonoNs ? nowMonoNs - snapshotPublishMonoNs : 0
    return now.addingTimeInterval(-Double(elapsedNs) / 1_000_000_000)
  }
}

public final class LabandSnapshotRingWriter {
  public let attachment: LabandSnapshotRingAttachment

  private let fd: Int32
  private let pointer: UnsafeMutableRawPointer
  private let mappedBytes: Int
  private let slotCount: Int
  private let maxRows: Int
  private let maxCols: Int
  private let slotStride: Int
  private let stringTableCapacity: Int
  private let lock = NSLock()
  private var generation: UInt64 = 0

  public init(
    path: String,
    logicalSessionId: String,
    incarnationId: String,
    maxRows: Int,
    maxCols: Int,
    slotCount: Int = LabandSnapshotRingLayout.defaultSlotCount
  ) throws {
    guard slotCount >= LabandSnapshotRingLayout.minimumSlotCount else {
      throw LabandSnapshotRingError.invalidSlotCount(slotCount)
    }
    guard maxRows > 0, maxCols > 0, maxRows <= Int(UInt16.max), maxCols <= Int(UInt16.max)
    else {
      throw LabandSnapshotRingError.invalidDimensions(rows: maxRows, cols: maxCols)
    }

    self.slotCount = slotCount
    self.maxRows = maxRows
    self.maxCols = maxCols
    self.stringTableCapacity = LabandSnapshotRingLayout.defaultStringTableBytes(
      maxRows: maxRows, maxCols: maxCols)
    self.slotStride = LabandSnapshotRingLayout.slotStride(
      maxRows: maxRows,
      maxCols: maxCols,
      stringTableBytes: stringTableCapacity
    )
    self.mappedBytes = LabandSnapshotRingLayout.fileBytes(
      slotCount: slotCount, slotStride: slotStride)

    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: path).deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let opened = Darwin.open(path, O_RDWR | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR)
    guard opened >= 0 else { throw LabandSnapshotRingError.fileOpenFailed(path, errno) }
    guard Darwin.ftruncate(opened, off_t(mappedBytes)) == 0 else {
      let err = errno
      Darwin.close(opened)
      throw LabandSnapshotRingError.fileResizeFailed(path, err)
    }
    let mapped = Darwin.mmap(nil, mappedBytes, PROT_READ | PROT_WRITE, MAP_SHARED, opened, 0)
    guard mapped != MAP_FAILED, let mapped else {
      let err = errno
      Darwin.close(opened)
      throw LabandSnapshotRingError.mmapFailed(path, err)
    }
    self.fd = opened
    self.pointer = mapped

    let sessionHash = LabandSnapshotRingLayout.stableHash(logicalSessionId)
    let incarnationHash = LabandSnapshotRingLayout.stableHash(incarnationId)
    self.attachment = LabandSnapshotRingAttachment(
      path: path,
      headerBytes: Int(LabandSnapshotRingLayout.fileHeaderBytes),
      slotHeaderBytes: Int(LabandSnapshotRingLayout.slotHeaderBytes),
      cellBytes: Int(LabandSnapshotRingLayout.cellBytes),
      slotCount: slotCount,
      maxRows: maxRows,
      maxCols: maxCols,
      slotStride: slotStride,
      fileBytes: mappedBytes,
      sessionIdHash: sessionHash,
      incarnationIdHash: incarnationHash
    )
    writeFileHeader(sessionHash: sessionHash, incarnationHash: incarnationHash)
  }

  deinit {
    Darwin.msync(pointer, mappedBytes, MS_ASYNC)
    Darwin.munmap(pointer, mappedBytes)
    Darwin.close(fd)
  }

  public func publish(
    snapshot: UnsafePointer<LabanSnapshot>,
    inputSeqApplied: UInt64 = 0,
    echoAckSeq: UInt64 = 0,
    ptyDrainMonoNs: UInt64 = LabandSnapshotRingLayout.monotonicNanoseconds()
  ) throws {
    try lock.withLock {
      let snap = snapshot.pointee
      let rows = Int(snap.rows)
      let cols = Int(snap.cols)
      guard rows > 0, cols > 0, rows <= maxRows, cols <= maxCols else {
        throw LabandSnapshotRingError.snapshotExceedsCapacity(
          rows: rows, cols: cols, maxRows: maxRows, maxCols: maxCols)
      }

      generation &+= 1
      if generation == 0 { generation = 1 }
      let slotIndex = Int((generation - 1) % UInt64(slotCount))
      let slot = pointer.advanced(
        by: Int(LabandSnapshotRingLayout.fileHeaderBytes) + slotIndex * slotStride)
      let seqlockComplete = generation &* 2
      slot.storeU64Release(seqlockComplete | 1, LabandSnapshotRingLayout.SlotHeaderOffset.seqlock)

      memset(
        slot.advanced(by: Int(LabandSnapshotRingLayout.slotHeaderBytes)), 0,
        slotStride - Int(LabandSnapshotRingLayout.slotHeaderBytes))

      let stringBytes = writeCells(slot: slot, snapshot: snap, rows: rows, cols: cols)
      let dirtyCount = writeDirtyRanges(slot: slot, snapshot: snap, rows: rows)
      let flags = slotFlags(snapshot: snap)
      let publishedAt = LabandSnapshotRingLayout.monotonicNanoseconds()

      slot.storeU64(generation, LabandSnapshotRingLayout.SlotHeaderOffset.generation)
      slot.storeU16(UInt16(rows), LabandSnapshotRingLayout.SlotHeaderOffset.rows)
      slot.storeU16(UInt16(cols), LabandSnapshotRingLayout.SlotHeaderOffset.cols)
      slot.storeU16(
        UInt16(max(0, Int(snap.cursor_row))),
        LabandSnapshotRingLayout.SlotHeaderOffset.cursorRow)
      slot.storeU16(
        UInt16(max(0, Int(snap.cursor_col))),
        LabandSnapshotRingLayout.SlotHeaderOffset.cursorCol)
      slot.storeU32(flags, LabandSnapshotRingLayout.SlotHeaderOffset.flags)
      slot.storeU16(UInt16(dirtyCount), LabandSnapshotRingLayout.SlotHeaderOffset.dirtyRangeCount)
      slot.storeU32(UInt32(stringBytes), LabandSnapshotRingLayout.SlotHeaderOffset.stringTableBytes)
      slot.storeU64(0, LabandSnapshotRingLayout.SlotHeaderOffset.scrollbackAnchor)
      slot.storeU64(inputSeqApplied, LabandSnapshotRingLayout.SlotHeaderOffset.inputSeqApplied)
      slot.storeU64(echoAckSeq, LabandSnapshotRingLayout.SlotHeaderOffset.echoAckSeq)
      slot.storeU64(ptyDrainMonoNs, LabandSnapshotRingLayout.SlotHeaderOffset.ptyDrainMonoNs)
      slot.storeU64(publishedAt, LabandSnapshotRingLayout.SlotHeaderOffset.snapshotPublishMonoNs)
      slot.storeU64(generation, LabandSnapshotRingLayout.SlotHeaderOffset.titleGeneration)
      slot.storeU64Release(seqlockComplete, LabandSnapshotRingLayout.SlotHeaderOffset.seqlock)
      pointer.storeU64(generation, LabandSnapshotRingLayout.FileHeaderOffset.writerGeneration)
    }
  }

  private func writeFileHeader(sessionHash: UInt64, incarnationHash: UInt64) {
    memset(pointer, 0, mappedBytes)
    for (index, byte) in LabandSnapshotRingLayout.magic.utf8.enumerated() {
      pointer.storeU8(byte, LabandSnapshotRingLayout.FileHeaderOffset.magic + index)
    }
    pointer.storeU16(
      LabandSnapshotRingLayout.abiVersion, LabandSnapshotRingLayout.FileHeaderOffset.abiVersion)
    pointer.storeU16(
      LabandSnapshotRingLayout.fileHeaderBytes,
      LabandSnapshotRingLayout.FileHeaderOffset.headerBytes)
    pointer.storeU16(
      LabandSnapshotRingLayout.slotHeaderBytes,
      LabandSnapshotRingLayout.FileHeaderOffset.slotHeaderBytes)
    pointer.storeU16(
      LabandSnapshotRingLayout.cellBytes, LabandSnapshotRingLayout.FileHeaderOffset.cellBytes)
    pointer.storeU16(UInt16(slotCount), LabandSnapshotRingLayout.FileHeaderOffset.slotCount)
    pointer.storeU16(UInt16(maxRows), LabandSnapshotRingLayout.FileHeaderOffset.maxRows)
    pointer.storeU16(UInt16(maxCols), LabandSnapshotRingLayout.FileHeaderOffset.maxCols)
    pointer.storeU32(
      LabandSnapshotRingLayout.byteOrderMarker,
      LabandSnapshotRingLayout.FileHeaderOffset.byteOrderMarker)
    pointer.storeU32(UInt32(slotStride), LabandSnapshotRingLayout.FileHeaderOffset.slotStride)
    pointer.storeU64(sessionHash, LabandSnapshotRingLayout.FileHeaderOffset.sessionIdHash)
    pointer.storeU64(incarnationHash, LabandSnapshotRingLayout.FileHeaderOffset.incarnationIdHash)
    pointer.storeU64(0, LabandSnapshotRingLayout.FileHeaderOffset.writerGeneration)
    pointer.storeU64(0, LabandSnapshotRingLayout.FileHeaderOffset.flags)
  }

  private func slotFlags(snapshot: LabanSnapshot) -> UInt32 {
    var flags: UInt32 = 0
    if snapshot.cursor_visible != 0 { flags |= LabandSnapshotRingLayout.SlotFlag.cursorVisible }
    if snapshot.cursor_blinking != 0 { flags |= LabandSnapshotRingLayout.SlotFlag.cursorBlink }
    if snapshot.synchronized_output != 0 {
      flags |= LabandSnapshotRingLayout.SlotFlag.synchronizedOutput
    }
    return flags
  }

  private func writeDirtyRanges(slot: UnsafeMutableRawPointer, snapshot: LabanSnapshot, rows: Int)
    -> Int
  {
    let rangesOffset = Int(LabandSnapshotRingLayout.slotHeaderBytes)
    guard let dirtyRows = snapshot.dirty_rows, Int(snapshot.dirty_row_count) >= rows else {
      slot.storeU16(0, rangesOffset)
      slot.storeU16(UInt16(rows), rangesOffset + 2)
      return 1
    }

    var count = 0
    var row = 0
    while row < rows && count < rows {
      while row < rows && dirtyRows[row] == 0 { row += 1 }
      if row >= rows { break }
      let start = row
      while row < rows && dirtyRows[row] != 0 { row += 1 }
      let offset = rangesOffset + count * 4
      slot.storeU16(UInt16(start), offset)
      slot.storeU16(UInt16(row), offset + 2)
      count += 1
    }
    if count == 0 {
      slot.storeU16(0, rangesOffset)
      slot.storeU16(UInt16(rows), rangesOffset + 2)
      return 1
    }
    return count
  }

  private func writeCells(
    slot: UnsafeMutableRawPointer,
    snapshot: LabanSnapshot,
    rows: Int,
    cols: Int
  ) -> Int {
    guard let cells = snapshot.cells else { return 0 }
    let cellsBase = slot.advanced(
      by: LabandSnapshotRingLayout.cellsOffset(maxRows: maxRows))
    let stringsBaseOffset = LabandSnapshotRingLayout.stringTableOffset(
      maxRows: maxRows, maxCols: maxCols)
    let stringsBase = slot.advanced(by: stringsBaseOffset)
    var stringUsed = 0
    let cellBytes = Int(LabandSnapshotRingLayout.cellBytes)

    for row in 0..<rows {
      for col in 0..<cols {
        let source = cells[row * cols + col]
        let dest = cellsBase.advanced(by: (row * maxCols + col) * cellBytes)
        dest.storeU32(source.codepoint, LabandSnapshotRingLayout.CellOffset.codepoint)
        dest.storeU32(0, LabandSnapshotRingLayout.CellOffset.stringOffset)
        dest.storeU16(0, LabandSnapshotRingLayout.CellOffset.stringLength)
        dest.storeU8(source.wide, LabandSnapshotRingLayout.CellOffset.width)
        dest.storeU8(source.underline_style, LabandSnapshotRingLayout.CellOffset.underlineStyle)
        dest.storeU16(source.flags, LabandSnapshotRingLayout.CellOffset.flags)
        dest.storeU32(source.foreground_rgba, LabandSnapshotRingLayout.CellOffset.foregroundRGBA)
        dest.storeU32(source.background_rgba, LabandSnapshotRingLayout.CellOffset.backgroundRGBA)
        dest.storeU32(source.hyperlink_id, LabandSnapshotRingLayout.CellOffset.hyperlinkIndex)
        dest.storeU32(0, LabandSnapshotRingLayout.CellOffset.semanticTokenIndex)

        guard source.utf8_length > 0, let storage = snapshot.utf8_storage else { continue }
        let byteLength = min(Int(source.utf8_length), stringTableCapacity - stringUsed)
        guard byteLength > 0 else { continue }
        let sourcePtr = UnsafeRawPointer(storage).advanced(by: Int(source.utf8_offset))
        memcpy(stringsBase.advanced(by: stringUsed), sourcePtr, byteLength)
        dest.storeU32(UInt32(stringUsed), LabandSnapshotRingLayout.CellOffset.stringOffset)
        dest.storeU16(UInt16(byteLength), LabandSnapshotRingLayout.CellOffset.stringLength)
        stringUsed += byteLength
      }
    }
    return stringUsed
  }
}

public final class LabandSnapshotRingReader {
  public let attachment: LabandSnapshotRingAttachment

  private let fd: Int32
  private let pointer: UnsafeMutableRawPointer
  private let mappedBytes: Int
  private let slotCount: Int
  private let maxRows: Int
  private let maxCols: Int
  private let slotStride: Int
  private let logicalSessionId: String
  private let incarnationId: String

  public init(
    attachment: LabandSnapshotRingAttachment,
    logicalSessionId: String,
    incarnationId: String
  ) throws {
    let opened = Darwin.open(attachment.path, O_RDONLY)
    guard opened >= 0 else {
      throw LabandSnapshotRingError.fileOpenFailed(attachment.path, errno)
    }
    let mapped = Darwin.mmap(nil, attachment.fileBytes, PROT_READ, MAP_SHARED, opened, 0)
    guard mapped != MAP_FAILED, let mapped else {
      let err = errno
      Darwin.close(opened)
      throw LabandSnapshotRingError.mmapFailed(attachment.path, err)
    }

    self.fd = opened
    self.pointer = mapped
    self.mappedBytes = attachment.fileBytes
    self.attachment = attachment
    self.logicalSessionId = logicalSessionId
    self.incarnationId = incarnationId
    self.slotCount = attachment.slotCount
    self.maxRows = attachment.maxRows
    self.maxCols = attachment.maxCols
    self.slotStride = attachment.slotStride
    try Self.validateHeader(pointer: UnsafeRawPointer(mapped), attachment: attachment)
  }

  deinit {
    Darwin.munmap(pointer, mappedBytes)
    Darwin.close(fd)
  }

  public func latestSnapshotFrame() throws -> LabandSnapshotFrame {
    let header = UnsafeRawPointer(pointer)
    let writerGeneration = header.loadU64(
      LabandSnapshotRingLayout.FileHeaderOffset.writerGeneration)
    guard writerGeneration > 0 else { throw LabandSnapshotRingError.noCompletedSnapshot }

    var best: SlotRead?
    for slotIndex in 0..<slotCount {
      if let read = readSlot(index: slotIndex), read.generation > (best?.generation ?? 0) {
        best = read
      }
    }
    guard let best else { throw LabandSnapshotRingError.noCompletedSnapshot }
    return LabandSnapshotFrame(
      generation: best.generation,
      dirtyRanges: best.dirtyRanges,
      ptyDrainMonoNs: best.ptyDrainMonoNs,
      snapshotPublishMonoNs: best.snapshotPublishMonoNs,
      snapshot: best.snapshot)
  }

  public func latestSnapshot() throws -> LabandSnapshotResponse {
    try latestSnapshotFrame().snapshot
  }

  public func generation() -> UInt64 {
    UnsafeRawPointer(pointer).loadU64(LabandSnapshotRingLayout.FileHeaderOffset.writerGeneration)
  }

  public func cell(row: Int, col: Int) throws -> LabandSnapshotRingCellRead {
    var best: LabandSnapshotRingCellRead?
    for slotIndex in 0..<slotCount {
      if let read = readCell(slotIndex: slotIndex, row: row, col: col),
        read.generation > (best?.generation ?? 0)
      {
        best = read
      }
    }
    guard let best else { throw LabandSnapshotRingError.noCompletedSnapshot }
    return best
  }

  private static func validateHeader(
    pointer: UnsafeRawPointer,
    attachment: LabandSnapshotRingAttachment
  ) throws {
    let magicBytes = (0..<8).map {
      pointer.loadU8(LabandSnapshotRingLayout.FileHeaderOffset.magic + $0)
    }
    guard String(bytes: magicBytes, encoding: .utf8) == LabandSnapshotRingLayout.magic else {
      throw LabandSnapshotRingError.incompatibleHeader("bad magic")
    }
    guard
      pointer.loadU16(LabandSnapshotRingLayout.FileHeaderOffset.abiVersion)
        == LabandSnapshotRingLayout.abiVersion
    else {
      throw LabandSnapshotRingError.incompatibleHeader("unsupported ABI version")
    }
    guard
      pointer.loadU32(LabandSnapshotRingLayout.FileHeaderOffset.byteOrderMarker)
        == LabandSnapshotRingLayout.byteOrderMarker
    else {
      throw LabandSnapshotRingError.incompatibleHeader("byte order marker mismatch")
    }
    guard
      pointer.loadU16(LabandSnapshotRingLayout.FileHeaderOffset.headerBytes)
        >= LabandSnapshotRingLayout.fileHeaderBytes
    else {
      throw LabandSnapshotRingError.incompatibleHeader("file header too small")
    }
    guard
      pointer.loadU16(LabandSnapshotRingLayout.FileHeaderOffset.slotHeaderBytes)
        >= LabandSnapshotRingLayout.slotHeaderBytes
    else {
      throw LabandSnapshotRingError.incompatibleHeader("slot header too small")
    }
    guard
      pointer.loadU16(LabandSnapshotRingLayout.FileHeaderOffset.cellBytes)
        >= LabandSnapshotRingLayout.cellBytes
    else {
      throw LabandSnapshotRingError.incompatibleHeader("cell record too small")
    }
    guard
      pointer.loadU16(LabandSnapshotRingLayout.FileHeaderOffset.slotCount)
        == UInt16(attachment.slotCount),
      pointer.loadU16(LabandSnapshotRingLayout.FileHeaderOffset.maxRows)
        == UInt16(attachment.maxRows),
      pointer.loadU16(LabandSnapshotRingLayout.FileHeaderOffset.maxCols)
        == UInt16(attachment.maxCols),
      pointer.loadU32(LabandSnapshotRingLayout.FileHeaderOffset.slotStride)
        == UInt32(attachment.slotStride)
    else {
      throw LabandSnapshotRingError.incompatibleHeader("attachment metadata mismatch")
    }
  }

  private struct SlotRead {
    var generation: UInt64
    var dirtyRanges: [LabandSnapshotDirtyRange]?
    var ptyDrainMonoNs: UInt64?
    var snapshotPublishMonoNs: UInt64?
    var snapshot: LabandSnapshotResponse
  }

  private func readSlot(index: Int) -> SlotRead? {
    let slot = UnsafeRawPointer(pointer).advanced(
      by: Int(LabandSnapshotRingLayout.fileHeaderBytes) + index * slotStride)
    let before = slot.loadU64Acquire(LabandSnapshotRingLayout.SlotHeaderOffset.seqlock)
    guard before != 0, before % 2 == 0 else { return nil }
    let generation = slot.loadU64(LabandSnapshotRingLayout.SlotHeaderOffset.generation)
    let rows = Int(slot.loadU16(LabandSnapshotRingLayout.SlotHeaderOffset.rows))
    let cols = Int(slot.loadU16(LabandSnapshotRingLayout.SlotHeaderOffset.cols))
    guard generation > 0, rows > 0, cols > 0, rows <= maxRows, cols <= maxCols else {
      return nil
    }
    let ptyDrainMonoNs = nonzero(
      slot.loadU64(LabandSnapshotRingLayout.SlotHeaderOffset.ptyDrainMonoNs))
    let snapshotPublishMonoNs = nonzero(
      slot.loadU64(LabandSnapshotRingLayout.SlotHeaderOffset.snapshotPublishMonoNs))
    let dirtyRanges = readDirtyRanges(slot: slot, rows: rows)
    let snapshot = readSnapshot(slot: slot, rows: rows, cols: cols)
    let after = slot.loadU64Acquire(LabandSnapshotRingLayout.SlotHeaderOffset.seqlock)
    guard before == after, after % 2 == 0 else { return nil }
    return SlotRead(
      generation: generation,
      dirtyRanges: dirtyRanges,
      ptyDrainMonoNs: ptyDrainMonoNs,
      snapshotPublishMonoNs: snapshotPublishMonoNs,
      snapshot: snapshot)
  }

  private func nonzero(_ value: UInt64) -> UInt64? {
    value == 0 ? nil : value
  }

  private func readDirtyRanges(
    slot: UnsafeRawPointer,
    rows: Int
  ) -> [LabandSnapshotDirtyRange]? {
    let count = Int(slot.loadU16(LabandSnapshotRingLayout.SlotHeaderOffset.dirtyRangeCount))
    guard rows > 0, count > 0 else { return nil }
    var ranges: [LabandSnapshotDirtyRange] = []
    ranges.reserveCapacity(min(count, rows))
    let rangesBase = slot.advanced(by: Int(LabandSnapshotRingLayout.slotHeaderBytes))
    for index in 0..<min(count, rows) {
      let offset = index * 4
      let start = Int(rangesBase.loadU16(offset))
      let end = Int(rangesBase.loadU16(offset + 2))
      guard start >= 0, start < end, end <= rows else { return nil }
      ranges.append(LabandSnapshotDirtyRange(startRow: start, endRow: end))
    }
    return ranges.isEmpty ? nil : ranges
  }

  private func readCell(slotIndex: Int, row: Int, col: Int) -> LabandSnapshotRingCellRead? {
    let slot = UnsafeRawPointer(pointer).advanced(
      by: Int(LabandSnapshotRingLayout.fileHeaderBytes) + slotIndex * slotStride)
    let before = slot.loadU64Acquire(LabandSnapshotRingLayout.SlotHeaderOffset.seqlock)
    guard before != 0, before % 2 == 0 else { return nil }
    let generation = slot.loadU64(LabandSnapshotRingLayout.SlotHeaderOffset.generation)
    let rows = Int(slot.loadU16(LabandSnapshotRingLayout.SlotHeaderOffset.rows))
    let cols = Int(slot.loadU16(LabandSnapshotRingLayout.SlotHeaderOffset.cols))
    guard generation > 0, row >= 0, col >= 0, row < rows, col < cols else { return nil }
    let cell = UnsafeRawPointer(pointer).advanced(
      by: Int(LabandSnapshotRingLayout.fileHeaderBytes) + slotIndex * slotStride
        + LabandSnapshotRingLayout.cellsOffset(maxRows: maxRows)
        + (row * maxCols + col) * Int(LabandSnapshotRingLayout.cellBytes))
    let stringsBase = slot.advanced(
      by: LabandSnapshotRingLayout.stringTableOffset(maxRows: maxRows, maxCols: maxCols))
    let stringTableBytes = Int(
      slot.loadU32(LabandSnapshotRingLayout.SlotHeaderOffset.stringTableBytes))
    let text = readCellText(
      cell: cell,
      stringsBase: stringsBase,
      stringTableBytes: stringTableBytes
    )
    let after = slot.loadU64Acquire(LabandSnapshotRingLayout.SlotHeaderOffset.seqlock)
    guard before == after, after % 2 == 0 else { return nil }
    return LabandSnapshotRingCellRead(
      generation: generation,
      rows: rows,
      cols: cols,
      row: row,
      col: col,
      text: text,
      flags: cell.loadU16(LabandSnapshotRingLayout.CellOffset.flags),
      foregroundRGBA: cell.loadU32(LabandSnapshotRingLayout.CellOffset.foregroundRGBA),
      backgroundRGBA: cell.loadU32(LabandSnapshotRingLayout.CellOffset.backgroundRGBA)
    )
  }

  private func readSnapshot(
    slot: UnsafeRawPointer,
    rows: Int,
    cols: Int
  ) -> LabandSnapshotResponse {
    let cellsBase = slot.advanced(
      by: LabandSnapshotRingLayout.cellsOffset(maxRows: maxRows))
    let stringsBase = slot.advanced(
      by: LabandSnapshotRingLayout.stringTableOffset(maxRows: maxRows, maxCols: maxCols))
    let stringTableBytes = Int(
      slot.loadU32(LabandSnapshotRingLayout.SlotHeaderOffset.stringTableBytes))
    let cellBytes = Int(LabandSnapshotRingLayout.cellBytes)
    var cells: [LabandSnapshotCell] = []
    cells.reserveCapacity(rows * cols)
    var visibleRows: [String] = Array(repeating: "", count: rows)

    for row in 0..<rows {
      var rowText = ""
      for col in 0..<cols {
        let cell = cellsBase.advanced(by: (row * maxCols + col) * cellBytes)
        let text = readCellText(
          cell: cell, stringsBase: stringsBase, stringTableBytes: stringTableBytes)
        cells.append(
          LabandSnapshotCell(
            row: row,
            col: col,
            text: text,
            flags: cell.loadU16(LabandSnapshotRingLayout.CellOffset.flags),
            foregroundRGBA: cell.loadU32(LabandSnapshotRingLayout.CellOffset.foregroundRGBA),
            backgroundRGBA: cell.loadU32(LabandSnapshotRingLayout.CellOffset.backgroundRGBA)
          )
        )
        rowText += text.isEmpty ? " " : text
      }
      visibleRows[row] = rowText
    }

    let flags = slot.loadU32(LabandSnapshotRingLayout.SlotHeaderOffset.flags)
    return LabandSnapshotResponse(
      logicalSessionId: logicalSessionId,
      incarnationId: incarnationId,
      rows: rows,
      cols: cols,
      cursorRow: Int(slot.loadU16(LabandSnapshotRingLayout.SlotHeaderOffset.cursorRow)),
      cursorCol: Int(slot.loadU16(LabandSnapshotRingLayout.SlotHeaderOffset.cursorCol)),
      cursorVisible: (flags & LabandSnapshotRingLayout.SlotFlag.cursorVisible) != 0,
      title: "",
      lifecycleState: .running,
      exitStatus: nil,
      dirty: true,
      visibleText: visibleRows.joined(separator: "\n"),
      cells: cells,
      synchronizedOutput: (flags & LabandSnapshotRingLayout.SlotFlag.synchronizedOutput) != 0
    )
  }

  private func readCellText(
    cell: UnsafeRawPointer,
    stringsBase: UnsafeRawPointer,
    stringTableBytes: Int
  ) -> String {
    let stringLength = Int(cell.loadU16(LabandSnapshotRingLayout.CellOffset.stringLength))
    let stringOffset = Int(cell.loadU32(LabandSnapshotRingLayout.CellOffset.stringOffset))
    if stringLength > 0, stringOffset >= 0, stringOffset + stringLength <= stringTableBytes {
      let buffer = UnsafeBufferPointer<UInt8>(
        start: stringsBase.advanced(by: stringOffset).assumingMemoryBound(to: UInt8.self),
        count: stringLength
      )
      return String(bytes: buffer, encoding: .utf8) ?? ""
    }
    let codepoint = cell.loadU32(LabandSnapshotRingLayout.CellOffset.codepoint)
    guard codepoint != 0, let scalar = UnicodeScalar(codepoint) else { return "" }
    return String(Character(scalar))
  }
}
