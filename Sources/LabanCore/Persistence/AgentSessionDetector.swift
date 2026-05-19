import Darwin
import Foundation
import LabanTerminalCore

/// Per-tab background poller that watches the tab's shell descendants
/// for `claude` / `codex` processes and captures their session id
/// from the agent's `.jsonl` file.
///
/// Why poll instead of kqueue: an earlier design used
/// `EVFILT_PROC | NOTE_EXEC` registered on the shell's pid, but the
/// shell `fork()`s and the *child* `execvp`s claude/codex — NOTE_EXEC
/// on the shell never fires for the child. NOTE_FORK + cascading
/// re-registration has a real race window (the child may exec before
/// re-registration completes). Polling sidesteps the race entirely;
/// the cost at 10 tabs × 2 ticks/sec is ~20 syscalls/sec — well
/// within the noise floor.
///
/// The timer NEVER stops once started. Each tick:
///   - If a matching agent descendant is alive and its session id is
///     unchanged → no-op.
///   - If a matched descendant is alive but its session id changed
///     (the user restarted with `claude --resume Y`) → update.
///   - If no matched descendant is found → mark
///     `wasRunningAtQuit = false` while preserving the previously
///     captured name/sessionId/jsonlPath. This is what the launch
///     planner reads to decide silent vs prefilled resume next time.
/// Process introspection surface used by `AgentSessionDetector`.
/// Production code uses `LibprocIntrospector` which talks to libproc;
/// tests inject a controlled mock so the detector logic can be
/// exercised without depending on xctest's flaky proc visibility.
public protocol ProcessIntrospector {
  /// Return the immediate children of `parent` along with each
  /// child's executable basename (the last path component of
  /// `proc_pidpath`). Order is not significant.
  func children(of parent: pid_t) -> [(pid: pid_t, basename: String)]
  /// Enumerate the absolute paths of vnode-backed file descriptors
  /// the given pid currently has open.
  func openVnodePaths(of pid: pid_t) -> [String]
  /// Return the argv vector observed for the given process. Empty
  /// when the kernel denies access or parsing fails.
  func arguments(of pid: pid_t) -> [String]
  /// Return the environment observed for the given process. Empty
  /// when the kernel denies access or parsing fails.
  func environment(of pid: pid_t) -> [String: String]
  /// Return the process cwd when visible to the current user.
  func currentWorkingDirectory(of pid: pid_t) -> String?
}

public final class AgentSessionDetector {

  public let tabId: String
  public let shellPid: pid_t
  public let tickInterval: DispatchTimeInterval
  public let queue: DispatchQueue
  public weak var observer: AgentSessionDetectorObserver?
  public let introspector: ProcessIntrospector
  private let recentSessionCutoff: Date

  private(set) var lastObservedAgent: AgentInfo?
  private var timer: DispatchSourceTimer?
  private let lock = NSLock()

  /// Recursion depth cap when walking the descendant tree. Cap = 4
  /// covers `npx claude`, `direnv exec . claude`, `time claude`, and
  /// similar one-or-two-layer wrappers without exploding for deeply
  /// nested process trees.
  public static let maxDescendantDepth: Int = 4

  public init(
    tabId: String,
    shellPid: pid_t,
    tickInterval: DispatchTimeInterval = .milliseconds(500),
    queue: DispatchQueue = DispatchQueue(label: "laban.agentdetector", qos: .utility),
    recentSessionCutoff: Date = Date(),
    introspector: ProcessIntrospector = LibprocIntrospector()
  ) {
    self.tabId = tabId
    self.shellPid = shellPid
    self.tickInterval = tickInterval
    self.queue = queue
    self.recentSessionCutoff = recentSessionCutoff
    self.introspector = introspector
  }

  deinit { stop() }

  public func start() {
    lock.lock()
    defer { lock.unlock() }
    if timer != nil { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: tickInterval)
    timer.setEventHandler { [weak self] in
      self?.tick()
    }
    self.timer = timer
    timer.resume()
  }

  /// Stop the timer. Plan calls for never-stop during a tab's life;
  /// this exists only for tab teardown.
  public func stop() {
    lock.lock()
    timer?.cancel()
    timer = nil
    lock.unlock()
  }

  private func tick() {
    handleObservation(detect())
  }

  internal func observeNow() {
    handleObservation(detect())
  }

  internal func observeNowPreservingLiveAgentOnMiss() {
    handleObservation(detect(), preserveLiveAgentOnMiss: true)
  }

  internal func detect() -> AgentInfo? {
    let descendants = collectDescendants(of: shellPid, depth: 0)
    if let agent = findAgent(in: descendants) {
      return agent
    }
    return findRecentClaudeSessionForShellCwd()
  }

