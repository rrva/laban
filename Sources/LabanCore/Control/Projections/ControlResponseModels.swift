import Foundation
import LabanTerminalCore

public struct RectResponse: Encodable {
  public var x: Int
  public var y: Int
  public var width: Int
  public var height: Int

  public init(x: Int, y: Int, width: Int, height: Int) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

public struct WindowResponse: Encodable {
  public var width: Int
  public var height: Int
  public var focused: Bool

  public init(width: Int, height: Int, focused: Bool) {
    self.width = width
    self.height = height
    self.focused = focused
  }
}

public struct TabResponse: Encodable {
  public var id: String
  public var index: Int
  public var title: String
  public var displayTitle: String
  public var titleSource: String
  public var terminalTitle: String?
  public var userTitle: String?
  public var titleFrozen: Bool
  public var activityState: String
  public var lastActivityAt: Date?
  public var lastOutputAt: Date?
  public var unseenOutput: Bool
  public var bellAttention: Bool
  public var attention: String
  public var exitStatus: Int?
  public var shellPhase: String
  public var lastCommandExitCode: Int?
  public var workspace: TabWorkspaceMetadata
  public var process: TabProcessMetadata
  public var agent: TabAgentMetadata
  public var progress: TabProgress?
  public var active: Bool
  public var status: String
  public var sessionId: String

  public init(
    id: String,
    index: Int,
    title: String,
    displayTitle: String,
    titleSource: String,
    terminalTitle: String?,
    userTitle: String?,
    titleFrozen: Bool,
    activityState: String,
    lastActivityAt: Date?,
    lastOutputAt: Date?,
    unseenOutput: Bool,
    bellAttention: Bool,
    attention: String,
    exitStatus: Int?,
    shellPhase: String,
    lastCommandExitCode: Int?,
    workspace: TabWorkspaceMetadata,
    process: TabProcessMetadata,
    agent: TabAgentMetadata,
    progress: TabProgress?,
    active: Bool,
    status: String,
    sessionId: String
  ) {
    self.id = id
    self.index = index
    self.title = title
    self.displayTitle = displayTitle
    self.titleSource = titleSource
    self.terminalTitle = terminalTitle
    self.userTitle = userTitle
    self.titleFrozen = titleFrozen
    self.activityState = activityState
    self.lastActivityAt = lastActivityAt
    self.lastOutputAt = lastOutputAt
    self.unseenOutput = unseenOutput
    self.bellAttention = bellAttention
    self.attention = attention
    self.exitStatus = exitStatus
    self.shellPhase = shellPhase
    self.lastCommandExitCode = lastCommandExitCode
    self.workspace = workspace
    self.process = process
    self.agent = agent
    self.progress = progress
    self.active = active
    self.status = status
    self.sessionId = sessionId
  }
}

public struct CursorSettingsResponse: Encodable {
  public var style: String
  public var blinkEnabled: Bool
  public var styleOverridden: Bool?
  public var blinkOverridden: Bool?

  public init(
    style: String,
    blinkEnabled: Bool,
    styleOverridden: Bool?,
    blinkOverridden: Bool?
  ) {
    self.style = style
    self.blinkEnabled = blinkEnabled
    self.styleOverridden = styleOverridden
    self.blinkOverridden = blinkOverridden
  }
}

public struct EmojiRenderingSettingsResponse: Encodable {
  public var mode: String
  public var effectiveMode: String

  public init(mode: String, effectiveMode: String) {
    self.mode = mode
    self.effectiveMode = effectiveMode
  }
}

public struct AttentionNotificationDecisionResponse: Encodable {
  public var id: String
  public var tabId: String
  public var source: String
  public var category: String
  public var action: String
  public var reason: String?
  public var title: String
  public var body: String
  public var dedupeKey: String
  public var createdAt: Date
  public var decidedAt: Date

  public init(
    id: String,
    tabId: String,
    source: String,
    category: String,
    action: String,
    reason: String?,
    title: String,
    body: String,
    dedupeKey: String,
    createdAt: Date,
    decidedAt: Date
  ) {
    self.id = id
    self.tabId = tabId
    self.source = source
    self.category = category
    self.action = action
    self.reason = reason
    self.title = title
    self.body = body
    self.dedupeKey = dedupeKey
    self.createdAt = createdAt
    self.decidedAt = decidedAt
  }
}

public struct GlyphEffectsStateResponse: Encodable {
  public var active: Bool
  public var liveCount: Int
  public var lastKind: Int
  /// Frames rendered while at least one effect was live — the pumping
  /// evidence counter (headless `/debug/state`; the app-side display-link
  /// wake counter arrives with the M3 `/debug/glyph-effects` endpoint).
  public var wakeCount: Int

