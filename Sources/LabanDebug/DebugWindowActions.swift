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
            try client.resize(
              sessionId: runtime.terminalClientRemoteSessionId(for: tab.sessionId),
              rows: Int(size.rows),
              cols: Int(size.cols)
            )
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

  /// Headless equivalent of the app's NSWindow focus observers
  /// (`TerminalBitmapView.reportFocus`): when the program enabled focus tracking
  /// (DEC private mode 1004), emit CSI I / CSI O. On the daemon-backed tier the
  /// local Session is fixture-mode, so `encodeFocus` only encodes — the bytes
  /// must be delivered to the daemon's PTY like `typeText`, or the app never
  /// sees focus changes.
  func windowFocus(_ request: WindowFocusActionRequest) -> DebugResponse {
    let focused = request.focused ?? true
    guard let tab = runtime.model.activeTab,
      let session = runtime.model.session(forTab: tab.id)
    else {
      return jsonError("no active session for windowFocus")
    }
    guard session.focusReportingEnabled,
      let bytes = session.encodeFocus(focused: focused), !bytes.isEmpty
    else {
      return runtime.actionResult(ok: true)
    }
    if let client = runtime.terminalSessionClient {
      do {
        try runtime.ensureTerminalClientSessionUnlocked(for: tab)
        try client.writeInput(
          sessionId: runtime.terminalClientRemoteSessionId(for: tab.sessionId),
          bytes: bytes)
      } catch {
        runtime.appendError(
          kind: "terminalClient.writeInput.failed",
          message: String(describing: error),
          sessionId: tab.sessionId,
          tabId: tab.id)
        return jsonError("windowFocus forward failed: \(error)")
      }
    } else {
      _ = session.sendFocus(focused: focused)
    }
    runtime.appendTerminalLog(sessionId: session.id, direction: "input", bytes: bytes)
    runtime.appendEvent(
      EventEntry(
        kind: "focus.reported", sessionId: tab.sessionId,
        action: focused ? "focusIn" : "focusOut"))
    runtime.renderFrameUnlocked()
    return runtime.actionResult(ok: true)
  }
}
