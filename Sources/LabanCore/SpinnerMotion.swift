import Foundation
import LabanRenderer

/// Pure value types for the spinner-motion smoothing detector
/// (execplans/active/spinner-motion-smoothing.md). No AppKit, no renderer
/// objects, no settings lookups: the caller supplies resolved cell state and
/// the effective-feature predicate.
public enum SpinnerMotion {
  /// Maximum width of a qualifying region in cells.
  public static let maxRegionColumns = 32
  /// Maximum number of changed cells in a qualifying observation.
  public static let maxChangedCells = 32
  /// Minimum and maximum observed cadence in seconds.
  public static let minCadenceSeconds = 0.04
  public static let maxCadenceSeconds = 0.60
  /// Cadence below which a source already emits finely sampled motion and is
  /// rendered authoritatively instead of interpolated. Sources that change
  /// colors faster than this already read as smooth; interpolating them only
  /// filters an already time-shaped signal and can add artifacts. The exit
  /// threshold adds hysteresis so sources hovering near the boundary do not
  /// flap between interpolated and authoritative rendering.
  public static let finelySampledEnterCadenceSeconds = 0.10
  public static let finelySampledExitCadenceSeconds = 0.12
  /// Maximum number of live transitions retained per session.
  public static let maxTransitions = 64
}

public struct SpinnerMotionCellKey: Hashable, Equatable, Sendable {
  public var row: Int
  public var col: Int

  public init(row: Int, col: Int) {
    self.row = row
    self.col = col
  }
}

/// Resolved visual state of one cell, factored the same way `FrameProducer`
/// resolves colors and attributes. The detector compares this state across
/// observations; only a foreground change on an otherwise identical cell is
/// eligible for motion smoothing.
public struct SpinnerMotionCellState: Equatable, Sendable {
  public var key: SpinnerMotionCellKey
  public var text: String
  public var displayWidth: Int
  public var foreground: UInt32
  public var background: UInt32
  public var attributes: TextAttributes
  public var underlineStyle: UnderlineStyle
  public var underlineColor: UInt32?
  public var hyperlink: String?
  public var wide: UInt8

  public init(
    key: SpinnerMotionCellKey,
    text: String,
    displayWidth: Int,
    foreground: UInt32,
    background: UInt32,
    attributes: TextAttributes,
    underlineStyle: UnderlineStyle,
    underlineColor: UInt32?,
    hyperlink: String?,
    wide: UInt8
  ) {
    self.key = key
    self.text = text
    self.displayWidth = displayWidth
    self.foreground = foreground
    self.background = background
    self.attributes = attributes
    self.underlineStyle = underlineStyle
    self.underlineColor = underlineColor
    self.hyperlink = hyperlink
    self.wide = wide
  }

  /// True when every visual identity property except foreground is identical.
  public func sameIdentity(as other: SpinnerMotionCellState) -> Bool {
    text == other.text
      && displayWidth == other.displayWidth
      && background == other.background
      && attributes == other.attributes
      && underlineStyle == other.underlineStyle
      && underlineColor == other.underlineColor
      && hyperlink == other.hyperlink
      && wide == other.wide
  }
}

/// One snapshot observation passed to the detector.
public struct SpinnerMotionObservation: Equatable, Sendable {
  public var timestamp: Double
  public var rows: Int
  public var cols: Int
  public var cells: [SpinnerMotionCellKey: SpinnerMotionCellState]
  public var mouseTracking: Bool

  public init(
    timestamp: Double,
    rows: Int,
    cols: Int,
    cells: [SpinnerMotionCellKey: SpinnerMotionCellState],
    mouseTracking: Bool
  ) {
    self.timestamp = timestamp
    self.rows = rows
    self.cols = cols
    self.cells = cells
    self.mouseTracking = mouseTracking
  }
}

