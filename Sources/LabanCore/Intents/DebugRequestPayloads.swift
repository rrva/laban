import Foundation

private enum DebugPayloadSchema {
  static let string = SchemaNode.string(enumValues: nil, const: nil, format: nil, pattern: nil)
  static let integer = SchemaNode.integer(min: nil, max: nil)
  static let number = SchemaNode.number(min: nil, max: nil)
  static let boolean = SchemaNode.boolean

  static func object(
    _ properties: [String: SchemaNode],
    required: [String] = [],
    additionalProperties: Bool = true
  ) -> SchemaNode {
    .object(properties: properties, required: required, additionalProperties: additionalProperties)
  }

  static func stringArray() -> SchemaNode {
    .array(string, minItems: 0)
  }
}

public struct DebugActionEnvelope: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var action: String

  public init(action: String) {
    self.action = action
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(["action": DebugPayloadSchema.string], required: ["action"])
  }
}

public enum DebugActionIntentID {
  public static let unsupported = "debug.action.unsupported"

  public static let knownActionNames: [String] = [
    "newTab",
    "closeTab",
    "selectTab",
    "setTabTitle",
    "freezeTabTitle",
    "clearTabTitle",
    "setTabMetadata",
    "moveTab",
    "resizeWindow",
    "setFontSize",
    "setRenderer",
    "typeText",
    "feedOutput",
    "advanceFrames",
    "setVectorSubpixelLayout",
    "setPreedit",
    "setClipboardText",
    "setSelection",
    "find.start",
    "find.step",
    "find.stop",
    "copy",
    "paste",
    "dropFiles",
    "scrollViewport",
    "mouseWheel",
    "mouseDrag",
    "click",
    "key",
    "windowFocus",
  ]

  public static func intentID(forAction action: String) -> String? {
    switch action {
    case "newTab": return "tab.new"
    case "closeTab": return "tab.close"
    case "selectTab": return "tab.select"
    case "setTabTitle": return "tab.title.set"
    case "freezeTabTitle": return "tab.title.freeze"
    case "clearTabTitle": return "tab.title.clear"
    case "setTabMetadata": return "tab.metadata.set"
    case "moveTab": return "tab.move"
    case "resizeWindow": return "window.resize"
    case "setFontSize": return "app.fontSize.set"
    case "setRenderer": return "renderer.set"
    case "typeText": return "terminal.typeText"
    case "feedOutput": return "fixture.feedOutput"
    case "advanceFrames": return "fixture.advanceFrames"
    case "setVectorSubpixelLayout": return "vector.subpixelLayout.set"
    case "setPreedit": return "preedit.set"
    case "setClipboardText": return "clipboard.setText"
    case "setSelection": return "selection.set"
    case "find.start": return "find.start"
    case "find.step": return "find.step"
    case "find.stop": return "find.stop"
    case "copy": return "clipboard.copy"
    case "paste": return "clipboard.paste"
    case "dropFiles": return "terminal.dropFiles"
    case "scrollViewport": return "terminal.scrollViewport"
    case "mouseWheel": return "terminal.mouseWheel"
    case "mouseDrag": return "terminal.mouseDrag"
    case "click": return "terminal.click"
    case "key": return "terminal.sendKey"
    case "windowFocus": return "fixture.windowFocus"
    default: return nil
    }
  }
}

public struct LegacyDebugActionInput: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var intentID: String
  public var action: String
  public var body: Data

  public init(intentID: String, action: String, body: Data = Data()) {
    self.intentID = intentID
    self.action = action
    self.body = body
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "action": DebugPayloadSchema.string,
        "body": SchemaNode.string(enumValues: nil, const: nil, format: "byte", pattern: nil),
        "intentID": DebugPayloadSchema.string,
      ], required: ["intentID", "action", "body"])
  }
}