  public init(active: Bool, liveCount: Int, lastKind: Int, wakeCount: Int) {
    self.active = active
    self.liveCount = liveCount
    self.lastKind = lastKind
    self.wakeCount = wakeCount
  }
}

public struct SpinnerMotionStateResponse: Encodable {
  public var configured: Bool
  public var effectiveRenderer: String
  public var rendererEligible: Bool
  public var reduceMotion: Bool
  public var effectiveEnabled: Bool
  public var activeTransitions: Int
  public var analyticMotionInstances: Int
  public var fallbackSnaps: Int
  public var effectKind: Int
  public var remainingSeconds: Double
  public var liveEffectFrames: Int

  public init(
    configured: Bool,
    effectiveRenderer: String,
    rendererEligible: Bool,
    reduceMotion: Bool,
    effectiveEnabled: Bool,
    activeTransitions: Int,
    analyticMotionInstances: Int,
    fallbackSnaps: Int,
    effectKind: Int,
    remainingSeconds: Double,
    liveEffectFrames: Int
  ) {
    self.configured = configured
    self.effectiveRenderer = effectiveRenderer
    self.rendererEligible = rendererEligible
    self.reduceMotion = reduceMotion
    self.effectiveEnabled = effectiveEnabled
    self.activeTransitions = activeTransitions
    self.analyticMotionInstances = analyticMotionInstances
    self.fallbackSnaps = fallbackSnaps
    self.effectKind = effectKind
    self.remainingSeconds = remainingSeconds
    self.liveEffectFrames = liveEffectFrames
  }
}

public struct StateResponse: Encodable {
  public var mode: String
  public var frame: Int
  public var window: WindowResponse
  public var tabs: [TabResponse]
  public var activeTabId: String?
  public var activeSessionId: String?
  public var findStateBySession: [String: FindStateResponse]
  public var cursorSettings: CursorSettingsResponse
  public var emojiRendering: EmojiRenderingSettingsResponse
  public var attentionNotifications: [AttentionNotificationDecisionResponse]
  /// Per-glyph animation channel state (nil when the serving runtime has no
  /// renderer to report — e.g. the GUI control server).
  public var glyphEffects: GlyphEffectsStateResponse?
  public var spinnerMotion: SpinnerMotionStateResponse?

  public init(
    mode: String,
    frame: Int,
    window: WindowResponse,
    tabs: [TabResponse],
    activeTabId: String?,
    activeSessionId: String?,
    findStateBySession: [String: FindStateResponse],
    cursorSettings: CursorSettingsResponse,
    emojiRendering: EmojiRenderingSettingsResponse,
    attentionNotifications: [AttentionNotificationDecisionResponse],
    glyphEffects: GlyphEffectsStateResponse? = nil,
    spinnerMotion: SpinnerMotionStateResponse? = nil
  ) {
    self.mode = mode
    self.frame = frame
    self.window = window
    self.tabs = tabs
    self.activeTabId = activeTabId
    self.activeSessionId = activeSessionId
    self.findStateBySession = findStateBySession
    self.cursorSettings = cursorSettings
    self.emojiRendering = emojiRendering
    self.attentionNotifications = attentionNotifications
    self.glyphEffects = glyphEffects
    self.spinnerMotion = spinnerMotion
  }
}

public struct AccessibilityDisplayFlagsResponse: Encodable {
  public var increaseContrast: Bool
  public var differentiateWithoutColor: Bool
  public var reduceTransparency: Bool
  public var reduceMotion: Bool

  public init(
    increaseContrast: Bool,
    differentiateWithoutColor: Bool,
    reduceTransparency: Bool,
    reduceMotion: Bool = false
  ) {
    self.increaseContrast = increaseContrast
    self.differentiateWithoutColor = differentiateWithoutColor
    self.reduceTransparency = reduceTransparency
    self.reduceMotion = reduceMotion
  }
}

public struct AccessibilityResponse: Encodable {
  public var isElement: Bool
  public var role: String
  public var label: String
  public var value: String
  public var focusRingType: String
  public var display: AccessibilityDisplayFlagsResponse