/// A confident traveling-wave estimate for one single-row region: a color
/// field anchored at a timestamp plus a velocity in cells per second. The
/// renderer samples `colors` at fractional offsets `x = (col - minCol) -
/// velocity * (t - anchorTimestamp)` so a pattern the source emits in whole
/// cell steps can glide at display rate. Pure value type; the Slug motion
/// shader mirrors `sample(col:at:)`.
public struct SpinnerWaveState: Equatable, Sendable {
  public var row: Int
  public var minCol: Int
  /// Linear-light straight RGBA per column, starting at `minCol` (<= 32).
  public var colors: [SIMD4<Float>]
  public var anchorTimestamp: Double
  public var velocityCellsPerSecond: Double
  public var confidence: Double

  public init(
    row: Int,
    minCol: Int,
    colors: [SIMD4<Float>],
    anchorTimestamp: Double,
    velocityCellsPerSecond: Double,
    confidence: Double
  ) {
    self.row = row
    self.minCol = minCol
    self.colors = colors
    self.anchorTimestamp = anchorTimestamp
    self.velocityCellsPerSecond = velocityCellsPerSecond
    self.confidence = confidence
  }

  /// Bilinear field sample for `col` at time `t`, clamped to the field
  /// bounds. A rightward-moving highlight has positive velocity: the color
  /// now at `col` was at anchor time at `col - velocity * age`.
  public func sample(col: Int, at t: Double) -> SIMD4<Float> {
    guard !colors.isEmpty else { return .zero }
    let age = t - anchorTimestamp
    let x = Double(col - minCol) - velocityCellsPerSecond * age
    let clampedX = max(0.0, min(Double(colors.count - 1), x))
    let lower = Int(clampedX.rounded(.down))
    let upper = min(colors.count - 1, lower + 1)
    let f = Float(clampedX - Double(lower))
    let a = colors[lower]
    let b = colors[upper]
    return a + (b - a) * f
  }
}

/// Estimates steady translation of a single-row color pattern from
/// consecutive observations. Detection is purely semantic: integer-shift
/// cross-correlation of the region's luminance vector. No process names,
/// output text, or glyph identities are consulted.
private struct TravelingWaveEstimator: Equatable, Sendable {
  private struct Vote: Equatable, Sendable {
    var shift: Int
    var dt: Double
    var score: Double
  }

  private var previousVector: [Double] = []
  private var previousMinCol = 0
  private var previousRow = -1
  private var previousTimestamp: Double?
  private var votes: [Vote] = []
  private var consecutiveFailures = 0
  private(set) var currentState: SpinnerWaveState?

  static var minimumColumns: Int { 6 }
  static var minimumScore: Double { 0.90 }

  var confident: Bool { currentState != nil }

  mutating func reset() {
    previousVector = []
    previousMinCol = 0
    previousRow = -1
    previousTimestamp = nil
    votes = []
    consecutiveFailures = 0
    currentState = nil
  }

  /// Record a broken observation stream (out-of-range cadence gap, region
  /// jump, or non-qualifying region). Two consecutive failures disengage.
  mutating func noteFailure() {
    consecutiveFailures += 1
    if consecutiveFailures >= 2 {
      votes = []
      currentState = nil
    }
  }