  /// Walk the descendant tree of `parent` up to `Self.maxDescendantDepth`
  /// layers. Returns all observed (pid, basename) pairs.
  internal func collectDescendants(of parent: pid_t, depth: Int) -> [(pid: pid_t, basename: String)]
  {
    if depth >= Self.maxDescendantDepth { return [] }
    let immediate = introspector.children(of: parent)
    var result: [(pid: pid_t, basename: String)] = immediate
    for child in immediate {
      result.append(contentsOf: collectDescendants(of: child.pid, depth: depth + 1))
    }
    return result
  }

  /// Find the first agent descendant whose `.jsonl` yields a session
  /// id via the matching `AgentSupport` extractor. Codex keeps its
  /// rollout open, so the open-fd path is enough. Claude Code may
  /// close the session file while idle, so Claude also falls back to
  /// the newest session JSONL in the process cwd's project directory.
  internal func findAgent(in descendants: [(pid: pid_t, basename: String)]) -> AgentInfo? {
    for entry in descendants {
      let argv = introspector.arguments(of: entry.pid)
      guard let support = AgentRegistry.agent(forBinaryBasename: entry.basename, arguments: argv)
      else {
        continue
      }
      let env = AgentEnvironmentSanitizer.sanitize(introspector.environment(of: entry.pid))
      let cwd = introspector.currentWorkingDirectory(of: entry.pid)
      for path in introspector.openVnodePaths(of: entry.pid) where path.hasSuffix(".jsonl") {
        if let sessionId = support.extractSessionId(path) {
          return AgentInfo(
            name: support.name,
            sessionId: sessionId,
            jsonlPath: path,
            wasRunningAtQuit: true,
            argv: argv,
            env: env,
            cwd: cwd
          )
        }
      }
      if support.name == .claude,
        let cwd,
        let path = ClaudeSessionLogLocator.newestSessionLog(cwd: cwd),
        let sessionId = support.extractSessionId(path)
      {
        return AgentInfo(
          name: support.name,
          sessionId: sessionId,
          jsonlPath: path,
          wasRunningAtQuit: true,
          argv: argv,
          env: env,
          cwd: cwd
        )
      }
    }
    return nil
  }

  internal func findRecentClaudeSessionForShellCwd() -> AgentInfo? {
    guard let support = AgentRegistry.entry(for: .claude),
      let cwd = introspector.currentWorkingDirectory(of: shellPid),
      let path = ClaudeSessionLogLocator.newestSessionLog(
        cwd: cwd, modifiedAfter: recentSessionCutoff),
      let sessionId = support.extractSessionId(path)
    else { return nil }

    let metadata = ClaudeSessionLogLocator.metadata(fromLogAt: path)
    var argv = ["claude"]
    if let model = metadata.model, !model.isEmpty {
      argv += ["--model", model]
    }
    if metadata.permissionMode == "bypassPermissions" {
      argv.append("--dangerously-skip-permissions")
    }

    return AgentInfo(
      name: .claude,
      sessionId: sessionId,
      jsonlPath: path,
      wasRunningAtQuit: false,
      argv: argv,
      env: AgentEnvironmentSanitizer.sanitize(introspector.environment(of: shellPid)),
      cwd: metadata.cwd ?? cwd
    )
  }

  internal func handleObservation(
    _ detected: AgentInfo?,
    preserveLiveAgentOnMiss: Bool = false
  ) {
    lock.lock()
    let prior = lastObservedAgent
    let next: AgentInfo?
    if let detected {
      next = detected
    } else if preserveLiveAgentOnMiss, prior?.wasRunningAtQuit == true {
      next = prior
    } else if let prior {
      // Lost: preserve identity but mark not-alive.
      var dead = prior
      dead.wasRunningAtQuit = false
      next = dead
    } else {
      next = nil
    }
    let changed = (next != prior)
    lastObservedAgent = next
    lock.unlock()
    if changed, let observer {
      observer.agentSessionDetector(self, didObserve: next)
    }
  }

  // MARK: - libproc bridging (legacy in-class helpers; kept for back-
  // compat with any caller that still wants the raw libproc surface
  // from inside the detector. New code should go through
  // `introspector`.)

