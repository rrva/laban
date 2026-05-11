import Foundation

enum DebugDiscoveryCatalog {
  static let endpoints: [DebugDiscoveryEndpoint] = [
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug",
      category: "discovery",
      summary: "List the live debug endpoints, controls, and command examples.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: "schemas/debug/discovery.schema.json"),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/capabilities",
      category: "discovery",
      summary: "Alias for /debug for agents that look for a capabilities document.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: "schemas/debug/discovery.schema.json"),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/health",
      category: "readiness",
      summary: "Check whether the process is ready and report the current frame.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: nil),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/state",
      category: "state",
      summary: "Return tabs, active session identity, window size, and focus state.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: "schemas/debug/state.schema.json"),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/screenshot",
      category: "artifacts",
      summary: "Return the current rendered surface as PNG bytes.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: nil),
    DebugDiscoveryEndpoint(
      method: "POST",
      path: "/debug/screenshot",
      category: "artifacts",
      summary: "Write a screenshot PNG under the artifact directory.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: "schemas/debug/screenshot-result.schema.json"),
    DebugDiscoveryEndpoint(
      method: "POST",
      path: "/debug/actions",
      category: "control",
      summary: "Drive tabs, input, mouse, clipboard, selection, and frames.",
      queryParameters: [],
      requestSchema: "schemas/debug/action.schema.json",
      responseSchema: "schemas/debug/action-result.schema.json"),
    DebugDiscoveryEndpoint(
      method: "POST",
      path: "/debug/wait",
      category: "control",
      summary: "Block until a frame, state, text, event, or render condition is true.",
      queryParameters: [],
      requestSchema: "schemas/debug/wait.schema.json",
      responseSchema: "schemas/debug/wait-result.schema.json"),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/sessions",
      category: "state",
      summary: "Return terminal-session lifecycle and metadata for all tabs.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: "schemas/debug/sessions.schema.json"),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/sessions/<id>",
      category: "state",
      summary: "Return one terminal session, optionally with bounded visible-grid cells.",
      queryParameters: ["includeGrid"],
      requestSchema: nil,
      responseSchema: "schemas/debug/session.schema.json"),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/render",
      category: "rendering",
      summary: "Return surface, viewport, cell size, damage, and draw stats.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: "schemas/debug/render.schema.json"),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/frame-commands",
      category: "rendering",
      summary: "Return bounded frame commands, optionally filtered by source.",
      queryParameters: ["source", "limit"],
      requestSchema: nil,
      responseSchema: "schemas/debug/frame-commands.schema.json"),
    DebugDiscoveryEndpoint(
      method: "POST",
      path: "/debug/render-trace",
      category: "rendering",
      summary: "Return render contributors, resources, passes, probes, and invariants.",
      queryParameters: [],
      requestSchema: "schemas/debug/render-trace-request.schema.json",
      responseSchema: "schemas/debug/render-trace.schema.json"),
    DebugDiscoveryEndpoint(
      method: "POST",
      path: "/debug/pixel-probe",
      category: "exploration",
      summary: "Sample exact pixels and rectangular regions from the rendered surface.",
      queryParameters: [],
      requestSchema: "schemas/debug/pixel-probe.schema.json",
      responseSchema: "schemas/debug/pixel-probe-result.schema.json"),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/atlas",
      category: "rendering",
      summary: "Return font, cell, and glyph diagnostics for the active renderer.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: "schemas/debug/atlas.schema.json"),
    DebugDiscoveryEndpoint(
      method: "POST",
      path: "/debug/snapshot",
      category: "exploration",
      summary: "Write a one-shot diagnostic bundle with JSON state and a screenshot.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: "schemas/debug/snapshot-result.schema.json"),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/events",
      category: "logs",
      summary: "Return bounded app/debug events after a sequence number.",
      queryParameters: ["since"],
      requestSchema: nil,
      responseSchema: "schemas/debug/events.schema.json"),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/input-log",
      category: "logs",
      summary: "Return keyboard/text routing diagnostics after a sequence number.",
      queryParameters: ["since"],
      requestSchema: nil,
      responseSchema: "schemas/debug/input-log.schema.json"),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/terminal-log",
      category: "logs",
      summary: "Return bounded escaped terminal input/output byte-flow diagnostics.",
      queryParameters: ["sessionId", "since", "limit"],
      requestSchema: nil,
      responseSchema: "schemas/debug/terminal-log.schema.json"),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/timing",
      category: "logs",
      summary: "Return frame and endpoint timing fields for sluggishness diagnosis.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: "schemas/debug/timing.schema.json"),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/metrics",
      category: "logs",
      summary: "Return local counters for frames, input, terminal bytes, and draw work.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: "schemas/debug/metrics.schema.json"),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/errors",
      category: "logs",
      summary: "Return structured warnings and errors after a sequence number.",
      queryParameters: ["since"],
      requestSchema: nil,
      responseSchema: "schemas/debug/errors.schema.json"),
    DebugDiscoveryEndpoint(
      method: "POST",
      path: "/debug/fixture",
      category: "control",
      summary: "Load, restart, or step fixture sessions without restarting the server.",
      queryParameters: [],
      requestSchema: "schemas/debug/fixture-control.schema.json",
      responseSchema: "schemas/debug/fixture-control.schema.json"),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/capture/status",
      category: "capture",
      summary: "Return whether full capture recording is active.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: nil),
    DebugDiscoveryEndpoint(
      method: "POST",
      path: "/debug/capture/start",
      category: "capture",
      summary: "Start full capture recording under the artifact directory.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: nil),
    DebugDiscoveryEndpoint(
      method: "POST",
      path: "/debug/capture/stop",
      category: "capture",
      summary: "Stop full capture recording and return manifest metadata.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: nil),
    DebugDiscoveryEndpoint(
      method: "POST",
      path: "/debug/capture/snapshot",
      category: "capture",
      summary: "Write a snapshot inside the active capture run.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: nil),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/selection",
      category: "state",
      summary: "Return the current terminal selection projection.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: "schemas/debug/selection.schema.json"),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/clipboard",
      category: "state",
      summary: "Return debug clipboard copy/paste diagnostics.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: "schemas/debug/clipboard.schema.json"),
  ]

  static let actions: [DebugDiscoveryControl] = [
    DebugDiscoveryControl(name: "newTab", summary: "Create and select a new tab."),
    DebugDiscoveryControl(name: "closeTab", summary: "Close a tab by id or the active tab."),
    DebugDiscoveryControl(name: "selectTab", summary: "Select a tab by tabId."),
    DebugDiscoveryControl(name: "resizeWindow", summary: "Resize the headless window surface."),
    DebugDiscoveryControl(name: "typeText", summary: "Send text through terminal input."),
    DebugDiscoveryControl(name: "feedOutput", summary: "Inject fixture terminal output bytes."),
    DebugDiscoveryControl(name: "advanceFrames", summary: "Render one or more additional frames."),
    DebugDiscoveryControl(name: "key", summary: "Send a structured key event."),
    DebugDiscoveryControl(name: "mouseWheel", summary: "Send a mouse wheel event."),
    DebugDiscoveryControl(name: "click", summary: "Send a click to sidebar or terminal content."),
    DebugDiscoveryControl(name: "setClipboardText", summary: "Set the debug clipboard text."),
    DebugDiscoveryControl(name: "paste", summary: "Paste debug clipboard text into the terminal."),
    DebugDiscoveryControl(name: "copy", summary: "Copy the current terminal selection."),
    DebugDiscoveryControl(name: "setSelection", summary: "Set terminal selection cell anchors."),
    DebugDiscoveryControl(name: "scrollViewport", summary: "Move terminal scrollback viewport."),
    DebugDiscoveryControl(name: "setTabTitle", summary: "Set a manual tab title."),
    DebugDiscoveryControl(name: "freezeTabTitle", summary: "Freeze or unfreeze title updates."),
    DebugDiscoveryControl(name: "clearTabTitle", summary: "Clear the manual tab title."),
    DebugDiscoveryControl(
      name: "setTabMetadata", summary: "Set workspace, process, or agent metadata."),
  ]

  static let waitConditions: [DebugDiscoveryControl] = [
    DebugDiscoveryControl(name: "frameAtLeast", summary: "Wait until frame is at least a value."),
    DebugDiscoveryControl(name: "tabCount", summary: "Wait until a tab count is reached."),
    DebugDiscoveryControl(name: "activeTab", summary: "Wait until a tab is active."),
    DebugDiscoveryControl(name: "sessionStatus", summary: "Wait for a session status."),
    DebugDiscoveryControl(name: "titleEquals", summary: "Wait for the active title."),
    DebugDiscoveryControl(
      name: "textVisible", summary: "Wait until visible terminal text appears."),
    DebugDiscoveryControl(name: "renderCommandSeen", summary: "Wait for a render command kind."),
    DebugDiscoveryControl(name: "eventSeen", summary: "Wait for an event kind."),
    DebugDiscoveryControl(
      name: "renderTraceInvariant",
      summary: "Wait for a render-trace invariant level and kind."),
  ]

  static let fixtureActions: [DebugDiscoveryControl] = [
    DebugDiscoveryControl(
      name: "load", summary: "Load a fixture JSON file by relative path under fixtureRoot."),
    DebugDiscoveryControl(name: "restart", summary: "Restart the current fixture from step zero."),
    DebugDiscoveryControl(name: "step", summary: "Apply one or more fixture steps."),
  ]

  static let examples: [DebugDiscoveryExample] = [
    DebugDiscoveryExample(
      title: "List capabilities",
      command: #"curl -H "Authorization: Bearer $DEBUG_TOKEN" "$DEBUG_URL/debug" | jq"#),
    DebugDiscoveryExample(
      title: "Type text",
      command:
        #"curl -H "Authorization: Bearer $DEBUG_TOKEN" -X POST "$DEBUG_URL/debug/actions" -d @action.json"#
    ),
    DebugDiscoveryExample(
      title: "Wait for visible text",
      command:
        #"curl -H "Authorization: Bearer $DEBUG_TOKEN" -X POST "$DEBUG_URL/debug/wait" -d @wait.json"#
    ),
    DebugDiscoveryExample(
      title: "Write a diagnostic bundle",
      command:
        #"curl -H "Authorization: Bearer $DEBUG_TOKEN" -X POST "$DEBUG_URL/debug/snapshot" -d '{}'"#
    ),
  ]
}

extension HeadlessDebugRuntime {
  public func health() -> DebugResponse {
    withRuntimeLock {
      jsonEncode(HealthResponse(ok: true, mode: mode, frame: currentFrame, focused: true))
    }
  }

  public func discovery() -> DebugResponse {
    withRuntimeLock {
      jsonEncode(
        DebugDiscoveryResponse(
          name: "laban-debug",
          schema: "schemas/debug/discovery.schema.json",
          runId: runId,
          mode: mode,
          frame: currentFrame,
          artifactRoot: artifactsURL.path,
          fixtureRoot: fixtureRootURL.path,
          entrypoints: ["/debug", "/debug/capabilities"],
          endpoints: DebugDiscoveryCatalog.endpoints,
          actions: DebugDiscoveryCatalog.actions,
          waitConditions: DebugDiscoveryCatalog.waitConditions,
          fixtureActions: DebugDiscoveryCatalog.fixtureActions,
          examples: DebugDiscoveryCatalog.examples
        ))
    }
  }
}
