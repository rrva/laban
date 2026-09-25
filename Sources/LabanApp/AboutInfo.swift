import AppKit
import Darwin
import LabanCore
import LabanRenderer
import LabanTerminalCore
import Metal
import Security

/// Everything the About window reports, gathered from the running app: how
/// this binary is built and signed, the component stack it runs on, and what
/// programs inside it are told. Values come from the live process, never from
/// constants that could drift from what actually shipped.
enum AboutInfo {
  // MARK: - Code signing

  struct CodeSigning: Equatable {
    enum Kind: Equatable {
      case unsigned
      case adHoc
      /// Signed by a certificate; the name is its common name, e.g.
      /// "Developer ID Application: Ragnar Rova (3563RJWBQP)".
      case certificate(String)
    }

    var kind: Kind
    var teamID: String?
    var hardenedRuntime: Bool
    var notarized: Bool

    var summary: String {
      switch kind {
      case .unsigned: return "Not signed"
      case .adHoc: return "Ad-hoc signature (local build, no team identity)"
      case .certificate(let name): return name
      }
    }

    var details: String {
      var parts: [String] = []
      if let teamID { parts.append("team \(teamID)") }
      parts.append(hardenedRuntime ? "hardened runtime" : "no hardened runtime")
      parts.append(notarized ? "notarized" : "not notarized")
      return parts.joined(separator: ", ")
    }
  }

  /// Reads the running app's signature (`SecCodeCopySelf`), not the bundle on
  /// disk, which an install or update may already have replaced.
  static func codeSigning() -> CodeSigning {
    var selfCode: SecCode?
    guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else {
      return CodeSigning(kind: .unsigned, teamID: nil, hardenedRuntime: false, notarized: false)
    }
    // SecCode is a SecStaticCode in C; Swift needs the cast. Querying the
    // running code keeps the answer about this process, not the file on disk.
    return codeSigning(for: unsafeBitCast(selfCode, to: SecStaticCode.self))
  }

  /// Signature of a bundle or binary on disk.
  static func codeSigning(bundleURL: URL) -> CodeSigning {
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

  struct VTCore: Equatable {
    var commit: String
    var patches: [String]

    var summary: String {
      let short = commit.isEmpty ? "unknown" : String(commit.prefix(9))
      let patchCount = patches.count == 1 ? "1 local patch" : "\(patches.count) local patches"
      return "libghostty-vt \(short) (Ghostty), \(patchCount)"
    }
  }

  /// The Ghostty commit and local patches `build-app` stamped into Info.plist.
  static func vtCore(bundle: Bundle = .main) -> VTCore {
    let commit = bundle.object(forInfoDictionaryKey: "LABANLibghosttyCommit") as? String ?? ""
    let patches =
      (bundle.object(forInfoDictionaryKey: "LABANLibghosttyPatches") as? String ?? "")
      .split(separator: ",").map { String($0).replacingOccurrences(of: "libghostty-vt-", with: "") }
    return VTCore(commit: commit, patches: patches)
  }

  // MARK: - Session daemon

  struct SessionDaemon: Equatable {
    var pid: pid_t
    var startedAt: Date
    /// The binary the daemon was launched from, as the kernel reports it.
    var executablePath: String
    /// True when the daemon was launched from this app's own `labpty`.
    var isThisAppsBinary: Bool
    /// True when the binary the daemon has mapped is not the file now
    /// installed as this app's `labpty` (an install or rebuild replaced it,
    /// so the daemon runs an older build). Compared by file identity: the
    /// running process keeps the replaced file mapped. The daemon keeps
    /// running across app restarts by design (it owns the shells) and
    /// switches when it is next started. nil when either side is unreadable.
    var runsDifferentBuild: Bool?
  }

  /// Every `labpty` session daemon of this user, wherever it was launched
  /// from: another install of the app shares the same session socket.
  static func sessionDaemons(
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

  struct FileIdentity: Equatable {
    var device: UInt64
    var inode: UInt64
  }

  static func fileIdentity(atPath path: String) -> FileIdentity? {
    var info = stat()
    guard stat(path, &info) == 0 else { return nil }
    return FileIdentity(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: info.st_ino)
  }

  /// Identity of the file a process has mapped as its executable, found by
  /// walking its memory regions to the one backed by `path`. This is the file
  /// the process actually runs, even after that path was replaced on disk.
  static func mappedExecutableIdentity(pid: pid_t, path: String) -> FileIdentity? {
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
  static func systemSummary() -> String {
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
  static func fontSummary(defaults: UserDefaults = .standard) -> String {
    let name =
      (defaults.string(forKey: FontAtlas.userFontKey)).flatMap { $0.isEmpty ? nil : $0 }
      ?? "JetBrains Mono (bundled)"
    let size = FontAtlas.terminalPointSize(from: defaults)
    let points = size == size.rounded() ? String(Int(size)) : String(format: "%.1f", size)
    return "\(name), \(points) pt"
  }

  static func themeSummary(appearance: NSAppearance = NSApp.effectiveAppearance) -> String {
    let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let follows = Theme.followsSystemAppearance ? ", follows system appearance" : ""
    return "\(Theme.current.name) (\(dark ? "dark" : "light") mode\(follows))"
  }

  // MARK: - GPU and display

  static func gpuName() -> String {
    MTLCreateSystemDefaultDevice()?.name ?? "No Metal device"
  }

  static func displaySummary(for screen: NSScreen?) -> String {
    guard let screen else { return "No display" }
    let points = screen.frame.size
    let scale = screen.backingScaleFactor
    return "\(Int(points.width))×\(Int(points.height)) pt @\(Self.trim(scale))x, "
      + "\(screen.maximumFramesPerSecond) Hz"
  }

  // MARK: - What programs see

  /// Terminal type every session advertises (`session_lifecycle.c`).
  static let terminalType = "xterm-256color"

  static func terminalProgram() -> String {
    let identity = TerminalIdentitySettings.identity()
    let note = identity == .ghosttyCompat ? " (Ghostty compatibility mode)" : ""
    return "\(identity.termProgram) \(identity.termProgramVersion)\(note)"
  }

  /// The gate sessions are actually created with (applied at launch from
  /// `KittyGraphicsSettings`), not the persisted setting, which only takes
  /// effect on the next launch.
  static func kittyGraphicsSummary() -> String {
    guard laban_kitty_graphics_enabled() else {
      return "Off (turned off by the LabanKittyGraphicsEnabled default or LABAN_KITTY_GRAPHICS=0)"
    }
    let stored = FrameImageStore.shared.count
    return stored == 1 ? "On, 1 image in use" : "On, \(stored) images in use"
  }

  // MARK: - Formatting

  static func relative(_ date: Date, now: Date = Date()) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: now)
  }

  private static func trim(_ value: CGFloat) -> String {
    value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
  }
}
