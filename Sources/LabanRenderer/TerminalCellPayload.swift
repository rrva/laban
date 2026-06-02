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
    public var row: Int
    public var col: Int
    public var text: String
    public var scalarValue: UInt32?
    public var foreground: UInt32
    public var background: UInt32
    public var attributes: TextAttributes
    public var underlineStyle: UnderlineStyle
    public var underlineColor: UInt32?
    public var hasHyperlink: Bool
    public var wide: UInt8
    public var utf8Range: Range<Int>?

    public init(
      row: Int,
      col: Int,
      text: String,
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
      self.text = text
      self.scalarValue = scalarValue
      self.foreground = foreground
      self.background = background
      self.attributes = attributes
      self.underlineStyle = underlineStyle
      self.underlineColor = underlineColor
      self.hasHyperlink = hasHyperlink
      self.wide = wide
      self.utf8Range = utf8Range
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
}