  /// Feed one qualifying single-row observation. `colors` and `vector` cover
  /// columns `minCol...` in parallel; `timeout` is the observation staleness
  /// bound (`min(2 * cadence, 0.8)`).
  mutating func observe(
    row: Int,
    minCol: Int,
    vector: [Double],
    colors: [SIMD4<Float>],
    timestamp: Double,
    timeout: Double
  ) {
    guard let previousTimestamp, previousRow == row else {
      adopt(vector: vector, minCol: minCol, row: row, timestamp: timestamp)
      return
    }
    let dt = timestamp - previousTimestamp
    guard dt > 0, dt <= timeout else {
      // A stale observation is a hard temporal break: drop the wave at once
      // instead of letting an outdated field extrapolate.
      votes = []
      currentState = nil
      adopt(vector: vector, minCol: minCol, row: row, timestamp: timestamp)
      return
    }
    var best: (shift: Int, score: Double) = (0, 0)
    for shift in -2...2 {
      let score = Self.correlation(
        current: vector, currentMinCol: minCol,
        previous: previousVector, previousMinCol: previousMinCol,
        shift: shift)
      if score > best.score { best = (shift, score) }
    }
    adopt(vector: vector, minCol: minCol, row: row, timestamp: timestamp)
    guard best.shift != 0, best.score >= Self.minimumScore else {
      noteFailure()
      return
    }
    consecutiveFailures = 0
    votes.append(Vote(shift: best.shift, dt: dt, score: best.score))
    if votes.count > 5 { votes.removeFirst() }
    let recent = votes.suffix(3)
    guard recent.count == 3, recent.allSatisfy({ $0.shift == best.shift }) else { return }
    let samples = recent.map { Double($0.shift) / $0.dt }.sorted()
    currentState = SpinnerWaveState(
      row: row,
      minCol: minCol,
      colors: colors,
      anchorTimestamp: timestamp,
      velocityCellsPerSecond: samples[1],
      confidence: best.score)
  }

  private mutating func adopt(vector: [Double], minCol: Int, row: Int, timestamp: Double) {
    previousVector = vector
    previousMinCol = minCol
    previousRow = row
    previousTimestamp = timestamp
  }

  /// Normalized (Pearson) correlation between `current[col]` and
  /// `previous[col - shift]` over the columns where both exist.
  private static func correlation(
    current: [Double],
    currentMinCol: Int,
    previous: [Double],
    previousMinCol: Int,
    shift: Int
  ) -> Double {
    var xs: [Double] = []
    var ys: [Double] = []
    xs.reserveCapacity(current.count)
    ys.reserveCapacity(current.count)
    for (i, value) in current.enumerated() {
      let j = (currentMinCol + i) - shift - previousMinCol
      guard j >= 0, j < previous.count else { continue }
      xs.append(value)
      ys.append(previous[j])
    }
    guard xs.count >= minimumColumns else { return 0 }
    let n = Double(xs.count)
    let meanX = xs.reduce(0, +) / n
    let meanY = ys.reduce(0, +) / n
    var sxx = 0.0
    var syy = 0.0
    var sxy = 0.0
    for i in 0..<xs.count {
      let dx = xs[i] - meanX
      let dy = ys[i] - meanY
      sxx += dx * dx
      syy += dy * dy
      sxy += dx * dy
    }
    guard sxx > 1e-12, syy > 1e-12 else { return 0 }
    return sxy / (sxx.squareRoot() * syy.squareRoot())
  }
}

/// Mutable per-session detector state. A pure value type owned by
/// `TerminalSurfaceController`; it does not retain AppKit or renderer objects.
public struct SpinnerMotionDetector: Equatable, Sendable {
  /// One qualifying observation in a cadence run.
  private struct QualifyingObservation: Equatable, Sendable {
    var timestamp: Double
    var minRow: Int
    var maxRow: Int
    var minCol: Int
    var maxCol: Int
    var changedCells: Int
  }

  private struct Transition: Equatable, Sendable {
    var startLinearRGBA: SIMD4<Float>
    var targetLinearRGBA: SIMD4<Float>
    var startTimestamp: Double
    var duration: Double
    var targetForeground: UInt32
  }

  private var previousCells: [SpinnerMotionCellKey: SpinnerMotionCellState] = [:]
  private var previousTimestamp: Double?
  private var qualifyingRun: [QualifyingObservation] = []
  private var transitions: [SpinnerMotionCellKey: Transition] = [:]
  private var lastObservationTimestamp: Double?
  private var finelySampledBypass = false
  private var waveEstimator = TravelingWaveEstimator()
  /// Confident traveling-wave state for the current observation stream, when
  /// the finely sampled bypass is engaged. The renderer may keep sampling the
  /// returned field/velocity between observations; the value is sticky across
  /// observations that do not feed the estimator (for example foreign
  /// single-cell changes) and clears when the wave disengages.
  private(set) public var lastWave: SpinnerWaveState?
  private(set) public var diagnostics: SpinnerMotionDiagnostics = .init()

