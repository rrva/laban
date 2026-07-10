import Foundation

public enum Capability: String, Codable, CaseIterable, Sendable {
  case observe
  case observeSensitive
  case navigate
  case propose
  case input
  case clipboard
  case fixture
}

public enum DataSensitivity: String, Codable, Sendable {
  case none
  case nonSensitiveState
  case visibleText
  case scrollback
  case keystrokes
  case clipboard
  case screenshot
  case trace
  case sensitivePrivate
}

public enum Surface: Sendable, Equatable {
  case gui
  case headless
}

public indirect enum SchemaNode: Sendable, Equatable {
  public enum Example: Sendable, Equatable {
    case string(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)
    case object([String: Example])
    case array([Example])
    case null

    var jsonValue: Any {
      switch self {
      case .string(let value):
        return value
      case .integer(let value):
        return value
      case .number(let value):
        return value
      case .boolean(let value):
        return value
      case .object(let values):
        var object: [String: Any] = [:]
        for key in values.keys.sorted() {
          object[key] = values[key]?.jsonValue
        }
        return object
      case .array(let values):
        return values.map(\.jsonValue)
      case .null:
        return NSNull()
      }
    }
  }

  case object(properties: [String: SchemaNode], required: [String], additionalProperties: Bool)
  case string(enumValues: [String]?, const: String?, format: String?, pattern: String?)
  case integer(min: Int?, max: Int?)
  case number(min: Double?, max: Double?)
  case boolean
  case array(SchemaNode, minItems: Int?)
  case optional(SchemaNode)
  case oneOf([SchemaNode])
  case ref(String)
  case defs([String: SchemaNode], SchemaNode)
  case withExamples(SchemaNode, [Example])

  public var examples: [Any]? {
    guard case .withExamples(_, let examples) = self else {
      return nil
    }
    return examples.map(\.jsonValue)
  }

  public func withExamples(_ examples: [Example]) -> SchemaNode {
    .withExamples(self, examples)
  }

  public func toJSONSchema() -> [String: Any] {
    switch self {
    case .object(let properties, let required, let additionalProperties):
      var propertySchemas: [String: Any] = [:]
      for key in properties.keys.sorted() {
        propertySchemas[key] = properties[key]?.toJSONSchema()
      }

      var schema: [String: Any] = [
        "additionalProperties": additionalProperties,
        "properties": propertySchemas,
        "type": "object",
      ]
      if !required.isEmpty {
        schema["required"] = required.sorted()
      }
      return schema

    case .string(let enumValues, let const, let format, let pattern):
      var schema: [String: Any] = ["type": "string"]
      if let enumValues {
        schema["enum"] = enumValues
      }
      if let const {
        schema["const"] = const
      }
      if let format {
        schema["format"] = format
      }
      if let pattern {
        schema["pattern"] = pattern
      }
      return schema

    case .integer(let min, let max):
      var schema: [String: Any] = ["type": "integer"]
      if let min {
        schema["minimum"] = min
      }
      if let max {
        schema["maximum"] = max
      }
      return schema

    case .number(let min, let max):
      var schema: [String: Any] = ["type": "number"]
      if let min {
        schema["minimum"] = min
      }
      if let max {
        schema["maximum"] = max
      }
      return schema

    case .boolean:
      return ["type": "boolean"]

    case .array(let item, let minItems):
      var schema: [String: Any] = [
        "items": item.toJSONSchema(),
        "type": "array",
      ]
      if let minItems {
        schema["minItems"] = minItems
      }
      return schema

    case .optional(let node):
      return node.toJSONSchema()

    case .oneOf(let nodes):
      return ["oneOf": nodes.map { $0.toJSONSchema() }]

    case .ref(let ref):
      return ["$ref": ref]

    case .defs(let defs, let node):
      var schema = node.toJSONSchema()
      var defSchemas: [String: Any] = [:]
      for key in defs.keys.sorted() {
        defSchemas[key] = defs[key]?.toJSONSchema()
      }
      schema["$defs"] = defSchemas
      return schema

    case .withExamples(let node, let examples):
      var schema = node.toJSONSchema()
      schema["examples"] = examples.map(\.jsonValue)
      return schema
    }
  }
}

public protocol JSONSchemaProviding {
  static var jsonSchema: SchemaNode { get }
}

public struct ControlResponse: Sendable {
  public var status: Int
  public var contentType: String
  public var headers: [String: String]
  public var body: Data

  public init(
    status: Int,
    contentType: String,
    headers: [String: String] = [:],
    body: Data
  ) {
    self.status = status
    self.contentType = contentType
    self.headers = headers
    self.body = body
  }

  public static func json<T: Encodable>(_ value: T, status: Int = 200) -> ControlResponse {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = .sortedKeys
    guard let body = try? encoder.encode(value) else {
      return error(500, "encoding failed")
    }
    return ControlResponse(
      status: status,
      contentType: "application/json",
      body: body)
  }

  public static func binary(
    _ body: Data,
    contentType: String,
    headers: [String: String] = [:],
    status: Int = 200
  ) -> ControlResponse {
    ControlResponse(status: status, contentType: contentType, headers: headers, body: body)
  }

