import Foundation

public enum CommandProposalState: String, Codable, Sendable, Equatable {
  case pendingReview
  case dismissed
  case ran
  case cancelledByAgent
  case expired
}

public struct CommandProposal: Sendable, Equatable, Identifiable {
  public let id: String
  public let targetSessionID: String
  public let command: String
  public let purpose: String?
  public var state: CommandProposalState
  public let createdAt: Date

  public init(
    id: String = UUID().uuidString,
    targetSessionID: String,
    command: String,
    purpose: String?,
    state: CommandProposalState = .pendingReview,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.targetSessionID = targetSessionID
    self.command = command
    self.purpose = purpose
    self.state = state
    self.createdAt = createdAt
  }
}

public struct CommandProposeResponse: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var ok: Bool
  public var proposalID: String
  public var targetSessionID: String
  public var state: String
  public var writtenToPTY: Bool

  public init(
    ok: Bool,
    proposalID: String,
    targetSessionID: String,
    state: CommandProposalState,
    writtenToPTY: Bool = false
  ) {
    self.ok = ok
    self.proposalID = proposalID
    self.targetSessionID = targetSessionID
    self.state = state.rawValue
    self.writtenToPTY = writtenToPTY
  }

  public static var jsonSchema: SchemaNode {
    .object(
      properties: [
        "ok": .boolean,
        "proposalID": .string(enumValues: nil, const: nil, format: nil, pattern: nil),
        "targetSessionID": .string(enumValues: nil, const: nil, format: nil, pattern: nil),
        "state": .string(
          enumValues: [CommandProposalState.pendingReview.rawValue],
          const: nil,
          format: nil,
          pattern: nil),
        "writtenToPTY": .boolean,
      ],
      required: ["ok", "proposalID", "targetSessionID", "state", "writtenToPTY"],
      additionalProperties: false)
  }
}

/// One proposal as returned by `commandProposal.get` and in the
/// `commandProposal.list` array. The command text is echoed back verbatim (it
/// is agent-authored and already length-capped at submit time); consumers that
/// render it must apply their own safe-rendering (see `CommandProposalSafeText`).
public struct CommandProposalView: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var id: String
  public var targetSessionID: String
  public var command: String
  public var purpose: String?
  public var state: String
  public var createdAt: Double

  public init(_ proposal: CommandProposal) {
    self.id = proposal.id
    self.targetSessionID = proposal.targetSessionID
    self.command = proposal.command
    self.purpose = proposal.purpose
    self.state = proposal.state.rawValue
    self.createdAt = proposal.createdAt.timeIntervalSince1970
  }

  private static var stateValues: [String] {
    [
      CommandProposalState.pendingReview.rawValue,
      CommandProposalState.dismissed.rawValue,
      CommandProposalState.ran.rawValue,
      CommandProposalState.cancelledByAgent.rawValue,
      CommandProposalState.expired.rawValue,
    ]
  }

  public static var jsonSchema: SchemaNode {
    .object(
      properties: [
        "id": .string(enumValues: nil, const: nil, format: nil, pattern: nil),
        "targetSessionID": .string(enumValues: nil, const: nil, format: nil, pattern: nil),
        "command": .string(enumValues: nil, const: nil, format: nil, pattern: nil),
        "purpose": .string(enumValues: nil, const: nil, format: nil, pattern: nil),
        "state": .string(enumValues: stateValues, const: nil, format: nil, pattern: nil),
        "createdAt": .number(min: nil, max: nil),
      ],
      required: ["id", "targetSessionID", "command", "state", "createdAt"],
      additionalProperties: false)
  }
}

/// Response for `commandProposal.list`: proposals scoped to the caller's own
/// session, newest first.
public struct CommandProposalListResponse: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var ok: Bool
  public var proposals: [CommandProposalView]

  public init(proposals: [CommandProposalView]) {
    self.ok = true
    self.proposals = proposals
  }

  public static var jsonSchema: SchemaNode {
    .object(
      properties: [
        "ok": .boolean,
        "proposals": .array(CommandProposalView.jsonSchema, minItems: 0),
      ],
      required: ["ok", "proposals"],
      additionalProperties: false)
  }
}