  public init() {}

  /// Observe a new terminal generation and return the active foreground
  /// transition map for the current timestamp.
  public mutating func observe(_ observation: SpinnerMotionObservation) -> [SpinnerMotionCellKey:
    GlyphForegroundTransition]
  {
    diagnostics = SpinnerMotionDiagnostics()
    diagnostics.finelySampledBypass = finelySampledBypass
    diagnostics.waveActive = lastWave != nil
    diagnostics.waveVelocityCellsPerSecond = lastWave?.velocityCellsPerSecond
    diagnostics.waveConfidence = lastWave?.confidence
    defer { lastObservationTimestamp = observation.timestamp }

    // Compute changed cells and qualifying region.
    var changed: [SpinnerMotionCellKey: SpinnerMotionCellState] = [:]
    for (key, cell) in observation.cells {
      if let previous = previousCells[key],
        !previous.sameIdentity(as: cell) || previous.foreground != cell.foreground
      {
        changed[key] = cell
      } else if previousCells[key] == nil {
        // Newly visible cell; treat as changed for region qualification but
        // it cannot start a same-glyph transition.
        changed[key] = cell
      }
    }

    // Update diagnostics before possible early returns.
    diagnostics.changedCells = changed.count
    diagnostics.mouseTracking = observation.mouseTracking

    guard !changed.isEmpty else {
      diagnostics.detectorActive = isActive(at: observation.timestamp)
      diagnostics.cadenceSeconds = estimatedCadence()
      let result = activeTransitions(at: observation.timestamp)
      diagnostics.activeTransitions = result.count
      updatePreviousCells(observation)
      return result
    }

    let region = SpinnerMotionDetector.qualifyingRegion(
      changed: Array(changed.keys),
      rows: observation.rows,
      cols: observation.cols)
    diagnostics.regionColumns = region.maxCol - region.minCol + 1
    diagnostics.regionRows = region.maxRow - region.minRow + 1

    let gap = previousTimestamp.map { observation.timestamp - $0 }
    previousTimestamp = observation.timestamp

    guard region.qualifies else {
      // Non-qualifying observation: snap changed cells and reset the run.
      resetRun()
      waveEstimator.noteFailure()
      lastWave = nil
      for key in changed.keys { transitions.removeValue(forKey: key) }
      diagnostics.detectorActive = false
      diagnostics.fallbackReason = region.reason
      let result = activeTransitions(at: observation.timestamp)
      diagnostics.activeTransitions = result.count
      updatePreviousCells(observation)
      return result
    }

    if let gap, !SpinnerMotionDetector.isCadenceGapInRange(gap) {
      resetRun()
      waveEstimator.noteFailure()
    } else if let last = qualifyingRun.last,
      !SpinnerMotionDetector.regionsAreNear(last, region)
    {
      resetRun()
      waveEstimator.noteFailure()
    }

    qualifyingRun.append(
      QualifyingObservation(
        timestamp: observation.timestamp,
        minRow: region.minRow,
        maxRow: region.maxRow,
        minCol: region.minCol,
        maxCol: region.maxCol,
        changedCells: changed.count))
    if qualifyingRun.count > 4 { qualifyingRun.removeFirst() }

    // Feed the traveling-wave estimator on single-row regions wide enough to
    // correlate. Narrower rounds (for example a foreign single-cell change)
    // are skipped without penalty; the estimator keeps its last baseline.
    if region.maxRow == region.minRow,
      region.maxCol - region.minCol + 1 >= TravelingWaveEstimator.minimumColumns
    {
      var vector: [Double] = []
      var colors: [SIMD4<Float>] = []
      var complete = true
      for col in region.minCol...region.maxCol {
        guard let cell = observation.cells[SpinnerMotionCellKey(row: region.minRow, col: col)]
        else {
          complete = false
          break
        }
        let linear = SRGBRenderTargetColor.linearizedStraightRGBA(cell.foreground)
        colors.append(linear)
        vector.append(Double(0.2126 * linear.x + 0.7152 * linear.y + 0.0722 * linear.z))
      }
      if complete {
        waveEstimator.observe(
          row: region.minRow,
          minCol: region.minCol,
          vector: vector,
          colors: colors,
          timestamp: observation.timestamp,
          timeout: min(2 * estimatedCadence(), 0.8))
      }
    }

    diagnostics.consecutiveQualifyingObservations = qualifyingRun.count

    guard isActive(at: observation.timestamp) else {
      // While the detector is inactive (warm-up or after a timeout) no wave
      // metadata may be published either.
      lastWave = nil
      diagnostics.waveActive = false
      diagnostics.waveVelocityCellsPerSecond = nil
      diagnostics.waveConfidence = nil
      diagnostics.detectorActive = false
      diagnostics.cadenceSeconds = estimatedCadence()
      let result = activeTransitions(at: observation.timestamp)
      diagnostics.activeTransitions = result.count
      updatePreviousCells(observation)
      return result
    }

    let cadence = estimatedCadence()
    diagnostics.cadenceSeconds = cadence
    diagnostics.detectorActive = true

    // Finely sampled sources already read as smooth on their own; render them
    // authoritatively and reserve interpolation for sparse, discrete jumps.
    // Hysteresis keeps sources near the threshold from flapping. The run and
    // cadence bookkeeping above stays live so the bypass can disengage.
    if finelySampledBypass {
      if cadence > SpinnerMotion.finelySampledExitCadenceSeconds {
        finelySampledBypass = false
      }
    } else if cadence < SpinnerMotion.finelySampledEnterCadenceSeconds {
      finelySampledBypass = true
    }
    diagnostics.finelySampledBypass = finelySampledBypass
    guard !finelySampledBypass else {
      lastWave = waveEstimator.currentState
      diagnostics.waveActive = lastWave != nil
      diagnostics.waveVelocityCellsPerSecond = lastWave?.velocityCellsPerSecond
      diagnostics.waveConfidence = lastWave?.confidence
      let result = activeTransitions(at: observation.timestamp)
      diagnostics.activeTransitions = result.count
      updatePreviousCells(observation)
      return result
    }
    lastWave = nil

    // Create or retarget transitions for changed cells whose identity is
    // unchanged and whose foreground changed.
    var created = 0
    var overflow = 0
    for (key, current) in changed {
      guard let previous = previousCells[key], previous.sameIdentity(as: current),
        previous.foreground != current.foreground
      else {
        // Decorated, different glyph, or no baseline: snap.
        transitions.removeValue(forKey: key)
        continue
      }
      if transitions.count >= SpinnerMotion.maxTransitions, transitions[key] == nil {
        overflow += 1
        continue
      }
      let startLinear: SIMD4<Float>
      let previousLinear = SRGBRenderTargetColor.linearizedStraightRGBA(previous.foreground)
      if let existing = transitions[key] {
        // The renderer blends a transition's start color toward the cell's
        // current authoritative foreground, not toward the target recorded in
        // the transition. While the detector stays active those coincide, but
        // after a cadence/region reset the cell can snap past a stale
        // transition whose stored target no longer matches what is on screen.
        // Sampling toward `previous.foreground` keeps the retarget continuous
        // with the displayed color in exactly those cases; a settled stale
        // transition then samples to `previous.foreground` itself.
        startLinear = sampleLinear(existing, toward: previousLinear, at: observation.timestamp)
      } else {
        startLinear = previousLinear
      }
      transitions[key] = Transition(
        startLinearRGBA: startLinear,
        targetLinearRGBA: SRGBRenderTargetColor.linearizedStraightRGBA(current.foreground),
        startTimestamp: observation.timestamp,
        duration: cadence,
        targetForeground: current.foreground)
      created += 1
    }
    diagnostics.createdTransitions = created
    diagnostics.overflowTransitions = overflow

    let result = activeTransitions(at: observation.timestamp)
    diagnostics.activeTransitions = result.count
    updatePreviousCells(observation)
    return result
  }

