import Foundation

/// Owns live sessions and their reader threads.
///
/// `AppModel` serializes access with its model lock. This type keeps the close
/// ordering in one place: stop a `SessionRunner` before closing the matching
/// `Session`, because the C session destructor requires exclusive access.
final class SessionRegistry {
  private var sessions: [Session.ID: Session] = [:]
  private var sessionRunners: [Session.ID: SessionRunner] = [:]

  weak var captureSink: CaptureSink? {
    didSet {
      for session in sessions.values {
        session.captureSink = captureSink
      }
    }
  }

  var onSessionDirty: (@Sendable (Session.ID) -> Void)?

  var allSessions: [Session] { Array(sessions.values) }

  func session(id: Session.ID) -> Session? {
    sessions[id]
  }

  func add(_ session: Session) {
    session.captureSink = captureSink
    sessions[session.id] = session
    startRunner(for: session)
  }

  func close(sessionId: Session.ID) {
    stopRunner(for: sessionId)
    sessions[sessionId]?.close()
    sessions.removeValue(forKey: sessionId)
  }

  func closeAll() {
    for runner in sessionRunners.values {
      runner.stop()
    }
    sessionRunners.removeAll()
    for session in sessions.values {
      session.close()
    }
    sessions.removeAll()
  }

  func forEachSession(_ body: (Session) -> Void) {
    for session in sessions.values {
      body(session)
    }
  }

  func tabSessions(for tabs: [Tab]) -> [(tab: Tab, session: Session)] {
    tabs.compactMap { tab in
      guard let session = sessions[tab.sessionId] else { return nil }
      return (tab, session)
    }
  }

  private func startRunner(for session: Session) {
    let id = session.id
    guard
      let runner = session.makeRunner(onDirty: { [weak self] in
        self?.onSessionDirty?(id)
      })
    else { return }
    sessionRunners[id] = runner
    runner.start()
  }

  private func stopRunner(for sessionId: Session.ID) {
    if let runner = sessionRunners.removeValue(forKey: sessionId) {
      runner.stop()
    }
  }
}
