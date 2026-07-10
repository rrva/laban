import Foundation
import LabanControl
import LabanCore
import XCTest

@testable import LabanApp
@testable import LabanDebug

final class CatalogParityTests: XCTestCase {
  /// Intent ids `LiveIntentRouter` answers on the GUI surface (non-404 paths).
  private static let liveImplementedIntentIDs: Set<String> = [
    "app.state",
    "app.stateSummary",
    "app.accessibility",
    "terminal.modes",
    "find.state",
    "shellIntegration.state",
    "terminal.getText",
    "scrollIndicator.state",
    "session.list",
    "session.detail",
    "selection.read",
    "terminal.scrollViewport",
    "command.propose",
    "commandProposal.list",
    "commandProposal.get",
    "commandProposal.cancel",
    "debug.discovery",
    "debug.capabilities",
    "debug.health",
  ]

  func testSharedIntentsReturnNonErrorOnBothSurfaces() throws {
    let headlessRuntime = try makeHeadlessRuntime()
    defer { try? FileManager.default.removeItem(at: headlessRuntime.artifacts) }
    let (guiModel, guiRouter, _) = try makeGUIRuntime()
    let socketBase = try makeTempSocketPath()

    let headlessServer = LabanControlServer(
      router: HeadlessIntentRouter(runtime: headlessRuntime.runtime),
      surface: .headless,
      catalog: .shared)
    let headlessStart = try headlessServer.start(socketPath: socketBase + ".headless")
    defer { headlessServer.stop() }

    let guiServer = LabanControlServer(
      router: guiRouter, surface: .gui, catalog: .shared)
    let guiStart = try guiServer.start(socketPath: socketBase + ".gui")
    defer { guiServer.stop() }

    let headlessSessionID = try firstSessionID(
      socketPath: headlessStart.debugServer, token: headlessStart.debugToken)
    let guiSessionID = try firstSessionID(
      socketPath: guiStart.debugServer, token: guiStart.debugToken)
    let cases = sharedParityCases(
      headlessSessionID: headlessSessionID, guiSessionID: guiSessionID)

    for testCase in cases {
      let resolvedHeadlessBody = testCase.headlessBody ?? testCase.body
      let resolvedGuiBody = testCase.guiBody ?? testCase.body

      let headless = try request(
        socketPath: headlessStart.debugServer,
        method: testCase.method,
        path: testCase.headlessPath,
        token: headlessStart.debugToken,
        body: resolvedHeadlessBody)
      XCTAssertTrue(
        (200..<300).contains(headless.status),
        "\(testCase.intentID) headless expected 2xx, got \(headless.status)")

      let gui = try request(
        socketPath: guiStart.debugServer,
        method: testCase.method,
        path: testCase.guiPath,
        token: guiStart.debugToken,
        body: resolvedGuiBody)
      XCTAssertTrue(
        (200..<300).contains(gui.status),
        "\(testCase.intentID) gui expected 2xx, got \(gui.status)")

      if testCase.compareShape {
        let headlessJSON = try XCTUnwrap(
          try JSONSerialization.jsonObject(with: headless.body) as? [String: Any],
          "\(testCase.intentID) headless body is not a JSON object")
        let guiJSON = try XCTUnwrap(
          try JSONSerialization.jsonObject(with: gui.body) as? [String: Any],
          "\(testCase.intentID) gui body is not a JSON object")
        XCTAssertEqual(
          jsonShape(headlessJSON),
          jsonShape(guiJSON),
          "\(testCase.intentID) JSON shape mismatch between surfaces")
      }
    }
    _ = guiModel
  }

  func testEveryDescriptorIsExplicitlyClassified() throws {
    for descriptor in IntentCatalog.all.descriptors {
      XCTAssertTrue(
        descriptor.classificationExplicit,
        "\(descriptor.id) must declare explicit requiredCapability and dataSensitivity")
    }
    XCTAssertNoThrow(try IntentCatalog.all.validate())
  }

  func testNoGuiDescriptorRequiresInputOrClipboard() {
    let offenders = IntentCatalog.shared.descriptors.filter {
      $0.availability.gui
        && ($0.requiredCapability == .input || $0.requiredCapability == .clipboard)
    }
    XCTAssertEqual(
      offenders.map(\.id).sorted(),
      [],
      "gui:true intents must not require .input or .clipboard")
  }

