import AppKit
import LabanControl
import LabanCore

final class ControlAttachApprovalPresenter: ControlAttachApprovalDelegate, @unchecked Sendable {
  static let shared = ControlAttachApprovalPresenter()

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
    if request.principalIsVerified {
      alert.messageText = "Allow \(request.principalDisplayName) to control Laban?"
      alert.informativeText = "A verified app is asking for one session-scoped permission."
    } else {
      alert.messageText = "Allow unverified \(request.principalDisplayName) to control Laban?"
      alert.informativeText =
        "Only allow this if you recognize the app and the path shown below."
    }
    alert.accessoryView = makeDetailsView(for: request)
    alert.alertStyle = .warning

    alert.addButton(withTitle: "Allow Once")
    let canAlwaysAllow = request.canPersist
    if canAlwaysAllow {
      alert.addButton(withTitle: "Always Allow")
    }
    alert.addButton(withTitle: "Deny")

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

  private func makeDetailsView(for request: ControlAttachApprovalRequest) -> NSView {
    let detailsWidth: CGFloat = 360
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .width
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = true
    stack.setFrameSize(NSSize(width: detailsWidth, height: 1))

    stack.addArrangedSubview(
      detailRow(
        "Operation", shortOperationSummary(request.operationSummary), rowWidth: detailsWidth)
    )
    stack.addArrangedSubview(detailRow("Session", request.sessionDisplay, rowWidth: detailsWidth))
    stack.addArrangedSubview(
      detailRow("Requester", request.principalDisplayName, rowWidth: detailsWidth))
    if let path = request.principalPath, !path.isEmpty {
      stack.addArrangedSubview(
        detailRow(
          "Path", compactPath(path), tooltip: path, monospaced: true, rowWidth: detailsWidth)
      )
    }
    stack.addArrangedSubview(detailRow("Chain", request.helperChainSummary, rowWidth: detailsWidth))
    stack.addArrangedSubview(
      detailRow("Data", readableDataSensitivity(request.dataSensitivity), rowWidth: detailsWidth)
    )
    if !request.capabilities.isEmpty {
      stack.addArrangedSubview(
        detailRow("Permission", readableCapabilities(request.capabilities), rowWidth: detailsWidth)
      )
    }
    stack.addArrangedSubview(
      detailRow(
        "Scope",
        request.canPersist ? "This app in this Laban session" : "This request only",
        rowWidth: detailsWidth
      )
    )
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

  private func shortOperationSummary(_ summary: String) -> String {
    let withoutParenthetical = summary.replacingOccurrences(
      of: #"\s*\([^)]*\)"#,
      with: "",
      options: .regularExpression)
    return withoutParenthetical.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
  }

  private func compactPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == home {
      return "~"
    }
    if path.hasPrefix(home + "/") {
      return "~" + String(path.dropFirst(home.count))
    }
    return path
  }

  private func readableDataSensitivity(_ raw: String) -> String {
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

  private func readableCapabilities(_ capabilities: [String]) -> String {
    capabilities.map(readableCapability).joined(separator: ", ")
  }

  private func readableCapability(_ raw: String) -> String {
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
