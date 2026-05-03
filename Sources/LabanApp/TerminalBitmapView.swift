import AppKit
import CoreGraphics
import LabanCore
import LabanRenderer
import LabanTerminalCore

final class TerminalBitmapView: NSView, NSTextInputClient {

  private let model: AppModel
  private let fontAtlas: FontAtlas
  private var surface: BitmapSurface
  private var renderer: SoftwareRenderer
  private let cellWidth: Int
  private let cellHeight: Int
  private let sidebarWidth: CGFloat = SidebarLayout.defaultWidth

  private var cachedCGImage: CGImage?
  private var frameTimer: Timer?

  // Last known terminal grid size (updated each frame)
  private var lastRows: Int = 24

  // Selection anchor/focus in terminal grid coordinates (row, col); row 0 = top
  private var selectionAnchor: (row: Int, col: Int)?
  private var selectionFocus: (row: Int, col: Int)?

  // Damage-driven render budget state
  private var renderInvalidated = true
  private var lastRenderedActiveTabId: Tab.ID?

  // IME composition buffer
  private var markedText: NSAttributedString = .init(string: "")

  // Tracks last surface dimensions to avoid redundant reallocations
  private var lastPixelWidth: Int = 0
  private var lastPixelHeight: Int = 0
  private var lastSurfaceScale: CGFloat = 0

  init(
    model: AppModel,
    fontAtlas: FontAtlas,
    cellWidth: Int,
    cellHeight: Int
  ) {
    self.model = model
    self.fontAtlas = fontAtlas
    self.cellWidth = cellWidth
    self.cellHeight = cellHeight
    let placeholder = BitmapSurface(width: 1, height: 1)
    self.surface = placeholder
    self.renderer = SoftwareRenderer(surface: placeholder, fontAtlas: fontAtlas)
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else {
      frameTimer?.invalidate()
      frameTimer = nil
      return
    }
    // Prevent duplicate timers when view transitions between windows
    if frameTimer == nil {
      recreateSurface()
      let timer = Timer(
        timeInterval: 1.0 / 30.0,
        target: self,
        selector: #selector(advanceFrame),
        userInfo: nil,
        repeats: true
      )
      RunLoop.current.add(timer, forMode: .common)
      frameTimer = timer
    } else {
      recreateSurface()
    }
    renderInvalidated = true
    window?.makeFirstResponder(self)
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    if recreateSurface() {
      renderInvalidated = true
    }
  }

  /// Returns true if the surface was actually recreated.
  @discardableResult
  private func recreateSurface() -> Bool {
    let scale = window?.backingScaleFactor ?? 1.0
    let pixW = max(1, Int(ceil(bounds.width * scale)))
    let pixH = max(1, Int(ceil(bounds.height * scale)))
    guard pixW != lastPixelWidth || pixH != lastPixelHeight || scale != lastSurfaceScale else {
      return false
    }
    lastPixelWidth = pixW
    lastPixelHeight = pixH
    lastSurfaceScale = scale
    surface = BitmapSurface(width: pixW, height: pixH, scale: scale)
    renderer = SoftwareRenderer(surface: surface, fontAtlas: fontAtlas)
    return true
  }

  private func invalidateFrame() {
    renderInvalidated = true
  }

  // MARK: - Frame loop

  @objc func advanceFrame() {
    for tab in model.tabs {
      model.session(forTab: tab.id)?.poll()
    }

    guard let activeTab = model.activeTab,
      let session = model.session(forTab: activeTab.id)
    else { return }

    let terminalDirty = session.renderDirty()
    let tabChanged = lastRenderedActiveTabId != activeTab.id

    // Return early when nothing changed
    guard terminalDirty || renderInvalidated || tabChanged else { return }

    guard let snap = session.snapshot() else { return }
    defer { laban_snapshot_destroy(snap) }

    lastRows = Int(snap.pointee.rows)
    let h = bounds.height

    var cmds: [FrameCommand] = []

    let sidebarProducer = SidebarProducer(
      sidebarWidth: sidebarWidth,
      cellWidth: CGFloat(cellWidth),
      cellHeight: CGFloat(cellHeight)
    )
    cmds += sidebarProducer.commands(tabs: model.tabs, activeTabId: activeTab.id, height: h)

    let termProducer = FrameProducer(
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      originX: sidebarWidth,
      originY: 0
    )
    cmds += termProducer.commands(from: UnsafePointer(snap))

    renderer.render(cmds)
    cachedCGImage = surface.cgImage
    needsDisplay = true

    session.markRendered()
    renderInvalidated = false
    lastRenderedActiveTabId = activeTab.id
  }

