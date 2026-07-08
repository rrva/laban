import Foundation
import LabanCore

public enum ControlAttachApprovalScope: Codable, Equatable, Sendable {
  case currentRegisteredSession

  enum CodingKeys: String, CodingKey {
    case scope
  }

  enum ScopeName: String, Codable, Sendable {
    case currentRegisteredSession
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let name = try container.decode(ScopeName.self, forKey: .scope)
    switch name {
    case .currentRegisteredSession:
      self = .currentRegisteredSession
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .currentRegisteredSession:
      try container.encode(ScopeName.currentRegisteredSession, forKey: .scope)
    }
  }
}

public struct ControlAttachApprovalRecord: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var id: String
  public var displayName: String
  public var bundleIdentifier: String?
  public var signing: ControlCodeSigningIdentity
  public var signingRequirement: String
  public var scope: ControlAttachApprovalScope
  public var sessionID: String
  public var shellIdentityFingerprint: String
  public var allowedRouteIDs: [String]
  public var allowedIntentIDs: [String]
  public var capabilities: [Capability]
  public var maxDataSensitivity: String
  public var allowedSideEffectClasses: [String]
  public var leafIdentityFingerprint: String
  public var hmac: String
  public var createdAt: Date
  public var lastUsedAt: Date?
  public var revokedAt: Date?

  public init(
    schemaVersion: Int = 1,
    id: String,
    displayName: String,
    bundleIdentifier: String? = nil,
    signing: ControlCodeSigningIdentity,
    signingRequirement: String = "",
    scope: ControlAttachApprovalScope = .currentRegisteredSession,
    sessionID: String,
    shellIdentityFingerprint: String,
    allowedRouteIDs: [String],
    allowedIntentIDs: [String],
    capabilities: [Capability],
    maxDataSensitivity: String,
    allowedSideEffectClasses: [String],
    leafIdentityFingerprint: String,
    hmac: String = "",
    createdAt: Date = Date(),
    lastUsedAt: Date? = nil,
    revokedAt: Date? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.id = id
    self.displayName = displayName
    self.bundleIdentifier = bundleIdentifier
    self.signing = signing
    self.signingRequirement =
      signingRequirement.isEmpty
      ? (signing.designatedRequirement ?? "")
      : signingRequirement
    self.scope = scope
    self.sessionID = sessionID
    self.shellIdentityFingerprint = shellIdentityFingerprint
    self.allowedRouteIDs = allowedRouteIDs
    self.allowedIntentIDs = allowedIntentIDs
    self.capabilities = capabilities
    self.maxDataSensitivity = maxDataSensitivity
    self.allowedSideEffectClasses = allowedSideEffectClasses
    self.leafIdentityFingerprint = leafIdentityFingerprint
    self.hmac = hmac
    self.createdAt = createdAt
    self.lastUsedAt = lastUsedAt
    self.revokedAt = revokedAt
  }

  public var isRevoked: Bool {
    revokedAt != nil
  }
}

public enum ControlAttachApprovalDecision: Equatable, Sendable {
  case allowOnce
  case alwaysAllowSignedIdentity
  case deny
}

public struct ControlAttachApprovalRequest: Sendable {
  public let id: String
  public let principalDisplayName: String
  public let principalIsVerified: Bool
  public let helperChainSummary: String
  public let principalPath: String?
  public let sessionDisplay: String
  public let operationSummary: String
  public let dataSensitivity: String
  public let capabilities: [String]
  public let canPersist: Bool
  public let persistenceDisabledReason: String?

  public init(
    id: String,
    principalDisplayName: String,
    principalIsVerified: Bool,
    helperChainSummary: String,
    principalPath: String?,
    sessionDisplay: String,
    operationSummary: String,
    dataSensitivity: String,
    capabilities: [String],
    canPersist: Bool,
    persistenceDisabledReason: String?
  ) {
    self.id = id
    self.principalDisplayName = principalDisplayName
    self.principalIsVerified = principalIsVerified
    self.helperChainSummary = helperChainSummary
    self.principalPath = principalPath
    self.sessionDisplay = sessionDisplay
    self.operationSummary = operationSummary
    self.dataSensitivity = dataSensitivity
    self.capabilities = capabilities
    self.canPersist = canPersist
    self.persistenceDisabledReason = persistenceDisabledReason
  }
}

public protocol ControlAttachApprovalDelegate: AnyObject, Sendable {
  func requestControlAttachApproval(
    _ request: ControlAttachApprovalRequest,
    completion: @escaping @Sendable (ControlAttachApprovalDecision) -> Void
  )
}

public struct ControlAttachApprovalContext: Sendable, Equatable {
  public let approvalID: String
  public let sessionID: String
  public let peerPID: pid_t
  public let peerStartTime: Date?
  public let auditToken: Data?
  public let principalFingerprint: String
  public let method: String
  public let path: String
  public let query: String
  public let bodySHA256: String?
  public let resolvedRouteID: String
  public let resolvedIntentID: String
  public let capabilities: [Capability]
  public let maxDataSensitivity: String
  public let allowedSideEffectClasses: [String]

