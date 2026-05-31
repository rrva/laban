import Darwin
import Foundation
import LabanTerminalCore

public enum SessionError: Error {
  case createFailed
}

public enum TerminalColorScheme {
  case light
  case dark

  var rawValue: Int32 {
    switch self {
    case .light: return Int32(LABAN_COLOR_SCHEME_LIGHT)
    case .dark: return Int32(LABAN_COLOR_SCHEME_DARK)
    }
  }
}

public final class Session {
  public typealias ID = String

  public struct CapturedWrite<Result: Equatable & Sendable>: Equatable, Sendable {
    public var result: Result
    public var bytes: [UInt8]

    public init(result: Result, bytes: [UInt8]) {
      self.result = result
      self.bytes = bytes
    }
  }

  public typealias CapturedKeyWrite = CapturedWrite<Int32>
  public typealias CapturedMouseWrite = CapturedWrite<Int32>

  public struct ProcessMetadata: Equatable, Sendable {
    public var childPid: Int?
    public var foregroundPid: Int?
    public var foregroundProcess: String?
    public var foregroundCommand: String?
    public var foregroundArguments: [String]?
    public var cwd: String?

    public init(
      childPid: Int? = nil,
      foregroundPid: Int? = nil,
      foregroundProcess: String? = nil,
      foregroundCommand: String? = nil,
      foregroundArguments: [String]? = nil,
      cwd: String? = nil
    ) {
      self.childPid = childPid
      self.foregroundPid = foregroundPid
      self.foregroundProcess = foregroundProcess
      self.foregroundCommand = foregroundCommand
      self.foregroundArguments = foregroundArguments
      self.cwd = cwd
    }
  }

  public let id: ID
  private var handle: OpaquePointer?
  public private(set) var isClosed = false
  /// Serializes the handle's lifecycle: every C call below holds this across
  /// its use of `handle`, and `close()` holds it while destroying, so the
  /// laband multi-client tier can never run `laban_session_destroy` on one
  /// thread while another is mid-`write`/`snapshot`/`resize` (M-5 UAF).
  /// Recursive so a synchronous callback that re-enters a Session method on
  /// the same thread cannot self-deadlock. The runner thread's direct
  /// `laban_session_poll` is not covered here — it stays caller-ordered
  /// (stop the runner before `close()`), as `makeRunner` documents.
  private let handleLock = NSRecursiveLock()
  private let fixtureMode: Bool
  private let callbackState: SessionCallbackState
  private var captureCallbackUserdata: UnsafeMutableRawPointer?
  private var tabStatusCallbackUserdata: UnsafeMutableRawPointer?
  private var bellCallbackUserdata: UnsafeMutableRawPointer?
  private var oscNotificationCallbackUserdata: UnsafeMutableRawPointer?
  private var clipboardCallbackUserdata: UnsafeMutableRawPointer?
  private var workingDirectoryCallbackUserdata: UnsafeMutableRawPointer?
  private var shellIntegrationCallbackUserdata: UnsafeMutableRawPointer?
  public weak var captureSink: CaptureSink? {
    didSet {
      callbackState.setCaptureSink(captureSink)
      updateCaptureCallback()
    }
  }

  /// One snapshot of the iTerm2 OSC 21337 tab-status fields. Per the spec,
  /// `nil` means "key was absent in this update — preserve the prior
  /// value", `""` means "clear the field", anything else is a new value.
  public struct TabStatusUpdate: Sendable {
    public var indicator: String?
    public var status: String?
    public var statusColor: String?
  }

  /// Set once per Session at the call site (AppModel) to receive parsed
  /// OSC 21337 updates. Fires on the same thread that drove `poll()`.
  public var onTabStatus: ((TabStatusUpdate) -> Void)? {
    didSet {
      callbackState.setTabStatusHandler(onTabStatus)
      updateTabStatusCallback()
    }
  }

  /// Set once per Session to receive terminal BEL events. Fires on the same
  /// thread that drove `poll()` or `feedOutput(_:)`.
  public var onBell: ((UInt64) -> Void)? {
    didSet {
      callbackState.setBellHandler(onBell)
      updateBellCallback()
    }
  }

  /// Set once per Session to receive OSC 9 desktop notifications — `ESC ] 9 ;
  /// <text> BEL/ST` — for example the Codex agent TUI emitting "agent turn
  /// complete" or "approval requested". Fires with the notification text on the
  /// same thread that drove `poll()` or `feedOutput(_:)`. (The OSC 10/11 color
  /// query reply that shares the same C scanner is always-on and needs no
  /// handler.)
  public var onOSCNotification: ((String) -> Void)? {
    didSet {
      callbackState.setOSCNotificationHandler(onOSCNotification)
      updateOSCNotificationCallback()
    }
  }

  /// Set to observe OSC 7 working-directory reports — `ESC ] 7 ;
  /// file://<host>/<path> ST` — that a shell emits on each prompt. Fires with
  /// the decoded absolute path on the same thread that drove `poll()` /
  /// `feedOutput(_:)`. Observing is optional: the reported cwd is adopted as the
  /// session's authoritative directory regardless (it flows through
  /// `processMetadata().cwd`), so this handler is for observers that want the
  /// change immediately (e.g. the debug event stream). A remote-host report is
  /// filtered out in the C layer and never fires this.
  public var onWorkingDirectory: ((String) -> Void)? {
    didSet {
      callbackState.setWorkingDirectoryHandler(onWorkingDirectory)
      updateWorkingDirectoryCallback()
    }
  }

  /// Set to receive OSC 52 clipboard *writes* — `ESC ] 52 ; c ; <base64> ST`,
  /// emitted by a program (e.g. an editor or coding agent reached over SSH)
  /// that wants to place data on the macOS clipboard. Fires with the already
  /// base64-decoded bytes on the same thread that drove `poll()` /
  /// `feedOutput(_:)`; the AppKit consumer hops to the main queue to touch
  /// `NSPasteboard`. An invalid or oversized payload is dropped before this
  /// fires. Always honored when set — there is no opt-in for write.
  public var onClipboardWrite: ((Data) -> Void)? {
    didSet {
      callbackState.setClipboardWriteHandler(onClipboardWrite)
      updateClipboardCallbacks()
    }
  }

  /// Set to receive OSC 52 clipboard *read* queries — `ESC ] 52 ; c ; ? ST`.
  /// Fires with the requested selection string ONLY when `clipboardReadEnabled`
  /// is true (default false), so a remote program cannot read the host
  /// clipboard unasked. The handler should read the clipboard off the reader
  /// thread (hop to main) and answer with `respondClipboardRead`.
  public var onClipboardReadRequest: ((String) -> Void)? {
    didSet {
      callbackState.setClipboardReadHandler(onClipboardReadRequest)
      updateClipboardCallbacks()
    }
  }

  /// Whether to answer OSC 52 read queries. Defaults to false: writes (copy
  /// from a remote program to the host clipboard) work out of the box, but a
  /// read query is dropped with no reply unless the host opts in. Mirrors the
  /// security stance of xterm's `allowWindowOps`.
  public var clipboardReadEnabled: Bool = false {
    didSet {
      guard oldValue != clipboardReadEnabled else { return }
      handleLock.lock()
      defer { handleLock.unlock() }
      guard !isClosed, let h = handle else { return }
      laban_session_set_osc52_read_enabled(h, clipboardReadEnabled ? 1 : 0)
    }
  }

