import Darwin
import Foundation

/// When closing a pane, tab, or window, or quitting, asks before it kills a
/// running program. See `docs/product/spec.md` §28.
public enum CloseConfirmationMode: String, CaseIterable, Codable, Sendable {
  /// Ask only when an affected pane runs something other than a safe-listed
  /// program (a shell at its prompt, a multiplexer).
  case whenRunning
  case always
  case never
}

public enum CloseConfirmationSettings {
  public static let modeKey = "LabanCloseConfirmationMode"
  public static let safeListKey = "LabanCloseConfirmationSafeList"

  /// Programs that hold no state worth a prompt: the common shells, and the
  /// multiplexers whose sessions outlive the pane.
  public static let defaultSafeList = ["bash", "sh", "zsh", "fish", "nu", "tmux", "screen"]

  public static func mode(defaults: UserDefaults = .standard) -> CloseConfirmationMode {
    defaults.string(forKey: modeKey).flatMap(CloseConfirmationMode.init(rawValue:))
      ?? .whenRunning
  }

  public static func setMode(_ mode: CloseConfirmationMode, defaults: UserDefaults = .standard) {
    defaults.set(mode.rawValue, forKey: modeKey)
  }

  public static func safeList(defaults: UserDefaults = .standard) -> [String] {
    defaults.stringArray(forKey: safeListKey) ?? defaultSafeList
  }

  /// Stores the list trimmed and de-duplicated; an empty list is kept as
  /// empty (every program then counts as running).
  public static func setSafeList(_ names: [String], defaults: UserDefaults = .standard) {
    var seen = Set<String>()
    let cleaned = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && seen.insert($0).inserted }
    defaults.set(cleaned, forKey: safeListKey)
  }
}

/// The process group in the foreground of a session's terminal.
public struct ForegroundProcess: Equatable, Sendable {
  public var pid: Int32
  /// `argv`, or just the kernel process name when the arguments are unreadable.
  public var arguments: [String]

  public init(pid: Int32, arguments: [String]) {
    self.pid = pid
    self.arguments = arguments
  }

  /// The program name as the user typed it: argv[0]'s basename, without a
  /// login shell's leading dash. Version-named binaries (the native Claude
  /// Code install runs as `…/versions/2.1.3`) keep their argv[0] (`claude`).
  public var name: String {
    var base = URL(fileURLWithPath: arguments.first ?? "").lastPathComponent
    if base.hasPrefix("-") { base.removeFirst() }
    return base
  }
}

public enum ForegroundProcessProbe {
  /// The foreground process of the terminal whose session leader is
  /// `shellPid`, read from the kernel's view of that process (`e_tpgid`), so
  /// it works without the pty descriptor and therefore for every backend.
  /// Returns the shell itself when it owns the foreground, and nil when the
  /// shell is gone or unreadable.
  public static func foreground(ofShell shellPid: Int32) -> ForegroundProcess? {
    guard shellPid > 0, let shell = bsdInfo(shellPid) else { return nil }
    let tpgid = Int32(bitPattern: shell.e_tpgid)
    let leader = tpgid > 0 && tpgid != Int32(bitPattern: shell.pbi_pgid) ? tpgid : shellPid
    if let process = describe(leader) { return process }
    // The group leader of a pipeline can exit before its peers; the group is
    // still busy, so report it even without a readable name.
    return leader == shellPid ? nil : ForegroundProcess(pid: leader, arguments: [])
  }

  private static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
  }

  private static func describe(_ pid: Int32) -> ForegroundProcess? {
    let arguments = LibprocIntrospector().arguments(of: pid)
    if !arguments.isEmpty { return ForegroundProcess(pid: pid, arguments: arguments) }
    var name = [CChar](repeating: 0, count: 256)
    guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return nil }
    return ForegroundProcess(pid: pid, arguments: [String(cString: name)])
  }
}

/// Everything the policy needs to judge one pane, gathered at close time.
public struct PaneCloseInput: Equatable, Sendable {
  public var sessionId: Session.ID
  public var tabId: Tab.ID
  public var tabTitle: String
  public var exited: Bool
  /// The pane's own shell (its session leader), when known.
  public var shellPid: Int32?
  /// nil when the pane has no inspectable process (fixture sessions, a
  /// session whose shell pid is not known yet).
  public var foreground: ForegroundProcess?
  /// OSC 9;4 progress is showing for this pane.
  public var progressActive: Bool
  /// Pane metadata names a coding agent (agent status, OSC 21337 agent name).
  public var agentNamed: Bool

