import Foundation
import LabanControl
import LabanCore

/// LabanApp-side `ControlSecurityObserver`: drives the agent-attached indicator
/// (TTL) and appends sanitized audit lines to the persistent `EventLog`.
final class ControlSecurityCoordinator: ControlSecurityObserver, @unchecked Sendable {
  static let privilegedActivityTTL: TimeInterval = 30

  private weak var indicatorHost: ControlAgentAttachedIndicatorHost?
  private let timerQueue = DispatchQueue(label: "laban.control.security.ttl")
  private var expiryTimer: DispatchSourceTimer?

  init(indicatorHost: ControlAgentAttachedIndicatorHost?) {
    self.indicatorHost = indicatorHost
  }

  func didAuthorize(_ context: ControlSecurityContext) {
    // Non-privileged successful reads are not audited (C7).
  }

  func didDeny(_ context: ControlSecurityContext, reason: ControlSecurityDenyReason) {
    EventLog.shared.log(
      "control.denied",
      auditPayload(from: context, extra: ["reason": reason.rawValue]))
  }

  func didPrivilegedActivity(_ context: ControlSecurityContext) {
    EventLog.shared.log("control.privileged", auditPayload(from: context))
    armIndicator()
  }

  func didAttachAuthorize(_ context: ControlSecurityContext) {
    EventLog.shared.log("control.attach", auditPayload(from: context))
    armIndicator()
  }

  func didAttachRequest(_ context: ControlSecurityContext) {
    EventLog.shared.log("control.attach.requested", auditPayload(from: context))
  }

  func didAttachApprove(_ context: ControlSecurityContext, mode: String) {
    EventLog.shared.log(
      "control.attach.approved",
      auditPayload(from: context, extra: ["mode": mode]))
    armIndicator()
  }

  func didAttachDeny(_ context: ControlSecurityContext, reason: ControlSecurityDenyReason) {
    EventLog.shared.log(
      "control.attach.denied",
      auditPayload(from: context, extra: ["reason": reason.rawValue]))
  }

  func didAttachRevoke(_ context: ControlSecurityContext) {
    EventLog.shared.log("control.attach.revoked", auditPayload(from: context))
  }

  func didAttachAutoApprove(_ context: ControlSecurityContext, approvalID: String) {
    EventLog.shared.log(
      "control.attach.autoApproved",
      auditPayload(from: context, extra: ["approvalID": approvalID]))
    armIndicator()
  }

  private func auditPayload(
    from context: ControlSecurityContext,
    extra: [String: Any] = [:]
  ) -> [String: Any] {
    var payload: [String: Any] = extra
    if let intentID = context.intentID {
      payload["intent"] = intentID
    }
    if let capability = context.capability {
      payload["capability"] = capability.rawValue
    }
    payload["surface"] = context.surface == .gui ? "gui" : "headless"
    if let sessionID = context.sessionID {
      payload["session"] = sessionID
    }
    payload["ts"] = ISO8601DateFormatter().string(from: context.timestamp)
    return payload
  }

  private func armIndicator() {
    DispatchQueue.main.async { [weak self] in
      self?.indicatorHost?.setAgentAttachedIndicatorActive(true)
    }
    timerQueue.async { [weak self] in
      self?.scheduleExpiry()
    }
  }

  private func scheduleExpiry() {
    expiryTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: timerQueue)
    timer.schedule(deadline: .now() + Self.privilegedActivityTTL)
    timer.setEventHandler { [weak self] in
      DispatchQueue.main.async {
        self?.indicatorHost?.setAgentAttachedIndicatorActive(false)
      }
      timer.cancel()
    }
    timer.resume()
    expiryTimer = timer
  }
}
