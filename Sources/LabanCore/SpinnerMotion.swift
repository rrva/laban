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
  /// Maximum number of retained row baselines.
  public static let maxRetainedRows = 4
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
  private(set) public var diagnostics: SpinnerMotionDiagnostics = .init()

  public init() {}

  /// Observe a new terminal generation and return the active foreground
  /// transition map for the current timestamp.
  public mutating func observe(_ observation: SpinnerMotionObservation) -> [SpinnerMotionCellKey: GlyphForegroundTransition] {
    diagnostics = SpinnerMotionDiagnostics()
    defer { lastObservationTimestamp = observation.timestamp }

    // Compute changed cells and qualifying region.
    var changed: [SpinnerMotionCellKey: SpinnerMotionCellState] = [:]
    for (key, cell) in observation.cells {
      if let previous = previousCells[key], !previous.sameIdentity(as: cell) || previous.foreground != cell.foreground {
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
    } else if let last = qualifyingRun.last,
      !SpinnerMotionDetector.regionsAreNear(last, region) {
      resetRun()
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

    diagnostics.consecutiveQualifyingObservations = qualifyingRun.count

    guard isActive(at: observation.timestamp) else {
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

    // Create or retarget transitions for changed cells whose identity is
    // unchanged and whose foreground changed.
    var created = 0
    var overflow = 0
    for (key, current) in changed {
      guard let previous = previousCells[key], previous.sameIdentity(as: current), previous.foreground != current.foreground else {
        // Decorated, different glyph, or no baseline: snap.
        transitions.removeValue(forKey: key)
        continue
      }
      if transitions.count >= SpinnerMotion.maxTransitions, transitions[key] == nil {
        overflow += 1
        continue
      }
      let startLinear: SIMD4<Float>
      if let existing = transitions[key] {
        startLinear = sampleLinear(existing, at: observation.timestamp)
      } else {
        startLinear = SRGBRenderTargetColor.linearizedStraightRGBA(previous.foreground)
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
  public func activeTransitions(at timestamp: Double) -> [SpinnerMotionCellKey: GlyphForegroundTransition] {
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

  private func sampleLinear(_ transition: Transition, at timestamp: Double) -> SIMD4<Float> {
    let age = timestamp - transition.startTimestamp
    let u = max(0, min(1, age / max(transition.duration, 1e-9)))
    let p = Self.smoothstep(u)
    let start = transition.startLinearRGBA
    let target = transition.targetLinearRGBA
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

  private static func qualifyingRegion(changed: [SpinnerMotionCellKey], rows: Int, cols: Int) -> Region {
    guard !changed.isEmpty else {
      return Region(minRow: 0, maxRow: -1, minCol: 0, maxCol: -1, qualifies: false, reason: "no changed cells")
    }
    let minRow = changed.map(\.row).min()!
    let maxRow = changed.map(\.row).max()!
    let minCol = changed.map(\.col).min()!
    let maxCol = changed.map(\.col).max()!
    let rowSpan = maxRow - minRow + 1
    let colSpan = maxCol - minCol + 1
    if rowSpan > 2 {
      return Region(minRow: minRow, maxRow: maxRow, minCol: minCol, maxCol: maxCol, qualifies: false, reason: "rows > 2")
    }
    if colSpan > SpinnerMotion.maxRegionColumns {
      return Region(minRow: minRow, maxRow: maxRow, minCol: minCol, maxCol: maxCol, qualifies: false, reason: "columns > 32")
    }
    if changed.count > SpinnerMotion.maxChangedCells {
      return Region(minRow: minRow, maxRow: maxRow, minCol: minCol, maxCol: maxCol, qualifies: false, reason: "changed cells > 32")
    }
    return Region(minRow: minRow, maxRow: maxRow, minCol: minCol, maxCol: maxCol, qualifies: true, reason: nil)
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
    // Retain only the most recently changed rows to bound memory. Anchor rows
    // from the current observation are pinned; the rest are LRU.
    var touchedRows = Set<Int>()
    for key in observation.cells.keys { touchedRows.insert(key.row) }
    var retainedRows = Array(touchedRows)
    if retainedRows.count > SpinnerMotion.maxRetainedRows {
      retainedRows.sort()
      retainedRows = Array(retainedRows.suffix(SpinnerMotion.maxRetainedRows))
    }
    let keep = Set(retainedRows)
    previousCells = observation.cells.filter { keep.contains($0.key.row) }
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
    mouseTracking: Bool = false
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
  }
}
