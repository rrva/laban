import CoreGraphics
import Foundation
import LabanCore
import LabanRenderer
import LabanTerminalCore

struct DebugMouseActions {
  private unowned let runtime: HeadlessDebugRuntime

  init(runtime: HeadlessDebugRuntime) {
    self.runtime = runtime
  }

  func mouseWheel(_ request: MouseWheelActionRequest) -> DebugResponse {
    let frameBefore = runtime.currentFrame
    guard let x = request.x, let y = request.y, let deltaY = request.deltaY else {
      return jsonError("mouseWheel requires x, y, and deltaY")
    }
    if x < runtime.sidebarWidth {
      runtime.appendEvent(EventEntry(kind: "mouse.sidebar", action: "mouseWheel"))
      return runtime.actionResult(ok: true)
    }
    guard let tab = runtime.model.activeTab,
      let session = runtime.model.session(forTab: tab.id)
    else {
      return jsonError("no active session for mouseWheel")
    }
    let terminalPoint = runtime.terminalMousePosition(x: x, y: y)
    let isUp = deltaY > 0

    let viewportState = session.viewportState()
    if viewportState?.mouseTracking == true {
      return sendTrackedWheel(
        isUp: isUp,
        terminalPoint: terminalPoint,
        frameBefore: frameBefore,
        tab: tab,
        session: session
      )
    } else if viewportState?.altScreen == true, viewportState?.altScroll == true {
      // Alternate scroll mode (DEC private 1007): the alternate screen has no
      // scrollback, so a notch drives the app's cursor keys instead. Mirrors
      // TerminalBitmapView.scrollWheel so headless runs match the real app.
      return sendAltScrollWheel(
        isUp: isUp, frameBefore: frameBefore, tab: tab, session: session)
    } else {
      return scrollWheel(isUp: isUp, frameBefore: frameBefore, tab: tab, session: session)
    }
  }

  private func sendAltScrollWheel(
    isUp: Bool,
    frameBefore: Int,
    tab: Tab,
    session: Session
  ) -> DebugResponse {
    // One wheel notch maps to one cursor-key press; Up scrolls toward earlier
    // content, matching less/man/vim on the alternate screen. The key encoder
    // picks ESC O A vs ESC [ A from the app's DECCKM state.
    let key: Key = isUp ? .arrowUp : .arrowDown
    let sent = session.sendKeyCapturingBytes(KeyEvent(action: .press, key: key))
    let encoded = sent.result == 0 ? sent.bytes : []
    if !encoded.isEmpty {
      runtime.appendTerminalLog(sessionId: session.id, direction: "input", bytes: encoded)
    }
    runtime.appendInputEnvelope(
      InputEventEnvelope(
        inputId: UUID().uuidString,
        source: "debug",
        kind: "scroll",
        route: "terminal",
        frameBefore: frameBefore,
        tabId: tab.id,
        sessionId: session.id,
        command: "altScroll",
        encodedHex: encoded.isEmpty
          ? nil
          : encoded.map { String(format: "%02x", $0) }.joined(),
        encodedLength: encoded.isEmpty ? nil : encoded.count
      ))
    runtime.appendEvent(
      EventEntry(kind: "mouse.sent", sessionId: tab.sessionId, action: "altScroll"))
    runtime.renderFrameUnlocked()
    return jsonEncode(
      MouseActionResult(
        ok: sent.result == 0, frame: runtime.currentFrame,
        activeTabId: tab.id, activeSessionId: tab.sessionId,
        mouseTracking: false, sent: sent.result == 0
      ))
  }

  func click(_ request: ClickActionRequest) -> DebugResponse {
    let frameBefore = runtime.currentFrame
    guard let x = request.x, let y = request.y, let button = request.button else {
      return jsonError("click requires x, y, and button")
    }
    if x < runtime.sidebarWidth {
      return clickSidebar(x: x, y: y)
    }
    guard let tab = runtime.model.activeTab,
      let session = runtime.model.session(forTab: tab.id)
    else {
      return jsonError("no active session for click")
    }
    let terminalPoint = runtime.terminalMousePosition(x: x, y: y)

    if let viewportState = session.viewportState(), viewportState.mouseTracking {
      return sendMouseClick(
        button: button,
        terminalPoint: terminalPoint,
        frameBefore: frameBefore,
        tab: tab,
        session: session
      )
    } else {
      return setClickSelection(
        terminalPoint: terminalPoint,
        frameBefore: frameBefore,
        tab: tab,
        session: session
      )
    }
  }