  func testGuiCatalogIDsMatchLiveIntentRouterImplementation() {
    let catalogGuiIDs = Set(
      IntentCatalog.shared.descriptors.filter(\.availability.gui).map(\.id))
    XCTAssertEqual(
      catalogGuiIDs,
      Self.liveImplementedIntentIDs,
      "gui:true catalog ids must match LiveIntentRouter implementation")
  }

  func testGuiNavigateAllowlistIsExactlyScrollViewport() {
    let guiNavigateIDs = Set(
      IntentCatalog.shared.descriptors.filter {
        $0.availability.gui && $0.requiredCapability == .navigate
      }.map(\.id))
    XCTAssertEqual(guiNavigateIDs, ["terminal.scrollViewport"])
  }

  func testGuiProposeAllowlistIsExactlyProposeAndLifecycle() {
    let guiProposeIDs = Set(
      IntentCatalog.shared.descriptors.filter {
        $0.availability.gui && $0.requiredCapability == .propose
      }.map(\.id))
    XCTAssertEqual(
      guiProposeIDs,
      [
        "command.propose",
        "commandProposal.list",
        "commandProposal.get",
        "commandProposal.cancel",
      ])
  }

  // MARK: - Helpers

  private struct ParityCase {
    let intentID: String
    let method: String
    let headlessPath: String
    let guiPath: String
    let body: Data?
    let headlessBody: Data?
    let guiBody: Data?
    let compareShape: Bool

    init(
      intentID: String,
      method: String,
      headlessPath: String,
      guiPath: String,
      body: Data? = nil,
      headlessBody: Data? = nil,
      guiBody: Data? = nil,
      compareShape: Bool
    ) {
      self.intentID = intentID
      self.method = method
      self.headlessPath = headlessPath
      self.guiPath = guiPath
      self.body = body
      self.headlessBody = headlessBody
      self.guiBody = guiBody
      self.compareShape = compareShape
    }
  }

