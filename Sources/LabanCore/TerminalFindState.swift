import Foundation

public enum TerminalFindDirection: String, Codable, Equatable, Sendable {
  case next
  case previous
}

public struct TerminalFindState: Codable, Equatable, Sendable {
  public var isActive: Bool
  public var needle: String
  public var matches: [TerminalFindMatch]
  public var selectedIndex: Int?
  public var viewportScrollOffsetAtStart: Int?
  public var viewportRowsAtStart: Int?

  public init(
    isActive: Bool,
    needle: String,
    matches: [TerminalFindMatch],
    selectedIndex: Int?,
    viewportScrollOffsetAtStart: Int?,
    viewportRowsAtStart: Int?
  ) {
    self.isActive = isActive
    self.needle = needle
    self.matches = matches
    self.selectedIndex = selectedIndex
    self.viewportScrollOffsetAtStart = viewportScrollOffsetAtStart
    self.viewportRowsAtStart = viewportRowsAtStart
  }

  public static let inactive = TerminalFindState(
    isActive: false,
    needle: "",
    matches: [],
    selectedIndex: nil,
    viewportScrollOffsetAtStart: nil,
    viewportRowsAtStart: nil
  )

  public var total: Int { matches.count }

  public var selectedMatch: TerminalFindMatch? {
    guard let selectedIndex, matches.indices.contains(selectedIndex) else { return nil }
    return matches[selectedIndex]
  }
}
