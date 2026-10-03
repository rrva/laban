import Foundation

/// A parsed OpenSSH command line, reduced to what an image upload over the
/// same connection needs: the user's connection options and the destination.
/// See ADR 0039.
///
/// `parse` mirrors OpenSSH's own `getopt` loop (`ssh.c`): options may appear
/// before *and* after the destination, a bundled cluster such as `-At` or
/// `-vp22` is expanded, an argument-taking option consumes the rest of its
/// cluster or the next argv element, `--` ends option parsing, and the first
/// non-option after the destination starts the remote command — which is
/// dropped. Anything it cannot reproduce faithfully returns `nil`, so a paste
/// falls back to today's behavior instead of connecting somewhere unexpected.
public struct SSHCommandLine: Equatable, Sendable {
  /// One kept user option, normalized to separate tokens (`-p22` → `-p`, `22`).
  public struct Option: Equatable, Sendable {
    public var flag: Character
    public var value: String?

    public init(flag: Character, value: String? = nil) {
      self.flag = flag
      self.value = value
    }

    var tokens: [String] {
      if let value { return ["-\(flag)", value] }
      return ["-\(flag)"]
    }
  }

  /// The user's connection options that the upload keeps, in argv order.
  public var options: [Option]
  /// The destination exactly as typed (`host`, `user@host`, `ssh://…`).
  public var destination: String
  /// `-l` login, when given (last one wins, matching OpenSSH).
  public var login: String?
  /// `-p` port, when given (last one wins, matching OpenSSH).
  public var port: String?

  /// OpenSSH options that take an argument (`ssh.c` getopt string).
  static let optionsWithArgument = Set("BbcDEeFIiJLlmOoPpQRSWw")
  /// OpenSSH options that take no argument.
  static let flagOptions = Set("1246AaCfGgKkMNnqsTtVvXxYy")
  /// Options that change what ssh *does* (control commands, stdio forwarding,
  /// queries, config dump, version, subsystems, forward-only sessions with
  /// no remote shell): never re-run them.
  static let refusedOptions = Set("GNOQsVW")
  /// Session-shaping flags the upload must not inherit: TTY allocation (-t,
  /// -T is re-added), background (-f), stdin from /dev/null (-n, which would
  /// starve the upload), agent/X11 forwarding (-A -X -Y), master mode (-M),
  /// and verbosity (-v, which would bury the failure reason).
  static let strippedFlags = Set("AfMnTtvXY")
  /// Forwards the upload must not open again: -L -R -D ports, -w tunnel.
  static let strippedArgumentOptions = Set("DLRw")

  /// Options prepended to every upload. OpenSSH keeps the *first* value it
  /// sees for an option, so these come before the user's own options and win
  /// over a conflicting `-o` the user typed or a value in `ssh_config`.
  public static let forcedOptions: [String] = [
    "-T",
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=10",
    "-o", "ClearAllForwardings=yes",
    "-o", "ControlMaster=no",
    "-o", "PermitLocalCommand=no",
    "-o", "RemoteCommand=none",
    "-o", "StdinNull=no",
    "-o", "SessionType=default",
    "-o", "ForkAfterAuthentication=no",
    "-o", "ForwardAgent=no",
    "-o", "ForwardX11=no",
  ]

  public init(options: [Option], destination: String, login: String? = nil, port: String? = nil) {
    self.options = options
    self.destination = destination
    self.login = login
    self.port = port
  }