  public static func error(_ status: Int, _ message: String) -> ControlResponse {
    let escaped =
      message
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    let body = Data("{\"error\":\"\(escaped)\"}".utf8)
    return ControlResponse(status: status, contentType: "application/json", body: body)
  }
}

public struct ControlArtifact: Sendable {
  public let contentType: String
  public let headers: [String: String]
  public let body: Data

  public init(
    contentType: String,
    headers: [String: String] = [:],
    body: Data
  ) {
    self.contentType = contentType
    self.headers = headers
    self.body = body
  }
}

public struct ArtifactRequest: Sendable {
  public let id: String
  public let params: [String: String]

  public init(id: String, params: [String: String] = [:]) {
    self.id = id
    self.params = params
  }
}

public struct ControlReadiness: Codable, Sendable, Equatable {
  public let debugServer: String
  public let debugToken: String
  public let pid: Int32
  public let runId: String

  public init(debugServer: String, debugToken: String, pid: Int32, runId: String) {
    self.debugServer = debugServer
    self.debugToken = debugToken
    self.pid = pid
    self.runId = runId
  }
}

public struct TabSelectInput: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var tabId: String?
  public var index: Int?

  public init(tabId: String? = nil, index: Int? = nil) {
    self.tabId = tabId
    self.index = index
  }

  public static var jsonSchema: SchemaNode {
    .object(
      properties: [
        "index": .integer(min: 0, max: nil),
        "tabId": .string(enumValues: nil, const: nil, format: nil, pattern: nil),
      ],
      required: [],
      additionalProperties: false)
  }
}

public struct TypeTextInput: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var text: String

  public init(text: String) {
    self.text = text
  }

  public static var jsonSchema: SchemaNode {
    .object(
      properties: [
        "text": .string(enumValues: nil, const: nil, format: nil, pattern: nil)
      ],
      required: ["text"],
      additionalProperties: false)
  }
}

public struct SendKeyInput: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var key: String
  public var modifiers: [String]

  public init(key: String, modifiers: [String] = []) {
    self.key = key
    self.modifiers = modifiers
  }

  public static var jsonSchema: SchemaNode {
    .object(
      properties: [
        "key": .string(enumValues: nil, const: nil, format: nil, pattern: nil),
        "modifiers": .array(
          .string(enumValues: nil, const: nil, format: nil, pattern: nil),
          minItems: 0),
      ],
      required: ["key"],
      additionalProperties: false)
  }
}

public enum Intent: Sendable, Equatable {
  case tabSelect(TabSelectInput)
  case terminalTypeText(TypeTextInput)
  case terminalSendKey(SendKeyInput)
  case legacyDebugAction(LegacyDebugActionInput)
  case unsupportedDebugAction(UnsupportedDebugActionInput)

  public var id: String {
    switch self {
    case .tabSelect:
      return "tab.select"
    case .terminalTypeText:
      return "terminal.typeText"
    case .terminalSendKey:
      return "terminal.sendKey"
    case .legacyDebugAction(let input):
      return input.intentID
    case .unsupportedDebugAction:
      return DebugActionIntentID.unsupported
    }
  }
}

public enum Query: Sendable, Equatable {
  case state

  public var id: String {
    "app.state"
  }
}

public protocol IntentRouter: AnyObject {
  func route(_ intent: Intent) -> ControlResponse
  func query(_ query: Query) -> ControlResponse
  func query(_ query: LegacyDebugQueryInput) -> ControlResponse
  func control(_ input: LegacyDebugControlInput) -> ControlResponse
  func artifact(_ request: ArtifactRequest) -> ControlResponse?
}

extension IntentRouter {
  public func query(_ query: LegacyDebugQueryInput) -> ControlResponse {
    .error(501, "not yet ported")
  }

  public func control(_ input: LegacyDebugControlInput) -> ControlResponse {
    .error(501, "not yet ported")
  }
}

public struct IntentDescriptor: Sendable, Equatable {
  public enum Kind: String, Sendable {
    case query
    case action
    case wait
    case event
    case artifact
  }

  public struct SideEffects: Sendable, Equatable {
    public var ptyInput: Bool
    public var lifecycle: Bool
    public var clipboard: Bool
    public var filesystem: Bool
    public var network: Bool

    public init(
      ptyInput: Bool = false,
      lifecycle: Bool = false,
      clipboard: Bool = false,
      filesystem: Bool = false,
      network: Bool = false
    ) {
      self.ptyInput = ptyInput
      self.lifecycle = lifecycle
      self.clipboard = clipboard
      self.filesystem = filesystem
      self.network = network
    }
  }

  public struct Risk: Sendable, Equatable {
    public enum Level: String, Sendable {
      case none
      case low
      case medium
      case high
    }

    public let level: Level
    public let reason: String

    public init(level: Level, reason: String) {
      self.level = level
      self.reason = reason
    }
  }

  public enum Audit: String, Sendable {
    case none
    case metadataOnly
    case redactedInput
    case fullInput
  }

  public struct Availability: Sendable, Equatable {
    public let gui: Bool
    public let headless: Bool

