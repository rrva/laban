import Foundation

public enum NativeNotificationDiagnosticStage: String, Codable, Sendable {
  case settings
  case authorizationRequestFailed
  case testRequested
  case submit
  case added
  case addFailed
  case decision
  case willPresent
}

public struct NativeNotificationSettingsSnapshot: Codable, Equatable, Sendable {
  public var authorizationStatus: String
  public var alertSetting: String
  public var notificationCenterSetting: String
  public var soundSetting: String
  public var alertStyle: String
  public var canShowAlert: Bool

  public init(
    authorizationStatus: String,
    alertSetting: String,
    notificationCenterSetting: String,
    soundSetting: String,
    alertStyle: String,
    canShowAlert: Bool
  ) {
    self.authorizationStatus = authorizationStatus
    self.alertSetting = alertSetting
    self.notificationCenterSetting = notificationCenterSetting
    self.soundSetting = soundSetting
    self.alertStyle = alertStyle
    self.canShowAlert = canShowAlert
  }
}

public struct NativeNotificationRuntimeIdentity: Codable, Equatable, Sendable {
  public var bundleIdentifier: String?
  public var bundlePath: String
  public var buildCommit: String
  public var buildDate: String
  public var signingMode: String
  public var teamIdentifier: String?
  public var cdHash: String?

  public init(
    bundleIdentifier: String?,
    bundlePath: String,
    buildCommit: String,
    buildDate: String,
    signingMode: String,
    teamIdentifier: String?,
    cdHash: String?
  ) {
    self.bundleIdentifier = bundleIdentifier
    self.bundlePath = bundlePath
    self.buildCommit = buildCommit
    self.buildDate = buildDate
    self.signingMode = signingMode
    self.teamIdentifier = teamIdentifier
    self.cdHash = cdHash
  }
}

public enum NativeNotificationFocusAuthorizationStatus: String, Codable, Sendable {
  /// The user has not run the explicit Focus troubleshooting check in this process.
  case notChecked
  case notDetermined
  case restricted
  case denied
  case authorized
  case unavailable
  case unknown
}

public struct NativeNotificationFocusSnapshot: Codable, Equatable, Sendable {
  public var authorizationStatus: NativeNotificationFocusAuthorizationStatus
  public var suppressesNotifications: Bool?
  public var checkedAt: Date?

  public init(
    authorizationStatus: NativeNotificationFocusAuthorizationStatus,
    suppressesNotifications: Bool?,
    checkedAt: Date? = nil
  ) {
    self.authorizationStatus = authorizationStatus
    self.suppressesNotifications = suppressesNotifications
    self.checkedAt = checkedAt
  }

  public static let notChecked = NativeNotificationFocusSnapshot(
    authorizationStatus: .notChecked,
    suppressesNotifications: nil)

  public static let unavailable = NativeNotificationFocusSnapshot(
    authorizationStatus: .unavailable,
    suppressesNotifications: nil)
}

public struct NativeNotificationDiagnosticEvent: Codable, Equatable, Sendable {
  public var sequence: Int
  public var timestamp: Date
  public var eventId: String
  public var tabId: String?
  public var source: String?
  public var category: String?
  public var stage: NativeNotificationDiagnosticStage
  public var outcome: String?
  public var suppressionReason: String?
  public var errorDomain: String?
  public var errorCode: Int?
  public var presentationOptions: [String]?

  public init(
    sequence: Int,
    timestamp: Date,
    eventId: String,
    tabId: String? = nil,
    source: String? = nil,
    category: String? = nil,
    stage: NativeNotificationDiagnosticStage,
    outcome: String? = nil,
    suppressionReason: String? = nil,
    errorDomain: String? = nil,
    errorCode: Int? = nil,
    presentationOptions: [String]? = nil
  ) {
    self.sequence = sequence
    self.timestamp = timestamp
    self.eventId = eventId
    self.tabId = tabId
    self.source = source
    self.category = category
    self.stage = stage
    self.outcome = outcome
    self.suppressionReason = suppressionReason
    self.errorDomain = errorDomain
    self.errorCode = errorCode
    self.presentationOptions = presentationOptions
  }
}

public struct NativeNotificationDiagnosticsSnapshot: Codable, Equatable, Sendable {
  public var nativeAvailable: Bool
  public var refreshInFlight: Bool
  public var lastRefreshedAt: Date?
  public var settings: NativeNotificationSettingsSnapshot?
  public var pendingCount: Int?
  public var deliveredCount: Int?
  public var focusAuthorizationStatus: NativeNotificationFocusAuthorizationStatus
  public var focusSuppressesNotifications: Bool?
  public var focusCheckedAt: Date?
  public var identity: NativeNotificationRuntimeIdentity?
  public var events: [NativeNotificationDiagnosticEvent]
  public var nextSequence: Int

  public init(
    nativeAvailable: Bool,
    refreshInFlight: Bool,
    lastRefreshedAt: Date?,
    settings: NativeNotificationSettingsSnapshot?,
    pendingCount: Int?,
    deliveredCount: Int?,
    focusAuthorizationStatus: NativeNotificationFocusAuthorizationStatus,
    focusSuppressesNotifications: Bool?,
    focusCheckedAt: Date?,
    identity: NativeNotificationRuntimeIdentity?,
    events: [NativeNotificationDiagnosticEvent],
    nextSequence: Int
  ) {
    self.nativeAvailable = nativeAvailable
    self.refreshInFlight = refreshInFlight
    self.lastRefreshedAt = lastRefreshedAt
    self.settings = settings
    self.pendingCount = pendingCount
    self.deliveredCount = deliveredCount
    self.focusAuthorizationStatus = focusAuthorizationStatus
    self.focusSuppressesNotifications = focusSuppressesNotifications
    self.focusCheckedAt = focusCheckedAt
    self.identity = identity
    self.events = events
    self.nextSequence = nextSequence
  }

