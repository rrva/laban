import Darwin
import Foundation

public struct LabptyByteRingReadResult: Equatable, Sendable {
  public var bytes: Data
  public var newOffset: UInt64
  public var overflowed: Bool
}

public final class LabptyByteRingReader {
  public let path: String
  public let outputRingOffset: UInt64
  public let outputRingCapacity: UInt64
  private let fd: Int32
  private let map: UnsafeMutableRawPointer
  private let mapLength: Int

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
    let headerBytes = LabptyByteRingReader.loadUInt32(bytes, offset: 16)
    guard headerBytes == LabptyByteRingLayout.headerBytes else {
      munmap(map, mapLength)
      Darwin.close(fd)
      throw TerminalSessionClientError.protocolError("unsupported labpty byte ring header")
    }
    outputRingOffset = LabptyByteRingReader.loadUInt64(bytes, offset: 56)
    outputRingCapacity = LabptyByteRingReader.loadUInt64(bytes, offset: 64)
    guard LabptyByteRingLayout.validateOutputCapacity(outputRingCapacity) else {
      munmap(map, mapLength)
      Darwin.close(fd)
      throw TerminalSessionClientError.protocolError("invalid labpty byte ring capacity")
    }
  }

  deinit {
    munmap(map, mapLength)
    Darwin.close(fd)
  }

  public func outputWriteOffset() -> UInt64 {
    let bytes = map.assumingMemoryBound(to: UInt8.self)
    return Self.loadUInt64(bytes, offset: Int(LabptyByteRingLayout.outputBytesWrittenTotalOffset))
  }

  public func outputWrapCount() -> UInt64 {
    let bytes = map.assumingMemoryBound(to: UInt8.self)
    return Self.loadUInt64(bytes, offset: Int(LabptyByteRingLayout.outputWrapCountOffset))
  }

  public func producerAliveMonoNs() -> UInt64 {
    let bytes = map.assumingMemoryBound(to: UInt8.self)
    return Self.loadUInt64(bytes, offset: Int(LabptyByteRingLayout.producerAliveMonoNsOffset))
  }

  public func readSince(_ lastOffset: UInt64) -> LabptyByteRingReadResult {
    let current = outputWriteOffset()
    guard current > lastOffset else {
      return LabptyByteRingReadResult(bytes: Data(), newOffset: current, overflowed: false)
    }
    let available = current - lastOffset
    let overflowed = available > outputRingCapacity
    let start = overflowed ? current - outputRingCapacity : lastOffset
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
}
