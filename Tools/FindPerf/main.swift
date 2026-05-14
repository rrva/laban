import Foundation
import LabanCore
import LabanTerminalCore

private struct PerfMetric {
  var name: String
  var lineCount: Int
  var iterations: Int
  var observedMatches: Int
  var samples: [Double]

  var mean: Double {
    samples.reduce(0, +) / Double(samples.count)
  }

  var p50: Double {
    percentile(0.50)
  }

  var p95: Double {
    percentile(0.95)
  }

  var min: Double {
    samples.min() ?? 0
  }

  var max: Double {
    samples.max() ?? 0
  }

  private func percentile(_ value: Double) -> Double {
    guard !samples.isEmpty else { return 0 }
    let sorted = samples.sorted()
    let index = Swift.min(sorted.count - 1, Int((Double(sorted.count - 1) * value).rounded(.up)))
    return sorted[index]
  }

  func line() -> String {
    String(
      format:
        "%@ lines=%d observed=%d n=%d mean=%.3fms p50=%.3fms p95=%.3fms min=%.3fms max=%.3fms",
      name,
      lineCount,
      observedMatches,
      iterations,
      mean,
      p50,
      p95,
      min,
      max
    )
  }
}

private struct Threshold {
  var meanMs: Double
  var p95Ms: Double
}

private enum FindPerfError: Error, CustomStringConvertible {
  case missingSession
  case noMatches(String)
  case threshold(String)

  var description: String {
    switch self {
    case .missingSession:
      return "could not create initial terminal session"
    case .noMatches(let label):
      return "\(label) produced no find matches"
    case .threshold(let message):
      return message
    }
  }
}

private let args = Set(CommandLine.arguments.dropFirst())
private let guardMode = args.contains("--guard")
private let profileLoop = args.contains("--profile-loop")
private let lineCount = intEnv("LABAN_FIND_PERF_LINES", defaultValue: 10_000)
private let startIterations = intEnv("LABAN_FIND_PERF_START_ITERATIONS", defaultValue: 12)
private let cachedIterations = intEnv("LABAN_FIND_PERF_CACHED_ITERATIONS", defaultValue: 80)
private let profileSeconds = doubleEnv("LABAN_FIND_PERF_PROFILE_SECONDS", defaultValue: 4.0)

do {
  if profileLoop {
    let operations = try runProfileLoop(lineCount: lineCount, seconds: profileSeconds)
    print("profile-loop operations=\(operations)")
  } else {
    print("Find performance guard, release build")
    let start = try measureColdStart(lineCount: lineCount, iterations: startIterations)
    let step = try measureCachedStep(lineCount: lineCount, iterations: cachedIterations)
    let pending = try measurePendingNeedle(lineCount: lineCount, iterations: cachedIterations)
    let metrics = [start, step, pending]
    for metric in metrics {
      print(metric.line())
    }
    if guardMode {
      try enforceThresholds(metrics)
      print("find performance guard passed")
    }
  }
} catch {
  fputs("find performance guard failed: \(error)\n", stderr)
  exit(1)
}

private func measureColdStart(lineCount: Int, iterations: Int) throws -> PerfMetric {
  let fixture = try makeFixture(lineCount: lineCount)
  defer { fixture.model.closeAllSessions() }
  let observed = try warmFind(model: fixture.model, sessionID: fixture.sessionID)
  var samples: [Double] = []
  samples.reserveCapacity(iterations)

  for _ in 0..<iterations {
    _ = fixture.model.stopFind(sessionID: fixture.sessionID)
    samples.append(
      try measureMilliseconds {
        let state = fixture.model.startFind(sessionID: fixture.sessionID, needle: "needle")
        guard let state, state.total > 0 else {
          throw FindPerfError.noMatches("find.start")
        }
      })
  }

  return PerfMetric(
    name: "find.start",
    lineCount: lineCount,
    iterations: iterations,
    observedMatches: observed,
    samples: samples
  )
}

private func measureCachedStep(lineCount: Int, iterations: Int) throws -> PerfMetric {
  let fixture = try makeFixture(lineCount: lineCount)
  defer { fixture.model.closeAllSessions() }
  let observed = try warmFind(model: fixture.model, sessionID: fixture.sessionID)
  var samples: [Double] = []
  samples.reserveCapacity(iterations)

  for _ in 0..<iterations {
    samples.append(
      try measureMilliseconds {
        let state = fixture.model.stepFind(sessionID: fixture.sessionID, direction: .next)
        guard let state, state.total > 0 else {
          throw FindPerfError.noMatches("find.step")
        }
      })
  }

  return PerfMetric(
    name: "find.step",
    lineCount: lineCount,
    iterations: iterations,
    observedMatches: observed,
    samples: samples
  )
}