  public init(
    approvalID: String,
    sessionID: String,
    peerPID: pid_t,
    peerStartTime: Date?,
    auditToken: Data? = nil,
    principalFingerprint: String,
    method: String,
    path: String,
    query: String,
    bodySHA256: String?,
    resolvedRouteID: String,
    resolvedIntentID: String,
    capabilities: [Capability],
    maxDataSensitivity: String,
    allowedSideEffectClasses: [String]
  ) {
    self.approvalID = approvalID
    self.sessionID = sessionID
    self.peerPID = peerPID
    self.peerStartTime = peerStartTime
    self.auditToken = auditToken
    self.principalFingerprint = principalFingerprint
    self.method = method
    self.path = path
    self.query = query
    self.bodySHA256 = bodySHA256
    self.resolvedRouteID = resolvedRouteID
    self.resolvedIntentID = resolvedIntentID
    self.capabilities = capabilities
    self.maxDataSensitivity = maxDataSensitivity
    self.allowedSideEffectClasses = allowedSideEffectClasses
  }
}

public struct ControlAttachProcessChain: Sendable, Equatable {
  public let entries: [ControlProcessIdentity]

  public init(entries: [ControlProcessIdentity]) {
    self.entries = entries
  }

  public var principal: ControlAttachPrincipal? {
    var nonBundled: [ControlProcessIdentity] = []
    for entry in entries.reversed() where !ControlAttachPrincipal.isBundledHelper(entry) {
      nonBundled.append(entry)
    }
    let principalEntry =
      nonBundled.first { !ControlAttachPrincipal.isGenericInterpreter($0) }
      ?? nonBundled.first
    guard let principalEntry else { return nil }
    let isGeneric = ControlAttachPrincipal.isGenericInterpreter(principalEntry)
    return ControlAttachPrincipal(
      identity: principalEntry,
      isGenericInterpreter: isGeneric,
      isPersistable: ControlAttachPrincipal.isPersistable(principalEntry),
      helperChain: entries)
  }

  public var helperChainSummary: String {
    let names = entries.reversed().map { $0.displayName }
    return names.joined(separator: " -> ")
  }
}

public struct ControlAttachPrincipal: Sendable, Equatable {
  public let identity: ControlProcessIdentity
  public let isGenericInterpreter: Bool
  public let isPersistable: Bool
  public let helperChain: [ControlProcessIdentity]

  public init(
    identity: ControlProcessIdentity,
    isGenericInterpreter: Bool,
    isPersistable: Bool,
    helperChain: [ControlProcessIdentity]
  ) {
    self.identity = identity
    self.isGenericInterpreter = isGenericInterpreter
    self.isPersistable = isPersistable
    self.helperChain = helperChain
  }

  public static func isGenericInterpreter(_ identity: ControlProcessIdentity) -> Bool {
    if !identity.executableBaseName.isEmpty {
      return ControlAttachConstants.genericInterpreters.contains(identity.executableBaseName)
    }
    return ControlAttachConstants.genericInterpreterSigningIdentifiers.contains(
      identity.signing?.signingIdentifier ?? "")
  }

  public static func isGenericInterpreter(_ basename: String) -> Bool {
    ControlAttachConstants.genericInterpreters.contains(basename)
  }

  public static func isBundledHelper(_ identity: ControlProcessIdentity) -> Bool {
    if !identity.executableBaseName.isEmpty {
      return ControlAttachConstants.bundledHelpers.contains(identity.executableBaseName)
    }
    return identity.signing?.bundleIdentifier?.hasSuffix(".Laban") == true
  }

  public static func isPersistable(_ identity: ControlProcessIdentity) -> Bool {
    !isGenericInterpreter(identity)
      && !isBundledHelper(identity)
      && identity.signing?.isAdHocOrUnsigned == false
      && identity.signing?.designatedRequirement?.isEmpty == false
  }
}

public enum ControlAttachConstants {
  public static let bundledHelpers: [String] = ["laban", "laban-agent"]

  public static let genericInterpreters: [String] = [
    "sh", "zsh", "bash", "fish",
    "python", "python3", "node", "npm", "npx", "pnpm", "yarn", "bun", "deno", "uv", "pipx",
    "ruby", "perl", "php", "java", "osascript", "swift", "xcrun",
  ]

  public static let genericInterpreterSigningIdentifiers: [String] = [
    "com.apple.swift", "com.apple.python", "com.apple.javascript",
    "org.python.python", "org.nodejs.node", "com.apple.ruby",
  ]
}

public struct RegisteredAttachShellIdentity: Equatable, Sendable {
  public let sessionID: String
  public let tabGeneration: String?
  public let shellPID: pid_t
  public let shellStartTime: Date?
  public let shellUID: uid_t
  public let shellExecutablePath: String?
  public let registeredAt: Date

  public init(
    sessionID: String,
    tabGeneration: String? = nil,
    shellPID: pid_t,
    shellStartTime: Date?,
    shellUID: uid_t,
    shellExecutablePath: String?,
    registeredAt: Date = Date()
  ) {
    self.sessionID = sessionID
    self.tabGeneration = tabGeneration
    self.shellPID = shellPID
    self.shellStartTime = shellStartTime
    self.shellUID = shellUID
    self.shellExecutablePath = shellExecutablePath
    self.registeredAt = registeredAt
  }

  public var fingerprint: String {
    var parts: [String] = []
    parts.append("session=\(sessionID)")
    parts.append("pid=\(shellPID)")
    if let shellStartTime {
      parts.append("start=\(Int64(shellStartTime.timeIntervalSince1970 * 1000))")
    }
    return parts.joined(separator: ";")
  }
}
