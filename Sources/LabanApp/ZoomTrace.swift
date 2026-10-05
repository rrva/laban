import Foundation
import LabanRenderer

/// One zoom input event recorded while `/zoom/trace` is armed. `time` is
/// `NSEvent.timestamp`, the same clock as `ZoomPresentSample.time`.
struct ZoomTraceInput: Equatable {
  var time: Double
  /// "wheel" (discrete), "precise" (phased trackpad), "phaseless" (precise
  /// without a phase envelope), or "momentum" (ignored inertial tail).
  var source: String
  var deltaY: Double
  var scrollingDeltaY: Double
  var phase: UInt
  var momentumPhase: UInt
}

/// One gesture commit (font rebuild + grid reflow) recorded while armed.
struct ZoomTraceCommit: Equatable {
  var time: Double
  var durationMs: Double
  var pointSize: Double
}

/// Per-burst evenness of what reached the screen during a zoom. A burst is a
/// run of inputs with no gap longer than `burstGap`; its presents are the vsync
/// samples from its first to its last visible size change. A "still" vsync is
/// one where the size moved less than a quarter of the burst's median non-zero
/// step: during steady input that is a visible hitch, and the next vsync
/// usually shows a double step.
struct ZoomTraceSummary: Equatable {
  struct Burst: Equatable {
    var start: Double
    var inputs: Int
    var vsyncs: Int
    var stillVsyncs: Int
    var p50StepPercent: Double
    var maxStepPercent: Double
    var commits: Int
    var maxCommitMs: Double
    var fromPointSize: Double
    var toPointSize: Double
  }

  var bursts: [Burst]

  static let burstGap: Double = 0.4

  init(inputs: [ZoomTraceInput], presents: [ZoomPresentSample], commits: [ZoomTraceCommit]) {
    let times = inputs.filter { $0.source != "momentum" }.map(\.time).sorted()
    var windows: [(start: Double, last: Double, count: Int)] = []
    for t in times {
      if let w = windows.last, t - w.last <= Self.burstGap {
        windows[windows.count - 1].last = t
        windows[windows.count - 1].count += 1
      } else {
        windows.append((t, t, 1))
      }
    }
    let sortedPresents = presents.sorted { $0.time < $1.time }
    bursts = windows.enumerated().map { index, w in
      // The glide and the commit can land after the last input; stop at the
      // next burst so bursts never share samples.
      let nextStart = index + 1 < windows.count ? windows[index + 1].start : .infinity
      let end = min(w.last + Self.burstGap, nextStart)
      // Include the vsync just before the burst so the first change counts.
      let firstIndex = sortedPresents.lastIndex { $0.time < w.start } ?? 0
      let window = sortedPresents[firstIndex...].prefix { $0.time < end }
      let sizes = window.map(\.visualPointSize)
      var steps = zip(sizes, sizes.dropFirst()).map { abs(log($1 / $0)) }
      // Trim to the motion span: first through last vsync that changed size.
      let moving = steps.indices.filter { steps[$0] > 1e-9 }
      if let first = moving.first, let last = moving.last {
        steps = Array(steps[first...last])
      } else {
        steps = []
      }
      let nonZero = steps.filter { $0 > 1e-9 }.sorted()
      let median = nonZero.isEmpty ? 0 : nonZero[nonZero.count / 2]
      let burstCommits = commits.filter { $0.time >= w.start && $0.time < end }
      return Burst(
        start: w.start,
        inputs: w.count,
        vsyncs: steps.count,
        stillVsyncs: steps.filter { $0 < median * 0.25 }.count,
        p50StepPercent: Self.percent(median),
        maxStepPercent: Self.percent(nonZero.last ?? 0),
        commits: burstCommits.count,
        maxCommitMs: burstCommits.map(\.durationMs).max() ?? 0,
        fromPointSize: sizes.first ?? 0,
        toPointSize: sizes.last ?? 0)
    }
  }

  private static func percent(_ logStep: Double) -> Double {
    (exp(logStep) - 1) * 100
  }

  var json: [[String: Any]] {
    bursts.map {
      [
        "start": $0.start, "inputs": $0.inputs, "vsyncs": $0.vsyncs,
        "stillVsyncs": $0.stillVsyncs,
        "stillPercent": $0.vsyncs > 0 ? Double($0.stillVsyncs) / Double($0.vsyncs) * 100 : 0,
        "p50StepPercent": $0.p50StepPercent, "maxStepPercent": $0.maxStepPercent,
        "commits": $0.commits, "maxCommitMs": $0.maxCommitMs,
        "fromPointSize": $0.fromPointSize, "toPointSize": $0.toPointSize,
      ]
    }
  }
}
