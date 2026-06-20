import Foundation
import LabanCore

struct ControlHTTPRequest {
  let method: String
  let path: String
  let query: [String: String]
  let pathParameters: [String: String]
  let body: Data
}

enum ControlRouteResolution {
  case resolved(String)
  case failed(ControlResponse)
}

struct ControlRoute {
  let endpoint: ControlEndpointDescriptor
  let resolveIntentID: (ControlHTTPRequest) -> ControlRouteResolution
  let dispatch: (LabanControlServer, ControlHTTPRequest) -> ControlResponse

  func match(method: String, path: String) -> [String: String]? {
    guard endpoint.binding.method == method else { return nil }

    let patternSegments = endpoint.binding.path.split(
      separator: "/", omittingEmptySubsequences: false)
    let pathSegments = path.split(separator: "/", omittingEmptySubsequences: false)
    guard patternSegments.count == pathSegments.count else { return nil }

    var parameters: [String: String] = [:]
    for (patternSegment, pathSegment) in zip(patternSegments, pathSegments) {
      let pattern = String(patternSegment)
      let value = String(pathSegment)
      if pattern.hasPrefix("<"), pattern.hasSuffix(">") {
        let name = String(pattern.dropFirst().dropLast())
        parameters[name] = value.removingPercentEncoding ?? value
        continue
      }
      guard pattern == value else { return nil }
    }
    return parameters
  }
}