private func measurePendingNeedle(lineCount: Int, iterations: Int) throws -> PerfMetric {
  let fixture = try makeFixture(lineCount: lineCount)
  defer { fixture.model.closeAllSessions() }
  let observed = try warmFind(model: fixture.model, sessionID: fixture.sessionID)
  var samples: [Double] = []
  samples.reserveCapacity(iterations)

  for iteration in 0..<iterations {
    let needle = iteration.isMultiple(of: 2) ? "needle" : "needlex"
    samples.append(
      try measureMilliseconds {
        guard
          fixture.model.setFindNeedlePending(sessionID: fixture.sessionID, needle: needle) != nil
        else {
          throw FindPerfError.noMatches("find.pending")
        }
      })
  }

  return PerfMetric(
    name: "find.pending",
    lineCount: lineCount,
    iterations: iterations,
    observedMatches: observed,
    samples: samples
  )
}

private func runProfileLoop(lineCount: Int, seconds: Double) throws -> Int {
  let fixture = try makeFixture(lineCount: lineCount)
  defer { fixture.model.closeAllSessions() }
  let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
  var operations = 0
  while DispatchTime.now().uptimeNanoseconds < deadline {
    _ = fixture.model.stopFind(sessionID: fixture.sessionID)
    let state = fixture.model.startFind(sessionID: fixture.sessionID, needle: "needle")
    guard let state, state.total > 0 else {
      throw FindPerfError.noMatches("profile-loop")
    }
    operations += 1
  }
  return operations
}

private func warmFind(model: AppModel, sessionID: Session.ID) throws -> Int {
  guard let state = model.startFind(sessionID: sessionID, needle: "needle"), state.total > 0 else {
    throw FindPerfError.noMatches("warmup")
  }
  return state.total
}

private func makeFixture(lineCount: Int) throws -> (model: AppModel, sessionID: Session.ID) {
  var size = LabanTerminalSize()
  size.rows = 24
  size.cols = 120
  let model = try AppModel(initialSize: size)
  guard let tab = model.tabs.first, let session = model.session(forTab: tab.id) else {
    throw FindPerfError.missingSession
  }

  var text = ""
  text.reserveCapacity(lineCount * 72)
  for index in 0..<lineCount {
    if index.isMultiple(of: 997) {
      text += "row \(index) needle terminal find performance guard target\r\n"
    } else {
      text += "row \(index) ordinary terminal output for scrollback timing\r\n"
    }
  }

  session.write(Array(text.utf8))
  session.poll()
  return (model, session.id)
}

private func measureMilliseconds(_ body: () throws -> Void) rethrows -> Double {
  let start = DispatchTime.now().uptimeNanoseconds
  try body()
  let end = DispatchTime.now().uptimeNanoseconds
  return Double(end - start) / 1_000_000.0
}

private func enforceThresholds(_ metrics: [PerfMetric]) throws {
  let thresholds = [
    "find.start": Threshold(
      meanMs: doubleEnv("LABAN_FIND_PERF_START_MEAN_MS", defaultValue: 8.0),
      p95Ms: doubleEnv("LABAN_FIND_PERF_START_P95_MS", defaultValue: 15.0)
    ),
    "find.step": Threshold(
      meanMs: doubleEnv("LABAN_FIND_PERF_STEP_MEAN_MS", defaultValue: 0.25),
      p95Ms: doubleEnv("LABAN_FIND_PERF_STEP_P95_MS", defaultValue: 1.0)
    ),
    "find.pending": Threshold(
      meanMs: doubleEnv("LABAN_FIND_PERF_PENDING_MEAN_MS", defaultValue: 0.25),
      p95Ms: doubleEnv("LABAN_FIND_PERF_PENDING_P95_MS", defaultValue: 1.0)
    ),
  ]

  for metric in metrics {
    guard let threshold = thresholds[metric.name] else { continue }
    if metric.mean > threshold.meanMs || metric.p95 > threshold.p95Ms {
      throw FindPerfError.threshold(
        String(
          format:
            "%@ exceeded threshold: mean %.3fms > %.3fms or p95 %.3fms > %.3fms",
          metric.name,
          metric.mean,
          threshold.meanMs,
          metric.p95,
          threshold.p95Ms
        )
      )
    }
  }
}

private func intEnv(_ name: String, defaultValue: Int) -> Int {
  guard let raw = ProcessInfo.processInfo.environment[name], let value = Int(raw), value > 0 else {
    return defaultValue
  }
  return value
}

private func doubleEnv(_ name: String, defaultValue: Double) -> Double {
  guard let raw = ProcessInfo.processInfo.environment[name], let value = Double(raw), value > 0
  else {
    return defaultValue
  }
  return value
}
