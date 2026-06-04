import CoreGraphics
import Foundation
import LabanCore
import LabanRenderer
import LabanTerminalCore

struct DebugMouseActions {
  private unowned let runtime: HeadlessDebugRuntime

  private struct MouseEncodingOptions {
    var trackingMode: Int
    var format: Int
  }

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
    let encodingOptions = mouseEncodingOptions(session: session)
    if encodingOptions != nil || viewportState?.mouseTracking == true {
      return sendTrackedWheel(
        isUp: isUp,
        terminalPoint: terminalPoint,
        frameBefore: frameBefore,
        tab: tab,
        session: session,
        encodingOptions: encodingOptions
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

    let encodingOptions = mouseEncodingOptions(session: session)
    if encodingOptions != nil || session.viewportState()?.mouseTracking == true {
      return sendMouseClick(
        button: button,
        terminalPoint: terminalPoint,
        frameBefore: frameBefore,
        tab: tab,
        session: session,
        encodingOptions: encodingOptions
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

  func drag(_ request: MouseDragActionRequest) -> DebugResponse {
    let frameBefore = runtime.currentFrame
    guard
      let startX = request.startX,
      let startY = request.startY,
      let endX = request.endX,
      let endY = request.endY
    else {
      return jsonError("mouseDrag requires startX, startY, endX, and endY")
    }
    if startX < runtime.sidebarWidth {
      runtime.appendEvent(EventEntry(kind: "mouse.sidebar", action: "mouseDrag"))
      return runtime.actionResult(ok: true)
    }
    guard let tab = runtime.model.activeTab,
      let session = runtime.model.session(forTab: tab.id)
    else {
      return jsonError("no active session for mouseDrag")
    }
    let encodingOptions = mouseEncodingOptions(session: session)
    guard encodingOptions != nil || session.viewportState()?.mouseTracking == true else {
      return jsonError("mouseDrag requires mouse tracking")
    }

    let mouseButton = Self.mouseButton(named: request.button)
    let startPoint = runtime.terminalMousePosition(x: startX, y: startY)
    let endPoint = runtime.terminalMousePosition(x: endX, y: endY)
    let pressEvent = mouseEvent(
      action: .press, button: mouseButton, at: startPoint, encodingOptions: encodingOptions)
    let motionEvent = mouseEvent(
      action: .motion, button: mouseButton, at: endPoint, encodingOptions: encodingOptions)
    let releaseEvent = mouseEvent(
      action: .release, button: mouseButton, at: endPoint, encodingOptions: encodingOptions)

    let pressSent = sendMouseEvent(pressEvent, tab: tab, session: session)
    let motionSent =
      pressSent.result == 0
      ? sendMouseEvent(motionEvent, tab: tab, session: session)
      : Session.CapturedMouseWrite(result: -1, bytes: [])

    if let holdMs = request.holdMs, holdMs > 0 {
      Thread.sleep(forTimeInterval: Double(min(holdMs, 5_000)) / 1_000.0)
    }

    let releaseSent =
      pressSent.result == 0
      ? sendMouseEvent(releaseEvent, tab: tab, session: session)
      : Session.CapturedMouseWrite(result: -1, bytes: [])
    let encoded = pressSent.bytes + motionSent.bytes + releaseSent.bytes
    runtime.appendInputEnvelope(
      InputEventEnvelope(
        inputId: UUID().uuidString,
        source: "debug",
        kind: "mouse",
        route: "terminal",
        frameBefore: frameBefore,
        tabId: tab.id,
        sessionId: session.id,
        command: "mouseDrag",
        encodedHex: encoded.isEmpty
          ? nil
          : encoded.map { String(format: "%02x", $0) }
            .joined(),
        encodedLength: encoded.isEmpty ? nil : encoded.count
      ))
    runtime.renderFrameUnlocked()
    runtime.appendEvent(EventEntry(kind: "mouse.sent", sessionId: tab.sessionId, action: "mouseDrag"))
    let sent = pressSent.result == 0 && motionSent.result == 0 && releaseSent.result == 0
    return jsonEncode(
      MouseActionResult(
        ok: sent, frame: runtime.currentFrame,
        activeTabId: tab.id, activeSessionId: tab.sessionId,
        mouseTracking: true, sent: sent
      ))
  }

  private func sendTrackedWheel(
    isUp: Bool,
    terminalPoint: (x: Float, y: Float),
    frameBefore: Int,
    tab: Tab,
    session: Session,
    encodingOptions: MouseEncodingOptions?
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
      cellHeight: runtime.cellHeight,
      trackingMode: encodingOptions?.trackingMode ?? 0,
      format: encodingOptions?.format ?? 0
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

  private func mouseEncodingOptions(session: Session) -> MouseEncodingOptions? {
    if runtime.terminalSessionClient != nil,
      let snapshot = runtime.terminalClientSnapshotUnlocked(sessionId: session.id)
    {
      guard snapshot.mouseTracking == true, let trackingMode = snapshot.mouseTrackingMode,
        trackingMode > 0
      else {
        return nil
      }
      return MouseEncodingOptions(
        trackingMode: trackingMode,
        format: snapshot.mouseFormat ?? 0)
    }
    return nil
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
    session: Session,
    encodingOptions: MouseEncodingOptions?
  ) -> DebugResponse {
    let mouseButton = Self.mouseButton(named: button)
    let pressEvent = MouseEvent(
      action: .press,
      button: mouseButton,
      x: terminalPoint.x,
      y: terminalPoint.y,
      screenWidth: runtime.terminalSurfaceWidth,
      screenHeight: runtime.windowHeight,
      cellWidth: runtime.cellWidth,
      cellHeight: runtime.cellHeight,
      trackingMode: encodingOptions?.trackingMode ?? 0,
      format: encodingOptions?.format ?? 0
    )
    let releaseEvent = MouseEvent(
      action: .release,
      button: mouseButton,
      x: terminalPoint.x,
      y: terminalPoint.y,
      screenWidth: runtime.terminalSurfaceWidth,
      screenHeight: runtime.windowHeight,
      cellWidth: runtime.cellWidth,
      cellHeight: runtime.cellHeight,
      trackingMode: encodingOptions?.trackingMode ?? 0,
      format: encodingOptions?.format ?? 0
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

  private static func mouseButton(named name: String?) -> MouseButton {
    switch name {
    case "middle": return .middle
    case "right": return .right
    default: return .left
    }
  }

  private func mouseEvent(
    action: MouseAction,
    button: MouseButton,
    at terminalPoint: (x: Float, y: Float),
    encodingOptions: MouseEncodingOptions?
  ) -> MouseEvent {
    MouseEvent(
      action: action,
      button: button,
      x: terminalPoint.x,
      y: terminalPoint.y,
      screenWidth: runtime.terminalSurfaceWidth,
      screenHeight: runtime.windowHeight,
      cellWidth: runtime.cellWidth,
      cellHeight: runtime.cellHeight,
      trackingMode: encodingOptions?.trackingMode ?? 0,
      format: encodingOptions?.format ?? 0
    )
  }

  private func sendMouseEvent(
    _ event: MouseEvent,
    tab: Tab,
    session: Session
  ) -> Session.CapturedMouseWrite {
    let sent = session.sendMouseCapturingBytes(event)
    let encoded = sent.result == 0 ? sent.bytes : []
    if !encoded.isEmpty {
      forwardEncodedInputToDaemon(encoded, tab: tab, session: session)
      runtime.appendTerminalLog(sessionId: session.id, direction: "input", bytes: encoded)
    }
    return sent
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
