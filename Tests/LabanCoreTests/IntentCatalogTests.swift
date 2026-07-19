import Foundation
import LabanCore
import XCTest

final class IntentCatalogTests: XCTestCase {
  func testSharedCatalogValidates() throws {
    XCTAssertNoThrow(try IntentCatalog.shared.validate())
  }

  func testValidateRejectsEmptyAndDuplicateIds() {
    XCTAssertThrowsError(try IntentCatalog([makeDescriptor(id: "")]).validate()) { error in
      XCTAssertEqual(error as? IntentCatalog.ValidationError, .emptyID(index: 0))
    }

    XCTAssertThrowsError(
      try IntentCatalog([
        makeDescriptor(id: "duplicate.intent"),
        makeDescriptor(id: "duplicate.intent"),
      ]).validate()
    ) { error in
      XCTAssertEqual(error as? IntentCatalog.ValidationError, .duplicateID("duplicate.intent"))
    }
  }

  func testStarterDescriptorsArePresentWithObserveGuiSurface() throws {
    let expectedGuiObserve: Set<String> = [
      "app.state"
    ]
    let expectedHeadlessOnlyInput: Set<String> = [
      "tab.select",
      "terminal.typeText",
      "terminal.sendKey",
    ]
    XCTAssertTrue(expectedGuiObserve.isSubset(of: IntentCatalog.shared.ids))
    XCTAssertTrue(expectedHeadlessOnlyInput.isSubset(of: IntentCatalog.shared.ids))

    for id in expectedGuiObserve {
      let descriptor = try XCTUnwrap(IntentCatalog.shared.descriptor(id: id))
      XCTAssertTrue(descriptor.availability.permits(.gui), id)
      XCTAssertTrue(descriptor.availability.permits(.headless), id)
    }
    for id in expectedHeadlessOnlyInput {
      let descriptor = try XCTUnwrap(IntentCatalog.shared.descriptor(id: id))
      XCTAssertFalse(descriptor.availability.permits(.gui), id)
      XCTAssertTrue(descriptor.availability.permits(.headless), id)
    }
  }

  func testFixtureCatalogLimitsGUIToDiagnosticWindowFocus() throws {
    XCTAssertEqual(
      IntentCatalog.fixture.ids,
      [
        "fixture.advanceFrames", "fixture.advanceTime", "fixture.control",
        "fixture.feedOutput", "fixture.windowFocus", "glyphEffects.setEnabled",
      ])
    for descriptor in IntentCatalog.fixture.descriptors {
      XCTAssertTrue(descriptor.availability.headless, descriptor.id)
      if descriptor.id == "fixture.windowFocus" {
        XCTAssertTrue(descriptor.availability.gui)
        XCTAssertEqual(descriptor.requiredCapability, .diagnosticControl)
      } else {
        XCTAssertFalse(descriptor.availability.gui, descriptor.id)
      }
    }
    XCTAssertNoThrow(try IntentCatalog.fixture.validate())

    let guiFixture = makeDescriptor(
      id: "fixture.feedOutput",
      requiredCapability: .fixture,
      availability: .init(gui: true, headless: true))
    XCTAssertThrowsError(try IntentCatalog([guiFixture]).validate()) { error in
      XCTAssertEqual(
        error as? IntentCatalog.ValidationError,
        .fixtureAvailableInGUI("fixture.feedOutput"))
    }
  }

  func testAllCatalogIsSharedUnionFixture() {
    XCTAssertEqual(
      IntentCatalog.all.ids,
      IntentCatalog.shared.ids.union(IntentCatalog.fixture.ids))
    XCTAssertEqual(IntentCatalog.all.sharedIds(), IntentCatalog.shared.ids)
  }

  func testStarterSchemasAreNonEmpty() throws {
    XCTAssertFalse(TabSelectInput.jsonSchema.toJSONSchema().isEmpty)
    XCTAssertFalse(TypeTextInput.jsonSchema.toJSONSchema().isEmpty)
    XCTAssertFalse(SendKeyInput.jsonSchema.toJSONSchema().isEmpty)
    XCTAssertFalse(WaitRequest.jsonSchema.toJSONSchema().isEmpty)
    XCTAssertFalse(RenderTraceRequest.jsonSchema.toJSONSchema().isEmpty)
    XCTAssertFalse(PixelProbeRequest.jsonSchema.toJSONSchema().isEmpty)
    XCTAssertFalse(FixtureControlRequest.jsonSchema.toJSONSchema().isEmpty)

    for descriptor in IntentCatalog.shared.descriptors {
      if descriptor.kind != .artifact {
        XCTAssertFalse(try XCTUnwrap(descriptor.outputSchema).toJSONSchema().isEmpty)
      }
      XCTAssertFalse(try XCTUnwrap(descriptor.errorSchema).toJSONSchema().isEmpty)

      if descriptor.kind == .action || descriptor.kind == .wait {
        XCTAssertFalse(try XCTUnwrap(descriptor.inputSchema).toJSONSchema().isEmpty)
      }
    }
  }

