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
    var code: SecCode?
    let attributes: [String: Any] = [
      kSecGuestAttributePid as String: pid,
      kSecGuestAttributePidToOverrideSelfCheck as String: true,
    ]
    let status = SecCodeCopyGuestWithAttributes(
      nil, attributes as CFDictionary, SecCSFlag(), &code)
    guard status == errSecSuccess, let code else { return nil }

    var info: CFDictionary?
    let infoStatus = SecCodeCopySigningInformation(
      code, SecCSFlag(rawValue: kSecCSSigningInformation), &info)
    guard infoStatus == errSecSuccess, let info else { return nil }

    let dict = info as! [String: Any]
    let team = (dict[kSecCodeInfoTeamIdentifier as String] as? String)
    let signingID = (dict[kSecCodeInfoIdentifier as String] as? String)
    let codeHash = (dict[kSecCodeInfoUnique as String] as? String)
    let isAdHoc = (dict[kSecCodeInfoSignatureFlags as String] as? Int) == nil
    let designatedRequirement = requirementString(for: code)

    return ControlCodeSigningIdentity(
      teamIdentifier: team,
      bundleIdentifier: signingID,
      signingIdentifier: signingID,
      designatedRequirement: designatedRequirement,
      codeHash: codeHash,
      isAdHocOrUnsigned: isAdHoc)
  }

  public func validateLivePID(_ pid: pid_t, startTime: Date, requirement: String) -> Bool {
    var code: SecCode?
    let attributes: [String: Any] = [
      kSecGuestAttributePid as String: pid,
      kSecGuestAttributePidToOverrideSelfCheck as String: true,
    ]
    let status = SecCodeCopyGuestWithAttributes(
      nil, attributes as CFDictionary, SecCSFlag(), &code)
    guard status == errSecSuccess, let code else { return false }

    var requirementRef: SecRequirement?
    let reqStatus = SecRequirementCreateWithString(
      requirement as CFString, SecCSFlag(), &requirementRef)
    guard reqStatus == errSecSuccess, let requirementRef else { return false }

    let verifyStatus = SecCodeCheckValidity(
      code, SecCSFlag(), requirementRef)
    return verifyStatus == errSecSuccess
  }

  private func requirementString(for code: SecCode) -> String? {
    var requirement: SecRequirement?
    let status = SecCodeCopyDesignatedRequirement(code, SecCSFlag(), &requirement)
    guard status == errSecSuccess, let requirement else { return nil }

    var string: CFString?
    let dataStatus = SecRequirementCopyString(
      requirement, SecCSFlag(), &string)
    guard dataStatus == errSecSuccess, let string else { return nil }
    return string as String
  }
}
#endif
