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

/// The readiness JSON `laban-agent --debug-server` prints. Relocated to
/// `LabanCore.ControlReadiness` so `LabanControl` can return it from
/// `LabanCore.ControlReadiness` so `LabanControl` can return it from
/// `start(socketPath:)`; this alias keeps existing `LabanDebug` references
/// (and the byte-identical field names/encoder) intact.
public typealias DebugReadiness = ControlReadiness

// MARK: - JSON helpers

func jsonEncode<T: Encodable>(_ value: T, status: Int = 200) -> DebugResponse {
  let encoded = controlJSONEncode(value, status: status)
  return DebugResponse(status: encoded.status, body: encoded.body)
}

func jsonError(_ message: String, status: Int = 400) -> DebugResponse {
  let encoded = controlJSONError(message, status: status)
  return DebugResponse(status: encoded.status, body: encoded.body)
}

// MARK: - Response models (relocated observe DTOs typealias LabanCore)

typealias RectResponse = LabanCore.RectResponse
typealias WindowResponse = LabanCore.WindowResponse
typealias TabResponse = LabanCore.TabResponse
typealias CursorSettingsResponse = LabanCore.CursorSettingsResponse
typealias EmojiRenderingSettingsResponse = LabanCore.EmojiRenderingSettingsResponse
typealias AttentionNotificationDecisionResponse = LabanCore.AttentionNotificationDecisionResponse
typealias StateResponse = LabanCore.StateResponse
typealias AccessibilityDisplayFlagsResponse = LabanCore.AccessibilityDisplayFlagsResponse
typealias AccessibilityResponse = LabanCore.AccessibilityResponse
typealias TerminalModesResponse = LabanCore.TerminalModesResponse
typealias ActionResult = LabanCore.ActionResult
typealias FindMatchResponse = LabanCore.FindMatchResponse
typealias FindStateResponse = LabanCore.FindStateResponse
typealias ShellIntegrationStateResponse = LabanCore.ShellIntegrationStateResponse
typealias SessionResponse = LabanCore.SessionResponse
typealias SessionsResponse = LabanCore.SessionsResponse
typealias SessionGridCellResponse = LabanCore.SessionGridCellResponse
typealias SessionGridResponse = LabanCore.SessionGridResponse
typealias CellCoordResponse = LabanCore.CellCoordResponse
typealias SelectionResponse = LabanCore.SelectionResponse
typealias ScrollIndicatorStateResponse = LabanCore.ScrollIndicatorStateResponse
public typealias HealthResponse = LabanCore.HealthResponse
public typealias DebugDiscoveryEndpoint = LabanCore.DebugDiscoveryEndpoint
public typealias DebugDiscoveryControl = LabanCore.DebugDiscoveryControl
public typealias DebugDiscoveryExample = LabanCore.DebugDiscoveryExample
public typealias DebugDiscoveryResponse = LabanCore.DebugDiscoveryResponse

struct SurfaceResponse: Encodable {
  var width: Int
  var height: Int
  var scale: Double
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
  var configuredRenderer: String?
  var effectiveRenderer: String?
  var fallbackReason: String?
  var rasterFallbackGlyphs: Int?
  var vectorSubpixelLayout: String?
  var vectorSubpixelFallbackReason: String?
  var surface: SurfaceResponse
  var terminalViewport: RectResponse
  var cell: CellSizeResponse
  var damage: [RectResponse]
  var lastDraw: DrawStatsResponse
  var emojiRendering: EmojiRenderingSettingsResponse
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

struct AtlasCJKFontResponse: Encodable {
  var preference: String
  var font: String
  var family: String
  var source: String
  var candidates: [String]
  var fallbackOrder: [String]
  var glyphAvailable: Bool
  var glyphAdvance: Double
  var targetCellWidth: Double
  var scaleX: Double
}

struct AtlasResponse: Encodable {
  var font: String
  var fontSize: Double
  var cell: AtlasCellResponse
  var cjkFont: AtlasCJKFontResponse
  var glyphs: AtlasGlyphsResponse
  var missingCodepoints: [String]
  var atlases: [AtlasTextureResponse]
  var backend: String
  var emojiRendering: EmojiRenderingSettingsResponse
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

// MARK: - Clipboard response types

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

typealias PixelProbePointRequest = LabanCore.PixelProbePointRequest
typealias PixelProbeRegionRequest = LabanCore.PixelProbeRegionRequest
typealias PixelProbeRequest = LabanCore.PixelProbeRequest

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

typealias FixtureControlRequest = LabanCore.FixtureControlRequest

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
