import CoreGraphics
import Foundation

final class VectorGlyphMaskAtlas {
  struct Key: Hashable {
    var font: ObjectIdentifier
    var glyph: CGGlyph
    var width: Int
    var height: Int
    var originX: Int
    var originY: Int
    var syntheticItalic: Bool = false
  }

  struct Entry: Equatable {
    var key: Key
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var origin: CGPoint
  }

  static let baseSlotSize = 16

  let width: Int
  let height: Int
  private let slotsWide: Int
  private let slotsHigh: Int
  private var occupiedSlots: [Bool]
  private var pixels: [UInt8]
  private var entries: [Key: Entry] = [:]
  private var sampleCounts: [Key: Int] = [:]

  init(width: Int = 2048, height: Int = 2048) {
    precondition(width > 0 && height > 0)
    precondition(width.isMultiple(of: Self.baseSlotSize))
    precondition(height.isMultiple(of: Self.baseSlotSize))
    self.width = width
    self.height = height
    self.slotsWide = width / Self.baseSlotSize
    self.slotsHigh = height / Self.baseSlotSize
    self.occupiedSlots = [Bool](repeating: false, count: slotsWide * slotsHigh)
    self.pixels = [UInt8](repeating: 0, count: width * height)
  }

  var entryCount: Int { entries.count }

  func entry(for key: Key) -> Entry? {
    entries[key]
  }

  func store(
    key: Key,
    width glyphWidth: Int,
    height glyphHeight: Int,
    origin: CGPoint,
    bytes: [UInt8]
  ) -> Entry? {
    guard glyphWidth > 0, glyphHeight > 0, bytes.count == glyphWidth * glyphHeight else {
      return nil
    }
    guard let entry = reserve(key: key, width: glyphWidth, height: glyphHeight, origin: origin)
    else { return nil }
    guard setBytes(bytes, for: entry) else { return nil }
    return entry
  }

  func reserve(
    key: Key,
    width glyphWidth: Int,
    height glyphHeight: Int,
    origin: CGPoint
  ) -> Entry? {
    guard glyphWidth > 0, glyphHeight > 0 else { return nil }
    if let existing = entries[key] { return existing }

    let slotWidth = (glyphWidth + Self.baseSlotSize - 1) / Self.baseSlotSize
    let slotHeight = (glyphHeight + Self.baseSlotSize - 1) / Self.baseSlotSize
    guard let slotOrigin = findFreeRegion(slotWidth: slotWidth, slotHeight: slotHeight) else {
      return nil
    }

    markRegion(slotOrigin, slotWidth: slotWidth, slotHeight: slotHeight, occupied: true)
    let pixelX = slotOrigin.x * Self.baseSlotSize
    let pixelY = slotOrigin.y * Self.baseSlotSize

    let entry = Entry(
      key: key,
      x: pixelX,
      y: pixelY,
      width: glyphWidth,
      height: glyphHeight,
      origin: origin)
    entries[key] = entry
    sampleCounts[key] = 0
    return entry
  }

  @discardableResult
  func setBytes(_ bytes: [UInt8], for entry: Entry) -> Bool {
    guard bytes.count == entry.width * entry.height else { return false }
    for row in 0..<entry.height {
      let sourceOffset = row * entry.width
      let destOffset = (entry.y + row) * width + entry.x
      pixels.replaceSubrange(
        destOffset..<(destOffset + entry.width),
        with: bytes[sourceOffset..<(sourceOffset + entry.width)])
    }
    return true
  }

  func remove(_ entry: Entry) {
    guard entries[entry.key] == entry else { return }
    entries.removeValue(forKey: entry.key)
    sampleCounts.removeValue(forKey: entry.key)
    let slotX = entry.x / Self.baseSlotSize
    let slotY = entry.y / Self.baseSlotSize
    let slotWidth = (entry.width + Self.baseSlotSize - 1) / Self.baseSlotSize
    let slotHeight = (entry.height + Self.baseSlotSize - 1) / Self.baseSlotSize
    markRegion((x: slotX, y: slotY), slotWidth: slotWidth, slotHeight: slotHeight, occupied: false)
  }

  func sampleCount(for entry: Entry) -> Int {
    sampleCounts[entry.key, default: 0]
  }

  func setSampleCount(_ count: Int, for entry: Entry) {
    guard entries[entry.key] == entry else { return }
    sampleCounts[entry.key] = max(0, count)
  }

  func bytes(for entry: Entry) -> [UInt8] {
    var result = [UInt8](repeating: 0, count: entry.width * entry.height)
    for row in 0..<entry.height {
      let sourceOffset = (entry.y + row) * width + entry.x
      let destOffset = row * entry.width
      result.replaceSubrange(
        destOffset..<(destOffset + entry.width),
        with: pixels[sourceOffset..<(sourceOffset + entry.width)])
    }
    return result
  }

  func transposedMortonSlotOrderPrefix(_ count: Int) -> [(x: Int, y: Int)] {
    let limit = min(max(0, count), slotsWide * slotsHigh)
    var result: [(x: Int, y: Int)] = []
    var index = 0
    while result.count < limit {
      let decoded = Self.transposedMortonDecode(index)
      if decoded.x < slotsWide, decoded.y < slotsHigh {
        result.append(decoded)
      }
      index += 1
    }
    return result
  }

  private func findFreeRegion(slotWidth: Int, slotHeight: Int) -> (x: Int, y: Int)? {
    guard slotWidth > 0, slotHeight > 0, slotWidth <= slotsWide, slotHeight <= slotsHigh else {
      return nil
    }
    var index = 0
    var visited = 0
    while visited < slotsWide * slotsHigh {
      let origin = Self.transposedMortonDecode(index)
      index += 1
      guard origin.x < slotsWide, origin.y < slotsHigh else { continue }
      visited += 1
      guard origin.x + slotWidth <= slotsWide, origin.y + slotHeight <= slotsHigh else {
        continue
      }
      guard origin.x.isMultiple(of: slotWidth), origin.y.isMultiple(of: slotHeight) else {
        continue
      }
      if regionIsFree(origin, slotWidth: slotWidth, slotHeight: slotHeight) {
        return origin
      }
    }
    return nil
  }

  private func regionIsFree(
    _ origin: (x: Int, y: Int),
    slotWidth: Int,
    slotHeight: Int
  ) -> Bool {
    for y in origin.y..<(origin.y + slotHeight) {
      for x in origin.x..<(origin.x + slotWidth) {
        if occupiedSlots[y * slotsWide + x] {
          return false
        }
      }
    }
    return true
  }

  private func markRegion(
    _ origin: (x: Int, y: Int),
    slotWidth: Int,
    slotHeight: Int,
    occupied: Bool
  ) {
    for y in origin.y..<(origin.y + slotHeight) {
      for x in origin.x..<(origin.x + slotWidth) {
        occupiedSlots[y * slotsWide + x] = occupied
      }
    }
  }

  private static func transposedMortonDecode(_ index: Int) -> (x: Int, y: Int) {
    var x = 0
    var y = 0
    var value = index
    var bit = 0
    while value > 0 {
      x |= (value & 1) << bit
      value >>= 1
      y |= (value & 1) << bit
      value >>= 1
      bit += 1
    }
    return (x: y, y: x)
  }
}