  public init(
    sessionId: Session.ID, tabId: Tab.ID, tabTitle: String, exited: Bool = false,
    shellPid: Int32? = nil, foreground: ForegroundProcess?, progressActive: Bool = false,
    agentNamed: Bool = false
  ) {
    self.sessionId = sessionId
    self.tabId = tabId
    self.tabTitle = tabTitle
    self.exited = exited
    self.shellPid = shellPid
    self.foreground = foreground
    self.progressActive = progressActive
    self.agentNamed = agentNamed
  }
}

public struct PaneCloseVerdict: Codable, Equatable, Sendable {
  /// Which signal decided the verdict.
  public enum Signal: String, Codable, Sendable {
    /// The foreground program is on the safe list.
    case safeList
    /// The foreground program is not on the safe list.
    case foregroundProcess
    /// The pane's process has exited.
    case exited
    /// No process could be inspected; treated as idle.
    case noProcessInfo
  }

  public enum AgentState: String, Codable, Sendable {
    /// Mid-turn: progress is showing.
    case working
    /// At its own input or awaiting the user.
    case waiting
  }

  public var sessionId: String
  public var tabId: String
  public var tabTitle: String
  public var busy: Bool
  public var signal: Signal
  /// The foreground program's name, when one was found.
  public var program: String?
  public var foregroundPid: Int?
  /// Set when the foreground program is a coding agent.
  public var agentState: AgentState?

  public init(
    sessionId: String, tabId: String, tabTitle: String, busy: Bool, signal: Signal,
    program: String? = nil, foregroundPid: Int? = nil, agentState: AgentState? = nil
  ) {
    self.sessionId = sessionId
    self.tabId = tabId
    self.tabTitle = tabTitle
    self.busy = busy
    self.signal = signal
    self.program = program
    self.foregroundPid = foregroundPid
    self.agentState = agentState
  }
}

/// What a close action affects.
public enum CloseConfirmationScope: String, Codable, Sendable {
  case pane
  case tab
  case window
  case quit
}

public struct CloseConfirmationDialog: Codable, Equatable, Sendable {
  public var messageText: String
  public var informativeText: String
  public var confirmButtonTitle: String
  /// The busy panes the dialog lists, in tab order.
  public var busyPanes: [PaneCloseVerdict]

  public init(
    messageText: String, informativeText: String, confirmButtonTitle: String,
    busyPanes: [PaneCloseVerdict]
  ) {
    self.messageText = messageText
    self.informativeText = informativeText
    self.confirmButtonTitle = confirmButtonTitle
    self.busyPanes = busyPanes
  }
}

public enum CloseConfirmation {
  /// Coding agents the dialog can name. Matched against argv[0] and, for
  /// script launches (`node …/claude`), argv[1].
  static let agentDisplayNames = [
    "claude": "Claude Code", "claude-code": "Claude Code", "codex": "Codex",
    "gemini": "Gemini CLI", "aider": "Aider", "opencode": "opencode",
  ]

  public static func evaluate(_ input: PaneCloseInput, safeList: [String]) -> PaneCloseVerdict {
    func verdict(
      busy: Bool, _ signal: PaneCloseVerdict.Signal, program: String? = nil,
      agentState: PaneCloseVerdict.AgentState? = nil
    ) -> PaneCloseVerdict {
      PaneCloseVerdict(
        sessionId: input.sessionId, tabId: input.tabId, tabTitle: input.tabTitle, busy: busy,
        signal: signal, program: program, foregroundPid: input.foreground.map { Int($0.pid) },
        agentState: agentState)
    }
    if input.exited { return verdict(busy: false, .exited) }
    guard let foreground = input.foreground else { return verdict(busy: false, .noProcessInfo) }
    let name = foreground.name
    // A shell is idle only as the pane's own shell at its prompt. Any other
    // shell process in the foreground is running something: a script
    // (`./deploy.sh`, `bash build.sh`), `sh -c …`, or a subshell.
    let isOtherShell =
      shellNames.contains(name) && input.shellPid.map { $0 != foreground.pid } ?? false
    if !name.isEmpty, safeList.contains(name), !isOtherShell {
      return verdict(busy: false, .safeList, program: name)
    }
    if isOtherShell {
      return verdict(busy: true, .foregroundProcess, program: shellJobName(foreground))
    }
    if let agent = agentName(foreground) {
      return verdict(
        busy: true, .foregroundProcess, program: agent,
        agentState: input.progressActive ? .working : .waiting)
    }
    let agentState: PaneCloseVerdict.AgentState? =
      input.agentNamed ? (input.progressActive ? .working : .waiting) : nil
    return verdict(
      busy: true, .foregroundProcess, program: name.isEmpty ? nil : name, agentState: agentState)
  }

