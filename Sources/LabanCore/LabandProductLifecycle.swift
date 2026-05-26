import Foundation

public enum LabandProtocolCompatibilityStatus: String, Codable, Equatable, Sendable {
  case current
  case olderCompatible
  case daemonTooOld
  case daemonTooNew
}

public struct LabandProtocolSupport: Codable, Equatable, Sendable {
  public var current: Int
  public var minimumCompatible: Int

  public init(
    current: Int = LabandProtocolVersion.current,
    minimumCompatible: Int = LabandProtocolVersion.minimumCompatible
  ) {
    self.current = current
    self.minimumCompatible = minimumCompatible
  }

  public func negotiate(with hello: LabandHelloResponse) -> LabandProtocolNegotiation {
    let daemonCurrent = hello.protocolVersion
    let daemonMinimum = hello.minimumProtocolVersion ?? daemonCurrent
    let lowestUsable = max(minimumCompatible, daemonMinimum)
    let highestUsable = min(current, daemonCurrent)
    guard lowestUsable <= highestUsable else {
      if daemonCurrent < minimumCompatible {
        return LabandProtocolNegotiation(
          status: .daemonTooOld,
          selectedProtocolVersion: nil,
          daemonProtocolVersion: daemonCurrent,
          daemonMinimumProtocolVersion: daemonMinimum
        )
      }
      return LabandProtocolNegotiation(
        status: .daemonTooNew,
        selectedProtocolVersion: nil,
        daemonProtocolVersion: daemonCurrent,
        daemonMinimumProtocolVersion: daemonMinimum
      )
    }
    return LabandProtocolNegotiation(
      status: highestUsable == current ? .current : .olderCompatible,
      selectedProtocolVersion: highestUsable,
      daemonProtocolVersion: daemonCurrent,
      daemonMinimumProtocolVersion: daemonMinimum
    )
  }
}

public struct LabandProtocolNegotiation: Codable, Equatable, Sendable {
  public var status: LabandProtocolCompatibilityStatus
  public var selectedProtocolVersion: Int?
  public var daemonProtocolVersion: Int
  public var daemonMinimumProtocolVersion: Int
}

public enum LabandUpgradePromptDefaultChoice: String, Codable, Equatable, Sendable {
  case continueCurrentHelper
  case closeSessionsAndUpgrade
}

public struct LabandLiveSessionSummary: Codable, Equatable, Sendable {
  public var logicalSessionId: String
  public var title: String
  public var commandDisplayName: String
  public var childPid: Int?

  public init(
    logicalSessionId: String,
    title: String,
    commandDisplayName: String,
    childPid: Int?
  ) {
    self.logicalSessionId = logicalSessionId
    self.title = title
    self.commandDisplayName = commandDisplayName
    self.childPid = childPid
  }

  public static func live(from sessions: [LabandSessionInfo]) -> [LabandLiveSessionSummary] {
    sessions.compactMap { session in
      guard session.lifecycleState == .running else { return nil }
      return LabandLiveSessionSummary(
        logicalSessionId: session.logicalSessionId,
        title: session.title,
        commandDisplayName: session.commandDisplayName,
        childPid: session.childPid
      )
    }
  }
}

public struct LabandUpgradePromptModel: Codable, Equatable, Sendable {
  public var title: String
  public var message: String
  public var liveSessions: [LabandLiveSessionSummary]
  public var defaultChoice: LabandUpgradePromptDefaultChoice

  public init(
    title: String,
    message: String,
    liveSessions: [LabandLiveSessionSummary],
    defaultChoice: LabandUpgradePromptDefaultChoice
  ) {
    self.title = title
    self.message = message
    self.liveSessions = liveSessions
    self.defaultChoice = defaultChoice
  }
}

public enum LabandLifecycleDecision: Equatable, Sendable {
  case connect(protocolVersion: Int, compatibility: LabandProtocolCompatibilityStatus, capabilities: [String])
  case restartIdleHelper(reason: String)
  case promptBeforeUpgrade(LabandUpgradePromptModel)
}

public struct LabandLifecyclePolicy: Equatable, Sendable {
  public var protocolSupport: LabandProtocolSupport

  public init(protocolSupport: LabandProtocolSupport = LabandProtocolSupport()) {
    self.protocolSupport = protocolSupport
  }

  public func decision(
    hello: LabandHelloResponse,
    sessions: [LabandSessionInfo]
  ) -> LabandLifecycleDecision {
    decision(hello: hello, liveSessions: LabandLiveSessionSummary.live(from: sessions))
  }