  private func sharedParityCases(
    headlessSessionID: String,
    guiSessionID: String
  ) -> [ParityCase] {
    [
      ParityCase(
        intentID: "app.state", method: "GET", headlessPath: "/debug/state",
        guiPath: "/debug/state", body: nil, compareShape: true),
      ParityCase(
        intentID: "app.accessibility", method: "GET",
        headlessPath: "/debug/accessibility", guiPath: "/debug/accessibility", body: nil,
        compareShape: true),
      ParityCase(
        intentID: "terminal.modes", method: "GET",
        headlessPath: "/debug/terminal-modes", guiPath: "/debug/terminal-modes", body: nil,
        compareShape: true),
      ParityCase(
        intentID: "find.state", method: "GET",
        headlessPath: "/debug/find/state", guiPath: "/debug/find/state", body: nil,
        compareShape: true),
      ParityCase(
        intentID: "shellIntegration.state",
        method: "GET",
        headlessPath: "/debug/shell-integration/state",
        guiPath: "/debug/shell-integration/state",
        body: nil,
        compareShape: true),
      ParityCase(
        intentID: "terminal.getText",
        method: "GET",
        headlessPath: "/debug/text?source=screen",
        guiPath: "/debug/text?source=screen",
        body: nil,
        compareShape: true),
      ParityCase(
        intentID: "scrollIndicator.state",
        method: "GET",
        headlessPath: "/debug/scroll-indicator/state",
        guiPath: "/debug/scroll-indicator/state",
        body: nil,
        compareShape: true),
      ParityCase(
        intentID: "session.list", method: "GET",
        headlessPath: "/debug/sessions", guiPath: "/debug/sessions", body: nil,
        compareShape: true),
      ParityCase(
        intentID: "session.detail",
        method: "GET",
        headlessPath: "/debug/sessions/\(headlessSessionID)",
        guiPath: "/debug/sessions/\(guiSessionID)",
        body: nil,
        compareShape: true),
      ParityCase(
        intentID: "selection.read", method: "GET",
        headlessPath: "/debug/selection", guiPath: "/debug/selection", body: nil,
        compareShape: true),
      ParityCase(
        intentID: "terminal.scrollViewport",
        method: "POST",
        headlessPath: "/debug/actions",
        guiPath: "/debug/actions",
        body: Data(#"{"action":"scrollViewport","deltaRows":0}"#.utf8),
        compareShape: false),
      ParityCase(
        intentID: "command.propose",
        method: "POST",
        headlessPath: "/debug/actions",
        guiPath: "/debug/actions",
        headlessBody: proposeBody(sessionID: headlessSessionID),
        guiBody: proposeBody(sessionID: guiSessionID),
        compareShape: true),
    ]
  }

  private func firstSessionID(socketPath: String, token: String) throws -> String {
    let (status, body) = try request(
      socketPath: socketPath, method: "GET", path: "/debug/sessions", token: token)
    XCTAssertEqual(status, 200)
    let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
    let sessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])
    let first = try XCTUnwrap(sessions.first)
    return try XCTUnwrap(first["id"] as? String)
  }

  private func proposeBody(sessionID: String) -> Data {
    Data(
      #"{"action":"propose","command":"echo parity","purpose":"catalog parity","targetSessionID":"\#(sessionID)"}"#
        .utf8)
  }

  private func makeHeadlessRuntime() throws -> (runtime: HeadlessDebugRuntime, artifacts: URL) {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-catalog-parity-headless-\(UUID().uuidString)")
    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "catalog-parity-headless")
    return (runtime, artifacts)
  }

  private func makeGUIRuntime() throws -> (AppModel, LiveIntentRouter, String) {
    let model = try AppModel()
    _ = try model.createTab()
    let sessionID = try XCTUnwrap(model.tabs.first?.sessionId)
    return (model, LiveIntentRouter(model: model), sessionID)
  }

  private func makeTempSocketPath() throws -> String {
    "/tmp/laban-catalog-parity-\(UUID().uuidString.prefix(8))"
  }

  private func request(
    socketPath: String,
    method: String,
    path: String,
    token: String,
    body: Data? = nil
  ) throws -> (status: Int, body: Data) {
    try ControlUDSTestSupport.requestFromBackgroundThread(
      socketPath: socketPath,
      path: path,
      method: method,
      token: token,
      body: body)
  }

  func testLabanAppReleaseBoundaryDoesNotImportOrDependOnLabanDebug() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let packageText = try String(contentsOf: root.appendingPathComponent("Package.swift"))
    let appTargetMarker = ".executableTarget(\n      name: \"LabanApp\","
    guard let targetStart = packageText.range(of: appTargetMarker) else {
      return XCTFail("Package.swift missing LabanApp target")
    }
    let targetTail = packageText[targetStart.lowerBound...]
    let targetEnd =
      targetTail.dropFirst().range(of: "\n    .target(")?.lowerBound
      ?? targetTail.dropFirst().range(of: "\n    .executableTarget(")?.lowerBound
      ?? targetTail.dropFirst().range(of: "\n    .library(")?.lowerBound
      ?? targetTail.dropFirst().range(of: "\n    .testTarget(")?.lowerBound
      ?? targetTail.endIndex
    let targetBlock = String(targetTail[..<targetEnd])
    XCTAssertFalse(targetBlock.contains(#""LabanDebug""#))

    let appURL = root.appendingPathComponent("Sources/LabanApp", isDirectory: true)
    guard
      let enumerator = FileManager.default.enumerator(
        at: appURL,
        includingPropertiesForKeys: nil)
    else {
      return XCTFail("missing Sources/LabanApp")
    }
    for case let file as URL in enumerator where file.pathExtension == "swift" {
      let text = try String(contentsOf: file)
      XCTAssertFalse(text.contains("import LabanDebug"), file.path)
    }
  }
}

// MARK: - JSON shape comparison

private indirect enum JSONShape: Equatable {
  case null
  case bool
  case number
  case string
  case array(JSONShape)
  case object([String: JSONShape])
}

private func jsonShape(_ value: Any) -> JSONShape {
  if value is NSNull {
    return .null
  }
  if value is Bool {
    return .bool
  }
  if let number = value as? NSNumber {
    if CFGetTypeID(number) == CFBooleanGetTypeID() {
      return .bool
    }
    return .number
  }
  if value is String {
    return .string
  }
  if let array = value as? [Any] {
    guard let first = array.first else {
      return .array(.null)
    }
    return .array(jsonShape(first))
  }
  if let object = value as? [String: Any] {
    var shapes: [String: JSONShape] = [:]
    for key in object.keys.sorted() {
      shapes[key] = jsonShape(object[key]!)
    }
    return .object(shapes)
  }
  return .null
}