    public init(gui: Bool, headless: Bool) {
      self.gui = gui
      self.headless = headless
    }

    public func permits(_ surface: Surface) -> Bool {
      switch surface {
      case .gui:
        return gui
      case .headless:
        return headless
      }
    }
  }

  public struct Transports: Sendable, Equatable {
    public let http: Bool
    public let mcp: Bool
    public let cli: Bool

    public init(http: Bool, mcp: Bool, cli: Bool) {
      self.http = http
      self.mcp = mcp
      self.cli = cli
    }
  }

  public let id: String
  public let kind: Kind
  public let category: String
  public let summary: String
  public let requiredCapability: Capability
  public let dataSensitivity: DataSensitivity
  public let sideEffects: SideEffects
  public let risk: Risk
  public let audit: Audit
  public let availability: Availability
  public let transports: Transports
  public let inputSchema: SchemaNode?
  public let outputSchema: SchemaNode?
  public let errorSchema: SchemaNode?
  public let classificationExplicit: Bool

  public init(
    id: String,
    kind: Kind,
    category: String,
    summary: String,
    requiredCapability: Capability,
    dataSensitivity: DataSensitivity,
    sideEffects: SideEffects,
    risk: Risk,
    audit: Audit,
    availability: Availability,
    transports: Transports,
    inputSchema: SchemaNode?,
    outputSchema: SchemaNode?,
    errorSchema: SchemaNode?,
    classificationExplicit: Bool = true
  ) {
    self.id = id
    self.kind = kind
    self.category = category
    self.summary = summary
    self.requiredCapability = requiredCapability
    self.dataSensitivity = dataSensitivity
    self.sideEffects = sideEffects
    self.risk = risk
    self.audit = audit
    self.availability = availability
    self.transports = transports
    self.inputSchema = inputSchema
    self.outputSchema = outputSchema
    self.errorSchema = errorSchema
    self.classificationExplicit = classificationExplicit
  }
}

public struct HTTPBinding: Sendable, Equatable {
  public let method: String
  public let path: String
  public let category: String
  public let summary: String
  public let queryParameters: [String]
  public let legacyRequestSchemaPath: String?
  public let legacyResponseSchemaPath: String?
  public let examples: [String]

  public init(
    method: String,
    path: String,
    category: String,
    summary: String,
    queryParameters: [String] = [],
    legacyRequestSchemaPath: String? = nil,
    legacyResponseSchemaPath: String? = nil,
    examples: [String] = []
  ) {
    self.method = method
    self.path = path
    self.category = category
    self.summary = summary
    self.queryParameters = queryParameters
    self.legacyRequestSchemaPath = legacyRequestSchemaPath
    self.legacyResponseSchemaPath = legacyResponseSchemaPath
    self.examples = examples
  }
}

public struct ControlEndpointDescriptor: Sendable, Equatable {
  public enum IntentMapping: Sendable, Equatable {
    case none
    case fixed(String)
    case requestBodyField(String)
    case queryParameter(String)
  }

  public let binding: HTTPBinding
  public let intentMapping: IntentMapping

  public init(binding: HTTPBinding, intentMapping: IntentMapping = .none) {
    self.binding = binding
    self.intentMapping = intentMapping
  }

  public var fixedIntentId: String? {
    guard case .fixed(let id) = intentMapping else {
      return nil
    }
    return id
  }
}

struct ControlRoute: Sendable, Equatable {
  let endpoint: ControlEndpointDescriptor
}

public struct IntentCatalog: Sendable {
  public enum ValidationError: Error, Equatable, CustomStringConvertible, Sendable {
    case emptyID(index: Int)
    case duplicateID(String)
    case fixtureAvailableInGUI(String)
    case missingInputSchema(String)
    case missingOutputSchema(String)
    case emptySchema(id: String, field: String)
    case unclassifiedDescriptor(String)

    public var description: String {
      switch self {
      case .emptyID(let index):
        return "intent descriptor at index \(index) has an empty id"
      case .duplicateID(let id):
        return "intent descriptor id is duplicated: \(id)"
      case .fixtureAvailableInGUI(let id):
        return "fixture intent is available in GUI: \(id)"
      case .missingInputSchema(let id):
        return "intent descriptor is missing an input schema: \(id)"
      case .missingOutputSchema(let id):
        return "intent descriptor is missing an output schema: \(id)"
      case .emptySchema(let id, let field):
        return "intent descriptor \(id) has an empty \(field) schema"
      case .unclassifiedDescriptor(let id):
        return "intent descriptor is missing explicit capability and dataSensitivity: \(id)"
      }
    }
  }

  public let descriptors: [IntentDescriptor]

  public init(_ descriptors: [IntentDescriptor]) {
    self.descriptors = descriptors
  }

  public func descriptor(id: String) -> IntentDescriptor? {
    descriptors.first { $0.id == id }
  }

  public var ids: Set<String> {
    Set(descriptors.map(\.id))
  }

  public func sharedIds() -> Set<String> {
    Set(Self.shared.descriptors.map(\.id))
  }

  public func validate() throws {
    try validate(endpointDescriptors: [])
  }

