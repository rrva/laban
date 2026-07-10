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
  weak var proposalPresenter: CommandProposalReviewPresenting?

  init(
    model: AppModel?,
    environment: LiveControlEnvironment? = nil,
    proposalPresenter: CommandProposalReviewPresenting? = nil
  ) {
    self.model = model
    self.proposalPresenter = proposalPresenter
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

  func route(_ intent: Intent) -> ControlResponse {
    performOnMain {
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
      default:
        return .error(404, "unavailable on gui")
      }
    }
  }

  func control(_ input: LegacyDebugControlInput) -> ControlResponse {
    performOnMain {
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
        return commandProposalCancelAction(body: input.body, scopedSessionID: input.scopedSessionID)
      default:
        return .error(404, "unavailable on gui")
      }
    }
  }

  func artifact(_ request: ArtifactRequest) -> ControlResponse? {
    nil
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
    "terminal.scrollViewport": "scrollViewport",
    "command.propose": "propose",
  ]
}