  /// Clear all state. Called when eligibility becomes false, session identity
  /// disappears, dimensions change, or incarnation changes.
  public mutating func reset() {
    previousCells.removeAll()
    previousTimestamp = nil
    qualifyingRun.removeAll()
    transitions.removeAll()
    finelySampledBypass = false
    waveEstimator.reset()
    lastWave = nil
    diagnostics = SpinnerMotionDiagnostics()
  }

  /// True when the detector has seen at least three consecutive qualifying
  /// observations and has not timed out.
  public func isActive(at timestamp: Double) -> Bool {
    guard qualifyingRun.count >= 3 else { return false }
    guard let last = qualifyingRun.last else { return false }
    let timeout = min(2 * estimatedCadence(), 0.8)
    return timestamp - last.timestamp <= timeout
  }

  /// Active transition map sampled at `timestamp`. Settled transitions are
  /// omitted so the next frame renders the authoritative target color.
  public func activeTransitions(at timestamp: Double) -> [SpinnerMotionCellKey:
    GlyphForegroundTransition]
  {
    var result: [SpinnerMotionCellKey: GlyphForegroundTransition] = [:]
    for (key, transition) in transitions {
      let age = timestamp - transition.startTimestamp
      guard age < transition.duration else { continue }
      result[key] = GlyphForegroundTransition(
        startLinearRGBA: transition.startLinearRGBA,
        startTimestampSeconds: transition.startTimestamp,
        durationSeconds: transition.duration)
    }
    return result
  }