  public func validate(endpointDescriptors endpoints: [ControlEndpointDescriptor]) throws {
    var seen: Set<String> = []
    for (index, descriptor) in descriptors.enumerated() {
      let id = descriptor.id.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !id.isEmpty else {
        throw ValidationError.emptyID(index: index)
      }
      guard seen.insert(descriptor.id).inserted else {
        throw ValidationError.duplicateID(descriptor.id)
      }
      if descriptor.requiredCapability == .fixture && descriptor.availability.gui {
        throw ValidationError.fixtureAvailableInGUI(descriptor.id)
      }
      if !descriptor.classificationExplicit {
        throw ValidationError.unclassifiedDescriptor(descriptor.id)
      }

      try validateSchema(descriptor.inputSchema, id: descriptor.id, field: "input")
      try validateSchema(descriptor.outputSchema, id: descriptor.id, field: "output")
      try validateSchema(descriptor.errorSchema, id: descriptor.id, field: "error")

      if requiresJSONInput(descriptor)
        && descriptor.inputSchema == nil
        && !hasLegacyRequestSchema(for: descriptor.id, in: endpoints)
      {
        throw ValidationError.missingInputSchema(descriptor.id)
      }

      if requiresJSONOutput(descriptor)
        && descriptor.outputSchema == nil
        && !hasLegacyResponseSchema(for: descriptor.id, in: endpoints)
      {
        throw ValidationError.missingOutputSchema(descriptor.id)
      }
    }
  }

  public static let shared = IntentCatalog(
    starterDescriptors
      + legacyActionDescriptors
      + legacyQueryDescriptors
      + legacyArtifactDescriptors)

  public static let fixture = IntentCatalog(fixtureDescriptors)

  public static let all = IntentCatalog(shared.descriptors + fixture.descriptors)

  private static let stateOutputSchema: SchemaNode = .object(
    properties: [:],
    required: [],
    additionalProperties: true)

  private static let actionOutputSchema: SchemaNode = .object(
    properties: [
      "message": .string(enumValues: nil, const: nil, format: nil, pattern: nil),
      "ok": .boolean,
    ],
    required: ["ok"],
    additionalProperties: true)

  private static let errorSchema: SchemaNode = .object(
    properties: [
      "error": .string(enumValues: nil, const: nil, format: nil, pattern: nil)
    ],
    required: ["error"],
    additionalProperties: false)

  private static let emptyInputSchema: SchemaNode = .object(
    properties: [:],
    required: [],
    additionalProperties: true)

  private static let genericOutputSchema: SchemaNode = .object(
    properties: [:],
    required: [],
    additionalProperties: true)

  private static let httpTransports = IntentDescriptor.Transports(
    http: true,
    mcp: false,
    cli: false)

  private static let guiObserve = IntentDescriptor.Availability(gui: true, headless: true)
  private static let headlessOnly = IntentDescriptor.Availability(gui: false, headless: true)

  private static let starterDescriptors: [IntentDescriptor] = [
    descriptor(
      id: "app.stateSummary",
      kind: .query,
      category: "app",
      summary: "Read redacted application state safe for app-observe tokens.",
      requiredCapability: .observe,
      dataSensitivity: .nonSensitiveState,
      availability: guiObserve,
      outputSchema: stateOutputSchema),
    descriptor(
      id: "app.state",
      kind: .query,
      category: "app",
      summary: "Read current application state (session/fixture rich view).",
      requiredCapability: .observeSensitive,
      dataSensitivity: .sensitivePrivate,
      availability: guiObserve,
      outputSchema: stateOutputSchema),
    descriptor(
      id: "tab.select",
      kind: .action,
      category: "tab",
      summary: "Select an existing terminal tab.",
      requiredCapability: .navigate,
      dataSensitivity: .nonSensitiveState,
      availability: headlessOnly,
      inputSchema: TabSelectInput.jsonSchema,
      outputSchema: actionOutputSchema),
    descriptor(
      id: "terminal.typeText",
      kind: .action,
      category: "terminal",
      summary: "Type text into the selected terminal.",
      requiredCapability: .input,
      dataSensitivity: .keystrokes,
      sideEffects: .init(ptyInput: true),
      risk: .init(level: .medium, reason: "Writes caller-provided text to the terminal PTY."),
      audit: .fullInput,
      availability: headlessOnly,
      inputSchema: TypeTextInput.jsonSchema,
      outputSchema: actionOutputSchema),
    descriptor(
      id: "terminal.sendKey",
      kind: .action,
      category: "terminal",
      summary: "Send a key press to the selected terminal.",
      requiredCapability: .input,
      dataSensitivity: .keystrokes,
      sideEffects: .init(ptyInput: true),
      risk: .init(level: .medium, reason: "Writes a synthesized key press to the terminal PTY."),
      audit: .fullInput,
      availability: headlessOnly,
      inputSchema: SendKeyInput.jsonSchema,
      outputSchema: actionOutputSchema),
  ]

