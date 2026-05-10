import Foundation
import LabanTerminalCore

// MARK: - Fixture model

public struct FixtureInitialSize: Codable, Equatable {
  public let cols: Int
  public let rows: Int
}

public enum FixtureStep: Equatable {
  case setTitle(String)
  case writeBytes(encoding: String, data: String)
  case waitFrames(Int)
}

extension FixtureStep: Codable {
  private enum CodingKeys: String, CodingKey {
    case op, title, encoding, data, count
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let op = try c.decode(String.self, forKey: .op)
    switch op {
    case "setTitle":
      self = .setTitle(try c.decode(String.self, forKey: .title))
    case "writeBytes":
      self = .writeBytes(
        encoding: try c.decode(String.self, forKey: .encoding),
        data: try c.decode(String.self, forKey: .data)
      )
    case "waitFrames":
      self = .waitFrames(try c.decode(Int.self, forKey: .count))
    default:
      throw FixtureError.unknownOp(op)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .setTitle(let title):
      try c.encode("setTitle", forKey: .op)
      try c.encode(title, forKey: .title)
    case .writeBytes(let encoding, let data):
      try c.encode("writeBytes", forKey: .op)
      try c.encode(encoding, forKey: .encoding)
      try c.encode(data, forKey: .data)
    case .waitFrames(let count):
      try c.encode("waitFrames", forKey: .op)
      try c.encode(count, forKey: .count)
    }
  }
}

public struct FixtureExpect: Codable {
  public let title: String?
  public let nonEmptyScreenshot: Bool?
  public let containsText: [String]?
}

public struct Fixture: Codable {
  public let name: String
  public let version: Int
  public let description: String?
  public let initialSize: FixtureInitialSize
  public let steps: [FixtureStep]
  public let expect: FixtureExpect?
}

// MARK: - Errors

public enum FixtureError: Error, Equatable {
  case unknownOp(String)
  case unsupportedEncoding(String)
  case snapshotFailed
  case pngEncodingFailed
}

// MARK: - Runner

public struct FixtureRunner {
  public let fixture: Fixture

  public init(fixture: Fixture) {
    self.fixture = fixture
  }

  public static func load(from url: URL) throws -> FixtureRunner {
    let data = try Data(contentsOf: url)
    let fixture = try JSONDecoder().decode(Fixture.self, from: data)
    return FixtureRunner(fixture: fixture)
  }

  // Applies all fixture steps to the active session; returns the sum of waitFrames counts.
  @discardableResult
  public func apply(to model: AppModel) throws -> Int {
    guard let tab = model.activeTab,
      let session = model.session(forTab: tab.id)
    else { return 0 }

    var frameCount = 0
    for step in fixture.steps {
      switch step {
      case .setTitle(let title):
        // OSC 0 sets the window title through the terminal VT parser.
        let osc = "\u{1B}]0;\(title)\u{07}"
        _ = session.write(Array(osc.utf8))
        _ = session.poll()

      case .writeBytes(let encoding, let data):
        guard encoding == "utf8" else { throw FixtureError.unsupportedEncoding(encoding) }
        _ = session.write(Array(data.utf8))
        _ = session.poll()

      case .waitFrames(let count):
        for _ in 0..<count {
          _ = session.poll()
          frameCount += 1
        }
      }
    }
    return frameCount
  }

  // Extracts all visible text from the snapshot, one trimmed line per non-empty row.
  public func visibleText(from snap: UnsafePointer<LabanSnapshot>) -> String {
    TerminalSnapshotText.visibleText(from: snap, mode: .trimmedNonEmptyRows)
  }
}
