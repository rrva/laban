import Foundation

public enum LabptyByteRingLayout {
  public static let magic = [UInt8]("LBPTY-BR".utf8)
  public static let abiMajor: UInt32 = 1
  public static let abiMinor: UInt32 = 0

  public static let headerBytes: UInt32 = 128
  public static let countersOffset: UInt32 = 128
  public static let countersBytes: UInt32 = 128
  public static let readerSlotOffset: UInt32 = 256
  public static let readerSlotBytes: UInt32 = 64
  public static let readerSlotCount: UInt32 = 8
  public static let inputRingOffset: UInt64 =
    UInt64(readerSlotOffset + readerSlotBytes * readerSlotCount)
  public static let phase1InputRingCapacity: UInt64 = 0
  public static let defaultOutputRingCapacity = 8 * 1024 * 1024
  public static let minimumOutputRingCapacity = 256 * 1024
  public static let maximumOutputRingCapacity = 64 * 1024 * 1024
  public static let phase1MetadataRingCapacity: UInt64 = 0
  public static let outputReadSafetyMarginBytes = 64 * 1024

  public static let outputBytesWrittenTotalOffset: UInt64 = 128
  public static let outputWrapCountOffset: UInt64 = 144
  public static let producerAliveMonoNsOffset: UInt64 = 160

  public struct Header: Equatable, Sendable {
    public var inputRingCapacity: UInt64
    public var outputRingCapacity: UInt64
    public var sessionIdHash: UInt64
    public var producerPid: UInt32
    public var createdAtUnixNs: UInt64

    public init(
      inputRingCapacity: UInt64 = LabptyByteRingLayout.phase1InputRingCapacity,
      outputRingCapacity: UInt64 = UInt64(LabptyByteRingLayout.defaultOutputRingCapacity),
      sessionIdHash: UInt64,
      producerPid: UInt32,
      createdAtUnixNs: UInt64
    ) {
      self.inputRingCapacity = inputRingCapacity
      self.outputRingCapacity = outputRingCapacity
      self.sessionIdHash = sessionIdHash
      self.producerPid = producerPid
      self.createdAtUnixNs = createdAtUnixNs
    }

    public var outputRingOffset: UInt64 {
      LabptyByteRingLayout.inputRingOffset + inputRingCapacity
    }

    public var metadataRingOffset: UInt64 {
      outputRingOffset + outputRingCapacity
    }

    public var fileByteCount: UInt64 {
      metadataRingOffset + LabptyByteRingLayout.phase1MetadataRingCapacity
    }
  }

  public static func isPowerOfTwo(_ value: UInt64) -> Bool {
    value > 0 && (value & (value - 1)) == 0
  }

  public static func validateOutputCapacity(_ capacity: UInt64) -> Bool {
    isPowerOfTwo(capacity)
      && capacity >= UInt64(minimumOutputRingCapacity)
      && capacity <= UInt64(maximumOutputRingCapacity)
  }

  public static func readableOutputWindow(for capacity: UInt64) -> UInt64 {
    let margin = min(UInt64(outputReadSafetyMarginBytes), capacity / 4)
    return capacity - margin
  }

  public static func fnv1a64(_ string: String) -> UInt64 {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in string.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x100000001b3
    }
    return hash
  }
}
