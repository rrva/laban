import Foundation

/// Maps `ssh://` and `telnet://` URLs (opened via the system — a clicked link,
/// `open ssh://host`, or a registered default handler) to the argv Laban
/// should exec in a fresh tab.
///
/// The argv is passed straight to `execve` (no shell), so there is no shell
/// injection surface. The remaining hazard is *option* injection: a host or
/// user beginning with `-` would be parsed by ssh/telnet as a flag (e.g.
/// `-oProxyCommand=…`). Such URLs are rejected.
public enum TerminalURLCommand {
  public static func argv(for url: URL) -> [String]? {
    guard
      let scheme = url.scheme?.lowercased(),
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let host = components.host, !host.isEmpty, !host.hasPrefix("-")
    else { return nil }

    let user = components.user
    if let user, user.hasPrefix("-") { return nil }

    switch scheme {
    case "ssh":
      var argv = ["ssh"]
      if let port = components.port { argv += ["-p", String(port)] }
      if let user, !user.isEmpty {
        argv.append("\(user)@\(host)")
      } else {
        argv.append(host)
      }
      return argv
    case "telnet":
      var argv = ["telnet", host]
      if let port = components.port { argv.append(String(port)) }
      return argv
    default:
      return nil
    }
  }
}
