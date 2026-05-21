import AppKit
import Foundation

/// Background update check orchestrator. Runs at startup, on a coarse timer,
/// and after wake / app-activate. Failures are silent — only "update available"
/// surfaces to the user, via the badge.
final class UpdateAutoChecker {
  private weak var badge: UpdateBadgeView?
  private let onUpdateAvailable: (UpdateManifest) -> Void
  private var timer: Timer?
  private var inFlight = false

  init(badge: UpdateBadgeView, onUpdateAvailable: @escaping (UpdateManifest) -> Void) {
    self.badge = badge
    self.onUpdateAvailable = onUpdateAvailable
  }

  func start() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
      self?.runCheckIfDue(trigger: .launch)
    }
    timer = Timer.scheduledTimer(
      withTimeInterval: UpdateAutoCheck.pollInterval, repeats: true
    ) { [weak self] _ in
      self?.runCheckIfDue(trigger: .running)
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(activeOrWake),
      name: NSApplication.didBecomeActiveNotification,
      object: nil)
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(activeOrWake),
      name: NSWorkspace.didWakeNotification,
      object: nil)
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    NotificationCenter.default.removeObserver(self)
    NSWorkspace.shared.notificationCenter.removeObserver(self)
  }

  deinit { stop() }

  @objc private func activeOrWake() {
    runCheckIfDue(trigger: .running)
  }

  private func runCheckIfDue(trigger: UpdateAutoCheck.Trigger) {
    guard !inFlight else { return }
    let manifestURL = UpdateChecker.configuredManifestURL()
    let decision = UpdateAutoCheck.decide(
      version: BuildInfo.version,
      manifestURLConfigured: manifestURL != nil,
      lastCheck: UpdateAutoCheck.loadLastCheck(),
      now: Date(),
      trigger: trigger)
    guard decision == .check, let manifestURL else { return }

    inFlight = true
    AppLog.app.info("update auto-check started")
    EventLog.shared.log("update.auto.start", ["url": manifestURL.absoluteString])
    UpdateChecker.check(manifestURL: manifestURL, currentVersion: BuildInfo.version) {
      [weak self] result in
      DispatchQueue.main.async {
        self?.inFlight = false
        UpdateAutoCheck.recordCheck(Date())
        self?.handle(result)
      }
    }
  }

  private func handle(_ result: Result<UpdateCheckResult, Error>) {
    switch result {
    case .success(.available(let manifest)):
      AppLog.app.info("update auto-check: available \(manifest.latest)")
      EventLog.shared.log(
        "update.auto.available",
        ["latest": manifest.latest, "current": BuildInfo.version])
      badge?.showUpdate(version: manifest.latest, notes: manifest.notes) {
        [onUpdateAvailable] in
        onUpdateAvailable(manifest)
      }
    case .success(.upToDate):
      badge?.clear()
    case .failure(let error):
      AppLog.app.error("update auto-check failed: \(error.localizedDescription)")
      EventLog.shared.log("update.auto.failed", ["error": error.localizedDescription])
    // Silent: leave badge as-is. A stale "available" badge from a prior
    // success stays visible until the next successful up-to-date result.
    }
  }
}
