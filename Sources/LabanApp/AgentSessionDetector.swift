import Darwin
import Foundation
import LabanCore
import LabanTerminalCore

/// Per-tab background poller that watches the tab's shell descendants
/// for `claude` / `codex` processes and captures their session id
/// from the open `.jsonl` file the agent holds.
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
}

public final class AgentSessionDetector {

  public let tabId: String
  public let shellPid: pid_t
  public let tickInterval: DispatchTimeInterval
  public let queue: DispatchQueue
  public weak var observer: AgentSessionDetectorObserver?
  public let introspector: ProcessIntrospector

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
    introspector: ProcessIntrospector = LibprocIntrospector()
  ) {
    self.tabId = tabId
    self.shellPid = shellPid
    self.tickInterval = tickInterval
    self.queue = queue
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
    let descendants = collectDescendants(of: shellPid, depth: 0)
    let detected = findAgent(in: descendants)
    handleObservation(detected)
  }

  /// Walk the descendant tree of `parent` up to `Self.maxDescendantDepth`
  /// layers. Returns all observed (pid, basename) pairs.
  internal func collectDescendants(of parent: pid_t, depth: Int) -> [(pid: pid_t, basename: String)] {
    if depth >= Self.maxDescendantDepth { return [] }
    let immediate = introspector.children(of: parent)
    var result: [(pid: pid_t, basename: String)] = immediate
    for child in immediate {
      result.append(contentsOf: collectDescendants(of: child.pid, depth: depth + 1))
    }
    return result
  }

  /// Find the first agent descendant whose open `.jsonl` fd yields a
  /// session id via the matching `AgentSupport.extractSessionId`
  /// extractor. Returns nil when no descendant matches.
  internal func findAgent(in descendants: [(pid: pid_t, basename: String)]) -> AgentInfo? {
    for entry in descendants {
      guard let support = AgentRegistry.agent(forBinaryBasename: entry.basename) else {
        continue
      }
      for path in introspector.openVnodePaths(of: entry.pid) where path.hasSuffix(".jsonl") {
        if let sessionId = support.extractSessionId(path) {
          return AgentInfo(
            name: support.name,
            sessionId: sessionId,
            jsonlPath: path,
            wasRunningAtQuit: true
          )
        }
      }
    }
    return nil
  }

  internal func handleObservation(_ detected: AgentInfo?) {
    lock.lock()
    let prior = lastObservedAgent
    let next: AgentInfo?
    if let detected {
      // Liveness signal: just observed alive.
      next = AgentInfo(
        name: detected.name,
        sessionId: detected.sessionId,
        jsonlPath: detected.jsonlPath,
        wasRunningAtQuit: true
      )
    } else if let prior {
      // Lost: preserve identity but mark not-alive.
      next = AgentInfo(
        name: prior.name,
        sessionId: prior.sessionId,
        jsonlPath: prior.jsonlPath,
        wasRunningAtQuit: false
      )
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
}