  private func sendTrackedWheel(
    isUp: Bool,
    terminalPoint: (x: Float, y: Float),
    frameBefore: Int,
    tab: Tab,
    session: Session
  ) -> DebugResponse {
    let button: MouseButton = isUp ? .wheelUp : .wheelDown
    let mouseEvent = MouseEvent(
      action: .press,
      button: button,
      x: terminalPoint.x,
      y: terminalPoint.y,
      screenWidth: runtime.terminalSurfaceWidth,
      screenHeight: runtime.windowHeight,
      cellWidth: runtime.cellWidth,
      cellHeight: runtime.cellHeight
    )
    let sent = session.sendMouseCapturingBytes(mouseEvent)
    let encoded = sent.bytes
    if !encoded.isEmpty {
      forwardEncodedInputToDaemon(encoded, tab: tab, session: session)
      runtime.appendTerminalLog(sessionId: session.id, direction: "input", bytes: encoded)
    }
    runtime.appendInputEnvelope(
      InputEventEnvelope(
        inputId: UUID().uuidString,
        source: "debug",
        kind: "mouse",
        route: "terminal",
        frameBefore: frameBefore,
        tabId: tab.id,
        sessionId: session.id,
        command: "mouseWheel",
        encodedHex: encoded.isEmpty
          ? nil
          : encoded.map { String(format: "%02x", $0) }
            .joined(),
        encodedLength: encoded.isEmpty ? nil : encoded.count
      ))
    runtime.appendEvent(
      EventEntry(kind: "mouse.sent", sessionId: tab.sessionId, action: "mouseWheel")
    )
    runtime.renderFrameUnlocked()
    return jsonEncode(
      MouseActionResult(
        ok: sent.result == 0, frame: runtime.currentFrame,
        activeTabId: tab.id, activeSessionId: tab.sessionId,
        mouseTracking: true, sent: sent.result == 0
      ))
  }

  private func scrollWheel(
    isUp: Bool,
    frameBefore: Int,
    tab: Tab,
    session: Session
  ) -> DebugResponse {
    let rows = isUp ? -1 : 1
    session.scrollViewport(deltaRows: rows)
    runtime.appendInputEnvelope(
      InputEventEnvelope(
        inputId: UUID().uuidString,
        source: "debug",
        kind: "mouse",
        route: "terminal",
        frameBefore: frameBefore,
        tabId: tab.id,
        sessionId: session.id,
        command: "mouseWheel",
        deltaRows: rows
      ))
    runtime.renderFrameUnlocked()
    runtime.appendEvent(
      EventEntry(
        kind: "viewport.scrolled", sessionId: tab.sessionId, action: "mouseWheel",
        deltaRows: rows))
    return runtime.actionResult(ok: true)
  }

  private func clickSidebar(x: Int, y: Int) -> DebugResponse {
    let sidebarProducer = SidebarProducer(
      sidebarWidth: CGFloat(runtime.sidebarWidth),
      cellWidth: CGFloat(runtime.cellWidth),
      cellHeight: CGFloat(runtime.cellHeight)
    )
    let point = CGPoint(x: CGFloat(x), y: CGFloat(y))
    switch sidebarProducer.hitTest(
      at: point,
      tabs: runtime.model.tabs,
      height: CGFloat(runtime.windowHeight)
    ) {
    case .newTab:
      do { try runtime.model.createTab() } catch {
        return jsonError("createTab failed: \(error)")
      }
      runtime.renderFrameUnlocked()
      runtime.appendEvent(EventEntry(kind: "tab.created", tabId: runtime.model.activeTab?.id))
    case .selectTab(let id):
      runtime.model.selectTab(id)
      runtime.renderFrameUnlocked()
      runtime.appendEvent(EventEntry(kind: "tab.selected", tabId: id))
    case .closeTab(let id):
      do { try runtime.model.closeTab(id) } catch {
        return jsonError("closeTab failed: \(error)")
      }
      runtime.renderFrameUnlocked()
      runtime.appendEvent(EventEntry(kind: "tab.closed", tabId: id))
    case .none:
      break
    }
    runtime.appendEvent(EventEntry(kind: "mouse.sidebar", action: "click"))
    return runtime.actionResult(ok: true)
  }

