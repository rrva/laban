import Foundation

final class LabandSnapshotGenerationMonitor: @unchecked Sendable {
  typealias GenerationProvider = @Sendable (_ sessionId: String) -> UInt64?
  typealias WakeHandler = @Sendable (_ sessionId: String, _ now: Date) -> Void

  private let generationProvider: GenerationProvider
  private let wakeHandler: WakeHandler
  private let interval: DispatchTimeInterval
  private let queue: DispatchQueue
  private let lock = NSLock()
  private var generationsBySessionId: [String: UInt64] = [:]
  private var timer: DispatchSourceTimer?
  private var stopped = false

  init(
    interval: DispatchTimeInterval = .milliseconds(8),
    queue: DispatchQueue = DispatchQueue(
      label: "laban.laband.snapshot-generation-monitor",
      qos: .userInteractive),
    generationProvider: @escaping GenerationProvider,
    wakeHandler: @escaping WakeHandler
  ) {
    self.interval = interval
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
    source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(1))

    lock.lock()
    guard !stopped, timer == nil, !generationsBySessionId.isEmpty else {
      lock.unlock()
      source.cancel()
      return
    }
    timer = source
    lock.unlock()
    source.resume()
  }

  private func poll() {
    lock.lock()
    let sessionIds = Array(generationsBySessionId.keys)
    let shouldPoll = !stopped && !sessionIds.isEmpty
    lock.unlock()
    guard shouldPoll else { return }

    for sessionId in sessionIds {
      guard let generation = generationProvider(sessionId) else { continue }

      var shouldWake = false
      lock.lock()
      if let previous = generationsBySessionId[sessionId] {
        if generation > previous {
          generationsBySessionId[sessionId] = generation
          shouldWake = true
        }
      }
      lock.unlock()

      if shouldWake {
        wakeHandler(sessionId, Date())
      }
    }
  }
}
