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

    do {
      let response = try CommandProposalService.propose(
        command: command,
        purpose: request.purpose,
        targetSessionID: targetSessionID)
      runtime.appendEvent(
        EventEntry(
          kind: "command.proposed",
          sessionId: targetSessionID,
          action: response.proposalID))
      return jsonEncode(response)
    } catch CommandProposalStore.SubmitError.commandTooLarge {
      return jsonError("command too large")
    } catch CommandProposalStore.SubmitError.purposeTooLarge {
      return jsonError("purpose too large")
    } catch CommandProposalStore.SubmitError.storeFull {
      return jsonError("too many proposals")
    } catch {
      return jsonError("propose failed")
    }
  }

  func list(scopedSessionID: String?) -> DebugResponse {
    Self.asDebugResponse(
      CommandProposalRouting.handleList(
        scopedSessionID: scopedSessionID,
        activeSessionID: { runtime.model.activeTab?.sessionId }))
  }

  func get(_ request: CommandProposalRefRequest, scopedSessionID: String?) -> DebugResponse {
    Self.asDebugResponse(
      CommandProposalRouting.handleGet(
        body: Self.encodeBody(request),
        scopedSessionID: scopedSessionID,
        activeSessionID: { runtime.model.activeTab?.sessionId }))
  }

  func cancel(_ request: CommandProposalRefRequest, scopedSessionID: String?) -> DebugResponse {
    let response = CommandProposalRouting.handleCancel(
      body: Self.encodeBody(request),
      scopedSessionID: scopedSessionID,
      activeSessionID: { runtime.model.activeTab?.sessionId })
    if response.status == 200,
      let proposalID = request.resolvedProposalID()
    {
      runtime.appendEvent(
        EventEntry(
          kind: "command.proposal.cancelled",
          sessionId: scopedSessionID,
          action: proposalID))
    }
    return Self.asDebugResponse(response)
  }

  /// The lifecycle handlers live in `CommandProposalRouting` (shared with the
  /// live GUI router) so both surfaces emit byte-identical bodies; this maps its
  /// `ControlResponse` onto the headless `DebugResponse`.
  private static func asDebugResponse(_ response: ControlResponse) -> DebugResponse {
    DebugResponse(status: response.status, body: response.body)
  }

  private static func encodeBody(_ request: CommandProposalRefRequest) -> Data {
    (try? JSONEncoder().encode(request)) ?? Data()
  }
}
