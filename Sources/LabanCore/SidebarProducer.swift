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
  ///
  /// `hoveredTabId` controls visibility of the per-tab close glyph: it
  /// renders only when the cursor is over the tab. The click region for
  /// closing is region-based (always live in `hitTest`), so the affordance
  /// is just visually quieter — discoverable but unobtrusive.
  public func commands(
    tabs: [Tab], activeTabId: Tab.ID?, height: CGFloat, topInset: CGFloat = 0,
    hoveredTabId: Tab.ID? = nil
  ) -> [FrameCommand] {
    var cmds: [FrameCommand] = []
    cmds.reserveCapacity(tabs.count * 7 + 6)

    // Sidebar background
    cmds.append(
      .rect(
        CGRect(x: 0, y: 0, width: sidebarWidth, height: height),
        color: Theme.current.bg1,
        source: .sidebar
      ))

    // The "+" new-tab button no longer lives in the sidebar — the AppKit
    // shell renders it as a titlebar accessory next to the traffic
    // lights so the sidebar is purely tab rows. Tabs start at the top.

    // Tab rows
    for (i, tab) in tabs.enumerated() {
      let tabY = height - CGFloat(i + 1) * rowHeight - topInset
      let isActive = tab.id == activeTabId
      let bg = isActive ? Theme.current.bg2 : Theme.current.bg1
      let fg = isActive ? Theme.current.fg1 : Theme.current.fg0

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
            color: Theme.current.blue,
            source: .sidebar
          ))
      }

      let labelX: CGFloat = isActive ? 12 : 10
      let exited = tab.status != .running
      let labelFg = exited ? Theme.current.dim0 : fg
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

      // Top-right indicator, by specificity:
      //  1. OSC 21337 agent dot — an agent explicitly reported a status.
      //  2. OSC 133 shell phase — a command failed (red) or is running
      //     (blue). This complements the bell badge: the bell says "output
      //     happened", the shell phase says "the command finished, here's
      //     whether it succeeded".
      //  3. Legacy red attention badge — "something happened in this tab".
      let meta = tab.titleMetadata
      let agentStatus = meta.agentStatus
      if let hex = agentStatus.indicatorColor,
        let color = Self.parseHexColor(hex)
      {
        cmds.append(
          .glyphRun(
            origin: CGPoint(x: badgeX, y: titleY),
            text: "●",
            foreground: color,
            background: bg,
            attributes: [],
            source: .sidebar
          ))
      } else if let shellColor = Self.shellPhaseIndicatorColor(meta) {
        cmds.append(
          .glyphRun(
            origin: CGPoint(x: badgeX, y: titleY),
            text: "●",
            foreground: shellColor,
            background: bg,
            attributes: [],
            source: .sidebar
          ))
      } else if let badge = resolved.statusBadge {
        cmds.append(
          .glyphRun(
            origin: CGPoint(x: badgeX, y: titleY),
            text: badge,
            foreground: Theme.current.red,
            background: bg,
            attributes: [],
            source: .sidebar
          ))
      }

      // Build the info-line stack. When an agent has pushed a status
      // text, it owns the first info slot — that's the most actionable
      // signal on the tab right now, more than which folder or which
      // binary is running. We keep a max of three info lines under the
      // title; folder and branch follow, and the command line drops out
      // when status takes its slot.
      var displayLines: [(String, UInt32)] = []
      if let st = agentStatus.statusText {
        let color =
          agentStatus.statusTextColor.flatMap(Self.parseHexColor)
          ?? Theme.current.fg0
        displayLines.append((st, color))
      }
      for line in resolved.infoLines.prefix(3 - displayLines.count) {
        displayLines.append((line, Theme.current.dim0))
      }
      for (offset, entry) in displayLines.enumerated() {
        cmds.append(
          .glyphRun(
            origin: CGPoint(x: labelX, y: lineY(offset + 1)),
            text: entry.0,
            foreground: entry.1,
            background: bg,
            attributes: [],
            source: .sidebar
          ))
      }

      // Close glyph: rendered only when this tab is hovered. Heavy `✕`
      // gives a beefier hit target than the previous `×` without needing
      // a separate font size. Click region is region-based (see hitTest)
      // so the affordance still works even when the glyph isn't shown.
      if hoveredTabId == tab.id {
        cmds.append(
          .glyphRun(
            origin: CGPoint(x: closeGlyphX, y: titleY),
            text: "✕",
            foreground: Theme.current.dim0,
            background: bg,
            attributes: [],
            source: .sidebar
          ))
      }
    }

    return cmds
  }

  // CG coordinates (y=0 at bottom). The "+" button is a titlebar
  // accessory now — sidebar hits are exclusively tab select / close.
  public func hitTest(
    at point: CGPoint, tabs: [Tab], height: CGFloat, topInset: CGFloat = 0
  ) -> HitResult {
    guard point.x >= 0, point.x < sidebarWidth else { return .none }

    for (i, tab) in tabs.enumerated() {
      let tabY = height - CGFloat(i + 1) * rowHeight - topInset
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

  /// The indicator color for a tab's OSC 133 shell phase, or nil when no
  /// indicator should show. A non-zero last command exit is the most
  /// actionable signal (red); a running command shows blue. `atPrompt` and
  /// `idle` show nothing so the sidebar stays quiet at rest.
  static func shellPhaseIndicatorColor(_ meta: TabTitleMetadata) -> UInt32? {
    if let exit = meta.lastCommandExitCode, exit != 0, meta.shellPhase == .finished {
      return Theme.current.red
    }
    if meta.shellPhase == .running {
      return Theme.current.blue
    }
    return nil
  }

  /// Parse OSC 21337 color values into the 0xRRGGBBAA format the renderer
  /// expects. Accepts the iTerm-observed `#rrggbb` form and the X11/CSS
  /// `rgb:R/G/B` form (each channel 1–4 hex chars). Alpha is forced to
  /// fully opaque since the OSC spec doesn't carry alpha.
  static func parseHexColor(_ raw: String) -> UInt32? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if trimmed.lowercased().hasPrefix("rgb:") {
      let body = trimmed.dropFirst(4)
      let parts = body.split(separator: "/")
      guard parts.count == 3 else { return nil }
      func channel(_ s: Substring) -> UInt32? {
        guard !s.isEmpty, s.count <= 4,
          let v = UInt32(s, radix: 16)
        else { return nil }
        // Scale to 0..255 based on the number of nibbles (e.g. "ff"→255,
        // "ffff"→255, "f"→255).
        let max = (UInt32(1) << (UInt32(s.count) * 4)) - 1
        return UInt32((v * 255 + max / 2) / max)
      }
      guard let r = channel(parts[0]), let g = channel(parts[1]),
        let b = channel(parts[2])
      else { return nil }
      return (r << 24) | (g << 16) | (b << 8) | 0xFF
    }

    var hex = Substring(trimmed)
    if hex.hasPrefix("#") { hex = hex.dropFirst() }
    guard hex.count == 6, let val = UInt32(hex, radix: 16) else { return nil }
    return (val << 8) | 0xFF
  }
}