/// Response for `commandProposal.cancel`: the resulting state after the cancel
/// attempt. `cancelled` is false when the proposal was already terminal.
public struct CommandProposalCancelResponse: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var ok: Bool
  public var proposalID: String
  public var cancelled: Bool
  public var state: String

  public init(proposalID: String, cancelled: Bool, state: CommandProposalState) {
    self.ok = true
    self.proposalID = proposalID
    self.cancelled = cancelled
    self.state = state.rawValue
  }

  public static var jsonSchema: SchemaNode {
    .object(
      properties: [
        "ok": .boolean,
        "proposalID": .string(enumValues: nil, const: nil, format: nil, pattern: nil),
        "cancelled": .boolean,
        "state": .string(enumValues: nil, const: nil, format: nil, pattern: nil),
      ],
      required: ["ok", "proposalID", "cancelled", "state"],
      additionalProperties: false)
  }
}

/// C15 safe-rendering: byte-exact visible escaping; copy text equals display text.
public struct CommandProposalSafeText: Sendable, Equatable {
  public static let maxByteLength = 4096

  public let displayText: String
  public let copyText: String
  public let truncated: Bool
  public let originalByteCount: Int

  public init(displayText: String, copyText: String, truncated: Bool, originalByteCount: Int) {
    self.displayText = displayText
    self.copyText = copyText
    self.truncated = truncated
    self.originalByteCount = originalByteCount
  }

  public static func render(_ raw: String) -> CommandProposalSafeText {
    let originalByteCount = raw.utf8.count
    var escaped = ""
    escaped.reserveCapacity(raw.count + 16)
    var emittedBytes = 0
    var truncated = false

    for scalar in raw.unicodeScalars {
      let piece = escapeScalar(scalar)
      let pieceBytes = piece.utf8.count
      if emittedBytes + pieceBytes > maxByteLength {
        truncated = true
        break
      }
      escaped += piece
      emittedBytes += pieceBytes
    }

    if truncated {
      escaped += "\n[TRUNCATED: showing first \(emittedBytes) of \(originalByteCount) bytes]"
    }

    return CommandProposalSafeText(
      displayText: escaped,
      copyText: escaped,
      truncated: truncated,
      originalByteCount: originalByteCount)
  }

  private static func escapeScalar(_ scalar: Unicode.Scalar) -> String {
    if isBidiOverride(scalar) {
      return bidiLabel(scalar)
    }
    if shouldEscapeInvisible(scalar) {
      return invisibleLabel(scalar)
    }
    switch scalar.value {
    case 0x09:
      return "\\t"
    case 0x0A:
      return "\\n"
    case 0x0D:
      return "\\r"
    case 0x1B:
      return "\\e"
    case 0x20...0x7E:
      return String(scalar)
    case 0x00...0x1F, 0x7F...0x9F:
      return String(format: "\\x%02x", UInt8(scalar.value))
    default:
      return String(scalar)
    }
  }

  private static func shouldEscapeInvisible(_ scalar: Unicode.Scalar) -> Bool {
    if scalar.properties.isDefaultIgnorableCodePoint { return true }
    switch scalar.properties.generalCategory {
    case .format, .surrogate, .privateUse:
      return true
    default:
      break
    }
    switch scalar.value {
    case 0x00AD, 0x200B, 0x200C, 0x200D, 0xFEFF:
      return true
    case 0xFE00...0xFE0F, 0xE0100...0xE01EF:
      return true
    default:
      return false
    }
  }

  private static func invisibleLabel(_ scalar: Unicode.Scalar) -> String {
    "[INVIS:U+\(String(scalar.value, radix: 16, uppercase: true))]"
  }

  private static func isBidiOverride(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069:
      return true
    default:
      return false
    }
  }

  private static func bidiLabel(_ scalar: Unicode.Scalar) -> String {
    let name: String
    switch scalar.value {
    case 0x202A: name = "LRE"
    case 0x202B: name = "RLE"
    case 0x202C: name = "PDF"
    case 0x202D: name = "LRO"
    case 0x202E: name = "RLO"
    case 0x2066: name = "LRI"
    case 0x2067: name = "RLI"
    case 0x2068: name = "FSI"
    case 0x2069: name = "PDI"
    default: name = "BIDI"
    }
    return "[BIDI:\(name) U+\(String(scalar.value, radix: 16, uppercase: true))]"
  }
}

public final class CommandProposalStore: @unchecked Sendable {
  public static let shared = CommandProposalStore()
  public static let maxStoredProposals = 64
  public static let maxCommandBytes = 4096
  public static let maxPurposeBytes = 1024
  /// A proposal left in `pendingReview` past this age is reported `expired` on
  /// the next read, so an agent polling `commandProposal.get` sees a terminal
  /// state instead of a proposal that lingers forever after the user walked
  /// away from the review UI.
  public static let pendingReviewTTL: TimeInterval = 30 * 60

