import Foundation
import LabanCore

public final class ControlAttachApprovalStore: @unchecked Sendable {
  public static let defaultsKey = "LabanControlAttachApprovalRecordsV1"

  public static func defaultSigner() -> ControlAttachApprovalRecordSigning? {
    ControlAttachApprovalRecordFileSigner()
  }

  private let defaults: UserDefaults
  private let signer: ControlAttachApprovalRecordSigning?
  private let lock = NSLock()

  public init(
    defaults: UserDefaults = .standard,
    signer: ControlAttachApprovalRecordSigning? = nil
  ) {
    self.defaults = defaults
    self.signer = signer
  }

  public func loadAll() -> [ControlAttachApprovalRecord] {
    lock.lock()
    defer { lock.unlock() }
    return loadAllLocked()
  }

  public func save(_ records: [ControlAttachApprovalRecord]) {
    lock.lock()
    defer { lock.unlock() }
    saveLocked(records)
  }

  /// Callers must hold `lock`.
  private func loadAllLocked() -> [ControlAttachApprovalRecord] {
    guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
    do {
      let records = try JSONDecoder().decode([ControlAttachApprovalRecord].self, from: data)
      if let signer = signer {
        return records.filter { signer.isValid($0) }
      }
      return records
    } catch {
      return []
    }
  }

  /// Callers must hold `lock`.
  private func saveLocked(_ records: [ControlAttachApprovalRecord]) {
    do {
      let signedRecords = signer.map { signer in records.map { signer.sign($0) } } ?? records
      let data = try JSONEncoder().encode(signedRecords)
      defaults.set(data, forKey: Self.defaultsKey)
    } catch {
      // Fail silently; approvals should not crash the app.
    }
  }

  /// Each mutation below holds `lock` across its entire load-modify-save
  /// sequence so a concurrent mutation on the same record (e.g. a revoke
  /// racing an updateLastUsed) cannot read stale state and clobber the
  /// other's write when it saves.
  public func add(_ record: ControlAttachApprovalRecord) {
    lock.lock()
    defer { lock.unlock() }
    var records = loadAllLocked()
    records.append(record)
    saveLocked(records)
  }

  public func revoke(id: String) {
    lock.lock()
    defer { lock.unlock() }
    var records = loadAllLocked()
    guard let index = records.firstIndex(where: { $0.id == id }) else { return }
    var record = records[index]
    record.revokedAt = Date()
    records[index] = record
    saveLocked(records)
  }

  public func updateLastUsed(id: String) {
    lock.lock()
    defer { lock.unlock() }
    var records = loadAllLocked()
    guard let index = records.firstIndex(where: { $0.id == id }) else { return }
    records[index].lastUsedAt = Date()
    saveLocked(records)
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
    let principalFingerprint = principal.identity.stablePrincipalFingerprint
    for record in records where record.isRevoked == false {
      guard record.sessionID == sessionID else { continue }
      guard record.shellIdentityFingerprint == shellIdentityFingerprint else { continue }
      guard record.allowedRouteIDs.contains(routeID) else { continue }
      guard record.allowedIntentIDs.contains(intentID) else { continue }
      let recordCapabilities = Set(record.capabilities)
      guard capabilities.isSubset(of: recordCapabilities) else { continue }
      guard record.allowedSideEffectClasses.contains(sideEffectClass) else { continue }
      guard dataSensitivity.compareSensitivity(to: record.maxDataSensitivity) else { continue }
      if record.principalIdentityFingerprint != principalFingerprint { continue }
      guard
        recordMatchesPrincipal(
          record,
          principal: principal,
          signingInspector: signingInspector,
          auditToken: principal.identity.auditToken)
      else { continue }
      return record
    }
    return nil
  }

  private func recordMatchesPrincipal(
    _ record: ControlAttachApprovalRecord,
    principal: ControlAttachPrincipal,
    signingInspector: ControlCodeSigningInspecting?,
    auditToken: Data?
  ) -> Bool {
    guard let principalSigning = principal.identity.signing else { return false }
    let requirement = record.signingRequirement
    guard !requirement.isEmpty else { return false }
    guard let startTime = principal.identity.startTime else { return false }
    if let inspector = signingInspector {
      return inspector.validatesLivePID(
        principal.identity.pid, startTime: startTime, auditToken: auditToken, against: requirement)
    }
    return requirement == (principalSigning.designatedRequirement ?? "")
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
