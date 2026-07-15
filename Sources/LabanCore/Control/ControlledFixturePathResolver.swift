import Foundation

/// Fail-closed path errors shared by headless fixtures and isolated GUI
/// diagnostic imports. Callers expose only these descriptions, never a
/// resolved absolute path.
public enum ControlledFixturePathError: Error, CustomStringConvertible, Equatable, Sendable {
  case empty
  case absolute
  case traversal
  case escapedRoot
  case symlink(String)

  public var description: String {
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

public enum ControlledFixturePathResolver {
  public static func resolve(_ path: String, root fixtureRootURL: URL) throws -> URL {
    let nsPath = path as NSString
    guard !path.isEmpty else { throw ControlledFixturePathError.empty }
    guard !nsPath.isAbsolutePath else { throw ControlledFixturePathError.absolute }

    let components = nsPath.pathComponents.filter { $0 != "." }
    guard !components.isEmpty else { throw ControlledFixturePathError.empty }
    guard !components.contains("..") else { throw ControlledFixturePathError.traversal }

    let root = fixtureRootURL.standardizedFileURL.resolvingSymlinksInPath()
    var candidate = root
    for component in components {
      candidate.appendPathComponent(component)
      if isSymlink(candidate) {
        throw ControlledFixturePathError.symlink(component)
      }
    }

    let canonical = candidate.standardizedFileURL.resolvingSymlinksInPath()
    guard canonical.path == root.path || canonical.path.hasPrefix(root.path + "/") else {
      throw ControlledFixturePathError.escapedRoot
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