  public func decision(
    hello: LabandHelloResponse,
    liveSessions: [LabandLiveSessionSummary]
  ) -> LabandLifecycleDecision {
    let negotiation = protocolSupport.negotiate(with: hello)
    if let selectedProtocolVersion = negotiation.selectedProtocolVersion {
      return .connect(
        protocolVersion: selectedProtocolVersion,
        compatibility: negotiation.status,
        capabilities: hello.capabilities
      )
    }
    if liveSessions.isEmpty {
      return .restartIdleHelper(
        reason: "laband protocol \(hello.protocolVersion) is incompatible and no live sessions exist"
      )
    }
    return .promptBeforeUpgrade(
      LabandUpgradePromptModel(
        title: "Live terminal sessions are still running",
        message:
          "Continue with the current helper or close selected sessions to upgrade it.",
        liveSessions: liveSessions,
        defaultChoice: .continueCurrentHelper
      )
    )
  }
}

public protocol LabandLifecycleClient {
  func hello() throws -> LabandHelloResponse
  func listSessions() throws -> [LabandSessionInfo]
}

extension LabandTerminalSessionClient: LabandLifecycleClient {}

public struct LabandLifecycleEvaluation: Equatable, Sendable {
  public var hello: LabandHelloResponse
  public var liveSessions: [LabandLiveSessionSummary]
  public var decision: LabandLifecycleDecision
}

public struct LabandProductLifecycleController: Sendable {
  public var policy: LabandLifecyclePolicy

  public init(policy: LabandLifecyclePolicy = LabandLifecyclePolicy()) {
    self.policy = policy
  }

  public func evaluate(client: any LabandLifecycleClient) throws -> LabandLifecycleEvaluation {
    let hello = try client.hello()
    let sessions = try client.listSessions()
    let liveSessions = LabandLiveSessionSummary.live(from: sessions)
    return LabandLifecycleEvaluation(
      hello: hello,
      liveSessions: liveSessions,
      decision: policy.decision(hello: hello, liveSessions: liveSessions)
    )
  }
}

public struct LabandProductPaths: Equatable, Sendable {
  public var applicationSupportURL: URL
  public var labandDirectoryURL: URL
  public var journalDirectoryURL: URL
  public var logDirectoryURL: URL

  public init(applicationSupportURL: URL) {
    self.applicationSupportURL = applicationSupportURL
    self.labandDirectoryURL = applicationSupportURL.appendingPathComponent("laband", isDirectory: true)
    self.journalDirectoryURL = labandDirectoryURL.appendingPathComponent("journal", isDirectory: true)
    self.logDirectoryURL = labandDirectoryURL.appendingPathComponent("logs", isDirectory: true)
  }

  public static func `default`() -> LabandProductPaths {
    LabandProductPaths(applicationSupportURL: PersistenceStore.defaultBaseURL())
  }

  public func createDirectories(fileManager: FileManager = .default) throws {
    try fileManager.createDirectory(at: journalDirectoryURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)
  }
}

public struct LabandLaunchAgentConfiguration: Equatable, Sendable {
  public var label: String
  public var machServiceName: String
  public var executableURL: URL
  public var paths: LabandProductPaths

  public init(
    label: String = "dev.laban.laband",
    machServiceName: String = "dev.laban.laband.xpc",
    executableURL: URL,
    paths: LabandProductPaths = .default()
  ) {
    self.label = label
    self.machServiceName = machServiceName
    self.executableURL = executableURL
    self.paths = paths
  }

  public var programArguments: [String] {
    [
      executableURL.path,
      "--product",
      "--xpc-service", machServiceName,
      "--journal", paths.journalDirectoryURL.path,
    ]
  }

  public var standardOutputURL: URL {
    paths.logDirectoryURL.appendingPathComponent("stdout.log")
  }

  public var standardErrorURL: URL {
    paths.logDirectoryURL.appendingPathComponent("stderr.log")
  }

  public func propertyList() -> [String: Any] {
    [
      "Label": label,
      "ProgramArguments": programArguments,
      "RunAtLoad": true,
      "KeepAlive": false,
      "MachServices": [machServiceName: true],
      "StandardOutPath": standardOutputURL.path,
      "StandardErrorPath": standardErrorURL.path,
    ]
  }

  public func propertyListData() throws -> Data {
    try PropertyListSerialization.data(
      fromPropertyList: propertyList(),
      format: .xml,
      options: 0
    )
  }
}

@objc public protocol LabandXPCControlProtocol {
  func sendRequest(_ requestData: Data, withReply reply: @escaping (Data) -> Void)
}
