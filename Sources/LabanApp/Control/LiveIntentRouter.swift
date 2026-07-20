import AppKit
import Foundation
import LabanControl
import LabanCore
import LabanTerminalCore

/// Live GUI hooks for building shared control projections from AppModel.
struct LiveControlEnvironment {
  var cellWidth: Int
  var cellHeight: Int
  var sidebarWidth: Int
  var frame: Int
  var windowWidth: Int
  var windowHeight: Int
  var transportMode: String
  var accessibilityDisplayFlags: AccessibilityDisplayFlagsResponse
  var selectionProvider: (Session.ID) -> TerminalSelection?
  var accessibilityValueProvider: (Tab) -> String
  var sessionClientInfoById: [Session.ID: LabandSessionInfo]

  static func `default`(model: AppModel) -> LiveControlEnvironment {
    LiveControlEnvironment(
      cellWidth: 10,
      cellHeight: 20,
      sidebarWidth: 200,
      frame: 0,
      windowWidth: 1200,
      windowHeight: 800,
      transportMode: "inProcess",
      accessibilityDisplayFlags: AccessibilityDisplayFlagsResponse(
        increaseContrast: false,
        differentiateWithoutColor: false,
        reduceTransparency: false),
      selectionProvider: { _ in nil },
      accessibilityValueProvider: { _ in "" },
      sessionClientInfoById: [:])
  }
}

/// Presents agent command proposals for human review (C15 safe rendering).
public protocol CommandProposalReviewPresenting: AnyObject {
  func present(proposal: CommandProposal)
}

/// Routes Phase 2 own-session observe requests against the live AppModel.
/// Server callbacks arrive off-main; reads hop to the main thread so model
/// observers and AppKit-facing refresh paths keep their existing contract.
final class LiveIntentRouter: IntentRouter {
  private weak var model: AppModel?
  private var environment: LiveControlEnvironment
  private var windowScreenshotProvider:
    (() -> Result<LabanWindowScreenshot, LabanWindowScreenshotFailure>)?
  private let notificationDiagnosticsStore: NativeNotificationDiagnosticsStore
  private let notificationIdentityProvider: () -> NativeNotificationRuntimeIdentity
  private var notificationStateRefresh: () -> Void
  private var notificationTestHandler: ((AttentionNotificationEvent, Bool) -> Void)?
  private var transparencyStateProvider: (() -> TerminalTransparencyDebugResponse?)?
  private var setBackgroundTransparencyHandler:
    ((Double, Double?, Bool, TerminalBackdropStyle?) -> Void)?
  private var resetTransparencyDiagnosticsHandler: (() -> Void)?
  private var setReduceTransparencyOverrideHandler: ((Bool?) -> Void)?
  private var setNativeFullScreenHandler: ((Bool) -> Void)?
  private var setBackgroundSourceHandler: ((TerminalBackdropStyle) -> Void)?
  private var setBackgroundImageScalingHandler: ((TerminalBackgroundImageScaling) -> Void)?
  private var importBackgroundImageHandler:
    ((String, TerminalBackgroundImageScaling) throws -> Void)?
  private var removeBackgroundImageHandler: (() -> Void)?
  private var fixtureWindowFocusHandler: (() -> Bool)?
  private let profileCaptureHandler: (Int, Int64) throws -> Data
  weak var proposalPresenter: CommandProposalReviewPresenting?

  init(
    model: AppModel?,
    environment: LiveControlEnvironment? = nil,
    proposalPresenter: CommandProposalReviewPresenting? = nil,
    notificationDiagnosticsStore: NativeNotificationDiagnosticsStore = .shared,
    notificationIdentityProvider: @escaping () -> NativeNotificationRuntimeIdentity = {
      NativeNotificationRuntimeIdentityProvider.snapshot()
    },
    profileCaptureHandler: @escaping (Int, Int64) throws -> Data = { samples, interval in
      guard ProfileRecorderSettings.resolve().isEnabled else {
        throw ProfileCaptureError.profilerNotRunning
      }
      return try ProfileSamplerCapture.captureBlocking(
        sampleCount: samples,
        intervalMilliseconds: interval)
    }
  ) {
    self.model = model
    self.proposalPresenter = proposalPresenter
    self.notificationDiagnosticsStore = notificationDiagnosticsStore
    self.notificationIdentityProvider = notificationIdentityProvider
    self.profileCaptureHandler = profileCaptureHandler
    self.notificationStateRefresh = {}
    if let environment {
      self.environment = environment
    } else if let model {
      self.environment = .default(model: model)
    } else {
      self.environment = LiveControlEnvironment(
        cellWidth: 10,
        cellHeight: 20,
        sidebarWidth: 200,
        frame: 0,
        windowWidth: 1200,
        windowHeight: 800,
        transportMode: "inProcess",
        accessibilityDisplayFlags: AccessibilityDisplayFlagsResponse(
          increaseContrast: false,
          differentiateWithoutColor: false,
          reduceTransparency: false),
        selectionProvider: { _ in nil },
        accessibilityValueProvider: { _ in "" },
        sessionClientInfoById: [:])
    }
  }