  private static let legacyActionDescriptors: [IntentDescriptor] = [
    descriptor(
      id: "tab.new", category: "tab", summary: "Create and select a new tab.",
      requiredCapability: .input, dataSensitivity: .nonSensitiveState,
      sideEffects: .init(lifecycle: true)),
    descriptor(
      id: "tab.close",
      category: "tab",
      summary: "Close a tab by id or the active tab.",
      requiredCapability: .input, dataSensitivity: .nonSensitiveState,
      sideEffects: .init(lifecycle: true),
      inputSchema: TabTargetActionRequest.jsonSchema),
    descriptor(
      id: "tab.title.set",
      category: "tab",
      summary: "Set a manual tab title.",
      requiredCapability: .input, dataSensitivity: .nonSensitiveState,
      inputSchema: TabTitleActionRequest.jsonSchema),
    descriptor(
      id: "tab.title.freeze",
      category: "tab",
      summary: "Freeze or unfreeze title updates.",
      requiredCapability: .input, dataSensitivity: .nonSensitiveState,
      inputSchema: TabTitleActionRequest.jsonSchema),
    descriptor(
      id: "tab.title.clear",
      category: "tab",
      summary: "Clear the manual tab title.",
      requiredCapability: .input, dataSensitivity: .nonSensitiveState,
      inputSchema: TabTargetActionRequest.jsonSchema),
    descriptor(
      id: "tab.metadata.set",
      category: "tab",
      summary: "Set tab metadata shown by debug state and journals.",
      requiredCapability: .input, dataSensitivity: .nonSensitiveState,
      inputSchema: TabMetadataActionRequest.jsonSchema),
    descriptor(
      id: "tab.move",
      category: "tab",
      summary: "Move a tab to a target index.",
      requiredCapability: .input, dataSensitivity: .nonSensitiveState,
      inputSchema: MoveTabActionRequest.jsonSchema),
    descriptor(
      id: "window.resize",
      category: "window",
      summary: "Resize the headless window surface.",
      requiredCapability: .fixture, dataSensitivity: .nonSensitiveState,
      inputSchema: ResizeWindowActionRequest.jsonSchema),
    descriptor(
      id: "app.fontSize.set",
      category: "app",
      summary: "Set the live terminal font size.",
      requiredCapability: .fixture, dataSensitivity: .nonSensitiveState,
      inputSchema: SetFontSizeActionRequest.jsonSchema),
    descriptor(
      id: "renderer.set",
      category: "rendering",
      summary: "Set the headless renderer backend.",
      requiredCapability: .fixture, dataSensitivity: .nonSensitiveState,
      inputSchema: SetRendererActionRequest.jsonSchema),
    descriptor(
      id: "vector.subpixelLayout.set",
      category: "rendering",
      summary: "Set the vector renderer subpixel layout.",
      requiredCapability: .fixture, dataSensitivity: .nonSensitiveState,
      inputSchema: VectorSubpixelLayoutActionRequest.jsonSchema),
    descriptor(
      id: "clipboard.setText",
      category: "clipboard",
      summary: "Set debug clipboard text.",
      requiredCapability: .fixture,
      dataSensitivity: .clipboard,
      inputSchema: TextActionRequest.jsonSchema),
    descriptor(
      id: "clipboard.copy",
      category: "clipboard",
      summary: "Copy the current terminal selection.",
      requiredCapability: .fixture,
      dataSensitivity: .clipboard,
      inputSchema: SessionTargetActionRequest.jsonSchema),
    descriptor(
      id: "clipboard.paste",
      category: "clipboard",
      summary: "Paste debug clipboard text into the terminal.",
      requiredCapability: .input,
      dataSensitivity: .clipboard,
      sideEffects: .init(ptyInput: true),
      inputSchema: emptyInputSchema),
    descriptor(
      id: "selection.set",
      category: "selection",
      summary: "Set terminal selection cell anchors.",
      requiredCapability: .input,
      dataSensitivity: .visibleText,
      inputSchema: SelectionActionRequest.jsonSchema),
    descriptor(
      id: "preedit.set",
      category: "input",
      summary: "Set transient IME preedit text in headless runs.",
      requiredCapability: .input,
      dataSensitivity: .visibleText,
      inputSchema: PreeditActionRequest.jsonSchema),
    descriptor(
      id: "find.start",
      category: "find",
      summary: "Start literal find in a terminal session.",
      requiredCapability: .input,
      dataSensitivity: .visibleText,
      inputSchema: FindStartRequest.jsonSchema),
    descriptor(
      id: "find.step",
      category: "find",
      summary: "Advance the selected find match.",
      requiredCapability: .input,
      dataSensitivity: .visibleText,
      inputSchema: FindStepRequest.jsonSchema),
    descriptor(
      id: "find.stop",
      category: "find",
      summary: "Stop find and clear highlights.",
      requiredCapability: .input,
      dataSensitivity: .nonSensitiveState,
      inputSchema: FindSessionRequest.jsonSchema),
    descriptor(
      id: "terminal.dropFiles",
      category: "terminal",
      summary: "Drop files into terminal content.",
      requiredCapability: .input,
      dataSensitivity: .nonSensitiveState,
      sideEffects: .init(filesystem: true),
      inputSchema: DropFilesActionRequest.jsonSchema),
    descriptor(
      id: "command.propose",
      category: "command",
      summary: "Propose a command for user review; never writes PTY bytes.",
      requiredCapability: .propose,
      dataSensitivity: .visibleText,
      availability: guiObserve,
      inputSchema: CommandProposeRequest.jsonSchema,
      outputSchema: CommandProposeResponse.jsonSchema),
    descriptor(
      id: "terminal.scrollViewport",
      category: "terminal",
      summary: "Move terminal scrollback viewport.",
      requiredCapability: .navigate,
      dataSensitivity: .nonSensitiveState,
      availability: guiObserve,
      inputSchema: ScrollViewportActionRequest.jsonSchema),
    descriptor(
      id: "terminal.mouseWheel",
      category: "terminal",
      summary: "Send a mouse wheel event.",
      requiredCapability: .input,
      dataSensitivity: .nonSensitiveState,
      sideEffects: .init(ptyInput: true),
      inputSchema: MouseWheelActionRequest.jsonSchema),
    descriptor(
      id: "terminal.mouseDrag",
      category: "terminal",
      summary: "Send a mouse press-drag-release gesture.",
      requiredCapability: .input,
      dataSensitivity: .nonSensitiveState,
      sideEffects: .init(ptyInput: true),
      inputSchema: MouseDragActionRequest.jsonSchema),
    descriptor(
      id: "terminal.click",
      category: "terminal",
      summary: "Send a click to sidebar or terminal content.",
      requiredCapability: .input,
      dataSensitivity: .nonSensitiveState,
      sideEffects: .init(ptyInput: true),
      inputSchema: ClickActionRequest.jsonSchema),
    descriptor(
      id: DebugActionIntentID.unsupported,
      category: "debug",
      summary: "Route an unknown legacy debug action to the legacy unsupported response.",
      requiredCapability: .observe,
      dataSensitivity: .none,
      availability: headlessOnly,
      inputSchema: UnsupportedDebugActionInput.jsonSchema),
  ]

