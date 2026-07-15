import Foundation
import LabanCore

typealias CellCoordinateReq = LabanCore.CellCoordinateReq

enum DebugAction: Decodable {
  case newTab
  case closeTab(TabTargetActionRequest)
  case selectTab(TabTargetActionRequest)
  case setTabTitle(TabTitleActionRequest)
  case freezeTabTitle(TabTitleActionRequest)
  case clearTabTitle(TabTargetActionRequest)
  case setTabMetadata(TabMetadataActionRequest)
  case moveTab(MoveTabActionRequest)
  case resizeWindow(ResizeWindowActionRequest)
  case setFontSize(SetFontSizeActionRequest)
  case setRenderer(SetRendererActionRequest)
  case typeText(TextActionRequest)
  case feedOutput(TextActionRequest)
  case advanceFrames(AdvanceFramesActionRequest)
  case setVectorSubpixelLayout(VectorSubpixelLayoutActionRequest)
  case setClipboardText(TextActionRequest)
  case setSelection(SelectionActionRequest)
  case setPreedit(PreeditActionRequest)
  case findStart(FindStartRequest)
  case findStep(FindStepRequest)
  case findStop(FindSessionRequest)
  case copy(SessionTargetActionRequest)
  case paste
  case dropFiles(DropFilesActionRequest)
  case scrollViewport(ScrollViewportActionRequest)
  case propose(CommandProposeRequest)
  case proposalList(CommandProposalRefRequest)
  case proposalGet(CommandProposalRefRequest)
  case proposalCancel(CommandProposalRefRequest)
  case mouseWheel(MouseWheelActionRequest)
  case mouseDrag(MouseDragActionRequest)
  case click(ClickActionRequest)
  case key(DebugKeyActionRequest)
  case windowFocus(WindowFocusActionRequest)
  case setBackgroundTransparency(SetBackgroundTransparencyActionRequest)
  case resetTransparencyDiagnostics(ResetTransparencyDiagnosticsActionRequest)
  case setReduceTransparencyOverride(SetReduceTransparencyOverrideActionRequest)
  case setNativeFullScreen(SetNativeFullScreenActionRequest)
  case setBackgroundSource(SetBackgroundSourceActionRequest)
  case setBackgroundImageScaling(SetBackgroundImageScalingActionRequest)
  case importBackgroundImage(ImportBackgroundImageActionRequest)
  case removeBackgroundImage(RemoveBackgroundImageActionRequest)
  case unsupported(String)