  func bindModel(_ model: AppModel) {
    performOnMain { self.model = model }
  }

  func updateEnvironment(_ environment: LiveControlEnvironment) {
    performOnMain { self.environment = environment }
  }

  func bindWindowScreenshotProvider(
    _ provider: @escaping () -> Result<LabanWindowScreenshot, LabanWindowScreenshotFailure>
  ) {
    performOnMain { self.windowScreenshotProvider = provider }
  }

  func bindNotificationStateRefresh(_ refresh: @escaping () -> Void) {
    performOnMain { self.notificationStateRefresh = refresh }
  }

  func bindNotificationTestHandler(
    _ handler: @escaping (AttentionNotificationEvent, Bool) -> Void
  ) {
    performOnMain { self.notificationTestHandler = handler }
  }

  func bindFixtureWindowFocusHandler(_ handler: @escaping @MainActor () -> Bool) {
    performOnMain {
      self.fixtureWindowFocusHandler = {
        MainActor.assumeIsolated {
          handler()
        }
      }
    }
  }

  func bindTransparencyControl(
    state: @escaping () -> TerminalTransparencyDebugResponse?,
    setBackground: @escaping (Double, Double?, Bool, TerminalBackdropStyle?) -> Void,
    resetDiagnostics: @escaping () -> Void,
    setReduceTransparencyOverride: @escaping (Bool?) -> Void,
    setNativeFullScreen: @escaping (Bool) -> Void,
    setBackgroundSource: @escaping (TerminalBackdropStyle) -> Void,
    setBackgroundImageScaling: @escaping (TerminalBackgroundImageScaling) -> Void,
    importBackgroundImage: @escaping (String, TerminalBackgroundImageScaling) throws -> Void,
    removeBackgroundImage: @escaping () -> Void
  ) {
    performOnMain {
      self.transparencyStateProvider = state
      self.setBackgroundTransparencyHandler = setBackground
      self.resetTransparencyDiagnosticsHandler = resetDiagnostics
      self.setReduceTransparencyOverrideHandler = setReduceTransparencyOverride
      self.setNativeFullScreenHandler = setNativeFullScreen
      self.setBackgroundSourceHandler = setBackgroundSource
      self.setBackgroundImageScalingHandler = setBackgroundImageScaling
      self.importBackgroundImageHandler = importBackgroundImage
      self.removeBackgroundImageHandler = removeBackgroundImage
    }
  }