  private static let legacyQueryDescriptors: [IntentDescriptor] = [
    descriptor(
      id: "debug.discovery", kind: .query, category: "discovery",
      summary: "List debug endpoints and examples.",
      requiredCapability: .observe, dataSensitivity: .none,
      availability: guiObserve),
    descriptor(
      id: "debug.capabilities", kind: .query, category: "discovery",
      summary: "Alias for debug discovery.",
      requiredCapability: .observe, dataSensitivity: .none,
      availability: guiObserve),
    descriptor(
      id: "debug.health", kind: .query, category: "readiness",
      summary: "Report debug process readiness.",
      requiredCapability: .observe, dataSensitivity: .none,
      availability: guiObserve),
    descriptor(
      id: "app.accessibility", kind: .query, category: "state",
      summary: "Return terminal accessibility projection.",
      requiredCapability: .observeSensitive, dataSensitivity: .visibleText,
      availability: guiObserve),
    descriptor(
      id: "terminal.modes", kind: .query, category: "state",
      summary: "Return active terminal mode state.",
      requiredCapability: .observe, dataSensitivity: .nonSensitiveState,
      availability: guiObserve),
    descriptor(
      id: "persistence.state", kind: .query, category: "state",
      summary: "Inspect persistence files and agent mirrors.",
      requiredCapability: .observeSensitive, dataSensitivity: .nonSensitiveState),
    descriptor(
      id: "persistence.flush", category: "persistence",
      summary: "Synchronously flush persistence writers.",
      requiredCapability: .fixture, dataSensitivity: .nonSensitiveState),
    descriptor(
      id: "persistence.relaunch", category: "persistence",
      summary: "Rebuild state from persisted workspace data.",
      requiredCapability: .fixture, dataSensitivity: .nonSensitiveState,
      sideEffects: .init(lifecycle: true)),
    descriptor(
      id: "persistence.restorePicker", kind: .query, category: "state",
      summary: "Return pending semantic restore candidates.",
      requiredCapability: .observeSensitive, dataSensitivity: .nonSensitiveState),
    descriptor(
      id: "persistence.restorePicker.select",
      category: "persistence",
      summary: "Launch selected semantic restore candidates.",
      requiredCapability: .fixture, dataSensitivity: .nonSensitiveState,
      sideEffects: .init(lifecycle: true),
      inputSchema: AgentRestoreSelectionRequest.jsonSchema),
    descriptor(
      id: "find.state", kind: .query, category: "find", summary: "Return current find state.",
      requiredCapability: .observeSensitive, dataSensitivity: .visibleText,
      availability: guiObserve),
    descriptor(
      id: "shellIntegration.state", kind: .query, category: "state",
      summary: "Return OSC 133 shell integration state.",
      requiredCapability: .observeSensitive, dataSensitivity: .nonSensitiveState,
      availability: guiObserve),
    descriptor(
      id: "scrollIndicator.state", kind: .query, category: "state",
      summary: "Return scroll indicator debug state.",
      requiredCapability: .observe, dataSensitivity: .nonSensitiveState,
      availability: guiObserve),
    descriptor(
      id: "scrollTrace", kind: .query, category: "state",
      summary: "Return scroll diagnostic events.",
      requiredCapability: .observeSensitive, dataSensitivity: .trace),
    descriptor(
      id: "wait.condition",
      kind: .wait,
      category: "control",
      summary: "Block until a debug condition is true.",
      requiredCapability: .fixture, dataSensitivity: .nonSensitiveState,
      inputSchema: WaitRequest.jsonSchema),
    descriptor(
      id: "session.list", kind: .query, category: "state", summary: "Return all terminal sessions.",
      requiredCapability: .observeSensitive, dataSensitivity: .nonSensitiveState,
      availability: guiObserve),
    descriptor(
      id: "session.detail", kind: .query, category: "state",
      summary: "Return one terminal session.",
      requiredCapability: .observeSensitive, dataSensitivity: .visibleText,
      availability: guiObserve),
    descriptor(
      id: "terminal.getText", kind: .query, category: "terminal",
      summary: "Return bounded plain-text lines from the visible screen or full scrollback.",
      requiredCapability: .observeSensitive, dataSensitivity: .scrollback,
      availability: guiObserve),
    descriptor(
      id: "render.state", kind: .query, category: "rendering",
      summary: "Return renderer state and draw stats.",
      requiredCapability: .fixture, dataSensitivity: .trace),
    descriptor(
      id: "render.frameCommands", kind: .query, category: "rendering",
      summary: "Return bounded frame commands.",
      requiredCapability: .fixture, dataSensitivity: .trace),
    descriptor(
      id: "render.trace",
      kind: .query,
      category: "rendering",
      summary: "Return render contributors, resources, passes, and probes.",
      requiredCapability: .fixture,
      dataSensitivity: .trace,
      inputSchema: RenderTraceRequest.jsonSchema),
    descriptor(
      id: "render.pixelProbe",
      kind: .query,
      category: "exploration",
      summary: "Sample exact pixels and rectangular regions.",
      requiredCapability: .fixture,
      dataSensitivity: .screenshot,
      inputSchema: PixelProbeRequest.jsonSchema),
    descriptor(
      id: "render.atlas", kind: .query, category: "rendering",
      summary: "Return font atlas diagnostics.",
      requiredCapability: .fixture, dataSensitivity: .trace),
    descriptor(
      id: "artifact.snapshot", category: "exploration",
      summary: "Write a diagnostic artifact bundle.",
      requiredCapability: .fixture, dataSensitivity: .trace,
      sideEffects: .init(filesystem: true)),
    descriptor(
      id: "log.events", kind: .query, category: "logs", summary: "Return debug events.",
      requiredCapability: .observeSensitive, dataSensitivity: .nonSensitiveState),
    descriptor(
      id: "log.tabJournal", kind: .query, category: "logs",
      summary: "Return tab state journal events.",
      requiredCapability: .observeSensitive, dataSensitivity: .nonSensitiveState),
    descriptor(
      id: "log.input", kind: .query, category: "logs",
      summary: "Return keyboard/text routing diagnostics.",
      requiredCapability: .observeSensitive, dataSensitivity: .keystrokes),
    descriptor(
      id: "log.terminal", kind: .query, category: "logs",
      summary: "Return terminal byte-flow diagnostics.",
      requiredCapability: .observeSensitive, dataSensitivity: .scrollback),
    descriptor(
      id: "log.timing", kind: .query, category: "logs",
      summary: "Return endpoint and render timing.",
      requiredCapability: .observe, dataSensitivity: .nonSensitiveState),
    descriptor(
      id: "log.metrics", kind: .query, category: "logs", summary: "Return local debug counters.",
      requiredCapability: .observe, dataSensitivity: .nonSensitiveState),
    descriptor(
      id: "log.errors", kind: .query, category: "logs",
      summary: "Return structured warnings and errors.",
      requiredCapability: .observe, dataSensitivity: .nonSensitiveState),
    descriptor(
      id: "capture.status", kind: .query, category: "capture",
      summary: "Return full capture recording status.",
      requiredCapability: .fixture, dataSensitivity: .nonSensitiveState),
    descriptor(
      id: "capture.start", category: "capture", summary: "Start full capture recording.",
      requiredCapability: .fixture, dataSensitivity: .nonSensitiveState,
      sideEffects: .init(filesystem: true), inputSchema: CaptureStartRequest.jsonSchema),
    descriptor(
      id: "capture.stop", category: "capture", summary: "Stop full capture recording.",
      requiredCapability: .fixture, dataSensitivity: .nonSensitiveState,
      sideEffects: .init(filesystem: true)),
    descriptor(
      id: "capture.snapshot", category: "capture",
      summary: "Write a snapshot inside the active capture run.",
      requiredCapability: .fixture, dataSensitivity: .nonSensitiveState,
      sideEffects: .init(filesystem: true)),
    descriptor(
      id: "selection.read", kind: .query, category: "state",
      summary: "Return current terminal selection.",
      requiredCapability: .observeSensitive, dataSensitivity: .visibleText,
      availability: guiObserve),
    descriptor(
      id: "clipboard.read", kind: .query, category: "state",
      summary: "Return debug clipboard diagnostics.",
      requiredCapability: .observeSensitive, dataSensitivity: .clipboard),
  ]