public enum ControlRouteCatalog {
  public static let endpoints: [ControlEndpointDescriptor] = [
    endpoint(
      method: "GET",
      path: "/debug",
      category: "discovery",
      summary: "List the live debug endpoints, controls, and command examples.",
      responseSchema: "schemas/debug/discovery.schema.json",
      intentID: "debug.discovery"),
    endpoint(
      method: "GET",
      path: "/debug/capabilities",
      category: "discovery",
      summary: "Alias for /debug for agents that look for a capabilities document.",
      responseSchema: "schemas/debug/discovery.schema.json",
      intentID: "debug.capabilities"),
    endpoint(
      method: "GET",
      path: "/debug/health",
      category: "readiness",
      summary: "Check whether the process is ready and report the current frame.",
      intentID: "debug.health"),
    endpoint(
      method: "GET",
      path: "/debug/state",
      category: "state",
      summary: "Return tabs, active session identity, window size, and focus state.",
      responseSchema: "schemas/debug/state.schema.json",
      intentID: "app.state"),
    endpoint(
      method: "GET",
      path: "/debug/accessibility",
      category: "state",
      summary: "Return terminal accessibility role, label, value, focus ring, and display flags.",
      intentID: "app.accessibility"),
    endpoint(
      method: "GET",
      path: "/debug/terminal-modes",
      category: "state",
      summary:
        "Return active-session DEC private mode state (grapheme cluster 2027, sync output, focus, mouse).",
      intentID: "terminal.modes"),
    endpoint(
      method: "GET",
      path: "/debug/screenshot",
      category: "artifacts",
      summary: "Return the current rendered surface as PNG bytes.",
      intentID: "artifact.screenshot"),
    endpoint(
      method: "POST",
      path: "/debug/screenshot",
      category: "artifacts",
      summary: "Write a screenshot PNG under the artifact directory.",
      responseSchema: "schemas/debug/screenshot-result.schema.json",
      intentID: "artifact.screenshot.write"),
    ControlEndpointDescriptor(
      binding: HTTPBinding(
        method: "POST",
        path: "/debug/actions",
        category: "control",
        summary: "Drive tabs, input, mouse, clipboard, selection, and frames.",
        legacyRequestSchemaPath: "schemas/debug/action.schema.json",
        legacyResponseSchemaPath: "schemas/debug/action-result.schema.json"),
      intentMapping: .requestBodyField("action")),
    endpoint(
      method: "GET",
      path: "/debug/persistence/state",
      category: "state",
      summary: "Inspect workspace.json, transcript files, and agent JSONL mirrors.",
      intentID: "persistence.state"),
    endpoint(
      method: "POST",
      path: "/debug/persistence/flush",
      category: "control",
      summary:
        "Drain the persistence debounce + transcript writers synchronously (simulates applicationWillTerminate).",
      intentID: "persistence.flush"),
    endpoint(
      method: "POST",
      path: "/debug/persistence/relaunch",
      category: "control",
      summary:
        "Flush, close every session, then rebuild from workspace.json. Use to run quit/restore cycles inside one debug-server lifetime.",
      intentID: "persistence.relaunch"),
    endpoint(
      method: "GET",
      path: "/debug/persistence/restore-picker",
      category: "state",
      summary:
        "Return pending Claude/Codex semantic restore candidates after a laband daemon-loss restore.",
      intentID: "persistence.restorePicker"),
    endpoint(
      method: "POST",
      path: "/debug/persistence/restore-picker/select",
      category: "control",
      summary:
        "Launch selected Claude/Codex semantic restores through the native resume trampoline.",
      intentID: "persistence.restorePicker.select"),
    endpoint(
      method: "POST",
      path: "/debug/find/start",
      category: "control",
      summary: "Start literal find in the active or named terminal session.",
      requestSchema: "schemas/debug/find-start.schema.json",
      responseSchema: "schemas/debug/find-state.schema.json",
      intentID: "find.start"),
    endpoint(
      method: "POST",
      path: "/debug/find/step",
      category: "control",
      summary: "Advance the selected find match in the active or named terminal session.",
      requestSchema: "schemas/debug/find-step.schema.json",
      responseSchema: "schemas/debug/find-state.schema.json",
      intentID: "find.step"),
    endpoint(
      method: "POST",
      path: "/debug/find/stop",
      category: "control",
      summary: "Stop find and clear highlights in the active or named terminal session.",
      requestSchema: "schemas/debug/find-stop.schema.json",
      intentID: "find.stop"),
    endpoint(
      method: "GET",
      path: "/debug/find/state",
      category: "state",
      summary: "Return current find state for the active or named terminal session.",
      queryParameters: ["sessionID", "sessionId"],
      responseSchema: "schemas/debug/find-state.schema.json",
      intentID: "find.state"),
    endpoint(
      method: "GET",
      path: "/debug/shell-integration/state",
      category: "state",
      summary:
        "Return OSC 133 shell-integration phase + last exit code for the active or named session.",
      queryParameters: ["sessionID", "sessionId"],
      responseSchema: "schemas/debug/shell-integration-state.schema.json",
      intentID: "shellIntegration.state"),
    endpoint(
      method: "GET",
      path: "/debug/scroll-indicator/state",
      category: "state",
      summary:
        "Return overlay scroll indicator input/output (shouldHold, pill text, thumb geometry) for the active or named session. Accepts hover=true to simulate the right-edge hover-reveal.",
      queryParameters: ["sessionID", "sessionId", "hover"],
      responseSchema: "schemas/debug/scroll-indicator-state.schema.json",
      intentID: "scrollIndicator.state"),
    endpoint(
      method: "GET",
      path: "/debug/scroll-trace",
      category: "state",
      summary:
        "Return the ScrollDiagnostics event ring (viewport samples, labpty feeds, scroll/snap events) recorded since --scroll-debug / LABAN_SCROLL_DEBUG armed it. Accepts clear=1 to drain the ring after reading.",
      queryParameters: ["clear"],
      intentID: "scrollTrace"),
    endpoint(
      method: "POST",
      path: "/debug/wait",
      category: "control",
      summary: "Block until a frame, state, text, event, or render condition is true.",
      requestSchema: "schemas/debug/wait.schema.json",
      responseSchema: "schemas/debug/wait-result.schema.json",
      intentID: "wait.condition"),
    endpoint(
      method: "GET",
      path: "/debug/sessions",
      category: "state",
      summary: "Return terminal-session lifecycle and metadata for all tabs.",
      responseSchema: "schemas/debug/sessions.schema.json",
      intentID: "session.list"),
    endpoint(
      method: "GET",
      path: "/debug/sessions/<id>",
      category: "state",
      summary: "Return one terminal session, optionally with bounded visible-grid cells.",
      queryParameters: ["includeGrid"],
      responseSchema: "schemas/debug/session.schema.json",
      intentID: "session.detail"),
    endpoint(
      method: "GET",
      path: "/debug/render",
      category: "rendering",
      summary: "Return surface, viewport, cell size, damage, and draw stats.",
      responseSchema: "schemas/debug/render.schema.json",
      intentID: "render.state"),
    endpoint(
      method: "GET",
      path: "/debug/frame-commands",
      category: "rendering",
      summary: "Return bounded frame commands, optionally filtered by source.",
      queryParameters: ["source", "limit"],
      responseSchema: "schemas/debug/frame-commands.schema.json",
      intentID: "render.frameCommands"),
    endpoint(
      method: "POST",
      path: "/debug/render-trace",
      category: "rendering",
      summary: "Return render contributors, resources, passes, probes, and invariants.",
      requestSchema: "schemas/debug/render-trace-request.schema.json",
      responseSchema: "schemas/debug/render-trace.schema.json",
      intentID: "render.trace"),
    endpoint(
      method: "POST",
      path: "/debug/pixel-probe",
      category: "exploration",
      summary: "Sample exact pixels and rectangular regions from the rendered surface.",
      requestSchema: "schemas/debug/pixel-probe.schema.json",
      responseSchema: "schemas/debug/pixel-probe-result.schema.json",
      intentID: "render.pixelProbe"),
    endpoint(
      method: "GET",
      path: "/debug/atlas",
      category: "rendering",
      summary: "Return font, cell, and glyph diagnostics for the active renderer.",
      responseSchema: "schemas/debug/atlas.schema.json",
      intentID: "render.atlas"),
    endpoint(
      method: "POST",
      path: "/debug/snapshot",
      category: "exploration",
      summary: "Write a one-shot diagnostic bundle with JSON state and a screenshot.",
      responseSchema: "schemas/debug/snapshot-result.schema.json",
      intentID: "artifact.snapshot"),
    endpoint(
      method: "GET",
      path: "/debug/events",
      category: "logs",
      summary: "Return bounded app/debug events after a sequence number.",
      queryParameters: ["since"],
      responseSchema: "schemas/debug/events.schema.json",
      intentID: "log.events"),
    endpoint(
      method: "GET",
      path: "/debug/tab-journal",
      category: "logs",
      summary:
        "Return the bounded journal of per-tab visible state transitions after a sequence number.",
      queryParameters: ["since", "tabId"],
      responseSchema: "schemas/debug/tab-journal.schema.json",
      intentID: "log.tabJournal"),
    endpoint(
      method: "GET",
      path: "/debug/input-log",
      category: "logs",
      summary: "Return keyboard/text routing diagnostics after a sequence number.",
      queryParameters: ["since"],
      responseSchema: "schemas/debug/input-log.schema.json",
      intentID: "log.input"),
    endpoint(
      method: "GET",
      path: "/debug/terminal-log",
      category: "logs",
      summary: "Return bounded escaped terminal input/output byte-flow diagnostics.",
      queryParameters: ["sessionId", "since", "limit"],
      responseSchema: "schemas/debug/terminal-log.schema.json",
      intentID: "log.terminal"),
    endpoint(
      method: "GET",
      path: "/debug/timing",
      category: "logs",
      summary: "Return frame and endpoint timing fields for sluggishness diagnosis.",
      responseSchema: "schemas/debug/timing.schema.json",
      intentID: "log.timing"),
    endpoint(
      method: "GET",
      path: "/debug/metrics",
      category: "logs",
      summary: "Return local counters for frames, input, terminal bytes, and draw work.",
      responseSchema: "schemas/debug/metrics.schema.json",
      intentID: "log.metrics"),
    endpoint(
      method: "GET",
      path: "/debug/errors",
      category: "logs",
      summary: "Return structured warnings and errors after a sequence number.",
      queryParameters: ["since"],
      responseSchema: "schemas/debug/errors.schema.json",
      intentID: "log.errors"),
    endpoint(
      method: "POST",
      path: "/debug/fixture",
      category: "control",
      summary: "Load, restart, or step fixture sessions without restarting the server.",
      requestSchema: "schemas/debug/fixture-control.schema.json",
      responseSchema: "schemas/debug/fixture-control.schema.json",
      intentID: "fixture.control"),
    endpoint(
      method: "GET",
      path: "/debug/capture/status",
      category: "capture",
      summary: "Return whether full capture recording is active.",
      intentID: "capture.status"),
    endpoint(
      method: "POST",
      path: "/debug/capture/start",
      category: "capture",
      summary: "Start full capture recording under the artifact directory.",
      intentID: "capture.start"),
    endpoint(
      method: "POST",
      path: "/debug/capture/stop",
      category: "capture",
      summary: "Stop full capture recording and return manifest metadata.",
      intentID: "capture.stop"),
    endpoint(
      method: "POST",
      path: "/debug/capture/snapshot",
      category: "capture",
      summary: "Write a snapshot inside the active capture run.",
      intentID: "capture.snapshot"),
    endpoint(
      method: "GET",
      path: "/debug/cast/recent",
      category: "capture",
      summary: "Snapshot the last N seconds of a tab's PTY output as an asciinema v2 cast.",
      queryParameters: ["seconds", "tabId"],
      intentID: "cast.recent"),
    endpoint(
      method: "GET",
      path: "/debug/selection",
      category: "state",
      summary: "Return the current terminal selection projection.",
      responseSchema: "schemas/debug/selection.schema.json",
      intentID: "selection.read"),
    endpoint(
      method: "GET",
      path: "/debug/clipboard",
      category: "state",
      summary: "Return debug clipboard copy/paste diagnostics.",
      responseSchema: "schemas/debug/clipboard.schema.json",
      intentID: "clipboard.read"),
  ]