  func route(_ intent: Intent) -> ControlResponse {
    if case .legacyDebugAction(let input) = intent,
      input.intentID == "profile.capture"
    {
      // Sampling is intentionally handled on the control server's worker
      // thread. Routing it through performOnMain would freeze AppKit for the
      // entire capture and distort the profile being collected.
      return captureProfileAction(body: input.body)
    }
    return performOnMain {
      switch intent {
      case .legacyDebugAction(let input):
        switch input.intentID {
        case "terminal.scrollViewport":
          return scrollViewportAction(body: input.body, scopedSessionID: input.scopedSessionID)
        case "command.propose":
          return commandProposeAction(body: input.body, scopedSessionID: input.scopedSessionID)
        case "commandProposal.list":
          return commandProposalListAction(scopedSessionID: input.scopedSessionID)
        case "commandProposal.get":
          return commandProposalGetAction(body: input.body, scopedSessionID: input.scopedSessionID)
        case "commandProposal.cancel":
          return commandProposalCancelAction(
            body: input.body, scopedSessionID: input.scopedSessionID)
        case "fixture.windowFocus":
          return fixtureWindowFocusAction(body: input.body)
        case "transparency.setBackground":
          return setBackgroundTransparencyAction(body: input.body)
        case "transparency.diagnostics.reset":
          return resetTransparencyDiagnosticsAction(body: input.body)
        case "transparency.reduceTransparencyOverride.set":
          return setReduceTransparencyOverrideAction(body: input.body)
        case "transparency.nativeFullScreen.set":
          return setNativeFullScreenAction(body: input.body)
        case "transparency.backgroundSource.set":
          return setBackgroundSourceAction(body: input.body)
        case "transparency.backgroundImageScaling.set":
          return setBackgroundImageScalingAction(body: input.body)
        case "transparency.backgroundImage.import":
          return importBackgroundImageAction(body: input.body)
        case "transparency.backgroundImage.remove":
          return removeBackgroundImageAction(body: input.body)
        default:
          return .error(404, "unavailable on gui")
        }
      case .tabSelect, .terminalTypeText, .terminalSendKey:
        return .error(404, "unavailable on gui")
      case .unsupportedDebugAction(let input):
        return .error(404, "debug action \(input.action) is unavailable on gui")
      }
    }
  }

  // This structured `Query` overload is not on the live HTTP surface: every
  // route in ControlRouteCatalog dispatches through
  // `query(_ query: LegacyDebugQueryInput)`, which threads the caller's
  // scopedSessionID and readRedaction. This overload is reached only by
  // headless/test callers, none of which are session-scoped, so the
  // unredacted/unscoped projection context here is not a live cross-session
  // leak.
  func query(_ query: Query) -> ControlResponse {
    performOnMain {
      guard let model = model else {
        return .error(500, "model released")
      }
      let ctx = projectionContext(
        model: model, scopedSessionID: nil, readRedaction: .none)
      return json(ControlStateProjections.stateResponse(ctx))
    }
  }

  func query(_ query: LegacyDebugQueryInput) -> ControlResponse {
    performOnMain {
      if query.intentID == "transparency.state" {
        guard let state = transparencyStateProvider?() else {
          return .error(503, "transparency diagnostics unavailable")
        }
        return json(state)
      }
      guard let model = model else {
        return .error(500, "model released")
      }
      let ctx = projectionContext(
        model: model,
        scopedSessionID: query.scopedSessionID,
        readRedaction: query.readRedaction)
      switch query.intentID {
      case "debug.discovery", "debug.capabilities":
        return json(guiDiscoveryResponse(readRedaction: query.readRedaction))
      case "debug.health":
        return json(guiHealthResponse())
      case "app.state", "app.stateSummary":
        return json(ControlStateProjections.stateResponse(ctx))
      case "notifications.state":
        notificationStateRefresh()
        let since = query.params["since"].flatMap(Int.init)
        return json(
          notificationDiagnosticsStore.snapshot(
            since: since,
            identity: notificationIdentityProvider()))
      case "app.accessibility":
        return json(ControlStateProjections.accessibilityResponse(ctx))
      case "terminal.modes":
        return json(ControlStateProjections.terminalModesResponse(ctx))
      case "find.state":
        return legacyJSON(ControlStateProjections.findState(query: query.params, ctx: ctx))
      case "shellIntegration.state":
        return legacyJSON(
          ControlStateProjections.shellIntegrationState(query: query.params, ctx: ctx))
      case "terminal.getText":
        return legacyJSON(ControlStateProjections.getTextResponse(query: query.params, ctx: ctx))
      case "window.screenshot":
        return windowScreenshotResponse(query: query, model: model)
      case "scrollIndicator.state":
        return legacyJSON(
          ControlStateProjections.scrollIndicatorState(query: query.params, ctx: ctx))
      case "session.list":
        return json(ControlStateProjections.sessionsResponse(ctx))
      case "session.detail":
        let sessionId = query.params["sessionId"] ?? query.params["sessionID"] ?? ""
        return legacyJSON(
          ControlStateProjections.sessionResponse(id: sessionId, query: query.params, ctx: ctx))
      case "selection.read":
        return json(ControlStateProjections.selectionResponse(ctx))
      case "spinnerMotion.state":
        guard let response = ControlStateProjections.spinnerMotionResponse(ctx) else {
          return .error(503, "spinner motion diagnostics unavailable")
        }
        return json(response)
      default:
        return .error(404, "unavailable on gui")
      }
    }
  }