  private static let legacyArtifactDescriptors: [IntentDescriptor] = [
    descriptor(
      id: "artifact.screenshot",
      kind: .artifact,
      category: "artifacts",
      summary: "Return the current rendered surface as PNG bytes.",
      requiredCapability: .observeSensitive,
      dataSensitivity: .screenshot,
      outputSchema: nil),
    descriptor(
      id: "artifact.screenshot.write",
      category: "artifacts",
      summary: "Write a screenshot PNG under the artifact directory.",
      requiredCapability: .fixture,
      dataSensitivity: .screenshot,
      sideEffects: .init(filesystem: true)),
    descriptor(
      id: "cast.recent",
      kind: .artifact,
      category: "capture",
      summary: "Snapshot recent PTY output as an asciinema cast.",
      requiredCapability: .fixture,
      dataSensitivity: .scrollback,
      outputSchema: nil),
  ]

  private static let fixtureDescriptors: [IntentDescriptor] = [
    descriptor(
      id: "fixture.feedOutput",
      category: "fixture",
      summary: "Inject fixture terminal output bytes.",
      requiredCapability: .fixture,
      dataSensitivity: .scrollback,
      inputSchema: TextActionRequest.jsonSchema),
    descriptor(
      id: "fixture.advanceFrames",
      category: "fixture",
      summary: "Render one or more deterministic fixture frames.",
      requiredCapability: .fixture,
      dataSensitivity: .trace,
      inputSchema: AdvanceFramesActionRequest.jsonSchema),
    descriptor(
      id: "fixture.windowFocus",
      category: "fixture",
      summary: "Drive terminal focus reporting in headless runs.",
      requiredCapability: .fixture,
      dataSensitivity: .nonSensitiveState,
      inputSchema: WindowFocusActionRequest.jsonSchema),
    descriptor(
      id: "fixture.control",
      category: "fixture",
      summary: "Load, restart, or step fixture sessions.",
      requiredCapability: .fixture,
      dataSensitivity: .nonSensitiveState,
      sideEffects: .init(lifecycle: true, filesystem: true),
      inputSchema: FixtureControlRequest.jsonSchema),
  ]