  public enum SubmitError: Error, Equatable {
    case commandTooLarge
    case purposeTooLarge
    case storeFull
  }

  /// Result of a `cancel` request. `cancel` only transitions a proposal that is
  /// still `pendingReview`; any terminal state is reported back so the caller
  /// can map it to a `409`-style response rather than silently succeeding.
  public enum CancelResult: Equatable {
    case cancelled(CommandProposal)
    case notFound
    case alreadyTerminal(CommandProposalState)
  }

  private let lock = NSLock()
  private var proposals: [String: CommandProposal] = [:]
  private let now: @Sendable () -> Date

  public init(now: @escaping @Sendable () -> Date = { Date() }) {
    self.now = now
  }

  /// Applies lazy TTL expiry to a stored proposal: a `pendingReview` proposal
  /// older than `pendingReviewTTL` is reported (and persisted) as `expired`.
  /// Callers must hold `lock`.
  private func resolvedLocked(_ proposal: CommandProposal) -> CommandProposal {
    guard proposal.state == .pendingReview else { return proposal }
    guard now().timeIntervalSince(proposal.createdAt) >= Self.pendingReviewTTL else {
      return proposal
    }
    var expired = proposal
    expired.state = .expired
    proposals[proposal.id] = expired
    return expired
  }

  @discardableResult
  public func submit(
    command: String,
    purpose: String?,
    targetSessionID: String
  ) throws -> CommandProposal {
    guard command.utf8.count <= Self.maxCommandBytes else {
      throw SubmitError.commandTooLarge
    }
    if let purpose, purpose.utf8.count > Self.maxPurposeBytes {
      throw SubmitError.purposeTooLarge
    }
    lock.lock()
    defer { lock.unlock() }
    // Keep only proposals still awaiting review; terminal ones (ran, dismissed,
    // cancelled, expired) are dropped so the store does not grow without bound.
    proposals = proposals.filter { _, proposal in
      resolvedLocked(proposal).state == .pendingReview
    }
    guard proposals.count < Self.maxStoredProposals else {
      throw SubmitError.storeFull
    }
    let proposal = CommandProposal(
      targetSessionID: targetSessionID,
      command: command,
      purpose: purpose,
      createdAt: now())
    proposals[proposal.id] = proposal
    return proposal
  }

  public func proposal(id: String) -> CommandProposal? {
    lock.lock()
    defer { lock.unlock() }
    guard let proposal = proposals[id] else { return nil }
    return resolvedLocked(proposal)
  }

  /// All proposals whose target session is `sessionID`, newest first, with TTL
  /// expiry applied. Session scoping is enforced by the caller (router), which
  /// passes the caller's own scoped session.
  public func list(targetSessionID: String) -> [CommandProposal] {
    lock.lock()
    defer { lock.unlock() }
    return proposals.values
      .map { resolvedLocked($0) }
      .filter { $0.targetSessionID == targetSessionID }
      .sorted { $0.createdAt > $1.createdAt }
  }

  /// Cancels a `pendingReview` proposal, moving it to `cancelledByAgent`. A
  /// proposal already in a terminal state is not changed.
  public func cancel(id: String) -> CancelResult {
    lock.lock()
    defer { lock.unlock() }
    guard let stored = proposals[id] else { return .notFound }
    let resolved = resolvedLocked(stored)
    guard resolved.state == .pendingReview else {
      return .alreadyTerminal(resolved.state)
    }
    var cancelled = resolved
    cancelled.state = .cancelledByAgent
    proposals[id] = cancelled
    return .cancelled(cancelled)
  }

  public func updateState(id: String, state: CommandProposalState) {
    lock.lock()
    defer { lock.unlock() }
    guard var proposal = proposals[id] else { return }
    proposal.state = state
    proposals[id] = proposal
  }

  #if DEBUG
    public func resetForTesting() {
      lock.lock()
      proposals = [:]
      lock.unlock()
    }
  #endif
}

public enum CommandProposalService {
  public enum ProposeError: Error, Equatable {
    case commandTooLarge
    case purposeTooLarge
    case storeFull
  }

  public static func propose(
    command: String,
    purpose: String?,
    targetSessionID: String
  ) throws -> CommandProposeResponse {
    let proposal = try CommandProposalStore.shared.submit(
      command: command,
      purpose: purpose,
      targetSessionID: targetSessionID)
    return CommandProposeResponse(
      ok: true,
      proposalID: proposal.id,
      targetSessionID: targetSessionID,
      state: .pendingReview,
      writtenToPTY: false)
  }
}
