import Darwin
import LabanRenderer
import LabanTerminalCore
import Metal
import Security

/// Diagnostics shared by the Diagnostics window and `laban version --verbose`:
/// how this build is made and signed, the component stack it runs on, the
/// session daemons serving it, and what programs are told. Values come from
/// the live process and system, never from constants that could drift from
/// what actually shipped. AppKit-only facts (renderer, display, theme) are
/// added by the app.
public enum LabanDiagnostics {
  // MARK: - Code signing

  public struct CodeSigning: Equatable {
    public enum Kind: Equatable {
      case unsigned
      case adHoc
      /// Signed by a certificate; the name is its common name, e.g.
      /// "Developer ID Application: Ragnar Rova (3563RJWBQP)".
      case certificate(String)
    }

    public var kind: Kind
    public var teamID: String?
    public var hardenedRuntime: Bool
    public var notarized: Bool

    public var summary: String {
      switch kind {
      case .unsigned: return "Not signed"
      case .adHoc: return "Ad-hoc signature (local build, no team identity)"
      case .certificate(let name): return name
      }
    }

    public var details: String {
      var parts: [String] = []
      if let teamID { parts.append("team \(teamID)") }
      parts.append(hardenedRuntime ? "hardened runtime" : "no hardened runtime")
      parts.append(notarized ? "notarized" : "not notarized")
      return parts.joined(separator: ", ")
    }
  }

  /// Reads the running app's signature (`SecCodeCopySelf`), not the bundle on
  /// disk, which an install or update may already have replaced.
  public static func codeSigning() -> CodeSigning {
    var selfCode: SecCode?
    guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else {
      return CodeSigning(kind: .unsigned, teamID: nil, hardenedRuntime: false, notarized: false)
    }
    // SecCode is a SecStaticCode in C; Swift needs the cast. Querying the
    // running code keeps the answer about this process, not the file on disk.
    return codeSigning(for: unsafeBitCast(selfCode, to: SecStaticCode.self))
  }

  /// Signature of a bundle or binary on disk.
  public static func codeSigning(bundleURL: URL) -> CodeSigning {
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
      let staticCode
    else {
      return CodeSigning(kind: .unsigned, teamID: nil, hardenedRuntime: false, notarized: false)
    }
    return codeSigning(for: staticCode)
  }

  private static func codeSigning(for code: SecStaticCode) -> CodeSigning {
    var rawInfo: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        code, SecCSFlags(rawValue: kSecCSSigningInformation), &rawInfo) == errSecSuccess,
      let info = rawInfo as? [String: Any],
      info[kSecCodeInfoIdentifier as String] != nil
    else {
      return CodeSigning(kind: .unsigned, teamID: nil, hardenedRuntime: false, notarized: false)
    }
    let flags = (info[kSecCodeInfoFlags as String] as? UInt32) ?? 0
    let adHocFlag: UInt32 = 0x0002  // kSecCodeSignatureAdhoc
    let runtimeFlag: UInt32 = 0x1_0000  // kSecCodeSignatureRuntime
    let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
    let kind: CodeSigning.Kind
    if flags & adHocFlag != 0 || certificates.isEmpty {
      kind = .adHoc
    } else {
      // The first certificate is the leaf (the signing certificate).
      let name = SecCertificateCopySubjectSummary(certificates[0]) as String? ?? "Unknown certificate"
      kind = .certificate(name)
    }
    var notarized = false
    var requirement: SecRequirement?
    if kind != .adHoc,
      SecRequirementCreateWithString("notarized" as CFString, [], &requirement) == errSecSuccess,
      let requirement
    {
      notarized = SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
    return CodeSigning(
      kind: kind,
      teamID: info[kSecCodeInfoTeamIdentifier as String] as? String,
      hardenedRuntime: flags & runtimeFlag != 0,
      notarized: notarized)
  }

  // MARK: - VT core

  public struct VTCore: Equatable {
    public var commit: String
    public var patches: [String]

    public var summary: String {
      let short = commit.isEmpty ? "unknown" : String(commit.prefix(9))
      let patchCount = patches.count == 1 ? "1 local patch" : "\(patches.count) local patches"
      return "libghostty-vt \(short) (Ghostty), \(patchCount)"
    }
  }

