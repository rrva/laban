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
    guard command.utf8.count <= CommandProposalStore.maxCommandBytes else {
      return .error(413, "command too large")
    }
    if let purpose = request.purpose, purpose.utf8.count > CommandProposalStore.maxPurposeBytes {
      return .error(413, "purpose too large")
    }

    let response: CommandProposeResponse
    do {
      response = try CommandProposalService.propose(
        command: command,
        purpose: request.purpose,
        targetSessionID: targetSessionID)
    } catch CommandProposalStore.SubmitError.storeFull {
      return .error(429, "too many proposals")
    } catch CommandProposalStore.SubmitError.commandTooLarge {
      return .error(413, "command too large")
    } catch CommandProposalStore.SubmitError.purposeTooLarge {
      return .error(413, "purpose too large")
    } catch {
      return .error(500, "internal error")
    }
    return ControlResponse.json(response)
  }
}