  func control(_ input: LegacyDebugControlInput) -> ControlResponse {
    performOnMain {
      switch input.intentID {
      case "notifications.test":
        return notificationTestAction(body: input.body)
      case "terminal.scrollViewport":
        return scrollViewportAction(body: input.body, scopedSessionID: input.scopedSessionID)
      case "command.propose":
        return commandProposeAction(body: input.body, scopedSessionID: input.scopedSessionID)
      case "commandProposal.list":
        return commandProposalListAction(scopedSessionID: input.scopedSessionID)
      case "commandProposal.get":
        return commandProposalGetAction(body: input.body, scopedSessionID: input.scopedSessionID)
      case "commandProposal.cancel":
        return commandProposalCancelAction(body: input.body, scopedSessionID: input.scopedSessionID)
      default:
        return .error(404, "unavailable on gui")
      }
    }
  }

  func artifact(_ request: ArtifactRequest) -> ControlResponse? {
    nil
  }

  private func notificationTestAction(body: Data) -> ControlResponse {
    guard let handler = notificationTestHandler else {
      return .error(503, "notification test unavailable")
    }
    let request: NativeNotificationTestRequest
    if body.isEmpty {
      request = NativeNotificationTestRequest()
    } else {
      guard let decoded = try? JSONDecoder().decode(NativeNotificationTestRequest.self, from: body)
      else {
        return .error(400, "invalid notification test request")
      }
      request = decoded
    }

    let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Laban"
    let message =
      request.body?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? "Native notification test"
    guard !title.isEmpty, title.unicodeScalars.count <= 128 else {
      return .error(400, "notification title must contain 1...128 Unicode scalars")
    }
    guard !message.isEmpty, message.unicodeScalars.count <= 512 else {
      return .error(400, "notification body must contain 1...512 Unicode scalars")
    }

    let event = AttentionNotificationEvent(
      tabId: "settings",
      source: .osc,
      category: .needsAction,
      title: title,
      body: message,
      dedupeKey: "debug-notification-test")
    notificationDiagnosticsStore.record(
      eventId: event.id,
      tabId: event.tabId,
      source: event.source.rawValue,
      category: event.category.rawValue,
      stage: .testRequested,
      outcome: "accepted")
    handler(event, request.soundEnabled ?? AttentionNotificationSettings.soundEnabled)
    return json(
      NativeNotificationTestAcceptedResponse(accepted: true, eventId: event.id),
      status: 202)
  }

  private func captureProfileAction(body: Data) -> ControlResponse {
    guard
      let request = try? JSONDecoder().decode(CaptureProfileActionRequest.self, from: body),
      (1...1_200).contains(request.samples),
      (1...1_000).contains(request.intervalMilliseconds),
      request.samples * request.intervalMilliseconds <= 120_000
    else {
      return .error(400, "invalid captureProfile request")
    }

    let processID = Int(ProcessInfo.processInfo.processIdentifier)
    if let expectedPID = request.expectedPID, expectedPID != processID {
      return .error(409, "profile target process changed")
    }

    do {
      let profile = try profileCaptureHandler(
        request.samples, Int64(request.intervalMilliseconds))
      guard !profile.isEmpty else {
        return .error(500, "profile capture returned no samples")
      }
      return json(CaptureProfileActionResponse(profileData: profile, pid: processID))
    } catch ProfileCaptureError.profilerNotRunning {
      return .error(409, "CPU sampling is disabled")
    } catch ProfileCaptureError.captureAlreadyInProgress {
      return .error(409, "CPU profile capture already in progress")
    } catch {
      AppLog.app.error("Control-plane CPU profile capture failed: \(String(describing: error))")
      return .error(500, "CPU profile capture failed")
    }
  }

