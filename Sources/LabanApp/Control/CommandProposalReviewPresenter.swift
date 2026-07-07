import AppKit
import LabanCore

/// Presents agent command proposals with C15 safe rendering (byte-exact escaped text;
/// copy == display; no PTY actuation).
final class CommandProposalReviewPresenter: CommandProposalReviewPresenting {
  static let shared = CommandProposalReviewPresenter()

  func present(proposal: CommandProposal) {
    DispatchQueue.main.async {
      self.presentOnMain(proposal: proposal)
    }
  }

  private func presentOnMain(proposal: CommandProposal) {
    let commandRendered = CommandProposalSafeText.render(proposal.command)
    let purposeRendered = proposal.purpose.map { CommandProposalSafeText.render($0) }

    let alert = NSAlert()
    alert.messageText = "Agent Command Proposal"
    alert.informativeText =
      "Review the exact command text below. Laban will not run it automatically."
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Copy Command")
    alert.addButton(withTitle: "Dismiss")

    let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 180))
    let scroll = NSScrollView(frame: accessory.bounds)
    scroll.autoresizingMask = [.width, .height]
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder

    let textView = NSTextView(frame: scroll.contentView.bounds)
    textView.isEditable = false
    textView.isSelectable = true
    textView.font = NSFont.monospacedSystemFont(
      ofSize: NSFont.smallSystemFontSize, weight: .regular)
    textView.textColor = .labelColor
    textView.backgroundColor = .textBackgroundColor
    textView.textContainerInset = NSSize(width: 8, height: 8)

    var body = "Command:\n\(commandRendered.displayText)"
    if let purposeRendered {
      body += "\n\nPurpose:\n\(purposeRendered.displayText)"
    }
    if commandRendered.truncated || purposeRendered?.truncated == true {
      body += "\n\n(Content truncated to safe display limit.)"
    }
    textView.string = body

    scroll.documentView = textView
    accessory.addSubview(scroll)
    alert.accessoryView = accessory

    let finish: (NSApplication.ModalResponse) -> Void = { response in
      switch response {
      case .alertFirstButtonReturn:
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commandRendered.copyText, forType: .string)
        CommandProposalStore.shared.updateState(id: proposal.id, state: .dismissed)
      default:
        CommandProposalStore.shared.updateState(id: proposal.id, state: .dismissed)
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
}

#if DEBUG
  /// Test hook exposing rendered strings without presenting AppKit sheets.
  enum CommandProposalReviewRendering {
    static func renderedCopyText(for proposal: CommandProposal) -> (
      command: CommandProposalSafeText,
      purpose: CommandProposalSafeText?
    ) {
      (
        CommandProposalSafeText.render(proposal.command),
        proposal.purpose.map { CommandProposalSafeText.render($0) }
      )
    }
  }
#endif
