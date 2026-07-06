import Foundation

public enum CommandProposalRouting {
  public static func handle(
    body: Data,
    scopedSessionID: String?,
    sessionExists: (String) -> Bool,
    activeSessionID: () -> String?
  ) -> ControlResponse {
    guard let request = try? JSONDecoder().decode(CommandProposeRequest.self, from: body) else {
      return .error(400, "bad request")
    }
    guard let command = request.command, !command.isEmpty else {
      return .error(400, "missing command")
    }
    guard
      let targetSessionID = request.resolvedTargetSessionID(fallback: scopedSessionID)
        ?? activeSessionID()
    else {
      return .error(400, "no session for propose")
    }
    guard sessionExists(targetSessionID) else {
      return .error(400, "no session for propose")
    }

    let response = CommandProposalService.propose(
      command: command,
      purpose: request.purpose,
      targetSessionID: targetSessionID)
    return ControlResponse.json(response)
  }
}
