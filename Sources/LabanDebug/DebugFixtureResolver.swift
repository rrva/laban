import Foundation
import LabanCore

typealias DebugFixturePathError = ControlledFixturePathError

enum DebugFixtureResolver {
  static func resolve(_ path: String, root fixtureRootURL: URL) throws -> URL {
    try ControlledFixturePathResolver.resolve(path, root: fixtureRootURL)
  }
}
