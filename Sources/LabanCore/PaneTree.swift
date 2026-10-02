import Foundation

public enum PaneAxis: String, Codable, Sendable {
  case horizontal, vertical
}

/// Which child of a split: `first` is left (vertical axis) or top (horizontal axis).
public enum PaneSide: String, Codable, Sendable { case first, second }

/// The route from the root of a tree to one split node. `[]` is the root split;
/// `[.second]` is the root's second child, and so on. A path addresses a divider
/// unambiguously, which a session ID cannot once trees are nested.
public typealias PanePath = [PaneSide]

public enum PaneDirection: String, Codable, Sendable {
  case left, right, up, down

  /// The axis of a divider that separates panes lying in this direction.
  public var axis: PaneAxis {
    switch self {
    case .left, .right: return .vertical
    case .up, .down: return .horizontal
    }
  }

  /// True when moving in this direction goes from a split's `first` towards its `second`.
  public var towardsSecond: Bool { self == .right || self == .down }

  /// What Cmd+Control+arrow sends to the shell in a tab with no divider to nudge: the
  /// readline start-of-line and end-of-line bytes (Ctrl+A, Ctrl+E) for Left and Right,
  /// as before splits existed. Nil for Up and Down, which stay no-ops.
  public var unsplitNudgeLineEditingBytes: [UInt8]? {
    switch self {
    case .left: return [0x01]
    case .right: return [0x05]
    case .up, .down: return nil
    }
  }
}

/// One divider of a laid-out tree plus the rect of the split that owns it.
/// Drag math converts a pointer position into `(pointer - container.min) / container.extent`.
public struct PaneDivider: Equatable {
  public let path: PanePath
  public let axis: PaneAxis
  public let rect: CGRect
  public let container: CGRect
  public let fraction: Double

  public init(path: PanePath, axis: PaneAxis, rect: CGRect, container: CGRect, fraction: Double) {
    self.path = path
    self.axis = axis
    self.rect = rect
    self.container = container
    self.fraction = fraction
  }

  /// Thickness of the line that follows the pointer while a divider is dragged.
  public static let previewThickness: CGFloat = 3

  /// The drag-preview line: `thickness` pixels across, centred on where the divider would
  /// sit at `fraction` of `container`, and spanning the container the other way.
  public static func previewRect(
    axis: PaneAxis, container: CGRect, fraction: Double, thickness: CGFloat = previewThickness
  ) -> CGRect {
    let value = CGFloat(fraction.isFinite ? fraction : 0.5)
    if axis == .vertical {
      let center = container.minX + floor(container.width * value)
      return CGRect(
        x: center - thickness / 2, y: container.minY, width: thickness, height: container.height)
    }
    // y grows upward: the first (top) child owns the high-y end of the container.
    let center = container.maxY - floor(container.height * value)
    return CGRect(
      x: container.minX, y: center - thickness / 2, width: container.width, height: thickness)
  }
}

/// A divider drag in progress, shared by the AppKit view and the headless runtime so the
/// pointer-to-fraction math is identical. `fraction` is the proposed position as a share of
/// `container`; it is only a proposal until the drag commits.
public struct PaneDividerDrag: Equatable {
  public let tabId: Tab.ID
  public let path: PanePath
  public let axis: PaneAxis
  public let container: CGRect
  /// Where the divider sat when the drag began, to tell a real drag from a bare click.
  public let startFraction: Double
  public var fraction: Double
  /// The pointer's position along the drag axis at the press. The divider follows the
  /// pointer's movement from here, so pressing off-centre in the grab zone moves nothing.
  public let grabPointer: CGFloat
  /// The panes under the dragged split at the press. A commit lands only while the split
  /// at `path` still holds exactly these panes along the same axis.
  public let splitLeaves: [Session.ID]

  public init(
    tabId: Tab.ID, path: PanePath, axis: PaneAxis, container: CGRect, fraction: Double,
    grabbedAt grab: CGPoint, splitLeaves: [Session.ID]
  ) {
    self.tabId = tabId
    self.path = path
    self.axis = axis
    self.container = container
    self.startFraction = fraction
    self.fraction = fraction
    self.grabPointer = Self.pointer(grab, axis: axis, container: container)
    self.splitLeaves = splitLeaves
  }

