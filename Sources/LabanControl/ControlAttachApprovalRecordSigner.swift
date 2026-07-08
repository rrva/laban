import CryptoKit
import Foundation

public protocol ControlAttachApprovalRecordSigning: Sendable {
  func sign(_ record: ControlAttachApprovalRecord) -> ControlAttachApprovalRecord
  func isValid(_ record: ControlAttachApprovalRecord) -> Bool
}

public final class ControlAttachApprovalRecordHMACSigner: ControlAttachApprovalRecordSigning,
  @unchecked Sendable
{
  private let key: SymmetricKey
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(key: Data) {
    self.key = SymmetricKey(data: key)
    self.encoder = JSONEncoder()
    self.encoder.outputFormatting = .sortedKeys
    self.decoder = JSONDecoder()
  }

  public func sign(_ record: ControlAttachApprovalRecord) -> ControlAttachApprovalRecord {
    var canonical = record
    canonical.hmac = ""
    guard let data = try? encoder.encode(canonical) else { return record }
    let mac = HMAC<SHA256>.authenticationCode(for: data, using: key)
    let hex = mac.map { String(format: "%02x", $0) }.joined()
    var signed = record
    signed.hmac = hex
    return signed
  }

  public func isValid(_ record: ControlAttachApprovalRecord) -> Bool {
    guard !record.hmac.isEmpty else { return false }
    var canonical = record
    canonical.hmac = ""
    guard let data = try? encoder.encode(canonical) else { return false }
    let mac = HMAC<SHA256>.authenticationCode(for: data, using: key)
    let expected = mac.map { String(format: "%02x", $0) }.joined()
    return constantTimeEquals(expected, record.hmac)
  }

  private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let aBytes = Array(a.utf8)
    let bBytes = Array(b.utf8)
    guard aBytes.count == bBytes.count else { return false }
    var result: UInt8 = 0
    for (x, y) in zip(aBytes, bBytes) {
      result |= x ^ y
    }
    return result == 0
  }
}

#if canImport(Security)
  import Security

  public final class ControlAttachApprovalRecordKeychainSigner: ControlAttachApprovalRecordSigning,
    @unchecked Sendable
  {
    private let service: String
    private let account: String
    private let signer: ControlAttachApprovalRecordHMACSigner

    public init(
      service: String = "com.ragnar.laban.control.approvals",
      account: String = "approvalRecordKey"
    ) {
      self.service = service
      self.account = account
      let key = Self.loadOrCreateKey(service: service, account: account)
      self.signer = ControlAttachApprovalRecordHMACSigner(key: key)
    }

    public func sign(_ record: ControlAttachApprovalRecord) -> ControlAttachApprovalRecord {
      signer.sign(record)
    }

    public func isValid(_ record: ControlAttachApprovalRecord) -> Bool {
      signer.isValid(record)
    }

    private static func loadOrCreateKey(service: String, account: String) -> Data {
      if let data = loadKey(service: service, account: account) { return data }
      var bytes = [UInt8](repeating: 0, count: 32)
      let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
      guard status == errSecSuccess else { return Data(repeating: 0, count: 32) }
      let data = Data(bytes)
      storeKey(data, service: service, account: account)
      return data
    }

    private static func loadKey(service: String, account: String) -> Data? {
      let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: account,
        kSecReturnData: true,
        kSecMatchLimit: kSecMatchLimitOne,
      ]
      var result: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      guard status == errSecSuccess, let data = result as? Data else { return nil }
      return data
    }

    private static func storeKey(_ data: Data, service: String, account: String) {
      let deleteQuery: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: account,
      ]
      _ = SecItemDelete(deleteQuery as CFDictionary)

      let addQuery: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: account,
        kSecValueData: data,
        kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      ]
      _ = SecItemAdd(addQuery as CFDictionary, nil)
    }
  }
#endif
