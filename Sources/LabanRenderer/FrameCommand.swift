import CoreGraphics

public enum FrameSource: String, Sendable {
  case sidebar
  case chrome
  case terminal
  case cursor
  case selection
  case find
  case image
}

public enum UnderlineStyle: UInt8, Sendable, Codable, Equatable {
  case none = 0
  case single = 1
  case double = 2
  case curly = 3
  case dotted = 4
  case dashed = 5

  public var name: String? {
    switch self {
    case .none: return nil
    case .single: return "single"
    case .double: return "double"
    case .curly: return "curly"
    case .dotted: return "dotted"
    case .dashed: return "dashed"
    }
  }

  public init(name: String) {
    switch name {
    case "single": self = .single
    case "double": self = .double
    case "curly": self = .curly
    case "dotted": self = .dotted
    case "dashed": self = .dashed
    default: self = .none
    }
  }
}

public struct TextAttributes: OptionSet, Sendable, Codable, Equatable {
  public let rawValue: UInt16

  public init(rawValue: UInt16) {
    self.rawValue = rawValue
  }

  public static let bold = TextAttributes(rawValue: 1 << 0)
  public static let italic = TextAttributes(rawValue: 1 << 1)
  public static let faint = TextAttributes(rawValue: 1 << 2)
  public static let inverse = TextAttributes(rawValue: 1 << 3)
  public static let invisible = TextAttributes(rawValue: 1 << 4)
  public static let underline = TextAttributes(rawValue: 1 << 5)
  public static let strikethrough = TextAttributes(rawValue: 1 << 6)
  public static let overline = TextAttributes(rawValue: 1 << 7)
  public static let blink = TextAttributes(rawValue: 1 << 8)

  public static let renderableMask: TextAttributes = [
    .bold, .italic, .faint, .inverse, .invisible, .underline, .strikethrough, .overline, .blink,
  ]

  /// Attributes the GPU-driven cell path renders without falling back to the
  /// classic command path. These are all colour/visibility-safe: `FrameProducer`
  /// pre-resolves `inverse` (the C bridge swaps fg/bg) and `faint` (fg is blended
  /// toward bg) into the final colours the cell record already carries, an
  /// `invisible` cell emits no glyph, and `blink` has no static visual. Font
  /// selection only reads bold/italic, so none of these change the glyph or its
  /// geometry. Decorations, clusters, and wide cells are folded in by later M4
  /// slices as the cell path learns to draw them.
  public static let gpuCellRenderableMask: TextAttributes = [
    .bold, .italic, .faint, .inverse, .invisible, .blink,
  ]

  public var names: [String] {
    var result: [String] = []
    if contains(.bold) { result.append("bold") }
    if contains(.italic) { result.append("italic") }
    if contains(.faint) { result.append("faint") }
    if contains(.inverse) { result.append("inverse") }
    if contains(.invisible) { result.append("invisible") }
    if contains(.underline) { result.append("underline") }
    if contains(.strikethrough) { result.append("strikethrough") }
    if contains(.overline) { result.append("overline") }
    if contains(.blink) { result.append("blink") }
    return result
  }

  public init(names: [String]) {
    var attrs: TextAttributes = []
    for name in names {
      switch name {
      case "bold": attrs.insert(.bold)
      case "italic": attrs.insert(.italic)
      case "faint", "dim": attrs.insert(.faint)
      case "inverse": attrs.insert(.inverse)
      case "invisible": attrs.insert(.invisible)
      case "underline": attrs.insert(.underline)
      case "strikethrough": attrs.insert(.strikethrough)
      case "overline": attrs.insert(.overline)
      case "blink": attrs.insert(.blink)
      default: break
      }
    }
    self = attrs
  }
}

public enum FrameCommand: Sendable {
  case rect(CGRect, color: UInt32, source: FrameSource)
  case glyphRun(
    origin: CGPoint,
    text: String,
    foreground: UInt32,
    background: UInt32,
    attributes: TextAttributes,
    source: FrameSource,
    underlineStyle: UnderlineStyle = .none,
    underlineColor: UInt32? = nil,
    hyperlink: String? = nil
  )
  case cursor(CGRect, color: UInt32)
  case selection(CGRect, color: UInt32)
  case findMatch(CGRect, color: UInt32)
  case findSelected(CGRect, color: UInt32)
  case clip(CGRect)
  case texturedQuad(rect: CGRect, resourceId: UInt64, source: FrameSource)
}
