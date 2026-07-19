import CoreGraphics
import Darwin

/// Shared monotonic seconds clock (mach_absolute_time-based) for the
/// per-glyph animation channel. `TerminalSurfaceController` stamps
/// `FrameCommand.glyphRun.outputTimestampSeconds` in this domain and the
/// Slug renderer converts both the stamp and its `timeSeconds` uniform to a
/// renderer-relative Float, so stamp and uniform always share one time base.
public enum MonotonicClock {
  private static let timebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
  }()

  public static func seconds() -> Double {
    Double(mach_absolute_time()) * Double(timebase.numer) / Double(timebase.denom) / 1e9
  }
}

public enum FrameSource: String, Sendable {
  case sidebar
  case chrome
  case terminal
  case cursor
  case selection
  case find
  case image
  /// IME/dictation composition (marked/preedit) text drawn at the cursor.
  /// Rendered with the terminal glyph atlas and an underline so it reads as
  /// pending, not committed. Distinct from `.terminal` so the GPU-cell path
  /// can route it explicitly instead of treating it as payload-owned cells.
  case preedit
}

/// How a solid rectangle combines with pixels already present in the target.
/// Background-establishing rectangles use `replace` so repeated retained-frame
/// replay cannot accumulate translucent alpha; semantic overlays retain the
/// shipped source-over behavior.
public enum FrameCompositingMode: UInt8, Equatable, Sendable {
  case sourceOver
  case replace
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

  /// Converts the terminal core's wider semantic cell-flag field into glyph
  /// attributes. Cell flags such as explicit-background identity must never
  /// split font, glyph-atlas, or renderer batch keys.
  public init(cellFlags: UInt16) {
    self.rawValue = cellFlags & Self.renderableMask.rawValue
  }

  /// Attributes the GPU-driven cell path renders without falling back to the
  /// classic command path. These are all colour/visibility-safe: `FrameProducer`
  /// pre-resolves `inverse` (the C bridge swaps fg/bg) and `faint` (fg is blended
  /// toward bg) into the final colours the cell record already carries, an
  /// `invisible` cell emits no glyph, and `blink` has no static visual. Font
  /// selection only reads bold/italic, so none of these change the glyph or its
  /// geometry. Text decorations are emitted as solid overlays by the GPU-cell
  /// path, and wide/cluster glyph geometry is handled by the cell payload and
  /// atlas metrics rather than by attribute gating.
  public static let gpuCellRenderableMask: TextAttributes = [
    .bold, .italic, .faint, .inverse, .invisible, .underline, .strikethrough, .overline, .blink,
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
  case rect(
    CGRect,
    color: UInt32,
    source: FrameSource,
    compositing: FrameCompositingMode = .sourceOver
  )
  case glyphRun(
    origin: CGPoint,
    text: String,
    foreground: UInt32,
    background: UInt32,
    attributes: TextAttributes,
    source: FrameSource,
    underlineStyle: UnderlineStyle = .none,
    underlineColor: UInt32? = nil,
    hyperlink: String? = nil,
    displayCellCount: Int? = nil,
    /// Monotonic seconds (`MonotonicClock` domain) at which this run was first
    /// emitted after PTY output; nil = not fresh. Feeds the glyph-effect
    /// animation channel (`effectStart`); re-emissions caused by scroll,
    /// selection, or relayout damage keep nil so effects never restart.
    outputTimestampSeconds: Double? = nil
  )
  case cursor(CGRect, color: UInt32)
  case selection(CGRect, color: UInt32)
  case findMatch(CGRect, color: UInt32)
  case findSelected(CGRect, color: UInt32)
  case clip(CGRect)
  case texturedQuad(rect: CGRect, resourceId: UInt64, source: FrameSource)
}
