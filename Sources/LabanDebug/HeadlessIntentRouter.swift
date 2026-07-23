import Foundation
import LabanCore

public final class HeadlessIntentRouter: IntentRouter {
  private let runtime: HeadlessDebugRuntime
  private let notificationDiagnosticsStore: NativeNotificationDiagnosticsStore

  public init(
    runtime: HeadlessDebugRuntime,
    notificationDiagnosticsStore: NativeNotificationDiagnosticsStore =
      NativeNotificationDiagnosticsStore(nativeAvailable: false)
  ) {
    self.runtime = runtime
    self.notificationDiagnosticsStore = notificationDiagnosticsStore
  }

  public func route(_ intent: Intent) -> ControlResponse {
    switch intent {
    case .legacyDebugAction(let input):
      return json(runtime.applyAction(input.body, scopedSessionID: input.scopedSessionID))
    case .unsupportedDebugAction(let input):
      return json(runtime.unsupportedAction(input.action))
    case .tabSelect, .terminalTypeText, .terminalSendKey:
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
    case "app.state", "app.stateSummary":
      return json(runtime.state())
    case "notifications.state":
      return ControlResponse.json(
        notificationDiagnosticsStore.snapshot(
          since: query.params["since"].flatMap(Int.init)))
    case "app.accessibility":
      return json(runtime.accessibility())
    case "transparency.state":
      return json(runtime.transparencyState())
    case "terminal.modes":
      return json(runtime.terminalModes())
    case "persistence.state":
      return json(runtime.persistenceState())
    case "persistence.restorePicker":
      return json(runtime.persistenceRestorePicker())
    case "capture.status":
      return json(runtime.captureStatus())
    case "find.state":
      return json(runtime.findState(query: query.params))
    case "shellIntegration.state":
      return json(runtime.shellIntegrationState(query: query.params))
    case "terminal.getText":
      return json(runtime.getText(query: query.params))
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
    case "spinnerMotion.state":
      return json(runtime.spinnerMotion())
    case "hoverPreview.state":
      return json(runtime.hoverPreview())
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

  public func control(_ input: LegacyDebugControlInput) -> ControlResponse {
    switch input.intentID {
    case "notifications.test":
      return .error(409, "native notifications unavailable in headless mode")
    case "artifact.screenshot.write":
      return json(runtime.writeScreenshotArtifact())
    case "persistence.flush":
      return json(runtime.persistenceFlush())
    case "persistence.relaunch":
      return json(runtime.persistenceRelaunch())
    case "persistence.restorePicker.select":
      return json(runtime.persistenceRestoreSelection(input.body))
    case "find.start":
      return json(runtime.findStart(input.body))
    case "find.step":
      return json(runtime.findStep(input.body))
    case "find.stop":
      return json(runtime.findStop(input.body))
    case "wait.condition":
      return json(runtime.wait(input.body))
    case "render.trace":
      return json(runtime.renderTrace(input.body))
    case "render.pixelProbe":
      return json(runtime.pixelProbe(input.body))
    case "artifact.snapshot":
      return json(runtime.artifactSnapshot())
    case "fixture.control":
      return json(runtime.fixtureControl(input.body))
    case "capture.start":
      return json(runtime.startCapture(input.body))
    case "capture.stop":
      return json(runtime.stopCapture())
    case "capture.snapshot":
      return json(runtime.captureSnapshot())
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
