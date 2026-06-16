import CoreGraphics
import Foundation
import LabanRenderer

// Produces FrameCommands for the left-side tab sidebar.
// Uses CG coordinates (y=0 at bottom-left); callers pass the view height.
// Row layout (top to bottom in display, high to low in CG y):
//   Row 0..N:       one row per tab
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
    // Four lines per tab: title + workspace + command + status.
    self.rowHeight = ceil(cellHeight * 4) + 10
  }

  public enum HitResult: Equatable {
    case newTab
    case selectTab(Tab.ID)
    case closeTab(Tab.ID)
    case none
  }

  /// Visual state for an in-progress drag-reorder. `slot` is the
  /// insertion index in `[0, tabs.count]` where dropping would land the
  /// dragged row; `draggingTabId` is the row that should render in its
  /// "being dragged" appearance (dimmed). When the slot would simply
  /// re-insert the dragged tab into its current position the producer
  /// skips the accent bar — a no-op move shouldn't paint a drop target.
  public struct DragIndicator: Equatable {
    public var slot: Int
    public var draggingTabId: Tab.ID
    public init(slot: Int, draggingTabId: Tab.ID) {
      self.slot = slot
      self.draggingTabId = draggingTabId
    }
  }

  /// `topInset` reserves vertical space at the top of the sidebar column —
  /// used by the AppKit shell to keep the first tab clear of the window
  /// traffic lights when running with a transparent full-size titlebar. The
  /// background rect still fills the full column so the reserved strip
  /// inherits the sidebar color rather than exposing the window beneath.
  ///
  /// `hoveredTabId` swaps the right-edge slot between status indicator and
  /// close glyph: the slot anchors at `slotX` regardless of state, so
  /// nothing shifts position when the cursor enters or leaves a row. When
  /// the tab is hovered the X wins the slot; otherwise the indicator (agent
  /// dot, shell phase, attention badge) renders there. Click region is
  /// scoped to the slot so selecting a tab body still works.
  public func commands(
    tabs: [Tab], activeTabId: Tab.ID?, height: CGFloat, topInset: CGFloat = 0,
    hoveredTabId: Tab.ID? = nil,
    dragIndicator: DragIndicator? = nil,
    scrollOffset: CGFloat = 0,
    now: Date = Date(),
    reduceMotion: Bool = false
  ) -> [FrameCommand] {
    let out = output(
      tabs: tabs, activeTabId: activeTabId, height: height, topInset: topInset,
      hoveredTabId: hoveredTabId, dragIndicator: dragIndicator, scrollOffset: scrollOffset)
    // Legacy entry point with no per-tab entry times: markers render in
    // their static full-opacity rest form.
    return out.commands
  }

  /// A needsAction marker in the memoized command list: which command to
  /// re-tint, and whose entry timestamp drives its announce-once timeline.
  public struct PulseMarker {
    public var commandIndex: Int
    public var tabId: Tab.ID
  }

  /// Sidebar commands plus the needsAction markers. Markers are emitted at
  /// FULL opacity and the whole output is independent of `now`, so callers
  /// can memoize it and re-tint only the marker entries per frame while the
  /// announce animation runs — rebuilding the sidebar (and re-resolving every
  /// tab title) at the display rate just to animate one dot is what
  /// saturated the main thread under streaming load.
  public struct Output {
    public var commands: [FrameCommand]
    public var pulseMarkers: [PulseMarker]
  }

  /// Apply the announce-once timeline to the memoized marker entries: an
  /// entrance fade + halo bloom when a tab just entered needsAction, a static
  /// full-opacity marker at rest, a gentle dip on each re-ping. A no-op when
  /// nothing needs action, and markers with no recorded entry render static.
  /// Reduce Motion callers skip this — the full-opacity base IS the frozen
  /// form.
  public static func retintPulseMarkers(
    _ output: Output,
    at now: Date,
    entryTimes: [Tab.ID: Date],
    cellWidth: CGFloat,
    cellHeight: CGFloat,
    maxX: CGFloat
  ) -> [FrameCommand] {
    guard !output.pulseMarkers.isEmpty else { return output.commands }
    var cmds = output.commands
    for marker in output.pulseMarkers {
      guard let since = entryTimes[marker.tabId] else { continue }
      let elapsed = now.timeIntervalSince(since)
      guard
        case .glyphRun(
          let origin, let text, _, let background, let attributes, let source,
          let underlineStyle, let underlineColor, let hyperlink) = cmds[marker.commandIndex]
      else { continue }
      let color = AttentionPulse.applyAlpha(
        Theme.current.attention, AttentionPulse.markerAlpha(elapsed: elapsed))
      cmds[marker.commandIndex] = .glyphRun(
        origin: origin,
        text: text,
        foreground: color,
        background: background,
        attributes: attributes,
        source: source,
        underlineStyle: underlineStyle,
        underlineColor: underlineColor,
        hyperlink: hyperlink)
      if let halo = AttentionPulse.halo(elapsed: elapsed) {
        let side = max(cellWidth, cellHeight) * CGFloat(halo.scale)
        let rect = CGRect(
          x: origin.x + cellWidth / 2 - side / 2,
          y: origin.y + cellHeight / 2 - side / 2,
          width: side, height: side)
        // Appending keeps the memoized indices stable, and the bloom still
        // lands UNDER the ◆: the renderer issues all solid rects before
        // sidebar glyphs regardless of command order. Clamped to the strip
        // so the bloom can't widen the sidebar-strip scissor mid-entrance.
        let clamped = rect.intersection(
          CGRect(x: 0, y: rect.origin.y, width: maxX, height: rect.height))
        if !clamped.isEmpty {
          cmds.append(
            .rect(
              clamped,
              color: AttentionPulse.applyAlpha(Theme.current.attention, halo.alpha),
              source: .sidebar))
        }
      }
    }
    return cmds
  }

  public func output(
    tabs: [Tab], activeTabId: Tab.ID?, height: CGFloat, topInset: CGFloat = 0,
    hoveredTabId: Tab.ID? = nil,
    dragIndicator: DragIndicator? = nil,
    scrollOffset: CGFloat = 0
  ) -> Output {
    var pulseMarkers: [PulseMarker] = []
    var cmds: [FrameCommand] = []
    cmds.reserveCapacity(tabs.count * 7 + 6)
    let visibleTop = max(0, height - topInset)
    let visibleRect = CGRect(x: 0, y: 0, width: sidebarWidth, height: visibleTop)
    let scrollOffset = clampedScrollOffset(
      scrollOffset, tabCount: tabs.count, height: height, topInset: topInset)

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

    // Index of the row currently being dragged (if any). Used to dim
    // its visual without disturbing other rows.
    let draggingIndex: Int? = dragIndicator.flatMap { ind in
      tabs.firstIndex(where: { $0.id == ind.draggingTabId })
    }

    // Tab rows
    for (i, tab) in tabs.enumerated() {
      let tabY = height - CGFloat(i + 1) * rowHeight - topInset + scrollOffset
      let rowRect = CGRect(x: 0, y: tabY, width: sidebarWidth, height: rowHeight)
        .intersection(visibleRect)
      guard !rowRect.isEmpty else { continue }
      let isActive = tab.id == activeTabId
      let isDragging = (draggingIndex == i)
      let meta = tab.titleMetadata
      let agentStatus = meta.agentStatus
      // How urgently this background tab wants the user (a focused tab is always
      // `.none`). `needsAction` additionally washes the whole row faintly toward
      // the theme's attention accent.
      let attention = TabAttentionClassifier.classify(meta, isActive: isActive)
      let baseBg = isActive ? Theme.current.bg2 : Theme.current.bg1
      let bg =
        attention == .needsAction
        ? Self.tint(
          baseBg, toward: Theme.current.attention, fraction: Self.needsActionTintFraction)
        : baseBg
      let fg = isActive ? Theme.current.fg1 : Theme.current.fg0

      cmds.append(
        .rect(
          rowRect,
          color: bg,
          source: .sidebar
        ))

      if isActive {
        let stripe = CGRect(x: 0, y: tabY, width: 3, height: rowHeight)
          .intersection(visibleRect)
        cmds.append(
          .rect(
            stripe,
            color: Theme.current.blue,
            source: .sidebar
          ))
      }

      // Keep the label column at a constant x so title text doesn't shift
      // when the active-state stripe (rendered above) appears or disappears.
      let labelX: CGFloat = 12
      let exited = tab.status != .running
      let labelFg = exited ? Theme.current.dim0 : fg
      // Right-edge slot: status indicator and the hover-revealed close glyph
      // share one anchor x. The slot never moves between hover states, so
      // the title column doesn't have an "indented" gap when the X is
      // absent — the indicator simply sits where the X would be.
      let slotX = sidebarWidth - 18
      let indexText = "\(tab.position)"
      let indexX = labelX
      let titleX = labelX + 3 * cellWidth
      let titleMaxScalars = max(1, Int(floor((slotX - titleX - 4) / cellWidth)))
      // Info lines use the same right edge — title and info both end at the
      // single shared slot so widths don't drift line-to-line.
      let infoMaxScalars = titleMaxScalars
      let resolved = TabTitleResolver.resolve(
        tab.titleMetadata,
        fallbackPosition: tab.position,
        lastActivity: tab.lastOutputAt ?? tab.lastActivityAt,
        maxTitleScalars: titleMaxScalars,
        maxSubtitleScalars: infoMaxScalars
      )
      // Build the info-line stack before computing geometry. A notification
      // or pushed agent status occupies a slot that is NOT in
      // `resolved.infoLines`, so sizing the row from `infoLines` alone
      // undercounts the rendered lines and the surplus line drops below the
      // row edge into the next tab. Size off the stack that is actually drawn.
      let displayLines = Self.displayLines(for: tab, resolved: resolved)

      // Vertical layout: title + the info-line stack, centered inside the
      // fixed quad-height row. Centering keeps geometry stable across status
      // changes (a normally-running tab stays the same row height as an exited
      // one) while removing the empty bottom strip on tabs with fewer lines.
      let drawnLines = 1 + displayLines.count
      let edgePad: CGFloat = 4
      let stackHeight = CGFloat(drawnLines) * cellHeight
      let availableHeight = rowHeight - 2 * edgePad
      let yOffset = max(0, (availableHeight - stackHeight) / 2)
      let lineY: (Int) -> CGFloat = { idx in
        // idx 0 is the topmost (title); larger idx is lower on screen.
        tabY + edgePad + yOffset + CGFloat(drawnLines - 1 - idx) * cellHeight
      }
      let titleY = lineY(0)
      let appendGlyph:
        (
          _ origin: CGPoint, _ text: String, _ foreground: UInt32, _ background: UInt32
        ) -> Void = { origin, text, foreground, background in
          let cellRect = CGRect(
            x: origin.x, y: origin.y,
            width: CGFloat(max(1, text.count)) * cellWidth,
            height: cellHeight)
          guard visibleRect.contains(cellRect) else { return }
          cmds.append(
            .glyphRun(
              origin: origin,
              text: text,
              foreground: foreground,
              background: background,
              attributes: [],
              source: .sidebar
            ))
        }

      appendGlyph(CGPoint(x: indexX, y: titleY), indexText, Theme.current.dim0, bg)
      appendGlyph(CGPoint(x: titleX, y: titleY), resolved.displayTitle, labelFg, bg)

      // Right-edge attention marker — one per tab, chosen by attention level.
      // Rendered only when the tab is not hovered (the close X takes the slot
      // on hover) and never on the focused tab (always `.none`):
      //   needsAction → attention-accent ◆ over the row tint applied above
      //                  ("act here" — yellow, not red: red means failure)
      //   done        → accent ◆ ("ready at prompt" / turn finished)
      //   passive/none → an explicit OSC 21337 agent dot, else a failed-command
      //                  red dot, else a muted unseen/bell badge, else nothing
      //
      // The slot shows the close X iff the cursor is on this row AND it isn't
      // the drag source (drag suppresses the X to avoid an accidental
      // mid-gesture close); otherwise the slot belongs to the marker, including
      // while dragging (the drag overlay dims it with the rest of the row).
      let showCloseX = (hoveredTabId == tab.id) && !isDragging
      if !showCloseX && !isActive {
        let slot = CGPoint(x: slotX, y: titleY)
        switch attention {
        case .needsAction:
          // The one place that pulses. Emitted at full opacity and recorded
          // by index: the breathing alpha is applied by
          // `retintPulseMarkers(_:at:)` so memoized callers animate the dot
          // without rebuilding the sidebar. Reduce Motion shows exactly this
          // full-opacity form (still distinct by colour + shape).
          let markerIndex = cmds.count
          appendGlyph(slot, "◆", Theme.current.attention, bg)
          if markerIndex < cmds.count {
            pulseMarkers.append(PulseMarker(commandIndex: markerIndex, tabId: tab.id))
          }
        case .done:
          appendGlyph(slot, "◆", Theme.current.cursor, bg)
        case .passive, .none:
          if let hex = agentStatus.indicatorColor, let color = Self.parseHexColor(hex) {
            // An agent that explicitly pushed a colour (OSC 21337) owns the slot.
            appendGlyph(slot, "●", color, bg)
          } else if let shellColor = Self.shellPhaseIndicatorColor(meta) {
            // A failed last command: a steady red dot — it finished, it is not
            // waiting on the user, so it does not earn the needsAction pulse.
            appendGlyph(slot, "●", shellColor, bg)
          } else if let badge = resolved.statusBadge {
            // Low-salience activity: an exited-nonzero "!" stays red; bell/
            // unseen ("•"/"*") are muted so they inform without shouting.
            let color = badge == "!" ? Theme.current.red : Theme.current.dim0
            appendGlyph(slot, badge, color, bg)
          }
        }
      }

      // Render the info-line stack assembled above the layout block, each
      // line one cell below the previous. Status/notification slots already
      // took priority over folder/branch/command when the stack was built.
      for (offset, entry) in displayLines.enumerated() {
        appendGlyph(CGPoint(x: titleX, y: lineY(offset + 1)), entry.0, entry.1, bg)
      }

      // Close glyph: rendered only when this tab is hovered AND not the
      // active drag source, taking over the right-edge slot the indicator
      // otherwise owns. Heavy `✕` gives a beefier hit target than `×`
      // without needing a separate font size. Hit region is scoped to the
      // slot in hitTest. Drag suppression prevents an accidental close
      // when the user is already mid-gesture on the row.
      if showCloseX {
        appendGlyph(CGPoint(x: slotX, y: titleY), "✕", Theme.current.dim0, bg)
      }

      // Dim the row that the user is currently dragging so it reads as
      // "lifted". Drawn after the title text so it tints everything in
      // the row uniformly.
      if isDragging {
        let overlayRect = CGRect(x: 0, y: tabY, width: sidebarWidth, height: rowHeight)
          .intersection(visibleRect)
        cmds.append(
          .rect(
            overlayRect,
            color: Self.dragSourceOverlayColor,
            source: .sidebar
          ))
      }
    }

    // Drop-target accent. Drawn last so it sits on top of every row.
    // The slot range is `[0, tabs.count]`; a value equal to the dragging
    // index or `draggingIndex + 1` would re-insert the row in place, so
    // we suppress the bar to avoid a misleading drop hint.
    if let ind = dragIndicator,
      let accentY = dropAccentY(
        slot: ind.slot,
        tabCount: tabs.count,
        height: height,
        topInset: topInset,
        scrollOffset: scrollOffset,
        draggingIndex: draggingIndex
      )
    {
      let accentRect = CGRect(x: 0, y: accentY, width: sidebarWidth, height: 2)
        .intersection(visibleRect)
      if accentRect.isEmpty { return Output(commands: cmds, pulseMarkers: pulseMarkers) }
      cmds.append(
        .rect(
          accentRect,
          color: Theme.current.blue,
          source: .sidebar
        ))
    }

    return Output(commands: cmds, pulseMarkers: pulseMarkers)
  }

  public func maxScrollOffset(
    tabCount: Int,
    height: CGFloat,
    topInset: CGFloat = 0
  ) -> CGFloat {
    let visibleHeight = max(0, height - topInset)
    let contentHeight = CGFloat(max(0, tabCount)) * rowHeight
    return max(0, contentHeight - visibleHeight)
  }

  public func clampedScrollOffset(
    _ offset: CGFloat,
    tabCount: Int,
    height: CGFloat,
    topInset: CGFloat = 0
  ) -> CGFloat {
    min(max(0, offset), maxScrollOffset(tabCount: tabCount, height: height, topInset: topInset))
  }

  /// 0xRRGGBBAA — a low-alpha black overlay used to dim the row that the
  /// user is dragging. Tuned to read as "lifted" on both light and dark
  /// themes without losing the underlying label.
  private static let dragSourceOverlayColor: UInt32 = 0x0000_0066

  /// Fraction the needsAction row tint blends `bg` toward the attention colour.
  /// Faint enough to read as a wash behind the text, not a fill.
  static let needsActionTintFraction: Double = 0.14

  /// Blend `base` toward `accent` by `fraction` (0…1), preserving base's alpha.
  /// 0xRRGGBBAA in, 0xRRGGBBAA out. Used for the faint row wash behind a tab
  /// that needs the user's action.
  static func tint(_ base: UInt32, toward accent: UInt32, fraction: Double) -> UInt32 {
    let f = min(max(fraction, 0), 1)
    func channel(_ shift: UInt32) -> UInt32 {
      let b = Double((base >> shift) & 0xFF)
      let a = Double((accent >> shift) & 0xFF)
      return UInt32((b + (a - b) * f).rounded()) & 0xFF
    }
    return (channel(24) << 24) | (channel(16) << 16) | (channel(8) << 8) | (base & 0xFF)
  }

  /// Compute the y-position (CG bottom-origin) of the drop-target accent
  /// bar for `slot`. Returns nil when no accent should be drawn — either
  /// because the slot is out of range or because the drop would land the
  /// row in its existing position.
  private func dropAccentY(
    slot: Int,
    tabCount: Int,
    height: CGFloat,
    topInset: CGFloat,
    scrollOffset: CGFloat,
    draggingIndex: Int?
  ) -> CGFloat? {
    guard slot >= 0, slot <= tabCount else { return nil }
    if let dragIdx = draggingIndex, slot == dragIdx || slot == dragIdx + 1 {
      return nil
    }
    // Top of the row currently at index `slot` (or bottom of the last
    // row when `slot == tabCount`). Two pixels tall, centered on the
    // boundary, clamped to the visible column.
    let topOfSlot = height - CGFloat(slot) * rowHeight - topInset + scrollOffset
    return max(0, topOfSlot - 1)
  }

  /// Insertion index in `[0, tabs.count]` for a drag-and-drop release at
  /// `point` (CG coordinates, y=0 at bottom). Each row is split at its
  /// vertical midpoint: a release on the top half lands the dragged tab
  /// before that row, the bottom half lands it after. Above the first
  /// row → 0; below the last row → `tabs.count`. Returns nil only when
  /// `tabs` is empty, so callers always have a valid target while a
  /// drag is live.
  ///
  /// `point.x` is intentionally NOT bounded to the sidebar: a drag that
  /// strays out of the column still resolves to a slot, which matches
  /// the macOS convention that a drag is "owned" by the originating
  /// view until release.
  public func dropSlot(
    at point: CGPoint, tabs: [Tab], height: CGFloat, topInset: CGFloat = 0,
    scrollOffset: CGFloat = 0
  ) -> Int? {
    guard !tabs.isEmpty else { return nil }
    let scrollOffset = clampedScrollOffset(
      scrollOffset, tabCount: tabs.count, height: height, topInset: topInset)
    let firstTabTop = height - topInset + scrollOffset
    if point.y >= firstTabTop { return 0 }
    let lastTabBottom = firstTabTop - CGFloat(tabs.count) * rowHeight
    if point.y < lastTabBottom { return tabs.count }
    for i in tabs.indices {
      let tabTop = firstTabTop - CGFloat(i) * rowHeight
      let tabBottom = tabTop - rowHeight
      if point.y >= tabBottom, point.y < tabTop {
        let midpoint = tabBottom + rowHeight / 2
        return point.y >= midpoint ? i : i + 1
      }
    }
    return tabs.count
  }

  // CG coordinates (y=0 at bottom). The "+" button is a titlebar
  // accessory now — sidebar hits are exclusively tab select / close.
  public func hitTest(
    at point: CGPoint, tabs: [Tab], height: CGFloat, topInset: CGFloat = 0,
    scrollOffset: CGFloat = 0
  ) -> HitResult {
    guard point.x >= 0, point.x < sidebarWidth else { return .none }
    guard point.y >= 0, point.y < height - topInset else { return .none }
    let scrollOffset = clampedScrollOffset(
      scrollOffset, tabCount: tabs.count, height: height, topInset: topInset)

    for (i, tab) in tabs.enumerated() {
      let tabY = height - CGFloat(i + 1) * rowHeight - topInset + scrollOffset
      guard point.y >= tabY, point.y < tabY + rowHeight else { continue }
      // Close-X box covers the right-edge slot — the same slot the status
      // indicator occupies when not hovered. The hit target is anchored to
      // the rendered title baseline so it follows the X whether the tab is
      // sparsely populated (fresh) or has multiple info lines, and its left
      // edge lines up with the 4 pt gutter the renderer reserves past the
      // truncated title so it never overlaps rendered text. Clicks outside the
      // slot still select the tab.
      let layout = titleLayout(tab: tab, tabY: tabY)
      let closeBoxBottom = layout.baselineY - cellHeight / 2
      if point.x >= layout.closeBoxLeft, point.y >= closeBoxBottom {
        return .closeTab(tab.id)
      }
      return .selectTab(tab.id)
    }

    return .none
  }

  /// The indicator color for a tab's OSC 133 shell phase, or nil when no
  /// indicator should show. A non-zero last-command exit shows red; every
  /// other phase shows nothing so the sidebar stays quiet at rest.
  ///
  /// A merely *running* command deliberately shows nothing. OSC 133 pins the
  /// phase at `.running` for the whole lifetime of a foreground program, so a
  /// long-lived agent / REPL / editor would otherwise light a permanent dot on
  /// every tab — an always-on indicator that carries no signal. Only the
  /// failure case earns a dot.
  ///
  /// The red signal is gated on the exit code, NOT on `phase == .finished`:
  /// shells emit OSC 133 `D;<exit>` immediately followed by `A` in the same
  /// precmd, so the *settled* phase after a command is `.atPrompt`, never
  /// `.finished`. Gating on `.finished` would mean the failure dot is only
  /// "live" for the sub-millisecond between the two markers — i.e. never
  /// visible.
  static func shellPhaseIndicatorColor(_ meta: TabTitleMetadata) -> UInt32? {
    if let exit = meta.lastCommandExitCode, exit != 0 {
      return Theme.current.red
    }
    return nil
  }

  /// Builds the info-line stack that `output()` renders below the title.
  /// Kept separate from rendering so `hitTest()` can compute the same
  /// vertical geometry and keep the close target aligned with the glyph.
  private static func displayLines(
    for tab: Tab, resolved: ResolvedTabTitle
  ) -> [(String, UInt32)] {
    let meta = tab.titleMetadata
    let agentStatus = meta.agentStatus
    var displayLines: [(String, UInt32)] = []
    if let notif = meta.notification {
      // Keep it short and glanceable: the ◆ badge carries the signal, so the
      // line is just a short urgency label plus an unread count — not the
      // agent's full notification text (the native banner already has that).
      // "action" = blocked on approval/input; "ready" = turn finished.
      let label = notif.urgent ? "action" : "ready"
      let line = notif.count > 1 ? "\(label) ×\(notif.count)" : label
      displayLines.append((line, notif.urgent ? Theme.current.attention : Theme.current.cursor))
    }
    if let st = agentStatus.statusText {
      let color =
        agentStatus.statusTextColor.flatMap(Self.parseHexColor)
        ?? Theme.current.fg0
      displayLines.append((st, color))
    }
    if let progress = meta.progress {
      displayLines.append(Self.progressDisplayLine(progress))
    }
    for line in resolved.infoLines.prefix(max(0, 3 - displayLines.count)) {
      displayLines.append((line, Theme.current.dim0))
    }
    return displayLines
  }

  /// Title baseline Y and the left edge of the close hit box for a tab row,
  /// using the same layout as `output()`. The close box starts at the same
  /// 4 pt gutter the renderer reserves past the truncated title, so it never
  /// overlaps rendered text.
  private func titleLayout(tab: Tab, tabY: CGFloat) -> (baselineY: CGFloat, closeBoxLeft: CGFloat) {
    let labelX: CGFloat = 12
    let slotX = sidebarWidth - 18
    let titleX = labelX + 3 * cellWidth
    let titleMaxScalars = max(1, Int(floor((slotX - titleX - 4) / cellWidth)))
    let resolved = TabTitleResolver.resolve(
      tab.titleMetadata,
      fallbackPosition: tab.position,
      lastActivity: tab.lastOutputAt ?? tab.lastActivityAt,
      maxTitleScalars: titleMaxScalars,
      maxSubtitleScalars: titleMaxScalars
    )
    let displayLines = Self.displayLines(for: tab, resolved: resolved)
    let drawnLines = 1 + displayLines.count
    let edgePad: CGFloat = 4
    let stackHeight = CGFloat(drawnLines) * cellHeight
    let availableHeight = rowHeight - 2 * edgePad
    let yOffset = max(0, (availableHeight - stackHeight) / 2)
    let titleY = tabY + edgePad + yOffset + CGFloat(drawnLines - 1) * cellHeight
    let closeBoxLeft = titleX + CGFloat(titleMaxScalars) * cellWidth + 4
    return (titleY, closeBoxLeft)
  }

  /// Parse OSC 21337 color values into the 0xRRGGBBAA format the renderer
  /// expects. Accepts the iTerm-observed `#rrggbb` form and the X11/CSS
  /// `rgb:R/G/B` form (each channel 1–4 hex chars). Alpha is forced to
  /// fully opaque since the OSC spec doesn't carry alpha.
  /// Compact textual progress for the OSC 9;4 contract: a five-cell bar plus
  /// percent for determinate/error states (error renders red), a plain
  /// activity label for indeterminate.
  static func progressDisplayLine(_ progress: TabProgress) -> (String, UInt32) {
    switch progress.state {
    case .indeterminate:
      return ("working…", Theme.current.fg0)
    case .determinate, .error:
      let percent = max(0, min(progress.percent ?? 0, 100))
      let filled = Int((Double(percent) / 100.0 * 5.0).rounded())
      let bar =
        String(repeating: "▰", count: filled)
        + String(repeating: "▱", count: 5 - filled)
      let color = progress.state == .error ? Theme.current.red : Theme.current.fg0
      return ("\(bar) \(percent)%", color)
    }
  }

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
