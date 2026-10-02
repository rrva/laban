import Foundation

public enum AppError: Error, Equatable {
  case tabLimitReached
  case tabNotFound
  case lastTabClosed
}

public enum TabStatus: Equatable {
  case running
  case exited(code: Int)
  case exitedSignal(signal: Int)

  public var debugString: String {
    switch self {
    case .running: return "running"
    case .exited: return "exited"
    case .exitedSignal: return "exited"
    }
  }
}

public struct Tab {
  public typealias ID = String

  public let id: ID
  public var position: Int
  public var title: String {
    get { titleMetadata.displayTitle }
    set {
      guard let userTitle = TerminalTitle.sanitize(newValue) else { return }
      titleMetadata.userTitle = userTitle
      titleMetadata.displayTitle = userTitle
      titleMetadata.titleSource = .user
    }
  }
  public var isActive: Bool
  public var panes: PaneTree
  public var focusedSessionId: Session.ID
  public var focusHistory: [Session.ID]
  public var allSessionIds: [Session.ID] { panes.leafSessionIds() }
  /// The pane that temporarily fills the whole terminal area while the others keep
  /// running hidden. Persisted with the workspace. Ignored when it is not in the tree.
  public var zoomedSessionId: Session.ID?

  /// True when `zoomedSessionId` names a pane that is still in the tree.
  public var isZoomed: Bool { zoomedSessionId.map { panes.contains($0) } ?? false }

  /// How many panes are drawn: one while zoomed, otherwise every leaf. Renderer and
  /// input code use this (not `allSessionIds.count`) to choose the split or
  /// single-pane path.
  public var visiblePaneCount: Int { isZoomed ? 1 : allSessionIds.count }

  /// The pane rectangles actually shown: the zoomed pane alone filling `rect`, or the
  /// whole tree's layout. Everything that draws, hit-tests or resizes uses this.
  public func visibleLayout(in rect: CGRect, dividerWidth: CGFloat = 1) -> [PaneRect] {
    if isZoomed, let zoomedSessionId {
      return [PaneRect(sessionId: zoomedSessionId, rect: rect)]
    }
    return panes.layout(in: rect, dividerWidth: dividerWidth)
  }

  /// The dividers actually shown: none while zoomed.
  public func visibleDividers(in rect: CGRect, dividerWidth: CGFloat = 1) -> [PaneDivider] {
    isZoomed ? [] : panes.dividers(in: rect, dividerWidth: dividerWidth)
  }

  /// A session-addressed view for daemon adapters. Does not mutate model focus.
  public func focusing(_ sessionId: Session.ID) -> Tab {
    precondition(panes.contains(sessionId))
    var copy = self
    copy.focusedSessionId = sessionId
    return copy
  }
  public var status: TabStatus = .running
  public var titleMetadata: TabTitleMetadata
  /// Last output / activity time for this tab's session. Runtime-only (never
  /// persisted) and bumped on every output tick, so it lives on Tab rather than
  /// on TabTitleMetadata: keeping it off the title struct means an output tick
  /// no longer mutates TabTitleMetadata, so it cannot invalidate the sidebar's
  /// metadata-keyed cache or force a per-tick title re-resolve. Read only by the
  /// relative-age subtitle and the debug endpoints.
  public var lastActivityAt: Date?
  public var lastOutputAt: Date?

  public init(
    id: ID,
    position: Int,
    title: String,
    isActive: Bool,
    sessionId: Session.ID,
    status: TabStatus = .running,
    lastActivityAt: Date? = nil,
    lastOutputAt: Date? = nil,
    titleMetadata: TabTitleMetadata? = nil
  ) {
    self.id = id
    self.position = position
    self.isActive = isActive
    self.panes = .leaf(sessionId: sessionId)
    self.focusedSessionId = sessionId
    self.focusHistory = [sessionId]
    self.status = status
    self.lastActivityAt = lastActivityAt
    self.lastOutputAt = lastOutputAt

    if let titleMetadata {
      self.titleMetadata = TabTitleResolver.resolvedMetadata(
        titleMetadata,
        fallbackPosition: position
      )
    } else if title == "Tab \(position)" {
      self.titleMetadata = TabTitleMetadata.fallback(position: position, active: isActive)
    } else {
      let sanitized = TerminalTitle.sanitize(title) ?? "Tab \(position)"
      self.titleMetadata = TabTitleMetadata(
        userTitle: sanitized,
        displayTitle: sanitized,
        titleSource: .user,
        activityState: isActive ? .active : .background
      )
    }
  }
}
