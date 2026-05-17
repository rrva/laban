import Foundation

struct CellCoordinateReq: Decodable {
  var row: Int
  var col: Int
}

enum DebugAction: Decodable {
  case newTab
  case closeTab(TabTargetActionRequest)
  case selectTab(TabTargetActionRequest)
  case setTabTitle(TabTitleActionRequest)
  case freezeTabTitle(TabTitleActionRequest)
  case clearTabTitle(TabTargetActionRequest)
  case setTabMetadata(TabMetadataActionRequest)
  case resizeWindow(ResizeWindowActionRequest)
  case typeText(TextActionRequest)
  case feedOutput(TextActionRequest)
  case advanceFrames(AdvanceFramesActionRequest)
  case setClipboardText(TextActionRequest)
  case setSelection(SelectionActionRequest)
  case findStart(FindStartRequest)
  case findStep(FindStepRequest)
  case findStop(FindSessionRequest)
  case copy(SessionTargetActionRequest)
  case paste
  case dropFiles(DropFilesActionRequest)
  case scrollViewport(ScrollViewportActionRequest)
  case mouseWheel(MouseWheelActionRequest)
  case click(ClickActionRequest)
  case key(DebugKeyActionRequest)
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
    case "resizeWindow":
      self = .resizeWindow(try ResizeWindowActionRequest(from: decoder))
    case "typeText":
      self = .typeText(try TextActionRequest(from: decoder))
    case "feedOutput":
      self = .feedOutput(try TextActionRequest(from: decoder))
    case "advanceFrames":
      self = .advanceFrames(try AdvanceFramesActionRequest(from: decoder))
    case "setClipboardText":
      self = .setClipboardText(try TextActionRequest(from: decoder))
    case "setSelection":
      self = .setSelection(try SelectionActionRequest(from: decoder))
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
    case "mouseWheel":
      self = .mouseWheel(try MouseWheelActionRequest(from: decoder))
    case "click":
      self = .click(try ClickActionRequest(from: decoder))
    case "key":
      self = .key(try DebugKeyActionRequest(from: decoder))
    default:
      self = .unsupported(action)
    }
  }
}

struct TabTargetActionRequest: Decodable {
  var tabId: String?
}

struct TabTitleActionRequest: Decodable {
  var tabId: String?
  var title: String?
  var text: String?
  var frozen: Bool?
}

struct TabMetadataActionRequest: Decodable {
  var tabId: String?
  var cwd: String?
  var repoName: String?
  var repoRoot: String?
  var worktreeName: String?
  var branch: String?
  var isDirty: Bool?
  var foregroundProcess: String?
  var foregroundCommand: String?
  var pid: Int?
  var agentName: String?
  var sessionName: String?
  var agentSessionId: String?
  var taskLabel: String?
  var model: String?
  var contextPercent: Int?
  var awaitingInput: Bool?
  var activityState: String?
  var unseenOutput: Bool?
  var exitStatus: Int?
}

struct ResizeWindowActionRequest: Decodable {
  var width: Int?
  var height: Int?
}

struct TextActionRequest: Decodable {
  var text: String?
  /// Optional target tab. Honored by `feedOutput` so callers can
  /// target a specific tab without first changing focus. Other
  /// actions that use `TextActionRequest` (`typeText`,
  /// `setClipboardText`) ignore this — typed text goes to the
  /// active tab by definition.
  var tabId: String?
}

struct AdvanceFramesActionRequest: Decodable {
  var count: Int?
}

struct DebugKeyActionRequest: Decodable {
  var key: String?
  var type: String?
  var modifiers: [String]?
  var consumedModifiers: [String]?
  var unshifted: String?
  var text: String?
}

struct MouseWheelActionRequest: Decodable {
  var x: Int?
  var y: Int?
  var deltaY: Double?
}

struct ClickActionRequest: Decodable {
  var x: Int?
  var y: Int?
  var button: String?
}

struct SelectionActionRequest: Decodable {
  var sessionId: String?
  var anchor: CellCoordinateReq?
  var focus: CellCoordinateReq?
}

struct SessionTargetActionRequest: Decodable {
  var sessionId: String?
}

struct DropFilesActionRequest: Decodable {
  var paths: [String]?
}

struct ScrollViewportActionRequest: Decodable {
  var sessionId: String?
  var deltaRows: Int?
}

struct FindStartRequest: Decodable {
  var sessionID: String?
  var sessionId: String?
  var needle: String?

  var targetSessionId: String? { sessionID ?? sessionId }
}

struct FindStepRequest: Decodable {
  var sessionID: String?
  var sessionId: String?
  var direction: String?

  var targetSessionId: String? { sessionID ?? sessionId }
}

struct FindSessionRequest: Decodable {
  var sessionID: String?
  var sessionId: String?

  var targetSessionId: String? { sessionID ?? sessionId }
}

struct CaptureStartRequest: Decodable {
  var name: String? = nil
  var screenshots: String? = nil
}

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

struct WaitRequest: Decodable {
  var timeoutMs: Int
  var condition: WaitCondition
}

struct WaitCondition: Decodable {
  var kind: String
  var frame: Int?
  var eventKind: String?
  var count: Int?
  var tabId: String?
  var sessionId: String?
  var status: String?
  var title: String?
  var text: String?
  var commandKind: String?
  var invariantKind: String?
  var level: String?
}

struct RenderTraceRequest: Decodable {
  var frame: Int?
  var target: String?
  var include: [String]?
  var commandIds: [String]?
  var pixelProbes: [PixelProbeReq]?
  var limit: Int?
}

struct PixelProbeReq: Decodable {
  var name: String?
  var x: Int
  var y: Int
}