  /// Answer an OSC 52 read query by writing the host clipboard back to the
  /// child PTY as `ESC ] 52 ; <selection> ; <base64> ST`. Call from an
  /// `onClipboardReadRequest` handler after reading `NSPasteboard`.
  public func respondClipboardRead(selection: String, data: Data) {
    let base64 = Array(OSC52Clipboard.encodeRead(data).utf8)
    let selectionBytes = Array(selection.utf8)
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return }
    selectionBytes.withUnsafeBufferPointer { sel in
      sel.withMemoryRebound(to: CChar.self) { selChar in
        base64.withUnsafeBufferPointer { b64 in
          _ = laban_session_respond_clipboard_osc52(
            h, selChar.baseAddress, selChar.count, b64.baseAddress, b64.count)
        }
      }
    }
  }

  /// Set to observe OSC 133 shell-integration transitions. Fires with the
  /// *post-reduction* `ShellIntegrationState` after each marker, on the same
  /// thread that drove `poll()` or `feedOutput(_:)`. The state is tracked
  /// unconditionally (so `shellIntegrationState()` is always live); this
  /// handler is only for observers that want to react to changes.
  public var onShellIntegration: ((ShellIntegrationState) -> Void)? {
    didSet {
      callbackState.setShellIntegrationHandler(onShellIntegration)
    }
  }

  public init(config: inout LabanLaunchConfig, size: LabanTerminalSize) throws {
    let id = UUID().uuidString
    self.id = id
    self.fixtureMode = config.fixture_mode != 0
    self.callbackState = SessionCallbackState(sessionId: id)
    var h: OpaquePointer?
    guard laban_session_create(&config, size, &h) == 0, let h else {
      throw SessionError.createFailed
    }
    self.handle = h
    installShellIntegrationCallback()
  }

  /// Register the OSC 133 observer once at creation. Unlike the bell and
  /// tab-status callbacks (which only register when a handler is set), shell
  /// integration state is tracked for the session's whole life so the debug
  /// endpoint and UI can read the current phase at any time, even before any
  /// observer attaches.
  private func installShellIntegrationCallback() {
    guard let h = handle else { return }
    if shellIntegrationCallbackUserdata == nil {
      shellIntegrationCallbackUserdata = Unmanaged.passRetained(callbackState).toOpaque()
    }
    laban_session_set_osc133_callback(
      h,
      sessionShellIntegrationCallback,
      shellIntegrationCallbackUserdata
    )
  }

  /// The current OSC 133 shell-integration phase and last exit code.
  /// Tracked from session creation; returns `.idle` with no exit code
  /// until the shell emits its first marker.
  public func shellIntegrationState() -> ShellIntegrationState {
    callbackState.currentShellIntegration()
  }

  public static func fixture(size: LabanTerminalSize) throws -> Session {
    var config = LabanLaunchConfig()
    config.fixture_mode = 1
    return try Session(config: &config, size: size)
  }

  public static func realShell(
    size: LabanTerminalSize,
    environment: [String: String] = [:],
    launchArgv: [String]? = nil
  ) throws -> Session {
    try makeRealShell(
      size: size, cwd: nil, environment: environment, launchArgv: launchArgv, deferSpawn: false)
  }

  /// Spawn the user's login shell with an explicit working directory.
  /// Used by the workspace-restore path so each restored tab opens its
  /// previously observed `cwd`. The cwd is captured by the C session
  /// layer via `LabanLaunchConfig.cwd` and applied with `chdir(2)`
  /// inside the constrained fork child before `execve(2)` runs.
  ///
  /// `environment` supplies env overrides merged into the spawn environment
  /// (the C layer keeps the parent environment and applies these on top) —
  /// used to point the shell at the OSC 133 rc-overlay via `ZDOTDIR`. See
  /// `ShellIntegrationOverlay`.
  public static func realShell(
    size: LabanTerminalSize,
    cwd: String,
    environment: [String: String] = [:],
    launchArgv: [String]? = nil
  ) throws -> Session {
    try makeRealShell(
      size: size, cwd: cwd, environment: environment, launchArgv: launchArgv, deferSpawn: false)
  }

  /// Build a real-shell session, optionally deferred, with env overrides and
  /// an optional explicit argv (argv[0] is the executable). Keeps the
  /// C-string lifetimes (cwd, envp, argv) valid for the duration of
  /// `laban_session_create`, which deep-copies the env array internally.
  private static func makeRealShell(
    size: LabanTerminalSize,
    cwd: String?,
    environment: [String: String],
    launchArgv: [String]?,
    deferSpawn: Bool
  ) throws -> Session {
    var config = LabanLaunchConfig()
    config.fixture_mode = 0
    if deferSpawn { config.defer_spawn = 1 }

    // Compose the nested withCString scopes from inside out so every C
    // pointer (cwd, envp, executable, argv) outlives the create call.
    func withEnv(_ body: () throws -> Session) throws -> Session {
      guard !environment.isEmpty else { return try body() }
      let entries = environment.map { "\($0.key)=\($0.value)" }
      return try withCStringArray(entries) { envPtr in
        config.envp = envPtr
        return try body()
      }
    }
    func withArgv(_ body: () throws -> Session) throws -> Session {
      guard let launchArgv, !launchArgv.isEmpty else { return try body() }
      return try launchArgv[0].withCString { exePtr in
        config.executable = exePtr
        return try withCStringArray(launchArgv) { argvPtr in
          config.argv = argvPtr
          return try body()
        }
      }
    }
    func build(cwdPtr: UnsafePointer<CChar>?) throws -> Session {
      config.cwd = cwdPtr
      return try withEnv { try withArgv { try Session(config: &config, size: size) } }
    }

    guard let cwd else { return try build(cwdPtr: nil) }
    return try cwd.withCString { try build(cwdPtr: $0) }
  }

  /// Create a real-shell session whose libghostty parser is fully
  /// constructed but whose child process has not been fork+exec'd yet.
  /// Pair with `startSpawn()` to actually launch the shell. The
  /// workspace-restore path uses this so a transcript replay can paint
  /// scrollback into the parser BEFORE any live shell output arrives.
  /// The cwd is recorded on the C session and applied at spawn time.
  ///
  /// `environment` overrides are captured at create time and applied when
  /// the deferred child finally spawns (the C layer persists them on the
  /// session), so the OSC 133 `ZDOTDIR` overlay survives restore.
  public static func makeDeferred(
    size: LabanTerminalSize,
    cwd: String,
    environment: [String: String] = [:]
  ) throws -> Session {
    // The deferred create path ignores config.argv (it returns before argv
    // handling and resolves the shell at spawn time), so an argv override for
    // bash must go through startSpawn(launchArgv:), not here.
    try makeRealShell(
      size: size, cwd: cwd, environment: environment, launchArgv: nil, deferSpawn: true)
  }

  /// Fork+exec the deferred-spawn child. No-op when the session was
  /// not created with `makeDeferred(...)`. Returns 0 on success, -1
  /// otherwise. The override cwd, if non-nil, replaces the cwd
  /// captured at create time — used by the cwd-gone fallback to swap
  /// in `$HOME` when the originally persisted directory is no longer
  /// reachable.
  ///
  /// `injection` (agent resume) takes precedence over `launchArgv`: a
  /// running agent must relaunch with its resume command. `launchArgv` is
  /// the shell-integration argv for shells that need one (bash's
  /// `--rcfile`); zsh/fish pass `nil` and rely on their env overlay, which
  /// survives via the session's persisted envp.
  @discardableResult
  public func startSpawn(
    overrideCwd: String? = nil,
    injection: RestoreShellInjection? = nil,
    launchArgv: [String]? = nil
  ) -> Int32 {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return -1 }
    if let argv = injection?.argv ?? launchArgv, !argv.isEmpty {
      let exe = injection?.shellPath ?? argv[0]
      return withOptionalCString(overrideCwd) { cwdPtr in
        exe.withCString { exePtr in
          Session.withCStringArray(argv) { argvPtr in
            laban_session_start_spawn_argv(h, cwdPtr, exePtr, argvPtr)
          }
        }
      }
    }
    if let overrideCwd {
      return overrideCwd.withCString { ptr in
        laban_session_start_spawn(h, ptr)
      }
    }
    return laban_session_start_spawn(h, nil)
  }

  /// Drop PTY output from a restored deferred spawn until the first
  /// input write. The restored transcript already painted the prior
  /// prompt; the replacement shell's startup prompt is only launch
  /// noise until the user or autoresume writes real input.
  @discardableResult
  public func suppressPtyOutputUntilInput(_ enabled: Bool = true) -> Int32 {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return -1 }
    return laban_session_suppress_pty_output_until_input(h, enabled ? 1 : 0)
  }

  public static func debugShell(
    size: LabanTerminalSize,
    extraEnvironment: [String: String] = [:]
  ) throws -> Session {
    var config = LabanLaunchConfig()
    config.fixture_mode = 0
    let executable = "/bin/sh"
    let argv = ["/bin/sh"]
    // Base deterministic env, plus any shell-integration overrides the
    // headless runtime threads in (empty for /bin/sh, which has no overlay).
    var env: [String: String] = [
      "TERM": "xterm-256color",
      "COLORTERM": "truecolor",
      "PS1": "$ ",
    ]
    for (k, v) in extraEnvironment { env[k] = v }
    let envp = env.map { "\($0.key)=\($0.value)" }

    return try executable.withCString { exePtr in
      try withCStringArray(argv) { argvPtr in
        try withCStringArray(envp) { envPtr in
          config.executable = exePtr
          config.argv = argvPtr
          config.envp = envPtr
          return try Session(config: &config, size: size)
        }
      }
    }
  }

  private func withOptionalCString<R>(
    _ string: String?,
    _ body: (UnsafePointer<CChar>?) -> R
  ) -> R {
    guard let string else { return body(nil) }
    return string.withCString { body($0) }
  }

  private static func withCStringArray<R>(
    _ strings: [String],
    _ body: (UnsafePointer<UnsafePointer<CChar>?>) throws -> R
  ) rethrows -> R {
    let cStrings = strings.map { strdup($0) }
    defer {
      for cString in cStrings {
        if let cString { free(cString) }
      }
    }
    var pointers = cStrings.map { cString -> UnsafePointer<CChar>? in
      guard let cString else { return nil }
      return UnsafePointer(cString)
    }
    pointers.append(nil)
    return try pointers.withUnsafeBufferPointer { buffer in
      try body(buffer.baseAddress!)
    }
  }

  public func close() {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed else { return }
    isClosed = true
    if let h = handle {
      clearCaptureCallback(handle: h)
      clearTabStatusCallback(handle: h)
      clearBellCallback(handle: h)
      clearOSCNotificationCallback(handle: h)
      clearClipboardCallbacks(handle: h)
      clearWorkingDirectoryCallback(handle: h)
      clearShellIntegrationCallback(handle: h)
      laban_session_destroy(h)
      handle = nil
    }
  }

  deinit { close() }

  @discardableResult
  public func poll() -> Int32 {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return -1 }
    return laban_session_poll(h)
  }

  /// Build a `SessionRunner` that owns this session's PTY drain on a
  /// dedicated thread. Returns nil if the session is closed. The
  /// caller is responsible for `start()`ing the runner and for calling
  /// `stop()` before this session is `close()`d.
  public func makeRunner(onDirty: @escaping @Sendable () -> Void) -> SessionRunner? {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !fixtureMode, !isClosed, let h = handle else { return nil }
    return SessionRunner(handle: h, onDirty: onDirty)
  }

  @discardableResult
  public func resize(_ size: LabanTerminalSize) -> Int32 {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return -1 }
    return laban_session_resize(h, size)
  }

  @discardableResult
  public func write(_ bytes: [UInt8]) -> Int32 {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return -1 }
    if bytes.isEmpty { return 0 }
    return bytes.withUnsafeBytes { buf in
      laban_session_write(h, buf.baseAddress!.assumingMemoryBound(to: UInt8.self), bytes.count)
    }
  }

  /// Feed bytes directly into the VT parser, bypassing the PTY.
  /// Used to inject OSC palette sequences at session startup.
  @discardableResult
  public func feedOutput(_ bytes: [UInt8]) -> Int32 {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return -1 }
    if bytes.isEmpty { return 0 }
    return bytes.withUnsafeBytes { buf in
      laban_session_feed_output(
        h, buf.baseAddress!.assumingMemoryBound(to: UInt8.self), bytes.count)
    }
  }

  /// Feed captured PTY output into the terminal parser during deterministic replay.
  /// This bypasses PTY input semantics and does not emit capture callbacks.
  @discardableResult
  public func replayPtyOutput(_ bytes: [UInt8]) -> Int32 {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return -1 }
    if bytes.isEmpty { return 0 }
    return bytes.withUnsafeBytes { buf in
      laban_session_replay_pty_output(
        h, buf.baseAddress!.assumingMemoryBound(to: UInt8.self), bytes.count)
    }
  }

  public func setCaptureFrame(_ frame: Int) {
    callbackState.setCaptureFrame(frame)
  }

  public func snapshot() -> UnsafeMutablePointer<LabanSnapshot>? {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return nil }
    var snap: UnsafeMutablePointer<LabanSnapshot>?
    guard laban_session_snapshot(h, &snap) == 0 else { return nil }
    return snap
  }

  /// Returns true if the session has unrendered terminal changes.
  /// Returns false on C failure or closed session; the frame loop
  /// should treat C failure as non-fatal and retry on the next tick.
  public func renderDirty() -> Bool {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return false }
    var dirty: Int32 = 0
    guard laban_session_render_dirty(h, &dirty) == 0 else { return false }
    return dirty != 0
  }

  /// Mark the most recent snapshot as rendered, preserving later row dirties.
  /// Returns -1 on C failure, 0 on success.
  @discardableResult
  public func markRendered() -> Int32 {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return -1 }
    return laban_session_mark_rendered(h)
  }

  // MARK: - Exit state

  /// Returns the current exit state of the child process.
  /// Returns `.running` when closed so callers need not special-case isClosed.
  public func exitState() -> TabStatus {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return .running }
    let raw = laban_session_exit_state(h)
    switch raw.status {
    case 1: return .exited(code: Int(raw.exit_status))
    case 2: return .exitedSignal(signal: Int(raw.exit_status))
    default: return .running
    }
  }

  // MARK: - PTY-byte capture

  /// Mirror every byte fed to the VT parser into `path` until `stopCapture()`
  /// is called. Existing file contents are overwritten. Returns true on
  /// success.
  @discardableResult
  public func startCapture(path: String) -> Bool {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return false }
    return path.withCString { laban_session_capture_start(h, $0) == 0 }
  }

  @discardableResult
  public func stopCapture() -> Bool {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return false }
    return laban_session_capture_stop(h) == 0
  }

  public var isCapturing: Bool {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return false }
    return laban_session_capture_active(h) != 0
  }

  /// Tee keyboard input into the capture sink as PTY_INPUT without writing to
  /// any PTY. In the daemon (labpty/laband) tier the app's viewer session has
  /// no PTY — output arrives via `feedOutput` and responses via VT effects, but
  /// keystrokes go over the socket to the daemon, so PTY_INPUT never reaches the
  /// app-side sink unless teed here. The app calls this with the same bytes it
  /// sends to the daemon. No-op when no capture sink is attached.
  public func captureInput(_ bytes: [UInt8]) {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return }
    if bytes.isEmpty { return }
    bytes.withUnsafeBytes { buf in
      laban_session_capture_input(
        h, buf.baseAddress!.assumingMemoryBound(to: UInt8.self), bytes.count)
    }
  }

  /// True when libghostty-vt currently has the alternate-screen buffer
  /// active (full-screen TUI mode — vim/htop/less). The workspace
  /// persistence path samples this at quit so transcript replay does
  /// not paint half-finished TUI state on the next launch.
  public var altBufferActive: Bool {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return false }
    return laban_session_alt_buffer_active(h) != 0
  }

  /// Register a persistence-tee callback through the C ABI. The
  /// callback fires from `laban_vt_write_capture` AFTER the existing
  /// capture callback and BEFORE libghostty's VT parser receives the
  /// bytes. The contract is memcpy-only — the implementer must not do
  /// IO or block in the callback. See the C header for the full
  /// contract. Pass `(nil, nil)` to clear.
  @discardableResult
  public func setPersistenceCallback(
    _ callback: LabanPersistenceBytesCallback?,
    userdata: UnsafeMutableRawPointer?
  ) -> Int32 {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return -1 }
    return laban_session_set_persistence_callback(h, callback, userdata)
  }

  // MARK: - Title

  /// Consume any pending title-changed notification from the C layer.
  /// Returns (dirty: true, raw: String?) when a title change was pending and
  /// its raw bytes were copied; returns (false, nil) when nothing changed.
  public func consumeTitle() -> (dirty: Bool, raw: String?) {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return (false, nil) }
    return withUnsafeTemporaryAllocation(of: CChar.self, capacity: 1024) { buf in
      let r = laban_session_consume_title(h, buf.baseAddress, buf.count)
      guard r > 0, let baseAddress = buf.baseAddress else { return (false, nil) }
      let raw = String(cString: baseAddress)
      return (true, raw.isEmpty ? nil : raw)
    }
  }

  // MARK: - Process metadata

  public func processMetadata() -> ProcessMetadata? {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return nil }
    // Fixture sessions have no PTY and no foreground process. The C path
    // still returns success with empty pid/process/command and `launch_cwd`
    // as the cwd, which produces a non-nil `ProcessMetadata` whose derived
    // `ProcessIdentity` is nil. In laband (background-session) mode that
    // empty identity clobbers the daemon-supplied identity installed by
    // `AppSessionCoordinator.refreshTabMetadata` every time the
    // surface controller polls the local session, which made the tab
    // title flip-flop ~4 Hz between "~" and "~\nzsh". Returning nil here
    // short-circuits the `guard let metadata = session.processMetadata()`
    // in `TabMetadataSynchronizer.syncSurfaceMetadata`, leaving the
    // daemon as the sole authority for foreground-process metadata.
    if fixtureMode { return nil }
    var childPid: Int32 = -1
    var foregroundPid: Int32 = -1

    return withUnsafeTemporaryAllocation(of: CChar.self, capacity: 256) { processBuf in
      withUnsafeTemporaryAllocation(of: CChar.self, capacity: 1024) { commandBuf in
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: 1024) { cwdBuf in
          let result = laban_session_process_metadata(
            h,
            &childPid,
            &foregroundPid,
            processBuf.baseAddress,
            processBuf.count,
            commandBuf.baseAddress,
            commandBuf.count,
            cwdBuf.baseAddress,
            cwdBuf.count
          )
          guard
            result == 0,
            let processBaseAddress = processBuf.baseAddress,
            let commandBaseAddress = commandBuf.baseAddress,
            let cwdBaseAddress = cwdBuf.baseAddress
          else {
            return nil
          }
          let foregroundArguments =
            foregroundPid > 0 ? Self.foregroundArguments(for: foregroundPid) : nil
          return ProcessMetadata(
            childPid: childPid > 0 ? Int(childPid) : nil,
            foregroundPid: foregroundPid > 0 ? Int(foregroundPid) : nil,
            foregroundProcess: TerminalTitle.sanitize(String(cString: processBaseAddress)),
            foregroundCommand: TerminalTitle.sanitize(String(cString: commandBaseAddress)),
            foregroundArguments: foregroundArguments,
            cwd: TerminalTitle.sanitize(String(cString: cwdBaseAddress))
          )
        }
      }
    }
  }

  private static func foregroundArguments(for pid: Int32) -> [String]? {
    let arguments = LibprocIntrospector().arguments(of: pid_t(pid)).prefix(16)
      .compactMap { TerminalTitle.sanitize($0) }
    return arguments.isEmpty ? nil : arguments
  }

  // MARK: - Viewport scrolling

  /// Scroll the terminal viewport by deltaRows relative to the current offset.
  /// Negative values scroll toward older history; positive values scroll toward
  /// the active bottom. Returns 0 on success.
  @discardableResult
  public func scrollViewport(deltaRows: Int) -> Int32 {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return -1 }
    return laban_session_scroll_viewport(h, Int32(deltaRows))
  }

  /// Returns the current viewport state (scrollback rows, offset, mouse tracking, etc.),
  /// or nil if the session is closed or the C call fails.
  public func viewportState() -> ViewportState? {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return nil }
    var vs = LabanViewportState()
    guard laban_session_viewport_state(h, &vs) == 0 else { return nil }
    return ViewportState(from: vs)
  }

  public func scrollbackBlock(rowOffset: Int = 0, maxRows: Int = 0) -> ScrollbackBlock? {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return nil }
    let safeOffset = max(0, rowOffset)
    let safeMaxRows = max(0, maxRows)

    var textBuffer: UnsafeMutablePointer<CChar>?
    var rowOffsets: UnsafeMutablePointer<UInt32>?
    var outRows: size_t = 0
    var outTextLen: size_t = 0
    guard
      laban_session_scrollback_extract_alloc(
        h,
        size_t(safeOffset),
        size_t(safeMaxRows),
        &textBuffer,
        &rowOffsets,
        &outRows,
        &outTextLen
      ) == 0,
      let textBuffer
    else { return nil }
    defer { laban_session_scrollback_extract_free(textBuffer) }
    defer {
      if let rowOffsets {
        laban_session_scrollback_extract_free(rowOffsets)
      }
    }

    let byteCount = Int(outTextLen)
    let raw = UnsafeRawBufferPointer(start: textBuffer, count: byteCount)
    let text = String(decoding: raw, as: UTF8.self)
    let offsets: [Int]
    if let rowOffsets, outRows > 0 {
      offsets = UnsafeBufferPointer(start: rowOffsets, count: Int(outRows)).map(Int.init)
    } else {
      offsets = []
    }
    return ScrollbackBlock(
      text: text,
      rowOffsets: offsets
    )
  }

  public func findMatchesInScrollback(
    needle: String,
    rowOffset: Int = 0,
    maxRows: Int = 0,
    caseMode: TerminalFindCaseMode = .smart
  ) -> [TerminalFindMatch]? {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return nil }
    let needleBytes = Array(needle.utf8)
    guard !needleBytes.isEmpty else { return [] }
    guard needleBytes.allSatisfy({ $0 < 0x80 }) else { return nil }

    let foldASCII = TerminalFind.shouldFoldASCII(needleBytes: needleBytes, caseMode: caseMode)
    let safeOffset = max(0, rowOffset)
    let safeMaxRows = max(0, maxRows)

    var matchesPointer: UnsafeMutablePointer<LabanFindMatch>?
    var matchCount: size_t = 0
    var complete: Int32 = 0
    let rc = needleBytes.withUnsafeBufferPointer { buffer -> Int32 in
      guard let baseAddress = buffer.baseAddress else { return -1 }
      return laban_session_find_matches_alloc(
        h,
        baseAddress,
        size_t(buffer.count),
        foldASCII ? 1 : 0,
        size_t(safeOffset),
        size_t(safeMaxRows),
        &matchesPointer,
        &matchCount,
        &complete
      )
    }
    defer {
      if let matchesPointer {
        laban_session_find_matches_free(matchesPointer)
      }
    }

    guard rc == 0, complete != 0 else { return nil }
    guard let matchesPointer, matchCount > 0 else { return [] }
    return UnsafeBufferPointer(start: matchesPointer, count: Int(matchCount)).map { match in
      TerminalFindMatch(
        row: Int(match.row),
        startColumn: Int(match.start_column),
        endColumn: Int(match.end_column)
      )
    }
  }

  /// Snap the viewport to the active bottom if it is currently showing older
  /// scrollback. Returns the row delta the viewport moved.
  ///
  /// This pins to the bottom in a single C call (`GHOSTTY_SCROLL_VIEWPORT_BOTTOM`)
  /// rather than reading the scrollbar and scrolling by `(total - len) - offset`
  /// in two steps. The reader thread streams a chatty app's output into
  /// libghostty concurrently, so a two-step snap can have rows appended between
  /// the read and the scroll: the delta is then stale, the viewport lands short
  /// of the live bottom, follow-output never re-engages, and the overlay scroll
  /// indicator stays stuck visible. The atomic pin closes that race.
  @discardableResult
  public func scrollViewportToActiveBottom() -> Int {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return 0 }
    var movedRows: Int32 = 0
    guard laban_session_scroll_viewport_to_bottom(h, &movedRows) == 0 else { return 0 }
    return Int(movedRows)
  }

  public var synchronizedOutputActive: Bool {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return false }
    var active: Int32 = 0
    guard laban_session_synchronized_output_active(h, &active) == 0 else { return false }
    return active != 0
  }

  @discardableResult
  public func resetSynchronizedOutput() -> Int32 {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return -1 }
    return laban_session_reset_synchronized_output(h)
  }

  public func bellCount() -> UInt64 {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return 0 }
    var count: UInt64 = 0
    guard laban_session_bell_count(h, &count) == 0 else { return 0 }
    return count
  }

  @discardableResult
  public func setColorScheme(_ scheme: TerminalColorScheme) -> Int32 {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return -1 }
    return laban_session_set_color_scheme(h, scheme.rawValue)
  }

  public var focusReportingEnabled: Bool {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return false }
    var enabled: Int32 = 0
    guard laban_session_focus_reporting_enabled(h, &enabled) == 0 else { return false }
    return enabled != 0
  }

  public func encodeFocus(focused: Bool) -> [UInt8]? {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return nil }
    var buf = [UInt8](repeating: 0, count: 16)
    var len: size_t = 0
    guard laban_session_encode_focus(h, focused ? 1 : 0, &buf, buf.count, &len) == 0 else {
      return nil
    }
    guard len > 0 else { return nil }
    return Array(buf.prefix(Int(len)))
  }

  @discardableResult
  public func sendFocus(focused: Bool) -> Int32 {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return -1 }
    return laban_session_send_focus(h, focused ? 1 : 0)
  }

  // MARK: - Key encoding

  /// Encode a key event into terminal input bytes using libghostty-vt's key encoder.
  /// Returns nil if the session is closed, if encoding fails, or if the key produces no bytes
  /// (e.g. an unmodified modifier key). Handles UTF-8 text lifetime internally.
  public func encodeKey(_ event: KeyEvent) -> [UInt8]? {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return nil }
    var buf = [UInt8](repeating: 0, count: 128)
    var len = 0
    let rc = event.withLabanKeyEvent { raw in
      var rawCopy = raw
      return buf.withUnsafeMutableBytes { outBuf in
        laban_session_encode_key(
          h, &rawCopy,
          outBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
          outBuf.count, &len)
      }
    }
    if rc == 1, len > 0 {
      var heapBuf = [UInt8](repeating: 0, count: len)
      var heapLen = 0
      let heapRC = event.withLabanKeyEvent { raw in
        var rawCopy = raw
        return heapBuf.withUnsafeMutableBytes { outBuf in
          laban_session_encode_key(
            h, &rawCopy,
            outBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
            outBuf.count, &heapLen)
        }
      }
      guard heapRC == 0, heapLen > 0 else { return nil }
      return Array(heapBuf.prefix(heapLen))
    }
    guard rc == 0, len > 0 else { return nil }
    return Array(buf.prefix(len))
  }

  /// Encode and send a key event to the terminal session.
  /// Returns 0 on success or when the key produces no bytes; -1 on error.
  /// In fixture mode, encoding succeeds but no PTY write occurs.
  @discardableResult
  public func sendKey(_ event: KeyEvent) -> Int32 {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return -1 }
    return event.withLabanKeyEvent { raw in
      var rawCopy = raw
      return laban_session_send_key(h, &rawCopy)
    }
  }

  /// Encode and send a key event, returning the exact bytes accepted by the
  /// terminal-core send path. In fixture mode, returns encoded bytes without a
  /// PTY write.
  public func sendKeyCapturingBytes(_ event: KeyEvent) -> CapturedKeyWrite {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return CapturedKeyWrite(result: -1, bytes: []) }
    var buf = [UInt8](repeating: 0, count: 128)
    var len = 0
    let result = event.withLabanKeyEvent { raw in
      var rawCopy = raw
      return buf.withUnsafeMutableBytes { outBuf in
        laban_session_send_key_encoded(
          h,
          &rawCopy,
          outBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
          outBuf.count,
          &len)
      }
    }
    if result == 1, len > buf.count {
      buf = [UInt8](repeating: 0, count: len)
      len = 0
      let retry = event.withLabanKeyEvent { raw in
        var rawCopy = raw
        return buf.withUnsafeMutableBytes { outBuf in
          laban_session_send_key_encoded(
            h,
            &rawCopy,
            outBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
            outBuf.count,
            &len)
        }
      }
      guard retry == 0 else { return CapturedKeyWrite(result: retry, bytes: []) }
      return CapturedKeyWrite(result: retry, bytes: Array(buf.prefix(len)))
    }
    guard result == 0 else { return CapturedKeyWrite(result: result, bytes: []) }
    return CapturedKeyWrite(result: result, bytes: Array(buf.prefix(len)))
  }

  // MARK: - Mouse encoding

  /// Encode a mouse event into terminal escape bytes using libghostty's mouse encoder.
  /// Returns nil if the session is closed, the C call fails, or if mouse tracking is
  /// disabled (the encoder returns zero bytes).
  public func encodeMouse(_ event: MouseEvent) -> [UInt8]? {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return nil }
    var raw = event.toLabanMouseEvent()
    var buf = [UInt8](repeating: 0, count: 64)
    var outLen: size_t = 0
    guard laban_session_encode_mouse(h, &raw, &buf, buf.count, &outLen) == 0 else { return nil }
    guard outLen > 0 else { return nil }
    return Array(buf.prefix(Int(outLen)))
  }

  /// Encode and send a mouse event through the PTY. Returns 0 on success.
  /// In fixture mode, this is a no-op that returns 0.
  @discardableResult
  public func sendMouse(_ event: MouseEvent) -> Int32 {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return -1 }
    var raw = event.toLabanMouseEvent()
    return laban_session_send_mouse(h, &raw)
  }

  public func sendMouseCapturingBytes(_ event: MouseEvent) -> CapturedMouseWrite {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return CapturedMouseWrite(result: -1, bytes: []) }
    var raw = event.toLabanMouseEvent()
    var buf = [UInt8](repeating: 0, count: 128)
    var outLen: size_t = 0
    let result = laban_session_send_mouse_encoded(h, &raw, &buf, buf.count, &outLen)
    if result == 1, outLen > buf.count {
      buf = [UInt8](repeating: 0, count: outLen)
      outLen = 0
      let retry = laban_session_send_mouse_encoded(h, &raw, &buf, buf.count, &outLen)
      guard retry == 0 else { return CapturedMouseWrite(result: retry, bytes: []) }
      return CapturedMouseWrite(result: retry, bytes: Array(buf.prefix(Int(outLen))))
    }
    guard result == 0 else { return CapturedMouseWrite(result: result, bytes: []) }
    return CapturedMouseWrite(result: result, bytes: Array(buf.prefix(Int(outLen))))
  }

  // MARK: - Paste

  /// Pure libghostty check: returns true when the bytes contain no
  /// characters that look like command injection in a raw shell
  /// (newlines, escape sequences, etc.). Wrapper around
  /// `ghostty_paste_is_safe`. No session required.
  public static func pasteIsSafe(_ bytes: [UInt8]) -> Bool {
    bytes.withUnsafeBufferPointer { buf in
      laban_paste_is_safe(buf.baseAddress, bytes.count) != 0
    }
  }

  public func bracketedPasteEnabled() -> Bool {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return false }
    var enabled: Int32 = 0
    guard laban_session_bracketed_paste_enabled(h, &enabled) == 0 else { return false }
    return enabled != 0
  }

  public struct PasteWriteResult: Equatable, Sendable {
    public var bracketed: Bool
    public var bytesWritten: Int
  }

  public typealias CapturedPasteWrite = CapturedWrite<PasteWriteResult?>

  @discardableResult
  public func writePaste(_ text: String) -> PasteWriteResult? {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return nil }
    let bytes = Array(text.utf8)
    if bytes.isEmpty {
      return PasteWriteResult(bracketed: bracketedPasteEnabled(), bytesWritten: 0)
    }
    var raw = LabanPasteResult()
    let r = bytes.withUnsafeBytes { buf in
      laban_session_write_paste(
        h,
        buf.baseAddress!.assumingMemoryBound(to: UInt8.self),
        bytes.count,
        &raw
      )
    }
    guard r == 0 else { return nil }
    return PasteWriteResult(bracketed: raw.bracketed != 0, bytesWritten: raw.bytes_written)
  }

  /// Encode `text` as the terminal's paste byte sequence (bracketed
  /// if DECSET 2004 is active, raw otherwise) and return the bytes
  /// **without** writing them to this session's PTY or fixture VT.
  /// Use this when the bytes are destined for a remote PTY owner
  /// (labpty / laband daemon): the local Session in those backends
  /// is fixture-mode purely for rendering, and feeding the paste
  /// into it would inject the paste content into the rendered grid
  /// at the cursor (visible as paste digits leaking into adjacent
  /// rows of the UI). The remote daemon's PTY echo, if any, comes
  /// back via the byte ring and gets fed through `feedOutput` like
  /// every other PTY output byte.
  public func encodePaste(_ text: String) -> CapturedPasteWrite {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return CapturedPasteWrite(result: nil, bytes: []) }
    let bytes = Array(text.utf8)
    if bytes.isEmpty {
      return CapturedPasteWrite(
        result: PasteWriteResult(bracketed: bracketedPasteEnabled(), bytesWritten: 0),
        bytes: []
      )
    }

    var out = [UInt8](repeating: 0, count: bytes.count + 16)
    let outCapacity = out.count
    var outLen: size_t = 0
    var bracketed: Int32 = 0
    let rc = bytes.withUnsafeBytes { inputBuf in
      out.withUnsafeMutableBytes { outBuf in
        laban_session_encode_paste(
          h,
          inputBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
          bytes.count,
          outBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
          outCapacity,
          &outLen,
          &bracketed
        )
      }
    }
    guard rc == 0 else { return CapturedPasteWrite(result: nil, bytes: []) }
    return CapturedPasteWrite(
      result: PasteWriteResult(bracketed: bracketed != 0, bytesWritten: outLen),
      bytes: Array(out.prefix(Int(outLen)))
    )
  }

  public func writePasteCapturingBytes(_ text: String) -> CapturedPasteWrite {
    handleLock.lock()
    defer { handleLock.unlock() }
    guard !isClosed, let h = handle else { return CapturedPasteWrite(result: nil, bytes: []) }
    let bytes = Array(text.utf8)
    if bytes.isEmpty {
      return CapturedPasteWrite(
        result: PasteWriteResult(bracketed: bracketedPasteEnabled(), bytesWritten: 0),
        bytes: []
      )
    }

    var out = [UInt8](repeating: 0, count: bytes.count + 16)
    var outCapacity = out.count
    var outLen: size_t = 0
    var raw = LabanPasteResult()
    let rc = bytes.withUnsafeBytes { inputBuf in
      out.withUnsafeMutableBytes { outBuf in
        laban_session_write_paste_encoded(
          h,
          inputBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
          bytes.count,
          outBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
          outCapacity,
          &outLen,
          &raw
        )
      }
    }
    if rc == 1, outLen > out.count {
      out = [UInt8](repeating: 0, count: Int(outLen))
      outCapacity = out.count
      outLen = 0
      raw = LabanPasteResult()
      let retry = bytes.withUnsafeBytes { inputBuf in
        out.withUnsafeMutableBytes { outBuf in
          laban_session_write_paste_encoded(
            h,
            inputBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
            bytes.count,
            outBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
            outCapacity,
            &outLen,
            &raw
          )
        }
      }
      guard retry == 0 else { return CapturedPasteWrite(result: nil, bytes: []) }
      return CapturedPasteWrite(
        result: PasteWriteResult(bracketed: raw.bracketed != 0, bytesWritten: raw.bytes_written),
        bytes: Array(out.prefix(Int(outLen)))
      )
    }
    guard rc == 0 else { return CapturedPasteWrite(result: nil, bytes: []) }
    return CapturedPasteWrite(
      result: PasteWriteResult(bracketed: raw.bracketed != 0, bytesWritten: raw.bytes_written),
      bytes: Array(out.prefix(Int(outLen)))
    )
  }

  private func updateCaptureCallback() {
    guard !isClosed, let h = handle else { return }
    if callbackState.hasCaptureSink {
      if captureCallbackUserdata == nil {
        captureCallbackUserdata = Unmanaged.passRetained(callbackState).toOpaque()
      }
      laban_session_set_capture_callback(
        h,
        sessionCaptureCallback,
        captureCallbackUserdata
      )
    } else {
      clearCaptureCallback(handle: h)
    }
  }

  private func updateTabStatusCallback() {
    guard !isClosed, let h = handle else { return }
    if callbackState.hasTabStatusHandler {
      if tabStatusCallbackUserdata == nil {
        tabStatusCallbackUserdata = Unmanaged.passRetained(callbackState).toOpaque()
      }
      laban_session_set_tab_status_callback(
        h,
        sessionTabStatusCallback,
        tabStatusCallbackUserdata
      )
    } else {
      clearTabStatusCallback(handle: h)
    }
  }

  private func updateBellCallback() {
    guard !isClosed, let h = handle else { return }
    if callbackState.hasBellHandler {
      if bellCallbackUserdata == nil {
        bellCallbackUserdata = Unmanaged.passRetained(callbackState).toOpaque()
      }
      laban_session_set_bell_callback(h, sessionBellCallback, bellCallbackUserdata)
    } else {
      clearBellCallback(handle: h)
    }
  }

  private func updateOSCNotificationCallback() {
    guard !isClosed, let h = handle else { return }
    if callbackState.hasOSCNotificationHandler {
      if oscNotificationCallbackUserdata == nil {
        oscNotificationCallbackUserdata = Unmanaged.passRetained(callbackState).toOpaque()
      }
      laban_session_set_osc_notification_callback(
        h, sessionOSCNotificationCallback, oscNotificationCallbackUserdata)
    } else {
      clearOSCNotificationCallback(handle: h)
    }
  }

  private func updateClipboardCallbacks() {
    guard !isClosed, let h = handle else { return }
    if callbackState.hasClipboardHandlers {
      if clipboardCallbackUserdata == nil {
        clipboardCallbackUserdata = Unmanaged.passRetained(callbackState).toOpaque()
      }
      laban_session_set_osc_clipboard_callbacks(
        h, sessionClipboardWriteCallback, sessionClipboardReadCallback,
        clipboardCallbackUserdata)
    } else {
      clearClipboardCallbacks(handle: h)
    }
  }

  private func updateWorkingDirectoryCallback() {
    guard !isClosed, let h = handle else { return }
    if callbackState.hasWorkingDirectoryHandler {
      if workingDirectoryCallbackUserdata == nil {
        workingDirectoryCallbackUserdata = Unmanaged.passRetained(callbackState).toOpaque()
      }
      laban_session_set_osc_working_directory_callback(
        h, sessionWorkingDirectoryCallback, workingDirectoryCallbackUserdata)
    } else {
      clearWorkingDirectoryCallback(handle: h)
    }
  }

  private func clearCaptureCallback(handle h: OpaquePointer) {
    laban_session_set_capture_callback(h, nil, nil)
    if let userdata = captureCallbackUserdata {
      Unmanaged<SessionCallbackState>.fromOpaque(userdata).release()
      captureCallbackUserdata = nil
    }
  }

  private func clearTabStatusCallback(handle h: OpaquePointer) {
    laban_session_set_tab_status_callback(h, nil, nil)
    if let userdata = tabStatusCallbackUserdata {
      Unmanaged<SessionCallbackState>.fromOpaque(userdata).release()
      tabStatusCallbackUserdata = nil
    }
  }

  private func clearBellCallback(handle h: OpaquePointer) {
    laban_session_set_bell_callback(h, nil, nil)
    if let userdata = bellCallbackUserdata {
      Unmanaged<SessionCallbackState>.fromOpaque(userdata).release()
      bellCallbackUserdata = nil
    }
  }

  private func clearOSCNotificationCallback(handle h: OpaquePointer) {
    laban_session_set_osc_notification_callback(h, nil, nil)
    if let userdata = oscNotificationCallbackUserdata {
      Unmanaged<SessionCallbackState>.fromOpaque(userdata).release()
      oscNotificationCallbackUserdata = nil
    }
  }

  private func clearClipboardCallbacks(handle h: OpaquePointer) {
    laban_session_set_osc_clipboard_callbacks(h, nil, nil, nil)
    if let userdata = clipboardCallbackUserdata {
      Unmanaged<SessionCallbackState>.fromOpaque(userdata).release()
      clipboardCallbackUserdata = nil
    }
  }

  private func clearWorkingDirectoryCallback(handle h: OpaquePointer) {
    laban_session_set_osc_working_directory_callback(h, nil, nil)
    if let userdata = workingDirectoryCallbackUserdata {
      Unmanaged<SessionCallbackState>.fromOpaque(userdata).release()
      workingDirectoryCallbackUserdata = nil
    }
  }

  private func clearShellIntegrationCallback(handle h: OpaquePointer) {
    laban_session_set_osc133_callback(h, nil, nil)
    if let userdata = shellIntegrationCallbackUserdata {
      Unmanaged<SessionCallbackState>.fromOpaque(userdata).release()
      shellIntegrationCallbackUserdata = nil
    }
  }
}

