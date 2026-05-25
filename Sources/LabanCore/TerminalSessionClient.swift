import Foundation
import LabanTerminalCore

public enum TerminalSessionClientError: Error, CustomStringConvertible {
  case sessionNotFound(String)
  case sessionNotRunning(String)
  case createFailed(String)
  case writeFailed(String)
  case resizeFailed(String)
  case snapshotFailed(String)
  case protocolError(String)

  public var description: String {
    switch self {
    case .sessionNotFound(let id): return "session not found: \(id)"
    case .sessionNotRunning(let id): return "session is not running: \(id)"
    case .createFailed(let message): return "session create failed: \(message)"
    case .writeFailed(let id): return "session input write failed: \(id)"
    case .resizeFailed(let id): return "session resize failed: \(id)"
    case .snapshotFailed(let id): return "session snapshot failed: \(id)"
    case .protocolError(let message): return "laband protocol error: \(message)"
    }
  }
}

public enum TerminalSessionBackend: String, Equatable, Sendable {
  case inProcess = "in-process"
  case laband

  public static func configured(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> TerminalSessionBackend {
    let raw = environment["LABAN_TERMINAL_BACKEND"] ?? TerminalSessionBackend.inProcess.rawValue
    guard let backend = TerminalSessionBackend(rawValue: raw) else {
      throw TerminalSessionClientError.protocolError(
        "unsupported LABAN_TERMINAL_BACKEND '\(raw)'")
    }
    return backend
  }
}

public struct TerminalSessionLaunchRequest: Equatable, Sendable {
  public var executable: String?
  public var argv: [String]?
  public var cwd: String?
  public var environmentPatch: [String: String]
  public var rows: Int
  public var cols: Int
  public var logicalSessionId: String?

  public init(
    executable: String? = nil,
    argv: [String]? = nil,
    cwd: String? = nil,
    environmentPatch: [String: String] = [:],
    rows: Int = 24,
    cols: Int = 80,
    logicalSessionId: String? = nil
  ) {
    self.executable = executable
    self.argv = argv
    self.cwd = cwd
    self.environmentPatch = environmentPatch
    self.rows = rows
    self.cols = cols
    self.logicalSessionId = logicalSessionId
  }
}

public protocol TerminalSessionClient: AnyObject {
  var transportMode: String { get }

  @discardableResult
  func createSession(_ request: TerminalSessionLaunchRequest) throws -> LabandSessionInfo
  func listSessions() throws -> [LabandSessionInfo]
  func writeInput(sessionId: String, bytes: [UInt8]) throws
  func resize(sessionId: String, rows: Int, cols: Int) throws -> LabandSessionInfo
  func attachSnapshotRing(sessionId: String) throws -> LabandSnapshotRingAttachment
  func snapshot(sessionId: String) throws -> LabandSnapshotResponse
  func markRendered(sessionId: String) throws
  func transferLease(sessionId: String, holderClientId: String) throws -> LabandSessionInfo
  func terminate(sessionId: String) throws -> LabandSessionInfo
}

extension LabandSnapshotResponse {
  public static func copying(
    logicalSessionId: String,
    incarnationId: String,
    snapshot pointer: UnsafePointer<LabanSnapshot>,
    lifecycleState: LabandLifecycleState
  ) -> LabandSnapshotResponse {
    let snapshot = pointer.pointee
    let title = snapshot.title.map { String(cString: $0) } ?? ""
    return LabandSnapshotResponse(
      logicalSessionId: logicalSessionId,
      incarnationId: incarnationId,
      rows: Int(snapshot.rows),
      cols: Int(snapshot.cols),
      cursorRow: Int(snapshot.cursor_row),
      cursorCol: Int(snapshot.cursor_col),
      cursorVisible: snapshot.cursor_visible != 0,
      title: title,
      lifecycleState: snapshot.status == 0 ? lifecycleState : .exited,
      exitStatus: snapshot.status == 0 ? nil : Int(snapshot.exit_status),
      dirty: snapshot.dirty != 0,
      visibleText: TerminalSnapshotText.visibleText(from: pointer, mode: .fullGrid),
      cells: Self.copyCells(snapshot)
    )
  }

  private static func copyCells(_ snapshot: LabanSnapshot) -> [LabandSnapshotCell] {
    let rows = Int(snapshot.rows)
    let cols = Int(snapshot.cols)
    guard rows > 0, cols > 0, let cells = snapshot.cells else { return [] }
    var output: [LabandSnapshotCell] = []
    output.reserveCapacity(rows * cols)
    for row in 0..<rows {
      for col in 0..<cols {
        let cell = cells[row * cols + col]
        output.append(
          LabandSnapshotCell(
            row: row,
            col: col,
            text: copyText(cell, storage: snapshot.utf8_storage),
            flags: cell.flags,
            foregroundRGBA: cell.foreground_rgba,
            backgroundRGBA: cell.background_rgba
          )
        )
      }
    }
    return output
  }

  private static func copyText(_ cell: LabanCell, storage: UnsafePointer<CChar>?) -> String {
    guard cell.utf8_length > 0, let storage else { return "" }
    let ptr = UnsafeRawPointer(storage).advanced(by: Int(cell.utf8_offset))
    let buffer = UnsafeBufferPointer<UInt8>(
      start: ptr.assumingMemoryBound(to: UInt8.self),
      count: Int(cell.utf8_length)
    )
    return String(bytes: buffer, encoding: .utf8) ?? ""
  }
}
