import CoreGraphics
import Foundation

/// Renderer-neutral terminal cell data captured while the libghostty snapshot
/// is still alive. This is an acceleration channel for Metal's GPU-cell path;
/// `[FrameCommand]` remains the shared debug, replay, and software language.
public struct TerminalCellPayload: Equatable, Sendable {
  public enum FallbackReason: String, Codable, Equatable, Sendable {
    case missingCellStorage
    case invalidUTF8
    case selectionOrFindOverlay
    case exitBanner
    case wideOrClusterCell
    case proceduralCell
    case unsupportedAttributes
    case textDecoration
    case hyperlink
  }

  public struct BackgroundRun: Equatable, Sendable {
    public var row: Int
    public var startCol: Int
    public var colCount: Int
    public var color: UInt32

    public init(row: Int, startCol: Int, colCount: Int, color: UInt32) {
      self.row = row
      self.startCol = startCol
      self.colCount = colCount
      self.color = color
    }
  }

  public struct Glyph: Equatable, Sendable {
    /// Sentinel for "no single scalar": valid Unicode scalar values end at
    /// 0x10FFFF, so this can never collide with real content.
    @usableFromInline internal static let noScalar: UInt32 = 0xFFFF_FFFF

    public var row: Int
    public var col: Int
    public var foreground: UInt32
    public var background: UInt32
    @usableFromInline internal var scalarRaw: UInt32
    @usableFromInline internal var underlineColorRaw: UInt32
    @usableFromInline internal var utf8Start: Int32
    @usableFromInline internal var utf8Length: Int32
    public var attributes: TextAttributes
    public var underlineStyle: UnderlineStyle
    public var hasHyperlink: Bool
    public var wide: UInt8

    /// POD storage: cluster text lives in the payload's `utf8Bytes` side
    /// buffer (`utf8Range`) or as a single scalar — never inline, so arrays
    /// of `Glyph` copy with memcpy and destroy without ARC. Accessors are
    /// `@inlinable` so the producer (LabanCore) and renderer keep these as
    /// register ops instead of cross-module calls in their per-cell loops.
    public var scalarValue: UInt32? {
      @inlinable @inline(__always) get { scalarRaw == Self.noScalar ? nil : scalarRaw }
      @inlinable @inline(__always) set { scalarRaw = newValue ?? Self.noScalar }
    }

    /// 0 means "no explicit underline color", matching the producer, which
    /// maps `cell.underline_color_rgba == 0` to nil before constructing.
    public var underlineColor: UInt32? {
      @inlinable @inline(__always) get { underlineColorRaw == 0 ? nil : underlineColorRaw }
      @inlinable @inline(__always) set { underlineColorRaw = newValue ?? 0 }
    }

    public var utf8Range: Range<Int>? {
      @inlinable @inline(__always) get {
        utf8Length == 0 ? nil : Int(utf8Start)..<Int(utf8Start) + Int(utf8Length)
      }
      @inlinable @inline(__always) set {
        if let newValue, !newValue.isEmpty {
          utf8Start = Int32(newValue.lowerBound)
          utf8Length = Int32(newValue.count)
        } else {
          utf8Start = 0
          utf8Length = 0
        }
      }
    }

    @inlinable
    public init(
      row: Int,
      col: Int,
      scalarValue: UInt32? = nil,
      foreground: UInt32,
      background: UInt32,
      attributes: TextAttributes,
      underlineStyle: UnderlineStyle = .none,
      underlineColor: UInt32? = nil,
      hasHyperlink: Bool = false,
      wide: UInt8 = 0,
      utf8Range: Range<Int>? = nil
    ) {
      self.row = row
      self.col = col
      self.foreground = foreground
      self.background = background
      self.scalarRaw = scalarValue ?? Self.noScalar
      self.underlineColorRaw = underlineColor ?? 0
      if let utf8Range, !utf8Range.isEmpty {
        self.utf8Start = Int32(utf8Range.lowerBound)
        self.utf8Length = Int32(utf8Range.count)
      } else {
        self.utf8Start = 0
        self.utf8Length = 0
      }
      self.attributes = attributes
      self.underlineStyle = underlineStyle
      self.hasHyperlink = hasHyperlink
      self.wide = wide
    }
  }

  public struct ProceduralCell: Equatable, Sendable {
    public var row: Int
    public var col: Int
    public var scalarValue: UInt32
    public var foreground: UInt32

    public init(row: Int, col: Int, scalarValue: UInt32, foreground: UInt32) {
      self.row = row
      self.col = col
      self.scalarValue = scalarValue
      self.foreground = foreground
    }
  }

  public struct CursorRect: Equatable, Sendable {
    public var rect: CGRect
    public var color: UInt32

    public init(rect: CGRect, color: UInt32) {
      self.rect = rect
      self.color = color
    }
  }