  public init(tab: Tab, divider: PaneDivider, grabbedAt grab: CGPoint) {
    self.init(
      tabId: tab.id, path: divider.path, axis: divider.axis, container: divider.container,
      fraction: divider.fraction, grabbedAt: grab,
      splitLeaves: tab.panes.subtree(at: divider.path)?.leafSessionIds() ?? [])
  }

  public var hasMoved: Bool { fraction != startFraction }

  // y grows upward, so a horizontal divider's fraction is measured down from the top.
  private static func pointer(_ point: CGPoint, axis: PaneAxis, container: CGRect) -> CGFloat {
    axis == .vertical ? point.x - container.minX : container.maxY - point.y
  }

  public mutating func moveTo(x: CGFloat, y: CGFloat) {
    let extent = axis == .vertical ? container.width : container.height
    guard extent > 0 else { return }
    let delta = Self.pointer(CGPoint(x: x, y: y), axis: axis, container: container) - grabPointer
    fraction = startFraction + Double(delta / extent)
  }

  /// The translucent line to draw for the proposed position.
  public var previewRect: CGRect {
    PaneDivider.previewRect(axis: axis, container: container, fraction: fraction)
  }

  /// Whether `tab` still holds the split this drag grabbed: same panes, same axis.
  public func targetsSameSplit(in tab: Tab) -> Bool {
    guard tab.id == tabId, case .split(let current, _, _, _)? = tab.panes.subtree(at: path)
    else { return false }
    return current == axis && tab.panes.subtree(at: path)?.leafSessionIds() == splitLeaves
  }
}

extension PaneDividerDrag {
  /// Moves the proposal to the pointer and clamps it to where a commit would land, so the
  /// preview line shows the real outcome. The one drag-move path for the AppKit view and
  /// the headless runtime; it must never touch the pane tree or the PTY sizes.
  public mutating func move(toX x: CGFloat, y: CGFloat, in model: AppModel) {
    moveTo(x: x, y: y)
    // Back at the grab point is no move at all, even when the start sits outside the clamp.
    guard hasMoved else { return }
    if let clamped = model.clampedSplitFraction(inTab: tabId, path: path, fraction: fraction) {
      fraction = clamped
    }
  }

  /// Release: applies the proposal to the tree once, which resizes the shells once. A bare
  /// click, a tab that is no longer active, a zoomed tab and a split that changed shape
  /// under the drag change nothing. The one commit path for the AppKit view and the
  /// headless runtime.
  public func commit(in model: AppModel) {
    guard hasMoved, let tab = model.activeTab, targetsSameSplit(in: tab), !tab.isZoomed
    else { return }
    try? model.setSplitFraction(inTab: tabId, path: path, fraction: fraction)
  }
}