private final class SessionCallbackState {
  let sessionId: Session.ID
  private let lock = NSLock()
  private weak var captureSink: CaptureSink?
  private var captureFrame = 0
  private var tabStatusHandler: ((Session.TabStatusUpdate) -> Void)?
  private var bellHandler: ((UInt64) -> Void)?
  private var oscNotificationHandler: ((String) -> Void)?
  private var clipboardWriteHandler: ((Data) -> Void)?
  private var clipboardReadHandler: ((String) -> Void)?
  private var workingDirectoryHandler: ((String) -> Void)?
  private var shellIntegrationHandler: ((ShellIntegrationState) -> Void)?
  private var shellIntegration = ShellIntegrationState()

  init(sessionId: Session.ID) {
    self.sessionId = sessionId
  }

  var hasCaptureSink: Bool {
    lock.lock()
    defer { lock.unlock() }
    return captureSink != nil
  }

  var hasTabStatusHandler: Bool {
    lock.lock()
    defer { lock.unlock() }
    return tabStatusHandler != nil
  }

  var hasBellHandler: Bool {
    lock.lock()
    defer { lock.unlock() }
    return bellHandler != nil
  }

  var hasOSCNotificationHandler: Bool {
    lock.lock()
    defer { lock.unlock() }
    return oscNotificationHandler != nil
  }

