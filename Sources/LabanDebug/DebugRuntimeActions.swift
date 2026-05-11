import Foundation

extension HeadlessDebugRuntime {
  func applyActionUnlocked(_ action: DebugAction) -> DebugResponse {
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
    case .resizeWindow(let request):
      return DebugWindowActions(runtime: self).resizeWindow(request)
    case .advanceFrames(let request):
      return DebugWindowActions(runtime: self).advanceFrames(request)
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
    case .setSelection(let request):
      return DebugSelectionActions(runtime: self).setSelection(request)
    case .scrollViewport(let request):
      return DebugViewportActions(runtime: self).scrollViewport(request)
    case .mouseWheel(let request):
      return DebugMouseActions(runtime: self).mouseWheel(request)
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
}
