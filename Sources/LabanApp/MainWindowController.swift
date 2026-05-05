import AppKit
import LabanCore
import LabanRenderer
import LabanTerminalCore

final class MainWindowController: NSWindowController {

  static func makeAndShow() throws -> MainWindowController {
    let fontAtlas = FontAtlas(pointSize: 14)
    let sidebarFontAtlas = FontAtlas(pointSize: 11)
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
      sidebarFontAtlas: sidebarFontAtlas,
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

    // "+" new-tab button as a titlebar accessory next to the traffic
    // lights. Frees a full row from the sidebar without sacrificing
    // discoverability — the button is always visible at a fixed screen
    // position regardless of how many tabs are open.
    let plusButton = NSButton(
      title: "+",
      target: nil,
      action: #selector(TerminalBitmapView.newTab(_:))
    )
    plusButton.bezelStyle = .smallSquare
    plusButton.isBordered = false
    plusButton.font = NSFont.systemFont(ofSize: 16, weight: .light)
    plusButton.contentTintColor = .secondaryLabelColor
    plusButton.translatesAutoresizingMaskIntoConstraints = false
    let accessoryHost = NSView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
    accessoryHost.addSubview(plusButton)
    NSLayoutConstraint.activate([
      plusButton.centerXAnchor.constraint(equalTo: accessoryHost.centerXAnchor),
      plusButton.centerYAnchor.constraint(equalTo: accessoryHost.centerYAnchor),
      plusButton.widthAnchor.constraint(equalToConstant: 24),
      plusButton.heightAnchor.constraint(equalToConstant: 24),
    ])
    let accessory = NSTitlebarAccessoryViewController()
    accessory.view = accessoryHost
    accessory.layoutAttribute = .leading
    window.addTitlebarAccessoryViewController(accessory)

    let controller = MainWindowController(window: window)
    return controller
  }
}