  private func setBackgroundTransparencyAction(body: Data) -> ControlResponse {
    guard
      let request = try? JSONDecoder().decode(
        SetBackgroundTransparencyActionRequest.self, from: body),
      request.opacity.isFinite,
      request.blur?.isFinite != false,
      let handler = setBackgroundTransparencyHandler
    else {
      return .error(400, "invalid setBackgroundTransparency request")
    }
    handler(
      min(max(request.opacity, 0), 1),
      request.blur.map { min(max($0, 0), 1) },
      request.applyToExplicitCellBackgrounds,
      request.backdropStyle)
    return diagnosticActionOK()
  }

  private func resetTransparencyDiagnosticsAction(body: Data) -> ControlResponse {
    guard
      (try? JSONDecoder().decode(ResetTransparencyDiagnosticsActionRequest.self, from: body))
        != nil,
      let handler = resetTransparencyDiagnosticsHandler
    else {
      return .error(400, "invalid resetTransparencyDiagnostics request")
    }
    handler()
    return diagnosticActionOK()
  }

  private func setReduceTransparencyOverrideAction(body: Data) -> ControlResponse {
    guard
      let request = try? JSONDecoder().decode(
        SetReduceTransparencyOverrideActionRequest.self, from: body),
      let handler = setReduceTransparencyOverrideHandler
    else {
      return .error(400, "invalid setReduceTransparencyOverride request")
    }
    handler(request.enabled)
    return diagnosticActionOK()
  }

  private func setNativeFullScreenAction(body: Data) -> ControlResponse {
    guard
      let request = try? JSONDecoder().decode(SetNativeFullScreenActionRequest.self, from: body),
      let handler = setNativeFullScreenHandler
    else {
      return .error(400, "invalid setNativeFullScreen request")
    }
    handler(request.enabled)
    return diagnosticActionOK()
  }

  private func setBackgroundSourceAction(body: Data) -> ControlResponse {
    guard
      let request = try? JSONDecoder().decode(SetBackgroundSourceActionRequest.self, from: body),
      let handler = setBackgroundSourceHandler
    else {
      return .error(400, "invalid setBackgroundSource request")
    }
    handler(request.source)
    return diagnosticActionOK()
  }

  private func setBackgroundImageScalingAction(body: Data) -> ControlResponse {
    guard
      let request = try? JSONDecoder().decode(
        SetBackgroundImageScalingActionRequest.self, from: body),
      let handler = setBackgroundImageScalingHandler
    else {
      return .error(400, "invalid setBackgroundImageScaling request")
    }
    handler(request.scaling)
    return diagnosticActionOK()
  }

  private func importBackgroundImageAction(body: Data) -> ControlResponse {
    guard
      let request = try? JSONDecoder().decode(ImportBackgroundImageActionRequest.self, from: body),
      let handler = importBackgroundImageHandler
    else {
      return .error(400, "invalid importBackgroundImage request")
    }
    do {
      try handler(request.path, request.scaling)
      return diagnosticActionOK()
    } catch {
      return .error(400, "background image fixture import rejected")
    }
  }

  private func removeBackgroundImageAction(body: Data) -> ControlResponse {
    guard
      (try? JSONDecoder().decode(RemoveBackgroundImageActionRequest.self, from: body)) != nil,
      let handler = removeBackgroundImageHandler
    else {
      return .error(400, "invalid removeBackgroundImage request")
    }
    handler()
    return diagnosticActionOK()
  }

  private func fixtureWindowFocusAction(body: Data) -> ControlResponse {
    guard let request = try? JSONDecoder().decode(WindowFocusActionRequest.self, from: body) else {
      return .error(400, "invalid windowFocus request")
    }
    guard request.focused ?? true else {
      return .error(400, "live windowFocus supports focused=true only")
    }
    guard let handler = fixtureWindowFocusHandler else {
      return .error(503, "live windowFocus unavailable")
    }
    guard handler() else {
      return .error(503, "live windowFocus window unavailable")
    }
    return diagnosticActionOK()
  }

