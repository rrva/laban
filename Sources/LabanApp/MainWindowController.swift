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
    let viewH: CGFloat = 760

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

    let mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: viewW, height: viewH),
      styleMask: mask,
      backing: .buffered,
      defer: false
    )
    window.title = "Laban"
    window.contentView = termView
    window.center()
    window.makeKeyAndOrderFront(nil)

    let controller = MainWindowController(window: window)
    return controller
  }
}
