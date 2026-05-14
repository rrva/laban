import AppKit
import LabanCore

final class TerminalFindChipView: NSView, NSSearchFieldDelegate {
  private static let positionDefaultsKey = "FindChipOriginFraction"

  let searchField = NSSearchField()
  private let counterLabel = NSTextField(labelWithString: "")
  private let previousButton = NSButton()
  private let nextButton = NSButton()
  private let closeButton = NSButton()
  private var dragStartInWindow: NSPoint?
  private var frameStart: NSRect = .zero

  var onNeedleChanged: ((String) -> Void)?
  var onStep: ((TerminalFindDirection) -> Void)?
  var onClose: (() -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = true
    wantsLayer = true
    layer?.cornerRadius = 6
    layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor
    layer?.borderColor = NSColor.separatorColor.cgColor
    layer?.borderWidth = 1

    searchField.placeholderString = "Find…"
    searchField.delegate = self
    searchField.controlSize = .small
    searchField.font = NSFont.systemFont(ofSize: 12)
    searchField.target = self
    searchField.action = #selector(searchAction(_:))
    searchField.translatesAutoresizingMaskIntoConstraints = false
    searchField.setAccessibilityRole(NSAccessibility.Role(rawValue: "AXSearchField"))
    searchField.setAccessibilityLabel("Find")

    counterLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    counterLabel.textColor = .secondaryLabelColor
    counterLabel.alignment = .center
    counterLabel.translatesAutoresizingMaskIntoConstraints = false

    configureButton(previousButton, symbol: "chevron.up", action: #selector(previous(_:)))
    previousButton.setAccessibilityLabel("Previous Match")
    configureButton(nextButton, symbol: "chevron.down", action: #selector(next(_:)))
    nextButton.setAccessibilityLabel("Next Match")
    configureButton(closeButton, symbol: "xmark", action: #selector(close(_:)))
    closeButton.setAccessibilityLabel("Close Find")

    let stack = NSStackView(views: [
      searchField, counterLabel, previousButton, nextButton, closeButton,
    ])
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 6
    stack.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 6)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
      searchField.widthAnchor.constraint(equalToConstant: 180),
      counterLabel.widthAnchor.constraint(equalToConstant: 44),
      previousButton.widthAnchor.constraint(equalToConstant: 22),
      previousButton.heightAnchor.constraint(equalToConstant: 22),
      nextButton.widthAnchor.constraint(equalToConstant: 22),
      nextButton.heightAnchor.constraint(equalToConstant: 22),
      closeButton.widthAnchor.constraint(equalToConstant: 22),
      closeButton.heightAnchor.constraint(equalToConstant: 22),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(with state: TerminalFindState, isSearching: Bool = false) {
    if searchField.stringValue != state.needle {
      searchField.stringValue = state.needle
    }
    if isSearching, !state.needle.isEmpty {
      counterLabel.stringValue = "..."
    } else if state.needle.isEmpty {
      counterLabel.stringValue = ""
    } else if let selected = state.selectedIndex, state.total > 0 {
      counterLabel.stringValue = "\(selected + 1)/\(state.total)"
    } else {
      counterLabel.stringValue = "0/0"
    }
    previousButton.isEnabled = state.total > 0
    nextButton.isEnabled = state.total > 0
    counterLabel.setAccessibilityValue(
      counterLabel.stringValue.replacingOccurrences(of: "/", with: " of "))
  }

  func focusAndSelectAll() {
    window?.makeFirstResponder(searchField)
    searchField.currentEditor()?.selectAll(nil)
  }

  static func defaultFrame(in terminalRect: NSRect, size: NSSize) -> NSRect {
    if let saved = savedOrigin(in: terminalRect, size: size) {
      return NSRect(origin: saved, size: size)
    }
    return NSRect(
      x: terminalRect.maxX - size.width - 8,
      y: terminalRect.maxY - size.height - 8,
      width: size.width,
      height: size.height
    )
  }

  override func mouseDown(with event: NSEvent) {
    dragStartInWindow = event.locationInWindow
    frameStart = frame
    super.mouseDown(with: event)
  }

  override func mouseDragged(with event: NSEvent) {
    guard let dragStartInWindow, let superview else {
      super.mouseDragged(with: event)
      return
    }
    let dx = event.locationInWindow.x - dragStartInWindow.x
    let dy = event.locationInWindow.y - dragStartInWindow.y
    var next = frameStart
    next.origin.x += dx
    next.origin.y += dy
    next.origin.x = min(max(0, next.origin.x), max(0, superview.bounds.width - next.width))
    next.origin.y = min(max(0, next.origin.y), max(0, superview.bounds.height - next.height))
    frame = next
    persistPosition()
  }

  private func configureButton(_ button: NSButton, symbol: String, action: Selector) {
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    button.target = self
    button.action = action
    button.bezelStyle = .texturedRounded
    button.isBordered = false
    button.translatesAutoresizingMaskIntoConstraints = false
  }

  @objc private func searchAction(_ sender: NSSearchField) {
    onNeedleChanged?(sender.stringValue)
  }

  func controlTextDidChange(_ obj: Notification) {
    onNeedleChanged?(searchField.stringValue)
  }

  func control(
    _ control: NSControl,
    textView: NSTextView,
    doCommandBy commandSelector: Selector
  ) -> Bool {
    switch commandSelector {
    case #selector(NSResponder.cancelOperation(_:)):
      onClose?()
      return true
    case #selector(NSResponder.insertNewline(_:)):
      onStep?(.next)
      return true
    case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
      onStep?(.previous)
      return true
    default:
      return false
    }
  }

  @objc private func previous(_ sender: Any?) {
    onStep?(.previous)
  }

  @objc private func next(_ sender: Any?) {
    onStep?(.next)
  }

  @objc private func close(_ sender: Any?) {
    onClose?()
  }

  private func persistPosition() {
    guard let superview else { return }
    let width = max(superview.bounds.width - frame.width, 1)
    let height = max(superview.bounds.height - frame.height, 1)
    let fx = min(max(frame.origin.x / width, 0), 1)
    let fy = min(max(frame.origin.y / height, 0), 1)
    UserDefaults.standard.set("\(fx),\(fy)", forKey: Self.positionDefaultsKey)
  }

  private static func savedOrigin(in bounds: NSRect, size: NSSize) -> NSPoint? {
    guard let raw = UserDefaults.standard.string(forKey: positionDefaultsKey) else { return nil }
    let parts = raw.split(separator: ",").compactMap { Double($0) }
    guard parts.count == 2 else { return nil }
    let width = max(bounds.width - size.width, 1)
    let height = max(bounds.height - size.height, 1)
    return NSPoint(
      x: bounds.minX + CGFloat(parts[0]) * width,
      y: bounds.minY + CGFloat(parts[1]) * height
    )
  }
}
