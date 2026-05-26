import Foundation

final class LabandSnapshotGenerationMonitor: @unchecked Sendable {
  typealias GenerationProvider = @Sendable (_ sessionId: String) -> UInt64?
  typealias WakeHandler = @Sendable (_ sessionId: String, _ now: Date) -> Void

  private let generationProvider: GenerationProvider
  private let wakeHandler: WakeHandler
  private let idleInterval: DispatchTimeInterval
  private let activeInterval: DispatchTimeInterval
  private let activeDuration: TimeInterval
  private let queue: DispatchQueue
  private let lock = NSLock()
  private var generationsBySessionId: [String: UInt64] = [:]
  private var activeUntil: Date?
  private var timer: DispatchSourceTimer?
  private var stopped = false

  init(
    interval: DispatchTimeInterval = .milliseconds(8),
    activeInterval: DispatchTimeInterval = .milliseconds(2),
    activeDuration: TimeInterval = 0.150,
    queue: DispatchQueue = DispatchQueue(
      label: "laban.laband.snapshot-generation-monitor",
      qos: .userInteractive),
    generationProvider: @escaping GenerationProvider,
    wakeHandler: @escaping WakeHandler
  ) {
    self.idleInterval = interval
    self.activeInterval = activeInterval
    self.activeDuration = activeDuration
    self.queue = queue
    self.generationProvider = generationProvider
    self.wakeHandler = wakeHandler
  }

  deinit {
    stop()
  }

  func track(sessionId: String) {
    guard !sessionId.isEmpty else { return }
    let initialGeneration = generationProvider(sessionId) ?? 0

    lock.lock()
    guard !stopped else {
      lock.unlock()
      return
    }
    generationsBySessionId[sessionId] = initialGeneration
    let shouldStart = timer == nil
    lock.unlock()

    if shouldStart {
      startTimerIfNeeded()
    }
  }

  func boost(sessionId: String) {
    guard !sessionId.isEmpty else { return }
    let source: DispatchSourceTimer?
    let boostedUntil = Date().addingTimeInterval(activeDuration)
    lock.lock()
    guard !stopped, generationsBySessionId[sessionId] != nil else {
      lock.unlock()
      return
    }
    if activeUntil.map({ $0 < boostedUntil }) ?? true {
      activeUntil = boostedUntil
    }
    source = timer
    lock.unlock()

    source?.schedule(deadline: .now() + activeInterval, leeway: .milliseconds(1))
  }

  func untrack(sessionId: String) {
    let timerToCancel: DispatchSourceTimer?
    lock.lock()
    generationsBySessionId.removeValue(forKey: sessionId)
    if generationsBySessionId.isEmpty {
      timerToCancel = timer
      timer = nil
    } else {
      timerToCancel = nil
    }
    lock.unlock()
    timerToCancel?.cancel()
  }

  func stop() {
    let timerToCancel: DispatchSourceTimer?
    lock.lock()
    stopped = true
    generationsBySessionId.removeAll()
    timerToCancel = timer
    timer = nil
    lock.unlock()
    timerToCancel?.cancel()
  }

  private func startTimerIfNeeded() {
    let source = DispatchSource.makeTimerSource(queue: queue)
    source.setEventHandler { [weak self] in
      self?.poll()
    }

    lock.lock()
    guard !stopped, timer == nil, !generationsBySessionId.isEmpty else {
      lock.unlock()
      source.cancel()
      return
    }
    timer = source
    lock.unlock()
    source.schedule(deadline: .now() + idleInterval, leeway: .milliseconds(1))
    source.resume()
  }

  private func poll() {
    lock.lock()
    let sessionIds = Array(generationsBySessionId.keys)
    let shouldPoll = !stopped && !sessionIds.isEmpty
    lock.unlock()
    guard shouldPoll else { return }

    let now = Date()
    for sessionId in sessionIds {
      guard let generation = generationProvider(sessionId) else { continue }

      var shouldWake = false
      lock.lock()
      if let previous = generationsBySessionId[sessionId] {
        if generation > previous {
          generationsBySessionId[sessionId] = generation
          let boostedUntil = now.addingTimeInterval(activeDuration)
          if activeUntil.map({ $0 < boostedUntil }) ?? true {
            activeUntil = boostedUntil
          }
          shouldWake = true
        }
      }
      lock.unlock()

      if shouldWake {
        wakeHandler(sessionId, now)
      }
    }
    scheduleNextTimer()
  }

  private func scheduleNextTimer() {
    let source: DispatchSourceTimer?
    let interval: DispatchTimeInterval
    lock.lock()
    guard !stopped, !generationsBySessionId.isEmpty, let timer else {
      lock.unlock()
      return
    }
    let active = activeUntil.map { $0 > Date() } ?? false
    source = timer
    interval = active ? activeInterval : idleInterval
    lock.unlock()

    source?.schedule(deadline: .now() + interval, leeway: .milliseconds(1))
  }
}