  public init(
    isElement: Bool,
    role: String,
    label: String,
    value: String,
    focusRingType: String,
    display: AccessibilityDisplayFlagsResponse
  ) {
    self.isElement = isElement
    self.role = role
    self.label = label
    self.value = value
    self.focusRingType = focusRingType
    self.display = display
  }
}

public struct TerminalModesResponse: Encodable {
  public var graphemeCluster2027: Bool
  public var synchronizedOutput: Bool
  public var focusReporting: Bool
  public var mouseTracking: Bool

  public enum CodingKeys: String, CodingKey {
    case graphemeCluster2027 = "grapheme_cluster_2027"
    case synchronizedOutput = "synchronized_output"
    case focusReporting = "focus_reporting"
    case mouseTracking = "mouse_tracking"
  }

  public init(
    graphemeCluster2027: Bool,
    synchronizedOutput: Bool,
    focusReporting: Bool,
    mouseTracking: Bool
  ) {
    self.graphemeCluster2027 = graphemeCluster2027
    self.synchronizedOutput = synchronizedOutput
    self.focusReporting = focusReporting
    self.mouseTracking = mouseTracking
  }
}

public struct ActionResult: Encodable {
  public var ok: Bool
  public var frame: Int
  public var activeTabId: String?
  public var activeSessionId: String?
  public var error: String?

  public init(
    ok: Bool,
    frame: Int,
    activeTabId: String?,
    activeSessionId: String?,
    error: String?
  ) {
    self.ok = ok
    self.frame = frame
    self.activeTabId = activeTabId
    self.activeSessionId = activeSessionId
    self.error = error
  }
}

public struct HealthResponse: Encodable {
  public var ok: Bool
  public var mode: String
  public var frame: Int
  public var focused: Bool

  public init(ok: Bool, mode: String, frame: Int, focused: Bool) {
    self.ok = ok
    self.mode = mode
    self.frame = frame
    self.focused = focused
  }
}

public struct DebugDiscoveryEndpoint: Encodable {
  public var method: String
  public var path: String
  public var category: String
  public var summary: String
  public var queryParameters: [String]
  public var requestSchema: String?
  public var responseSchema: String?

  public init(
    method: String,
    path: String,
    category: String,
    summary: String,
    queryParameters: [String],
    requestSchema: String? = nil,
    responseSchema: String? = nil
  ) {
    self.method = method
    self.path = path
    self.category = category
    self.summary = summary
    self.queryParameters = queryParameters
    self.requestSchema = requestSchema
    self.responseSchema = responseSchema
  }
}

public struct DebugDiscoveryControl: Encodable {
  public var name: String
  public var summary: String

  public init(name: String, summary: String) {
    self.name = name
    self.summary = summary
  }
}

public struct DebugDiscoveryExample: Encodable {
  public var title: String
  public var command: String

  public init(title: String, command: String) {
    self.title = title
    self.command = command
  }
}

public struct DebugDiscoveryResponse: Encodable {
  public var name: String
  public var schema: String
  public var runId: String
  public var mode: String
  public var frame: Int
  public var artifactRoot: String
  public var fixtureRoot: String
  public var entrypoints: [String]
  public var endpoints: [DebugDiscoveryEndpoint]
  public var actions: [DebugDiscoveryControl]
  public var waitConditions: [DebugDiscoveryControl]
  public var fixtureActions: [DebugDiscoveryControl]
  public var examples: [DebugDiscoveryExample]

  public init(
    name: String,
    schema: String,
    runId: String,
    mode: String,
    frame: Int,
    artifactRoot: String,
    fixtureRoot: String,
    entrypoints: [String],
    endpoints: [DebugDiscoveryEndpoint],
    actions: [DebugDiscoveryControl],
    waitConditions: [DebugDiscoveryControl],
    fixtureActions: [DebugDiscoveryControl],
    examples: [DebugDiscoveryExample]
  ) {
    self.name = name
    self.schema = schema
    self.runId = runId
    self.mode = mode
    self.frame = frame
    self.artifactRoot = artifactRoot
    self.fixtureRoot = fixtureRoot
    self.entrypoints = entrypoints
    self.endpoints = endpoints
    self.actions = actions
    self.waitConditions = waitConditions
    self.fixtureActions = fixtureActions
    self.examples = examples
  }
}

public struct FindMatchResponse: Encodable {
  public var row: Int
  public var startColumn: Int
  public var endColumn: Int