  public var rows: Int
  public var cols: Int
  public var origin: CGPoint
  public var cellSize: CGSize
  public var contentYOffset: CGFloat
  public var defaultBackground: UInt32
  /// Top-down row indices included in this payload. On partial damage this is
  /// only the dirty rows; on full damage it is every visible row.
  public var dirtyRows: [Int]
  public var backgroundRuns: [BackgroundRun]
  public var glyphs: [Glyph]
  public var proceduralCells: [ProceduralCell]
  public var cursorRects: [CursorRect]
  public var utf8Bytes: [UInt8]
  public var fallbackReason: FallbackReason?

  public var isGPUCellCompatible: Bool { fallbackReason == nil }

  public init(
    rows: Int,
    cols: Int,
    origin: CGPoint,
    cellSize: CGSize,
    contentYOffset: CGFloat,
    defaultBackground: UInt32,
    dirtyRows: [Int] = [],
    backgroundRuns: [BackgroundRun] = [],
    glyphs: [Glyph] = [],
    proceduralCells: [ProceduralCell] = [],
    cursorRects: [CursorRect] = [],
    utf8Bytes: [UInt8] = [],
    fallbackReason: FallbackReason? = nil
  ) {
    self.rows = rows
    self.cols = cols
    self.origin = origin
    self.cellSize = cellSize
    self.contentYOffset = contentYOffset
    self.defaultBackground = defaultBackground
    self.dirtyRows = dirtyRows
    self.backgroundRuns = backgroundRuns
    self.glyphs = glyphs
    self.proceduralCells = proceduralCells
    self.cursorRects = cursorRects
    self.utf8Bytes = utf8Bytes
    self.fallbackReason = fallbackReason
  }

  public var terminalRect: CGRect {
    CGRect(
      x: origin.x,
      y: origin.y,
      width: CGFloat(cols) * cellSize.width,
      height: CGFloat(rows) * cellSize.height
    )
  }

  public func cellRect(row: Int, col: Int) -> CGRect {
    CGRect(
      x: origin.x + CGFloat(col) * cellSize.width,
      y: origin.y + CGFloat(rows - 1 - row) * cellSize.height + contentYOffset,
      width: cellSize.width,
      height: cellSize.height
    )
  }

  public struct CapacitySnapshot: Equatable, Sendable {
    public var dirtyRows: Int
    public var backgroundRuns: Int
    public var glyphs: Int
    public var proceduralCells: Int
    public var cursorRects: Int
    public var utf8Bytes: Int
  }

  public var capacitySnapshot: CapacitySnapshot {
    CapacitySnapshot(
      dirtyRows: dirtyRows.capacity,
      backgroundRuns: backgroundRuns.capacity,
      glyphs: glyphs.capacity,
      proceduralCells: proceduralCells.capacity,
      cursorRects: cursorRects.capacity,
      utf8Bytes: utf8Bytes.capacity)
  }

  public mutating func reset(
    rows: Int,
    cols: Int,
    origin: CGPoint,
    cellSize: CGSize,
    contentYOffset: CGFloat,
    defaultBackground: UInt32,
    fallbackReason: FallbackReason? = nil
  ) {
    self.rows = rows
    self.cols = cols
    self.origin = origin
    self.cellSize = cellSize
    self.contentYOffset = contentYOffset
    self.defaultBackground = defaultBackground
    self.fallbackReason = fallbackReason
    dirtyRows.removeAll(keepingCapacity: true)
    backgroundRuns.removeAll(keepingCapacity: true)
    glyphs.removeAll(keepingCapacity: true)
    proceduralCells.removeAll(keepingCapacity: true)
    cursorRects.removeAll(keepingCapacity: true)
    utf8Bytes.removeAll(keepingCapacity: true)
  }

  /// Appends a glyph for `cluster` using the same storage rule as
  /// `FrameProducer.fillTerminalCellPayload`: a single Unicode scalar is
  /// stored inline as `scalarValue`; any other cluster is appended to
  /// `utf8Bytes` and referenced by `utf8Range`. Intended for test fixtures
  /// that previously stored arbitrary text on the glyph itself.
  public mutating func appendGlyph(
    row: Int,
    col: Int,
    cluster: String,
    foreground: UInt32,
    background: UInt32,
    attributes: TextAttributes,
    underlineStyle: UnderlineStyle = .none,
    underlineColor: UInt32? = nil,
    hasHyperlink: Bool = false,
    wide: UInt8 = 0
  ) {
    var glyph = Glyph(
      row: row,
      col: col,
      foreground: foreground,
      background: background,
      attributes: attributes,
      underlineStyle: underlineStyle,
      underlineColor: underlineColor,
      hasHyperlink: hasHyperlink,
      wide: wide)
    let scalars = cluster.unicodeScalars
    if scalars.count == 1, let scalar = scalars.first {
      glyph.scalarValue = scalar.value
    } else if !cluster.isEmpty {
      let start = utf8Bytes.count
      utf8Bytes.append(contentsOf: cluster.utf8)
      glyph.utf8Range = start..<utf8Bytes.count
    }
    glyphs.append(glyph)
  }
}
