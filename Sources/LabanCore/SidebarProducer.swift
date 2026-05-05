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
    // Four lines per tab: title + workspace + command + status. Padding kept
    // tight so 9 tabs still fit in a typical window without a scrollbar.
    self.rowHeight = ceil(cellHeight * 4) + 10
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
      // Close button lives in the top-right of the row, aligned with the
      // title baseline. Hit area is restricted to the actual glyph extent
      // so clicks elsewhere on the right edge still select the tab.
      let closeGlyphX = sidebarWidth - 18
      let badgeX = closeGlyphX - 16
      let indexText = "\(tab.position)"
      let titleX = labelX + CGFloat(indexText.count + 1) * cellWidth
      let titleMaxScalars = max(1, Int(floor((badgeX - titleX - 4) / cellWidth)))
      // Info lines start at labelX (no index prefix indent) so they get the
      // full row width; subtract the right-edge padding for the close X.
      let infoMaxScalars = max(1, Int(floor((closeGlyphX - labelX - 4) / cellWidth)))
      let resolved = TabTitleResolver.resolve(
        tab.titleMetadata,
        fallbackPosition: tab.position,
        maxTitleScalars: titleMaxScalars,
        maxSubtitleScalars: infoMaxScalars
      )
      // Vertical layout: title + up to three info lines, centered inside
      // the fixed quad-height row. Centering keeps geometry stable across
      // status changes (a normally-running tab stays the same row height as
      // an exited one) while removing the empty bottom strip on tabs that
      // only render two lines.
      let infoCount = min(3, resolved.infoLines.count)
      let drawnLines = 1 + infoCount
      let edgePad: CGFloat = 4
      let stackHeight = CGFloat(drawnLines) * cellHeight
      let availableHeight = rowHeight - 2 * edgePad
      let yOffset = max(0, (availableHeight - stackHeight) / 2)
      let lineY: (Int) -> CGFloat = { idx in
        // idx 0 is the topmost (title); larger idx is lower on screen.
        tabY + edgePad + yOffset + CGFloat(drawnLines - 1 - idx) * cellHeight
      }
      let titleY = lineY(0)

      cmds.append(
        .glyphRun(
          origin: CGPoint(x: labelX, y: titleY),
          text: indexText,
          foreground: labelFg,
          background: bg,
          attributes: [],
          source: .sidebar
        ))
      cmds.append(
        .glyphRun(
          origin: CGPoint(x: titleX, y: titleY),
          text: resolved.displayTitle,
          foreground: labelFg,
          background: bg,
          attributes: [],
          source: .sidebar
        ))

      if let badge = resolved.statusBadge {
        cmds.append(
          .glyphRun(
            origin: CGPoint(x: badgeX, y: titleY),
            text: badge,
            foreground: Theme.CurrentTheme.red,
            background: bg,
            attributes: [],
            source: .sidebar
          ))
      }

      // Render up to three info lines under the title. Empty entries are
      // already filtered upstream so what we get is what we draw.
      for (offset, line) in resolved.infoLines.prefix(3).enumerated() {
        cmds.append(
          .glyphRun(
            origin: CGPoint(x: labelX, y: lineY(offset + 1)),
            text: line,
            foreground: Theme.CurrentTheme.dim0,
            background: bg,
            attributes: [],
            source: .sidebar
          ))
      }

      cmds.append(
        .glyphRun(
          origin: CGPoint(x: closeGlyphX, y: titleY),
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
      // Close-X box: upper half of the row on the right edge. Centering
      // moves the title vertically depending on how many info lines are
      // drawn, but the title (and the X glyph) always sits in the upper
      // half — this matches without recomputing per-tab line layout.
      let closeBoxBottom = tabY + rowHeight / 2
      if point.x >= sidebarWidth - 28, point.y >= closeBoxBottom {
        return .closeTab(tab.id)
      }
      return .selectTab(tab.id)
    }

    return .none
  }
}
