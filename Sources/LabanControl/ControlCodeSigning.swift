import Foundation

#if canImport(Security)
  import Security

  /// macOS code-signing inspection for live PIDs.
  ///
  /// This uses `SecCodeCopyGuestWithAttributes` to obtain a code object for the
  /// running process identified by pid + start time, then extracts the static
  /// signing information and a stable requirement string. Path-based validation
  /// is not used for authorization.
  public struct ControlCodeSigning: Sendable {
    public init() {}

    public func identity(forLivePID pid: pid_t, startTime: Date) -> ControlCodeSigningIdentity? {
      guard let code = code(forPID: pid) else { return nil }
      guard let staticCode = staticCode(for: code) else { return nil }

      var info: CFDictionary?
      let infoStatus = SecCodeCopySigningInformation(
        staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
      guard infoStatus == errSecSuccess, let info else { return nil }

      let dict = info as! [String: Any]
      let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
      let signingID = dict[kSecCodeInfoIdentifier as String] as? String
      let isAdHoc = team == nil
      let designatedRequirement = requirementString(for: code)

      return ControlCodeSigningIdentity(
        teamIdentifier: team,
        bundleIdentifier: signingID,
        signingIdentifier: signingID,
        designatedRequirement: designatedRequirement,
        codeHash: nil,
        isAdHocOrUnsigned: isAdHoc)
    }

    public func validateLivePID(_ pid: pid_t, startTime: Date, requirement: String) -> Bool {
      guard let code = code(forPID: pid) else { return false }

      var requirementRef: SecRequirement?
      let reqStatus = SecRequirementCreateWithString(
        requirement as CFString, SecCSFlags(), &requirementRef)
      guard reqStatus == errSecSuccess, let requirementRef else { return false }

      let verifyStatus = SecCodeCheckValidity(code, SecCSFlags(), requirementRef)
      return verifyStatus == errSecSuccess
    }

    private func code(forPID pid: pid_t) -> SecCode? {
      var code: SecCode?
      let attributes: [String: Any] = [kSecGuestAttributePid: pid]
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

    private func requirementString(for code: SecCode) -> String? {
      var requirement: SecRequirement?
      let status = SecCodeCopyDesignatedRequirement(code, SecCSFlags(), &requirement)
      guard status == errSecSuccess, let requirement else { return nil }

      var string: CFString?
      let dataStatus = SecRequirementCopyString(requirement, SecCSFlags(), &string)
      guard dataStatus == errSecSuccess, let string else { return nil }
      return string as String
    }
  }
#endif
