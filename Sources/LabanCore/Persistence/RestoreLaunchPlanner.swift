import Darwin
import Foundation

/// Decides what (if anything) Laban should feed into a restored tab's
/// PTY right after the shell starts. Three outcomes only:
///
///   - `.executeNow(command)` — write the bytes followed by a newline
///     so the shell runs the command immediately. Used ONLY when the
///     tab carries a captured agent session id AND
///     `agent.wasRunningAtQuit == true`. The non-destructive action
///     of `claude --resume <id>` / `codex resume <id>` is the only
///     thing we auto-execute.
///   - `.prefillPrompt(command)` — write the bytes WITHOUT a
///     trailing newline. The user sees the resume command sitting at
///     the shell prompt and presses ENTER to run it. Used when the
///     tab has a captured agent session id but the agent was no
///     longer running at quit (the user had Ctrl-D'd it earlier).
///   - `.noPrefill` — do nothing; the fresh shell prompt is the
///     final state. Used for every non-agent tab and for agent tabs
///     where detection never fired. Persisted `launchCommand` is
///     historical metadata only; restore must not treat it as a
///     generic command-resume mechanism.
///
/// The decision reads `agent.wasRunningAtQuit`, NOT `processStatus`.
/// `processStatus` tracks the *shell* — always alive while the tab is
/// open — not the agent grandchild. Using shell processStatus would
/// silently auto-resume long-dead Claude conversations, which is
/// wrong.
public enum RestoreLaunchInstruction: Equatable {
  case executeNow(command: String)
  case prefillPrompt(command: String)
  case noPrefill
}

public protocol RestoreSessionActivityChecking {
  func isAgentSessionLive(for tab: TabState) -> Bool
}

public struct ProcessTreeRestoreSessionActivityChecker: RestoreSessionActivityChecking {
  private let introspector: any ProcessIntrospector

  public init(introspector: any ProcessIntrospector = LibprocIntrospector()) {
    self.introspector = introspector
  }

  public func isAgentSessionLive(for tab: TabState) -> Bool {
    guard let shellPid = tab.shellPid, shellPid > 0,
      let persistedAgent = tab.agent
    else { return false }

    let detector = AgentSessionDetector(
      tabId: tab.id,
      shellPid: pid_t(shellPid),
      introspector: introspector)
    guard let liveAgent = detector.detectLiveAgentDescendant() else { return false }
    return liveAgent.name == persistedAgent.name
      && liveAgent.sessionId == persistedAgent.sessionId
  }
}

public enum RestoreLaunchPlanner {

  public static func instruction(
    for tab: TabState,
    activityChecker: (any RestoreSessionActivityChecking)? = nil
  ) -> RestoreLaunchInstruction {
    guard let agent = tab.agent else { return .noPrefill }
    guard let support = AgentRegistry.entry(for: agent.name) else { return .noPrefill }
    let context = AgentLaunchContext(
      cwd: agent.cwd ?? tab.cwd,
      argv: agent.argv ?? [],
      env: agent.env ?? [:])
    let command = support.resumeCommand(sessionId: agent.sessionId, context: context)
    if activityChecker?.isAgentSessionLive(for: tab) == true {
      return .noPrefill
    }
    return agent.wasRunningAtQuit
      ? .executeNow(command: command)
      : .prefillPrompt(command: command)
  }

  /// Convenience for the restore factory, which holds a
  /// `RestoredSessionSpec` rather than the full `TabState`. The spec
  /// forwards the only fields the planner reads (`agent`, `shellPid`,
  /// `cwd`, `tabId`); the others are immaterial to the decision.
  public static func instruction(
    for spec: RestoredSessionSpec,
    activityChecker: (any RestoreSessionActivityChecking)? = nil
  ) -> RestoreLaunchInstruction {
    guard let agent = spec.agent else { return .noPrefill }
    let tab = TabState(
      id: spec.tabId,
      cwd: spec.cwd,
      launchCommand: "",
      lastActiveAt: Date(),
      shellPid: spec.shellPid,
      agent: agent)
    return instruction(for: tab, activityChecker: activityChecker)
  }
}