  private static func descriptor(
    id: String,
    kind: IntentDescriptor.Kind = .action,
    category: String,
    summary: String,
    requiredCapability: Capability,
    dataSensitivity: DataSensitivity,
    sideEffects: IntentDescriptor.SideEffects = .init(),
    risk: IntentDescriptor.Risk = .init(level: .low, reason: "Legacy debug surface operation."),
    audit: IntentDescriptor.Audit = .metadataOnly,
    availability: IntentDescriptor.Availability? = nil,
    transports: IntentDescriptor.Transports? = nil,
    inputSchema: SchemaNode? = nil,
    outputSchema: SchemaNode? = nil,
    errorSchema: SchemaNode? = nil
  ) -> IntentDescriptor {
    IntentDescriptor(
      id: id,
      kind: kind,
      category: category,
      summary: summary,
      requiredCapability: requiredCapability,
      dataSensitivity: dataSensitivity,
      sideEffects: sideEffects,
      risk: risk,
      audit: audit,
      availability: availability ?? headlessOnly,
      transports: transports ?? httpTransports,
      inputSchema: inputSchema ?? defaultInputSchema(for: kind),
      outputSchema: outputSchema ?? defaultOutputSchema(for: kind),
      errorSchema: errorSchema ?? Self.errorSchema,
      classificationExplicit: true)
  }

  private static func defaultInputSchema(for kind: IntentDescriptor.Kind) -> SchemaNode? {
    switch kind {
    case .action, .wait:
      return emptyInputSchema
    case .query, .event, .artifact:
      return nil
    }
  }

  private static func defaultOutputSchema(for kind: IntentDescriptor.Kind) -> SchemaNode? {
    switch kind {
    case .artifact:
      return nil
    case .query, .action, .wait, .event:
      return genericOutputSchema
    }
  }

  private func validateSchema(_ schema: SchemaNode?, id: String, field: String) throws {
    guard let schema else {
      return
    }
    if schema.toJSONSchema().isEmpty {
      throw ValidationError.emptySchema(id: id, field: field)
    }
  }

  private func requiresJSONInput(_ descriptor: IntentDescriptor) -> Bool {
    switch descriptor.kind {
    case .action, .wait:
      return true
    case .query, .event, .artifact:
      return false
    }
  }

  private func requiresJSONOutput(_ descriptor: IntentDescriptor) -> Bool {
    switch descriptor.kind {
    case .artifact:
      return false
    case .query, .action, .wait, .event:
      return true
    }
  }

  private func hasLegacyRequestSchema(
    for id: String,
    in endpoints: [ControlEndpointDescriptor]
  ) -> Bool {
    endpoints.contains {
      $0.fixedIntentId == id && $0.binding.legacyRequestSchemaPath != nil
    }
  }

  private func hasLegacyResponseSchema(
    for id: String,
    in endpoints: [ControlEndpointDescriptor]
  ) -> Bool {
    endpoints.contains {
      $0.fixedIntentId == id && $0.binding.legacyResponseSchemaPath != nil
    }
  }
}