public struct LegacyDebugQueryInput: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var intentID: String
  public var params: [String: String]

  public init(intentID: String, params: [String: String] = [:]) {
    self.intentID = intentID
    self.params = params
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "intentID": DebugPayloadSchema.string,
        "params": DebugPayloadSchema.object([:]),
      ], required: ["intentID", "params"])
  }
}

public struct LegacyDebugControlInput: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var intentID: String
  public var body: Data
  public var params: [String: String]

  public init(intentID: String, body: Data = Data(), params: [String: String] = [:]) {
    self.intentID = intentID
    self.body = body
    self.params = params
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "body": SchemaNode.string(enumValues: nil, const: nil, format: "byte", pattern: nil),
        "intentID": DebugPayloadSchema.string,
        "params": DebugPayloadSchema.object([:]),
      ], required: ["intentID", "body", "params"])
  }
}

public struct UnsupportedDebugActionInput: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var action: String

  public init(action: String) {
    self.action = action
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(["action": DebugPayloadSchema.string], required: ["action"])
  }
}

public struct CellCoordinateReq: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var row: Int
  public var col: Int

  public init(row: Int, col: Int) {
    self.row = row
    self.col = col
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "col": DebugPayloadSchema.integer,
        "row": DebugPayloadSchema.integer,
      ], required: ["row", "col"])
  }
}

public struct TabTargetActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var tabId: String?

  public init(tabId: String? = nil) {
    self.tabId = tabId
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(["tabId": DebugPayloadSchema.string])
  }
}

public struct SelectTabActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var action: String?
  public var tabId: String?
  public var index: Int?

  public init(action: String? = nil, tabId: String? = nil, index: Int? = nil) {
    self.action = action
    self.tabId = tabId
    self.index = index
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "action": DebugPayloadSchema.string,
      "index": SchemaNode.integer(min: 0, max: nil),
      "tabId": DebugPayloadSchema.string,
    ])
  }
}

public struct MoveTabActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var tabId: String?
  public var toIndex: Int?

  public init(tabId: String? = nil, toIndex: Int? = nil) {
    self.tabId = tabId
    self.toIndex = toIndex
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "tabId": DebugPayloadSchema.string,
      "toIndex": SchemaNode.integer(min: 0, max: nil),
    ])
  }
}

public struct TabTitleActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var tabId: String?
  public var title: String?
  public var text: String?
  public var frozen: Bool?

  public init(
    tabId: String? = nil,
    title: String? = nil,
    text: String? = nil,
    frozen: Bool? = nil
  ) {
    self.tabId = tabId
    self.title = title
    self.text = text
    self.frozen = frozen
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "frozen": DebugPayloadSchema.boolean,
      "tabId": DebugPayloadSchema.string,
      "text": DebugPayloadSchema.string,
      "title": DebugPayloadSchema.string,
    ])
  }
}