  var hasClipboardHandlers: Bool {
    lock.lock()
    defer { lock.unlock() }
    return clipboardWriteHandler != nil || clipboardReadHandler != nil
  }

  var hasWorkingDirectoryHandler: Bool {
    lock.lock()
    defer { lock.unlock() }
    return workingDirectoryHandler != nil
  }

  func setCaptureSink(_ sink: CaptureSink?) {
    lock.lock()
    captureSink = sink
    lock.unlock()
  }

  func setCaptureFrame(_ frame: Int) {
    lock.lock()
    captureFrame = frame
    lock.unlock()
  }

  func setTabStatusHandler(_ handler: ((Session.TabStatusUpdate) -> Void)?) {
    lock.lock()
    tabStatusHandler = handler
    lock.unlock()
  }

  func setBellHandler(_ handler: ((UInt64) -> Void)?) {
    lock.lock()
    bellHandler = handler
    lock.unlock()
  }

  func setOSCNotificationHandler(_ handler: ((String) -> Void)?) {
    lock.lock()
    oscNotificationHandler = handler
    lock.unlock()
  }

  func setClipboardWriteHandler(_ handler: ((Data) -> Void)?) {
    lock.lock()
    clipboardWriteHandler = handler
    lock.unlock()
  }

  func setClipboardReadHandler(_ handler: ((String) -> Void)?) {
    lock.lock()
    clipboardReadHandler = handler
    lock.unlock()
  }

