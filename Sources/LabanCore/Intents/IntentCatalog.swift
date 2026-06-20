import Foundation

public enum Capability: String, Codable, CaseIterable, Sendable {
  case observe
  case observeSensitive
  case control
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

  public var id: String {
    switch self {
    case .tabSelect:
      return "tab.select"
    case .terminalTypeText:
      return "terminal.typeText"
    case .terminalSendKey:
      return "terminal.sendKey"
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
  func artifact(_ request: ArtifactRequest) -> ControlResponse?
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
    errorSchema: SchemaNode?
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

  init(endpoint: ControlEndpointDescriptor) {
    self.endpoint = endpoint
  }
}

public struct IntentCatalog: Sendable {
  public enum ValidationError: Error, Equatable, CustomStringConvertible, Sendable {
    case emptyID(index: Int)
    case duplicateID(String)
    case fixtureAvailableInGUI(String)
    case missingInputSchema(String)
    case missingOutputSchema(String)
    case emptySchema(id: String, field: String)

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

  public static let shared = IntentCatalog([
    IntentDescriptor(
      id: "app.state",
      kind: .query,
      category: "app",
      summary: "Read current application state.",
      requiredCapability: .observe,
      dataSensitivity: .nonSensitiveState,
      sideEffects: .init(),
      risk: .init(level: .none, reason: "Read-only state snapshot."),
      audit: .metadataOnly,
      availability: .init(gui: true, headless: true),
      transports: .init(http: true, mcp: true, cli: true),
      inputSchema: nil,
      outputSchema: stateOutputSchema,
      errorSchema: errorSchema),
    IntentDescriptor(
      id: "tab.select",
      kind: .action,
      category: "tab",
      summary: "Select an existing terminal tab.",
      requiredCapability: .control,
      dataSensitivity: .nonSensitiveState,
      sideEffects: .init(),
      risk: .init(level: .low, reason: "Changes focus without writing to the terminal."),
      audit: .metadataOnly,
      availability: .init(gui: true, headless: true),
      transports: .init(http: true, mcp: true, cli: true),
      inputSchema: TabSelectInput.jsonSchema,
      outputSchema: actionOutputSchema,
      errorSchema: errorSchema),
    IntentDescriptor(
      id: "terminal.typeText",
      kind: .action,
      category: "terminal",
      summary: "Type text into the selected terminal.",
      requiredCapability: .control,
      dataSensitivity: .keystrokes,
      sideEffects: .init(ptyInput: true),
      risk: .init(level: .medium, reason: "Writes caller-provided text to the terminal PTY."),
      audit: .fullInput,
      availability: .init(gui: true, headless: true),
      transports: .init(http: true, mcp: true, cli: true),
      inputSchema: TypeTextInput.jsonSchema,
      outputSchema: actionOutputSchema,
      errorSchema: errorSchema),
    IntentDescriptor(
      id: "terminal.sendKey",
      kind: .action,
      category: "terminal",
      summary: "Send a key press to the selected terminal.",
      requiredCapability: .control,
      dataSensitivity: .keystrokes,
      sideEffects: .init(ptyInput: true),
      risk: .init(level: .medium, reason: "Writes a synthesized key press to the terminal PTY."),
      audit: .fullInput,
      availability: .init(gui: true, headless: true),
      transports: .init(http: true, mcp: true, cli: true),
      inputSchema: SendKeyInput.jsonSchema,
      outputSchema: actionOutputSchema,
      errorSchema: errorSchema),
  ])

  public static let fixture = IntentCatalog([])

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
