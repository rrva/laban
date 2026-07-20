import Foundation
import LabanTerminalCore

public struct ControlProjectionContext {
  public var model: AppModel
  public var mode: String
  public var frame: Int
  public var windowWidth: Int
  public var windowHeight: Int
  public var cellWidth: Int
  public var cellHeight: Int
  public var sidebarWidth: Int
  public var accessibilityDisplayFlags: AccessibilityDisplayFlagsResponse
  public var selectionBySession: [Session.ID: TerminalSelection]
  public var sessionClientInfoById: [Session.ID: LabandSessionInfo]
  public var transportMode: String
  /// When set, whole-app reads (`app.state`, `session.list`) are filtered to this session.
  public var scopedSessionID: String?
  /// Redacts sensitive fields for app-observe callers.
  public var readRedaction: ControlReadRedaction
  public var clientSnapshotProvider: (@Sendable (Session.ID) -> LabandSnapshotResponse?)?
  public var accessibilityValueProvider: (@Sendable (Tab) -> String)?
  /// Reports the per-glyph animation channel state for `/debug/state`; nil
  /// when the serving runtime has no renderer to report (GUI control server).
  public var glyphEffectsProvider: (() -> GlyphEffectsStateResponse?)?
  /// Reports the spinner motion smoothing state for `/debug/state`; nil when
  /// the serving runtime has no renderer to report (GUI control server).
  public var spinnerMotionProvider: (() -> SpinnerMotionStateResponse?)?

  public init(
    model: AppModel,
    mode: String,
    frame: Int,
    windowWidth: Int,
    windowHeight: Int,
    cellWidth: Int,
    cellHeight: Int,
    sidebarWidth: Int,
    accessibilityDisplayFlags: AccessibilityDisplayFlagsResponse,
    selectionBySession: [Session.ID: TerminalSelection] = [:],
    sessionClientInfoById: [Session.ID: LabandSessionInfo] = [:],
    transportMode: String,
    scopedSessionID: String? = nil,
    readRedaction: ControlReadRedaction = .none,
    clientSnapshotProvider: (@Sendable (Session.ID) -> LabandSnapshotResponse?)? = nil,
    accessibilityValueProvider: (@Sendable (Tab) -> String)? = nil,
    glyphEffectsProvider: (() -> GlyphEffectsStateResponse?)? = nil,
    spinnerMotionProvider: (() -> SpinnerMotionStateResponse?)? = nil
  ) {
    self.model = model
    self.mode = mode
    self.frame = frame
    self.windowWidth = windowWidth
    self.windowHeight = windowHeight
    self.cellWidth = cellWidth
    self.cellHeight = cellHeight
    self.sidebarWidth = sidebarWidth
    self.accessibilityDisplayFlags = accessibilityDisplayFlags
    self.selectionBySession = selectionBySession
    self.sessionClientInfoById = sessionClientInfoById
    self.transportMode = transportMode
    self.scopedSessionID = scopedSessionID
    self.readRedaction = readRedaction
    self.clientSnapshotProvider = clientSnapshotProvider
    self.accessibilityValueProvider = accessibilityValueProvider
    self.glyphEffectsProvider = glyphEffectsProvider
    self.spinnerMotionProvider = spinnerMotionProvider
  }
}
