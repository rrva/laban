import Foundation
import LabanCore

public final class HeadlessIntentRouter: IntentRouter {
  private let runtime: HeadlessDebugRuntime

  public init(runtime: HeadlessDebugRuntime) {
    self.runtime = runtime
  }

  public func route(_ intent: Intent) -> ControlResponse {
    switch intent {
    case .unsupportedDebugAction(let input):
      return json(runtime.unsupportedAction(input.action))
    case .tabSelect, .terminalTypeText, .terminalSendKey, .legacyDebugAction:
      return .error(501, "not yet ported")
    }
  }

  public func query(_ query: Query) -> ControlResponse {
    switch query {
    case .state:
      return json(runtime.state())
    }
  }

  public func query(_ query: LegacyDebugQueryInput) -> ControlResponse {
    switch query.intentID {
    case "debug.discovery", "debug.capabilities":
      return json(runtime.discovery())
    case "debug.health":
      return json(runtime.health())
    case "app.state":
      return json(runtime.state())
    case "app.accessibility":
      return json(runtime.accessibility())
    case "terminal.modes":
      return json(runtime.terminalModes())
    case "persistence.state":
      return json(runtime.persistenceState())
    case "persistence.restorePicker":
      return json(runtime.persistenceRestorePicker())
    case "find.state":
      return json(runtime.findState(query: query.params))
    case "shellIntegration.state":
      return json(runtime.shellIntegrationState(query: query.params))
    case "scrollIndicator.state":
      return json(runtime.scrollIndicatorState(query: query.params))
    case "scrollTrace":
      return json(runtime.scrollTrace(query: query.params))
    case "session.list":
      return json(runtime.sessions())
    case "session.detail":
      return json(runtime.session(id: query.params["sessionId"] ?? "", query: query.params))
    case "render.state":
      return json(runtime.renderState())
    case "render.frameCommands":
      return json(runtime.frameCommands(query: query.params))
    case "render.atlas":
      return json(runtime.atlas())
    case "log.events":
      return json(runtime.events(since: intParam("since", in: query.params)))
    case "log.tabJournal":
      return json(
        runtime.tabJournalResponse(
          since: intParam("since", in: query.params),
          tabId: query.params["tabId"]))
    case "log.input":
      return json(runtime.inputLogResponse(since: intParam("since", in: query.params)))
    case "log.terminal":
      return json(runtime.terminalLogResponse(query: query.params))
    case "log.timing":
      return json(runtime.timingResponse())
    case "log.metrics":
      return json(runtime.metricsResponse())
    case "log.errors":
      return json(runtime.errors(since: intParam("since", in: query.params)))
    case "selection.read":
      return json(runtime.selection())
    case "clipboard.read":
      return json(runtime.clipboard())
    default:
      return .error(501, "not yet ported")
    }
  }

  public func artifact(_ request: ArtifactRequest) -> ControlResponse? {
    switch request.id {
    case "artifact.screenshot":
      do {
        let (data, frame, width, height) = try runtime.screenshotBytes()
        return .binary(
          data,
          contentType: "image/png",
          headers: [
            "X-App-Frame": "\(frame)",
            "X-App-Size": "\(width)x\(height)",
          ])
      } catch {
        return .error(500, "screenshot failed: \(error)")
      }
    case "cast.recent":
      let parsedSeconds = Double(request.params["seconds"] ?? "") ?? 10
      guard parsedSeconds.isFinite, parsedSeconds >= 0 else {
        return .error(400, "seconds must be a finite, non-negative number")
      }
      let seconds = min(parsedSeconds, 3600)
      switch runtime.recentCastBytes(seconds: seconds, tabId: request.params["tabId"]) {
      case .success(let data, let tabId, let chunks, let windowSeconds):
        return .binary(
          data,
          contentType: "application/x-asciicast",
          headers: [
            "X-App-Tab": "\(tabId)",
            "X-App-Cast-Chunks": "\(chunks)",
            "X-App-Cast-Window-Seconds": "\(windowSeconds)",
          ])
      case .failure(let status, let message):
        return .error(status, message)
      }
    default:
      return nil
    }
  }

  private func json(_ response: DebugResponse) -> ControlResponse {
    ControlResponse(
      status: response.status,
      contentType: "application/json",
      body: response.body)
  }

  private func intParam(_ name: String, in params: [String: String]) -> Int {
    params[name].flatMap { Int($0) } ?? 0
  }
}
