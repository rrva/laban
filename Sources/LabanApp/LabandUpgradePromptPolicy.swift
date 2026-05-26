import Foundation
import LabanCore

struct LabandUpgradePromptPresentation: Equatable {
  struct Action: Equatable {
    var identifier: LabandUpgradePromptDefaultChoice
    var title: String
  }

  var title: String
  var message: String
  var informativeText: String
  var actions: [Action]
  var defaultAction: LabandUpgradePromptDefaultChoice
}

enum LabandUpgradePromptPolicy {
  static func presentation(
    for decision: LabandLifecycleDecision
  ) -> LabandUpgradePromptPresentation? {
    guard case .promptBeforeUpgrade(let prompt) = decision else { return nil }
    let sessionDescription =
      prompt.liveSessions.count == 1
      ? "1 live terminal session"
      : "\(prompt.liveSessions.count) live terminal sessions"
    return LabandUpgradePromptPresentation(
      title: prompt.title,
      message: prompt.message,
      informativeText:
        "\(sessionDescription) will keep running if you continue with the current helper.",
      actions: [
        .init(identifier: .continueCurrentHelper, title: "Continue with Current Helper"),
        .init(identifier: .closeSessionsAndUpgrade, title: "Close Selected Sessions and Upgrade"),
      ],
      defaultAction: prompt.defaultChoice
    )
  }
}
