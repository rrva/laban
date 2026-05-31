import Foundation
import LabanCore

/// Read-only debug surface for the overlay scroll indicator. Lets
/// capture/replay tests assert "after scrolling N rows, the pill reads
/// '42 / 976'" without needing a screenshot harness, and gives the same
/// answers the AppKit view paints (it shares the `decide()` function).
extension HeadlessDebugRuntime {
  public func scrollIndicatorState(query: [String: String]) -> DebugResponse {
    withRuntimeLock {
      let requested = query["sessionID"] ?? query["sessionId"]
      let targetTab: Tab? = {
        if let requested,
          let tab = model.tabs.first(where: { $0.sessionId == requested })
        {
          return tab
        }
        if requested != nil { return nil }
        return model.activeTab
      }()
      guard let tab = targetTab, let session = model.session(forTab: tab.id) else {
        return jsonError("session not found", status: 404)
      }
      guard let vs = session.viewportState() else {
        return jsonEncode(
          ScrollIndicatorStateResponse(available: false, input: nil, output: nil))
      }
      let hover = (query["hover"] ?? "false").lowercased() == "true"
      let input = TerminalScrollIndicator.Input(
        viewportOffset: vs.viewportOffset,
        totalRows: vs.totalRows,
        viewportRows: vs.viewportRows,
        isHoverEdge: hover,
        isAltScreen: vs.altScreen,
        isMouseTracking: vs.mouseTracking
      )
      let output = TerminalScrollIndicator.decide(input)
      return jsonEncode(
        ScrollIndicatorStateResponse(available: true, input: input, output: output))
    }
  }
}

struct ScrollIndicatorStateResponse: Encodable {
  var available: Bool
  var input: TerminalScrollIndicator.Input?
  var output: TerminalScrollIndicator.Output?
}

/// Parity surface for the live `ScrollDebugServer` trace endpoint: exposes the
/// process-wide `ScrollDiagnostics` event ring so capture/replay and headless
/// runs can assert on the viewport time-series the same way a headful
/// `--scroll-debug` session inspects it.
extension HeadlessDebugRuntime {
  public func scrollTrace(query: [String: String]) -> DebugResponse {
    let events = ScrollDiagnostics.shared.snapshot()
    if query["clear"] == "1" { ScrollDiagnostics.shared.clear() }
    return jsonEncode(ScrollTraceResponse(count: events.count, events: events))
  }
}

struct ScrollTraceResponse: Encodable {
  var count: Int
  var events: [ScrollDiagnostics.Event]
}
