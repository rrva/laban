import Foundation

public enum PaneAxis: String, Codable, Sendable {
  case horizontal, vertical
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
    guard value.isFinite else { return self }
    switch self {
    case .leaf: return self
    case .split(let axis, let fraction, let first, let second):
      if first == .leaf(sessionId: id) || second == .leaf(sessionId: id) {
        return .split(axis: axis, fraction: min(0.9, max(0.1, value)), first: first, second: second)
      }
      return .split(
        axis: axis, fraction: fraction,
        first: first.settingFraction(ofSplitContaining: id, to: value),
        second: second.settingFraction(ofSplitContaining: id, to: value))
    }
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
    switch self {
    case .leaf: return []
    case .split(let axis, let fraction, let first, let second):
      let (a, divider, b) = Self.partition(
        rect, axis: axis, fraction: fraction, dividerWidth: dividerWidth)
      return [divider] + first.dividerRects(in: a, dividerWidth: dividerWidth)
        + second.dividerRects(in: b, dividerWidth: dividerWidth)
    }
  }

  private static func partition(
    _ rect: CGRect, axis: PaneAxis, fraction: Double, dividerWidth: CGFloat
  ) -> (CGRect, CGRect, CGRect) {
    let vertical = axis == .vertical
    let extent = max(0, vertical ? rect.width : rect.height)
    let cut = floor(extent * CGFloat(fraction.isFinite ? min(0.9, max(0.1, fraction)) : 0.5))
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
    return (
      CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: cut),
      CGRect(x: rect.minX, y: rect.minY + cut, width: rect.width, height: divider),
      CGRect(
        x: rect.minX, y: rect.minY + cut + divider, width: rect.width,
        height: extent - cut - divider)
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
