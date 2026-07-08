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

  public init(
    pid: pid_t,
    parentPID: pid_t? = nil,
    startTime: Date? = nil,
    uid: uid_t = getuid(),
    executablePath: String? = nil,
    arguments: [String] = [],
    signing: ControlCodeSigningIdentity? = nil
  ) {
    self.pid = pid
    self.parentPID = parentPID
    self.startTime = startTime
    self.uid = uid
    self.executablePath = executablePath
    self.arguments = arguments
    self.signing = signing
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

public protocol ControlProcessTreeInspecting: Sendable {
  func parentPID(of pid: pid_t) -> pid_t?
  func identity(for pid: pid_t) -> ControlProcessIdentity
}

public protocol ControlCodeSigningInspecting: Sendable {
  func signingIdentity(forLivePID pid: pid_t, startTime: Date) -> ControlCodeSigningIdentity?
  func validatesLivePID(_ pid: pid_t, startTime: Date, against requirement: String) -> Bool
}

public struct ControlProcessTreeInspector: ControlProcessTreeInspecting {
  public init() {}

  public func parentPID(of pid: pid_t) -> pid_t? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
      size >= MemoryLayout<kinfo_proc>.stride
    else {
      return nil
    }
    let ppid = info.kp_eproc.e_ppid
    return ppid > 0 ? ppid : nil
  }

  public func identity(for pid: pid_t) -> ControlProcessIdentity {
    let executablePath = ControlProcessInfo.executablePath(for: pid)
    let startTime = processStartTime(pid: pid)
    let parentPID = parentPID(of: pid)
    return ControlProcessIdentity(
      pid: pid,
      parentPID: parentPID,
      startTime: startTime,
      uid: getuid(),
      executablePath: executablePath,
      arguments: [],
      signing: nil)
  }

  private func processStartTime(pid: pid_t) -> Date? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
      size >= MemoryLayout<kinfo_proc>.stride
    else {
      return nil
    }
    var tv = info.kp_proc.p_starttime
    return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
  }
}

public final class ControlCodeSigningInspector: ControlCodeSigningInspecting {
  public init() {}

  public func signingIdentity(forLivePID pid: pid_t, startTime: Date) -> ControlCodeSigningIdentity? {
    #if canImport(Security)
    let cs = ControlCodeSigning()
    return cs.identity(forLivePID: pid, startTime: startTime)
    #else
    return nil
    #endif
  }

  public func validatesLivePID(_ pid: pid_t, startTime: Date, against requirement: String) -> Bool {
    #if canImport(Security)
    let cs = ControlCodeSigning()
    return cs.validateLivePID(pid, startTime: startTime, requirement: requirement)
    #else
    return false
    #endif
  }
}