  /// `proc_listpids(PROC_PPID_ONLY, ...)` lists children of `parent`.
  private func childrenOf(parent: pid_t) -> [pid_t] {
    let count = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent), nil, 0)
    guard count > 0 else { return [] }
    let cap = Int(count) / MemoryLayout<pid_t>.size + 64
    var buffer = [pid_t](repeating: 0, count: cap)
    let bytes = buffer.withUnsafeMutableBufferPointer { buf -> Int32 in
      proc_listpids(
        UInt32(PROC_PPID_ONLY), UInt32(parent), buf.baseAddress,
        Int32(buf.count * MemoryLayout<pid_t>.size))
    }
    guard bytes > 0 else { return [] }
    let n = Int(bytes) / MemoryLayout<pid_t>.size
    return Array(buffer.prefix(n)).filter { $0 > 0 && $0 != parent }
  }

  private func basenameOf(pid: pid_t) -> String? {
    // PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN (defined in
    // <sys/proc_info.h>) but the symbol isn't surfaced by the
    // Darwin Swift module. Hard-coded mirror of the C value.
    let cap = Int(MAXPATHLEN) * 4
    var path = [CChar](repeating: 0, count: cap)
    let n = path.withUnsafeMutableBufferPointer { buf in
      proc_pidpath(pid, buf.baseAddress, UInt32(buf.count))
    }
    guard n > 0 else { return nil }
    let exe = String(cString: path)
    guard !exe.isEmpty else { return nil }
    if let slash = exe.lastIndex(of: "/") {
      return String(exe[exe.index(after: slash)...])
    }
    return exe
  }

  /// Enumerate open file descriptors for `pid` and resolve each to
  /// its vnode path via `PROC_PIDFDVNODEPATHINFO`.
  private func openVnodePaths(pid: pid_t) -> [String] {
    let sizeNeeded = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard sizeNeeded > 0 else { return [] }
    let capacity = Int(sizeNeeded) + 64 * MemoryLayout<proc_fdinfo>.size
    let fdCount = capacity / MemoryLayout<proc_fdinfo>.size
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: fdCount)
    let bytes = fds.withUnsafeMutableBufferPointer { buf -> Int32 in
      guard let base = buf.baseAddress else { return -1 }
      return proc_pidinfo(pid, PROC_PIDLISTFDS, 0, base, Int32(capacity))
    }
    guard bytes > 0 else { return [] }
    let count = Int(bytes) / MemoryLayout<proc_fdinfo>.size

    var paths: [String] = []
    paths.reserveCapacity(count)
    for i in 0..<count {
      let fd = fds[i].proc_fd
      let type = fds[i].proc_fdtype
      // Only vnode fds carry file paths. Skip sockets, pipes, etc.
      guard Int32(type) == PROX_FDTYPE_VNODE else { continue }
      var info = vnode_fdinfowithpath()
      let infoSize = MemoryLayout<vnode_fdinfowithpath>.size
      let got = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
        proc_pidfdinfo(
          pid, fd, PROC_PIDFDVNODEPATHINFO, ptr, Int32(infoSize))
      }
      guard got > 0 else { continue }
      let path = withUnsafePointer(to: &info.pvip.vip_path) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
          String(cString: $0)
        }
      }
      if !path.isEmpty {
        paths.append(path)
      }
    }
    return paths
  }
}

public struct ClaudeSessionLogMetadata: Equatable {
  public var model: String?
  public var permissionMode: String?
  public var cwd: String?
  public init() {}
}

