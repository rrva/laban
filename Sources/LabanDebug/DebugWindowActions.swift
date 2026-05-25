import LabanRenderer

struct DebugWindowActions {
  private unowned let runtime: HeadlessDebugRuntime

  init(runtime: HeadlessDebugRuntime) {
    self.runtime = runtime
  }

  func resizeWindow(_ request: ResizeWindowActionRequest) -> DebugResponse {
    guard let width = request.width, let height = request.height else {
      return jsonError("resizeWindow requires width and height")
    }
    runtime.windowWidth = max(width, runtime.sidebarWidth + 1)
    runtime.windowHeight = max(height, 1)
    runtime.surface = BitmapSurface(width: runtime.windowWidth, height: runtime.windowHeight)
    runtime.renderer = SoftwareRenderer(surface: runtime.surface, fontAtlas: runtime.fontAtlas)
    runtime.model.resize(
      viewportWidth: runtime.windowWidth - runtime.sidebarWidth,
      viewportHeight: runtime.windowHeight,
      cellWidth: runtime.cellWidth,
      cellHeight: runtime.cellHeight
    )
    if let client = runtime.terminalSessionClient {
      let size = runtime.model.terminalSize
      for tab in runtime.model.tabs {
        do {
          try runtime.ensureTerminalClientSessionUnlocked(for: tab)
          runtime.terminalClientSessionInfoById[tab.sessionId] =
            try client.resize(sessionId: tab.sessionId, rows: Int(size.rows), cols: Int(size.cols))
        } catch {
          runtime.appendError(
            kind: "laband.resize.failed",
            message: String(describing: error),
            sessionId: tab.sessionId,
            tabId: tab.id
          )
          return jsonError("resizeWindow failed: \(error)")
        }
      }
    }
    runtime.renderFrameUnlocked()
    runtime.appendEvent(
      EventEntry(kind: "window.resized", width: runtime.windowWidth, height: runtime.windowHeight)
    )
    return runtime.actionResult(ok: true)
  }

  func advanceFrames(_ request: AdvanceFramesActionRequest) -> DebugResponse {
    let count = max(request.count ?? 1, 1)
    for _ in 0..<count {
      runtime.renderFrameUnlocked()
    }
    return runtime.actionResult(ok: true)
  }
}
