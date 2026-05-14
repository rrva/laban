import Foundation
import LabanCore

// MARK: - Core types

public struct DebugResponse {
  public var status: Int
  public var body: Data

  public init(status: Int = 200, body: Data) {
    self.status = status
    self.body = body
  }
}

public enum DebugServerError: Error {
  case nonLoopbackHost
  case socketFailed
  case bindFailed
  case listenFailed
  case encodingFailed
}

public enum HeadlessSessionMode: String, Sendable {
  case fixture
  case realShell
}

public struct DebugServerAddress: Equatable {
  public var host: String
  public var port: UInt16

  public static func parse(_ s: String) throws -> DebugServerAddress {
    let parts = s.components(separatedBy: ":")
    guard parts.count == 2, let port = UInt16(parts[1]) else {
      throw DebugServerError.bindFailed
    }
    let host = parts[0]
    guard host == "127.0.0.1" || host == "localhost" else {
      throw DebugServerError.nonLoopbackHost
    }
    return DebugServerAddress(host: host, port: port)
  }
}

public struct DebugReadiness: Encodable {
  public var debugServer: String
  public var debugToken: String
  public var pid: Int32
  public var runId: String
}

// MARK: - JSON helpers

func jsonEncode<T: Encodable>(_ value: T, status: Int = 200) -> DebugResponse {
  let enc = JSONEncoder()
  enc.dateEncodingStrategy = .iso8601
  enc.outputFormatting = .sortedKeys
  guard let data = try? enc.encode(value) else {
    return DebugResponse(
      status: 500, body: #"{"error":"encoding failed"}"#.data(using: .utf8)!)
  }
  return DebugResponse(status: status, body: data)
}

func jsonError(_ message: String, status: Int = 400) -> DebugResponse {
  let escaped =
    message
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
  let body = "{\"error\":\"\(escaped)\"}"
  return DebugResponse(status: status, body: body.data(using: .utf8)!)
}

// MARK: - Response models

struct HealthResponse: Encodable {
  var ok: Bool
  var mode: String
  var frame: Int
  var focused: Bool
}

struct RectResponse: Encodable {
  var x: Int
  var y: Int
  var width: Int
  var height: Int
}

struct SurfaceResponse: Encodable {
  var width: Int
  var height: Int
  var scale: Double
}

struct WindowResponse: Encodable {
  var width: Int
  var height: Int
  var focused: Bool
}

struct TabResponse: Encodable {
  var id: String
  var index: Int
  var title: String
  var displayTitle: String
  var titleSource: String
  var terminalTitle: String?
  var userTitle: String?
  var titleFrozen: Bool
  var activityState: String
  var lastActivityAt: Date?
  var lastOutputAt: Date?
  var unseenOutput: Bool
  var exitStatus: Int?
  var workspace: TabWorkspaceMetadata
  var process: TabProcessMetadata
  var agent: TabAgentMetadata
  var active: Bool
  var status: String
  var sessionId: String
}

struct StateResponse: Encodable {
  var mode: String
  var frame: Int
  var window: WindowResponse
  var tabs: [TabResponse]
  var activeTabId: String?
  var activeSessionId: String?
  var findStateBySession: [String: FindStateResponse]
}

struct ActionResult: Encodable {
  var ok: Bool
  var frame: Int
  var activeTabId: String?
  var activeSessionId: String?
  var error: String?
}

struct FindMatchResponse: Encodable {
  var row: Int
  var startColumn: Int
  var endColumn: Int
}

struct FindStateResponse: Encodable {
  var isActive: Bool
  var needle: String
  var total: Int
  var selectedIndex: Int?
  var matches: [FindMatchResponse]
  var viewportScrollOffsetAtStart: Int?
}

struct FindStopResponse: Encodable {
  var stopped: Bool
}

struct MouseActionResult: Encodable {
  var ok: Bool
  var frame: Int
  var activeTabId: String?
  var activeSessionId: String?
  var mouseTracking: Bool
  var sent: Bool
  var error: String?
}

struct ScreenshotResult: Encodable {
  var path: String
  var width: Int
  var height: Int
  var frame: Int
  var target: String
}

struct SessionResponse: Encodable {
  var id: String
  var tabId: String
  var pid: Int?
  var status: String
  var exitStatus: Int?
  var rows: Int
  var cols: Int
  var cellWidth: Int
  var cellHeight: Int
  var scrollbackLines: Int
  var viewportOffset: Int
  var title: String
  var displayTitle: String
  var titleSource: String
  var terminalTitle: String?
  var userTitle: String?
  var titleFrozen: Bool
  var activityState: String
  var lastActivityAt: Date?
  var lastOutputAt: Date?
  var unseenOutput: Bool
  var workspace: TabWorkspaceMetadata
  var process: TabProcessMetadata
  var agent: TabAgentMetadata
  var mouseTracking: Bool
  var focusReporting: Bool
  var dirty: Bool
  var grid: SessionGridResponse?
}

struct SessionsResponse: Encodable {
  var sessions: [SessionResponse]
}

struct SessionGridCellResponse: Encodable {
  var row: Int
  var col: Int
  var text: String
  var foreground: [Int]
  var background: [Int]
  var attributes: [String]
  var wide: String
  var hyperlink: String?
}

struct SessionGridResponse: Encodable {
  var rows: Int
  var cols: Int
  var cells: [SessionGridCellResponse]
  var truncated: Bool
}

struct CellSizeResponse: Encodable {
  var width: Int
  var height: Int
}

struct DrawStatsResponse: Encodable {
  var cells: Int
  var glyphs: Int
  var backgroundRects: Int
  var images: Int
  var cursor: Bool
}

struct RenderResponse: Encodable {
  var frame: Int
  var backend: String
  var surface: SurfaceResponse
  var terminalViewport: RectResponse
  var cell: CellSizeResponse
  var damage: [RectResponse]
  var lastDraw: DrawStatsResponse
}

struct AtlasCellResponse: Encodable {
  var width: Int
  var height: Int
  var baseline: Int
}

struct AtlasGlyphsResponse: Encodable {
  var loaded: Int
  var missing: Int
}

struct AtlasTextureResponse: Encodable {
  var id: String
  var width: Int
  var height: Int
  var occupancy: Double
}

struct AtlasResponse: Encodable {
  var font: String
  var fontSize: Double
  var cell: AtlasCellResponse
  var glyphs: AtlasGlyphsResponse
  var missingCodepoints: [String]
  var atlases: [AtlasTextureResponse]
  var backend: String
}

struct FrameCommandResponse: Encodable {
  var id: String
  var index: Int
  var kind: String
  var source: String
  var rect: RectResponse?
  var color: [Int]?
  var foreground: [Int]?
  var background: [Int]?
  var text: String?
  var resourceId: String?
  var attributes: [String]?
  var underlineStyle: String?
  var underlineColor: [Int]?
  var hyperlink: String?
}

struct FrameCommandsResponse: Encodable {
  var frame: Int
  var backend: String
  var commands: [FrameCommandResponse]
  var truncated: Bool
}

struct EventResponse: Encodable {
  var seq: Int
  var kind: String
  var tabId: String?
  var sessionId: String?
  var frame: Int?
  var width: Int?
  var height: Int?
  var text: String?
  var path: String?
  var action: String?
  var deltaRows: Int?
  var error: String?
}

struct EventsResponse: Encodable {
  var events: [EventResponse]
  var next: Int
}

struct WaitResult: Encodable {
  var ok: Bool
  var frame: Int
  var elapsedMs: Double
  var error: String?
}

// MARK: - Discovery response

struct DebugDiscoveryEndpoint: Encodable {
  var method: String
  var path: String
  var category: String
  var summary: String
  var queryParameters: [String]
  var requestSchema: String?
  var responseSchema: String?
}

struct DebugDiscoveryControl: Encodable {
  var name: String
  var summary: String
}

struct DebugDiscoveryExample: Encodable {
  var title: String
  var command: String
}

struct DebugDiscoveryResponse: Encodable {
  var name: String
  var schema: String
  var runId: String
  var mode: String
  var frame: Int
  var artifactRoot: String
  var fixtureRoot: String
  var entrypoints: [String]
  var endpoints: [DebugDiscoveryEndpoint]
  var actions: [DebugDiscoveryControl]
  var waitConditions: [DebugDiscoveryControl]
  var fixtureActions: [DebugDiscoveryControl]
  var examples: [DebugDiscoveryExample]
}

// MARK: - Render trace response types

struct TraceSourceResponse: Encodable {
  var id: String
  var kind: String
  var revision: Int?
  var sessionId: String?
  var rows: Int?
  var cols: Int?
}

struct TraceLayoutItem: Encodable {
  var id: String
  var kind: String
  var rect: RectResponse
  var sourceRefs: [String]?
}

struct TracePacket: Encodable {
  var id: String
  var producer: String
  var sourceRefs: [String]
  var dirtyRows: [Int]?
  var glyphRuns: Int?
  var backgroundRuns: Int?
}

struct TraceCommandRange: Encodable {
  var producer: String
  var inputRefs: [String]
  var firstCommandId: String
  var lastCommandId: String
}

struct TraceCommand: Encodable {
  var id: String
  var index: Int
  var kind: String
  var source: String
  var rect: RectResponse?
  var text: String?
  var sourceRefs: [String]?
  var attributes: [String]?
}

struct TraceResource: Encodable {
  var id: String
  var kind: String
  var status: String
  var width: Int?
  var height: Int?
}

struct TraceDraw: Encodable {
  var id: String
  var kind: String
  var commandRefs: [String]
  var clip: RectResponse?
  var drawRect: RectResponse?
}

struct TraceRenderPass: Encodable {
  var id: String
  var target: String
  var draws: [TraceDraw]
}

struct TraceContributor: Encodable {
  var passId: String
  var drawId: String
  var commandId: String
}

struct TracePixelProbe: Encodable {
  var name: String?
  var x: Int
  var y: Int
  var rgba: [Int]
  var contributors: [TraceContributor]
}

struct TraceInvariant: Encodable {
  var level: String
  var kind: String
  var message: String
}

struct RenderTraceResponse: Encodable {
  var traceId: String
  var frame: Int
  var backend: String
  var surface: SurfaceResponse
  var sources: [TraceSourceResponse]
  var layout: [TraceLayoutItem]
  var packets: [TracePacket]
  var commandRanges: [TraceCommandRange]
  var commands: [TraceCommand]
  var resources: [TraceResource]
  var passes: [TraceRenderPass]
  var pixelProbes: [TracePixelProbe]
  var invariants: [TraceInvariant]
  var truncated: Bool
}

// MARK: - Selection and clipboard response types

struct CellCoordResponse: Encodable {
  var row: Int
  var col: Int
}

struct SelectionResponse: Encodable {
  var active: Bool
  var sessionId: String?
  var anchor: CellCoordResponse?
  var focus: CellCoordResponse?
  var rects: [RectResponse]
  var text: String
}

struct ClipboardResponse: Encodable {
  var lastCopyText: String?
  var lastPasteText: String?
  var lastPasteUsedBracketedPaste: Bool?
  var lastPasteIgnoredNonText: Bool?

  // Encode nil optional fields as JSON null (schema requires all keys present).
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(lastCopyText, forKey: .lastCopyText)
    try c.encode(lastPasteText, forKey: .lastPasteText)
    try c.encode(lastPasteUsedBracketedPaste, forKey: .lastPasteUsedBracketedPaste)
    try c.encode(lastPasteIgnoredNonText, forKey: .lastPasteIgnoredNonText)
  }

  private enum CodingKeys: String, CodingKey {
    case lastCopyText, lastPasteText, lastPasteUsedBracketedPaste, lastPasteIgnoredNonText
  }
}

