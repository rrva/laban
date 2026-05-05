import AppKit
import LabanCore
import LabanRenderer
import LabanTerminalCore

final class MainWindowController: NSWindowController {

  static func makeAndShow() throws -> MainWindowController {
    let fontAtlas = FontAtlas(pointSize: 14)
    let cellSize = fontAtlas.cellSize
    let cellW = Int(cellSize.width)
    let cellH = Int(cellSize.height)

    let sidebarWidth = SidebarLayout.defaultWidth
    let insets = TerminalBitmapView.contentInsets
    let viewW: CGFloat = 1200
    // Bumped by `titlebarReservedHeight` so the terminal grid keeps roughly
    // the same default row count after the transparent-titlebar change ate
    // 28 pt of top padding.
    let viewH: CGFloat = 760 + TerminalBitmapView.titlebarReservedHeight

    let termW = max(1, Int(viewW - sidebarWidth - insets.left - insets.right))
    let termH = max(1, Int(viewH - insets.top - insets.bottom))
    var size = LabanTerminalSize()
    size.rows = Int32(termH / cellH)
    size.cols = Int32(termW / cellW)

    let model = try AppModel(
      initialSize: size,
      sessionFactory: Session.realShell
    )

    let termView = TerminalBitmapView(
      model: model,
      fontAtlas: fontAtlas,
      cellWidth: cellW,
      cellHeight: cellH
    )
    termView.frame = NSRect(x: 0, y: 0, width: viewW, height: viewH)

    let mask: NSWindow.StyleMask = [
      .titled, .closable, .miniaturizable, .resizable, .fullSizeContentView,
    ]
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: viewW, height: viewH),
      styleMask: mask,
      backing: .buffered,
      defer: false
    )
    window.title = "Laban"
    // Transparent titlebar with the contentView extending behind it; the
    // sidebar and terminal-area background rects fill the reserved strip so
    // the chrome looks continuous with the terminal. Traffic lights stay
    // interactive because AppKit composites them over the contentView.
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.contentView = termView
    window.center()
    window.makeKeyAndOrderFront(nil)

    let controller = MainWindowController(window: window)
    return controller
  }
}
