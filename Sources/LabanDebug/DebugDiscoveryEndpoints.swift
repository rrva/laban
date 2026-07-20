import Foundation
import LabanControl
import LabanCore

extension DebugDiscoveryEndpoint {
  init(binding: HTTPBinding) {
    self.init(
      method: binding.method,
      path: binding.path,
      category: binding.category,
      summary: binding.summary,
      queryParameters: binding.queryParameters,
      requestSchema: binding.legacyRequestSchemaPath,
      responseSchema: binding.legacyResponseSchemaPath)
  }

  /// The `/debug` discovery endpoint list, sourced from the shared route
  /// catalog so the doc survives `DebugHTTPServer`'s removal byte-stably.
  public static var catalog: [DebugDiscoveryEndpoint] {
    ControlRouteCatalog.endpoints.map { DebugDiscoveryEndpoint(binding: $0.binding) }
  }
}

public enum DebugDiscoveryCatalog {
  public static let actions: [DebugDiscoveryControl] = [
    DebugDiscoveryControl(name: "newTab", summary: "Create and select a new tab."),
    DebugDiscoveryControl(name: "closeTab", summary: "Close a tab by id or the active tab."),
    DebugDiscoveryControl(name: "selectTab", summary: "Select a tab by tabId."),
    DebugDiscoveryControl(
      name: "moveTab",
      summary: "Reorder a tab by id to a new zero-based index (clamped to the tab range)."),
    DebugDiscoveryControl(name: "resizeWindow", summary: "Resize the headless window surface."),
    DebugDiscoveryControl(
      name: "setFontSize",
      summary: "Apply a live font-size zoom step; grid renegotiates at unchanged window pixels."),
    DebugDiscoveryControl(name: "setRenderer", summary: "Switch the headless renderer backend."),
    DebugDiscoveryControl(
      name: "setVectorSubpixelLayout",
      summary: "Set the active vector renderer subpixel layout."),
    DebugDiscoveryControl(name: "typeText", summary: "Send text through terminal input."),
    DebugDiscoveryControl(name: "feedOutput", summary: "Inject fixture terminal output bytes."),
    DebugDiscoveryControl(name: "advanceFrames", summary: "Render one or more additional frames."),
    DebugDiscoveryControl(
      name: "advanceTime",
      summary: "Advance the deterministic virtual clock (glyph-effect channel) and render."),
    DebugDiscoveryControl(
      name: "setGlyphEffectsEnabled",
      summary: "Enable or disable per-glyph effects (ink-bloom, bell shake)."),
    DebugDiscoveryControl(
      name: "setSpinnerMotionSmoothingEnabled",
      summary: "Enable or disable spinner foreground-color motion smoothing."),
    DebugDiscoveryControl(
      name: "resetSpinnerMotionDiagnostics",
      summary: "Reset spinner-motion detector state."),
    DebugDiscoveryControl(name: "key", summary: "Send a structured key event."),
    DebugDiscoveryControl(name: "mouseWheel", summary: "Send a mouse wheel event."),
    DebugDiscoveryControl(name: "mouseDrag", summary: "Send a mouse press-drag-release gesture."),
    DebugDiscoveryControl(name: "click", summary: "Send a click to sidebar or terminal content."),
    DebugDiscoveryControl(name: "setClipboardText", summary: "Set the debug clipboard text."),
    DebugDiscoveryControl(name: "paste", summary: "Paste debug clipboard text into the terminal."),
    DebugDiscoveryControl(
      name: "dropFiles", summary: "Insert dropped file paths into the terminal."),
    DebugDiscoveryControl(name: "copy", summary: "Copy the current terminal selection."),
    DebugDiscoveryControl(name: "setSelection", summary: "Set terminal selection cell anchors."),
    DebugDiscoveryControl(name: "setPreedit", summary: "Set transient IME preedit text."),
    DebugDiscoveryControl(name: "find.start", summary: "Start find in a terminal session."),
    DebugDiscoveryControl(name: "find.step", summary: "Move to the next or previous find match."),
    DebugDiscoveryControl(name: "find.stop", summary: "Stop find and clear match highlights."),
    DebugDiscoveryControl(name: "scrollViewport", summary: "Move terminal scrollback viewport."),
    DebugDiscoveryControl(
      name: "propose",
      summary: "Propose a command for user review; never writes PTY bytes."),
    DebugDiscoveryControl(name: "setTabTitle", summary: "Set a manual tab title."),
    DebugDiscoveryControl(name: "freezeTabTitle", summary: "Freeze or unfreeze title updates."),
    DebugDiscoveryControl(name: "clearTabTitle", summary: "Clear the manual tab title."),
    DebugDiscoveryControl(
      name: "setTabMetadata", summary: "Set workspace, process, or agent metadata."),
    DebugDiscoveryControl(
      name: "setBackgroundTransparency",
      summary: "Set requested terminal opacity and explicit-cell policy."),
    DebugDiscoveryControl(
      name: "resetTransparencyDiagnostics", summary: "Reset transparency diagnostics."),
    DebugDiscoveryControl(
      name: "setReduceTransparencyOverride",
      summary: "Install or remove the diagnostic Reduce Transparency override."),
    DebugDiscoveryControl(
      name: "setBackgroundSource", summary: "Set the requested terminal background source."),
    DebugDiscoveryControl(
      name: "setBackgroundImageScaling", summary: "Set managed image scaling."),
    DebugDiscoveryControl(
      name: "importBackgroundImage",
      summary: "Import a contained fixture image into run-scoped storage."),
    DebugDiscoveryControl(
      name: "removeBackgroundImage", summary: "Remove the run-scoped managed image."),
  ]

  public static let waitConditions: [DebugDiscoveryControl] = [
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

  public static let fixtureActions: [DebugDiscoveryControl] = [
    DebugDiscoveryControl(
      name: "load", summary: "Load a fixture JSON file by relative path under fixtureRoot."),
    DebugDiscoveryControl(name: "restart", summary: "Restart the current fixture from step zero."),
    DebugDiscoveryControl(name: "step", summary: "Apply one or more fixture steps."),
  ]

  public static let examples: [DebugDiscoveryExample] = [
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
          endpoints: DebugDiscoveryEndpoint.catalog,
          actions: DebugDiscoveryCatalog.actions,
          waitConditions: DebugDiscoveryCatalog.waitConditions,
          fixtureActions: DebugDiscoveryCatalog.fixtureActions,
          examples: DebugDiscoveryCatalog.examples
        ))
    }
  }
}
