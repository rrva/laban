import Foundation
import LabanCore

extension HeadlessDebugRuntime {
  public func getText(query: [String: String]) -> DebugResponse {
    withRuntimeLock {
      syncSessionMetadataUnlocked()
      refreshTerminalClientSessionInfoUnlocked()
      let response = ControlStateProjections.getTextResponse(
        query: query, ctx: controlProjectionContext())
      return DebugResponse(status: response.status, body: response.body)
    }
  }
}