public struct TabMetadataActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var tabId: String?
  public var cwd: String?
  public var repoName: String?
  public var repoRoot: String?
  public var worktreeName: String?
  public var branch: String?
  public var isDirty: Bool?
  public var foregroundProcess: String?
  public var foregroundCommand: String?
  public var pid: Int?
  public var agentName: String?
  public var sessionName: String?
  public var agentSessionId: String?
  public var taskLabel: String?
  public var model: String?
  public var contextPercent: Int?
  public var awaitingInput: Bool?
  public var activityState: String?
  public var unseenOutput: Bool?
  public var bellAttention: Bool?
  public var exitStatus: Int?

  public init(
    tabId: String? = nil,
    cwd: String? = nil,
    repoName: String? = nil,
    repoRoot: String? = nil,
    worktreeName: String? = nil,
    branch: String? = nil,
    isDirty: Bool? = nil,
    foregroundProcess: String? = nil,
    foregroundCommand: String? = nil,
    pid: Int? = nil,
    agentName: String? = nil,
    sessionName: String? = nil,
    agentSessionId: String? = nil,
    taskLabel: String? = nil,
    model: String? = nil,
    contextPercent: Int? = nil,
    awaitingInput: Bool? = nil,
    activityState: String? = nil,
    unseenOutput: Bool? = nil,
    bellAttention: Bool? = nil,
    exitStatus: Int? = nil
  ) {
    self.tabId = tabId
    self.cwd = cwd
    self.repoName = repoName
    self.repoRoot = repoRoot
    self.worktreeName = worktreeName
    self.branch = branch
    self.isDirty = isDirty
    self.foregroundProcess = foregroundProcess
    self.foregroundCommand = foregroundCommand
    self.pid = pid
    self.agentName = agentName
    self.sessionName = sessionName
    self.agentSessionId = agentSessionId
    self.taskLabel = taskLabel
    self.model = model
    self.contextPercent = contextPercent
    self.awaitingInput = awaitingInput
    self.activityState = activityState
    self.unseenOutput = unseenOutput
    self.bellAttention = bellAttention
    self.exitStatus = exitStatus
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "activityState": DebugPayloadSchema.string,
      "agentName": DebugPayloadSchema.string,
      "agentSessionId": DebugPayloadSchema.string,
      "awaitingInput": DebugPayloadSchema.boolean,
      "bellAttention": DebugPayloadSchema.boolean,
      "branch": DebugPayloadSchema.string,
      "contextPercent": DebugPayloadSchema.integer,
      "cwd": DebugPayloadSchema.string,
      "exitStatus": DebugPayloadSchema.integer,
      "foregroundCommand": DebugPayloadSchema.string,
      "foregroundProcess": DebugPayloadSchema.string,
      "isDirty": DebugPayloadSchema.boolean,
      "model": DebugPayloadSchema.string,
      "pid": DebugPayloadSchema.integer,
      "repoName": DebugPayloadSchema.string,
      "repoRoot": DebugPayloadSchema.string,
      "sessionName": DebugPayloadSchema.string,
      "tabId": DebugPayloadSchema.string,
      "taskLabel": DebugPayloadSchema.string,
      "unseenOutput": DebugPayloadSchema.boolean,
      "worktreeName": DebugPayloadSchema.string,
    ])
  }
}

public struct ResizeWindowActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var width: Int?
  public var height: Int?

  public init(width: Int? = nil, height: Int? = nil) {
    self.width = width
    self.height = height
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "height": DebugPayloadSchema.integer,
      "width": DebugPayloadSchema.integer,
    ])
  }
}

public struct SetFontSizeActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var pointSize: Double?

  public init(pointSize: Double? = nil) {
    self.pointSize = pointSize
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(["pointSize": DebugPayloadSchema.number])
  }
}

public struct TextActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var text: String?
  public var tabId: String?

  public init(text: String? = nil, tabId: String? = nil) {
    self.text = text
    self.tabId = tabId
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "tabId": DebugPayloadSchema.string,
      "text": DebugPayloadSchema.string,
    ])
  }
}

public struct SetRendererActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var renderer: String?

  public init(renderer: String? = nil) {
    self.renderer = renderer
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "renderer": SchemaNode.string(
          enumValues: ["software", "classic", "gpuDriven", "vectorGlyph"],
          const: nil,
          format: nil,
          pattern: nil)
      ], required: ["renderer"])
  }
}

public struct AdvanceFramesActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var count: Int?

  public init(count: Int? = nil) {
    self.count = count
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(["count": SchemaNode.integer(min: 1, max: nil)])
  }
}

public struct VectorSubpixelLayoutActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var layout: String?
  public var offsets: [Double]?

  public init(layout: String? = nil, offsets: [Double]? = nil) {
    self.layout = layout
    self.offsets = offsets
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "layout": DebugPayloadSchema.string,
      "offsets": .array(DebugPayloadSchema.number, minItems: 3),
    ])
  }
}

public struct WindowFocusActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var focused: Bool?

  public init(focused: Bool? = nil) {
    self.focused = focused
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(["focused": DebugPayloadSchema.boolean])
  }
}