  public static let bindings: [HTTPBinding] = endpoints.map(\.binding)

  static let routes: [ControlRoute] =
    [
      ControlRoute(
        endpoint: endpoint(for: "GET", "/debug/state"),
        resolveIntentID: { _ in .resolved("app.state") },
        dispatch: { server, _ in server.router.query(.state) })
    ]
    + legacyJSONReadRoutes
    + legacyJSONControlRoutes
    + [
      ControlRoute(
        endpoint: endpoint(for: "GET", "/debug/sessions/<id>"),
        resolveIntentID: { _ in .resolved("session.detail") },
        dispatch: { server, request in
          var params = request.query
          params["sessionId"] = request.pathParameters["id"] ?? ""
          return server.router.query(
            LegacyDebugQueryInput(intentID: "session.detail", params: params))
        }),
      ControlRoute(
        endpoint: endpoint(for: "GET", "/debug/screenshot"),
        resolveIntentID: { _ in .resolved("artifact.screenshot") },
        dispatch: { server, request in
          server.router.artifact(
            ArtifactRequest(id: "artifact.screenshot", params: request.query))
            ?? .error(501, "not yet ported")
        }),
      ControlRoute(
        endpoint: endpoint(for: "GET", "/debug/cast/recent"),
        resolveIntentID: { _ in .resolved("cast.recent") },
        dispatch: { server, request in
          server.router.artifact(ArtifactRequest(id: "cast.recent", params: request.query))
            ?? .error(501, "not yet ported")
        }),
      ControlRoute(
        endpoint: endpoint(for: "POST", "/debug/actions"),
        resolveIntentID: resolveActionIntentID,
        dispatch: { server, request in server.dispatchDebugAction(request) }),
    ]