  func setWorkingDirectoryHandler(_ handler: ((String) -> Void)?) {
    lock.lock()
    workingDirectoryHandler = handler
    lock.unlock()
  }

  func setShellIntegrationHandler(_ handler: ((ShellIntegrationState) -> Void)?) {
    lock.lock()
    shellIntegrationHandler = handler
    lock.unlock()
  }

  /// Reduce one OSC 133 action into the running state and return the
  /// post-reduction state plus the observer to notify (if any). Done under
  /// the lock so the C scanner thread and the accessor never race.
  func applyShellIntegration(
    _ action: ShellIntegrationAction
  ) -> (state: ShellIntegrationState, handler: ((ShellIntegrationState) -> Void)?) {
    lock.lock()
    defer { lock.unlock() }
    shellIntegration.apply(action)
    return (shellIntegration, shellIntegrationHandler)
  }

  func currentShellIntegration() -> ShellIntegrationState {
    lock.lock()
    defer { lock.unlock() }
    return shellIntegration
  }

  func captureTarget() -> (sink: CaptureSink, frame: Int)? {
    lock.lock()
    defer { lock.unlock() }
    guard let captureSink else { return nil }
    return (captureSink, captureFrame)
  }

  func tabStatusTarget() -> ((Session.TabStatusUpdate) -> Void)? {
    lock.lock()
    defer { lock.unlock() }
    return tabStatusHandler
  }

