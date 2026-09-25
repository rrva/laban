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
      case .unsigned: return "Unsigned"
      case .adHoc: return "Ad-hoc (no team identity)"
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

  /// Reads the running app's own signature.
  static func codeSigning(bundleURL: URL = Bundle.main.bundleURL) -> CodeSigning {
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
      let staticCode
    else {
      return CodeSigning(kind: .unsigned, teamID: nil, hardenedRuntime: false, notarized: false)
    }
    var rawInfo: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &rawInfo) == errSecSuccess,
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
      let name = SecCertificateCopySubjectSummary(certificates[0]) as String? ?? "Unknown certificate"
      kind = .certificate(name)
    }
    var notarized = false
    var requirement: SecRequirement?
    if kind != .adHoc,
      SecRequirementCreateWithString("notarized" as CFString, [], &requirement) == errSecSuccess,
      let requirement
    {
      notarized = SecStaticCodeCheckValidity(staticCode, [], requirement) == errSecSuccess
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
    var binaryModifiedAt: Date?

    /// The installed labpty binary changed after this daemon started, so the
    /// daemon still runs an older build. It keeps running across app
    /// restarts by design (it owns the shells) and upgrades when replaced.
    var isOlderThanInstalledBinary: Bool {
      guard let binaryModifiedAt else { return false }
      return binaryModifiedAt > startedAt.addingTimeInterval(1)
    }
  }

  /// The running `labpty` daemons launched from this bundle's binary.
  static func sessionDaemons(
    labptyURL: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/labpty")
  ) -> [SessionDaemon] {
    let target = labptyURL.resolvingSymlinksInPath().path
    let modified =
      (try? FileManager.default.attributesOfItem(atPath: target))?[.modificationDate] as? Date
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(count) * 2)
    let listed = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard listed > 0 else { return [] }
    var daemons: [SessionDaemon] = []
    var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    for pid in pids.prefix(Int(listed)) where pid > 0 {
      guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0,
        String(cString: pathBuffer) == target
      else { continue }
      var info = proc_bsdinfo()
      let size = Int32(MemoryLayout<proc_bsdinfo>.size)
      guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
      let started = Date(
        timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
          + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
      daemons.append(SessionDaemon(pid: pid, startedAt: started, binaryModifiedAt: modified))
    }
    return daemons.sorted { $0.pid < $1.pid }
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
      return "Off (LabanKittyGraphicsEnabled is false or LABAN_KITTY_GRAPHICS=0)"
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
