import Foundation
import LabanCore

extension HeadlessDebugRuntime {
  public func scrollIndicatorState(query: [String: String]) -> DebugResponse {
    withRuntimeLock {
      let response = ControlStateProjections.scrollIndicatorState(
        query: query, ctx: controlProjectionContext())
      return DebugResponse(status: response.status, body: response.body)
    }
  }
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