  func bellTarget() -> ((UInt64) -> Void)? {
    lock.lock()
    defer { lock.unlock() }
    return bellHandler
  }

  func oscNotificationTarget() -> ((String) -> Void)? {
    lock.lock()
    defer { lock.unlock() }
    return oscNotificationHandler
  }

  func clipboardWriteTarget() -> ((Data) -> Void)? {
    lock.lock()
    defer { lock.unlock() }
    return clipboardWriteHandler
  }

  func clipboardReadTarget() -> ((String) -> Void)? {
    lock.lock()
    defer { lock.unlock() }
    return clipboardReadHandler
  }

  func workingDirectoryTarget() -> ((String) -> Void)? {
    lock.lock()
    defer { lock.unlock() }
    return workingDirectoryHandler
  }
}

private let sessionBellCallback:
  @convention(c) (UnsafeMutableRawPointer?, OpaquePointer?, UInt64) -> Void = {
    userdata, _, count in
    guard let userdata else { return }
    let state = Unmanaged<SessionCallbackState>.fromOpaque(userdata).takeUnretainedValue()
    state.bellTarget()?(count)
  }

private let sessionOSCNotificationCallback:
  @convention(c) (
    UnsafeMutableRawPointer?, OpaquePointer?, UnsafePointer<UInt8>?, Int
  ) -> Void = { userdata, _, text, len in
    guard let userdata, let text, len > 0 else { return }
    let state = Unmanaged<SessionCallbackState>.fromOpaque(userdata).takeUnretainedValue()
    let message = String(decoding: UnsafeBufferPointer(start: text, count: len), as: UTF8.self)
    state.oscNotificationTarget()?(message)
  }

