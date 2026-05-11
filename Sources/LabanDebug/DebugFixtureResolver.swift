import Foundation

enum DebugFixturePathError: Error, CustomStringConvertible {
  case empty
  case absolute
  case traversal
  case escapedRoot
  case symlink(String)

  var description: String {
    switch self {
    case .empty:
      return "fixture path must not be empty"
    case .absolute:
      return "fixture path must be relative to the fixture root"
    case .traversal:
      return "fixture path must not contain '..'"
    case .escapedRoot:
      return "fixture path must remain inside the fixture root"
    case .symlink(let component):
      return "fixture path must not contain symlink component '\(component)'"
    }
  }
}

enum DebugFixtureResolver {
  static func resolve(_ path: String, root fixtureRootURL: URL) throws -> URL {
    let nsPath = path as NSString
    guard !path.isEmpty else { throw DebugFixturePathError.empty }
    guard !nsPath.isAbsolutePath else { throw DebugFixturePathError.absolute }

    let components = nsPath.pathComponents.filter { $0 != "." }
    guard !components.isEmpty else { throw DebugFixturePathError.empty }
    guard !components.contains("..") else { throw DebugFixturePathError.traversal }

    let root = fixtureRootURL.standardizedFileURL.resolvingSymlinksInPath()
    var candidate = root
    for component in components {
      candidate.appendPathComponent(component)
      if isSymlink(candidate) {
        throw DebugFixturePathError.symlink(component)
      }
    }

    let canonical = candidate.standardizedFileURL.resolvingSymlinksInPath()
    guard canonical.path == root.path || canonical.path.hasPrefix(root.path + "/") else {
      throw DebugFixturePathError.escapedRoot
    }
    return candidate
  }

  private static func isSymlink(_ url: URL) -> Bool {
    guard
      let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
      let type = attrs[.type] as? FileAttributeType
    else {
      return false
    }
    return type == .typeSymbolicLink
  }
}