/// Layout owns only identity and geometry; sessions own processes and terminal state.
public indirect enum PaneTree: Equatable, Codable, Sendable {
  case leaf(sessionId: Session.ID)
  case split(axis: PaneAxis, fraction: Double, first: PaneTree, second: PaneTree)

  public func leafSessionIds() -> [Session.ID] {
    switch self {
    case .leaf(let id): return [id]
    case .split(_, _, let first, let second):
      return first.leafSessionIds() + second.leafSessionIds()
    }
  }

  public func contains(_ id: Session.ID) -> Bool { leafSessionIds().contains(id) }

  public func splitting(
    leaf id: Session.ID, axis: PaneAxis, newSessionId: Session.ID, newFirst: Bool = false
  ) -> PaneTree? {
    guard !contains(newSessionId) else { return nil }
    switch self {
    case .leaf(let existing) where existing == id:
      let new = PaneTree.leaf(sessionId: newSessionId)
      return .split(
        axis: axis, fraction: 0.5, first: newFirst ? new : self, second: newFirst ? self : new)
    case .leaf: return nil
    case .split(let axis0, let fraction, let first, let second):
      if let changed = first.splitting(
        leaf: id, axis: axis, newSessionId: newSessionId, newFirst: newFirst)
      {
        return .split(axis: axis0, fraction: fraction, first: changed, second: second)
      }
      if let changed = second.splitting(
        leaf: id, axis: axis, newSessionId: newSessionId, newFirst: newFirst)
      {
        return .split(axis: axis0, fraction: fraction, first: first, second: changed)
      }
      return nil
    }
  }

  public func removing(leaf id: Session.ID) -> PaneTree? {
    switch self {
    case .leaf(let existing): return existing == id ? nil : self
    case .split(let axis, let fraction, let first, let second):
      guard let remainingFirst = first.removing(leaf: id) else { return second }
      guard let remainingSecond = second.removing(leaf: id) else { return first }
      return .split(axis: axis, fraction: fraction, first: remainingFirst, second: remainingSecond)
    }
  }

  public func settingFraction(ofSplitContaining id: Session.ID, to value: Double) -> PaneTree {
    guard var parent = path(toLeaf: id), !parent.isEmpty else { return self }
    parent.removeLast()
    return settingFraction(at: parent, to: value) ?? self
  }

  /// Sets the fraction of the split at `path`, clamped to the sanity range
  /// 0.05...0.95. Returns nil if `path` does not name a split. A non-finite value
  /// leaves the tree unchanged. Minimum pane sizes are the caller's concern
  /// (see `fractionRange`).
  public func settingFraction(at path: PanePath, to value: Double) -> PaneTree? {
    guard let side = path.first else {
      guard case .split(let axis, let fraction, let first, let second) = self else { return nil }
      let next = value.isFinite ? Self.clampFraction(value) : fraction
      return .split(axis: axis, fraction: next, first: first, second: second)
    }
    guard case .split(let axis, let fraction, let first, let second) = self else { return nil }
    let rest = Array(path.dropFirst())
    switch side {
    case .first:
      guard let changed = first.settingFraction(at: rest, to: value) else { return nil }
      return .split(axis: axis, fraction: fraction, first: changed, second: second)
    case .second:
      guard let changed = second.settingFraction(at: rest, to: value) else { return nil }
      return .split(axis: axis, fraction: fraction, first: first, second: changed)
    }
  }

  /// The route from the root to the leaf showing `id`, as the sides taken at each
  /// enclosing split. The path to the root leaf of an unsplit tree is `[]`.
  public func path(toLeaf id: Session.ID) -> PanePath? {
    switch self {
    case .leaf(let existing): return existing == id ? [] : nil
    case .split(_, _, let first, let second):
      if let rest = first.path(toLeaf: id) { return [.first] + rest }
      if let rest = second.path(toLeaf: id) { return [.second] + rest }
      return nil
    }
  }

  /// The subtree at `path`, or nil if the path leaves the tree.
  func subtree(at path: PanePath) -> PaneTree? {
    guard let side = path.first else { return self }
    guard case .split(_, _, let first, let second) = self else { return nil }
    return (side == .first ? first : second).subtree(at: Array(path.dropFirst()))
  }

  /// The smallest extent this subtree needs along `axis`. A leaf needs `leafMinimum`;
  /// a split along `axis` needs both children plus its divider; a split across
  /// `axis` needs only its larger child.
  public func minimumExtent(
    along axis: PaneAxis, leafMinimum: CGFloat, dividerWidth: CGFloat
  ) -> CGFloat {
    switch self {
    case .leaf: return leafMinimum
    case .split(let splitAxis, _, let first, let second):
      let a = first.minimumExtent(along: axis, leafMinimum: leafMinimum, dividerWidth: dividerWidth)
      let b = second.minimumExtent(
        along: axis, leafMinimum: leafMinimum, dividerWidth: dividerWidth)
      return splitAxis == axis ? a + b + dividerWidth : max(a, b)
    }
  }

  /// The fractions at which the split at `path` keeps both sides at or above their
  /// minimum extents inside `rect`. When the container is too small for both, the
  /// range collapses to the single value that shares the shortfall evenly, so a drag
  /// can never invert the split. Nil if `path` does not name a split.
  public func fractionRange(
    at path: PanePath, in rect: CGRect, minimumWidth: CGFloat, minimumHeight: CGFloat,
    dividerWidth: CGFloat
  ) -> ClosedRange<Double>? {
    guard
      let divider = dividers(in: rect, dividerWidth: dividerWidth).first(where: { $0.path == path }
      ),
      case .split(let axis, _, let first, let second)? = subtree(at: path)
    else { return nil }
    let vertical = axis == .vertical
    let extent = Double(vertical ? divider.container.width : divider.container.height)
    guard extent > 0 else { return 0.5...0.5 }
    let leafMinimum = vertical ? minimumWidth : minimumHeight
    let firstMinimum = Double(
      first.minimumExtent(along: axis, leafMinimum: leafMinimum, dividerWidth: dividerWidth))
    let secondMinimum = Double(
      second.minimumExtent(along: axis, leafMinimum: leafMinimum, dividerWidth: dividerWidth))
    let low = firstMinimum / extent
    let high = (extent - Double(dividerWidth) - secondMinimum) / extent
    let clampedLow = Self.clampFraction(low)
    let clampedHigh = Self.clampFraction(high)
    if low <= high && clampedLow <= clampedHigh { return clampedLow...clampedHigh }
    let middle = Self.clampFraction((low + high) / 2)
    return middle...middle
  }

  /// Gives every leaf along a run of same-axis splits an equal share. A node's weight
  /// along an axis is 1 for a leaf or a split across that axis, and the sum of its
  /// children's weights for a split along it.
  public func equalized() -> PaneTree {
    guard case .split(let axis, _, let first, let second) = self else { return self }
    let a = Double(first.weight(along: axis))
    let b = Double(second.weight(along: axis))
    return .split(
      axis: axis, fraction: a / (a + b), first: first.equalized(), second: second.equalized())
  }

  private func weight(along axis: PaneAxis) -> Int {
    guard case .split(let splitAxis, _, let first, let second) = self, splitAxis == axis else {
      return 1
    }
    return first.weight(along: axis) + second.weight(along: axis)
  }

  /// The pane to focus when moving `direction` from `id`. Candidates lie entirely on
  /// that side of the focused pane. Panes sharing no perpendicular extent are used
  /// only when nothing overlaps. Ranking: perpendicular overlap present, smaller
  /// directional distance, larger overlap, smaller centre offset, more recent in
  /// `history` (later entries are more recent).
  public func directionalNeighbour(
    of id: Session.ID, direction: PaneDirection, in rect: CGRect, dividerWidth: CGFloat,
    history: [Session.ID]
  ) -> Session.ID? {
    let panes = layout(in: rect, dividerWidth: dividerWidth)
    guard let focused = panes.first(where: { $0.sessionId == id })?.rect else { return nil }
    let tolerance: CGFloat = 1

    struct Candidate {
      let id: Session.ID
      let hasOverlap: Bool
      let distance: CGFloat
      let overlap: CGFloat
      let centreOffset: CGFloat
      let recency: Int
    }

    func candidate(_ pane: PaneRect) -> Candidate? {
      guard pane.sessionId != id else { return nil }
      let r = pane.rect
      let distance: CGFloat
      let overlap: CGFloat
      let centreOffset: CGFloat
      switch direction {
      case .right:
        guard r.minX >= focused.maxX - 0.001 else { return nil }
        distance = r.minX - focused.maxX
      case .left:
        guard r.maxX <= focused.minX + 0.001 else { return nil }
        distance = focused.minX - r.maxX
      case .up:
        guard r.minY >= focused.maxY - 0.001 else { return nil }
        distance = r.minY - focused.maxY
      case .down:
        guard r.maxY <= focused.minY + 0.001 else { return nil }
        distance = focused.minY - r.maxY
      }
      if direction.axis == .vertical {
        overlap = min(r.maxY, focused.maxY) - max(r.minY, focused.minY)
        centreOffset = abs(r.midY - focused.midY)
      } else {
        overlap = min(r.maxX, focused.maxX) - max(r.minX, focused.minX)
        centreOffset = abs(r.midX - focused.midX)
      }
      return Candidate(
        id: pane.sessionId, hasOverlap: overlap > 0, distance: distance,
        overlap: max(0, overlap), centreOffset: centreOffset,
        recency: history.lastIndex(of: pane.sessionId) ?? -1)
    }

    func better(_ a: Candidate, than b: Candidate) -> Bool {
      if a.hasOverlap != b.hasOverlap { return a.hasOverlap }
      if abs(a.distance - b.distance) > tolerance / 2 { return a.distance < b.distance }
      if abs(a.overlap - b.overlap) > tolerance { return a.overlap > b.overlap }
      if abs(a.centreOffset - b.centreOffset) > tolerance { return a.centreOffset < b.centreOffset }
      return a.recency > b.recency
    }

    var best: Candidate?
    for pane in panes {
      guard let next = candidate(pane) else { continue }
      if let current = best, !better(next, than: current) { continue }
      best = next
    }
    return best?.id
  }

  /// The split whose divider a keyboard nudge in `direction` should move for the pane
  /// `id`: the nearest enclosing split along the direction's axis in which the pane
  /// is on the side the arrow points away from.
  public func nudgeTarget(for id: Session.ID, direction: PaneDirection) -> PanePath? {
    guard let route = path(toLeaf: id) else { return nil }
    for depth in stride(from: route.count - 1, through: 0, by: -1) {
      let ancestor = Array(route.prefix(depth))
      guard case .split(let axis, _, _, _)? = subtree(at: ancestor), axis == direction.axis
      else { continue }
      let side = route[depth]
      if direction.towardsSecond ? side == .first : side == .second { return ancestor }
    }
    return nil
  }

  public func layout(in rect: CGRect, dividerWidth: CGFloat = 1) -> [PaneRect] {
    switch self {
    case .leaf(let id): return [PaneRect(sessionId: id, rect: rect)]
    case .split(let axis, let fraction, let first, let second):
      let (a, _, b) = Self.partition(
        rect, axis: axis, fraction: fraction, dividerWidth: dividerWidth)
      return first.layout(in: a, dividerWidth: dividerWidth)
        + second.layout(in: b, dividerWidth: dividerWidth)
    }
  }

  public func dividerRects(in rect: CGRect, dividerWidth: CGFloat = 1) -> [CGRect] {
    dividers(in: rect, dividerWidth: dividerWidth).map(\.rect)
  }

  /// Every divider of the tree laid out in `rect`, parents before children, each with
  /// its path, the rect of its owning split and its current fraction.
  public func dividers(in rect: CGRect, dividerWidth: CGFloat = 1) -> [PaneDivider] {
    dividers(in: rect, dividerWidth: dividerWidth, path: [])
  }

  private func dividers(in rect: CGRect, dividerWidth: CGFloat, path: PanePath) -> [PaneDivider] {
    switch self {
    case .leaf: return []
    case .split(let axis, let fraction, let first, let second):
      let (a, divider, b) = Self.partition(
        rect, axis: axis, fraction: fraction, dividerWidth: dividerWidth)
      return [
        PaneDivider(path: path, axis: axis, rect: divider, container: rect, fraction: fraction)
      ]
        + first.dividers(in: a, dividerWidth: dividerWidth, path: path + [.first])
        + second.dividers(in: b, dividerWidth: dividerWidth, path: path + [.second])
    }
  }

  private static func clampFraction(_ value: Double) -> Double { min(0.95, max(0.05, value)) }

  private static func partition(
    _ rect: CGRect, axis: PaneAxis, fraction: Double, dividerWidth: CGFloat
  ) -> (CGRect, CGRect, CGRect) {
    let vertical = axis == .vertical
    let extent = max(0, vertical ? rect.width : rect.height)
    let cut = floor(extent * CGFloat(fraction.isFinite ? clampFraction(fraction) : 0.5))
    let divider = min(max(0, dividerWidth), extent - cut)
    if vertical {
      return (
        CGRect(x: rect.minX, y: rect.minY, width: cut, height: rect.height),
        CGRect(x: rect.minX + cut, y: rect.minY, width: divider, height: rect.height),
        CGRect(
          x: rect.minX + cut + divider, y: rect.minY, width: extent - cut - divider,
          height: rect.height)
      )
    }
    // Layout rects are in render and view space, where y grows upward, so the `first`
    // (top) child sits at the high-y end of the rect.
    let secondHeight = extent - cut - divider
    return (
      CGRect(x: rect.minX, y: rect.minY + secondHeight + divider, width: rect.width, height: cut),
      CGRect(x: rect.minX, y: rect.minY + secondHeight, width: rect.width, height: divider),
      CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: secondHeight)
    )
  }
}

public struct PaneRect: Equatable {
  public let sessionId: Session.ID
  public let rect: CGRect

  public init(sessionId: Session.ID, rect: CGRect) {
    self.sessionId = sessionId
    self.rect = rect
  }
}