  private static let legacyJSONReadRoutePaths: [(method: String, path: String)] = [
    ("GET", "/debug"),
    ("GET", "/debug/capabilities"),
    ("GET", "/debug/health"),
    ("GET", "/debug/accessibility"),
    ("GET", "/debug/terminal-modes"),
    ("GET", "/debug/persistence/state"),
    ("GET", "/debug/persistence/restore-picker"),
    ("GET", "/debug/find/state"),
    ("GET", "/debug/shell-integration/state"),
    ("GET", "/debug/scroll-indicator/state"),
    ("GET", "/debug/scroll-trace"),
    ("GET", "/debug/sessions"),
    ("GET", "/debug/render"),
    ("GET", "/debug/frame-commands"),
    ("GET", "/debug/atlas"),
    ("GET", "/debug/events"),
    ("GET", "/debug/tab-journal"),
    ("GET", "/debug/input-log"),
    ("GET", "/debug/terminal-log"),
    ("GET", "/debug/timing"),
    ("GET", "/debug/metrics"),
    ("GET", "/debug/errors"),
    ("GET", "/debug/capture/status"),
    ("GET", "/debug/selection"),
    ("GET", "/debug/clipboard"),
  ]

  private static var legacyJSONReadRoutes: [ControlRoute] {
    legacyJSONReadRoutePaths.map { method, path in
      let endpoint = endpoint(for: method, path)
      return ControlRoute(
        endpoint: endpoint,
        resolveIntentID: { _ in
          guard let intentID = endpoint.fixedIntentId else {
            return .failed(.error(500, "missing intent mapping"))
          }
          return .resolved(intentID)
        },
        dispatch: { server, request in
          guard let intentID = endpoint.fixedIntentId else {
            return .error(500, "missing intent mapping")
          }
          return server.router.query(
            LegacyDebugQueryInput(intentID: intentID, params: request.query))
        })
    }
  }

