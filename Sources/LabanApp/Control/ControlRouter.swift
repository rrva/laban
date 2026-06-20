import Foundation

public struct ControlTabState: Codable {
  public let id: String
  public let index: Int
  public let active: Bool
  public let sessionId: String?
}

public struct ControlState: Codable {
  public let tabs: [ControlTabState]
  public let activeTabId: String?
}

public struct ControlActionResult: Codable {
  public let ok: Bool
  public let activeTabId: String?
  public let error: String?
}

/// Phase 0 seam for the control transport. Later phases generalize this into
/// the typed intent router shared by the GUI and headless runtimes.
public protocol ControlRouter: AnyObject {
  func snapshotState() -> ControlState
  func selectTab(index: Int) -> ControlActionResult
}