  // MARK: - Sampling

  private static func smoothstep(_ t: Double) -> Double {
    let clamped = max(0, min(1, t))
    return clamped * clamped * (3 - 2 * clamped)
  }

  private func sampleLinear(
    _ transition: Transition, toward target: SIMD4<Float>, at timestamp: Double
  ) -> SIMD4<Float> {
    let age = timestamp - transition.startTimestamp
    let u = max(0, min(1, age / max(transition.duration, 1e-9)))
    let p = Self.smoothstep(u)
    let start = transition.startLinearRGBA
    return SIMD4<Float>(
      Float(Double(start.x) + (Double(target.x) - Double(start.x)) * p),
      Float(Double(start.y) + (Double(target.y) - Double(start.y)) * p),
      Float(Double(start.z) + (Double(target.z) - Double(start.z)) * p),
      Float(Double(start.w) + (Double(target.w) - Double(start.w)) * p))
  }

  // MARK: - Region qualification

  private struct Region: Equatable, Sendable {
    var minRow: Int
    var maxRow: Int
    var minCol: Int
    var maxCol: Int
    var qualifies: Bool
    var reason: String?
  }

  private static func qualifyingRegion(changed: [SpinnerMotionCellKey], rows: Int, cols: Int)
    -> Region
  {
    guard !changed.isEmpty else {
      return Region(
        minRow: 0, maxRow: -1, minCol: 0, maxCol: -1, qualifies: false, reason: "no changed cells")
    }
    let minRow = changed.map(\.row).min()!
    let maxRow = changed.map(\.row).max()!
    let minCol = changed.map(\.col).min()!
    let maxCol = changed.map(\.col).max()!
    let rowSpan = maxRow - minRow + 1
    let colSpan = maxCol - minCol + 1
    if rowSpan > 2 {
      return Region(
        minRow: minRow, maxRow: maxRow, minCol: minCol, maxCol: maxCol, qualifies: false,
        reason: "rows > 2")
    }
    if colSpan > SpinnerMotion.maxRegionColumns {
      return Region(
        minRow: minRow, maxRow: maxRow, minCol: minCol, maxCol: maxCol, qualifies: false,
        reason: "columns > 32")
    }
    if changed.count > SpinnerMotion.maxChangedCells {
      return Region(
        minRow: minRow, maxRow: maxRow, minCol: minCol, maxCol: maxCol, qualifies: false,
        reason: "changed cells > 32")
    }
    return Region(
      minRow: minRow, maxRow: maxRow, minCol: minCol, maxCol: maxCol, qualifies: true, reason: nil)
  }

