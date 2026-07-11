import LabanCore

/// The own-session read family: the exact set of intents a dialog-first
/// approval can grant for the approved session, per
/// `execplans/active/dialog-first-session-observe.md` (Definitions,
/// Design/Server Milestone 1). Defined once here so the lazy-attach
/// allowlist, the policy layer, and tests all share the same set.
///
/// This is a strict subset of what the broker `sessionObserve` credential
/// grants (review NOTE 4): `sessionObserve` also grants `app.accessibility`,
/// `terminal.modes`, and `session.list`, which this family deliberately
/// omits. Nothing new is exposed by this family; only the approval path to a
/// narrower set changes.
public enum ControlSessionObserveFamily {
  /// The exact family intent set. Do not add or drop members without
  /// revisiting the Threat Model in the ExecPlan above.
  public static let intentIDs: Set<String> = [
    "terminal.getText",
    "session.detail",
    "selection.read",
    "find.state",
    "shellIntegration.state",
    "scrollIndicator.state",
    "app.state",
    "terminal.scrollViewport",
    "command.propose",
    "commandProposal.list",
    "commandProposal.get",
    "commandProposal.cancel",
  ]

  /// The capability ceiling for the family: never `.input`, `.clipboard`, or
  /// `.fixture` (Threat Model lock (a)).
  public static let capabilities: Set<Capability> = [
    .observe, .observeSensitive, .navigate, .propose,
  ]

  public static func contains(_ intentID: String) -> Bool {
    intentIDs.contains(intentID)
  }
}
