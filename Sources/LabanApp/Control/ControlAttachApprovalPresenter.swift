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
      alert.messageText = "Allow \"\(request.principalDisplayName)\" to control Laban?"
    } else {
      alert.messageText =
        "Allow the unverified app \"\(request.principalDisplayName)\" to control Laban?"
    }
    alert.informativeText = formatInformativeText(for: request)
    alert.alertStyle = .warning

    alert.addButton(withTitle: "Allow Once")
    let alwaysAllowButton: NSButton? =
      request.canPersist
      ? alert.addButton(withTitle: "Always Allow This App for This Session") : nil
    alert.addButton(withTitle: "Deny")

    if !request.canPersist, let reason = request.persistenceDisabledReason {
      alert.suppressionButton?.title = reason
      alert.showsSuppressionButton = true
    }

    let finish: (NSApplication.ModalResponse) -> Void = { response in
      switch response {
      case .alertFirstButtonReturn:
        completion(.allowOnce)
      case .alertSecondButtonReturn:
        if let alwaysAllowButton {
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

  private func formatInformativeText(for request: ControlAttachApprovalRequest) -> String {
    var lines: [String] = []
    if request.principalIsVerified {
      lines.append("A verified app wants to use Laban on your behalf.")
    } else {
      lines.append(
        "An unverified, unsigned, or generic interpreter wants to use Laban on your behalf.")
      lines.append("Verify the path below before approving.")
    }
    lines.append("")
    lines.append("Operation: \(request.operationSummary)")
    lines.append("Session: \(request.sessionDisplay)")
    if let path = request.principalPath, !path.isEmpty {
      lines.append("Path: \(path)")
    } else if !request.principalDisplayName.isEmpty {
      lines.append("Process: \(request.principalDisplayName)")
    }
    lines.append("Chain: \(request.helperChainSummary)")
    lines.append("Data sensitivity: \(request.dataSensitivity)")
    if !request.capabilities.isEmpty {
      lines.append("Capabilities: \(request.capabilities.joined(separator: ", "))")
    }
    if !request.canPersist, let reason = request.persistenceDisabledReason {
      lines.append("")
      lines.append("Always Allow is disabled: \(reason)")
    }
    return lines.joined(separator: "\n")
  }
}