/// OSC 52 write: the C scanner hands us the raw base64 payload. Decode + cap
/// here (the codec is shared with the headless runtime and unit-tested) and
/// deliver the clipboard bytes; a malformed or oversized payload is dropped.
private let sessionClipboardWriteCallback:
  @convention(c) (
    UnsafeMutableRawPointer?, OpaquePointer?,
    UnsafePointer<CChar>?, Int,
    UnsafePointer<UInt8>?, Int
  ) -> Void = { userdata, _, _, _, base64, base64Len in
    guard let userdata, let base64, base64Len > 0 else { return }
    let state = Unmanaged<SessionCallbackState>.fromOpaque(userdata).takeUnretainedValue()
    guard let handler = state.clipboardWriteTarget() else { return }
    let bytes = Array(UnsafeBufferPointer(start: base64, count: base64Len))
    guard let data = OSC52Clipboard.decodeWrite(base64: bytes) else { return }
    handler(data)
  }

/// OSC 52 read query: deliver the requested selection string. Only fires when
/// read is enabled (the C side gates on osc52_read_enabled).
private let sessionClipboardReadCallback:
  @convention(c) (
    UnsafeMutableRawPointer?, OpaquePointer?, UnsafePointer<CChar>?, Int
  ) -> Void = { userdata, _, selection, selectionLen in
    guard let userdata else { return }
    let state = Unmanaged<SessionCallbackState>.fromOpaque(userdata).takeUnretainedValue()
    guard let handler = state.clipboardReadTarget() else { return }
    let sel: String
    if let selection, selectionLen > 0 {
      sel = selection.withMemoryRebound(to: UInt8.self, capacity: selectionLen) {
        String(decoding: UnsafeBufferPointer(start: $0, count: selectionLen), as: UTF8.self)
      }
    } else {
      sel = "c"
    }
    handler(sel)
  }

/// OSC 7 working-directory report: deliver the decoded absolute path.
private let sessionWorkingDirectoryCallback:
  @convention(c) (
    UnsafeMutableRawPointer?, OpaquePointer?, UnsafePointer<CChar>?, Int
  ) -> Void = { userdata, _, path, len in
    guard let userdata, let path, len > 0 else { return }
    let state = Unmanaged<SessionCallbackState>.fromOpaque(userdata).takeUnretainedValue()
    guard let handler = state.workingDirectoryTarget() else { return }
    let cwd = path.withMemoryRebound(to: UInt8.self, capacity: len) {
      String(decoding: UnsafeBufferPointer(start: $0, count: len), as: UTF8.self)
    }
    handler(cwd)
  }

private let sessionShellIntegrationCallback:
  @convention(c) (
    UnsafeMutableRawPointer?,
    OpaquePointer?,
    LabanOSC133Action,
    Int32,
    Int32
  ) -> Void = { userdata, _, action, hasExitCode, exitCode in
    guard let userdata else { return }
    let state = Unmanaged<SessionCallbackState>.fromOpaque(userdata).takeUnretainedValue()
    let mapped: ShellIntegrationAction
    switch action {
    case LABAN_OSC133_PROMPT_START:
      mapped = .promptStart
    case LABAN_OSC133_PROMPT_END:
      mapped = .promptEnd
    case LABAN_OSC133_COMMAND_START:
      mapped = .commandStart
    case LABAN_OSC133_COMMAND_END:
      mapped = .commandEnd(exitCode: hasExitCode != 0 ? Int(exitCode) : nil)
    default:
      return
    }
    let (reduced, handler) = state.applyShellIntegration(mapped)
    handler?(reduced)
  }

private let sessionTabStatusCallback:
  @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?
  ) -> Void = { userdata, indicator, status, statusColor in
    guard let userdata else { return }
    let state = Unmanaged<SessionCallbackState>.fromOpaque(userdata).takeUnretainedValue()
    let update = Session.TabStatusUpdate(
      indicator: indicator.map { String(cString: $0) },
      status: status.map { String(cString: $0) },
      statusColor: statusColor.map { String(cString: $0) }
    )
    state.tabStatusTarget()?(update)
  }

private let sessionCaptureCallback:
  @convention(c) (
    UnsafeMutableRawPointer?,
    OpaquePointer?,
    LabanCaptureBytesDirection,
    UnsafePointer<UInt8>?,
    Int
  ) -> Void = { userdata, _, direction, bytes, length in
    guard let userdata, let bytes, length > 0 else { return }
    let state = Unmanaged<SessionCallbackState>.fromOpaque(userdata).takeUnretainedValue()
    guard let target = state.captureTarget() else { return }
    let mapped: CaptureByteDirection
    switch direction {
    case LABAN_CAPTURE_BYTES_PTY_INPUT:
      mapped = .ptyInput
    case LABAN_CAPTURE_BYTES_TERMINAL_RESPONSE:
      mapped = .terminalResponse
    default:
      mapped = .ptyOutput
    }
    let raw = UnsafeRawBufferPointer(start: bytes, count: length)
    _ = target.sink.recordBytes(
      direction: mapped,
      sessionId: state.sessionId,
      frame: target.frame,
      bytes: raw,
      preview: nil
    )
  }

// MARK: - Viewport state

public struct ViewportState {
  public let totalRows: Int
  public let scrollbackRows: Int
  public let viewportOffset: Int
  public let viewportRows: Int
  public let mouseTracking: Bool
  /// Alternate screen buffer active (full-screen TUI). Laban has no scrollback
  /// to scroll here, so the wheel only does something useful when the app opts
  /// into reporting or alternate scroll mode.
  public let altScreen: Bool
  /// Alternate scroll mode (DEC private 1007). When set and `mouseTracking` is
  /// off, wheel input drives the app's cursor keys instead of native scroll.
  public let altScroll: Bool

  init(from raw: LabanViewportState) {
    totalRows = Int(raw.total_rows)
    scrollbackRows = Int(raw.scrollback_rows)
    viewportOffset = Int(raw.viewport_offset)
    viewportRows = Int(raw.viewport_rows)
    mouseTracking = raw.mouse_tracking != 0
    altScreen = raw.alt_screen != 0
    altScroll = raw.alt_scroll != 0
  }

  public static func scrollDeltaToActiveBottom(
    viewportOffset: Int,
    totalRows: Int,
    viewportRows: Int
  ) -> Int {
    let bottomOffset = max(0, totalRows - viewportRows)
    return max(0, bottomOffset - viewportOffset)
  }

  public var scrollDeltaToActiveBottom: Int {
    Self.scrollDeltaToActiveBottom(
      viewportOffset: viewportOffset,
      totalRows: totalRows,
      viewportRows: viewportRows
    )
  }
}

// MARK: - Key types

public enum KeyAction: Equatable, Sendable {
  case release, press, held
}

public enum Key: Equatable, Sendable {
  case backquote, backslash, bracketLeft, bracketRight, comma
  case digit0, digit1, digit2, digit3, digit4, digit5, digit6, digit7, digit8, digit9
  case equal
  case a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z
  case minus, period, quote, semicolon, slash
  case backspace, enter, space, tab
  case delete, end, home, insert, pageDown, pageUp
  case arrowDown, arrowLeft, arrowRight, arrowUp
  case escape
  case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
  case f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24
}

public struct KeyModifiers: OptionSet, Sendable {
  public let rawValue: Int32
  public init(rawValue: Int32) { self.rawValue = rawValue }

