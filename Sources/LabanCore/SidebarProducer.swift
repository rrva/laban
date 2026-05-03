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
    self.rowHeight = ceil(cellHeight) + 8
  }

  public enum HitResult: Equatable {
    case newTab
    case selectTab(Tab.ID)
    case closeTab(Tab.ID)
    case none
  }

  public func commands(tabs: [Tab], activeTabId: Tab.ID?, height: CGFloat) -> [FrameCommand] {
    var cmds: [FrameCommand] = []
    cmds.reserveCapacity(tabs.count * 5 + 6)

    // Sidebar background
    cmds.append(
      .rect(
        CGRect(x: 0, y: 0, width: sidebarWidth, height: height),
        color: Theme.SelenizedLight.bg1,
        source: .sidebar
      ))

    // New-tab "+" row (topmost row)
    let newTabY = height - rowHeight
    let textBaseY = (rowHeight - cellHeight) / 2
    cmds.append(
      .glyphRun(
        origin: CGPoint(x: 10, y: newTabY + textBaseY),
        text: "+",
        foreground: Theme.SelenizedLight.fg0,
        background: Theme.SelenizedLight.bg1,
        source: .sidebar
      ))

    // Tab rows
    for (i, tab) in tabs.enumerated() {
      let tabY = height - CGFloat(i + 2) * rowHeight
      let isActive = tab.id == activeTabId
      let bg = isActive ? Theme.SelenizedLight.bg2 : Theme.SelenizedLight.bg1
      let fg = isActive ? Theme.SelenizedLight.fg1 : Theme.SelenizedLight.fg0

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
            color: Theme.SelenizedLight.blue,
            source: .sidebar
          ))
      }

      let labelX: CGFloat = isActive ? 12 : 10
      let label = "\(tab.position) \(tab.title.prefix(10))"
      cmds.append(
        .glyphRun(
          origin: CGPoint(x: labelX, y: tabY + textBaseY),
          text: label,
          foreground: fg,
          background: bg,
          source: .sidebar
        ))

      cmds.append(
        .glyphRun(
          origin: CGPoint(x: sidebarWidth - 22, y: tabY + textBaseY),
          text: "×",
          foreground: Theme.SelenizedLight.dim0,
          background: bg,
          source: .sidebar
        ))
    }

    return cmds
  }

  // CG coordinates (y=0 at bottom).
  public func hitTest(at point: CGPoint, tabs: [Tab], height: CGFloat) -> HitResult {
    guard point.x >= 0, point.x < sidebarWidth else { return .none }

    let newTabY = height - rowHeight
    if point.y >= newTabY, point.y < newTabY + rowHeight { return .newTab }

    for (i, tab) in tabs.enumerated() {
      let tabY = height - CGFloat(i + 2) * rowHeight
      guard point.y >= tabY, point.y < tabY + rowHeight else { continue }
      if point.x >= sidebarWidth - 28 { return .closeTab(tab.id) }
      return .selectTab(tab.id)
    }

    return .none
  }
}
