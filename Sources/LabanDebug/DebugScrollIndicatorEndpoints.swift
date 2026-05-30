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
        isAltScreen: vs.altScreen
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