  /// Parse a full ssh argv (`argv[0]` included). Returns `nil` when argv[0]
  /// is not `ssh`, an option is unknown or refused, an option is missing its
  /// argument, or there is no usable destination.
  public static func parse(_ argv: [String]) -> SSHCommandLine? {
    guard let executable = argv.first, isSSHExecutable(executable) else { return nil }
    var options: [Option] = []
    var destination: String?
    var login: String?
    var port: String?
    var terminated = false
    var index = 1
    while index < argv.count {
      let arg = argv[index]
      let isOption = !terminated && arg.hasPrefix("-") && arg != "-"
      if destination != nil && !isOption && arg != "--" {
        break  // the remote command starts here; it is dropped
      }
      if destination != nil && terminated { break }
      if !terminated && arg == "--" {
        terminated = true
        index += 1
        continue
      }
      if !isOption {
        destination = arg
        index += 1
        continue
      }
      let cluster = Array(arg.dropFirst())
      var position = 0
      while position < cluster.count {
        let flag = cluster[position]
        if refusedOptions.contains(flag) { return nil }
        if optionsWithArgument.contains(flag) {
          let value: String
          if position + 1 < cluster.count {
            value = String(cluster[(position + 1)...])
          } else {
            index += 1
            guard index < argv.count else { return nil }
            value = argv[index]
          }
          if flag == "o", isRefusedConfigOption(value) { return nil }
          if flag == "l" { login = value }
          if flag == "p" { port = value }
          if !strippedArgumentOptions.contains(flag) {
            options.append(Option(flag: flag, value: value))
          }
          break
        }
        guard flagOptions.contains(flag) else { return nil }
        if !strippedFlags.contains(flag) {
          options.append(Option(flag: flag))
        }
        position += 1
      }
      index += 1
    }
    guard let destination, isUsableDestination(destination) else { return nil }
    return SSHCommandLine(options: options, destination: destination, login: login, port: port)
  }

  /// True for `ssh` or an absolute/relative path whose basename is `ssh`.
  public static func isSSHExecutable(_ value: String) -> Bool {
    guard !value.isEmpty else { return false }
    return (value as NSString).lastPathComponent == "ssh"
  }

  /// The ssh arguments (executable excluded) that upload stdin by running
  /// `remoteCommand` on the same destination.
  public func uploadArguments(remoteCommand: String) -> [String] {
    Self.forcedOptions + options.flatMap(\.tokens) + [destination, remoteCommand]
  }

  /// Key under which per-destination upload consent is remembered. Includes
  /// `-l` and `-p` so `-p 2222 host` and `host` are asked separately.
  public var consentKey: String {
    var key = destination
    if let login { key = "\(login) " + key }
    if let port { key += ":\(port)" }
    return key
  }

  /// A user `-o` that turns the session into one with no usable remote shell
  /// or stdin (`SessionType none|subsystem`, `StdinNull yes`): the pane is a
  /// forward-only or subsystem session, so the image paste keeps today's ⌃V.
  static func isRefusedConfigOption(_ option: String) -> Bool {
    let separators = CharacterSet(charactersIn: "= \t")
    guard let split = option.rangeOfCharacter(from: separators) else { return false }
    let key = option[..<split.lowerBound].lowercased()
    let value = option[split.upperBound...]
      .trimmingCharacters(in: CharacterSet(charactersIn: "= \t\"")).lowercased()
    switch key {
    case "sessiontype": return value != "default"
    case "stdinnull": return value == "yes" || value == "true"
    default: return false
    }
  }

  /// Destination as shown to the user in the consent prompt and toasts.
  public var displayDestination: String {
    guard let port else { return destination }
    return "\(destination) -p \(port)"
  }

  private static func isUsableDestination(_ value: String) -> Bool {
    guard !value.isEmpty, !value.hasPrefix("-"), value.count <= 1024 else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
      scalar.value > 0x20 && scalar.value != 0x7F && !(0x80...0x9F).contains(scalar.value)
    }
  }
}

/// The remote half of an SSH image upload: the command ssh runs on the host
/// and the validation of what it prints back. See ADR 0039.
public enum SSHImageUploadScript {
  /// Largest image Laban uploads.
  public static let maxImageBytes = 20 * 1024 * 1024

  /// A fresh, collision-free remote file name (`<uuid>.png`).
  public static func makeFileName(uuid: UUID = UUID()) -> String {
    "\(uuid.uuidString.lowercased()).png"
  }