public struct DebugKeyActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var key: String?
  public var type: String?
  public var modifiers: [String]?
  public var consumedModifiers: [String]?
  public var unshifted: String?
  public var text: String?

  public init(
    key: String? = nil,
    type: String? = nil,
    modifiers: [String]? = nil,
    consumedModifiers: [String]? = nil,
    unshifted: String? = nil,
    text: String? = nil
  ) {
    self.key = key
    self.type = type
    self.modifiers = modifiers
    self.consumedModifiers = consumedModifiers
    self.unshifted = unshifted
    self.text = text
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "consumedModifiers": DebugPayloadSchema.stringArray(),
      "key": DebugPayloadSchema.string,
      "modifiers": DebugPayloadSchema.stringArray(),
      "text": DebugPayloadSchema.string,
      "type": DebugPayloadSchema.string,
      "unshifted": DebugPayloadSchema.string,
    ])
  }
}

public struct MouseWheelActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var x: Int?
  public var y: Int?
  public var deltaY: Double?

  public init(x: Int? = nil, y: Int? = nil, deltaY: Double? = nil) {
    self.x = x
    self.y = y
    self.deltaY = deltaY
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "deltaY": DebugPayloadSchema.number,
      "x": DebugPayloadSchema.integer,
      "y": DebugPayloadSchema.integer,
    ])
  }
}

public struct MouseDragActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var startX: Int?
  public var startY: Int?
  public var endX: Int?
  public var endY: Int?
  public var button: String?
  public var holdMs: Int?

  public init(
    startX: Int? = nil,
    startY: Int? = nil,
    endX: Int? = nil,
    endY: Int? = nil,
    button: String? = nil,
    holdMs: Int? = nil
  ) {
    self.startX = startX
    self.startY = startY
    self.endX = endX
    self.endY = endY
    self.button = button
    self.holdMs = holdMs
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "button": DebugPayloadSchema.string,
      "endX": DebugPayloadSchema.integer,
      "endY": DebugPayloadSchema.integer,
      "holdMs": SchemaNode.integer(min: 0, max: nil),
      "startX": DebugPayloadSchema.integer,
      "startY": DebugPayloadSchema.integer,
    ])
  }
}

public struct ClickActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var x: Int?
  public var y: Int?
  public var button: String?

  public init(x: Int? = nil, y: Int? = nil, button: String? = nil) {
    self.x = x
    self.y = y
    self.button = button
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "button": DebugPayloadSchema.string,
      "x": DebugPayloadSchema.integer,
      "y": DebugPayloadSchema.integer,
    ])
  }
}

public struct SelectionActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var sessionId: String?
  public var anchor: CellCoordinateReq?
  public var focus: CellCoordinateReq?

  public init(
    sessionId: String? = nil,
    anchor: CellCoordinateReq? = nil,
    focus: CellCoordinateReq? = nil
  ) {
    self.sessionId = sessionId
    self.anchor = anchor
    self.focus = focus
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "anchor": CellCoordinateReq.jsonSchema,
      "focus": CellCoordinateReq.jsonSchema,
      "sessionId": DebugPayloadSchema.string,
    ])
  }
}

public struct PreeditActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var sessionId: String?
  public var text: String?
  public var caretCells: Int?

  public init(sessionId: String? = nil, text: String? = nil, caretCells: Int? = nil) {
    self.sessionId = sessionId
    self.text = text
    self.caretCells = caretCells
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "caretCells": DebugPayloadSchema.integer,
      "sessionId": DebugPayloadSchema.string,
      "text": DebugPayloadSchema.string,
    ])
  }
}

public struct SessionTargetActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var sessionId: String?

  public init(sessionId: String? = nil) {
    self.sessionId = sessionId
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(["sessionId": DebugPayloadSchema.string])
  }
}

public struct DropFilesActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var paths: [String]?

  public init(paths: [String]? = nil) {
    self.paths = paths
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(["paths": DebugPayloadSchema.stringArray()])
  }
}

