import AppKit
import LabanControl
import LabanCore

final class ControlAttachApprovalPresenter: ControlAttachApprovalDelegate, @unchecked Sendable {
  static let shared = ControlAttachApprovalPresenter()

  /// The alert button titles this presenter would construct for `request`,
  /// in the order they are added to the alert (first button ==
  /// `alertFirstButtonReturn`). Factored out of `presentOnMain` so button
  /// presence/order is unit-testable without driving `NSAlert`/`NSApp`.
  static func buttonTitles(for request: ControlAttachApprovalRequest) -> [String] {
    var titles = ["Allow Once"]
    if request.canPersist {
      titles.append("Always Allow")
    }
    titles.append("Deny")
    return titles
  }

  func requestControlAttachApproval(
    _ request: ControlAttachApprovalRequest,
    completion: @escaping @Sendable (ControlAttachApprovalDecision) -> Void
  ) {
    DispatchQueue.main.async {
      self.presentOnMain(request: request, completion: completion)
    }
  }

  private func presentOnMain(
    request: ControlAttachApprovalRequest,
    completion: @escaping @Sendable (ControlAttachApprovalDecision) -> Void
  ) {
    let alert = NSAlert()
    // "Observe", not "control": every capability this dialog can grant is
    // read-only (read state/session, propose a command for review). It cannot
    // type, click, paste, or otherwise drive the terminal. Saying "control"
    // here misrepresents an observe-only permission as actuation.
    if request.principalIsVerified {
      alert.messageText = "Allow \(request.principalDisplayName) to observe this Laban session?"
      alert.informativeText = "A verified app is asking for one session-scoped read permission."
    } else {
      alert.messageText =
        "Allow unverified \(request.principalDisplayName) to observe this Laban session?"
      alert.informativeText =
        "Only allow this if you recognize the app and the path shown below."
    }
    alert.accessoryView = makeDetailsView(for: request)
    alert.alertStyle = .warning

    let canAlwaysAllow = request.canPersist
    for title in Self.buttonTitles(for: request) {
      alert.addButton(withTitle: title)
    }

    let finish: (NSApplication.ModalResponse) -> Void = { response in
      switch response {
      case .alertFirstButtonReturn:
        completion(.allowOnce)
      case .alertSecondButtonReturn:
        if canAlwaysAllow {
          completion(.alwaysAllowSignedIdentity)
        } else {
          completion(.deny)
        }
      default:
        completion(.deny)
      }
    }

    if let window = NSApp.keyWindow ?? NSApp.mainWindow {
      alert.beginSheetModal(for: window) { response in
        finish(response)
      }
    } else {
      finish(alert.runModal())
    }
  }

  /// The wording this alert's fixed-title rows a name (before Scope's dynamic
  /// suffix and the optional persistence-disabled note) render for `request`,
  /// in the order `makeDetailsView` arranges them. Factored out so the
  /// Data/Proposes/Not-included wording is unit-testable without driving
  /// `NSStackView`/`NSAlert` (mirrors `buttonTitles(for:)`).
  ///
  /// A family grant (`request.grantsSessionReadFamily`) describes the whole
  /// own-session read family, content-inclusive, names the propose grant
  /// (review NOTE 2), and adds a "Not included" row. A non-family (legacy,
  /// request-exact) grant keeps the single-sensitivity Data row unchanged and
  /// has no "Not included" row.
  static func detailRows(for request: ControlAttachApprovalRequest) -> [(String, String)] {
    var rows: [(String, String)] = [
      ("Operation", shortOperationSummary(request.operationSummary)),
      ("Session", request.sessionDisplay),
      ("Requester", request.principalDisplayName),
    ]
    if let path = request.principalPath, !path.isEmpty {
      rows.append(("Path", compactPath(path)))
    }
    rows.append(("Chain", request.helperChainSummary))
    if request.grantsSessionReadFamily {
      rows.append(
        (
          "Data",
          "This session's screen text, scrollback, and selection, "
            + "and may suggest commands for your review"
        ))
    } else {
      rows.append(("Data", readableDataSensitivity(request.dataSensitivity)))
    }
    if !request.capabilities.isEmpty {
      rows.append(("Permission", readableCapabilities(request.capabilities)))
    }
    rows.append(
      (
        "Scope",
        request.canPersist ? "This app in this Laban session" : "This request only"
      ))
    if request.grantsSessionReadFamily {
      rows.append(
        ("Not included", "No keyboard input, clipboard, tab switching, or other sessions."))
    }
    return rows
  }

