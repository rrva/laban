import Darwin
import Foundation

public final class LabptyByteRingWriter {
  public let path: String
  public let outputRingCapacity: UInt64
  public let outputRingOffset: UInt64
  private let fd: Int32
  private let map: UnsafeMutableRawPointer
  private let mapLength: Int
  private var outputOffset: UInt64 = 0

  public init(
    path: String,
    outputRingCapacity: UInt64 = UInt64(LabptyByteRingLayout.defaultOutputRingCapacity),
    logicalSessionId: String = ""
  ) throws {
    guard LabptyByteRingLayout.validateOutputCapacity(outputRingCapacity) else {
      throw TerminalSessionClientError.protocolError("invalid labpty output capacity")
    }
    self.path = path
    self.outputRingCapacity = outputRingCapacity
    outputRingOffset = LabptyByteRingLayout.inputRingOffset
    mapLength = Int(outputRingOffset + outputRingCapacity)
    fd = Darwin.open(path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
    guard fd >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard ftruncate(fd, off_t(mapLength)) == 0 else {
      Darwin.close(fd)
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let mapped = mmap(nil, mapLength, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
    guard mapped != MAP_FAILED else {
      Darwin.close(fd)
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    map = mapped!
    memset(map, 0, mapLength)
    initializeHeader(logicalSessionId: logicalSessionId)
    heartbeat()
  }

  deinit {
    munmap(map, mapLength)
    Darwin.close(fd)
  }

  public func write(_ bytes: Data) {
    bytes.withUnsafeBytes { raw in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
      write(base, count: raw.count)
    }
  }

  public func heartbeat() {
    storeUInt64(monotonicNanoseconds(), offset: Int(LabptyByteRingLayout.producerAliveMonoNsOffset))
  }

  private func write(_ bytes: UnsafePointer<UInt8>, count: Int) {
    guard count > 0 else { return }
    let ring = map.assumingMemoryBound(to: UInt8.self).advanced(by: Int(outputRingOffset))
    let startIndex = Int(outputOffset & (outputRingCapacity - 1))
    let first = min(count, Int(outputRingCapacity) - startIndex)
    memcpy(ring.advanced(by: startIndex), bytes, first)
    if count > first {
      memcpy(ring, bytes.advanced(by: first), count - first)
    }
    outputOffset += UInt64(count)
    storeUInt64(outputOffset, offset: Int(LabptyByteRingLayout.outputBytesWrittenTotalOffset))
    storeUInt64(
      outputOffset / outputRingCapacity,
      offset: Int(LabptyByteRingLayout.outputWrapCountOffset))
    heartbeat()
  }

  private func initializeHeader(logicalSessionId: String) {
    let bytes = map.assumingMemoryBound(to: UInt8.self)
    for (index, byte) in LabptyByteRingLayout.magic.enumerated() {
      bytes[index] = byte
    }
    storeUInt32(LabptyByteRingLayout.abiMajor, offset: 8)
    storeUInt32(LabptyByteRingLayout.abiMinor, offset: 12)
    storeUInt32(LabptyByteRingLayout.headerBytes, offset: 16)
    storeUInt32(LabptyByteRingLayout.countersOffset, offset: 20)
    storeUInt32(LabptyByteRingLayout.readerSlotOffset, offset: 24)
    storeUInt32(LabptyByteRingLayout.readerSlotBytes, offset: 28)
    storeUInt32(LabptyByteRingLayout.readerSlotCount, offset: 32)
    storeUInt64(LabptyByteRingLayout.inputRingOffset, offset: 40)
    storeUInt64(0, offset: 48)
    storeUInt64(outputRingOffset, offset: 56)
    storeUInt64(outputRingCapacity, offset: 64)
    storeUInt64(outputRingOffset + outputRingCapacity, offset: 72)
    storeUInt64(0, offset: 80)
    storeUInt64(LabptyByteRingLayout.fnv1a64(logicalSessionId), offset: 88)
    storeUInt32(UInt32(getpid()), offset: 96)
    storeUInt64(unixNanoseconds(), offset: 104)
  }

  private func storeUInt32(_ value: UInt32, offset: Int) {
    let bytes = map.assumingMemoryBound(to: UInt8.self)
    bytes[offset] = UInt8(value & 0xFF)
    bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
    bytes[offset + 2] = UInt8((value >> 16) & 0xFF)
    bytes[offset + 3] = UInt8((value >> 24) & 0xFF)
  }

  private func storeUInt64(_ value: UInt64, offset: Int) {
    let bytes = map.assumingMemoryBound(to: UInt8.self)
    for index in 0..<8 {
      bytes[offset + index] = UInt8((value >> UInt64(index * 8)) & 0xFF)
    }
  }

  private func monotonicNanoseconds() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
  }

  private func unixNanoseconds() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_REALTIME, &ts)
    return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
  }
}