  private static func isCadenceGapInRange(_ gap: Double) -> Bool {
    gap >= SpinnerMotion.minCadenceSeconds && gap <= SpinnerMotion.maxCadenceSeconds
  }

  private static func regionsAreNear(_ previous: QualifyingObservation, _ current: Region) -> Bool {
    let rowOverlapOrAdjacent =
      current.minRow <= previous.maxRow + 1 && current.maxRow >= previous.minRow - 1
    let colOverlapOrAdjacent =
      current.minCol <= previous.maxCol + 4 && current.maxCol >= previous.minCol - 4
    return rowOverlapOrAdjacent && colOverlapOrAdjacent
  }

  private mutating func resetRun() {
    qualifyingRun.removeAll()
  }

  private mutating func updatePreviousCells(_ observation: SpinnerMotionObservation) {
    // Keep the whole grid baseline so changes in any row can be compared
    // against the same-glyph previous state. The grid is bounded by the
    // terminal dimensions, so retaining every cell is cheap (a few KiB).
    previousCells = observation.cells
  }

  private func estimatedCadence() -> Double {
    guard qualifyingRun.count >= 2 else {
      return SpinnerMotion.maxCadenceSeconds
    }
    let gaps = zip(qualifyingRun.dropFirst(), qualifyingRun).map { $0.timestamp - $1.timestamp }
    let recent = Array(gaps.suffix(4))
    let mean = recent.reduce(0, +) / Double(recent.count)
    return max(SpinnerMotion.minCadenceSeconds, min(SpinnerMotion.maxCadenceSeconds, mean))
  }
}

/// Human-readable diagnostics reported by `SpinnerMotionDetector` and exposed
/// on debug endpoints.
public struct SpinnerMotionDiagnostics: Equatable, Sendable, Codable {
  public var detectorActive: Bool
  public var consecutiveQualifyingObservations: Int
  public var changedCells: Int
  public var regionColumns: Int
  public var regionRows: Int
  public var cadenceSeconds: Double?
  public var createdTransitions: Int
  public var activeTransitions: Int
  public var overflowTransitions: Int
  public var fallbackReason: String?
  public var mouseTracking: Bool
  public var finelySampledBypass: Bool
  public var waveActive: Bool
  public var waveVelocityCellsPerSecond: Double?
  public var waveConfidence: Double?

  public init(
    detectorActive: Bool = false,
    consecutiveQualifyingObservations: Int = 0,
    changedCells: Int = 0,
    regionColumns: Int = 0,
    regionRows: Int = 0,
    cadenceSeconds: Double? = nil,
    createdTransitions: Int = 0,
    activeTransitions: Int = 0,
    overflowTransitions: Int = 0,
    fallbackReason: String? = nil,
    mouseTracking: Bool = false,
    finelySampledBypass: Bool = false,
    waveActive: Bool = false,
    waveVelocityCellsPerSecond: Double? = nil,
    waveConfidence: Double? = nil
  ) {
    self.detectorActive = detectorActive
    self.consecutiveQualifyingObservations = consecutiveQualifyingObservations
    self.changedCells = changedCells
    self.regionColumns = regionColumns
    self.regionRows = regionRows
    self.cadenceSeconds = cadenceSeconds
    self.createdTransitions = createdTransitions
    self.activeTransitions = activeTransitions
    self.overflowTransitions = overflowTransitions
    self.fallbackReason = fallbackReason
    self.mouseTracking = mouseTracking
    self.finelySampledBypass = finelySampledBypass
    self.waveActive = waveActive
    self.waveVelocityCellsPerSecond = waveVelocityCellsPerSecond
    self.waveConfidence = waveConfidence
  }
}
