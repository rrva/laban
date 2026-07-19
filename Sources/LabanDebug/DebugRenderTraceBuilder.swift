import LabanRenderer

struct DebugRenderTraceTerminalSnapshot {
  var sessionId: String
  var rows: Int
  var cols: Int
}

struct DebugRenderTraceBuilder {
  var frame: Int
  var windowWidth: Int
  var windowHeight: Int
  var sidebarWidth: Int
  var surfaceWidth: Int
  var surfaceHeight: Int
  var surfaceScale: Double
  var cellWidth: Int
  var cellHeight: Int
  var hasActiveTab: Bool
  var terminalSnapshot: DebugRenderTraceTerminalSnapshot?
  var commands: [FrameCommand]
  var limit: Int
  var pixelProbes: [PixelProbeReq]?
  var pixelSampler: DebugPixelProbeSampler

  func response() -> RenderTraceResponse {
    let terminalViewportWidth = max(windowWidth - sidebarWidth, 1)
    let sourceRefs = SourceRefs(frame: frame)
    let serializer = DebugFrameCommandSerializer(cellWidth: cellWidth, cellHeight: cellHeight)
    let traceCommands = serializedCommands(serializer: serializer)
    let clipRect = RectResponse(x: 0, y: 0, width: windowWidth, height: windowHeight)

    return RenderTraceResponse(
      traceId: "frame-\(frame)",
      frame: frame,
      backend: "software",
      surface: SurfaceResponse(width: surfaceWidth, height: surfaceHeight, scale: surfaceScale),
      sources: sources(sourceRefs: sourceRefs),
      layout: layout(terminalViewportWidth: terminalViewportWidth, sourceRefs: sourceRefs),
      packets: packets(sourceRefs: sourceRefs),
      commandRanges: commandRanges(sourceRefs: sourceRefs),
      commands: traceCommands.commands,
      resources: [
        TraceResource(id: "font-jetbrainsmono", kind: "font", status: "resident"),
        TraceResource(
          id: "surface-main", kind: "surface", status: "resident",
          width: surfaceWidth, height: surfaceHeight),
      ],
      passes: [
        TraceRenderPass(
          id: "pass-main",
          target: "window",
          draws: traceCommands.commands.isEmpty
            ? []
            : [
              TraceDraw(
                id: "draw-main",
                kind: "batch",
                commandRefs: traceCommands.commands.map(\.id),
                clip: clipRect,
                drawRect: clipRect)
            ])
      ],
      pixelProbes: pixelSampler.traceProbes(pixelProbes),
      invariants: [
        TraceInvariant(
          level: "ok",
          kind: "renderer.software",
          message: "trace produced from software renderer")
      ],
      truncated: traceCommands.truncated
    )
  }

  private func sources(sourceRefs: SourceRefs) -> [TraceSourceResponse] {
    var result = [
      TraceSourceResponse(id: sourceRefs.state, kind: "appState", revision: frame)
    ]

    if let terminalSnapshot {
      result.append(
        TraceSourceResponse(
          id: sourceRefs.terminalSnapshot,
          kind: "terminalSnapshot",
          sessionId: terminalSnapshot.sessionId,
          rows: terminalSnapshot.rows,
          cols: terminalSnapshot.cols
        ))
    }

    return result
  }

  private func layout(
    terminalViewportWidth: Int,
    sourceRefs: SourceRefs
  ) -> [TraceLayoutItem] {
    [
      TraceLayoutItem(
        id: "layout-window",
        kind: "window",
        rect: RectResponse(x: 0, y: 0, width: windowWidth, height: windowHeight),
        sourceRefs: [sourceRefs.state]),
      TraceLayoutItem(
        id: "layout-sidebar",
        kind: "sidebar",
        rect: RectResponse(x: 0, y: 0, width: sidebarWidth, height: windowHeight),
        sourceRefs: [sourceRefs.state]),
      TraceLayoutItem(
        id: "layout-terminal",
        kind: "terminalViewport",
        rect: RectResponse(
          x: sidebarWidth, y: 0, width: terminalViewportWidth, height: windowHeight),
        sourceRefs: [sourceRefs.state]),
    ]
  }

  private func packets(sourceRefs: SourceRefs) -> [TracePacket] {
    guard hasActiveTab else { return [] }
    let summary = commandSummary()
    return [
      TracePacket(
        id: "pkt-term-\(frame)",
        producer: "LabanTerminalCore",
        sourceRefs: [sourceRefs.terminalSnapshot],
        dirtyRows: [],
        glyphRuns: summary.terminalGlyphs,
        backgroundRuns: summary.terminalBackgroundRects)
    ]
  }

  private func commandRanges(sourceRefs: SourceRefs) -> [TraceCommandRange] {
    let summary = commandSummary()
    var result: [TraceCommandRange] = []

    if let first = summary.sidebarFirst, let last = summary.sidebarLast {
      result.append(
        TraceCommandRange(
          producer: "sidebar",
          inputRefs: [sourceRefs.state],
          firstCommandId: "cmd-\(first)",
          lastCommandId: "cmd-\(last)"
        ))
    }

    if let first = summary.terminalFirst, let last = summary.terminalLast {
      result.append(
        TraceCommandRange(
          producer: "terminal",
          inputRefs: ["pkt-term-\(frame)"],
          firstCommandId: "cmd-\(first)",
          lastCommandId: "cmd-\(last)"
        ))
    }

    return result
  }

  private func serializedCommands(
    serializer: DebugFrameCommandSerializer
  ) -> (commands: [TraceCommand], truncated: Bool) {
    var result: [TraceCommand] = []
    var truncated = false

    for (index, command) in commands.enumerated() {
      if result.count >= limit {
        truncated = true
        break
      }
      result.append(serializer.traceCommand(command, index: index))
    }

    return (result, truncated)
  }

  private func commandSummary() -> CommandSummary {
    var summary = CommandSummary()

    for (index, command) in commands.enumerated() {
      switch command {
      case .rect(_, _, let source, _) where source == .sidebar:
        summary.sidebarFirst = summary.sidebarFirst ?? index
        summary.sidebarLast = index
      case .rect(_, _, let source, _) where source == .terminal:
        summary.terminalBackgroundRects += 1
        summary.terminalFirst = summary.terminalFirst ?? index
        summary.terminalLast = index
      case .glyphRun(_, _, _, _, _, let source, _, _, _, _, _) where source == .sidebar:
        summary.sidebarFirst = summary.sidebarFirst ?? index
        summary.sidebarLast = index
      case .glyphRun(_, _, _, _, _, let source, _, _, _, _, _) where source == .terminal:
        summary.terminalGlyphs += 1
        summary.terminalFirst = summary.terminalFirst ?? index
        summary.terminalLast = index
      default:
        break
      }
    }

    return summary
  }

  private struct SourceRefs {
    var frame: Int

    var state: String { "state-\(frame)" }
    var terminalSnapshot: String { "term-snap-\(frame)" }
  }

  private struct CommandSummary {
    var terminalGlyphs = 0
    var terminalBackgroundRects = 0
    var sidebarFirst: Int?
    var sidebarLast: Int?
    var terminalFirst: Int?
    var terminalLast: Int?
  }
}