  private func makeDetailsView(for request: ControlAttachApprovalRequest) -> NSView {
    let detailsWidth: CGFloat = 360
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .width
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = true
    stack.setFrameSize(NSSize(width: detailsWidth, height: 1))

    for (title, value) in Self.detailRows(for: request) {
      let monospaced = title == "Path"
      stack.addArrangedSubview(
        detailRow(
          title, value,
          tooltip: monospaced ? request.principalPath : nil,
          monospaced: monospaced,
          rowWidth: detailsWidth))
    }
    if !request.canPersist, let reason = request.persistenceDisabledReason {
      let note = NSTextField(wrappingLabelWithString: "Always Allow is unavailable: \(reason)")
      note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
      note.textColor = .secondaryLabelColor
      note.maximumNumberOfLines = 2
      note.translatesAutoresizingMaskIntoConstraints = false
      note.widthAnchor.constraint(equalToConstant: detailsWidth).isActive = true
      stack.addArrangedSubview(note)
    }

    stack.layoutSubtreeIfNeeded()
    stack.setFrameSize(NSSize(width: detailsWidth, height: ceil(stack.fittingSize.height)))
    return stack
  }

  private func detailRow(
    _ title: String,
    _ value: String,
    tooltip: String? = nil,
    monospaced: Bool = false,
    rowWidth: CGFloat
  ) -> NSView {
    let titleField = NSTextField(labelWithString: title)
    titleField.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
    titleField.textColor = .secondaryLabelColor
    titleField.alignment = .right
    titleField.setContentCompressionResistancePriority(.required, for: .horizontal)
    titleField.translatesAutoresizingMaskIntoConstraints = false

    let valueField =
      monospaced
      ? NSTextField(labelWithString: value)
      : NSTextField(wrappingLabelWithString: value)
    valueField.font =
      monospaced
      ? .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
      : .systemFont(ofSize: NSFont.systemFontSize)
    valueField.lineBreakMode = monospaced ? .byTruncatingMiddle : .byWordWrapping
    valueField.maximumNumberOfLines = monospaced ? 1 : 3
    valueField.toolTip = tooltip
    valueField.isSelectable = true
    valueField.translatesAutoresizingMaskIntoConstraints = false
    valueField.setContentHuggingPriority(.defaultLow, for: .horizontal)
    valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let row = NSStackView(views: [titleField, valueField])
    row.orientation = .horizontal
    row.alignment = .firstBaseline
    row.spacing = 10
    row.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      titleField.widthAnchor.constraint(equalToConstant: 76),
      row.widthAnchor.constraint(equalToConstant: rowWidth),
    ])
    return row
  }

  private static func shortOperationSummary(_ summary: String) -> String {
    let withoutParenthetical = summary.replacingOccurrences(
      of: #"\s*\([^)]*\)"#,
      with: "",
      options: .regularExpression)
    return withoutParenthetical.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
  }

  private static func compactPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == home {
      return "~"
    }
    if path.hasPrefix(home + "/") {
      return "~" + String(path.dropFirst(home.count))
    }
    return path
  }

  private static func readableDataSensitivity(_ raw: String) -> String {
    switch raw {
    case "none": return "None"
    case "nonSensitiveState": return "Basic app state"
    case "visibleText": return "Visible terminal text"
    case "scrollback": return "Scrollback"
    case "keystrokes": return "Keystrokes"
    case "clipboard": return "Clipboard"
    case "screenshot": return "Screenshot"
    case "trace": return "Trace data"
    case "sensitivePrivate": return "Private session data"
    default: return raw
    }
  }

  private static func readableCapabilities(_ capabilities: [String]) -> String {
    capabilities.map(readableCapability).joined(separator: ", ")
  }

  private static func readableCapability(_ raw: String) -> String {
    switch raw {
    case "observe": return "Read app state"
    case "observeSensitive": return "Read private session state"
    case "navigate": return "Navigate tabs and viewport"
    case "propose": return "Propose commands"
    case "input": return "Send input"
    case "fixture": return "Use fixture controls"
    default: return raw
    }
  }
}
