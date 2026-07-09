import CryptoKit
import Darwin
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

public final class ControlAttachApprovalRecordFileSigner: ControlAttachApprovalRecordSigning,
  @unchecked Sendable
{
  public static let defaultKeyFilename = "control-approval-signing.key"

  private let keyURL: URL
  private let lock = NSLock()
  private var cachedSigner: ControlAttachApprovalRecordHMACSigner?

  public init(keyURL: URL = ControlAttachApprovalRecordFileSigner.defaultKeyURL()) {
    self.keyURL = keyURL
  }

  public static func defaultKeyURL() -> URL {
    ControlAdvertisement.directory().appendingPathComponent(defaultKeyFilename)
  }

  public func sign(_ record: ControlAttachApprovalRecord) -> ControlAttachApprovalRecord {
    guard let signer = signer(createIfMissing: true) else { return record }
    return signer.sign(record)
  }

  public func isValid(_ record: ControlAttachApprovalRecord) -> Bool {
    guard let signer = signer(createIfMissing: false) else { return false }
    return signer.isValid(record)
  }

  private func signer(createIfMissing: Bool) -> ControlAttachApprovalRecordHMACSigner? {
    lock.lock()
    defer { lock.unlock() }
    if let cachedSigner { return cachedSigner }
    guard
      let key =
        createIfMissing
        ? Self.loadOrCreateKey(at: keyURL)
        : Self.loadKey(at: keyURL)
    else {
      return nil
    }
    let signer = ControlAttachApprovalRecordHMACSigner(key: key)
    cachedSigner = signer
    return signer
  }

  private static func loadOrCreateKey(at url: URL) -> Data? {
    if let key = loadKey(at: url) { return key }
    let key = randomKey()
    guard storeKey(key, at: url) else { return nil }
    return key
  }

  private static func loadKey(at url: URL) -> Data? {
    guard prepareKeyDirectory(url.deletingLastPathComponent(), allowCreate: false) else {
      return nil
    }
    var st = stat()
    guard lstat(url.path, &st) == 0 else { return nil }
    guard isPrivateRegularFile(st) else { return nil }

    let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { return nil }
    var opened = stat()
    guard fstat(fd, &opened) == 0, isPrivateRegularFile(opened) else {
      Darwin.close(fd)
      return nil
    }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    let data: Data
    do {
      data = try handle.readToEnd() ?? Data()
      try handle.close()
    } catch {
      try? handle.close()
      return nil
    }
    guard data.count == 32 else { return nil }
    return data
  }

  private static func storeKey(_ data: Data, at url: URL) -> Bool {
    guard data.count == 32 else { return false }
    let directory = url.deletingLastPathComponent()
    guard prepareKeyDirectory(directory, allowCreate: true) else { return false }

    var st = stat()
    if lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) != S_IFREG {
      return false
    }

    let tmp = directory.appendingPathComponent(
      ".\(url.lastPathComponent).\(getpid()).\(UUID().uuidString).tmp")
    let fd = Darwin.open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { return false }
    do {
      try ControlFD.setCloseOnExec(fd)
    } catch {
      Darwin.close(fd)
      try? FileManager.default.removeItem(at: tmp)
      return false
    }

    var installed = false
    defer {
      Darwin.close(fd)
      if !installed {
        try? FileManager.default.removeItem(at: tmp)
      }
    }

    let wroteAll = data.withUnsafeBytes { rawBuffer -> Bool in
      guard let base = rawBuffer.baseAddress else { return false }
      var written = 0
      while written < rawBuffer.count {
        let result = Darwin.write(fd, base.advanced(by: written), rawBuffer.count - written)
        if result < 0 && errno == EINTR { continue }
        guard result > 0 else { return false }
        written += result
      }
      return true
    }
    guard wroteAll, fchmod(fd, S_IRUSR | S_IWUSR) == 0, fsync(fd) == 0 else { return false }
    guard Darwin.rename(tmp.path, url.path) == 0 else { return false }
    installed = true
    return true
  }

  private static func prepareKeyDirectory(_ directory: URL, allowCreate: Bool) -> Bool {
    do {
      try ControlDirectorySecurity.rejectSymlinkDirectory(at: directory)
      if !allowCreate {
        var st = stat()
        guard stat(directory.path, &st) == 0 else { return false }
      }
      try ControlDirectorySecurity.ensurePrivateDirectory(at: directory)
      return true
    } catch {
      return false
    }
  }

  private static func randomKey() -> Data {
    var key = Data(count: 32)
    key.withUnsafeMutableBytes { rawBuffer in
      if let base = rawBuffer.baseAddress {
        arc4random_buf(base, rawBuffer.count)
      }
    }
    return key
  }

  private static func isPrivateRegularFile(_ st: stat) -> Bool {
    (st.st_mode & S_IFMT) == S_IFREG
      && st.st_uid == getuid()
      && UInt16(st.st_mode & 0o777) == 0o600
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
