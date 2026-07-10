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

    let targetSessionID: String
    if let scopedSessionID {
      // A scoped caller is bound to exactly one session: never fall back to
      // the app's active session, and reject outright if the request asks
      // for a different session than the one it is scoped to.
      let requestedTarget = request.resolvedTargetSessionID(fallback: nil)
      if let requestedTarget, requestedTarget != scopedSessionID {
        return .error(403, "forbidden")
      }
      targetSessionID = scopedSessionID
    } else {
      guard
        let resolved = request.resolvedTargetSessionID(fallback: nil) ?? activeSessionID()
      else {
        return .error(400, "no session for propose")
      }
      targetSessionID = resolved
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

  /// Resolves the session a proposal lifecycle request operates on. A scoped
  /// caller is bound to its own session; a whole-app/fixture caller falls back
  /// to the active session. Returns nil when no session can be resolved.
  private static func resolveScopeSession(
    scopedSessionID: String?,
    activeSessionID: () -> String?
  ) -> String? {
    if let scopedSessionID { return scopedSessionID }
    return activeSessionID()
  }

  /// `commandProposal.list`: proposals targeting the caller's own session,
  /// newest first. Session-scoped; a caller never sees another session's
  /// proposals.
  public static func handleList(
    scopedSessionID: String?,
    activeSessionID: () -> String?,
    store: CommandProposalStore = .shared
  ) -> ControlResponse {
    guard
      let sessionID = resolveScopeSession(
        scopedSessionID: scopedSessionID, activeSessionID: activeSessionID)
    else {
      return .error(400, "no session for proposal list")
    }
    let views = store.list(targetSessionID: sessionID).map(CommandProposalView.init)
    return ControlResponse.json(CommandProposalListResponse(proposals: views))
  }

  /// `commandProposal.get`: one proposal by id, only if it targets the caller's
  /// own session (cross-session -> 403, unknown -> 404).
  public static func handleGet(
    body: Data,
    scopedSessionID: String?,
    activeSessionID: () -> String?,
    store: CommandProposalStore = .shared
  ) -> ControlResponse {
    guard let request = try? JSONDecoder().decode(CommandProposalRefRequest.self, from: body),
      let proposalID = request.resolvedProposalID()
    else {
      return .error(400, "missing proposalID")
    }
    guard
      let sessionID = resolveScopeSession(
        scopedSessionID: scopedSessionID, activeSessionID: activeSessionID)
    else {
      return .error(400, "no session for proposal get")
    }
    guard let proposal = store.proposal(id: proposalID) else {
      return .error(404, "not found")
    }
    guard proposal.targetSessionID == sessionID else {
      return .error(403, "forbidden")
    }
    return ControlResponse.json(CommandProposalView(proposal))
  }

  /// `commandProposal.cancel`: transitions a still-pending proposal to
  /// `cancelledByAgent`. Cross-session -> 403, unknown -> 404, already-terminal
  /// -> 409.
  public static func handleCancel(
    body: Data,
    scopedSessionID: String?,
    activeSessionID: () -> String?,
    store: CommandProposalStore = .shared
  ) -> ControlResponse {
    guard let request = try? JSONDecoder().decode(CommandProposalRefRequest.self, from: body),
      let proposalID = request.resolvedProposalID()
    else {
      return .error(400, "missing proposalID")
    }
    guard
      let sessionID = resolveScopeSession(
        scopedSessionID: scopedSessionID, activeSessionID: activeSessionID)
    else {
      return .error(400, "no session for proposal cancel")
    }
    // Scope-check against the stored proposal before mutating it.
    guard let existing = store.proposal(id: proposalID) else {
      return .error(404, "not found")
    }
    guard existing.targetSessionID == sessionID else {
      return .error(403, "forbidden")
    }
    switch store.cancel(id: proposalID) {
    case .cancelled(let proposal):
      return ControlResponse.json(
        CommandProposalCancelResponse(
          proposalID: proposalID, cancelled: true, state: proposal.state))
    case .alreadyTerminal(let state):
      return .error(409, "proposal already \(state.rawValue)")
    case .notFound:
      return .error(404, "not found")
    }
  }
}