// MARK: - Input log projection

struct InputLogResponse: Encodable {
  var events: [InputEventEnvelope]
  var next: Int
}

// MARK: - Exploratory diagnostics

struct PixelProbePointRequest: Decodable {
  var x: Int
  var y: Int
}

struct PixelProbeRegionRequest: Decodable {
  var name: String
  var x: Int
  var y: Int
  var width: Int
  var height: Int
}

struct PixelProbeRequest: Decodable {
  var points: [PixelProbePointRequest]?
  var regions: [PixelProbeRegionRequest]?
}

struct PixelProbePointResult: Encodable {
  var x: Int
  var y: Int
  var rgba: [Int]
}

struct PixelProbeRegionResult: Encodable {
  var name: String
  var averageRgba: [Int]
  var nonBackgroundPixels: Int
  var sampledPixels: Int
}

struct PixelProbeResponse: Encodable {
  var frame: Int
  var points: [PixelProbePointResult]
  var regions: [PixelProbeRegionResult]
}

struct TerminalLogEntryResponse: Encodable {
  var seq: Int
  var direction: String
  var escaped: String
  var sessionId: String?
  var frame: Int?
}

struct TerminalLogResponse: Encodable {
  var sessionId: String
  var events: [TerminalLogEntryResponse]
  var next: Int
  var truncated: Bool
}