  public init(row: Int, startColumn: Int, endColumn: Int) {
    self.row = row
    self.startColumn = startColumn
    self.endColumn = endColumn
  }
}

public struct FindStateResponse: Encodable {
  public var isActive: Bool
  public var needle: String
  public var total: Int
  public var selectedIndex: Int?
  public var matches: [FindMatchResponse]
  public var viewportScrollOffsetAtStart: Int?

  public init(
    isActive: Bool,
    needle: String,
    total: Int,
    selectedIndex: Int?,
    matches: [FindMatchResponse],
    viewportScrollOffsetAtStart: Int?
  ) {
    self.isActive = isActive
    self.needle = needle
    self.total = total
    self.selectedIndex = selectedIndex
    self.matches = matches
    self.viewportScrollOffsetAtStart = viewportScrollOffsetAtStart
  }
}

public struct ShellIntegrationStateResponse: Encodable {
  public var sessionId: String
  public var phase: String
  public var lastExitCode: Int?
  /// Monotonic count of commands that have finished (OSC 133 D) this
  /// session. `laban wait command-finished` polls this field and exits once
  /// it increments past the value observed at the start of the wait.
  public var completedCommandCount: Int

  public init(
    sessionId: String,
    phase: String,
    lastExitCode: Int?,
    completedCommandCount: Int
  ) {
    self.sessionId = sessionId
    self.phase = phase
    self.lastExitCode = lastExitCode
    self.completedCommandCount = completedCommandCount
  }
}

public struct TerminalGetTextResponse: Encodable {
  public var ok: Bool
  public var sessionId: String
  public var source: String
  public var lines: [String]
  public var truncated: Bool
  public var totalAvailable: Int

  public init(
    ok: Bool,
    sessionId: String,
    source: String,
    lines: [String],
    truncated: Bool,
    totalAvailable: Int
  ) {
    self.ok = ok
    self.sessionId = sessionId
    self.source = source
    self.lines = lines
    self.truncated = truncated
    self.totalAvailable = totalAvailable
  }
}

public struct ScrollIndicatorStateResponse: Encodable {
  public var available: Bool
  public var input: TerminalScrollIndicator.Input?
  public var output: TerminalScrollIndicator.Output?

  public init(
    available: Bool,
    input: TerminalScrollIndicator.Input?,
    output: TerminalScrollIndicator.Output?
  ) {
    self.available = available
    self.input = input
    self.output = output
  }
}

public struct SessionResponse: Encodable {
  public var id: String
  public var tabId: String
  public var pid: Int?
  public var foregroundPid: Int?
  public var daemonProcessPid: Int?
  public var logicalSessionId: String?
  public var incarnationId: String?
  public var attachedClientCount: Int?
  public var leaseHolder: String?
  public var leaseId: String?
  public var leaseEpoch: UInt64?
  public var leaseExpiresAtMonoNs: UInt64?
  public var transportMode: String
  public var status: String
  public var exitStatus: Int?
  public var rows: Int
  public var cols: Int
  public var cellWidth: Int
  public var cellHeight: Int
  public var scrollbackLines: Int
  public var viewportOffset: Int
  public var title: String
  public var displayTitle: String
  public var titleSource: String
  public var terminalTitle: String?
  public var userTitle: String?
  public var titleFrozen: Bool
  public var activityState: String
  public var lastActivityAt: Date?
  public var lastOutputAt: Date?
  public var unseenOutput: Bool
  public var bellAttention: Bool
  public var workspace: TabWorkspaceMetadata
  public var process: TabProcessMetadata
  public var agent: TabAgentMetadata
  public var mouseTracking: Bool
  public var focusReporting: Bool
  public var dirty: Bool
  public var grid: SessionGridResponse?