public struct ScrollViewportActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var sessionId: String?
  public var deltaRows: Int?

  public init(sessionId: String? = nil, deltaRows: Int? = nil) {
    self.sessionId = sessionId
    self.deltaRows = deltaRows
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "deltaRows": DebugPayloadSchema.integer,
      "sessionId": DebugPayloadSchema.string,
    ])
  }
}

public struct FindStartRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var sessionID: String?
  public var sessionId: String?
  public var needle: String?

  public var targetSessionId: String? { sessionID ?? sessionId }

  public init(sessionID: String? = nil, sessionId: String? = nil, needle: String? = nil) {
    self.sessionID = sessionID
    self.sessionId = sessionId
    self.needle = needle
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "needle": DebugPayloadSchema.string,
      "sessionID": DebugPayloadSchema.string,
      "sessionId": DebugPayloadSchema.string,
    ])
  }
}

public struct FindStepRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var sessionID: String?
  public var sessionId: String?
  public var direction: String?

  public var targetSessionId: String? { sessionID ?? sessionId }

  public init(sessionID: String? = nil, sessionId: String? = nil, direction: String? = nil) {
    self.sessionID = sessionID
    self.sessionId = sessionId
    self.direction = direction
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "direction": DebugPayloadSchema.string,
      "sessionID": DebugPayloadSchema.string,
      "sessionId": DebugPayloadSchema.string,
    ])
  }
}

public struct FindSessionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var sessionID: String?
  public var sessionId: String?

  public var targetSessionId: String? { sessionID ?? sessionId }

  public init(sessionID: String? = nil, sessionId: String? = nil) {
    self.sessionID = sessionID
    self.sessionId = sessionId
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "sessionID": DebugPayloadSchema.string,
      "sessionId": DebugPayloadSchema.string,
    ])
  }
}

public struct CaptureStartRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var name: String?
  public var screenshots: String?

  public init(name: String? = nil, screenshots: String? = nil) {
    self.name = name
    self.screenshots = screenshots
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "name": DebugPayloadSchema.string,
      "screenshots": DebugPayloadSchema.string,
    ])
  }
}

public struct WaitRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var timeoutMs: Int
  public var condition: WaitCondition

  public init(timeoutMs: Int, condition: WaitCondition) {
    self.timeoutMs = timeoutMs
    self.condition = condition
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "condition": WaitCondition.jsonSchema,
        "timeoutMs": SchemaNode.integer(min: 0, max: nil),
      ], required: ["timeoutMs", "condition"])
  }
}

public struct WaitCondition: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var kind: String
  public var frame: Int?
  public var eventKind: String?
  public var count: Int?
  public var tabId: String?
  public var sessionId: String?
  public var status: String?
  public var title: String?
  public var text: String?
  public var commandKind: String?
  public var invariantKind: String?
  public var level: String?

  public init(
    kind: String,
    frame: Int? = nil,
    eventKind: String? = nil,
    count: Int? = nil,
    tabId: String? = nil,
    sessionId: String? = nil,
    status: String? = nil,
    title: String? = nil,
    text: String? = nil,
    commandKind: String? = nil,
    invariantKind: String? = nil,
    level: String? = nil
  ) {
    self.kind = kind
    self.frame = frame
    self.eventKind = eventKind
    self.count = count
    self.tabId = tabId
    self.sessionId = sessionId
    self.status = status
    self.title = title
    self.text = text
    self.commandKind = commandKind
    self.invariantKind = invariantKind
    self.level = level
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "commandKind": DebugPayloadSchema.string,
        "count": DebugPayloadSchema.integer,
        "eventKind": DebugPayloadSchema.string,
        "frame": DebugPayloadSchema.integer,
        "invariantKind": DebugPayloadSchema.string,
        "kind": DebugPayloadSchema.string,
        "level": DebugPayloadSchema.string,
        "sessionId": DebugPayloadSchema.string,
        "status": DebugPayloadSchema.string,
        "tabId": DebugPayloadSchema.string,
        "text": DebugPayloadSchema.string,
        "title": DebugPayloadSchema.string,
      ], required: ["kind"])
  }
}