  private static let legacyJSONControlRoutePaths: [(method: String, path: String)] = [
    ("POST", "/debug/screenshot"),
    ("POST", "/debug/persistence/flush"),
    ("POST", "/debug/persistence/relaunch"),
    ("POST", "/debug/persistence/restore-picker/select"),
    ("POST", "/debug/find/start"),
    ("POST", "/debug/find/step"),
    ("POST", "/debug/find/stop"),
    ("POST", "/debug/wait"),
    ("POST", "/debug/render-trace"),
    ("POST", "/debug/pixel-probe"),
    ("POST", "/debug/snapshot"),
    ("POST", "/debug/fixture"),
    ("POST", "/debug/capture/start"),
    ("POST", "/debug/capture/stop"),
    ("POST", "/debug/capture/snapshot"),
  ]

  private static var legacyJSONControlRoutes: [ControlRoute] {
    legacyJSONControlRoutePaths.map { method, path in
      let endpoint = endpoint(for: method, path)
      return ControlRoute(
        endpoint: endpoint,
        resolveIntentID: { _ in
          guard let intentID = endpoint.fixedIntentId else {
            return .failed(.error(500, "missing intent mapping"))
          }
          return .resolved(intentID)
        },
        dispatch: { server, request in
          guard let intentID = endpoint.fixedIntentId else {
            return .error(500, "missing intent mapping")
          }
          return server.router.control(
            LegacyDebugControlInput(
              intentID: intentID,
              body: request.body,
              params: request.query))
        })
    }
  }

  private static func endpoint(
    method: String,
    path: String,
    category: String,
    summary: String,
    queryParameters: [String] = [],
    requestSchema: String? = nil,
    responseSchema: String? = nil,
    intentID: String
  ) -> ControlEndpointDescriptor {
    ControlEndpointDescriptor(
      binding: HTTPBinding(
        method: method,
        path: path,
        category: category,
        summary: summary,
        queryParameters: queryParameters,
        legacyRequestSchemaPath: requestSchema,
        legacyResponseSchemaPath: responseSchema),
      intentMapping: .fixed(intentID))
  }

  private static func endpoint(for method: String, _ path: String) -> ControlEndpointDescriptor {
    guard
      let endpoint = endpoints.first(where: {
        $0.binding.method == method && $0.binding.path == path
      })
    else {
      preconditionFailure("missing control endpoint \(method) \(path)")
    }
    return endpoint
  }

  private static func resolveActionIntentID(
    _ request: ControlHTTPRequest
  ) -> ControlRouteResolution {
    guard let envelope = try? JSONDecoder().decode(DebugActionEnvelope.self, from: request.body)
    else {
      return .failed(.error(400, "bad request"))
    }
    return .resolved(
      DebugActionIntentID.intentID(forAction: envelope.action) ?? DebugActionIntentID.unsupported)
  }
}