  private enum CodingKeys: String, CodingKey {
    case action
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let action = try container.decode(String.self, forKey: .action)
    switch action {
    case "newTab":
      self = .newTab
    case "closeTab":
      self = .closeTab(try TabTargetActionRequest(from: decoder))
    case "selectTab":
      self = .selectTab(try TabTargetActionRequest(from: decoder))
    case "setTabTitle":
      self = .setTabTitle(try TabTitleActionRequest(from: decoder))
    case "freezeTabTitle":
      self = .freezeTabTitle(try TabTitleActionRequest(from: decoder))
    case "clearTabTitle":
      self = .clearTabTitle(try TabTargetActionRequest(from: decoder))
    case "setTabMetadata":
      self = .setTabMetadata(try TabMetadataActionRequest(from: decoder))
    case "moveTab":
      self = .moveTab(try MoveTabActionRequest(from: decoder))
    case "resizeWindow":
      self = .resizeWindow(try ResizeWindowActionRequest(from: decoder))
    case "setFontSize":
      self = .setFontSize(try SetFontSizeActionRequest(from: decoder))
    case "setRenderer":
      self = .setRenderer(try SetRendererActionRequest(from: decoder))
    case "typeText":
      self = .typeText(try TextActionRequest(from: decoder))
    case "feedOutput":
      self = .feedOutput(try TextActionRequest(from: decoder))
    case "advanceFrames":
      self = .advanceFrames(try AdvanceFramesActionRequest(from: decoder))
    case "setVectorSubpixelLayout":
      self = .setVectorSubpixelLayout(try VectorSubpixelLayoutActionRequest(from: decoder))
    case "setClipboardText":
      self = .setClipboardText(try TextActionRequest(from: decoder))
    case "setSelection":
      self = .setSelection(try SelectionActionRequest(from: decoder))
    case "setPreedit":
      self = .setPreedit(try PreeditActionRequest(from: decoder))
    case "find.start":
      self = .findStart(try FindStartRequest(from: decoder))
    case "find.step":
      self = .findStep(try FindStepRequest(from: decoder))
    case "find.stop":
      self = .findStop(try FindSessionRequest(from: decoder))
    case "copy":
      self = .copy(try SessionTargetActionRequest(from: decoder))
    case "paste":
      self = .paste
    case "dropFiles":
      self = .dropFiles(try DropFilesActionRequest(from: decoder))
    case "scrollViewport":
      self = .scrollViewport(try ScrollViewportActionRequest(from: decoder))
    case "propose":
      self = .propose(try CommandProposeRequest(from: decoder))
    case "proposalList":
      self = .proposalList(try CommandProposalRefRequest(from: decoder))
    case "proposalGet":
      self = .proposalGet(try CommandProposalRefRequest(from: decoder))
    case "proposalCancel":
      self = .proposalCancel(try CommandProposalRefRequest(from: decoder))
    case "mouseWheel":
      self = .mouseWheel(try MouseWheelActionRequest(from: decoder))
    case "mouseDrag":
      self = .mouseDrag(try MouseDragActionRequest(from: decoder))
    case "click":
      self = .click(try ClickActionRequest(from: decoder))
    case "key":
      self = .key(try DebugKeyActionRequest(from: decoder))
    case "windowFocus":
      self = .windowFocus(try WindowFocusActionRequest(from: decoder))
    case "setBackgroundTransparency":
      self = .setBackgroundTransparency(
        try SetBackgroundTransparencyActionRequest(from: decoder))
    case "resetTransparencyDiagnostics":
      self = .resetTransparencyDiagnostics(
        try ResetTransparencyDiagnosticsActionRequest(from: decoder))
    case "setReduceTransparencyOverride":
      self = .setReduceTransparencyOverride(
        try SetReduceTransparencyOverrideActionRequest(from: decoder))
    case "setNativeFullScreen":
      self = .setNativeFullScreen(try SetNativeFullScreenActionRequest(from: decoder))
    case "setBackgroundSource":
      self = .setBackgroundSource(try SetBackgroundSourceActionRequest(from: decoder))
    case "setBackgroundImageScaling":
      self = .setBackgroundImageScaling(
        try SetBackgroundImageScalingActionRequest(from: decoder))
    case "importBackgroundImage":
      self = .importBackgroundImage(try ImportBackgroundImageActionRequest(from: decoder))
    case "removeBackgroundImage":
      self = .removeBackgroundImage(try RemoveBackgroundImageActionRequest(from: decoder))
    default:
      self = .unsupported(action)
    }
  }
}

extension DebugAction {
  var intent: Intent {
    switch self {
    case .newTab:
      return legacyIntent(action: "newTab")
    case .closeTab:
      return legacyIntent(action: "closeTab")
    case .selectTab(let request):
      return .tabSelect(TabSelectInput(tabId: request.tabId))
    case .setTabTitle:
      return legacyIntent(action: "setTabTitle")
    case .freezeTabTitle:
      return legacyIntent(action: "freezeTabTitle")
    case .clearTabTitle:
      return legacyIntent(action: "clearTabTitle")
    case .setTabMetadata:
      return legacyIntent(action: "setTabMetadata")
    case .moveTab:
      return legacyIntent(action: "moveTab")
    case .resizeWindow:
      return legacyIntent(action: "resizeWindow")
    case .setFontSize:
      return legacyIntent(action: "setFontSize")
    case .setRenderer:
      return legacyIntent(action: "setRenderer")
    case .typeText(let request):
      return .terminalTypeText(TypeTextInput(text: request.text ?? ""))
    case .feedOutput:
      return legacyIntent(action: "feedOutput")
    case .advanceFrames:
      return legacyIntent(action: "advanceFrames")
    case .setVectorSubpixelLayout:
      return legacyIntent(action: "setVectorSubpixelLayout")
    case .setClipboardText:
      return legacyIntent(action: "setClipboardText")
    case .setSelection:
      return legacyIntent(action: "setSelection")
    case .setPreedit:
      return legacyIntent(action: "setPreedit")
    case .findStart:
      return legacyIntent(action: "find.start")
    case .findStep:
      return legacyIntent(action: "find.step")
    case .findStop:
      return legacyIntent(action: "find.stop")
    case .copy:
      return legacyIntent(action: "copy")
    case .paste:
      return legacyIntent(action: "paste")
    case .dropFiles:
      return legacyIntent(action: "dropFiles")
    case .scrollViewport:
      return legacyIntent(action: "scrollViewport")
    case .propose:
      return legacyIntent(action: "propose")
    case .proposalList:
      return legacyIntent(action: "proposalList")
    case .proposalGet:
      return legacyIntent(action: "proposalGet")
    case .proposalCancel:
      return legacyIntent(action: "proposalCancel")
    case .mouseWheel:
      return legacyIntent(action: "mouseWheel")
    case .mouseDrag:
      return legacyIntent(action: "mouseDrag")
    case .click:
      return legacyIntent(action: "click")
    case .key(let request):
      return .terminalSendKey(
        SendKeyInput(key: request.key ?? "", modifiers: request.modifiers ?? []))
    case .windowFocus:
      return legacyIntent(action: "windowFocus")
    case .setBackgroundTransparency:
      return legacyIntent(action: "setBackgroundTransparency")
    case .resetTransparencyDiagnostics:
      return legacyIntent(action: "resetTransparencyDiagnostics")
    case .setReduceTransparencyOverride:
      return legacyIntent(action: "setReduceTransparencyOverride")
    case .setNativeFullScreen:
      return legacyIntent(action: "setNativeFullScreen")
    case .setBackgroundSource:
      return legacyIntent(action: "setBackgroundSource")
    case .setBackgroundImageScaling:
      return legacyIntent(action: "setBackgroundImageScaling")
    case .importBackgroundImage:
      return legacyIntent(action: "importBackgroundImage")
    case .removeBackgroundImage:
      return legacyIntent(action: "removeBackgroundImage")
    case .unsupported(let action):
      return .unsupportedDebugAction(UnsupportedDebugActionInput(action: action))
    }
  }