struct TimingResponse: Encodable {
  var frame: Int
  var lastFrameMs: Double
  var terminalPollMs: Double
  var snapshotMs: Double
  var commandExtractionMs: Double
  var renderMs: Double
  var screenshotMs: Double
}

struct MetricsCountersResponse: Encodable {
  var framesRendered: Int
  var events: Int
  var inputEvents: Int
  var terminalLogEvents: Int
  var errors: Int
  var screenshots: Int
  var tabs: Int
  var sessions: Int
}

struct TerminalByteMetricsResponse: Encodable {
  var input: Int
  var output: Int
  var terminalResponse: Int
}

struct LastFrameMetricsResponse: Encodable {
  var commands: Int
  var cells: Int
  var glyphs: Int
  var backgroundRects: Int
  var images: Int
  var cursor: Bool
  var lastFrameMs: Double
  var terminalPollMs: Double
  var snapshotMs: Double
  var commandExtractionMs: Double
  var renderMs: Double
}

struct MetricsResponse: Encodable {
  var runId: String
  var mode: String
  var frame: Int
  var uptimeMs: Double
  var counters: MetricsCountersResponse
  var terminalBytes: TerminalByteMetricsResponse
  var lastFrame: LastFrameMetricsResponse
}

struct DebugErrorEntryResponse: Encodable {
  var seq: Int
  var level: String
  var kind: String
  var message: String
  var sessionId: String?
  var tabId: String?
}

struct DebugErrorsResponse: Encodable {
  var errors: [DebugErrorEntryResponse]
  var next: Int
}

struct FixtureControlRequest: Decodable {
  var action: String
  var path: String?
  var count: Int?
}

struct FixtureControlResponse: Encodable {
  var ok: Bool
  var action: String
  var frame: Int
  var fixtureName: String?
  var fixturePath: String?
  var stepIndex: Int
  var stepCount: Int
  var activeTabId: String?
  var activeSessionId: String?
  var error: String?
}

struct ArtifactSnapshotFile: Encodable {
  var name: String
  var path: String
}

struct ArtifactSnapshotManifest: Encodable {
  var kind: String
  var runId: String
  var frame: Int
  var createdAt: Date
  var files: [ArtifactSnapshotFile]
}

struct SnapshotResultResponse: Encodable {
  var path: String
  var frame: Int
}
