import Darwin
import Foundation
import LabanTerminalCore

public struct LabptyByteRingReadResult: Equatable, Sendable {
  public var bytes: Data
  public var newOffset: UInt64
  public var overflowed: Bool
}

public final class LabptyByteRingReader {
  public let path: String
  public let outputRingOffset: UInt64
  public let outputRingCapacity: UInt64
  public let readableOutputWindow: UInt64
  private let fd: Int32
  private let map: UnsafeMutableRawPointer
  private let mapLength: Int
  private let outputBytesWrittenTotalOffset: UInt64
  private let outputWrapCountOffset: UInt64
  private let producerAliveMonoNsOffset: UInt64

  public init(path: String) throws {
    self.path = path
    fd = Darwin.open(path, O_RDONLY)
    guard fd >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var statBuffer = stat()
    guard fstat(fd, &statBuffer) == 0 else {
      Darwin.close(fd)
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard statBuffer.st_size >= off_t(LabptyByteRingLayout.headerBytes) else {
      Darwin.close(fd)
      throw TerminalSessionClientError.protocolError("labpty byte ring file is too small")
    }
    mapLength = Int(statBuffer.st_size)
    let mapped = mmap(nil, mapLength, PROT_READ, MAP_SHARED, fd, 0)
    guard mapped != MAP_FAILED else {
      Darwin.close(fd)
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    map = mapped!
    let bytes = map.assumingMemoryBound(to: UInt8.self)
    guard Array(UnsafeBufferPointer(start: bytes, count: 8)) == LabptyByteRingLayout.magic else {
      munmap(map, mapLength)
      Darwin.close(fd)
      throw TerminalSessionClientError.protocolError("invalid labpty byte ring magic")
    }
    let abiMajor = LabptyByteRingReader.loadUInt32(bytes, offset: 8)
    guard abiMajor == LabptyByteRingLayout.abiMajor else {
      munmap(map, mapLength)
      Darwin.close(fd)
      throw TerminalSessionClientError.protocolError("unsupported labpty byte ring ABI")
    }
    let headerBytes = UInt64(LabptyByteRingReader.loadUInt32(bytes, offset: 16))
    guard headerBytes >= UInt64(LabptyByteRingLayout.headerBytes),
      headerBytes <= UInt64(mapLength)
    else {
      munmap(map, mapLength)
      Darwin.close(fd)
      throw TerminalSessionClientError.protocolError("unsupported labpty byte ring header")
    }
    let countersOffset = UInt64(LabptyByteRingReader.loadUInt32(bytes, offset: 20))
    let readerSlotOffset = UInt64(LabptyByteRingReader.loadUInt32(bytes, offset: 24))
    let readerSlotBytes = UInt64(LabptyByteRingReader.loadUInt32(bytes, offset: 28))
    let readerSlotCount = UInt64(LabptyByteRingReader.loadUInt32(bytes, offset: 32))
    guard
      countersOffset >= headerBytes,
      LabptyByteRingReader.validateSpan(
        offset: countersOffset,
        count: UInt64(LabptyByteRingLayout.countersBytes),
        mapLength: UInt64(mapLength)),
      readerSlotOffset >= countersOffset + UInt64(LabptyByteRingLayout.countersBytes),
      readerSlotBytes >= UInt64(LabptyByteRingLayout.readerSlotBytes),
      readerSlotCount >= UInt64(LabptyByteRingLayout.readerSlotCount)
    else {
      munmap(map, mapLength)
      Darwin.close(fd)
      throw TerminalSessionClientError.protocolError("unsupported labpty byte ring layout")
    }
    let inputRingOffset = LabptyByteRingReader.loadUInt64(bytes, offset: 40)
    let inputRingCapacity = LabptyByteRingReader.loadUInt64(bytes, offset: 48)
    let ringOffset = LabptyByteRingReader.loadUInt64(bytes, offset: 56)
    let ringCapacity = LabptyByteRingReader.loadUInt64(bytes, offset: 64)
    let metadataRingOffset = LabptyByteRingReader.loadUInt64(bytes, offset: 72)
    let readerSlotSpan = readerSlotBytes * readerSlotCount
    guard readerSlotCount == 0 || readerSlotBytes <= UInt64.max / readerSlotCount,
      inputRingOffset >= readerSlotOffset + readerSlotSpan,
      inputRingCapacity <= UInt64.max - inputRingOffset,
      ringOffset == inputRingOffset + inputRingCapacity,
      ringCapacity <= UInt64.max - ringOffset,
      metadataRingOffset >= ringOffset + ringCapacity
    else {
      munmap(map, mapLength)
      Darwin.close(fd)
      throw TerminalSessionClientError.protocolError("unsupported labpty byte ring offsets")
    }
    guard LabptyByteRingLayout.validateOutputCapacity(ringCapacity) else {
      munmap(map, mapLength)
      Darwin.close(fd)
      throw TerminalSessionClientError.protocolError("invalid labpty byte ring capacity")
    }
    guard LabptyByteRingReader.validateSpan(
      offset: ringOffset, count: ringCapacity, mapLength: UInt64(mapLength))
    else {
      munmap(map, mapLength)
      Darwin.close(fd)
      throw TerminalSessionClientError.protocolError("labpty byte ring span exceeds file length")
    }
    outputRingOffset = ringOffset
    outputRingCapacity = ringCapacity
    readableOutputWindow = LabptyByteRingLayout.readableOutputWindow(for: ringCapacity)
    outputBytesWrittenTotalOffset = countersOffset
    outputWrapCountOffset = countersOffset + 16
    producerAliveMonoNsOffset = countersOffset + 32
  }

  deinit {
    munmap(map, mapLength)
    Darwin.close(fd)
  }

  public func outputWriteOffset() -> UInt64 {
    let bytes = map.assumingMemoryBound(to: UInt8.self)
    return Self.loadAlignedUInt64(bytes, offset: Int(outputBytesWrittenTotalOffset))
  }

  public func outputWrapCount() -> UInt64 {
    let bytes = map.assumingMemoryBound(to: UInt8.self)
    return Self.loadAlignedUInt64(bytes, offset: Int(outputWrapCountOffset))
  }

  public func producerAliveMonoNs() -> UInt64 {
    let bytes = map.assumingMemoryBound(to: UInt8.self)
    return Self.loadAlignedUInt64(bytes, offset: Int(producerAliveMonoNsOffset))
  }

  public func readSince(_ lastOffset: UInt64) -> LabptyByteRingReadResult {
    var result = readStableRangeSince(lastOffset)
    for _ in 0..<3 {
      let confirmed = outputWriteOffset()
      if confirmed == result.newOffset {
        return result
      }
      if confirmed > result.newOffset
        && confirmed - result.newOffset <= outputRingCapacity - readableOutputWindow
      {
        return result
      }
      result = readStableRangeSince(lastOffset)
    }
    return result
  }

  private func readStableRangeSince(_ lastOffset: UInt64) -> LabptyByteRingReadResult {
    let current = outputWriteOffset()
    guard current > lastOffset else {
      return LabptyByteRingReadResult(bytes: Data(), newOffset: current, overflowed: false)
    }
    return readRange(startOffset: lastOffset, currentOffset: current)
  }

  private func readRange(startOffset lastOffset: UInt64, currentOffset current: UInt64)
    -> LabptyByteRingReadResult
  {
    let available = current - lastOffset
    let overflowed = available > readableOutputWindow
    let start = overflowed ? current - readableOutputWindow : lastOffset
    let count = Int(current - start)
    let ring = map.assumingMemoryBound(to: UInt8.self).advanced(by: Int(outputRingOffset))
    let startIndex = Int(start & (outputRingCapacity - 1))
    var data = Data()
    data.reserveCapacity(count)
    let first = min(count, Int(outputRingCapacity) - startIndex)
    data.append(ring.advanced(by: startIndex), count: first)
    if count > first {
      data.append(ring, count: count - first)
    }
    return LabptyByteRingReadResult(bytes: data, newOffset: current, overflowed: overflowed)
  }

  private static func loadUInt32(_ bytes: UnsafePointer<UInt8>, offset: Int) -> UInt32 {
    UInt32(bytes[offset])
      | (UInt32(bytes[offset + 1]) << 8)
      | (UInt32(bytes[offset + 2]) << 16)
      | (UInt32(bytes[offset + 3]) << 24)
  }

  private static func loadUInt64(_ bytes: UnsafePointer<UInt8>, offset: Int) -> UInt64 {
    var value: UInt64 = 0
    for index in 0..<8 {
      value |= UInt64(bytes[offset + index]) << UInt64(index * 8)
    }
    return value
  }

  private static func loadAlignedUInt64(_ bytes: UnsafePointer<UInt8>, offset: Int) -> UInt64 {
    laban_atomic_load_u64_acquire(UnsafeRawPointer(bytes.advanced(by: offset)))
  }

  private static func validateSpan(offset: UInt64, count: UInt64, mapLength: UInt64) -> Bool {
    offset <= mapLength && count <= mapLength - offset
  }
}
