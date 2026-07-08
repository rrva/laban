import Foundation

#if canImport(Security)
  import Security

  private let kSecGuestAttributeAudit: CFString = "audit" as CFString

  /// macOS code-signing inspection for live PIDs.
  ///
  /// This uses `SecCodeCopyGuestWithAttributes` to obtain a code object for the
  /// running process identified by pid + start time, then extracts the static
  /// signing information and a stable requirement string. Path-based validation
  /// is not used for authorization.
  public struct ControlCodeSigning: Sendable {
    public init() {}

    public func identity(forLivePID pid: pid_t, startTime: Date) -> ControlCodeSigningIdentity? {
      guard processStartTimeMatches(pid: pid, startTime: startTime) else { return nil }
      guard let code = code(forPID: pid) else { return nil }
      return identity(for: code)
    }

    public func identity(forAuditToken auditToken: Data) -> ControlCodeSigningIdentity? {
      guard let code = code(forAuditToken: auditToken) else { return nil }
      return identity(for: code)
    }

    public func validateLivePID(_ pid: pid_t, startTime: Date, requirement: String) -> Bool {
      guard processStartTimeMatches(pid: pid, startTime: startTime) else { return false }
      guard let code = code(forPID: pid) else { return false }
      return validate(code: code, requirement: requirement)
    }

    public func validate(auditToken: Data, requirement: String) -> Bool {
      guard let code = code(forAuditToken: auditToken) else { return false }
      return validate(code: code, requirement: requirement)
    }

    private func identity(for code: SecCode) -> ControlCodeSigningIdentity? {
      guard let staticCode = staticCode(for: code) else { return nil }

      var info: CFDictionary?
      let infoStatus = SecCodeCopySigningInformation(
        staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
      guard infoStatus == errSecSuccess, let info else { return nil }

      let dict = info as! [CFString: Any]
      let team = dict[kSecCodeInfoTeamIdentifier] as? String
      let signingID = dict[kSecCodeInfoIdentifier] as? String
      let isAdHoc = team == nil
      let designatedRequirement = requirementString(for: staticCode)

      return ControlCodeSigningIdentity(
        teamIdentifier: team,
        bundleIdentifier: signingID,
        signingIdentifier: signingID,
        designatedRequirement: designatedRequirement,
        codeHash: nil,
        isAdHocOrUnsigned: isAdHoc)
    }

    private func validate(code: SecCode, requirement: String) -> Bool {
      var requirementRef: SecRequirement?
      let reqStatus = SecRequirementCreateWithString(
        requirement as CFString, SecCSFlags(), &requirementRef)
      guard reqStatus == errSecSuccess, let requirementRef else { return false }

      let verifyStatus = SecCodeCheckValidity(code, SecCSFlags(), requirementRef)
      return verifyStatus == errSecSuccess
    }

    private func processStartTimeMatches(pid: pid_t, startTime: Date) -> Bool {
      guard let liveStartTime = ControlProcessTreeInspector().identity(for: pid)?.startTime
      else { return false }
      return liveStartTime == startTime
    }

    private func code(forPID pid: pid_t) -> SecCode? {
      var code: SecCode?
      let attributes: [CFString: Any] = [kSecGuestAttributePid: pid]
      let status = SecCodeCopyGuestWithAttributes(
        nil, attributes as CFDictionary, SecCSFlags(), &code)
      guard status == errSecSuccess else { return nil }
      return code
    }

    private func code(forAuditToken auditToken: Data) -> SecCode? {
      let auditTokenLength = 32
      guard auditToken.count == auditTokenLength else { return nil }
      var code: SecCode?
      let data = auditToken as CFData
      let attributes: [CFString: Any] = [kSecGuestAttributeAudit: data]
      let status = SecCodeCopyGuestWithAttributes(
        nil, attributes as CFDictionary, SecCSFlags(), &code)
      guard status == errSecSuccess else { return nil }
      return code
    }

    private func staticCode(for code: SecCode) -> SecStaticCode? {
      var staticCode: SecStaticCode?
      let status = SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode)
      guard status == errSecSuccess else { return nil }
      return staticCode
    }

    private func requirementString(for staticCode: SecStaticCode) -> String? {
      var requirement: SecRequirement?
      let status = SecCodeCopyDesignatedRequirement(staticCode, SecCSFlags(), &requirement)
      guard status == errSecSuccess, let requirement else { return nil }

      var string: CFString?
      let dataStatus = SecRequirementCopyString(requirement, SecCSFlags(), &string)
      guard dataStatus == errSecSuccess, let string else { return nil }
      return string as String
    }
  }
#endif
