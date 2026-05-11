import CoreGraphics
import Foundation
import LabanCore
import LabanRenderer
import LabanTerminalCore

extension HeadlessDebugRuntime {
  func applyActionUnlocked(_ req: ActionRequest) -> DebugResponse {
    switch req.action {

    case "newTab":
      do { try model.createTab() } catch {
        return jsonError("createTab failed: \(error)")
      }
      renderFrameUnlocked()
      appendEvent(EventEntry(kind: "tab.created", tabId: model.activeTab?.id))
      return actionResult(ok: true)

    case "closeTab":
      guard let tabId = req.tabId else { return jsonError("closeTab requires tabId") }
      do { try model.closeTab(tabId) } catch {
        return jsonError("closeTab failed: \(error)")
      }
      renderFrameUnlocked()
      appendEvent(EventEntry(kind: "tab.closed", tabId: tabId))
      return actionResult(ok: true)

    case "selectTab":
      guard let tabId = req.tabId else { return jsonError("selectTab requires tabId") }
      model.selectTab(tabId)
      renderFrameUnlocked()
      appendEvent(EventEntry(kind: "tab.selected", tabId: tabId))
      return actionResult(ok: true)

    case "setTabTitle":
      let targetTabId = req.tabId ?? model.activeTab?.id
      guard let tabId = targetTabId else { return jsonError("setTabTitle requires an active tab") }
      guard let title = req.title ?? req.text else {
        return jsonError("setTabTitle requires title")
      }
      do { try model.renameTab(tabId, title: title) } catch {
        return jsonError("setTabTitle failed: \(error)")
      }
      renderFrameUnlocked()
      appendEvent(EventEntry(kind: "tab.title.set", tabId: tabId, text: title))
      return actionResult(ok: true)

    case "freezeTabTitle":
      let targetTabId = req.tabId ?? model.activeTab?.id
      guard let tabId = targetTabId else {
        return jsonError("freezeTabTitle requires an active tab")
      }
      do { try model.freezeTitle(forTab: tabId, frozen: req.frozen ?? true) } catch {
        return jsonError("freezeTabTitle failed: \(error)")
      }
      renderFrameUnlocked()
      appendEvent(EventEntry(kind: "tab.title.frozen", tabId: tabId))
      return actionResult(ok: true)

    case "clearTabTitle":
      let targetTabId = req.tabId ?? model.activeTab?.id
      guard let tabId = targetTabId else {
        return jsonError("clearTabTitle requires an active tab")
      }
      do { try model.clearUserTitle(forTab: tabId) } catch {
        return jsonError("clearTabTitle failed: \(error)")
      }
      renderFrameUnlocked()
      appendEvent(EventEntry(kind: "tab.title.cleared", tabId: tabId))
      return actionResult(ok: true)

    case "setTabMetadata":
      let targetTabId = req.tabId ?? model.activeTab?.id
      guard let tabId = targetTabId else {
        return jsonError("setTabMetadata requires an active tab")
      }
      let workspace =
        req.cwd != nil || req.repoName != nil || req.repoRoot != nil || req.worktreeName != nil
          || req.branch != nil || req.isDirty != nil
        ? TabWorkspaceMetadata(
          cwd: req.cwd,
          repoName: req.repoName,
          repoRoot: req.repoRoot,
          worktreeName: req.worktreeName,
          branch: req.branch,
          isDirty: req.isDirty ?? false
        )
        : nil
      let process =
        req.foregroundProcess != nil || req.foregroundCommand != nil || req.pid != nil
        ? TabProcessMetadata(
          foregroundProcess: req.foregroundProcess,
          foregroundCommand: req.foregroundCommand,
          pid: req.pid
        )
        : nil
      let agent =
        req.agentName != nil || req.sessionName != nil || req.agentSessionId != nil
          || req.taskLabel != nil || req.model != nil || req.contextPercent != nil
          || req.awaitingInput != nil
        ? TabAgentMetadata(
          agentName: req.agentName,
          sessionName: req.sessionName,
          sessionId: req.agentSessionId,
          taskLabel: req.taskLabel,
          model: req.model,
          contextPercent: req.contextPercent,
          awaitingInput: req.awaitingInput ?? false
        )
        : nil
      let activityState = req.activityState.flatMap(TabActivityState.init(rawValue:))
      do {
        try model.updateTitleMetadata(
          forTab: tabId,
          workspace: workspace,
          process: process,
          agent: agent,
          activityState: activityState,
          unseenOutput: req.unseenOutput,
          exitStatus: req.exitStatus
        )
      } catch {
        return jsonError("setTabMetadata failed: \(error)")
      }
      renderFrameUnlocked()
      appendEvent(EventEntry(kind: "tab.metadata.set", tabId: tabId))
      return actionResult(ok: true)

    case "resizeWindow":
      guard let w = req.width, let h = req.height else {
        return jsonError("resizeWindow requires width and height")
      }
      windowWidth = max(w, sidebarWidth + 1)
      windowHeight = max(h, 1)
      surface = BitmapSurface(width: windowWidth, height: windowHeight)
      renderer = SoftwareRenderer(surface: surface, fontAtlas: fontAtlas)
      model.resize(
        viewportWidth: windowWidth - sidebarWidth,
        viewportHeight: windowHeight,
        cellWidth: cellWidth, cellHeight: cellHeight
      )
      renderFrameUnlocked()
      appendEvent(EventEntry(kind: "window.resized", width: windowWidth, height: windowHeight))
      return actionResult(ok: true)

    case "typeText":
      guard let text = req.text else { return jsonError("typeText requires text") }
      let frameBefore = currentFrame
      let activeTab = model.activeTab
      let bytes = Array(text.utf8)
      if let tab = model.activeTab, let session = model.session(forTab: tab.id) {
        session.write(bytes)
        model.noteOutput(forTab: tab.id)
        appendTerminalLog(sessionId: session.id, direction: "input", bytes: bytes)
      }
      renderFrameUnlocked()
      appendInputEnvelope(
        InputEventEnvelope(
          inputId: UUID().uuidString,
          source: "debug",
          kind: "text",
          route: "terminal",
          frameBefore: frameBefore,
          tabId: activeTab?.id,
          sessionId: activeTab?.sessionId,
          text: text,
          encodedHex: bytes.map { String(format: "%02x", $0) }.joined(),
          encodedLength: bytes.count
        ))
      appendEvent(EventEntry(kind: "input.typed", text: text))
      return actionResult(ok: true)

    case "feedOutput":
      guard let text = req.text else { return jsonError("feedOutput requires text") }
      if let tab = model.activeTab, let session = model.session(forTab: tab.id) {
        let bytes = Array(text.utf8)
        session.feedOutput(bytes)
        model.noteOutput(forTab: tab.id)
        appendTerminalLog(sessionId: session.id, direction: "output", bytes: bytes)
      }
      renderFrameUnlocked()
      appendEvent(EventEntry(kind: "output.fed", text: text))
      return actionResult(ok: true)

    case "advanceFrames":
      let count = max(req.count ?? 1, 1)
      for _ in 0..<count {
        renderFrameUnlocked()
      }
      return actionResult(ok: true)

    case "setClipboardText":
      guard let text = req.text else { return jsonError("setClipboardText requires text") }
      debugClipboard = text
      appendEvent(EventEntry(kind: "clipboard.set", text: text))
      return actionResult(ok: true)

    case "setSelection":
      let frameBefore = currentFrame
      guard let anchorReq = req.anchor, let focusReq = req.focus else {
        return jsonError("setSelection requires anchor and focus")
      }
      let targetTab =
        req.sessionId.flatMap { sid in model.tabs.first(where: { $0.sessionId == sid }) }
        ?? model.activeTab
      guard let tab = targetTab, let session = model.session(forTab: tab.id) else {
        return jsonError("no session for setSelection")
      }
      let sel = TerminalSelection(
        sessionId: session.id,
        anchor: TerminalCellCoordinate(row: anchorReq.row, col: anchorReq.col),
        focus: TerminalCellCoordinate(row: focusReq.row, col: focusReq.col)
      )
      selectionBySession[session.id] = sel
      appendInputEnvelope(
        InputEventEnvelope(
          inputId: UUID().uuidString,
          source: "debug",
          kind: "selection",
          route: "selection",
          frameBefore: frameBefore,
          tabId: tab.id,
          sessionId: session.id,
          command: "setSelection",
          anchorRow: anchorReq.row,
          anchorCol: anchorReq.col,
          focusRow: focusReq.row,
          focusCol: focusReq.col
        ))
      renderFrameUnlocked()
      appendEvent(EventEntry(kind: "selection.set", sessionId: tab.sessionId))
      return actionResult(ok: true)

    case "copy":
      let frameBefore = currentFrame
      let targetTab =
        req.sessionId.flatMap { sid in model.tabs.first(where: { $0.sessionId == sid }) }
        ?? model.activeTab
      guard let tab = targetTab, let session = model.session(forTab: tab.id) else {
        return jsonError("no session for copy")
      }
      guard let sel = selectionBySession[session.id] else {
        lastCopyText = ""
        appendEvent(EventEntry(kind: "clipboard.copied", text: ""))
        return actionResult(ok: true)
      }
      let text: String
      if let snap = session.snapshot() {
        defer { laban_snapshot_destroy(snap) }
        text = sel.selectedText(from: snap.pointee)
      } else {
        text = ""
      }
      lastCopyText = text
      debugClipboard = text
      appendInputEnvelope(
        InputEventEnvelope(
          inputId: UUID().uuidString,
          source: "debug",
          kind: "copy",
          route: "appCommand",
          frameBefore: frameBefore,
          tabId: tab.id,
          sessionId: session.id,
          command: "copy"
        ))
      appendEvent(EventEntry(kind: "clipboard.copied", text: text))
      return actionResult(ok: true)

    case "paste":
      let frameBefore = currentFrame
      let activeTab = model.activeTab
      // Apply the same hard-size cap that the AppKit paste path uses.
      // Without this a malicious automation client could feed an
      // arbitrarily large clipboard via setClipboardText then trigger
      // paste, freezing the debug-runtime thread and bloating memory.
      let pasteHardLimit = TerminalPaste.hardLimitBytes
      if debugClipboard.utf8.count > pasteHardLimit {
        return jsonError("clipboard exceeds paste limit (\(pasteHardLimit) bytes)")
      }
      let sanitized = TerminalPaste.sanitize(debugClipboard)
      var encodedBytes: [UInt8] = []
      if let tab = model.activeTab, let session = model.session(forTab: tab.id) {
        let result: Session.PasteWriteResult?
        if sanitized.isEmpty {
          result = nil
        } else {
          let sent = session.writePasteCapturingBytes(sanitized)
          result = sent.result
          encodedBytes = sent.bytes
        }
        lastPasteText = sanitized
        lastPasteUsedBracketedPaste = result?.bracketed
        lastPasteIgnoredNonText = sanitized != debugClipboard
        if !encodedBytes.isEmpty {
          appendTerminalLog(
            sessionId: session.id,
            direction: "input",
            bytes: encodedBytes
          )
        }
      }
      renderFrameUnlocked()
      appendInputEnvelope(
        InputEventEnvelope(
          inputId: UUID().uuidString,
          source: "debug",
          kind: "paste",
          route: "terminal",
          frameBefore: frameBefore,
          tabId: activeTab?.id,
          sessionId: activeTab?.sessionId,
          text: sanitized,
          command: "paste",
          encodedHex: encodedBytes.isEmpty
            ? nil
            : encodedBytes.map { String(format: "%02x", $0) }.joined(),
          encodedLength: encodedBytes.isEmpty ? nil : encodedBytes.count
        ))
      appendEvent(EventEntry(kind: "clipboard.pasted", text: sanitized))
      return actionResult(ok: true)

    case "scrollViewport":
      let frameBefore = currentFrame
      let targetTab =
        req.sessionId.flatMap { sid in
          model.tabs.first(where: { $0.sessionId == sid })
        } ?? model.activeTab
      guard let t = targetTab, let session = model.session(forTab: t.id) else {
        return jsonError("no session for scrollViewport")
      }
      session.scrollViewport(deltaRows: req.deltaRows ?? 0)
      appendInputEnvelope(
        InputEventEnvelope(
          inputId: UUID().uuidString,
          source: "debug",
          kind: "scroll",
          route: "terminal",
          frameBefore: frameBefore,
          tabId: t.id,
          sessionId: session.id,
          command: "scrollViewport",
          deltaRows: req.deltaRows ?? 0
        ))
      renderFrameUnlocked()
      appendEvent(
        EventEntry(kind: "viewport.scrolled", sessionId: t.sessionId, deltaRows: req.deltaRows))
      return actionResult(ok: true)

    case "mouseWheel":
      let frameBefore = currentFrame
      guard let x = req.x, let y = req.y, let deltaY = req.deltaY else {
        return jsonError("mouseWheel requires x, y, and deltaY")
      }
      // Sidebar hit test.
      if x < sidebarWidth {
        // Sidebar hits are consumed locally.
        appendEvent(EventEntry(kind: "mouse.sidebar", action: "mouseWheel"))
        return actionResult(ok: true)
      }
      guard let tab = model.activeTab, let session = model.session(forTab: tab.id) else {
        return jsonError("no active session for mouseWheel")
      }
      let terminalPoint = terminalMousePosition(x: x, y: y)
      // Determine wheel direction: deltaY > 0 means scroll up (older history).
      let isUp = deltaY > 0

      if let vs = session.viewportState(), vs.mouseTracking {
        // Mouse tracking active: encode and send wheel event.
        let button: MouseButton = isUp ? .wheelUp : .wheelDown
        let me = MouseEvent(
          action: .press,
          button: button,
          x: terminalPoint.x,
          y: terminalPoint.y,
          screenWidth: terminalSurfaceWidth,
          screenHeight: windowHeight,
          cellWidth: cellWidth,
          cellHeight: cellHeight
        )
        let sent = session.sendMouseCapturingBytes(me)
        let encoded = sent.bytes
        if !encoded.isEmpty {
          appendTerminalLog(sessionId: session.id, direction: "input", bytes: encoded)
        }
        appendInputEnvelope(
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
        appendEvent(EventEntry(kind: "mouse.sent", sessionId: tab.sessionId, action: "mouseWheel"))
        renderFrameUnlocked()
        return jsonEncode(
          MouseActionResult(
            ok: sent.result == 0, frame: currentFrame,
            activeTabId: tab.id, activeSessionId: tab.sessionId,
            mouseTracking: true, sent: sent.result == 0
          ))
      } else {
        // Normal mode: scroll viewport.
        let rows = isUp ? -1 : 1
        session.scrollViewport(deltaRows: rows)
        appendInputEnvelope(
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
        renderFrameUnlocked()
        appendEvent(
          EventEntry(
            kind: "viewport.scrolled", sessionId: tab.sessionId, action: "mouseWheel",
            deltaRows: rows))
        return actionResult(ok: true)
      }

    case "click":
      let frameBefore = currentFrame
      guard let x = req.x, let y = req.y, let button = req.button else {
        return jsonError("click requires x, y, and button")
      }
      // Sidebar hit test.
      if x < sidebarWidth {
        let sp = SidebarProducer(
          sidebarWidth: CGFloat(sidebarWidth),
          cellWidth: CGFloat(cellWidth),
          cellHeight: CGFloat(cellHeight)
        )
        let pt = CGPoint(x: CGFloat(x), y: CGFloat(y))
        switch sp.hitTest(at: pt, tabs: model.tabs, height: CGFloat(windowHeight)) {
        case .newTab:
          do { try model.createTab() } catch {
            return jsonError("createTab failed: \(error)")
          }
          renderFrameUnlocked()
          appendEvent(EventEntry(kind: "tab.created", tabId: model.activeTab?.id))
        case .selectTab(let id):
          model.selectTab(id)
          renderFrameUnlocked()
          appendEvent(EventEntry(kind: "tab.selected", tabId: id))
        case .closeTab(let id):
          do { try model.closeTab(id) } catch {
            return jsonError("closeTab failed: \(error)")
          }
          renderFrameUnlocked()
          appendEvent(EventEntry(kind: "tab.closed", tabId: id))
        case .none:
          break
        }
        appendEvent(EventEntry(kind: "mouse.sidebar", action: "click"))
        return actionResult(ok: true)
      }
      guard let tab = model.activeTab, let session = model.session(forTab: tab.id) else {
        return jsonError("no active session for click")
      }
      let terminalPoint = terminalMousePosition(x: x, y: y)

      if let vs = session.viewportState(), vs.mouseTracking {
        // Mouse tracking active: send press/release events.
        let btn: MouseButton
        switch button {
        case "middle": btn = .middle
        case "right": btn = .right
        default: btn = .left
        }
        let pressEvent = MouseEvent(
          action: .press, button: btn,
          x: terminalPoint.x, y: terminalPoint.y,
          screenWidth: terminalSurfaceWidth, screenHeight: windowHeight,
          cellWidth: cellWidth, cellHeight: cellHeight
        )
        let releaseEvent = MouseEvent(
          action: .release, button: btn,
          x: terminalPoint.x, y: terminalPoint.y,
          screenWidth: terminalSurfaceWidth, screenHeight: windowHeight,
          cellWidth: cellWidth, cellHeight: cellHeight
        )
        let pressSent = session.sendMouseCapturingBytes(pressEvent)
        let releaseSent =
          pressSent.result == 0
          ? session.sendMouseCapturingBytes(releaseEvent)
          : Session.CapturedMouseWrite(result: -1, bytes: [])
        let pressBytes = pressSent.bytes
        let releaseBytes = releaseSent.bytes
        let encoded = pressBytes + releaseBytes
        if !encoded.isEmpty {
          appendTerminalLog(sessionId: session.id, direction: "input", bytes: encoded)
        }
        appendInputEnvelope(
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
        renderFrameUnlocked()
        appendEvent(EventEntry(kind: "mouse.sent", sessionId: tab.sessionId, action: "click"))
        let sent = pressSent.result == 0 && releaseSent.result == 0
        return jsonEncode(
          MouseActionResult(
            ok: sent, frame: currentFrame,
            activeTabId: tab.id, activeSessionId: tab.sessionId,
            mouseTracking: true, sent: sent
          ))
      } else {
        // No mouse tracking: set a one-cell local selection at the clicked cell.
        let termX = Int(terminalPoint.x)
        let termY = Int(terminalPoint.y)
        let clickedRow = max(0, windowHeight - termY - 1) / max(cellHeight, 1)
        let clickedCol = max(0, termX) / max(cellWidth, 1)
        let coord = TerminalCellCoordinate(row: clickedRow, col: clickedCol)
        let sel = TerminalSelection(sessionId: session.id, anchor: coord, focus: coord)
        selectionBySession[session.id] = sel
        appendInputEnvelope(
          InputEventEnvelope(
            inputId: UUID().uuidString,
            source: "debug",
            kind: "selection",
            route: "selection",
            frameBefore: frameBefore,
            tabId: tab.id,
            sessionId: session.id,
            command: "click",
            anchorRow: coord.row,
            anchorCol: coord.col,
            focusRow: coord.row,
            focusCol: coord.col
          ))
        renderFrameUnlocked()
        appendEvent(EventEntry(kind: "selection.set", sessionId: tab.sessionId, action: "click"))
        return jsonEncode(
          MouseActionResult(
            ok: true, frame: currentFrame,
            activeTabId: tab.id, activeSessionId: tab.sessionId,
            mouseTracking: false, sent: false
          ))
      }

    case "key":
      guard let keyName = req.key,
        let key = DebugRuntimeKeyInput.key(fromName: keyName)
      else {
        return jsonError("key action requires a valid key name")
      }
      let action = DebugRuntimeKeyInput.action(from: req.type)
      let mods = DebugRuntimeKeyInput.modifiers(from: req.modifiers)
      let consumed = DebugRuntimeKeyInput.modifiers(from: req.consumedModifiers)
      let frameBefore = currentFrame
      let activeTab = model.activeTab
      let inputId = UUID().uuidString

      if mods.contains(.command) {
        let (route, commandStr) = commandRouteForKey(key)
        appendInputEnvelope(
          InputEventEnvelope(
            inputId: inputId, seq: 0,
            source: "debug", kind: "key", route: route,
            frameBefore: frameBefore,
            tabId: activeTab?.id, sessionId: activeTab?.sessionId,
            key: keyName, modifiers: req.modifiers, command: commandStr
          ))
        appendEvent(EventEntry(kind: "input.key", text: keyName, action: req.action))
        if route == "appCommand" {
          executeCommandKey(key)
        }
        return actionResult(ok: true)
      }

      var unshiftedCodepoint: UInt32 = 0
      if let u = req.unshifted, let scalar = u.unicodeScalars.first {
        unshiftedCodepoint = scalar.value
      }
      let keyEvent = KeyEvent(
        action: action,
        key: key,
        modifiers: mods,
        consumedModifiers: consumed,
        unshiftedCodepoint: unshiftedCodepoint,
        text: req.text
      )
      var encodedHex: String? = nil
      var encodedLength: Int? = nil
      if let tab = activeTab, let session = model.session(forTab: tab.id) {
        let sent = session.sendKeyCapturingBytes(keyEvent)
        if sent.result == 0, !sent.bytes.isEmpty {
          encodedHex = sent.bytes.map { String(format: "%02x", $0) }.joined()
          encodedLength = sent.bytes.count
          appendTerminalLog(sessionId: session.id, direction: "input", bytes: sent.bytes)
        }
      }
      renderFrameUnlocked()
      appendInputEnvelope(
        InputEventEnvelope(
          inputId: inputId, seq: 0,
          source: "debug", kind: "key", route: "terminal",
          frameBefore: frameBefore,
          tabId: activeTab?.id, sessionId: activeTab?.sessionId,
          key: keyName, text: req.text,
          modifiers: req.modifiers, consumedModifiers: req.consumedModifiers,
          encodedHex: encodedHex, encodedLength: encodedLength
        ))
      appendEvent(EventEntry(kind: "input.key", text: keyName, action: req.action))
      return actionResult(ok: true)

    default:
      appendEvent(EventEntry(kind: "action.unsupported", action: req.action))
      appendError(
        kind: "action.unsupported",
        message: "debug action \(req.action) is not implemented yet"
      )
      let active = model.activeTab
      return jsonEncode(
        ActionResult(
          ok: false, frame: currentFrame,
          activeTabId: active?.id, activeSessionId: active?.sessionId,
          error: "debug action \(req.action) is not implemented yet"
        ))
    }
  }

  private func commandRouteForKey(_ key: Key) -> (route: String, command: String?) {
    DebugRuntimeKeyInput.commandRoute(for: key)
  }

  private func executeCommandKey(_ key: Key) {
    switch key {
    case .t:
      _ = try? model.createTab()
      renderFrameUnlocked()
    case .w:
      if let tabId = model.activeTab?.id {
        try? model.closeTab(tabId)
        renderFrameUnlocked()
      }
    default:
      guard let idx = DebugRuntimeKeyInput.tabIndex(for: key), idx < model.tabs.count else {
        return
      }
      model.selectTab(model.tabs[idx].id)
      renderFrameUnlocked()
    }
  }
}
