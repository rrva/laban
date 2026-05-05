import AppKit
import Foundation
import OSLog

/// Bundles a one-file diagnostic dump for bug reports: build info,
/// recent stall captures, recent event log, recent OSLog excerpt,
/// system info. Writes a `.tar.gz` to the Desktop and reveals it in
/// Finder so the user can drop it into a chat.
///
/// Designed to be triggered from a menu item — no UI prompts, no
/// network. The user always sees the file before sending it.
enum SendDiagnostics {

  /// Run the bundle on a background queue and reveal the result on main.
  /// Safe to call repeatedly; each invocation produces a fresh file.
  static func run() {
    DispatchQueue.global(qos: .userInitiated).async {
      let result = build()
      DispatchQueue.main.async { reveal(result) }
    }
  }

  // MARK: - Bundle

  private struct Result {
    var url: URL?
    var error: String?
  }

  private static func build() -> Result {
    let fm = FileManager.default
    let stamp = Self.stampString()
    let stagingURL = fm.temporaryDirectory
      .appendingPathComponent("laban-diag-\(stamp)")
    do {
      try fm.createDirectory(at: stagingURL, withIntermediateDirectories: true)
    } catch {
      return Result(error: "create staging: \(error)")
    }
    defer { try? fm.removeItem(at: stagingURL) }

    // 1. Build / system / runtime info — every field someone would ask
    //    for if you sent them just an OSLog excerpt and they had to ask
    //    "what was your setup again."
    let resident = residentMemoryMB()
    let info = """
      laban diagnostics
      generated:    \(stamp)
      build:        \(BuildInfo.summary)
      pid:          \(ProcessInfo.processInfo.processIdentifier)
      uptime:       \(uptimeString())
      os:           \(ProcessInfo.processInfo.operatingSystemVersionString)
      kernel:       \(sysctlString("kern.osrelease"))
      machine:      \(machineModel())
      cpu:          \(sysctlString("machdep.cpu.brand_string"))
      cores:        \(ProcessInfo.processInfo.activeProcessorCount)
      memory:       \(physicalMemoryGB()) GB physical, \(resident) MB resident
      locale:       \(Locale.current.identifier)
      timezone:     \(TimeZone.current.identifier)
      displays:     \(displaySummary())
      libghostty:   \(libghosttyCommit())
      """
    try? info.write(
      to: stagingURL.appendingPathComponent("info.txt"),
      atomically: true, encoding: .utf8)

    // 1a. Crash reports for our process (ips files in DiagnosticReports).
    //     macOS keeps these even after the bad process is gone, which is
    //     often the only record of a kill-9'd freeze.
    let drURL = fm.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/DiagnosticReports")
    if let entries = try? fm.contentsOfDirectory(atPath: drURL.path) {
      let copyDir = stagingURL.appendingPathComponent("crash-reports")
      let candidates = entries.filter { $0.lowercased().hasPrefix("labanapp") }
      if !candidates.isEmpty {
        try? fm.createDirectory(at: copyDir, withIntermediateDirectories: true)
        for name in candidates {
          try? fm.copyItem(
            at: drURL.appendingPathComponent(name),
            to: copyDir.appendingPathComponent(name))
        }
      }
    }

    // 1b. App preferences (theme picks, follows-system flag, …) so we
    //     can reproduce the user's configured state.
    if let plist = UserDefaults.standard.persistentDomain(forName: "com.laban.LabanApp"),
      let data = try? PropertyListSerialization.data(
        fromPropertyList: plist, format: .xml, options: 0)
    {
      try? data.write(to: stagingURL.appendingPathComponent("defaults.plist"))
    }

    // 2. Watchdog samples (last 10 by mtime; both inproc-stall and
    //    rolling external samples if any).
    let watchdogDir = fm.homeDirectoryForCurrentUser
      .appendingPathComponent("laban-watchdog")
    if let entries = try? fm.contentsOfDirectory(
      at: watchdogDir,
      includingPropertiesForKeys: [.contentModificationDateKey]
    ) {
      let sorted = entries.sorted {
        let a =
          (try? $0.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? Date.distantPast
        let b =
          (try? $1.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? Date.distantPast
        return a > b
      }
      let copyDir = stagingURL.appendingPathComponent("watchdog")
      try? fm.createDirectory(at: copyDir, withIntermediateDirectories: true)
      for url in sorted.prefix(10) {
        try? fm.copyItem(
          at: url, to: copyDir.appendingPathComponent(url.lastPathComponent))
      }
    }

    // 3. Event log (whatever we have on disk; pruning keeps it bounded).
    let eventDir = EventLog.shared.directoryURL
    if let entries = try? fm.contentsOfDirectory(at: eventDir, includingPropertiesForKeys: nil) {
      let copyDir = stagingURL.appendingPathComponent("events")
      try? fm.createDirectory(at: copyDir, withIntermediateDirectories: true)
      for url in entries {
        try? fm.copyItem(
          at: url, to: copyDir.appendingPathComponent(url.lastPathComponent))
      }
    }

    // 4. App log files (rolling 7-day text log mirrored from AppLog).
    //    OSLogStore and `log show` both refuse to read for an
    //    unprivileged user, so AppLog writes a sidecar text file we
    //    can always bundle.
    let logSrc = LogFile.shared.directoryURL
    if let entries = try? fm.contentsOfDirectory(at: logSrc, includingPropertiesForKeys: nil) {
      let copyDir = stagingURL.appendingPathComponent("log")
      try? fm.createDirectory(at: copyDir, withIntermediateDirectories: true)
      for url in entries {
        try? fm.copyItem(
          at: url, to: copyDir.appendingPathComponent(url.lastPathComponent))
      }
    }

    // 5. Tar everything up. Output goes to the Desktop so the user
    //    sees it immediately.
    let outURL = fm.homeDirectoryForCurrentUser
      .appendingPathComponent("Desktop")
      .appendingPathComponent("laban-diag-\(stamp).tar.gz")
    let tar = Process()
    tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    tar.arguments = [
      "-czf", outURL.path,
      "-C", stagingURL.deletingLastPathComponent().path,
      stagingURL.lastPathComponent,
    ]
    tar.standardOutput = Pipe()
    tar.standardError = Pipe()
    do {
      try tar.run()
      tar.waitUntilExit()
      guard tar.terminationStatus == 0 else {
        return Result(error: "tar exited \(tar.terminationStatus)")
      }
    } catch {
      return Result(error: "tar: \(error)")
    }
    return Result(url: outURL)
  }

  // MARK: - Reveal

  private static func reveal(_ result: Result) {
    if let url = result.url {
      EventLog.shared.log("diagnostics.bundle", ["path": url.path])
      AppLog.app.info("diagnostics bundle written to \(url.path)")
      NSWorkspace.shared.activateFileViewerSelecting([url])
    } else {
      let msg = result.error ?? "unknown error"
      AppLog.app.error("diagnostics bundle failed: \(msg)")
      let alert = NSAlert()
      alert.messageText = "Send Diagnostics failed"
      alert.informativeText = msg
      alert.addButton(withTitle: "OK")
      alert.runModal()
    }
  }

  // MARK: - Helpers

  private static func stampString() -> String {
    var tv = timeval()
    gettimeofday(&tv, nil)
    var t = time_t(tv.tv_sec)
    var tm = tm()
    localtime_r(&t, &tm)
    return String(
      format: "%04d%02d%02d-%02d%02d%02d",
      tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
      tm.tm_hour, tm.tm_min, tm.tm_sec)
  }

  private static let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
  private static func isoMs(_ d: Date) -> String { isoFormatter.string(from: d) }

  private static func machineModel() -> String { sysctlString("hw.model") }

  private static func sysctlString(_ name: String) -> String {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    guard size > 0 else { return "?" }
    var bytes = [CChar](repeating: 0, count: size)
    sysctlbyname(name, &bytes, &size, nil, 0)
    return String(cString: bytes)
  }

  private static func physicalMemoryGB() -> String {
    let bytes = ProcessInfo.processInfo.physicalMemory
    return String(format: "%.1f", Double(bytes) / 1_073_741_824.0)
  }

  private static func residentMemoryMB() -> String {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
      ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    guard kr == KERN_SUCCESS else { return "?" }
    return String(format: "%.0f", Double(info.resident_size) / 1_048_576.0)
  }

  private static func uptimeString() -> String {
    let seconds = Int(ProcessInfo.processInfo.systemUptime)
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    let s = seconds % 60
    return "\(h)h\(m)m\(s)s"
  }

  private static func displaySummary() -> String {
    NSScreen.screens.enumerated().map { (i, screen) in
      let f = screen.frame
      let scale = screen.backingScaleFactor
      return "[\(i)] \(Int(f.width))x\(Int(f.height))@\(scale)x"
    }.joined(separator: " ")
  }

  /// Best-effort: read the pinned commit out of scripts/fetch-libghostty-vt
  /// so we can correlate snapshot stacks with libghostty source. Falls
  /// back to "unknown" if the script isn't where we expect.
  private static func libghosttyCommit() -> String {
    let candidates = [
      Bundle.main.bundlePath + "/Contents/Resources/fetch-libghostty-vt",
      "/Users/rrj/wrk/laban/scripts/fetch-libghostty-vt",
    ]
    for path in candidates {
      guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
      for line in text.split(separator: "\n") {
        if line.contains("GHOSTTY_COMMIT=") {
          let parts = line.split(separator: "\"")
          if parts.count >= 2 { return String(parts[1].prefix(12)) }
        }
      }
    }
    return "unknown"
  }
}
