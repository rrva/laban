import Foundation
import LabanCore

struct DebugCommandProposalActions {
  private unowned let runtime: HeadlessDebugRuntime

  init(runtime: HeadlessDebugRuntime) {
    self.runtime = runtime
  }

  func propose(_ request: CommandProposeRequest, scopedSessionID: String?) -> DebugResponse {
    guard let command = request.command, !command.isEmpty else {
      return jsonError("missing command")
    }
    guard
      let targetSessionID = request.resolvedTargetSessionID(fallback: scopedSessionID)
        ?? runtime.model.activeTab?.sessionId
    else {
      return jsonError("no session for propose")
    }
    guard runtime.model.tabs.contains(where: { $0.sessionId == targetSessionID }) else {
      return jsonError("no session for propose")
    }

    let response = CommandProposalService.propose(
      command: command,
      purpose: request.purpose,
      targetSessionID: targetSessionID)
    runtime.appendEvent(
      EventEntry(
        kind: "command.proposed",
        sessionId: targetSessionID,
        action: response.proposalID))
    return jsonEncode(response)
  }
}
