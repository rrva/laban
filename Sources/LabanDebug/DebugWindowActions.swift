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