  private func sendMouseClick(
    button: String,
    terminalPoint: (x: Float, y: Float),
    frameBefore: Int,
    tab: Tab,
    session: Session
  ) -> DebugResponse {
    let mouseButton: MouseButton
    switch button {
    case "middle": mouseButton = .middle
    case "right": mouseButton = .right
    default: mouseButton = .left
    }
    let pressEvent = MouseEvent(
      action: .press,
      button: mouseButton,
      x: terminalPoint.x,
      y: terminalPoint.y,
      screenWidth: runtime.terminalSurfaceWidth,
      screenHeight: runtime.windowHeight,
      cellWidth: runtime.cellWidth,
      cellHeight: runtime.cellHeight
    )
    let releaseEvent = MouseEvent(
      action: .release,
      button: mouseButton,
      x: terminalPoint.x,
      y: terminalPoint.y,
      screenWidth: runtime.terminalSurfaceWidth,
      screenHeight: runtime.windowHeight,
      cellWidth: runtime.cellWidth,
      cellHeight: runtime.cellHeight
    )
    let pressSent = session.sendMouseCapturingBytes(pressEvent)
    let releaseSent =
      pressSent.result == 0
      ? session.sendMouseCapturingBytes(releaseEvent)
      : Session.CapturedMouseWrite(result: -1, bytes: [])
    let encoded = pressSent.bytes + releaseSent.bytes
    if !encoded.isEmpty {
      forwardEncodedInputToDaemon(encoded, tab: tab, session: session)
      runtime.appendTerminalLog(sessionId: session.id, direction: "input", bytes: encoded)
    }
    runtime.appendInputEnvelope(
      InputEventEnvelope(
        inputId: UUID().uuidString,
        source: "debug",
        kind: "mouse",
        route: "terminal",
        frameBefore: frameBefore,
        tabId: tab.id,
        sessionId: session.id,
        command: "click",
        encodedHex: encoded.isEmpty
          ? nil
          : encoded.map { String(format: "%02x", $0) }
            .joined(),
        encodedLength: encoded.isEmpty ? nil : encoded.count
      ))
    runtime.renderFrameUnlocked()
    runtime.appendEvent(EventEntry(kind: "mouse.sent", sessionId: tab.sessionId, action: "click"))
    let sent = pressSent.result == 0 && releaseSent.result == 0
    return jsonEncode(
      MouseActionResult(
        ok: sent, frame: runtime.currentFrame,
        activeTabId: tab.id, activeSessionId: tab.sessionId,
        mouseTracking: true, sent: sent
      ))
  }

  /// On the remote (labpty/laband) tier `sendMouseCapturingBytes` only encodes —
  /// the bytes must reach the daemon PTY via the terminal client, mirroring
  /// `DebugInputActions.typeText`. No-op in-process (no client; the encode path
  /// already wrote locally) and when there is nothing to deliver.
  private func forwardEncodedInputToDaemon(_ bytes: [UInt8], tab: Tab, session: Session) {
    guard !bytes.isEmpty, let client = runtime.terminalSessionClient else { return }
    do {
      try runtime.ensureTerminalClientSessionUnlocked(for: tab)
      try client.writeInput(
        sessionId: runtime.terminalClientRemoteSessionId(for: session.id),
        bytes: bytes)
    } catch {
      runtime.appendError(
        kind: "terminalClient.writeInput.failed",
        message: String(describing: error),
        sessionId: session.id,
        tabId: tab.id)
    }
  }

  private func setClickSelection(
    terminalPoint: (x: Float, y: Float),
    frameBefore: Int,
    tab: Tab,
    session: Session
  ) -> DebugResponse {
    let termX = Int(terminalPoint.x)
    let termY = Int(terminalPoint.y)
    let clickedRow = max(0, runtime.windowHeight - termY - 1) / max(runtime.cellHeight, 1)
    let clickedCol = max(0, termX) / max(runtime.cellWidth, 1)
    let coordinate = TerminalCellCoordinate(row: clickedRow, col: clickedCol)
    let selection = TerminalSelection(sessionId: session.id, anchor: coordinate, focus: coordinate)
    runtime.selectionBySession[session.id] = selection
    runtime.appendInputEnvelope(
      InputEventEnvelope(
        inputId: UUID().uuidString,
        source: "debug",
        kind: "selection",
        route: "selection",
        frameBefore: frameBefore,
        tabId: tab.id,
        sessionId: session.id,
        command: "click",
        anchorRow: coordinate.row,
        anchorCol: coordinate.col,
        focusRow: coordinate.row,
        focusCol: coordinate.col
      ))
    runtime.renderFrameUnlocked()
    runtime.appendEvent(
      EventEntry(kind: "selection.set", sessionId: tab.sessionId, action: "click")
    )
    return jsonEncode(
      MouseActionResult(
        ok: true, frame: runtime.currentFrame,
        activeTabId: tab.id, activeSessionId: tab.sessionId,
        mouseTracking: false, sent: false
      ))
  }
}