  func testTransparencySchemasUseExactBackgroundImageAvailabilityWireValues() throws {
    let expected = ["none", "available", "missing", "corrupt", "headlessUnsupported"]
    XCTAssertEqual(TerminalBackgroundImageAvailability.allCases.map(\.rawValue), expected)

    let generated = TerminalTransparencyDebugResponse.jsonSchema.toJSONSchema()
    let generatedProperties = try XCTUnwrap(generated["properties"] as? [String: Any])
    let generatedState = try XCTUnwrap(
      generatedProperties["backgroundImageState"] as? [String: Any])
    XCTAssertEqual(generatedState["enum"] as? [String], expected)

    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let checkedSchemaURL =
      repositoryRoot
      .appendingPathComponent("schemas/debug/transparency.schema.json")
    let checkedSchema = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(contentsOf: checkedSchemaURL))
        as? [String: Any])
    let checkedProperties = try XCTUnwrap(checkedSchema["properties"] as? [String: Any])
    let checkedState = try XCTUnwrap(
      checkedProperties["backgroundImageState"] as? [String: Any])
    XCTAssertEqual(checkedState["enum"] as? [String], expected)
  }

  func testKnownDebugActionIntentIDsAreCataloged() {
    for action in DebugActionIntentID.knownActionNames {
      guard let id = DebugActionIntentID.intentID(forAction: action) else {
        return XCTFail("missing intent id for \(action)")
      }
      XCTAssertNotNil(IntentCatalog.all.descriptor(id: id), "\(action) -> \(id)")
    }
    XCTAssertNotNil(IntentCatalog.all.descriptor(id: DebugActionIntentID.unsupported))
  }

  func testRouteAwareValidationAllowsQueryOnlyDescriptorWithoutInputSchema() {
    let queryOnly = makeDescriptor(
      id: "test.state",
      kind: .query,
      inputSchema: nil,
      outputSchema: simpleOutputSchema)
    XCTAssertNoThrow(try IntentCatalog([queryOnly]).validate())
  }

  func testRouteAwareValidationAllowsLegacyRequestSchemaForActionWithoutInputSchema() {
    let legacyAction = makeDescriptor(
      id: "legacy.action",
      kind: .action,
      inputSchema: nil,
      outputSchema: simpleOutputSchema)
    let endpoint = ControlEndpointDescriptor(
      binding: HTTPBinding(
        method: "POST",
        path: "/debug/actions",
        category: "debug",
        summary: "Legacy action endpoint.",
        legacyRequestSchemaPath: "schemas/debug/action.schema.json",
        legacyResponseSchemaPath: "schemas/debug/action-result.schema.json"),
      intentMapping: .fixed("legacy.action"))
    XCTAssertNoThrow(try IntentCatalog([legacyAction]).validate(endpointDescriptors: [endpoint]))
  }

  func testControlResponseJSONPinsLegacyEncoderSettings() {
    let response = ControlResponse.json(DatedPayload(z: Date(timeIntervalSince1970: 0), a: 1))
    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.contentType, "application/json")
    XCTAssertEqual(
      String(data: response.body, encoding: .utf8),
      #"{"a":1,"z":"1970-01-01T00:00:00Z"}"#)
  }

  func testControlResponseErrorMatchesLegacyJSONErrorShape() {
    let response = ControlResponse.error(418, #"bad "input"\path"#)
    XCTAssertEqual(response.status, 418)
    XCTAssertEqual(response.contentType, "application/json")
    XCTAssertEqual(
      String(data: response.body, encoding: .utf8),
      #"{"error":"bad \"input\"\\path"}"#)
  }
}

private struct DatedPayload: Encodable {
  let z: Date
  let a: Int
}

private let simpleOutputSchema: SchemaNode = .object(
  properties: ["ok": .boolean],
  required: ["ok"],
  additionalProperties: false)

private let simpleErrorSchema: SchemaNode = .object(
  properties: ["error": .string(enumValues: nil, const: nil, format: nil, pattern: nil)],
  required: ["error"],
  additionalProperties: false)

private func makeDescriptor(
  id: String,
  kind: IntentDescriptor.Kind = .query,
  requiredCapability: Capability = .observe,
  availability: IntentDescriptor.Availability = .init(gui: true, headless: true),
  inputSchema: SchemaNode? = nil,
  outputSchema: SchemaNode? = simpleOutputSchema,
  errorSchema: SchemaNode? = simpleErrorSchema
) -> IntentDescriptor {
  IntentDescriptor(
    id: id,
    kind: kind,
    category: "test",
    summary: "Test descriptor.",
    requiredCapability: requiredCapability,
    dataSensitivity: .none,
    sideEffects: .init(),
    risk: .init(level: .none, reason: "Test descriptor."),
    audit: .none,
    availability: availability,
    transports: .init(http: true, mcp: false, cli: false),
    inputSchema: inputSchema,
    outputSchema: outputSchema,
    errorSchema: errorSchema,
    classificationExplicit: true)
}