  var intentID: String {
    intent.id
  }

  private func legacyIntent(action: String) -> Intent {
    .legacyDebugAction(
      LegacyDebugActionInput(
        intentID: DebugActionIntentID.intentID(forAction: action)
          ?? DebugActionIntentID.unsupported,
        action: action))
  }
}

typealias TabTargetActionRequest = LabanCore.TabTargetActionRequest
typealias MoveTabActionRequest = LabanCore.MoveTabActionRequest
typealias TabTitleActionRequest = LabanCore.TabTitleActionRequest
typealias TabMetadataActionRequest = LabanCore.TabMetadataActionRequest
typealias ResizeWindowActionRequest = LabanCore.ResizeWindowActionRequest
typealias SetFontSizeActionRequest = LabanCore.SetFontSizeActionRequest
typealias SetRendererActionRequest = LabanCore.SetRendererActionRequest
typealias TextActionRequest = LabanCore.TextActionRequest
typealias AdvanceFramesActionRequest = LabanCore.AdvanceFramesActionRequest
typealias WindowFocusActionRequest = LabanCore.WindowFocusActionRequest
typealias DebugKeyActionRequest = LabanCore.DebugKeyActionRequest
typealias MouseWheelActionRequest = LabanCore.MouseWheelActionRequest
typealias MouseDragActionRequest = LabanCore.MouseDragActionRequest
typealias ClickActionRequest = LabanCore.ClickActionRequest
typealias SelectionActionRequest = LabanCore.SelectionActionRequest
typealias PreeditActionRequest = LabanCore.PreeditActionRequest
typealias SessionTargetActionRequest = LabanCore.SessionTargetActionRequest
typealias DropFilesActionRequest = LabanCore.DropFilesActionRequest
typealias ScrollViewportActionRequest = LabanCore.ScrollViewportActionRequest
typealias FindStartRequest = LabanCore.FindStartRequest
typealias FindStepRequest = LabanCore.FindStepRequest
typealias FindSessionRequest = LabanCore.FindSessionRequest
typealias CaptureStartRequest = LabanCore.CaptureStartRequest
typealias SetBackgroundTransparencyActionRequest =
  LabanCore.SetBackgroundTransparencyActionRequest
typealias ResetTransparencyDiagnosticsActionRequest =
  LabanCore.ResetTransparencyDiagnosticsActionRequest
typealias SetReduceTransparencyOverrideActionRequest =
  LabanCore.SetReduceTransparencyOverrideActionRequest
typealias SetNativeFullScreenActionRequest = LabanCore.SetNativeFullScreenActionRequest

struct CaptureStatusResponse: Encodable {
  var active: Bool
  var runId: String?
  var directory: String?
  var manifestPath: String?
  var screenshots: String?
}

struct CaptureStartResponse: Encodable {
  var active: Bool
  var alreadyActive: Bool
  var runId: String
  var directory: String
  var screenshots: String
}

struct CaptureStopResponse: Encodable {
  var active: Bool
  var runId: String?
  var directory: String?
  var manifestPath: String
}

typealias WaitRequest = LabanCore.WaitRequest
typealias WaitCondition = LabanCore.WaitCondition
typealias RenderTraceRequest = LabanCore.RenderTraceRequest
typealias PixelProbeReq = LabanCore.PixelProbeReq
