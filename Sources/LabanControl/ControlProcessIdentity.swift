import Darwin
import Foundation

public struct ControlProcessIdentity: Equatable, Sendable {
  public var pid: pid_t
  public var parentPID: pid_t?
  public var startTime: Date?
  public var uid: uid_t
  public var executablePath: String?
  public var arguments: [String]
  public var signing: ControlCodeSigningIdentity?
  public var auditToken: Data?

  public init(
    pid: pid_t,
    parentPID: pid_t? = nil,
    startTime: Date? = nil,
    uid: uid_t = getuid(),
    executablePath: String? = nil,
    arguments: [String] = [],
    signing: ControlCodeSigningIdentity? = nil,
    auditToken: Data? = nil
  ) {
    self.pid = pid
    self.parentPID = parentPID
    self.startTime = startTime
    self.uid = uid
    self.executablePath = executablePath
    self.arguments = arguments
    self.signing = signing
    self.auditToken = auditToken
  }

  public var displayName: String {
    if let displayName = signing?.displayName {
      return displayName
    }
    if let path = executablePath, !path.isEmpty {
      return URL(fileURLWithPath: path).lastPathComponent
    }
    return "process \(pid)"
  }

  public var executableBaseName: String {
    if let path = executablePath, !path.isEmpty {
      return URL(fileURLWithPath: path).lastPathComponent
    }
    if let identifier = signing?.signingIdentifier, !identifier.isEmpty {
      return identifier
    }
    return "process \(pid)"
  }

  public var fingerprint: String {
    var parts: [String] = []
    parts.append("pid=\(pid)")
    if let startTime {
      parts.append("start=\(Int64(startTime.timeIntervalSince1970 * 1000))")
    }
    if let signing {
      parts.append("signing=\(signing.fingerprint)")
    } else if let executablePath, !executablePath.isEmpty {
      parts.append("path=\(executablePath)")
    }
    return parts.joined(separator: ";")
  }

  /// A stable fingerprint for the identity that is safe to store in persisted
  /// approval records. It does not include the process PID or start time, so it
  /// matches the same signed app across a new process instance.
  public var stablePrincipalFingerprint: String {
    if let signing, let requirement = signing.designatedRequirement, !requirement.isEmpty {
      return requirement
    }
    return executablePath ?? "pid=\(pid)"
  }
}

public struct ControlCodeSigningIdentity: Codable, Equatable, Sendable {
  public var teamIdentifier: String?
  public var bundleIdentifier: String?
  public var signingIdentifier: String?
  public var designatedRequirement: String?
  public var codeHash: String?
  public var isAdHocOrUnsigned: Bool

  public init(
    teamIdentifier: String? = nil,
    bundleIdentifier: String? = nil,
    signingIdentifier: String? = nil,
    designatedRequirement: String? = nil,
    codeHash: String? = nil,
    isAdHocOrUnsigned: Bool = true
  ) {
    self.teamIdentifier = teamIdentifier
    self.bundleIdentifier = bundleIdentifier
    self.signingIdentifier = signingIdentifier
    self.designatedRequirement = designatedRequirement
    self.codeHash = codeHash
    self.isAdHocOrUnsigned = isAdHocOrUnsigned
  }

  public var fingerprint: String {
    var parts: [String] = []
    if let teamIdentifier { parts.append("team=\(teamIdentifier)") }
    if let bundleIdentifier { parts.append("bundle=\(bundleIdentifier)") }
    if let signingIdentifier { parts.append("signing=\(signingIdentifier)") }
    if let codeHash { parts.append("hash=\(codeHash)") }
    parts.append("adHoc=\(isAdHocOrUnsigned)")
    return parts.joined(separator: ";")
  }

  public var displayName: String? {
    if let bundleIdentifier { return bundleIdentifier }
    if let signingIdentifier { return signingIdentifier }
    return nil
  }
}

public struct AuditToken {
  public var val: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32)

  public init() {
    self.val = (0, 0, 0, 0, 0, 0, 0, 0)
  }
}

public protocol ControlProcessTreeInspecting: Sendable {
  func parentPID(of pid: pid_t) -> pid_t?
  func identity(for pid: pid_t) -> ControlProcessIdentity?
}

public protocol ControlCodeSigningInspecting: Sendable {
  func signingIdentity(forLivePID pid: pid_t, startTime: Date, auditToken: Data?)
    -> ControlCodeSigningIdentity?
  func validatesLivePID(
    _ pid: pid_t, startTime: Date, auditToken: Data?, against requirement: String
  ) -> Bool
}

public struct ControlProcessTreeInspector: ControlProcessTreeInspecting {
  public init() {}

  public func parentPID(of pid: pid_t) -> pid_t? {
    guard let info = kinfoProc(for: pid) else { return nil }
    let ppid = info.kp_eproc.e_ppid
    return ppid > 0 ? ppid : nil
  }

  public func identity(for pid: pid_t) -> ControlProcessIdentity? {
    guard let info = kinfoProc(for: pid) else { return nil }
    let uid = info.kp_eproc.e_ucred.cr_uid
    guard uid == getuid() else { return nil }
    let startTime = processStartTime(from: info)
    guard startTime != nil else { return nil }
    let ppid = info.kp_eproc.e_ppid
    let parentPID = ppid > 0 ? ppid : nil
    let executablePath = ControlProcessInfo.executablePath(for: pid)
    return ControlProcessIdentity(
      pid: pid,
      parentPID: parentPID,
      startTime: startTime,
      uid: uid,
      executablePath: executablePath,
      arguments: [],
      signing: nil)
  }

  private func kinfoProc(for pid: pid_t) -> kinfo_proc? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
      size >= MemoryLayout<kinfo_proc>.stride
    else {
      return nil
    }
    return info
  }

  private func processStartTime(from info: kinfo_proc) -> Date? {
    let tv = info.kp_proc.p_starttime
    return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
  }
}

public final class ControlCodeSigningInspector: ControlCodeSigningInspecting, @unchecked Sendable {
  public init() {}

  public func signingIdentity(
    forLivePID pid: pid_t,
    startTime: Date,
    auditToken: Data?
  ) -> ControlCodeSigningIdentity? {
    #if canImport(Security)
      let cs = ControlCodeSigning()
      if let auditToken, !auditToken.isEmpty {
        if let identity = cs.identity(forAuditToken: auditToken) {
          return identity
        }
      }
      return cs.identity(forLivePID: pid, startTime: startTime)
    #else
      return nil
    #endif
  }

  public func validatesLivePID(
    _ pid: pid_t,
    startTime: Date,
    auditToken: Data?,
    against requirement: String
  ) -> Bool {
    #if canImport(Security)
      let cs = ControlCodeSigning()
      if let auditToken, !auditToken.isEmpty {
        if cs.validate(auditToken: auditToken, requirement: requirement) {
          return true
        }
      }
      return cs.validateLivePID(pid, startTime: startTime, requirement: requirement)
    #else
      return false
    #endif
  }
}