public enum ClaudeSessionLogLocator {
  public static func newestSessionLog(
    cwd: String,
    fileManager: FileManager = .default,
    modifiedAfter: Date? = nil
  ) -> String? {
    let projectURL = projectsRoot(fileManager: fileManager)
      .appendingPathComponent(encodedProjectName(for: cwd), isDirectory: true)
    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: projectURL,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles])
    else { return nil }

    return
      entries
      .filter {
        $0.pathExtension == "jsonl"
          && AgentSupport.isUUID($0.deletingPathExtension().lastPathComponent)
      }
      .compactMap { url -> (url: URL, modified: Date)? in
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        let modified = values?.contentModificationDate
        guard let modified else { return nil }
        if let modifiedAfter, modified < modifiedAfter { return nil }
        return (url, modified)
      }
      .max { lhs, rhs in lhs.modified < rhs.modified }?
      .url.path
  }

  public static func metadata(fromLogAt path: String, maxLines: Int = 64)
    -> ClaudeSessionLogMetadata
  {
    // Read just enough of the file to likely contain `maxLines` JSONL
    // records. The old implementation read the entire file into a Swift
    // String (cost: ~243 ms on a 17 MB session log) just to take
    // .prefix(64) lines, because String/split walks the whole UTF-8
    // string before slicing. Capping the read makes this O(needed
    // bytes), not O(file size).
    //
    // 96 KiB is comfortable: a typical Claude JSONL record is 0.5–2 KB,
    // so 64 records fit well under this ceiling. Records that overflow
    // are simply not parsed by this poll; the next field will be picked
    // up on a subsequent tick if/when the file shrinks below the cap.
    let maxBytes = 96 * 1024
    guard let fh = FileHandle(forReadingAtPath: path) else {
      return ClaudeSessionLogMetadata()
    }
    defer { try? fh.close() }
    let buf: Data
    do {
      buf = try fh.read(upToCount: maxBytes) ?? Data()
    } catch {
      return ClaudeSessionLogMetadata()
    }
    if buf.isEmpty { return ClaudeSessionLogMetadata() }

    var metadata = ClaudeSessionLogMetadata()
    var lineStart = 0
    var linesParsed = 0
    buf.withUnsafeBytes { raw in
      guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
      let count = raw.count
      var i = 0
      while i < count {
        if base[i] != 0x0A {  // newline
          i += 1
          continue
        }
        if i > lineStart {
          let slice = Data(bytes: base + lineStart, count: i - lineStart)
          if let object = try? JSONSerialization.jsonObject(with: slice) as? [String: Any] {
            if metadata.permissionMode == nil {
              metadata.permissionMode = object["permissionMode"] as? String
            }
            if metadata.model == nil {
              metadata.model = object["advisorModel"] as? String
              if metadata.model == nil,
                let message = object["message"] as? [String: Any]
              {
                metadata.model = message["model"] as? String
              }
            }
            if metadata.cwd == nil {
              metadata.cwd = object["cwd"] as? String
            }
            if metadata.permissionMode != nil, metadata.model != nil, metadata.cwd != nil {
              return
            }
          }
        }
        linesParsed += 1
        if linesParsed >= maxLines { return }
        lineStart = i + 1
        i += 1
      }
    }
    return metadata
  }

  static func encodedProjectName(for cwd: String) -> String {
    cwd.unicodeScalars.map { scalar in
      if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" {
        return String(scalar)
      }
      return "-"
    }.joined()
  }

  private static func projectsRoot(fileManager: FileManager) -> URL {
    if let override = AgentSupport.envOverride("CLAUDE_CONFIG_DIR") {
      return URL(fileURLWithPath: override).appendingPathComponent("projects", isDirectory: true)
    }
    return fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent(".claude", isDirectory: true)
      .appendingPathComponent("projects", isDirectory: true)
  }
}

public protocol AgentSessionDetectorObserver: AnyObject {
  func agentSessionDetector(
    _ detector: AgentSessionDetector, didObserve agent: AgentInfo?)
}

/// Production introspector backed by `libproc`. Maps the
/// `ProcessIntrospector` protocol calls onto `proc_listpids`,
/// `proc_pidpath`, `proc_pidinfo`, and `proc_pidfdinfo`.
public struct LibprocIntrospector: ProcessIntrospector {

  public init() {}

  public func children(of parent: pid_t) -> [(pid: pid_t, basename: String)] {
    let pids = childPids(of: parent)
    var result: [(pid: pid_t, basename: String)] = []
    result.reserveCapacity(pids.count)
    for pid in pids {
      if let basename = basenameOf(pid: pid) {
        result.append((pid, basename))
      }
    }
    return result
  }

  public func openVnodePaths(of pid: pid_t) -> [String] {
    let sizeNeeded = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard sizeNeeded > 0 else { return [] }
    let capacity = Int(sizeNeeded) + 64 * MemoryLayout<proc_fdinfo>.size
    let fdCount = capacity / MemoryLayout<proc_fdinfo>.size
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: fdCount)
    let bytes = fds.withUnsafeMutableBufferPointer { buf -> Int32 in
      guard let base = buf.baseAddress else { return -1 }
      return proc_pidinfo(pid, PROC_PIDLISTFDS, 0, base, Int32(capacity))
    }
    guard bytes > 0 else { return [] }
    let count = Int(bytes) / MemoryLayout<proc_fdinfo>.size