  // MARK: - Drawing

  override func draw(_ dirtyRect: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    guard let cgImg = cachedCGImage else {
      ctx.setFillColor(cgColorFrom(Theme.SelenizedLight.bg0))
      ctx.fill(bounds)
      return
    }
    ctx.saveGState()
    ctx.interpolationQuality = .none
    ctx.draw(cgImg, in: bounds)
    ctx.restoreGState()
  }

  // MARK: - Resize

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    let w = Int(newSize.width)
    let h = Int(newSize.height)
    guard w > 0, h > 0 else { return }
    if recreateSurface() {
      renderInvalidated = true
    }
    let termW = max(1, w - Int(sidebarWidth))
    model.resize(
      viewportWidth: termW, viewportHeight: h, cellWidth: cellWidth, cellHeight: cellHeight)
  }

  // MARK: - Responder

  override var acceptsFirstResponder: Bool { true }

  override func keyDown(with event: NSEvent) {
    if let chars = event.charactersIgnoringModifiers,
      let scalar = chars.unicodeScalars.first
    {
      let v = Int(scalar.value)
      if v >= 0xF700, v <= 0xF8FF {
        if let bytes = TerminalKeyEncoder.bytes(forFunctionKeyScalar: v) {
          sendBytes(bytes)
          return
        }
      }
    }
    if let bytes = TerminalKeyEncoder.bytes(
      forControlModifiedCharacters: event.characters,
      charactersIgnoringModifiers: event.charactersIgnoringModifiers,
      modifierFlags: event.modifierFlags)
    {
      sendBytes(bytes)
      return
    }
    if let bytes = TerminalKeyEncoder.bytes(
      forOptionMetaCharactersIgnoringModifiers: event.charactersIgnoringModifiers,
      modifierFlags: event.modifierFlags)
    {
      sendBytes(bytes)
      return
    }
    interpretKeyEvents([event])
  }

  // MARK: - NSTextInputClient

  func insertText(_ string: Any, replacementRange: NSRange) {
    let text: String
    if let s = string as? String {
      text = s
    } else if let a = string as? NSAttributedString {
      text = a.string
    } else {
      return
    }
    sendBytes(Array(text.utf8))
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    if let s = string as? String {
      markedText = NSAttributedString(string: s)
    } else if let a = string as? NSAttributedString {
      markedText = a
    }
  }

  func unmarkText() { markedText = NSAttributedString(string: "") }
  func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
  func markedRange() -> NSRange {
    markedText.length > 0
      ? NSRange(location: 0, length: markedText.length)
      : NSRange(location: NSNotFound, length: 0)
  }
  func hasMarkedText() -> Bool { markedText.length > 0 }
  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
    -> NSAttributedString?
  { nil }
  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { .zero }
  func characterIndex(for point: NSPoint) -> Int { NSNotFound }

  override func doCommand(by commandSelector: Selector) {
    switch commandSelector {
    case #selector(insertNewline(_:)): sendBytes([0x0D])
    case #selector(deleteBackward(_:)): sendBytes([0x7F])
    case #selector(cancelOperation(_:)): sendBytes([0x1B])
    case #selector(insertTab(_:)): sendBytes(TerminalKeyEncoder.tabBytes)
    case #selector(insertBacktab(_:)): sendBytes(TerminalKeyEncoder.backtabBytes)
    default: break
    }
  }

  private func sendBytes(_ bytes: [UInt8]) {
    guard let tabId = model.activeTab?.id else { return }
    model.session(forTab: tabId)?.write(bytes)
  }

  // MARK: - Clipboard

  @objc func copy(_ sender: Any?) {
    guard let activeTab = model.activeTab,
      let session = model.session(forTab: activeTab.id),
      let snap = session.snapshot(),
      let anchor = selectionAnchor,
      let focus = selectionFocus
    else { return }
    defer { laban_snapshot_destroy(snap) }

    let snapshot = snap.pointee
    let rows = Int(snapshot.rows)
    let cols = Int(snapshot.cols)
    guard rows > 0, cols > 0, let cells = snapshot.cells else { return }

    let minRow = max(0, min(anchor.row, focus.row))
    let maxRow = min(rows - 1, max(anchor.row, focus.row))
    let minCol = max(0, min(anchor.col, focus.col))
    let maxCol = min(cols - 1, max(anchor.col, focus.col))
    guard minRow <= maxRow else { return }

    var text = ""
    for row in minRow...maxRow {
      let colStart = row == minRow ? minCol : 0
      let colEnd = row == maxRow ? maxCol : cols - 1
      for col in colStart...colEnd {
        let cell = cells[row * cols + col]
        if cell.utf8_length > 0, let storage = snapshot.utf8_storage {
          let ptr = UnsafeRawPointer(storage).advanced(by: Int(cell.utf8_offset))
          let buf = UnsafeBufferPointer<UInt8>(
            start: ptr.assumingMemoryBound(to: UInt8.self),
            count: Int(cell.utf8_length)
          )
          text += String(bytes: buf, encoding: .utf8) ?? " "
        } else {
          text += " "
        }
      }
      if row < maxRow { text += "\n" }
    }

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  @objc func paste(_ sender: Any?) {
    guard let str = NSPasteboard.general.string(forType: .string) else { return }
    sendBytes(Array(str.utf8))
  }

  // MARK: - Mouse (selection + sidebar hits + mouse tracking)

  override func scrollWheel(with event: NSEvent) {
    guard
      let tabId = model.activeTab?.id,
      let session = model.session(forTab: tabId)
    else {
      return
    }

    let pt = convert(event.locationInWindow, from: nil)

    // Sidebar scrolls are consumed locally.
    guard pt.x >= sidebarWidth else { return }

    guard let vs = session.viewportState() else { return }

    // deltaY > 0 means scroll up (toward older history) in AppKit.
    let isUp = event.deltaY > 0

    if vs.mouseTracking {
      // Mouse tracking active: encode wheel as press+release.
      let button: MouseButton = isUp ? .wheelUp : .wheelDown
      let (cx, cy) = termCellFloat(at: pt)
      let me = MouseEvent(
        action: .press,
        button: button,
        x: cx, y: cy,
        screenWidth: Int(bounds.width),
        screenHeight: Int(bounds.height),
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        modifiers: event.labanModifiers
      )
      session.sendMouse(me)
      renderInvalidated = true
    } else {
      // Normal mode: scroll viewport.
      let direction: Int = isUp ? -1 : 1
      session.scrollViewport(deltaRows: direction)
      renderInvalidated = true
    }
  }

  override func mouseDown(with event: NSEvent) {
    let pt = convert(event.locationInWindow, from: nil)

    // Sidebar hit test.
    if pt.x < sidebarWidth {
      let sp = SidebarProducer(
        sidebarWidth: sidebarWidth,
        cellWidth: CGFloat(cellWidth),
        cellHeight: CGFloat(cellHeight)
      )
      switch sp.hitTest(at: pt, tabs: model.tabs, height: bounds.height) {
      case .newTab:
        _ = try? model.createTab()
        renderInvalidated = true
      case .selectTab(let id):
        model.selectTab(id)
        renderInvalidated = true
      case .closeTab(let id):
        _ = try? model.closeTab(id)
        renderInvalidated = true
      case .none: break
      }
      return
    }

    window?.makeFirstResponder(self)

    // Check if mouse tracking is active.
    if let tabId = model.activeTab?.id,
      let session = model.session(forTab: tabId),
      let vs = session.viewportState(),
      vs.mouseTracking
    {
      let (cx, cy) = termCellFloat(at: pt)
      let pressEvent = MouseEvent(
        action: .press,
        button: .left,
        x: cx, y: cy,
        screenWidth: Int(bounds.width),
        screenHeight: Int(bounds.height),
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        modifiers: event.labanModifiers
      )
      session.sendMouse(pressEvent)
      renderInvalidated = true
      return
    }

    // Fall back to selection.
    selectionAnchor = termCell(at: pt)
    selectionFocus = selectionAnchor
    renderInvalidated = true
  }

  override func mouseDragged(with event: NSEvent) {
    // If mouse tracking is active, send motion events.
    if let tabId = model.activeTab?.id,
      let session = model.session(forTab: tabId),
      let vs = session.viewportState(),
      vs.mouseTracking
    {
      let pt = convert(event.locationInWindow, from: nil)
      guard pt.x >= sidebarWidth else { return }
      let (cx, cy) = termCellFloat(at: pt)
      let motionEvent = MouseEvent(
        action: .motion,
        button: .none,
        x: cx, y: cy,
        screenWidth: Int(bounds.width),
        screenHeight: Int(bounds.height),
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        modifiers: event.labanModifiers
      )
      session.sendMouse(motionEvent)
      renderInvalidated = true
      return
    }
    selectionFocus = termCell(at: convert(event.locationInWindow, from: nil))
    renderInvalidated = true
  }

  override func mouseUp(with event: NSEvent) {
    // If mouse tracking is active, send release event.
    if let tabId = model.activeTab?.id,
      let session = model.session(forTab: tabId),
      let vs = session.viewportState(),
      vs.mouseTracking
    {
      let pt = convert(event.locationInWindow, from: nil)
      let (cx, cy) = termCellFloat(at: pt)
      let releaseEvent = MouseEvent(
        action: .release,
        button: .left,
        x: cx, y: cy,
        screenWidth: Int(bounds.width),
        screenHeight: Int(bounds.height),
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        modifiers: event.labanModifiers
      )
      session.sendMouse(releaseEvent)
      renderInvalidated = true
      return
    }
    selectionFocus = termCell(at: convert(event.locationInWindow, from: nil))
    renderInvalidated = true
  }

  override func rightMouseDown(with event: NSEvent) {
    let pt = convert(event.locationInWindow, from: nil)

    // Sidebar right-click is consumed locally.
    if pt.x < sidebarWidth {
      return
    }

    if let tabId = model.activeTab?.id,
      let session = model.session(forTab: tabId),
      let vs = session.viewportState(),
      vs.mouseTracking
    {
      let (cx, cy) = termCellFloat(at: pt)
      let pressEvent = MouseEvent(
        action: .press,
        button: .right,
        x: cx, y: cy,
        screenWidth: Int(bounds.width),
        screenHeight: Int(bounds.height),
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        modifiers: event.labanModifiers
      )
      session.sendMouse(pressEvent)
      renderInvalidated = true
    }
  }

  override func rightMouseUp(with event: NSEvent) {
    if let tabId = model.activeTab?.id,
      let session = model.session(forTab: tabId),
      let vs = session.viewportState(),
      vs.mouseTracking
    {
      let pt = convert(event.locationInWindow, from: nil)
      let (cx, cy) = termCellFloat(at: pt)
      let releaseEvent = MouseEvent(
        action: .release,
        button: .right,
        x: cx, y: cy,
        screenWidth: Int(bounds.width),
        screenHeight: Int(bounds.height),
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        modifiers: event.labanModifiers
      )
      session.sendMouse(releaseEvent)
      renderInvalidated = true
    }
  }

  // Convert a CG-coordinate view point to a terminal grid cell (row 0 = top).
  private func termCell(at pt: NSPoint) -> (row: Int, col: Int)? {
    let x = pt.x - sidebarWidth
    guard x >= 0 else { return nil }
    let col = Int(x / CGFloat(cellWidth))
    // CG y=0 at bottom; terminal row 0 is at y = (rows-1)*cellHeight
    let row = lastRows - 1 - Int(pt.y / CGFloat(cellHeight))
    guard row >= 0, row < lastRows, col >= 0 else { return nil }
    return (row, col)
  }

  // Convert a CG-coordinate view point to terminal grid float coordinates
  // (x, y) in cell units where (0, 0) is the top-left visible cell.
  private func termCellFloat(at pt: NSPoint) -> (Float, Float) {
    let fx = (pt.x - sidebarWidth) / CGFloat(cellWidth)
    // CG y=0 at bottom; terminal row 0 is at top
    let fy = (bounds.height - pt.y) / CGFloat(cellHeight)
    return (Float(max(0, fx)), Float(max(0, fy)))
  }

  // MARK: - Menu actions

  @objc func newTab(_ sender: Any?) {
    _ = try? model.createTab()
    renderInvalidated = true
  }

  @objc func closeTab(_ sender: Any?) {
    guard let tabId = model.activeTab?.id else { return }
    _ = try? model.closeTab(tabId)
    renderInvalidated = true
  }

  @objc func selectTabByIndex(_ sender: Any?) {
    guard let item = sender as? NSMenuItem else { return }
    let idx = item.tag - 1
    guard idx >= 0, idx < model.tabs.count else { return }
    model.selectTab(model.tabs[idx].id)
    renderInvalidated = true
  }
}

// MARK: - NSEvent modifier conversion for mouse events

extension NSEvent {
  /// Convert AppKit modifier flags to the terminal-expected bit mask.
  /// Bit 0 = Shift, Bit 1 = Meta (Option), Bit 2 = Ctrl, Bit 3 = Command (Super).
  fileprivate var labanModifiers: Int {
    var m = 0
    if modifierFlags.contains(.shift) { m |= 1 }
    if modifierFlags.contains(.option) { m |= 2 }
    if modifierFlags.contains(.control) { m |= 4 }
    if modifierFlags.contains(.command) { m |= 8 }
    return m
  }
}