  /// The single remote command: a `sh -c` with a single-quoted script, so it
  /// means the same thing whether the login shell is sh, bash, zsh, or fish.
  /// The file is created `0600` (umask 077) under the user's cache dir, stdin
  /// is written to it, and its absolute path is printed without a newline.
  /// `fileName` must come from `makeFileName` (hex digits and dashes only),
  /// which is what makes embedding it inside single quotes safe.
  public static func remoteCommand(fileName: String) -> String {
    precondition(isSafeFileName(fileName), "remote file name must come from makeFileName")
    return
      "sh -c 'umask 077; d=\"${XDG_CACHE_HOME:-$HOME/.cache}/laban/paste\"; "
      + "mkdir -p \"$d\" && f=\"$d/\(fileName)\" && cat > \"$f\" && printf %s \"$f\"'"
  }

  /// The remote path from the upload's stdout, or `nil` when the reply is not
  /// a printable absolute path ending in `/<fileName>`. Shell startup files
  /// that print to stdout in non-interactive sessions are tolerated: only the
  /// last non-empty line counts, and it must name the exact file we created.
  public static func remotePath(fromStdout data: Data, fileName: String) -> String? {
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    guard let path = lines.last, path.utf8.count <= 4096 else { return nil }
    guard path.hasPrefix("/"), path.hasSuffix("/" + fileName), path.hasSuffix(".png") else {
      return nil
    }
    let printable = path.unicodeScalars.allSatisfy { scalar in
      scalar.value >= 0x20 && scalar.value != 0x7F && !(0x80...0x9F).contains(scalar.value)
    }
    return printable ? path : nil
  }

  static func isSafeFileName(_ name: String) -> Bool {
    guard name.hasSuffix(".png") else { return false }
    let stem = name.dropLast(4)
    return !stem.isEmpty
      && stem.unicodeScalars.allSatisfy {
        CharacterSet(charactersIn: "0123456789abcdef-").contains($0)
      }
  }
}

/// What ⌘V does with the current pasteboard. See ADR 0039.
public enum ClipboardPasteAction: Equatable, Sendable {
  /// Paste the pasteboard text (also when an image rides along: H-7).
  case pasteText
  /// Image-only pasteboard, local program: forward ⌃V so it reads the image.
  case forwardControlV
  /// Image-only pasteboard while the pane runs ssh: upload and paste the path.
  case uploadOverSSH(SSHCommandLine)
  /// Nothing to paste.
  case none

  /// `ssh` is the parsed foreground ssh command line, or `nil` when the
  /// foreground process is not ssh or its argv could not be parsed. A pane
  /// whose foreground process is ssh is never a *local* Claude Code, so the
  /// ⌃V forward (which lets a local TUI read the Mac pasteboard) only loses
  /// to the upload when the remote program could not read that pasteboard.
  public static func decide(hasText: Bool, hasImage: Bool, ssh: SSHCommandLine?)
    -> ClipboardPasteAction
  {
    if hasText { return .pasteText }
    guard hasImage else { return .none }
    if let ssh { return .uploadOverSSH(ssh) }
    return .forwardControlV
  }
}

/// Remembers which destinations the user allowed clipboard image uploads to.
public protocol SSHImageUploadConsentStore: AnyObject {
  func isApproved(_ consentKey: String) -> Bool
  func approve(_ consentKey: String)
}

/// `UserDefaults`-backed consent store (`sshImageUpload.approvedDestinations`).
public final class UserDefaultsSSHImageUploadConsentStore: SSHImageUploadConsentStore {
  public static let defaultsKey = "sshImageUpload.approvedDestinations"
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public func isApproved(_ consentKey: String) -> Bool {
    approvedKeys.contains(consentKey)
  }

  public func approve(_ consentKey: String) {
    var keys = approvedKeys
    guard !keys.contains(consentKey) else { return }
    keys.append(consentKey)
    defaults.set(keys, forKey: Self.defaultsKey)
  }

  private var approvedKeys: [String] {
    defaults.stringArray(forKey: Self.defaultsKey) ?? []
  }
}