  private func diagnosticActionOK() -> ControlResponse {
    ControlResponse(
      status: 200,
      contentType: "application/json",
      body: Data(#"{"ok":true}"#.utf8))
  }

  private func windowScreenshotResponse(
    query: LegacyDebugQueryInput,
    model: AppModel
  ) -> ControlResponse {
    guard let scopedSessionID = query.scopedSessionID else {
      return .error(403, "session scope required")
    }
    guard model.activeTab?.sessionId == scopedSessionID else {
      return .error(409, "sessionNotVisible")
    }
    guard let provider = windowScreenshotProvider else {
      return .error(503, "windowScreenshotUnavailable")
    }
    let screenshot: LabanWindowScreenshot
    switch provider() {
    case .success(let captured):
      screenshot = captured
    case .failure(.permissionDenied):
      return .error(403, "screenRecordingPermissionDenied")
    case .failure(.captureFailed):
      return .error(503, "windowScreenshotUnavailable")
    }
    guard screenshot.pngData.count <= LabanWindowScreenshotCapture.maxPNGBytes else {
      return .error(413, "windowScreenshotTooLarge")
    }
    let signature = [UInt8](screenshot.pngData.prefix(8))
    guard signature == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] else {
      return .error(500, "windowScreenshotEncodingFailed")
    }
    return json(
      WindowScreenshotResponse(
        pngBase64: screenshot.pngData.base64EncodedString(),
        width: screenshot.width,
        height: screenshot.height,
        byteCount: screenshot.pngData.count,
        includesDialogs: true))
  }

  private func performOnMain<T>(_ work: () -> T) -> T {
    if Thread.isMainThread {
      return work()
    }
    return DispatchQueue.main.sync(execute: work)
  }

  private func scrollViewportAction(body: Data, scopedSessionID: String?) -> ControlResponse {
    guard let model = model else {
      return .error(500, "model released")
    }
    guard let request = try? JSONDecoder().decode(ScrollViewportActionRequest.self, from: body)
    else {
      return .error(400, "bad request")
    }
    // C12: a session-scoped caller resolves to its own session and never the
    // active tab. The active-tab fallback below is reachable only by a
    // whole-app/fixture caller (scopedSessionID == nil), which has no own
    // session; that path keeps legacy active-session behavior deliberately.
    let targetSessionID =
      request.sessionId ?? scopedSessionID ?? model.activeTab?.sessionId
    if let scopedSessionID, let requestedSessionID = request.sessionId,
      requestedSessionID != scopedSessionID
    {
      return .error(403, "forbidden")
    }
    guard let sessionID = targetSessionID,
      let tab = model.tabs.first(where: { $0.sessionId == sessionID }),
      let session = model.session(forTab: tab.id)
    else {
      return .error(400, "no session for scrollViewport")
    }
    let deltaRows = request.deltaRows ?? 0
    session.scrollViewport(deltaRows: deltaRows)
    let ctx = projectionContext(
      model: model, scopedSessionID: scopedSessionID, readRedaction: .none)
    return json(
      ControlStateProjections.actionResult(ok: true, ctx: ctx, targetSessionID: sessionID))
  }

  private func commandProposeAction(body: Data, scopedSessionID: String?) -> ControlResponse {
    guard let model = model else {
      return .error(500, "model released")
    }
    let response = CommandProposalRouting.handle(
      body: body,
      scopedSessionID: scopedSessionID,
      sessionExists: { sessionID in
        model.tabs.contains(where: { $0.sessionId == sessionID })
      },
      activeSessionID: { model.activeTab?.sessionId })
    guard response.status == 200,
      let proposal = decodeProposal(from: response.body)
    else {
      return response
    }
    if let stored = CommandProposalStore.shared.proposal(id: proposal.proposalID) {
      let presenter = proposalPresenter
      DispatchQueue.main.async {
        presenter?.present(proposal: stored)
      }
    }
    return response
  }

  private func commandProposalListAction(scopedSessionID: String?) -> ControlResponse {
    guard let model = model else { return .error(500, "model released") }
    return CommandProposalRouting.handleList(
      scopedSessionID: scopedSessionID,
      activeSessionID: { model.activeTab?.sessionId })
  }

  private func commandProposalGetAction(body: Data, scopedSessionID: String?) -> ControlResponse {
    guard let model = model else { return .error(500, "model released") }
    return CommandProposalRouting.handleGet(
      body: body,
      scopedSessionID: scopedSessionID,
      activeSessionID: { model.activeTab?.sessionId })
  }

  private func commandProposalCancelAction(
    body: Data, scopedSessionID: String?
  ) -> ControlResponse {
    guard let model = model else { return .error(500, "model released") }
    return CommandProposalRouting.handleCancel(
      body: body,
      scopedSessionID: scopedSessionID,
      activeSessionID: { model.activeTab?.sessionId })
  }

  private func decodeProposal(from body: Data) -> CommandProposeResponse? {
    try? JSONDecoder().decode(CommandProposeResponse.self, from: body)
  }

  private func projectionContext(
    model: AppModel,
    scopedSessionID: String?,
    readRedaction: ControlReadRedaction
  ) -> ControlProjectionContext {
    var selectionBySession: [Session.ID: TerminalSelection] = [:]
    for tab in model.tabs {
      if let session = model.session(forTab: tab.id),
        let selection = environment.selectionProvider(session.id)
      {
        selectionBySession[session.id] = selection
      }
    }
    return ControlProjectionContext(
      model: model,
      mode: "gui",
      frame: environment.frame,
      windowWidth: environment.windowWidth,
      windowHeight: environment.windowHeight,
      cellWidth: environment.cellWidth,
      cellHeight: environment.cellHeight,
      sidebarWidth: environment.sidebarWidth,
      accessibilityDisplayFlags: environment.accessibilityDisplayFlags,
      selectionBySession: selectionBySession,
      sessionClientInfoById: environment.sessionClientInfoById,
      transportMode: environment.transportMode,
      scopedSessionID: scopedSessionID,
      readRedaction: readRedaction,
      clientSnapshotProvider: nil,
      accessibilityValueProvider: { [environment] tab in environment.accessibilityValueProvider(tab)
      })
  }

  private func guiDiscoveryResponse(readRedaction: ControlReadRedaction) -> DebugDiscoveryResponse {
    let artifactRoot =
      FileManager.default.urls(
        for: .documentDirectory, in: .userDomainMask
      ).first?.path ?? ""
    return DebugDiscoveryResponse(
      name: "laban-debug",
      schema: "schemas/debug/discovery.schema.json",
      runId: ProcessInfo.processInfo.globallyUniqueString,
      mode: "gui",
      frame: environment.frame,
      artifactRoot: artifactRoot,
      fixtureRoot: "",
      entrypoints: ["/debug", "/debug/capabilities"],
      endpoints: guiDiscoveryEndpoints(readRedaction: readRedaction),
      actions: guiDiscoveryActions(readRedaction: readRedaction),
      waitConditions: [],
      fixtureActions: [],
      examples: guiDiscoveryExamples(readRedaction: readRedaction))
  }

  private func guiDiscoveryEndpoints(readRedaction: ControlReadRedaction)
    -> [DebugDiscoveryEndpoint]
  {
    ControlRouteCatalog.endpoints.compactMap { endpoint in
      guard endpointPermittedInGUIDiscovery(endpoint, readRedaction: readRedaction) else {
        return nil
      }
      let binding = endpoint.binding
      let isActionEndpoint = binding.path == "/debug/actions"
      let summary =
        isActionEndpoint
        ? "GUI-safe actions available to the authenticated token." : binding.summary
      let requestSchema = isActionEndpoint ? nil : binding.legacyRequestSchemaPath
      return DebugDiscoveryEndpoint(
        method: binding.method,
        path: binding.path,
        category: binding.category,
        summary: summary,
        queryParameters: binding.queryParameters,
        requestSchema: requestSchema,
        responseSchema: binding.legacyResponseSchemaPath)
    }
  }

  private func endpointPermittedInGUIDiscovery(
    _ endpoint: ControlEndpointDescriptor,
    readRedaction: ControlReadRedaction
  ) -> Bool {
    switch endpoint.intentMapping {
    case .fixed(let id):
      let effectiveID = effectiveDiscoveryIntentID(
        id,
        path: endpoint.binding.path,
        readRedaction: readRedaction)
      return descriptorPermittedInGUIDiscovery(effectiveID, readRedaction: readRedaction)
    case .requestBodyField(_):
      return !guiActionDescriptors(readRedaction: readRedaction).isEmpty
    case .none, .queryParameter(_):
      return false
    }
  }

  private func effectiveDiscoveryIntentID(
    _ id: String,
    path: String,
    readRedaction: ControlReadRedaction
  ) -> String {
    guard path == "/debug/state" else { return id }
    switch readRedaction {
    case .appObserveSummary:
      return "app.stateSummary"
    case .sessionObserveSummary, .none:
      return id
    }
  }

  private func guiDiscoveryActions(readRedaction: ControlReadRedaction) -> [DebugDiscoveryControl] {
    guiActionDescriptors(readRedaction: readRedaction).compactMap { descriptor in
      guard let actionName = Self.guiDebugActionNames[descriptor.id] else { return nil }
      return DebugDiscoveryControl(name: actionName, summary: descriptor.summary)
    }
  }

  private func guiActionDescriptors(readRedaction: ControlReadRedaction) -> [IntentDescriptor] {
    IntentCatalog.shared.descriptors.filter {
      $0.kind == .action
        && $0.availability.permits(.gui)
        && discoveryAllows($0.requiredCapability, readRedaction: readRedaction)
        && Self.guiDebugActionNames[$0.id] != nil
    }
  }

  private func descriptorPermittedInGUIDiscovery(
    _ id: String,
    readRedaction: ControlReadRedaction
  ) -> Bool {
    guard let descriptor = IntentCatalog.shared.descriptor(id: id) else { return false }
    return descriptor.availability.permits(.gui)
      && discoveryAllows(descriptor.requiredCapability, readRedaction: readRedaction)
  }

  private func discoveryAllows(
    _ capability: Capability,
    readRedaction: ControlReadRedaction
  ) -> Bool {
    switch readRedaction {
    case .appObserveSummary:
      return capability == .observe
    case .sessionObserveSummary:
      return capability == .observe
        || capability == .observeSensitive
        || capability == .navigate
        || capability == .propose
    case .none:
      return true
    }
  }

  private func guiDiscoveryExamples(readRedaction: ControlReadRedaction) -> [DebugDiscoveryExample]
  {
    var examples = [
      DebugDiscoveryExample(
        title: "List capabilities",
        command:
          #"curl --unix-socket "$LABAN_CONTROL_URL" -H "Authorization: Bearer $LABAN_TOKEN" http://laban/debug | jq"#
      )
    ]
    let actionNames = Set(guiDiscoveryActions(readRedaction: readRedaction).map(\.name))
    if actionNames.contains("scrollViewport") {
      examples.append(
        DebugDiscoveryExample(
          title: "Scroll own session",
          command:
            #"curl --unix-socket "$LABAN_CONTROL_URL" -H "Authorization: Bearer $LABAN_TOKEN" -X POST http://laban/debug/actions -d '{"action":"scrollViewport","deltaRows":1}'"#
        ))
    }
    if actionNames.contains("propose") {
      examples.append(
        DebugDiscoveryExample(
          title: "Propose a command",
          command:
            #"curl --unix-socket "$LABAN_CONTROL_URL" -H "Authorization: Bearer $LABAN_TOKEN" -X POST http://laban/debug/actions -d '{"action":"propose","command":"echo hello","purpose":"user review"}'"#
        ))
    }
    return examples
  }

  private func guiHealthResponse() -> HealthResponse {
    HealthResponse(
      ok: model != nil,
      mode: "gui",
      frame: environment.frame,
      focused: NSApplication.shared.isActive)
  }

  private func json<T: Encodable>(_ value: T, status: Int = 200) -> ControlResponse {
    ControlResponse.json(value, status: status)
  }

  private func legacyJSON(_ response: ControlJSONResponse) -> ControlResponse {
    ControlResponse(
      status: response.status,
      contentType: "application/json",
      body: response.body)
  }

  private static let guiDebugActionNames: [String: String] = [
    "profile.capture": "captureProfile",
    "terminal.scrollViewport": "scrollViewport",
    "command.propose": "propose",
    "transparency.setBackground": "setBackgroundTransparency",
    "transparency.diagnostics.reset": "resetTransparencyDiagnostics",
    "transparency.reduceTransparencyOverride.set": "setReduceTransparencyOverride",
    "transparency.nativeFullScreen.set": "setNativeFullScreen",
    "transparency.backgroundSource.set": "setBackgroundSource",
    "transparency.backgroundImageScaling.set": "setBackgroundImageScaling",
    "transparency.backgroundImage.import": "importBackgroundImage",
    "transparency.backgroundImage.remove": "removeBackgroundImage",
  ]
}