  public init(
    id: String,
    tabId: String,
    pid: Int?,
    foregroundPid: Int?,
    daemonProcessPid: Int?,
    logicalSessionId: String?,
    incarnationId: String?,
    attachedClientCount: Int?,
    leaseHolder: String?,
    leaseId: String?,
    leaseEpoch: UInt64?,
    leaseExpiresAtMonoNs: UInt64?,
    transportMode: String,
    status: String,
    exitStatus: Int?,
    rows: Int,
    cols: Int,
    cellWidth: Int,
    cellHeight: Int,
    scrollbackLines: Int,
    viewportOffset: Int,
    title: String,
    displayTitle: String,
    titleSource: String,
    terminalTitle: String?,
    userTitle: String?,
    titleFrozen: Bool,
    activityState: String,
    lastActivityAt: Date?,
    lastOutputAt: Date?,
    unseenOutput: Bool,
    bellAttention: Bool,
    workspace: TabWorkspaceMetadata,
    process: TabProcessMetadata,
    agent: TabAgentMetadata,
    mouseTracking: Bool,
    focusReporting: Bool,
    dirty: Bool,
    grid: SessionGridResponse?
  ) {
    self.id = id
    self.tabId = tabId
    self.pid = pid
    self.foregroundPid = foregroundPid
    self.daemonProcessPid = daemonProcessPid
    self.logicalSessionId = logicalSessionId
    self.incarnationId = incarnationId
    self.attachedClientCount = attachedClientCount
    self.leaseHolder = leaseHolder
    self.leaseId = leaseId
    self.leaseEpoch = leaseEpoch
    self.leaseExpiresAtMonoNs = leaseExpiresAtMonoNs
    self.transportMode = transportMode
    self.status = status
    self.exitStatus = exitStatus
    self.rows = rows
    self.cols = cols
    self.cellWidth = cellWidth
    self.cellHeight = cellHeight
    self.scrollbackLines = scrollbackLines
    self.viewportOffset = viewportOffset
    self.title = title
    self.displayTitle = displayTitle
    self.titleSource = titleSource
    self.terminalTitle = terminalTitle
    self.userTitle = userTitle
    self.titleFrozen = titleFrozen
    self.activityState = activityState
    self.lastActivityAt = lastActivityAt
    self.lastOutputAt = lastOutputAt
    self.unseenOutput = unseenOutput
    self.bellAttention = bellAttention
    self.workspace = workspace
    self.process = process
    self.agent = agent
    self.mouseTracking = mouseTracking
    self.focusReporting = focusReporting
    self.dirty = dirty
    self.grid = grid
  }
}

public struct SessionsResponse: Encodable {
  public var sessions: [SessionResponse]

  public init(sessions: [SessionResponse]) {
    self.sessions = sessions
  }
}

public struct SessionGridCellResponse: Encodable {
  public var row: Int
  public var col: Int
  public var text: String
  public var foreground: [Int]
  public var background: [Int]
  public var attributes: [String]
  public var wide: String
  public var hyperlink: String?

  public init(
    row: Int,
    col: Int,
    text: String,
    foreground: [Int],
    background: [Int],
    attributes: [String],
    wide: String,
    hyperlink: String?
  ) {
    self.row = row
    self.col = col
    self.text = text
    self.foreground = foreground
    self.background = background
    self.attributes = attributes
    self.wide = wide
    self.hyperlink = hyperlink
  }
}

public struct SessionGridResponse: Encodable {
  public var rows: Int
  public var cols: Int
  public var cells: [SessionGridCellResponse]
  public var truncated: Bool

  public init(rows: Int, cols: Int, cells: [SessionGridCellResponse], truncated: Bool) {
    self.rows = rows
    self.cols = cols
    self.cells = cells
    self.truncated = truncated
  }
}

public struct CellCoordResponse: Encodable {
  public var row: Int
  public var col: Int

  public init(row: Int, col: Int) {
    self.row = row
    self.col = col
  }
}

public struct SelectionResponse: Encodable {
  public var active: Bool
  public var sessionId: String?
  public var anchor: CellCoordResponse?
  public var focus: CellCoordResponse?
  public var rects: [RectResponse]
  public var text: String

  public init(
    active: Bool,
    sessionId: String?,
    anchor: CellCoordResponse?,
    focus: CellCoordResponse?,
    rects: [RectResponse],
    text: String
  ) {
    self.active = active
    self.sessionId = sessionId
    self.anchor = anchor
    self.focus = focus
    self.rects = rects
    self.text = text
  }
}
