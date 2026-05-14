import CoreGraphics
import LabanRenderer

struct DebugFrameCommandSerializer {
  var cellWidth: Int
  var cellHeight: Int

  func listCommand(
    _ command: FrameCommand,
    index: Int,
    includeText: Bool
  ) -> FrameCommandResponse {
    let id = "cmd-\(index)"
    switch command {
    case .rect(let rect, let color, let source):
      return FrameCommandResponse(
        id: id, index: index, kind: "rect", source: source.rawValue,
        rect: Self.rectResponse(rect), color: Self.rgbaArray(color))
    case .glyphRun(
      let origin, let text, let foreground, let background, let attributes, let source,
      let underlineStyle, let underlineColor, let hyperlink
    ):
      let approxRect = CGRect(
        x: origin.x, y: origin.y,
        width: CGFloat(text.count * cellWidth), height: CGFloat(cellHeight)
      )
      let attributeNames = attributes.names
      return FrameCommandResponse(
        id: id, index: index, kind: "glyphRun", source: source.rawValue,
        rect: Self.rectResponse(approxRect),
        foreground: Self.rgbaArray(foreground),
        background: Self.rgbaArray(background),
        text: includeText ? text : nil,
        attributes: attributeNames.isEmpty ? nil : attributeNames,
        underlineStyle: underlineStyle.name,
        underlineColor: underlineColor.map { Self.rgbaArray($0) },
        hyperlink: hyperlink
      )
    case .cursor(let rect, let color):
      return FrameCommandResponse(
        id: id, index: index, kind: "cursor", source: "cursor",
        rect: Self.rectResponse(rect), color: Self.rgbaArray(color))
    case .selection(let rect, let color):
      return FrameCommandResponse(
        id: id, index: index, kind: "selection", source: "selection",
        rect: Self.rectResponse(rect), color: Self.rgbaArray(color))
    case .findMatch(let rect, let color):
      return FrameCommandResponse(
        id: id, index: index, kind: "findMatch", source: "find",
        rect: Self.rectResponse(rect), color: Self.rgbaArray(color))
    case .findSelected(let rect, let color):
      return FrameCommandResponse(
        id: id, index: index, kind: "findSelected", source: "find",
        rect: Self.rectResponse(rect), color: Self.rgbaArray(color))
    case .clip(let rect):
      return FrameCommandResponse(
        id: id, index: index, kind: "clip", source: "unknown",
        rect: Self.rectResponse(rect))
    case .texturedQuad(let rect, let resourceId, let source):
      return FrameCommandResponse(
        id: id, index: index, kind: "texturedQuad", source: source.rawValue,
        rect: Self.rectResponse(rect), resourceId: String(resourceId))
    }
  }

  func traceCommand(_ command: FrameCommand, index: Int) -> TraceCommand {
    let id = "cmd-\(index)"
    switch command {
    case .rect(let rect, _, let source):
      return TraceCommand(
        id: id, index: index, kind: "rect",
        source: source.rawValue, rect: Self.rectResponse(rect))
    case .glyphRun(let origin, let text, _, _, let attributes, let source, _, _, _):
      let approxRect = CGRect(
        x: origin.x, y: origin.y,
        width: CGFloat(text.count * cellWidth), height: CGFloat(cellHeight)
      )
      let attributeNames = attributes.names
      return TraceCommand(
        id: id, index: index, kind: "glyphRun", source: source.rawValue,
        rect: Self.rectResponse(approxRect), text: text,
        attributes: attributeNames.isEmpty ? nil : attributeNames)
    case .cursor(let rect, _):
      return TraceCommand(
        id: id, index: index, kind: "cursor",
        source: "cursor", rect: Self.rectResponse(rect))
    case .selection(let rect, _):
      return TraceCommand(
        id: id, index: index, kind: "selection",
        source: "selection", rect: Self.rectResponse(rect))
    case .findMatch(let rect, _):
      return TraceCommand(
        id: id, index: index, kind: "findMatch",
        source: "find", rect: Self.rectResponse(rect))
    case .findSelected(let rect, _):
      return TraceCommand(
        id: id, index: index, kind: "findSelected",
        source: "find", rect: Self.rectResponse(rect))
    case .clip(let rect):
      return TraceCommand(
        id: id, index: index, kind: "clip",
        source: "unknown", rect: Self.rectResponse(rect))
    case .texturedQuad(let rect, _, let source):
      return TraceCommand(
        id: id, index: index, kind: "texturedQuad",
        source: source.rawValue, rect: Self.rectResponse(rect))
    }
  }

  static func kind(_ command: FrameCommand) -> String {
    switch command {
    case .rect: return "rect"
    case .glyphRun: return "glyphRun"
    case .cursor: return "cursor"
    case .selection: return "selection"
    case .findMatch: return "findMatch"
    case .findSelected: return "findSelected"
    case .clip: return "clip"
    case .texturedQuad: return "texturedQuad"
    }
  }

  static func rgbaArray(_ color: UInt32) -> [Int] {
    [
      Int((color >> 24) & 0xFF),
      Int((color >> 16) & 0xFF),
      Int((color >> 8) & 0xFF),
      Int(color & 0xFF),
    ]
  }

  static func rectResponse(_ rect: CGRect) -> RectResponse {
    RectResponse(
      x: Int(rect.origin.x), y: Int(rect.origin.y),
      width: Int(rect.size.width), height: Int(rect.size.height)
    )
  }
}
