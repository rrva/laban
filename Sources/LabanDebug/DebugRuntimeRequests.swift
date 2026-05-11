import Foundation

struct CellCoordinateReq: Decodable {
  var row: Int
  var col: Int
}

struct ActionRequest: Decodable {
  var action: String
  var tabId: String?
  var width: Int?
  var height: Int?
  var text: String?
  var title: String?
  var frozen: Bool?
  var count: Int?
  var key: String?
  var type: String?
  var modifiers: [String]?
  var consumedModifiers: [String]?
  var unshifted: String?
  var x: Int?
  var y: Int?
  var deltaY: Double?
  var button: String?
  var sessionId: String?
  var deltaRows: Int?
  var anchor: CellCoordinateReq?
  var focus: CellCoordinateReq?
  var cwd: String?
  var repoName: String?
  var repoRoot: String?
  var worktreeName: String?
  var branch: String?
  var isDirty: Bool?
  var foregroundProcess: String?
  var foregroundCommand: String?
  var pid: Int?
  var agentName: String?
  var sessionName: String?
  var agentSessionId: String?
  var taskLabel: String?
  var model: String?
  var contextPercent: Int?
  var awaitingInput: Bool?
  var activityState: String?
  var unseenOutput: Bool?
  var exitStatus: Int?
}

struct CaptureStartRequest: Decodable {
  var name: String? = nil
  var screenshots: String? = nil
}

struct CaptureStatusResponse: Encodable {
  var active: Bool
  var runId: String?
  var directory: String?
  var manifestPath: String?
  var screenshots: String?
}

struct CaptureStartResponse: Encodable {
  var active: Bool
  var alreadyActive: Bool
  var runId: String
  var directory: String
  var screenshots: String
}

struct CaptureStopResponse: Encodable {
  var active: Bool
  var runId: String?
  var directory: String?
  var manifestPath: String
}

struct WaitRequest: Decodable {
  var timeoutMs: Int
  var condition: WaitCondition
}

struct WaitCondition: Decodable {
  var kind: String
  var frame: Int?
  var eventKind: String?
  var count: Int?
  var tabId: String?
  var sessionId: String?
  var status: String?
  var title: String?
  var text: String?
  var commandKind: String?
  var invariantKind: String?
  var level: String?
}

struct RenderTraceRequest: Decodable {
  var frame: Int?
  var target: String?
  var include: [String]?
  var commandIds: [String]?
  var pixelProbes: [PixelProbeReq]?
  var limit: Int?
}

struct PixelProbeReq: Decodable {
  var name: String?
  var x: Int
  var y: Int
}
