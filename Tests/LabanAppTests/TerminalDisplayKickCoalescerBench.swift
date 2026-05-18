import Darwin
import Foundation
import XCTest

@testable import LabanApp

/// Microbench for TerminalDisplayKickCoalescer wake overhead.
///
/// XCTest runs `testWakeOverhead` on the main thread; the coalescer
/// posts its wake closure to the MainActor. To avoid deadlock we run
/// the bench loop on a background queue and let the main runloop
/// service the wakes. Each iteration measures one full
/// background → main → background round trip:
///
///   bg: requestFrameAdvance(now) { done.signal() }
///   main: closure runs, signals
///   bg: done.wait() returns
///
/// The cost we're isolating: per-wake Task creation vs.
/// DispatchQueue.main.async. Bursts inside a single iteration would be
/// collapsed by the coalescer; one iteration intentionally drives one
/// fresh burst.
final class TerminalDisplayKickCoalescerBench: XCTestCase {

  func testWakeOverhead() throws {
    guard ProcessInfo.processInfo.environment["LABAN_RUN_COALESCER_BENCH"] == "1" else {
      throw XCTSkip("set LABAN_RUN_COALESCER_BENCH=1 to enable")
    }

    let iterations = 20_000
    let warmup = 1_000
    let queue = DispatchQueue(label: "bench.coalescer.driver", qos: .userInitiated)
    let coalescer = TerminalDisplayKickCoalescer()
    let done = DispatchSemaphore(value: 0)
    let finished = expectation(description: "bench done")
    var samples: [UInt64] = []
    samples.reserveCapacity(iterations)

    queue.async {
      for _ in 0..<warmup {
        coalescer.requestFrameAdvance(now: Date()) { @MainActor in
          done.signal()
        }
        done.wait()
      }
      for _ in 0..<iterations {
        let start = DispatchTime.now().uptimeNanoseconds
        coalescer.requestFrameAdvance(now: Date()) { @MainActor in
          done.signal()
        }
        done.wait()
        let end = DispatchTime.now().uptimeNanoseconds
        samples.append(end &- start)
      }
      finished.fulfill()
    }
    wait(for: [finished], timeout: 120)

    let sorted = samples.sorted()
    let totalNs = sorted.reduce(UInt64(0), +)
    let meanNs = Double(totalNs) / Double(sorted.count)
    let p50Ns = sorted[sorted.count / 2]
    let p95Ns = sorted[Int(Double(sorted.count - 1) * 0.95)]
    let p99Ns = sorted[Int(Double(sorted.count - 1) * 0.99)]
    let label: String
    #if LABAN_COALESCER_DISPATCH
      label = "dispatch"
    #else
      label = "task"
    #endif
    print(
      String(
        format:
          "BENCH coalescer=%@ n=%d wake_mean=%.2fµs p50=%.2fµs p95=%.2fµs p99=%.2fµs total=%.1fms",
        label,
        iterations,
        meanNs / 1000.0,
        Double(p50Ns) / 1000.0,
        Double(p95Ns) / 1000.0,
        Double(p99Ns) / 1000.0,
        Double(totalNs) / 1_000_000.0))
  }
}