  /// Shells: on the safe list they stand for "at the prompt", which holds only
  /// for the pane's own shell process.
  static let shellNames: Set<String> = [
    "bash", "sh", "zsh", "fish", "nu", "dash", "ksh", "mksh", "tcsh", "csh", "elvish", "xonsh",
    "pwsh",
  ]

  /// Names a shell job by its script (`bash deploy.sh` → `deploy.sh`), or by
  /// the shell when it runs inline code or is interactive.
  static func shellJobName(_ process: ForegroundProcess) -> String {
    if process.arguments.count > 1, !process.arguments[1].hasPrefix("-") {
      return URL(fileURLWithPath: process.arguments[1]).lastPathComponent
    }
    return process.name
  }

  static func agentName(_ process: ForegroundProcess) -> String? {
    for argument in process.arguments.prefix(2) {
      let base = URL(fileURLWithPath: argument).lastPathComponent.lowercased()
      if let display = agentDisplayNames[base] { return display }
    }
    return nil
  }

  /// The dialog for closing panes judged by `verdicts`, or nil when the close
  /// should proceed without asking. Every sentence is one of the English
  /// format keys below, passed through `localize` (the app's string catalog;
  /// identity for debug output).
  public static func dialog(
    scope: CloseConfirmationScope, verdicts: [PaneCloseVerdict], mode: CloseConfirmationMode,
    localize: (String) -> String = { $0 }
  ) -> CloseConfirmationDialog? {
    let busy = verdicts.filter(\.busy)
    switch mode {
    case .never: return nil
    case .whenRunning where busy.isEmpty: return nil
    default: break
    }
    func program(_ pane: PaneCloseVerdict) -> String {
      pane.program ?? localize("A program")
    }
    let informative: String
    if busy.isEmpty {
      informative = localize("The terminal session will end.")
    } else if busy.count == 1, let only = busy.first {
      let format =
        only.agentState == .working
        ? localize("%@ is working and will be interrupted.")
        : localize("%@ is running and will be ended.")
      informative = String(format: format, program(only))
    } else {
      let lines = busy.map { pane in
        let format =
          pane.agentState == .working
          ? localize("%1$@ (working) in “%2$@”") : localize("%1$@ in “%2$@”")
        return "• " + String(format: format, program(pane), pane.tabTitle)
      }
      informative = ([localize("These programs will be ended:")] + lines)
        .joined(separator: "\n")
    }
    return CloseConfirmationDialog(
      messageText: localize(question(scope)),
      informativeText: informative,
      confirmButtonTitle: localize(confirmTitle(scope)),
      busyPanes: busy)
  }

  private static func question(_ scope: CloseConfirmationScope) -> String {
    switch scope {
    case .pane: return "Close this pane?"
    case .tab: return "Close this tab?"
    case .window: return "Close this window?"
    case .quit: return "Quit Laban?"
    }
  }

  private static func confirmTitle(_ scope: CloseConfirmationScope) -> String {
    switch scope {
    case .pane: return "Close Pane"
    case .tab: return "Close Tab"
    case .window: return "Close Window"
    case .quit: return "Quit"
    }
  }

