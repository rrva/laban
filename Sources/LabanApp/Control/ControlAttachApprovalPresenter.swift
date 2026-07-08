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
    alert.messageText = "Allow \"\(request.principalDisplayName)\" to control Laban?"
    alert.informativeText = formatInformativeText(for: request)
    alert.alertStyle = .warning

    let allowOnceButton = alert.addButton(withTitle: "Allow Once")
    let alwaysAllowButton: NSButton? =
      request.canPersist ? alert.addButton(withTitle: "Always Allow This App for This Session") : nil
    let denyButton = alert.addButton(withTitle: "Deny")

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
    lines.append("An app wants to use Laban on your behalf.")
    lines.append("")
    lines.append("Operation: \(request.operationSummary)")
    lines.append("Session: \(request.sessionDisplay)")
    if let path = request.principalPath, !path.isEmpty {
      lines.append("Path: \(path)")
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