    var paths: [String] = []
    paths.reserveCapacity(count)
    for i in 0..<count {
      let fd = fds[i].proc_fd
      let type = fds[i].proc_fdtype
      guard Int32(type) == PROX_FDTYPE_VNODE else { continue }
      var info = vnode_fdinfowithpath()
      let infoSize = MemoryLayout<vnode_fdinfowithpath>.size
      let got = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
        proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, ptr, Int32(infoSize))
      }
      guard got > 0 else { continue }
      let path = withUnsafePointer(to: &info.pvip.vip_path) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
          String(cString: $0)
        }
      }
      if !path.isEmpty { paths.append(path) }
    }
    return paths
  }

  public func arguments(of pid: pid_t) -> [String] {
    processArgumentsAndEnvironment(of: pid).arguments
  }

  public func environment(of pid: pid_t) -> [String: String] {
    processArgumentsAndEnvironment(of: pid).environment
  }

  public func currentWorkingDirectory(of pid: pid_t) -> String? {
    var info = proc_vnodepathinfo()
    let infoSize = MemoryLayout<proc_vnodepathinfo>.size
    let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
      proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, ptr, Int32(infoSize))
    }
    guard rc == Int32(infoSize) else { return nil }
    let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
      $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
        String(cString: $0)
      }
    }
    return path.isEmpty ? nil : path
  }

  private func childPids(of parent: pid_t) -> [pid_t] {
    let count = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent), nil, 0)
    guard count > 0 else { return [] }
    let cap = Int(count) / MemoryLayout<pid_t>.size + 64
    var buffer = [pid_t](repeating: 0, count: cap)
    let bytes = buffer.withUnsafeMutableBufferPointer { buf -> Int32 in
      proc_listpids(
        UInt32(PROC_PPID_ONLY), UInt32(parent), buf.baseAddress,
        Int32(buf.count * MemoryLayout<pid_t>.size))
    }
    guard bytes > 0 else { return [] }
    let n = Int(bytes) / MemoryLayout<pid_t>.size
    return Array(buffer.prefix(n)).filter { $0 > 0 && $0 != parent }
  }

  private func basenameOf(pid: pid_t) -> String? {
    let cap = Int(MAXPATHLEN) * 4
    var path = [CChar](repeating: 0, count: cap)
    let n = path.withUnsafeMutableBufferPointer { buf in
      proc_pidpath(pid, buf.baseAddress, UInt32(buf.count))
    }
    guard n > 0 else { return nil }
    let exe = String(cString: path)
    guard !exe.isEmpty else { return nil }
    if let slash = exe.lastIndex(of: "/") {
      return String(exe[exe.index(after: slash)...])
    }
    return exe
  }

  private func processArgumentsAndEnvironment(of pid: pid_t) -> (
    arguments: [String], environment: [String: String]
  ) {
    var mib = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
    var size = 0
    guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
      return ([], [:])
    }

    var buffer = [UInt8](repeating: 0, count: size)
    let rc = buffer.withUnsafeMutableBytes { rawBuffer -> Int32 in
      sysctl(&mib, u_int(mib.count), rawBuffer.baseAddress, &size, nil, 0)
    }
    guard rc == 0, size >= MemoryLayout<Int32>.size else {
      return ([], [:])
    }

    let bytes = Array(buffer.prefix(size))
    var argc: Int32 = 0
    withUnsafeMutableBytes(of: &argc) { dst in
      dst.copyBytes(from: bytes.prefix(MemoryLayout<Int32>.size))
    }
    guard argc >= 0 else { return ([], [:]) }

    var index = MemoryLayout<Int32>.size
    skipString(in: bytes, index: &index)
    skipNuls(in: bytes, index: &index)

    var arguments: [String] = []
    for _ in 0..<Int(argc) {
      skipNuls(in: bytes, index: &index)
      guard let value = readCString(in: bytes, index: &index), !value.isEmpty else {
        break
      }
      arguments.append(value)
    }

    var environment: [String: String] = [:]
    while index < bytes.count {
      skipNuls(in: bytes, index: &index)
      guard index < bytes.count else { break }
      guard let value = readCString(in: bytes, index: &index), !value.isEmpty else {
        break
      }
      guard let equals = value.firstIndex(of: "=") else { continue }
      let name = String(value[..<equals])
      let envValue = String(value[value.index(after: equals)...])
      environment[name] = envValue
    }
    return (arguments, environment)
  }

  private func readCString(in bytes: [UInt8], index: inout Int) -> String? {
    let start = index
    while index < bytes.count && bytes[index] != 0 {
      index += 1
    }
    guard index <= bytes.count else { return nil }
    let end = index
    if index < bytes.count { index += 1 }
    guard end > start else { return "" }
    return String(bytes: bytes[start..<end], encoding: .utf8)
  }

  private func skipString(in bytes: [UInt8], index: inout Int) {
    while index < bytes.count && bytes[index] != 0 {
      index += 1
    }
    if index < bytes.count { index += 1 }
  }

  private func skipNuls(in bytes: [UInt8], index: inout Int) {
    while index < bytes.count && bytes[index] == 0 {
      index += 1
    }
  }
}
