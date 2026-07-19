import Foundation

extension HeadlessDebugRuntime {
  public func applyAction(_ data: Data) -> DebugResponse {
    withRuntimeLock {
      guard let action = try? JSONDecoder().decode(DebugAction.self, from: data) else {
        appendError(kind: "action.invalid", message: "invalid action request")
        return jsonError("invalid action request")
      }
      return applyActionUnlocked(action, scopedSessionID: nil)
    }
  }

  func applyAction(_ data: Data, scopedSessionID: String?) -> DebugResponse {
    withRuntimeLock {
      guard let action = try? JSONDecoder().decode(DebugAction.self, from: data) else {
        appendError(kind: "action.invalid", message: "invalid action request")
        return jsonError("invalid action request")
      }
      return applyActionUnlocked(action, scopedSessionID: scopedSessionID)
    }
  }

  func applyActionUnlocked(_ action: DebugAction, scopedSessionID: String?) -> DebugResponse {
    switch action {
    case .newTab:
      return DebugTabActions(runtime: self).newTab()
    case .closeTab(let request):
      return DebugTabActions(runtime: self).closeTab(request)
    case .selectTab(let request):
      return DebugTabActions(runtime: self).selectTab(request)
    case .setTabTitle(let request):
      return DebugTabActions(runtime: self).setTabTitle(request)
    case .freezeTabTitle(let request):
      return DebugTabActions(runtime: self).freezeTabTitle(request)
    case .clearTabTitle(let request):
      return DebugTabActions(runtime: self).clearTabTitle(request)
    case .setTabMetadata(let request):
      return DebugTabActions(runtime: self).setTabMetadata(request)
    case .moveTab(let request):
      return DebugTabActions(runtime: self).moveTab(request)
    case .resizeWindow(let request):
      return DebugWindowActions(runtime: self).resizeWindow(request)
    case .setFontSize(let request):
      return DebugWindowActions(runtime: self).setFontSize(request)
    case .setRenderer(let request):
      return DebugWindowActions(runtime: self).setRenderer(request)
    case .advanceFrames(let request):
      return DebugWindowActions(runtime: self).advanceFrames(request)
    case .advanceTime(let request):
      return DebugWindowActions(runtime: self).advanceTime(request)
    case .setGlyphEffectsEnabled(let request):
      return DebugWindowActions(runtime: self).setGlyphEffectsEnabled(request)
    case .setVectorSubpixelLayout(let request):
      return DebugWindowActions(runtime: self).setVectorSubpixelLayout(request)
    case .windowFocus(let request):
      return DebugWindowActions(runtime: self).windowFocus(request)
    case .setBackgroundTransparency(let request):
      return setBackgroundTransparencyUnlocked(request)
    case .resetTransparencyDiagnostics:
      return resetTransparencyDiagnosticsUnlocked()
    case .setReduceTransparencyOverride(let request):
      return setReduceTransparencyOverrideUnlocked(request)
    case .setNativeFullScreen:
      return unsupportedAction("setNativeFullScreen")
    case .setBackgroundSource(let request):
      return setBackgroundSourceUnlocked(request)
    case .setBackgroundImageScaling(let request):
      return setBackgroundImageScalingUnlocked(request)
    case .importBackgroundImage(let request):
      return importBackgroundImageUnlocked(request)
    case .removeBackgroundImage:
      return removeBackgroundImageUnlocked()
    case .typeText(let request):
      return DebugInputActions(runtime: self).typeText(request)
    case .feedOutput(let request):
      return DebugInputActions(runtime: self).feedOutput(request)
    case .key(let request):
      return DebugInputActions(runtime: self).key(request)
    case .setClipboardText(let request):
      return DebugClipboardActions(runtime: self).setClipboardText(request)
    case .copy(let request):
      return DebugClipboardActions(runtime: self).copy(request)
    case .paste:
      return DebugClipboardActions(runtime: self).paste()
    case .dropFiles(let request):
      return DebugDropActions(runtime: self).dropFiles(request)
    case .setSelection(let request):
      return DebugSelectionActions(runtime: self).setSelection(request)
    case .setPreedit(let request):
      return DebugPreeditActions(runtime: self).setPreedit(request)
    case .findStart(let request):
      return DebugFindActions(runtime: self).start(request)
    case .findStep(let request):
      return DebugFindActions(runtime: self).step(request)
    case .findStop(let request):
      return DebugFindActions(runtime: self).stop(request)
    case .scrollViewport(let request):
      return DebugViewportActions(runtime: self).scrollViewport(request)
    case .propose(let request):
      return DebugCommandProposalActions(runtime: self).propose(
        request, scopedSessionID: scopedSessionID)
    case .proposalList:
      return DebugCommandProposalActions(runtime: self).list(scopedSessionID: scopedSessionID)
    case .proposalGet(let request):
      return DebugCommandProposalActions(runtime: self).get(
        request, scopedSessionID: scopedSessionID)
    case .proposalCancel(let request):
      return DebugCommandProposalActions(runtime: self).cancel(
        request, scopedSessionID: scopedSessionID)
    case .mouseWheel(let request):
      return DebugMouseActions(runtime: self).mouseWheel(request)
    case .mouseDrag(let request):
      return DebugMouseActions(runtime: self).drag(request)
    case .click(let request):
      return DebugMouseActions(runtime: self).click(request)
    case .unsupported(let actionName):
      return unsupportedAction(actionName)
    }
  }

  func unsupportedAction(_ actionName: String) -> DebugResponse {
    appendEvent(EventEntry(kind: "action.unsupported", action: actionName))
    appendError(
      kind: "action.unsupported",
      message: "debug action \(actionName) is not implemented yet"
    )
    let active = model.activeTab
    return jsonEncode(
      ActionResult(
        ok: false, frame: currentFrame,
        activeTabId: active?.id, activeSessionId: active?.sessionId,
        error: "debug action \(actionName) is not implemented yet"
      ))
  }

  func actionResult(ok: Bool) -> DebugResponse {
    let active = model.activeTab
    return jsonEncode(
      ActionResult(
        ok: ok,
        frame: currentFrame,
        activeTabId: active?.id,
        activeSessionId: active?.sessionId,
        error: nil
      ))
  }
}
