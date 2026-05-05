import CoreGraphics
import LabanRenderer

// Produces FrameCommands for the left-side tab sidebar.
// Uses CG coordinates (y=0 at bottom-left); callers pass the view height.
// Row layout (top → bottom in display, high → low in CG y):
//   Row 0 (top):    "+" new-tab button
//   Row 1..N:       one row per tab
public struct SidebarProducer {
  public let sidebarWidth: CGFloat
  public let cellWidth: CGFloat
  public let cellHeight: CGFloat
  public let rowHeight: CGFloat

  public init(
    sidebarWidth: CGFloat = 200,
    cellWidth: CGFloat = 8,
    cellHeight: CGFloat = 16
  ) {
    self.sidebarWidth = sidebarWidth
    self.cellWidth = cellWidth
    self.cellHeight = cellHeight
    self.rowHeight = ceil(cellHeight * 2) + 10
  }

  public enum HitResult: Equatable {
    case newTab
    case selectTab(Tab.ID)
    case closeTab(Tab.ID)
    case none
  }

  /// `topInset` reserves vertical space at the top of the sidebar column —
  /// used by the AppKit shell to keep the first tab clear of the window
  /// traffic lights when running with a transparent full-size titlebar. The
  /// background rect still fills the full column so the reserved strip
  /// inherits the sidebar color rather than exposing the window beneath.
  public func commands(
    tabs: [Tab], activeTabId: Tab.ID?, height: CGFloat, topInset: CGFloat = 0
  ) -> [FrameCommand] {
    var cmds: [FrameCommand] = []
    cmds.reserveCapacity(tabs.count * 7 + 6)

    // Sidebar background
    cmds.append(
      .rect(
        CGRect(x: 0, y: 0, width: sidebarWidth, height: height),
        color: Theme.CurrentTheme.bg1,
        source: .sidebar
      ))

    // New-tab "+" row (topmost row)
    let newTabY = height - rowHeight - topInset
    let textBaseY = (rowHeight - cellHeight) / 2
    cmds.append(
      .glyphRun(
        origin: CGPoint(x: 10, y: newTabY + textBaseY),
        text: "+",
        foreground: Theme.CurrentTheme.fg0,
        background: Theme.CurrentTheme.bg1,
        attributes: [],
        source: .sidebar
      ))

    // Tab rows
    for (i, tab) in tabs.enumerated() {
      let tabY = height - CGFloat(i + 2) * rowHeight - topInset
      let isActive = tab.id == activeTabId
      let bg = isActive ? Theme.CurrentTheme.bg2 : Theme.CurrentTheme.bg1
      let fg = isActive ? Theme.CurrentTheme.fg1 : Theme.CurrentTheme.fg0

      cmds.append(
        .rect(
          CGRect(x: 0, y: tabY, width: sidebarWidth, height: rowHeight),
          color: bg,
          source: .sidebar
        ))

      if isActive {
        cmds.append(
          .rect(
            CGRect(x: 0, y: tabY, width: 3, height: rowHeight),
            color: Theme.CurrentTheme.blue,
            source: .sidebar
          ))
      }

      let labelX: CGFloat = isActive ? 12 : 10
      let exited = tab.status != .running
      let labelFg = exited ? Theme.CurrentTheme.dim0 : fg
      let closeX = sidebarWidth - 22
      let markerX = closeX - 16
      let indexText = "\(tab.position)"
      let titleX = labelX + CGFloat(indexText.count + 1) * cellWidth
      let titleMaxScalars = max(1, Int(floor((markerX - titleX - 4) / cellWidth)))
      let subtitleMaxScalars = max(1, Int(floor((closeX - titleX - 4) / cellWidth)))
      let resolved = TabTitleResolver.resolve(
        tab.titleMetadata,
        fallbackPosition: tab.position,
        maxTitleScalars: titleMaxScalars,
        maxSubtitleScalars: subtitleMaxScalars
      )
      let primaryY =
        rowHeight >= cellHeight * 2 + 8
        ? tabY + rowHeight - cellHeight - 5
        : tabY + textBaseY
      let secondaryY = tabY + 5

      cmds.append(
        .glyphRun(
          origin: CGPoint(x: labelX, y: primaryY),
          text: indexText,
          foreground: labelFg,
          background: bg,
          attributes: [],
          source: .sidebar
        ))
      cmds.append(
        .glyphRun(
          origin: CGPoint(x: titleX, y: primaryY),
          text: resolved.displayTitle,
          foreground: labelFg,
          background: bg,
          attributes: [],
          source: .sidebar
        ))

      if let badge = resolved.statusBadge {
        cmds.append(
          .glyphRun(
            origin: CGPoint(x: markerX, y: primaryY),
            text: badge,
            foreground: Theme.CurrentTheme.red,
            background: bg,
            attributes: [],
            source: .sidebar
          ))
      }

      if rowHeight >= cellHeight * 2 + 8, let subtitle = resolved.subtitle {
        cmds.append(
          .glyphRun(
            origin: CGPoint(x: titleX, y: secondaryY),
            text: subtitle,
            foreground: Theme.CurrentTheme.dim0,
            background: bg,
            attributes: [],
            source: .sidebar
          ))
      }

      cmds.append(
        .glyphRun(
          origin: CGPoint(x: sidebarWidth - 22, y: tabY + textBaseY),
          text: "×",
          foreground: Theme.CurrentTheme.dim0,
          background: bg,
          attributes: [],
          source: .sidebar
        ))
    }

    return cmds
  }

  // CG coordinates (y=0 at bottom).
  public func hitTest(
    at point: CGPoint, tabs: [Tab], height: CGFloat, topInset: CGFloat = 0
  ) -> HitResult {
    guard point.x >= 0, point.x < sidebarWidth else { return .none }

    let newTabY = height - rowHeight - topInset
    if point.y >= newTabY, point.y < newTabY + rowHeight { return .newTab }

    for (i, tab) in tabs.enumerated() {
      let tabY = height - CGFloat(i + 2) * rowHeight - topInset
      guard point.y >= tabY, point.y < tabY + rowHeight else { continue }
      if point.x >= sidebarWidth - 28 { return .closeTab(tab.id) }
      return .selectTab(tab.id)
    }

    return .none
  }
}