  public static let shift = KeyModifiers(rawValue: 1 << 0)
  public static let control = KeyModifiers(rawValue: 1 << 1)
  public static let alt = KeyModifiers(rawValue: 1 << 2)
  public static let command = KeyModifiers(rawValue: 1 << 3)
  public static let capsLock = KeyModifiers(rawValue: 1 << 4)
  public static let numLock = KeyModifiers(rawValue: 1 << 5)
  public static let shiftSide = KeyModifiers(rawValue: 1 << 6)
  public static let controlSide = KeyModifiers(rawValue: 1 << 7)
  public static let altSide = KeyModifiers(rawValue: 1 << 8)
  public static let superSide = KeyModifiers(rawValue: 1 << 9)
}

public struct KeyEvent: Equatable, Sendable {
  public var action: KeyAction
  public var key: Key
  public var modifiers: KeyModifiers
  public var consumedModifiers: KeyModifiers
  public var composing: Bool
  public var unshiftedCodepoint: UInt32
  public var text: String?

  public init(
    action: KeyAction = .press,
    key: Key,
    modifiers: KeyModifiers = [],
    consumedModifiers: KeyModifiers = [],
    composing: Bool = false,
    unshiftedCodepoint: UInt32 = 0,
    text: String? = nil
  ) {
    self.action = action
    self.key = key
    self.modifiers = modifiers
    self.consumedModifiers = consumedModifiers
    self.composing = composing
    self.unshiftedCodepoint = unshiftedCodepoint
    self.text = text
  }

  func withLabanKeyEvent<T>(_ body: (LabanKeyEvent) -> T) -> T {
    var raw = LabanKeyEvent()
    switch action {
    case .release: raw.action = LABAN_KEY_ACTION_RELEASE
    case .press: raw.action = LABAN_KEY_ACTION_PRESS
    case .held: raw.action = LABAN_KEY_ACTION_REPEAT
    }
    raw.key = {
      switch key {
      case .backquote: return LABAN_KEY_BACKQUOTE
      case .backslash: return LABAN_KEY_BACKSLASH
      case .bracketLeft: return LABAN_KEY_BRACKET_LEFT
      case .bracketRight: return LABAN_KEY_BRACKET_RIGHT
      case .comma: return LABAN_KEY_COMMA
      case .digit0: return LABAN_KEY_DIGIT_0
      case .digit1: return LABAN_KEY_DIGIT_1
      case .digit2: return LABAN_KEY_DIGIT_2
      case .digit3: return LABAN_KEY_DIGIT_3
      case .digit4: return LABAN_KEY_DIGIT_4
      case .digit5: return LABAN_KEY_DIGIT_5
      case .digit6: return LABAN_KEY_DIGIT_6
      case .digit7: return LABAN_KEY_DIGIT_7
      case .digit8: return LABAN_KEY_DIGIT_8
      case .digit9: return LABAN_KEY_DIGIT_9
      case .equal: return LABAN_KEY_EQUAL
      case .a: return LABAN_KEY_A
      case .b: return LABAN_KEY_B
      case .c: return LABAN_KEY_C
      case .d: return LABAN_KEY_D
      case .e: return LABAN_KEY_E
      case .f: return LABAN_KEY_F
      case .g: return LABAN_KEY_G
      case .h: return LABAN_KEY_H
      case .i: return LABAN_KEY_I
      case .j: return LABAN_KEY_J
      case .k: return LABAN_KEY_K
      case .l: return LABAN_KEY_L
      case .m: return LABAN_KEY_M
      case .n: return LABAN_KEY_N
      case .o: return LABAN_KEY_O
      case .p: return LABAN_KEY_P
      case .q: return LABAN_KEY_Q
      case .r: return LABAN_KEY_R
      case .s: return LABAN_KEY_S
      case .t: return LABAN_KEY_T
      case .u: return LABAN_KEY_U
      case .v: return LABAN_KEY_V
      case .w: return LABAN_KEY_W
      case .x: return LABAN_KEY_X
      case .y: return LABAN_KEY_Y
      case .z: return LABAN_KEY_Z
      case .minus: return LABAN_KEY_MINUS
      case .period: return LABAN_KEY_PERIOD
      case .quote: return LABAN_KEY_QUOTE
      case .semicolon: return LABAN_KEY_SEMICOLON
      case .slash: return LABAN_KEY_SLASH
      case .backspace: return LABAN_KEY_BACKSPACE
      case .enter: return LABAN_KEY_ENTER
      case .space: return LABAN_KEY_SPACE
      case .tab: return LABAN_KEY_TAB
      case .delete: return LABAN_KEY_DELETE
      case .end: return LABAN_KEY_END
      case .home: return LABAN_KEY_HOME
      case .insert: return LABAN_KEY_INSERT
      case .pageDown: return LABAN_KEY_PAGE_DOWN
      case .pageUp: return LABAN_KEY_PAGE_UP
      case .arrowDown: return LABAN_KEY_ARROW_DOWN
      case .arrowLeft: return LABAN_KEY_ARROW_LEFT
      case .arrowRight: return LABAN_KEY_ARROW_RIGHT
      case .arrowUp: return LABAN_KEY_ARROW_UP
      case .escape: return LABAN_KEY_ESCAPE
      case .f1: return LABAN_KEY_F1
      case .f2: return LABAN_KEY_F2
      case .f3: return LABAN_KEY_F3
      case .f4: return LABAN_KEY_F4
      case .f5: return LABAN_KEY_F5
      case .f6: return LABAN_KEY_F6
      case .f7: return LABAN_KEY_F7
      case .f8: return LABAN_KEY_F8
      case .f9: return LABAN_KEY_F9
      case .f10: return LABAN_KEY_F10
      case .f11: return LABAN_KEY_F11
      case .f12: return LABAN_KEY_F12
      case .f13: return LABAN_KEY_F13
      case .f14: return LABAN_KEY_F14
      case .f15: return LABAN_KEY_F15
      case .f16: return LABAN_KEY_F16
      case .f17: return LABAN_KEY_F17
      case .f18: return LABAN_KEY_F18
      case .f19: return LABAN_KEY_F19
      case .f20: return LABAN_KEY_F20
      case .f21: return LABAN_KEY_F21
      case .f22: return LABAN_KEY_F22
      case .f23: return LABAN_KEY_F23
      case .f24: return LABAN_KEY_F24
      }
    }()
    raw.modifiers = modifiers.rawValue
    raw.consumed_modifiers = consumedModifiers.rawValue
    raw.composing = composing ? 1 : 0
    raw.unshifted_codepoint = unshiftedCodepoint
    raw.utf8 = nil
    raw.utf8_len = 0

    if let text, !text.isEmpty {
      return text.withCString { cStr in
        raw.utf8 = cStr
        raw.utf8_len = text.utf8.count
        return body(raw)
      }
    } else {
      return body(raw)
    }
  }
}

// MARK: - Mouse types

public enum MouseAction: Int {
  case press = 0
  case release = 1
  case motion = 2
}

public enum MouseButton: Int {
  case none = 0
  case left = 1
  case middle = 2
  case right = 3
  case wheelUp = 4
  case wheelDown = 5
}

public struct MouseEvent {
  public var action: MouseAction
  public var button: MouseButton
  public var x: Float
  public var y: Float
  public var screenWidth: Int
  public var screenHeight: Int
  public var cellWidth: Int
  public var cellHeight: Int
  public var modifiers: Int

  public init(
    action: MouseAction,
    button: MouseButton,
    x: Float,
    y: Float,
    screenWidth: Int,
    screenHeight: Int,
    cellWidth: Int,
    cellHeight: Int,
    modifiers: Int = 0
  ) {
    self.action = action
    self.button = button
    self.x = x
    self.y = y
    self.screenWidth = screenWidth
    self.screenHeight = screenHeight
    self.cellWidth = cellWidth
    self.cellHeight = cellHeight
    self.modifiers = modifiers
  }

  func toLabanMouseEvent() -> LabanMouseEvent {
    var raw = LabanMouseEvent()
    switch action {
    case .press: raw.action = LABAN_MOUSE_ACTION_PRESS
    case .release: raw.action = LABAN_MOUSE_ACTION_RELEASE
    case .motion: raw.action = LABAN_MOUSE_ACTION_MOTION
    }
    switch button {
    case .none: raw.button = LABAN_MOUSE_BUTTON_NONE
    case .left: raw.button = LABAN_MOUSE_BUTTON_LEFT
    case .middle: raw.button = LABAN_MOUSE_BUTTON_MIDDLE
    case .right: raw.button = LABAN_MOUSE_BUTTON_RIGHT
    case .wheelUp: raw.button = LABAN_MOUSE_BUTTON_WHEEL_UP
    case .wheelDown: raw.button = LABAN_MOUSE_BUTTON_WHEEL_DOWN
    }
    raw.x = x
    raw.y = y
    raw.screen_width = Int32(screenWidth)
    raw.screen_height = Int32(screenHeight)
    raw.cell_width = Int32(cellWidth)
    raw.cell_height = Int32(cellHeight)
    raw.modifiers = Int32(modifiers)
    return raw
  }
}