public struct RenderTraceRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var frame: Int?
  public var target: String?
  public var include: [String]?
  public var commandIds: [String]?
  public var pixelProbes: [PixelProbeReq]?
  public var limit: Int?

  public init(
    frame: Int? = nil,
    target: String? = nil,
    include: [String]? = nil,
    commandIds: [String]? = nil,
    pixelProbes: [PixelProbeReq]? = nil,
    limit: Int? = nil
  ) {
    self.frame = frame
    self.target = target
    self.include = include
    self.commandIds = commandIds
    self.pixelProbes = pixelProbes
    self.limit = limit
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "commandIds": DebugPayloadSchema.stringArray(),
      "frame": DebugPayloadSchema.integer,
      "include": DebugPayloadSchema.stringArray(),
      "limit": SchemaNode.integer(min: 0, max: nil),
      "pixelProbes": .array(PixelProbeReq.jsonSchema, minItems: 0),
      "target": DebugPayloadSchema.string,
    ])
  }
}

public struct PixelProbeReq: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var name: String?
  public var x: Int
  public var y: Int

  public init(name: String? = nil, x: Int, y: Int) {
    self.name = name
    self.x = x
    self.y = y
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "name": DebugPayloadSchema.string,
        "x": DebugPayloadSchema.integer,
        "y": DebugPayloadSchema.integer,
      ], required: ["x", "y"])
  }
}

public struct PixelProbePointRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var x: Int
  public var y: Int

  public init(x: Int, y: Int) {
    self.x = x
    self.y = y
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "x": DebugPayloadSchema.integer,
        "y": DebugPayloadSchema.integer,
      ], required: ["x", "y"])
  }
}

public struct PixelProbeRegionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var name: String
  public var x: Int
  public var y: Int
  public var width: Int
  public var height: Int

  public init(name: String, x: Int, y: Int, width: Int, height: Int) {
    self.name = name
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "height": SchemaNode.integer(min: 1, max: nil),
        "name": DebugPayloadSchema.string,
        "width": SchemaNode.integer(min: 1, max: nil),
        "x": DebugPayloadSchema.integer,
        "y": DebugPayloadSchema.integer,
      ], required: ["name", "x", "y", "width", "height"])
  }
}

public struct PixelProbeRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var points: [PixelProbePointRequest]?
  public var regions: [PixelProbeRegionRequest]?

  public init(points: [PixelProbePointRequest]? = nil, regions: [PixelProbeRegionRequest]? = nil) {
    self.points = points
    self.regions = regions
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "points": .array(PixelProbePointRequest.jsonSchema, minItems: 0),
      "regions": .array(PixelProbeRegionRequest.jsonSchema, minItems: 0),
    ])
  }
}

public struct FixtureControlRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var action: String
  public var path: String?
  public var count: Int?

  public init(action: String, path: String? = nil, count: Int? = nil) {
    self.action = action
    self.path = path
    self.count = count
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "action": DebugPayloadSchema.string,
        "count": SchemaNode.integer(min: 1, max: nil),
        "path": DebugPayloadSchema.string,
      ], required: ["action"])
  }
}

public struct AgentRestoreSelectionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var tabIds: [String]?
  public var selectedTabIds: [String]?
  public var environmentPatch: [String: String]?

  public init(
    tabIds: [String]? = nil,
    selectedTabIds: [String]? = nil,
    environmentPatch: [String: String]? = nil
  ) {
    self.tabIds = tabIds
    self.selectedTabIds = selectedTabIds
    self.environmentPatch = environmentPatch
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "environmentPatch": .object(
        properties: [:],
        required: [],
        additionalProperties: true),
      "selectedTabIds": DebugPayloadSchema.stringArray(),
      "tabIds": DebugPayloadSchema.stringArray(),
    ])
  }
}
