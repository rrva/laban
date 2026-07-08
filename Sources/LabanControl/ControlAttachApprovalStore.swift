import Foundation

public final class ControlAttachApprovalStore: @unchecked Sendable {
  public static let defaultsKey = "LabanControlAttachApprovalRecordsV1"

  private let defaults: UserDefaults
  private let lock = NSLock()

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public func loadAll() -> [ControlAttachApprovalRecord] {
    lock.lock()
    defer { lock.unlock() }
    guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
    do {
      return try JSONDecoder().decode([ControlAttachApprovalRecord].self, from: data)
    } catch {
      return []
    }
  }

  public func save(_ records: [ControlAttachApprovalRecord]) {
    lock.lock()
    defer { lock.unlock() }
    do {
      let data = try JSONEncoder().encode(records)
      defaults.set(data, forKey: Self.defaultsKey)
    } catch {
      // Fail silently; approvals should not crash the app.
    }
  }

  public func add(_ record: ControlAttachApprovalRecord) {
    var records = loadAll()
    records.append(record)
    save(records)
  }

  public func revoke(id: String) {
    var records = loadAll()
    guard let index = records.firstIndex(where: { $0.id == id }) else { return }
    var record = records[index]
    record.revokedAt = Date()
    records[index] = record
    save(records)
  }

  public func updateLastUsed(id: String) {
    var records = loadAll()
    guard let index = records.firstIndex(where: { $0.id == id }) else { return }
    records[index].lastUsedAt = Date()
    save(records)
  }

  public func findMatching(
    principal: ControlAttachPrincipal,
    sessionID: String,
    shellIdentityFingerprint: String,
    routeID: String,
    intentID: String,
    capabilities: Set<Capability>,
    dataSensitivity: String,
    sideEffectClass: String,
    signingInspector: ControlCodeSigningInspecting? = nil
  ) -> ControlAttachApprovalRecord? {
    let records = loadAll()
    for record in records where record.isRevoked == false {
      guard record.sessionID == sessionID else { continue }
      guard record.shellIdentityFingerprint == shellIdentityFingerprint else { continue }
      guard record.allowedRouteIDs.contains(routeID) else { continue }
      guard record.allowedIntentIDs.contains(intentID) else { continue }
      let recordCapabilities = Set(record.capabilities)
      guard capabilities.isSubset(of: recordCapabilities) else { continue }
      guard record.allowedSideEffectClasses.contains(sideEffectClass) else { continue }
      guard dataSensitivity.compareSensitivity(to: record.maxDataSensitivity) else { continue }
      guard recordMatchesPrincipal(record, principal: principal, signingInspector: signingInspector)
      else { continue }
      return record
    }
    return nil
  }

  private func recordMatchesPrincipal(
    _ record: ControlAttachApprovalRecord,
    principal: ControlAttachPrincipal,
    signingInspector: ControlCodeSigningInspecting?
  ) -> Bool {
    guard let principalSigning = principal.identity.signing else { return false }
    if let requirement = record.signing.designatedRequirement,
      let startTime = principal.identity.startTime,
      let inspector = signingInspector
    {
      return inspector.validatesLivePID(
        principal.identity.pid, startTime: startTime, against: requirement)
    }
    return record.signing == principalSigning
  }
}

extension String {
  fileprivate func compareSensitivity(to other: String) -> Bool {
    let order: [String] = [
      "none", "nonSensitiveState", "visibleText", "scrollback", "keystrokes",
      "clipboard", "screenshot", "trace", "sensitivePrivate",
    ]
    guard let lhsIndex = order.firstIndex(of: self),
      let rhsIndex = order.firstIndex(of: other)
    else {
      return self == other
    }
    return lhsIndex <= rhsIndex
  }
}