  private enum CodingKeys: String, CodingKey {
    case nativeAvailable
    case refreshInFlight
    case lastRefreshedAt
    case settings
    case pendingCount
    case deliveredCount
    case focusAuthorizationStatus
    case focusSuppressesNotifications
    case focusCheckedAt
    case identity
    case events
    case nextSequence
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(nativeAvailable, forKey: .nativeAvailable)
    try container.encode(refreshInFlight, forKey: .refreshInFlight)
    try container.encode(lastRefreshedAt, forKey: .lastRefreshedAt)
    try container.encode(settings, forKey: .settings)
    try container.encode(pendingCount, forKey: .pendingCount)
    try container.encode(deliveredCount, forKey: .deliveredCount)
    try container.encode(focusAuthorizationStatus, forKey: .focusAuthorizationStatus)
    try container.encode(focusSuppressesNotifications, forKey: .focusSuppressesNotifications)
    try container.encode(focusCheckedAt, forKey: .focusCheckedAt)
    try container.encode(identity, forKey: .identity)
    try container.encode(events, forKey: .events)
    try container.encode(nextSequence, forKey: .nextSequence)
  }
}

public final class NativeNotificationDiagnosticsStore: @unchecked Sendable {
  public static let shared = NativeNotificationDiagnosticsStore()

  private let lock = NSLock()
  private let capacity: Int
  private var nativeAvailable: Bool
  private var refreshInFlight = false
  private var refreshGeneration = 0
  private var lastRefreshedAt: Date?
  private var settings: NativeNotificationSettingsSnapshot?
  private var pendingCount: Int?
  private var deliveredCount: Int?
  private var focusStatus: NativeNotificationFocusSnapshot
  private var events: [NativeNotificationDiagnosticEvent] = []
  private var nextSequence = 1

  public init(capacity: Int = 64, nativeAvailable: Bool = true) {
    self.capacity = max(1, capacity)
    self.nativeAvailable = nativeAvailable
    self.focusStatus = nativeAvailable ? .notChecked : .unavailable
  }

  public func setNativeAvailable(_ available: Bool) {
    withLock {
      nativeAvailable = available
    }
  }

  public func beginRefresh() -> Int? {
    withLock {
      guard !refreshInFlight else { return nil }
      refreshGeneration += 1
      refreshInFlight = true
      return refreshGeneration
    }
  }

  public func finishRefresh(
    generation: Int,
    settings: NativeNotificationSettingsSnapshot?,
    pendingCount: Int?,
    deliveredCount: Int?,
    timestamp: Date = Date()
  ) {
    withLock {
      guard refreshInFlight, generation == refreshGeneration else { return }
      refreshInFlight = false
      lastRefreshedAt = timestamp
      if let settings { self.settings = settings }
      self.pendingCount = pendingCount
      self.deliveredCount = deliveredCount
    }
  }

  public func failRefresh(generation: Int) {
    withLock {
      guard refreshInFlight, generation == refreshGeneration else { return }
      refreshInFlight = false
    }
  }

  public func updateSettings(_ settings: NativeNotificationSettingsSnapshot) {
    withLock {
      self.settings = settings
    }
  }

  /// Cache the result of the user-triggered Focus troubleshooting check.
  /// This store never reads Focus itself; callers must update it explicitly.
  public func updateFocusStatus(_ status: NativeNotificationFocusSnapshot) {
    withLock {
      focusStatus = status
    }
  }

  public func focusSnapshot() -> NativeNotificationFocusSnapshot {
    withLock { focusStatus }
  }

  @discardableResult
  public func record(
    eventId: String,
    tabId: String? = nil,
    source: String? = nil,
    category: String? = nil,
    stage: NativeNotificationDiagnosticStage,
    outcome: String? = nil,
    suppressionReason: String? = nil,
    errorDomain: String? = nil,
    errorCode: Int? = nil,
    presentationOptions: [String]? = nil,
    timestamp: Date = Date()
  ) -> Int {
    withLock {
      let sequence = nextSequence
      nextSequence += 1
      events.append(
        NativeNotificationDiagnosticEvent(
          sequence: sequence,
          timestamp: timestamp,
          eventId: eventId,
          tabId: tabId,
          source: source,
          category: category,
          stage: stage,
          outcome: outcome,
          suppressionReason: suppressionReason,
          errorDomain: errorDomain,
          errorCode: errorCode,
          presentationOptions: presentationOptions))
      if events.count > capacity {
        events.removeFirst(events.count - capacity)
      }
      return sequence
    }
  }

  public func snapshot(
    since: Int? = nil,
    identity: NativeNotificationRuntimeIdentity? = nil
  ) -> NativeNotificationDiagnosticsSnapshot {
    withLock {
      NativeNotificationDiagnosticsSnapshot(
        nativeAvailable: nativeAvailable,
        refreshInFlight: refreshInFlight,
        lastRefreshedAt: lastRefreshedAt,
        settings: settings,
        pendingCount: pendingCount,
        deliveredCount: deliveredCount,
        focusAuthorizationStatus: focusStatus.authorizationStatus,
        focusSuppressesNotifications: focusStatus.suppressesNotifications,
        focusCheckedAt: focusStatus.checkedAt,
        identity: identity,
        events: events.filter { event in
          guard let since else { return true }
          return event.sequence >= since
        },
        nextSequence: nextSequence)
    }
  }

  private func withLock<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}