  /// The Ghostty commit and local patches `build-app` stamped into Info.plist.
  public static func vtCore(bundle: Bundle = .main) -> VTCore {
    let commit = bundle.object(forInfoDictionaryKey: "LABANLibghosttyCommit") as? String ?? ""
    let patches =
      (bundle.object(forInfoDictionaryKey: "LABANLibghosttyPatches") as? String ?? "")
      .split(separator: ",").map { String($0).replacingOccurrences(of: "libghostty-vt-", with: "") }
    return VTCore(commit: commit, patches: patches)
  }

  // MARK: - Session daemon

  public struct SessionDaemon: Equatable {
    public var pid: pid_t
    public var startedAt: Date
    /// The binary the daemon was launched from, as the kernel reports it.
    public var executablePath: String
    /// True when the daemon was launched from this app's own `labpty`.
    public var isThisAppsBinary: Bool
    /// True when the binary the daemon has mapped is not the file now
    /// installed as this app's `labpty` (an install or rebuild replaced it,
    /// so the daemon runs an older build). Compared by file identity: the
    /// running process keeps the replaced file mapped. The daemon keeps
    /// running across app restarts by design (it owns the shells) and
    /// switches when it is next started. nil when either side is unreadable.
    public var runsDifferentBuild: Bool?
  }

  /// Every `labpty` session daemon of this user, wherever it was launched
  /// from: another install of the app shares the same session socket.
  public static func sessionDaemons(
    labptyURL: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/labpty")
  ) -> [SessionDaemon] {
    // Kernel-reported paths are not symlink-resolved (/private/tmp stays
    // /private/tmp), so compare against the standardized, unresolved path.
    let installedPath = labptyURL.standardizedFileURL.path
    let installedFile = fileIdentity(atPath: labptyURL.path)
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(count) * 2)
    let listed = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard listed > 0 else { return [] }
    let uid = getuid()
    var daemons: [SessionDaemon] = []
    var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    for pid in pids.prefix(Int(listed)) where pid > 0 {
      guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else { continue }
      let path = String(cString: pathBuffer)
      guard (path as NSString).lastPathComponent == "labpty" else { continue }
      var info = proc_bsdinfo()
      let size = Int32(MemoryLayout<proc_bsdinfo>.size)
      guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == uid
      else { continue }
      let started = Date(
        timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
          + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
      let runningFile = mappedExecutableIdentity(pid: pid, path: path)
      let differs: Bool? =
        if let runningFile, let installedFile { runningFile != installedFile } else { nil }
      daemons.append(
        SessionDaemon(
          pid: pid, startedAt: started, executablePath: path,
          isThisAppsBinary: path == installedPath, runsDifferentBuild: differs))
    }
    return daemons.sorted { $0.pid < $1.pid }
  }

  public struct FileIdentity: Equatable {
    public var device: UInt64
    public var inode: UInt64
  }

  public static func fileIdentity(atPath path: String) -> FileIdentity? {
    var info = stat()
    guard stat(path, &info) == 0 else { return nil }
    return FileIdentity(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: info.st_ino)
  }

