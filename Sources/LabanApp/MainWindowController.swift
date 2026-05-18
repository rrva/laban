import AppKit
import LabanCore
import LabanRenderer
import LabanTerminalCore

final class MainWindowController: NSWindowController {
  /// The persistence coordinator owns its weak ref to the AppModel and
  /// debounces saves on a background queue. Kept on the window
  /// controller so AppDelegate can call `flushSync()` in
  /// `applicationWillTerminate` without having to walk back to the
  /// model.
  private(set) var persistenceCoordinator: PersistenceCoordinator?
  private(set) var model: AppModel?
  /// Per-tab agent-session detector + JSONL mirror orchestrator. Kept
  /// alive on the window controller so the detector timers don't
  /// stop when AppDelegate's local refs go out of scope.
  private(set) var agentObserverHost: AgentObserverHost?

  static func makeAndShow(restoring restoredState: WorkspaceState? = nil) throws
    -> MainWindowController
  {
    let fontAtlas = FontAtlas(pointSize: 14)
    let sidebarFontAtlas = FontAtlas(pointSize: 11)
    let cellSize = fontAtlas.cellSize
    let cellW = Int(cellSize.width)
    let cellH = Int(cellSize.height)

    let sidebarWidth = SidebarLayout.defaultWidth
    let insets = TerminalBitmapView.contentInsets
    let viewW: CGFloat = 1200
    // Bumped by `titlebarReservedHeight` so the terminal grid keeps roughly
    // the same default row count after the transparent-titlebar change ate
    // 28 pt of top padding.
    let viewH: CGFloat = 760 + TerminalBitmapView.titlebarReservedHeight

    let termW = max(1, Int(viewW - sidebarWidth - insets.left - insets.right))
    let termH = max(1, Int(viewH - insets.top - insets.bottom))
    var size = LabanTerminalSize()
    size.rows = Int32(termH / cellH)
    size.cols = Int32(termW / cellW)

    let model = try AppModel(
      initialSize: size,
      sessionFactory: Session.realShell
    )

    // The transcript host owns one TranscriptWriter per tab. AppModel
    // calls it when tabs are created/closed so the per-tab `.bin`
    // file is opened, fed PTY bytes, and torn down at the right
    // moments. Hook this up BEFORE any tab work so the default tab
    // created by AppModel.init gets a writer too. The host's
    // `isEnabled` gate is checked on every disk drain, so flipping
    // the "Restore on Launch" toggle off stops `.bin` writes
    // immediately even though writers stay attached.
    let transcriptHost = TranscriptHost(
      isEnabled: { RestoreOnLaunchSettings.isEnabled })
    model.transcriptDelegate = transcriptHost
    model.restoreFailureLogger = { tabId, error in
      AppLog.app.error("restored tab \(tabId) failed: \(String(describing: error))")
    }

    // Restore-time factory: build a deferred-spawn session in the
    // persisted cwd, then start a fresh shell. Historical transcript
    // bytes and persisted launch commands remain diagnostic/future
    // pivot data only; automatic restore must not paint old output
    // or replay generic terminal commands into a live terminal.
    model.restoredDeferredSessionFactory = { spec in
      let session = try Session.makeDeferred(size: spec.size, cwd: spec.cwd)
      let rc = session.startSpawn(
        overrideCwd: spec.cwdFallbackApplied ? spec.cwd : nil)
      if rc != 0 {
        // Spawn failed — log and surface a banner. The session keeps
        // its VT parser so the tab body is renderable; the user sees
        // a banner where the shell prompt would have been.
        AppLog.app.error(
          "restored tab \(spec.tabId) failed to spawn shell (cwd=\(spec.cwd))")
        let warning = "\r\n[restore failed: shell did not start in \(spec.cwd)]\r\n"
        _ = session.feedOutput(Array(warning.utf8))
      }
      return session
    }
    // Simple fallback for restored tabs that don't have a deferred
    // factory (used by headless tests that swap the factory out).
    model.restoredSessionFactory = { size, cwd in
      try Session.realShell(size: size, cwd: cwd)
    }

    // The default tab created by AppModel.init() needs its writer
    // attached too — its session was constructed before the delegate
    // was assigned. Attach explicitly here.
    for (tab, session) in model.allSessions() {
      transcriptHost.attachTranscriptWriter(to: session, tabId: tab.id)
    }

    // Rebuild the tab list from `workspace.json` BEFORE creating the
    // terminal view so the user never sees a flash of the default tab.
    // `replaceTabs(from:)` closes the auto-created first session and
    // spawns one fresh shell per persisted tab in its prior cwd.
    if let restoredState, !restoredState.windows.isEmpty {
      model.replaceTabs(from: restoredState)
    }
    // Restore can leave zero tabs (window had no persisted tabs, or
    // every restore spawn threw). The app must always show at least
    // one tab, so fall back to a fresh default-shell tab — the same
    // path the "+" titlebar button uses.
    if model.tabs.isEmpty {
      _ = try? model.createTab()
    }

    let termView = TerminalBitmapView(
      model: model,
      fontAtlas: fontAtlas,
      sidebarFontAtlas: sidebarFontAtlas,
      cellWidth: cellW,
      cellHeight: cellH
    )
    termView.frame = NSRect(x: 0, y: 0, width: viewW, height: viewH)

    let mask: NSWindow.StyleMask = [
      .titled, .closable, .miniaturizable, .resizable, .fullSizeContentView,
    ]
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: viewW, height: viewH),
      styleMask: mask,
      backing: .buffered,
      defer: false
    )
    window.title = "Laban"
    // Transparent titlebar with the contentView extending behind it; the
    // sidebar and terminal-area background rects fill the reserved strip so
    // the chrome looks continuous with the terminal. Traffic lights stay
    // interactive because AppKit composites them over the contentView.
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.contentView = termView
    window.center()
    window.makeKeyAndOrderFront(nil)

    // "+" new-tab button as a titlebar accessory next to the traffic
    // lights. Frees a full row from the sidebar without sacrificing
    // discoverability — the button is always visible at a fixed screen
    // position regardless of how many tabs are open.
    let plusButton = NSButton(
      title: "+",
      target: nil,
      action: #selector(TerminalBitmapView.newTab(_:))
    )
    plusButton.bezelStyle = .smallSquare
    plusButton.isBordered = false
    plusButton.font = NSFont.systemFont(ofSize: 16, weight: .light)
    plusButton.contentTintColor = .secondaryLabelColor
    plusButton.translatesAutoresizingMaskIntoConstraints = false
    let accessoryHost = NSView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
    accessoryHost.addSubview(plusButton)
    NSLayoutConstraint.activate([
      plusButton.centerXAnchor.constraint(equalTo: accessoryHost.centerXAnchor),
      plusButton.centerYAnchor.constraint(equalTo: accessoryHost.centerYAnchor),
      plusButton.widthAnchor.constraint(equalToConstant: 24),
      plusButton.heightAnchor.constraint(equalToConstant: 24),
    ])
    let accessory = NSTitlebarAccessoryViewController()
    accessory.view = accessoryHost
    accessory.layoutAttribute = .leading
    window.addTitlebarAccessoryViewController(accessory)

    let controller = MainWindowController(window: window)
    controller.model = model

    // Persistence is wired AFTER the optional restore so the initial
    // restored snapshot does not bounce back through the coordinator.
    // `attach(_:)` registers as the model's `onWorkspaceMutation`
    // subscriber; subsequent mutations debounce-save through
    // `PersistenceStore`. The toggle gate (`RestoreOnLaunchSettings`)
    // is checked inside the coordinator on every save and load attempt,
    // so flipping the menu item off makes both no-op silently.
    let coordinator = PersistenceCoordinator()
    coordinator.transcriptHost = transcriptHost
    coordinator.attach(model)
    controller.persistenceCoordinator = coordinator

    // Agent autoresume: M2. Per-tab detector polls for claude/codex
    // descendants and captures the session id from the open .jsonl
    // file; mirror snapshots that file on lifecycle events and on a
    // 5-minute periodic timer while the agent is alive. Attached
    // here so the first default tab (and any restored ones) get a
    // detector right away. Note that detectors short-circuit when
    // the session has no real PID (fixture mode in tests), so this
    // is safe even when the productive app delegate is shimmed.
    let mirror = AgentJSONLMirror()
    let observerHost = AgentObserverHost(appModel: model, mirror: mirror)
    controller.agentObserverHost = observerHost
    model.onTabCreated = { [weak observerHost] tabId, session in
      observerHost?.attach(session: session, tabId: tabId)
    }
    model.onTabClosed = { [weak observerHost] tabId in
      observerHost?.detach(tabId: tabId)
    }
    for (tab, session) in model.allSessions() {
      observerHost.attach(session: session, tabId: tab.id)
    }
    if let restoredState, !restoredState.windows.isEmpty {
      Self.applyRestoreLaunchPlans(
        for: restoredState, model: model)
    }

    // Schedule one save so the persisted state reflects the just-spawned
    // (or just-restored) tab list within the debounce window. Without
    // this, a user who quits before causing any further mutation would
    // leave `workspace.json` unchanged from its prior contents.
    coordinator.scheduleSave()

    return controller
  }

  /// For each restored tab whose persisted state has an `agent`,
  /// ask `RestoreLaunchPlanner` what to do and apply it:
  ///   - `.executeNow(cmd)` writes `clear && cmd\n` into the new
  ///     tab's PTY. The `clear` prefix wipes the visible grid before
  ///     the agent paints — without it, the shell's echo of the
  ///     resume line sits stuck at the top of the buffer because
  ///     claude/codex render inline (no alt-screen) and never
  ///     overwrite row 0.
  ///   - `.prefillPrompt(cmd)` writes `cmd` without a newline; the
  ///     user sees the resume command at the prompt and presses
  ///     ENTER to run it.
  ///   - `.noPrefill` is a no-op.
  ///
  /// Called once during restore, after `replaceTabs(from:)` has
  /// rebuilt the tab list and spawned each fresh shell.
  private static func applyRestoreLaunchPlans(
    for state: WorkspaceState, model: AppModel
  ) {
    guard let window = state.windows.first else { return }
    for tabState in window.tabs {
      let instruction = RestoreLaunchPlanner.instruction(for: tabState)
      switch instruction {
      case .noPrefill:
        continue
      case .executeNow(let command):
        guard let session = model.session(forTab: tabState.id) else { continue }
        let bytes = Array("clear && \(command)\n".utf8)
        _ = session.write(bytes)
      case .prefillPrompt(let command):
        guard let session = model.session(forTab: tabState.id) else { continue }
        let bytes = Array(command.utf8)
        _ = session.write(bytes)
      }
    }
  }
}
