import Foundation
import os

final class TerminalDisplayKickCoalescer: @unchecked Sendable {
  private let pendingDisplayKick = OSAllocatedUnfairLock(initialState: false)
  private let latestOutputDirtyAt = OSAllocatedUnfairLock<Date?>(initialState: nil)

  func latestDirtyAt() -> Date? {
    latestOutputDirtyAt.withLock { $0 }
  }

  func requestFrameAdvance(
    now: Date = Date(),
    advanceFrame: @escaping @MainActor () -> Void
  ) {
    latestOutputDirtyAt.withLock { $0 = now }
    let alreadyPending = pendingDisplayKick.withLock { value -> Bool in
      let wasPending = value
      value = true
      return wasPending
    }
    guard !alreadyPending else { return }

    Task { @MainActor in
      self.pendingDisplayKick.withLock { $0 = false }
      advanceFrame()
    }
  }
}