  /// Identity of the file a process has mapped as its executable, found by
  /// walking its memory regions to the one backed by `path`. This is the file
  /// the process actually runs, even after that path was replaced on disk.
  public static func mappedExecutableIdentity(pid: pid_t, path: String) -> FileIdentity? {
    var address: UInt64 = 0
    let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
    for _ in 0..<256 {
      var region = proc_regionwithpathinfo()
      guard proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, address, &region, size) == size else {
        return nil
      }
      let regionPath = withUnsafePointer(to: &region.prp_vip.vip_path) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
      }
      if regionPath == path {
        let stat = region.prp_vip.vip_vi.vi_stat
        return FileIdentity(device: UInt64(stat.vst_dev), inode: stat.vst_ino)
      }
      let next = region.prp_prinfo.pri_address + region.prp_prinfo.pri_size
      guard next > address else { return nil }
      address = next
    }
    return nil
  }

  // MARK: - System, font and theme

  /// "macOS 27.0 (Build 26A5406c), arm64" plus a Rosetta note when this
  /// process runs translated.
  public static func systemSummary() -> String {
    let os = ProcessInfo.processInfo.operatingSystemVersionString
      .replacingOccurrences(of: "Version ", with: "")
    var machine = [CChar](repeating: 0, count: 64)
    var size = machine.count
    let arch =
      sysctlbyname("hw.machine", &machine, &size, nil, 0) == 0
      ? String(cString: machine) : "unknown architecture"
    var translated: Int32 = 0
    var translatedSize = MemoryLayout<Int32>.size
    let rosetta =
      sysctlbyname("sysctl.proc_translated", &translated, &translatedSize, nil, 0) == 0
      && translated == 1
    return "macOS \(os), \(arch)\(rosetta ? " (running under Rosetta)" : "")"
  }

  /// The terminal font as configured: the user's font name, or the bundled
  /// JetBrains Mono, at the persisted point size.
  public static func fontSummary(defaults: UserDefaults = .standard) -> String {
    let name =
      (defaults.string(forKey: FontAtlas.userFontKey)).flatMap { $0.isEmpty ? nil : $0 }
      ?? "JetBrains Mono (bundled)"
    let size = FontAtlas.terminalPointSize(from: defaults)
    let points = size == size.rounded() ? String(Int(size)) : String(format: "%.1f", size)
    return "\(name), \(points) pt"
  }

  // MARK: - GPU and display

  public static func gpuName() -> String {
    MTLCreateSystemDefaultDevice()?.name ?? "No Metal device"
  }

  // MARK: - What programs see

  /// Terminal type every session advertises (`session_lifecycle.c`).
  public static let terminalType = "xterm-256color"

  public static func terminalProgram() -> String {
    let identity = TerminalIdentitySettings.identity()
    let note = identity == .ghosttyCompat ? " (Ghostty compatibility mode)" : ""
    return "\(identity.termProgram) \(identity.termProgramVersion)\(note)"
  }

  /// The gate sessions are actually created with (applied at launch from
  /// `KittyGraphicsSettings`), not the persisted setting, which only takes
  /// effect on the next launch.
  /// `imagesInUse` is known only inside the app, whose sessions hold images.
  public static func kittyGraphicsSummary(imagesInUse: Int? = nil) -> String {
    guard laban_kitty_graphics_enabled() else {
      return "Off (turned off by the LabanKittyGraphicsEnabled default or LABAN_KITTY_GRAPHICS=0)"
    }
    guard let imagesInUse else { return "On" }
    return imagesInUse == 1 ? "On, 1 image in use" : "On, \(imagesInUse) images in use"
  }

  // MARK: - Formatting

  public static func relative(_ date: Date, now: Date = Date()) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: now)
  }

  private static func trim(_ value: CGFloat) -> String {
    value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
  }

  // MARK: - Build identity

  public static func version(bundle: Bundle = .main) -> String {
    info("CFBundleShortVersionString", bundle) ?? "dev"
  }

  public static func buildCommit(bundle: Bundle = .main) -> String {
    info("LABANBuildCommit", bundle) ?? "dev"
  }

  /// "laban 0.8.1 (4c4288dd)": the one-line `laban --version`.
  public static func versionLine(bundle: Bundle = .main) -> String {
    "laban \(version(bundle: bundle)) (\(buildCommit(bundle: bundle)))"
  }

  static func builtSummary(bundle: Bundle, now: Date) -> String {
    guard let stamp = info("LABANBuildDate", bundle) else { return "Unknown (dev build)" }
    guard let date = ISO8601DateFormatter().date(from: stamp) else { return stamp }
    return "\(stamp) (\(relative(date, now: now)))"
  }

  private static func info(_ key: String, _ bundle: Bundle) -> String? {
    guard let value = bundle.object(forInfoDictionaryKey: key) as? String, !value.isEmpty
    else { return nil }
    return value
  }

  // MARK: - Report

  public struct Row: Equatable, Codable, Sendable {
    public var label: String
    public var value: String
    public init(_ label: String, _ value: String) {
      self.label = label
      self.value = value
    }
  }

  public struct Section: Equatable, Codable, Sendable {
    public var title: String
    public var rows: [Row]
  }

  /// Facts only the running app can state; the CLI leaves them nil and the
  /// rows are omitted.
  public struct AppFacts: Sendable {
    public var updates: String?
    public var renderer: String?
    public var theme: String?
    public var display: String?
    public var kittyImagesInUse: Int?
    public init(
      updates: String? = nil, renderer: String? = nil, theme: String? = nil,
      display: String? = nil, kittyImagesInUse: Int? = nil
    ) {
      self.updates = updates
      self.renderer = renderer
      self.theme = theme
      self.display = display
      self.kittyImagesInUse = kittyImagesInUse
    }
  }

  /// Build, Components and What programs see, in display order.
  public static func sections(
    bundle: Bundle = .main, app: AppFacts = AppFacts(), now: Date = Date()
  ) -> [Section] {
    let signing = codeSigning()
    var build = [
      Row("Version", "\(version(bundle: bundle)) (\(buildCommit(bundle: bundle)))"),
      Row("Built", builtSummary(bundle: bundle, now: now)),
      Row("Signed by", signing.summary),
      Row("Signature", signing.details),
    ]
    if let updates = app.updates { build.append(Row("Updates", updates)) }

    let engine = vtCore(bundle: bundle)
    var components = [
      Row("macOS", systemSummary()),
      Row("Terminal engine", engine.summary),
    ]
    if !engine.patches.isEmpty {
      components.append(Row("Patches", engine.patches.joined(separator: "\n")))
    }
    if let renderer = app.renderer { components.append(Row("Renderer", renderer)) }
    components.append(Row("Font", fontSummary()))
    if let theme = app.theme { components.append(Row("Theme", theme)) }
    components.append(Row("GPU", gpuName()))
    if let display = app.display { components.append(Row("Display", display)) }
    let labpty = bundle.bundleURL.appendingPathComponent("Contents/MacOS/labpty")
    let daemons = sessionDaemons(labptyURL: labpty)
    if daemons.isEmpty {
      components.append(Row("Session daemon", "No labpty session daemon running"))
    }
    for daemon in daemons {
      var text = "labpty pid \(daemon.pid), started \(relative(daemon.startedAt, now: now))"
      if !daemon.isThisAppsBinary { text += "\nLaunched from \(daemon.executablePath)" }
      if daemon.runsDifferentBuild == true {
        text += "\nRuns a different build than this app's labpty; it keeps your shells "
          + "alive and switches to this build when it is next started."
      }
      components.append(Row("Session daemon", text))
    }

    let programs = [
      Row("TERM", terminalType),
      Row("TERM_PROGRAM", terminalProgram()),
      Row("Kitty graphics", kittyGraphicsSummary(imagesInUse: app.kittyImagesInUse)),
    ]
    return [
      Section(title: "Build", rows: build),
      Section(title: "Components", rows: components),
      Section(title: "What programs see", rows: programs),
    ]
  }

  /// Plain text for bug reports: aligned rows, multi-line values indented.
  public static func text(
    sections: [Section], selfTest: [TerminalCapabilitySelfTest.Result]? = nil
  ) -> String {
    let width = (sections.flatMap { $0.rows.map(\.label.count) }.max() ?? 0) + 2
    var out: [String] = []
    for section in sections {
      out.append(section.title)
      for row in section.rows {
        let lines = row.value.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
          let label = index == 0 ? row.label : ""
          out.append("  " + label.padding(toLength: width, withPad: " ", startingAt: 0) + line)
        }
      }
      out.append("")
    }
    if let selfTest {
      out.append("Self-test: \(selfTestSummary(selfTest).text)")
      for result in selfTest {
        let mark: String
        switch result.status {
        case .passed: mark = "pass"
        case .failed: mark = "FAIL"
        case .disabled: mark = "off "
        }
        out.append("  [\(mark)] \(result.name): \(result.reply)")
      }
      out.append("")
    }
    return out.joined(separator: "\n")
  }

  /// JSON for agents: `{"version", "sections", "selfTest"}`.
  public static func json(
    bundle: Bundle = .main, sections: [Section],
    selfTest: [TerminalCapabilitySelfTest.Result]? = nil
  ) -> String {
    struct TestRow: Codable {
      var name: String
      var status: String
      var reply: String
    }
    struct Payload: Codable {
      var version: String
      var sections: [Section]
      var selfTest: [TestRow]?
    }
    let payload = Payload(
      version: versionLine(bundle: bundle), sections: sections,
      selfTest: selfTest?.map {
        TestRow(name: $0.name, status: $0.status.rawValue, reply: $0.reply)
      })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return (try? encoder.encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
  }

  /// "10 passed", "9 passed, 1 turned off", "8 passed, 2 failed".
  public static func selfTestSummary(
    _ results: [TerminalCapabilitySelfTest.Result]
  ) -> (text: String, allPassed: Bool) {
    let passed = results.filter { $0.status == .passed }.count
    let failed = results.filter { $0.status == .failed }.count
    let off = results.filter { $0.status == .disabled }.count
    var parts = ["\(passed) passed"]
    if off > 0 { parts.append("\(off) turned off") }
    if failed > 0 { parts.append("\(failed) failed") }
    return (parts.joined(separator: ", "), failed == 0)
  }
}