  /// Gathers the inputs for `sessionIds` from the model. `shellPid` resolves a
  /// session's shell pid (backend-specific); `probe` reads its foreground
  /// process, injectable for tests.
  public static func verdicts(
    for sessionIds: [Session.ID],
    model: AppModel,
    safeList: [String],
    shellPid: (Session.ID) -> Int32?,
    probe: (Int32) -> ForegroundProcess? = ForegroundProcessProbe.foreground(ofShell:)
  ) -> [PaneCloseVerdict] {
    sessionIds.compactMap { id in
      guard let pane = model.tabProjection(forSession: id) else { return nil }
      let metadata = pane.titleMetadata
      let exited: Bool
      switch pane.status {
      case .exited, .exitedSignal: exited = true
      default: exited = false
      }
      let pid = exited ? nil : shellPid(id)
      let input = PaneCloseInput(
        sessionId: id,
        tabId: pane.id,
        tabTitle: metadata.userTitle ?? metadata.displayTitle,
        exited: exited,
        shellPid: pid,
        foreground: pid.flatMap(probe),
        progressActive: metadata.progress.map { $0.state != .error } ?? false,
        agentNamed: metadata.agent.agentName != nil)
      return evaluate(input, safeList: safeList)
    }
  }

  /// The shell pid for `sessionId` from what the model and a daemon backend
  /// know: the daemon's session info first, then the in-process session.
  public static func shellPid(
    for sessionId: Session.ID, model: AppModel,
    clientInfo: [Session.ID: LabandSessionInfo] = [:]
  ) -> Int32? {
    if let pid = clientInfo[sessionId]?.childPid, pid > 0 { return Int32(pid) }
    if let pid = model.session(forSessionID: sessionId)?.processMetadata()?.childPid, pid > 0 {
      return Int32(pid)
    }
    return nil
  }
}

/// What the serving runtime knows about its sessions' processes.
public struct CloseConfirmationEnvironment {
  /// Resolves a session's shell pid for its backend.
  public var shellPid: (Session.ID) -> Int32?
  /// True when quitting detaches sessions that the next launch restores, so
  /// closing the window or quitting ends no program.
  public var sessionsSurviveQuit: Bool
  public var defaults: UserDefaults
  public var probe: (Int32) -> ForegroundProcess?

  public init(
    shellPid: @escaping (Session.ID) -> Int32?,
    sessionsSurviveQuit: Bool,
    defaults: UserDefaults = .standard,
    probe: @escaping (Int32) -> ForegroundProcess? = ForegroundProcessProbe.foreground(ofShell:)
  ) {
    self.shellPid = shellPid
    self.sessionsSurviveQuit = sessionsSurviveQuit
    self.defaults = defaults
    self.probe = probe
  }

  /// Daemon sessions outlive the app only when the next launch restores
  /// them; otherwise quitting orphans them like a close.
  public static func sessionsSurviveQuit(
    backend: TerminalSessionBackend, restoreOnLaunch: Bool = RestoreOnLaunchSettings.isEnabled
  ) -> Bool {
    backend != .inProcess && restoreOnLaunch
  }
}

/// The full close-confirmation decision for one close action: what the
/// `closeConfirmation.state` query reports and what the app acts on.
public struct CloseConfirmationDecision: Encodable {
  public var scope: CloseConfirmationScope
  public var mode: CloseConfirmationMode
  public var safeList: [String]
  public var sessionsSurviveQuit: Bool
  /// True when the close would show `dialog` before proceeding.
  public var asks: Bool
  public var panes: [PaneCloseVerdict]
  public var dialog: CloseConfirmationDialog?
}

extension CloseConfirmation {
  /// Decides the close of `sessionIds` under the user's settings. Closing the
  /// window or quitting asks nothing when the sessions survive quit.
  public static func decide(
    scope: CloseConfirmationScope,
    sessionIds: [Session.ID],
    model: AppModel,
    environment: CloseConfirmationEnvironment,
    localize: (String) -> String = { $0 }
  ) -> CloseConfirmationDecision {
    let mode = CloseConfirmationSettings.mode(defaults: environment.defaults)
    let safeList = CloseConfirmationSettings.safeList(defaults: environment.defaults)
    let survives = environment.sessionsSurviveQuit && (scope == .window || scope == .quit)
    let panes = verdicts(
      for: sessionIds, model: model, safeList: safeList, shellPid: environment.shellPid,
      probe: environment.probe)
    let dialog =
      survives ? nil : self.dialog(scope: scope, verdicts: panes, mode: mode, localize: localize)
    return CloseConfirmationDecision(
      scope: scope, mode: mode, safeList: safeList,
      sessionsSurviveQuit: environment.sessionsSurviveQuit, asks: dialog != nil, panes: panes,
      dialog: dialog)
  }
}
