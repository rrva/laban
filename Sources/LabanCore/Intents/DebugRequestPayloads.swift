import Foundation

private enum DebugPayloadSchema {
  static let string = SchemaNode.string(enumValues: nil, const: nil, format: nil, pattern: nil)
  static let integer = SchemaNode.integer(min: nil, max: nil)
  static let number = SchemaNode.number(min: nil, max: nil)
  static let boolean = SchemaNode.boolean

  static func object(
    _ properties: [String: SchemaNode],
    required: [String] = [],
    additionalProperties: Bool = true
  ) -> SchemaNode {
    .object(properties: properties, required: required, additionalProperties: additionalProperties)
  }

  static func stringArray() -> SchemaNode {
    .array(string, minItems: 0)
  }
}

public struct WindowScreenshotResponse: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var ok: Bool
  public var pngBase64: String
  public var width: Int
  public var height: Int
  public var byteCount: Int
  public var includesDialogs: Bool

  public init(
    ok: Bool = true,
    pngBase64: String,
    width: Int,
    height: Int,
    byteCount: Int,
    includesDialogs: Bool = true
  ) {
    self.ok = ok
    self.pngBase64 = pngBase64
    self.width = width
    self.height = height
    self.byteCount = byteCount
    self.includesDialogs = includesDialogs
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "ok": DebugPayloadSchema.boolean,
        "pngBase64": .string(enumValues: nil, const: nil, format: "byte", pattern: nil),
        "width": .integer(min: 1, max: nil),
        "height": .integer(min: 1, max: nil),
        "byteCount": .integer(min: 1, max: 10 * 1024 * 1024),
        "includesDialogs": DebugPayloadSchema.boolean,
      ],
      required: ["ok", "pngBase64", "width", "height", "byteCount", "includesDialogs"],
      additionalProperties: false)
  }
}

public struct DebugActionEnvelope: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var action: String

  public init(action: String) {
    self.action = action
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(["action": DebugPayloadSchema.string], required: ["action"])
  }
}

public enum DebugActionIntentID {
  public static let unsupported = "debug.action.unsupported"

  public static let knownActionNames: [String] = [
    "newTab",
    "closeTab",
    "selectTab",
    "setTabTitle",
    "freezeTabTitle",
    "clearTabTitle",
    "setTabMetadata",
    "moveTab",
    "resizeWindow",
    "setFontSize",
    "setRenderer",
    "typeText",
    "feedOutput",
    "advanceFrames",
    "advanceTime",
    "setGlyphEffectsEnabled",
    "setVectorSubpixelLayout",
    "setPreedit",
    "setClipboardText",
    "setSelection",
    "find.start",
    "find.step",
    "find.stop",
    "copy",
    "paste",
    "dropFiles",
    "scrollViewport",
    "propose",
    "proposalList",
    "proposalGet",
    "proposalCancel",
    "mouseWheel",
    "mouseDrag",
    "click",
    "key",
    "windowFocus",
    "setBackgroundTransparency",
    "resetTransparencyDiagnostics",
    "setReduceTransparencyOverride",
    "setNativeFullScreen",
    "setBackgroundSource",
    "setBackgroundImageScaling",
    "importBackgroundImage",
    "removeBackgroundImage",
    "captureProfile",
  ]

  public static func intentID(forAction action: String) -> String? {
    switch action {
    case "newTab": return "tab.new"
    case "closeTab": return "tab.close"
    case "selectTab": return "tab.select"
    case "setTabTitle": return "tab.title.set"
    case "freezeTabTitle": return "tab.title.freeze"
    case "clearTabTitle": return "tab.title.clear"
    case "setTabMetadata": return "tab.metadata.set"
    case "moveTab": return "tab.move"
    case "resizeWindow": return "window.resize"
    case "setFontSize": return "app.fontSize.set"
    case "setRenderer": return "renderer.set"
    case "typeText": return "terminal.typeText"
    case "feedOutput": return "fixture.feedOutput"
    case "advanceFrames": return "fixture.advanceFrames"
    case "advanceTime": return "fixture.advanceTime"
    case "setGlyphEffectsEnabled": return "glyphEffects.setEnabled"
    case "setVectorSubpixelLayout": return "vector.subpixelLayout.set"
    case "setPreedit": return "preedit.set"
    case "setClipboardText": return "clipboard.setText"
    case "setSelection": return "selection.set"
    case "find.start": return "find.start"
    case "find.step": return "find.step"
    case "find.stop": return "find.stop"
    case "copy": return "clipboard.copy"
    case "paste": return "clipboard.paste"
    case "dropFiles": return "terminal.dropFiles"
    case "scrollViewport": return "terminal.scrollViewport"
    case "propose": return "command.propose"
    case "proposalList": return "commandProposal.list"
    case "proposalGet": return "commandProposal.get"
    case "proposalCancel": return "commandProposal.cancel"
    case "mouseWheel": return "terminal.mouseWheel"
    case "mouseDrag": return "terminal.mouseDrag"
    case "click": return "terminal.click"
    case "key": return "terminal.sendKey"
    case "windowFocus": return "fixture.windowFocus"
    case "setBackgroundTransparency": return "transparency.setBackground"
    case "resetTransparencyDiagnostics": return "transparency.diagnostics.reset"
    case "setReduceTransparencyOverride": return "transparency.reduceTransparencyOverride.set"
    case "setNativeFullScreen": return "transparency.nativeFullScreen.set"
    case "setBackgroundSource": return "transparency.backgroundSource.set"
    case "setBackgroundImageScaling": return "transparency.backgroundImageScaling.set"
    case "importBackgroundImage": return "transparency.backgroundImage.import"
    case "removeBackgroundImage": return "transparency.backgroundImage.remove"
    case "captureProfile": return "profile.capture"
    default: return nil
    }
  }
}

public struct SetBackgroundTransparencyActionRequest: Codable, Sendable, Equatable,
  JSONSchemaProviding
{
  public var action: String?
  public var opacity: Double
  public var blur: Double?
  public var applyToExplicitCellBackgrounds: Bool
  public var backdropStyle: TerminalBackdropStyle?

  public init(
    action: String? = "setBackgroundTransparency",
    opacity: Double,
    blur: Double? = nil,
    applyToExplicitCellBackgrounds: Bool,
    backdropStyle: TerminalBackdropStyle? = nil
  ) {
    self.action = action
    self.opacity = opacity
    self.blur = blur
    self.applyToExplicitCellBackgrounds = applyToExplicitCellBackgrounds
    self.backdropStyle = backdropStyle
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "action": .string(
          enumValues: nil, const: "setBackgroundTransparency", format: nil, pattern: nil),
        "opacity": .number(min: 0, max: 1),
        "blur": .optional(.number(min: 0, max: 1)),
        "applyToExplicitCellBackgrounds": .boolean,
        "backdropStyle": .string(
          enumValues: TerminalBackdropStyle.allCases.map(\.rawValue), const: nil, format: nil,
          pattern: nil),
      ],
      required: ["action", "opacity", "applyToExplicitCellBackgrounds"],
      additionalProperties: false)
  }
}

public struct ResetTransparencyDiagnosticsActionRequest: Codable, Sendable, Equatable,
  JSONSchemaProviding
{
  public var action: String?

  public init(action: String? = "resetTransparencyDiagnostics") {
    self.action = action
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "action": .string(
          enumValues: nil, const: "resetTransparencyDiagnostics", format: nil, pattern: nil)
      ],
      required: ["action"],
      additionalProperties: false)
  }
}

public struct SetReduceTransparencyOverrideActionRequest: Codable, Sendable, Equatable,
  JSONSchemaProviding
{
  public var action: String?
  public var enabled: Bool?

  public init(action: String? = "setReduceTransparencyOverride", enabled: Bool?) {
    self.action = action
    self.enabled = enabled
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "action": .string(
          enumValues: nil, const: "setReduceTransparencyOverride", format: nil, pattern: nil),
        "enabled": .optional(.boolean),
      ],
      required: ["action", "enabled"],
      additionalProperties: false)
  }
}

public struct SetNativeFullScreenActionRequest: Codable, Sendable, Equatable,
  JSONSchemaProviding
{
  public var action: String?
  public var enabled: Bool

  public init(action: String? = "setNativeFullScreen", enabled: Bool) {
    self.action = action
    self.enabled = enabled
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "action": .string(
          enumValues: nil, const: "setNativeFullScreen", format: nil, pattern: nil),
        "enabled": .boolean,
      ],
      required: ["action", "enabled"],
      additionalProperties: false)
  }
}

public struct SetBackgroundSourceActionRequest: Codable, Sendable, Equatable,
  JSONSchemaProviding
{
  public var action: String?
  public var source: TerminalBackdropStyle

  public init(action: String? = "setBackgroundSource", source: TerminalBackdropStyle) {
    self.action = action
    self.source = source
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "action": .string(
          enumValues: nil, const: "setBackgroundSource", format: nil, pattern: nil),
        "source": .string(
          enumValues: TerminalBackdropStyle.allCases.map(\.rawValue), const: nil, format: nil,
          pattern: nil),
      ],
      required: ["action", "source"],
      additionalProperties: false)
  }
}

public struct SetBackgroundImageScalingActionRequest: Codable, Sendable, Equatable,
  JSONSchemaProviding
{
  public var action: String?
  public var scaling: TerminalBackgroundImageScaling

  public init(
    action: String? = "setBackgroundImageScaling",
    scaling: TerminalBackgroundImageScaling
  ) {
    self.action = action
    self.scaling = scaling
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "action": .string(
          enumValues: nil, const: "setBackgroundImageScaling", format: nil, pattern: nil),
        "scaling": .string(
          enumValues: TerminalBackgroundImageScaling.allCases.map(\.rawValue), const: nil,
          format: nil, pattern: nil),
      ],
      required: ["action", "scaling"],
      additionalProperties: false)
  }
}

public struct ImportBackgroundImageActionRequest: Codable, Sendable, Equatable,
  JSONSchemaProviding
{
  public var action: String?
  public var path: String
  public var scaling: TerminalBackgroundImageScaling

  public init(
    action: String? = "importBackgroundImage",
    path: String,
    scaling: TerminalBackgroundImageScaling
  ) {
    self.action = action
    self.path = path
    self.scaling = scaling
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "action": .string(
          enumValues: nil, const: "importBackgroundImage", format: nil, pattern: nil),
        "path": .string(enumValues: nil, const: nil, format: nil, pattern: nil),
        "scaling": .string(
          enumValues: TerminalBackgroundImageScaling.allCases.map(\.rawValue), const: nil,
          format: nil, pattern: nil),
      ],
      required: ["action", "path", "scaling"],
      additionalProperties: false)
  }
}

public struct RemoveBackgroundImageActionRequest: Codable, Sendable, Equatable,
  JSONSchemaProviding
{
  public var action: String?

  public init(action: String? = "removeBackgroundImage") {
    self.action = action
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "action": .string(
          enumValues: nil, const: "removeBackgroundImage", format: nil, pattern: nil)
      ],
      required: ["action"],
      additionalProperties: false)
  }
}

public struct CaptureProfileActionRequest: Codable, Sendable, Equatable,
  JSONSchemaProviding
{
  public var action: String?
  public var samples: Int
  public var intervalMilliseconds: Int
  public var expectedPID: Int?

  public init(
    action: String? = "captureProfile",
    samples: Int,
    intervalMilliseconds: Int,
    expectedPID: Int? = nil
  ) {
    self.action = action
    self.samples = samples
    self.intervalMilliseconds = intervalMilliseconds
    self.expectedPID = expectedPID
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "action": .string(
          enumValues: nil, const: "captureProfile", format: nil, pattern: nil),
        "expectedPID": .integer(min: 1, max: nil),
        "intervalMilliseconds": .integer(min: 1, max: 1_000),
        "samples": .integer(min: 1, max: 1_200),
      ],
      required: ["action", "samples", "intervalMilliseconds"],
      additionalProperties: false)
  }
}

public struct CaptureProfileActionResponse: Codable, Sendable, Equatable,
  JSONSchemaProviding
{
  public var ok: Bool
  public var format: String
  public var profileBase64: String
  public var byteCount: Int
  public var pid: Int

  public init(profileData: Data, pid: Int) {
    self.ok = true
    self.format = "perf-script"
    self.profileBase64 = profileData.base64EncodedString()
    self.byteCount = profileData.count
    self.pid = pid
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "byteCount": .integer(min: 1, max: nil),
        "format": .string(
          enumValues: nil, const: "perf-script", format: nil, pattern: nil),
        "ok": .boolean,
        "pid": .integer(min: 1, max: nil),
        "profileBase64": .string(
          enumValues: nil, const: nil, format: "byte", pattern: nil),
      ],
      required: ["ok", "format", "profileBase64", "byteCount", "pid"],
      additionalProperties: false)
  }
}

/// Stable wire projection for `GET /debug/transparency`. Requested values are
/// never overwritten by temporary accessibility/full-screen policy.
public struct TerminalTransparencyDebugResponse: Codable, Sendable, Equatable,
  JSONSchemaProviding
{
  private enum CodingKeys: String, CodingKey {
    case requestedOpacity
    case effectiveOpacity
    case requestedBlur
    case effectiveBlur
    case requestedBackdropStyle
    case effectiveBackdropStyle
    case backgroundImageScaling
    case backgroundImageState
    case backgroundImageIdentifier
    case backgroundImagePixelWidth
    case backgroundImagePixelHeight
    case backgroundImageContentDigest
    case backgroundImageImportCount
    case backgroundImageDecodeCount
    case backgroundImageFileReadCount
    case backgroundImageApplyCount
    case backgroundImageRedrawCount
    case applyToExplicitCellBackgrounds
    case forceOpaqueReason
    case surfaceOpaque
    case effectiveGlyphAntialiasing
    case effectiveGlyphAntialiasingReason
    case snapshotExplicitBackgroundCapability
    case configuredRenderer
    case effectiveRenderer
    case themeName
    case themeIsDark
    case effectiveAppearance
    case backdropSubviewCount
    case backdropSubviewKind
    case windowBlurAvailable
    case windowBlurRadius
    case systemReduceTransparency
    case reduceTransparencyOverride
    case effectiveReduceTransparency
    case nativeFullscreen
    case accessibilityRefreshCount
    case effectiveTransparencyApplyCount
    case transparencyRenderWakeCount
    case rendererPresentCount
    case presentIntervalDeadlineMisses
  }

  public var requestedOpacity: Double
  public var effectiveOpacity: Double
  public var requestedBlur: Double
  public var effectiveBlur: Double
  public var requestedBackdropStyle: String
  public var effectiveBackdropStyle: String
  public var backgroundImageScaling: String
  public var backgroundImageState: String
  public var backgroundImageIdentifier: String?
  public var backgroundImagePixelWidth: Int?
  public var backgroundImagePixelHeight: Int?
  public var backgroundImageContentDigest: String?
  public var backgroundImageImportCount: Int
  public var backgroundImageDecodeCount: Int
  public var backgroundImageFileReadCount: Int
  public var backgroundImageApplyCount: Int
  public var backgroundImageRedrawCount: Int
  public var applyToExplicitCellBackgrounds: Bool
  public var forceOpaqueReason: String?
  public var surfaceOpaque: Bool
  public var effectiveGlyphAntialiasing: String
  public var effectiveGlyphAntialiasingReason: String?
  public var snapshotExplicitBackgroundCapability: String
  public var configuredRenderer: String
  public var effectiveRenderer: String
  public var themeName: String
  public var themeIsDark: Bool
  public var effectiveAppearance: String
  public var backdropSubviewCount: Int
  public var backdropSubviewKind: String
  public var windowBlurAvailable: Bool
  public var windowBlurRadius: Int
  public var systemReduceTransparency: Bool
  public var reduceTransparencyOverride: Bool?
  public var effectiveReduceTransparency: Bool
  public var nativeFullscreen: Bool
  public var accessibilityRefreshCount: Int
  public var effectiveTransparencyApplyCount: Int
  public var transparencyRenderWakeCount: Int
  public var rendererPresentCount: Int
  public var presentIntervalDeadlineMisses: Int

  public init(
    requestedOpacity: Double,
    effectiveOpacity: Double,
    requestedBlur: Double,
    effectiveBlur: Double,
    requestedBackdropStyle: String,
    effectiveBackdropStyle: String,
    backgroundImageScaling: String,
    backgroundImageState: String,
    backgroundImageIdentifier: String? = nil,
    backgroundImagePixelWidth: Int? = nil,
    backgroundImagePixelHeight: Int? = nil,
    backgroundImageContentDigest: String? = nil,
    backgroundImageImportCount: Int = 0,
    backgroundImageDecodeCount: Int = 0,
    backgroundImageFileReadCount: Int = 0,
    backgroundImageApplyCount: Int = 0,
    backgroundImageRedrawCount: Int = 0,
    applyToExplicitCellBackgrounds: Bool,
    forceOpaqueReason: String?,
    surfaceOpaque: Bool,
    effectiveGlyphAntialiasing: String,
    effectiveGlyphAntialiasingReason: String?,
    snapshotExplicitBackgroundCapability: String,
    configuredRenderer: String,
    effectiveRenderer: String,
    themeName: String,
    themeIsDark: Bool,
    effectiveAppearance: String,
    backdropSubviewCount: Int,
    backdropSubviewKind: String,
    windowBlurAvailable: Bool,
    windowBlurRadius: Int,
    systemReduceTransparency: Bool,
    reduceTransparencyOverride: Bool?,
    effectiveReduceTransparency: Bool,
    nativeFullscreen: Bool,
    accessibilityRefreshCount: Int,
    effectiveTransparencyApplyCount: Int,
    transparencyRenderWakeCount: Int,
    rendererPresentCount: Int,
    presentIntervalDeadlineMisses: Int
  ) {
    self.requestedOpacity = requestedOpacity
    self.effectiveOpacity = effectiveOpacity
    self.requestedBlur = requestedBlur
    self.effectiveBlur = effectiveBlur
    self.requestedBackdropStyle = requestedBackdropStyle
    self.effectiveBackdropStyle = effectiveBackdropStyle
    self.backgroundImageScaling = backgroundImageScaling
    self.backgroundImageState = backgroundImageState
    self.backgroundImageIdentifier = backgroundImageIdentifier
    self.backgroundImagePixelWidth = backgroundImagePixelWidth
    self.backgroundImagePixelHeight = backgroundImagePixelHeight
    self.backgroundImageContentDigest = backgroundImageContentDigest
    self.backgroundImageImportCount = backgroundImageImportCount
    self.backgroundImageDecodeCount = backgroundImageDecodeCount
    self.backgroundImageFileReadCount = backgroundImageFileReadCount
    self.backgroundImageApplyCount = backgroundImageApplyCount
    self.backgroundImageRedrawCount = backgroundImageRedrawCount
    self.applyToExplicitCellBackgrounds = applyToExplicitCellBackgrounds
    self.forceOpaqueReason = forceOpaqueReason
    self.surfaceOpaque = surfaceOpaque
    self.effectiveGlyphAntialiasing = effectiveGlyphAntialiasing
    self.effectiveGlyphAntialiasingReason = effectiveGlyphAntialiasingReason
    self.snapshotExplicitBackgroundCapability = snapshotExplicitBackgroundCapability
    self.configuredRenderer = configuredRenderer
    self.effectiveRenderer = effectiveRenderer
    self.themeName = themeName
    self.themeIsDark = themeIsDark
    self.effectiveAppearance = effectiveAppearance
    self.backdropSubviewCount = backdropSubviewCount
    self.backdropSubviewKind = backdropSubviewKind
    self.windowBlurAvailable = windowBlurAvailable
    self.windowBlurRadius = windowBlurRadius
    self.systemReduceTransparency = systemReduceTransparency
    self.reduceTransparencyOverride = reduceTransparencyOverride
    self.effectiveReduceTransparency = effectiveReduceTransparency
    self.nativeFullscreen = nativeFullscreen
    self.accessibilityRefreshCount = accessibilityRefreshCount
    self.effectiveTransparencyApplyCount = effectiveTransparencyApplyCount
    self.transparencyRenderWakeCount = transparencyRenderWakeCount
    self.rendererPresentCount = rendererPresentCount
    self.presentIntervalDeadlineMisses = presentIntervalDeadlineMisses
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(requestedOpacity, forKey: .requestedOpacity)
    try container.encode(effectiveOpacity, forKey: .effectiveOpacity)
    try container.encode(requestedBlur, forKey: .requestedBlur)
    try container.encode(effectiveBlur, forKey: .effectiveBlur)
    try container.encode(requestedBackdropStyle, forKey: .requestedBackdropStyle)
    try container.encode(effectiveBackdropStyle, forKey: .effectiveBackdropStyle)
    try container.encode(backgroundImageScaling, forKey: .backgroundImageScaling)
    try container.encode(backgroundImageState, forKey: .backgroundImageState)
    // These keys are required stable fields in the checked response schema.
    // Encode absent metadata as JSON null rather than omitting the keys.
    try container.encode(backgroundImageIdentifier, forKey: .backgroundImageIdentifier)
    try container.encode(backgroundImagePixelWidth, forKey: .backgroundImagePixelWidth)
    try container.encode(backgroundImagePixelHeight, forKey: .backgroundImagePixelHeight)
    try container.encode(backgroundImageContentDigest, forKey: .backgroundImageContentDigest)
    try container.encode(backgroundImageImportCount, forKey: .backgroundImageImportCount)
    try container.encode(backgroundImageDecodeCount, forKey: .backgroundImageDecodeCount)
    try container.encode(backgroundImageFileReadCount, forKey: .backgroundImageFileReadCount)
    try container.encode(backgroundImageApplyCount, forKey: .backgroundImageApplyCount)
    try container.encode(backgroundImageRedrawCount, forKey: .backgroundImageRedrawCount)
    try container.encode(applyToExplicitCellBackgrounds, forKey: .applyToExplicitCellBackgrounds)
    try container.encodeIfPresent(forceOpaqueReason, forKey: .forceOpaqueReason)
    try container.encode(surfaceOpaque, forKey: .surfaceOpaque)
    try container.encode(effectiveGlyphAntialiasing, forKey: .effectiveGlyphAntialiasing)
    try container.encodeIfPresent(
      effectiveGlyphAntialiasingReason,
      forKey: .effectiveGlyphAntialiasingReason)
    try container.encode(
      snapshotExplicitBackgroundCapability,
      forKey: .snapshotExplicitBackgroundCapability)
    try container.encode(configuredRenderer, forKey: .configuredRenderer)
    try container.encode(effectiveRenderer, forKey: .effectiveRenderer)
    try container.encode(themeName, forKey: .themeName)
    try container.encode(themeIsDark, forKey: .themeIsDark)
    try container.encode(effectiveAppearance, forKey: .effectiveAppearance)
    try container.encode(backdropSubviewCount, forKey: .backdropSubviewCount)
    try container.encode(backdropSubviewKind, forKey: .backdropSubviewKind)
    try container.encode(windowBlurAvailable, forKey: .windowBlurAvailable)
    try container.encode(windowBlurRadius, forKey: .windowBlurRadius)
    try container.encode(systemReduceTransparency, forKey: .systemReduceTransparency)
    // The reset state is observable evidence, not an absent projection field.
    // Encode nil as JSON null so clients can distinguish "system value" from
    // an older server that does not expose the override contract.
    try container.encode(reduceTransparencyOverride, forKey: .reduceTransparencyOverride)
    try container.encode(effectiveReduceTransparency, forKey: .effectiveReduceTransparency)
    try container.encode(nativeFullscreen, forKey: .nativeFullscreen)
    try container.encode(accessibilityRefreshCount, forKey: .accessibilityRefreshCount)
    try container.encode(effectiveTransparencyApplyCount, forKey: .effectiveTransparencyApplyCount)
    try container.encode(transparencyRenderWakeCount, forKey: .transparencyRenderWakeCount)
    try container.encode(rendererPresentCount, forKey: .rendererPresentCount)
    try container.encode(presentIntervalDeadlineMisses, forKey: .presentIntervalDeadlineMisses)
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "requestedOpacity": .number(min: 0, max: 1),
        "effectiveOpacity": .number(min: 0, max: 1),
        "requestedBlur": .number(min: 0, max: 1),
        "effectiveBlur": .number(min: 0, max: 1),
        "requestedBackdropStyle": .string(
          enumValues: TerminalBackdropStyle.allCases.map(\.rawValue), const: nil, format: nil,
          pattern: nil),
        "effectiveBackdropStyle": .string(
          enumValues: TerminalBackdropStyle.allCases.map(\.rawValue), const: nil, format: nil,
          pattern: nil),
        "backgroundImageScaling": .string(
          enumValues: TerminalBackgroundImageScaling.allCases.map(\.rawValue), const: nil,
          format: nil, pattern: nil),
        "backgroundImageState": .string(
          enumValues: TerminalBackgroundImageAvailability.allCases.map(\.rawValue), const: nil,
          format: nil, pattern: nil),
        "backgroundImageIdentifier": .optional(
          .string(enumValues: nil, const: nil, format: nil, pattern: nil)),
        "backgroundImagePixelWidth": .optional(.integer(min: 1, max: nil)),
        "backgroundImagePixelHeight": .optional(.integer(min: 1, max: nil)),
        "backgroundImageContentDigest": .optional(
          .string(enumValues: nil, const: nil, format: nil, pattern: "^[0-9a-f]{64}$")),
        "backgroundImageImportCount": .integer(min: 0, max: nil),
        "backgroundImageDecodeCount": .integer(min: 0, max: nil),
        "backgroundImageFileReadCount": .integer(min: 0, max: nil),
        "backgroundImageApplyCount": .integer(min: 0, max: nil),
        "backgroundImageRedrawCount": .integer(min: 0, max: nil),
        "applyToExplicitCellBackgrounds": .boolean,
        "forceOpaqueReason": .optional(
          .string(
            enumValues: [
              TerminalTransparencyForceOpaqueReason.reduceTransparency.rawValue,
              TerminalTransparencyForceOpaqueReason.nativeFullscreen.rawValue,
              TerminalTransparencyForceOpaqueReason.legacySnapshotWriter.rawValue,
              TerminalTransparencyForceOpaqueReason.backgroundImageUnavailable.rawValue,
            ], const: nil, format: nil, pattern: nil)),
        "surfaceOpaque": .boolean,
        "effectiveGlyphAntialiasing": .string(
          enumValues: nil, const: nil, format: nil, pattern: nil),
        "effectiveGlyphAntialiasingReason": .optional(
          .string(enumValues: nil, const: nil, format: nil, pattern: nil)),
        "snapshotExplicitBackgroundCapability": .string(
          enumValues: TerminalSnapshotBackgroundCapability.allCases.map(\.rawValue), const: nil,
          format: nil, pattern: nil),
        "configuredRenderer": .string(enumValues: nil, const: nil, format: nil, pattern: nil),
        "effectiveRenderer": .string(enumValues: nil, const: nil, format: nil, pattern: nil),
        "themeName": .string(enumValues: nil, const: nil, format: nil, pattern: nil),
        "themeIsDark": .boolean,
        "effectiveAppearance": .string(
          enumValues: ["aqua", "darkAqua", "headless"], const: nil, format: nil, pattern: nil),
        "backdropSubviewCount": .integer(min: 0, max: 1),
        "backdropSubviewKind": .string(
          enumValues: TerminalBackdropStyle.allCases.map(\.rawValue), const: nil, format: nil,
          pattern: nil),
        "windowBlurAvailable": .boolean,
        "windowBlurRadius": .integer(min: 0, max: 100),
        "systemReduceTransparency": .boolean,
        "reduceTransparencyOverride": .optional(.boolean),
        "effectiveReduceTransparency": .boolean,
        "nativeFullscreen": .boolean,
        "accessibilityRefreshCount": .integer(min: 0, max: nil),
        "effectiveTransparencyApplyCount": .integer(min: 0, max: nil),
        "transparencyRenderWakeCount": .integer(min: 0, max: nil),
        "rendererPresentCount": .integer(min: 0, max: nil),
        "presentIntervalDeadlineMisses": .integer(min: 0, max: nil),
      ],
      required: [
        "requestedOpacity", "effectiveOpacity", "requestedBlur", "effectiveBlur",
        "requestedBackdropStyle",
        "effectiveBackdropStyle", "backgroundImageScaling", "backgroundImageState",
        "backgroundImageIdentifier", "backgroundImagePixelWidth", "backgroundImagePixelHeight",
        "backgroundImageContentDigest", "backgroundImageImportCount", "backgroundImageDecodeCount",
        "backgroundImageFileReadCount", "backgroundImageApplyCount", "backgroundImageRedrawCount",
        "applyToExplicitCellBackgrounds", "surfaceOpaque",
        "effectiveGlyphAntialiasing", "snapshotExplicitBackgroundCapability",
        "configuredRenderer", "effectiveRenderer", "themeName", "themeIsDark",
        "effectiveAppearance", "backdropSubviewCount",
        "backdropSubviewKind", "windowBlurAvailable", "windowBlurRadius",
        "systemReduceTransparency", "effectiveReduceTransparency", "nativeFullscreen",
        "accessibilityRefreshCount", "effectiveTransparencyApplyCount",
        "transparencyRenderWakeCount", "rendererPresentCount",
        "presentIntervalDeadlineMisses",
      ],
      additionalProperties: false)
  }
}

public struct LegacyDebugActionInput: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var intentID: String
  public var action: String
  public var body: Data
  /// When set, session-scoped actions default their target to this session (C12).
  public var scopedSessionID: String?

  public init(
    intentID: String,
    action: String,
    body: Data = Data(),
    scopedSessionID: String? = nil
  ) {
    self.intentID = intentID
    self.action = action
    self.body = body
    self.scopedSessionID = scopedSessionID
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "action": DebugPayloadSchema.string,
        "body": SchemaNode.string(enumValues: nil, const: nil, format: "byte", pattern: nil),
        "intentID": DebugPayloadSchema.string,
      ], required: ["intentID", "action", "body"])
  }
}

public struct LegacyDebugQueryInput: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var intentID: String
  public var params: [String: String]
  /// When set, whole-app reads are filtered to this session (session-observe token scope).
  public var scopedSessionID: String?
  /// Redacts sensitive fields for app-observe callers.
  public var readRedaction: ControlReadRedaction

  public init(
    intentID: String,
    params: [String: String] = [:],
    scopedSessionID: String? = nil,
    readRedaction: ControlReadRedaction = .none
  ) {
    self.intentID = intentID
    self.params = params
    self.scopedSessionID = scopedSessionID
    self.readRedaction = readRedaction
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "intentID": DebugPayloadSchema.string,
        "params": DebugPayloadSchema.object([:]),
      ], required: ["intentID", "params"])
  }
}

public struct LegacyDebugControlInput: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var intentID: String
  public var body: Data
  public var params: [String: String]
  /// When set, session-scoped controls default their target to this session (C12).
  public var scopedSessionID: String?

  public init(
    intentID: String,
    body: Data = Data(),
    params: [String: String] = [:],
    scopedSessionID: String? = nil
  ) {
    self.intentID = intentID
    self.body = body
    self.params = params
    self.scopedSessionID = scopedSessionID
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "body": SchemaNode.string(enumValues: nil, const: nil, format: "byte", pattern: nil),
        "intentID": DebugPayloadSchema.string,
        "params": DebugPayloadSchema.object([:]),
      ], required: ["intentID", "body", "params"])
  }
}

public struct UnsupportedDebugActionInput: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var action: String

  public init(action: String) {
    self.action = action
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(["action": DebugPayloadSchema.string], required: ["action"])
  }
}

/// Request for `commandProposal.get` and `commandProposal.cancel`: names one
/// proposal by id. `commandProposal.list` also decodes as this shape (id is
/// ignored for list).
public struct CommandProposalRefRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var action: String?
  public var proposalID: String?
  public var proposalId: String?

  public init(action: String? = nil, proposalID: String? = nil, proposalId: String? = nil) {
    self.action = action
    self.proposalID = proposalID
    self.proposalId = proposalId
  }

  public func resolvedProposalID() -> String? {
    if let proposalID, !proposalID.isEmpty { return proposalID }
    if let proposalId, !proposalId.isEmpty { return proposalId }
    return nil
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "action": DebugPayloadSchema.string,
        "proposalID": DebugPayloadSchema.string,
        "proposalId": DebugPayloadSchema.string,
      ],
      required: ["action"])
  }
}

public struct CommandProposeRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var action: String?
  public var targetSessionID: String?
  public var targetSessionId: String?
  public var command: String?
  public var purpose: String?

  public init(
    action: String? = "propose",
    targetSessionID: String? = nil,
    targetSessionId: String? = nil,
    command: String? = nil,
    purpose: String? = nil
  ) {
    self.action = action
    self.targetSessionID = targetSessionID
    self.targetSessionId = targetSessionId
    self.command = command
    self.purpose = purpose
  }

  public func resolvedTargetSessionID(fallback: String?) -> String? {
    if let targetSessionID, !targetSessionID.isEmpty { return targetSessionID }
    if let targetSessionId, !targetSessionId.isEmpty { return targetSessionId }
    return fallback
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "action": DebugPayloadSchema.string,
        "command": DebugPayloadSchema.string,
        "purpose": DebugPayloadSchema.string,
        "targetSessionID": DebugPayloadSchema.string,
        "targetSessionId": DebugPayloadSchema.string,
      ],
      required: ["action", "command"],
      additionalProperties: false)
  }
}

public struct CellCoordinateReq: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var row: Int
  public var col: Int

  public init(row: Int, col: Int) {
    self.row = row
    self.col = col
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "col": DebugPayloadSchema.integer,
        "row": DebugPayloadSchema.integer,
      ], required: ["row", "col"])
  }
}

public struct TabTargetActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var tabId: String?

  public init(tabId: String? = nil) {
    self.tabId = tabId
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(["tabId": DebugPayloadSchema.string])
  }
}

public struct SelectTabActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var action: String?
  public var tabId: String?
  public var index: Int?

  public init(action: String? = nil, tabId: String? = nil, index: Int? = nil) {
    self.action = action
    self.tabId = tabId
    self.index = index
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "action": DebugPayloadSchema.string,
      "index": SchemaNode.integer(min: 0, max: nil),
      "tabId": DebugPayloadSchema.string,
    ])
  }
}

public struct MoveTabActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var tabId: String?
  public var toIndex: Int?

  public init(tabId: String? = nil, toIndex: Int? = nil) {
    self.tabId = tabId
    self.toIndex = toIndex
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "tabId": DebugPayloadSchema.string,
      "toIndex": SchemaNode.integer(min: 0, max: nil),
    ])
  }
}

public struct TabTitleActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var tabId: String?
  public var title: String?
  public var text: String?
  public var frozen: Bool?

  public init(
    tabId: String? = nil,
    title: String? = nil,
    text: String? = nil,
    frozen: Bool? = nil
  ) {
    self.tabId = tabId
    self.title = title
    self.text = text
    self.frozen = frozen
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "frozen": DebugPayloadSchema.boolean,
      "tabId": DebugPayloadSchema.string,
      "text": DebugPayloadSchema.string,
      "title": DebugPayloadSchema.string,
    ])
  }
}

public struct TabMetadataActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var tabId: String?
  public var cwd: String?
  public var repoName: String?
  public var repoRoot: String?
  public var worktreeName: String?
  public var branch: String?
  public var isDirty: Bool?
  public var foregroundProcess: String?
  public var foregroundCommand: String?
  public var pid: Int?
  public var agentName: String?
  public var sessionName: String?
  public var agentSessionId: String?
  public var taskLabel: String?
  public var model: String?
  public var contextPercent: Int?
  public var awaitingInput: Bool?
  public var activityState: String?
  public var unseenOutput: Bool?
  public var bellAttention: Bool?
  public var exitStatus: Int?

  public init(
    tabId: String? = nil,
    cwd: String? = nil,
    repoName: String? = nil,
    repoRoot: String? = nil,
    worktreeName: String? = nil,
    branch: String? = nil,
    isDirty: Bool? = nil,
    foregroundProcess: String? = nil,
    foregroundCommand: String? = nil,
    pid: Int? = nil,
    agentName: String? = nil,
    sessionName: String? = nil,
    agentSessionId: String? = nil,
    taskLabel: String? = nil,
    model: String? = nil,
    contextPercent: Int? = nil,
    awaitingInput: Bool? = nil,
    activityState: String? = nil,
    unseenOutput: Bool? = nil,
    bellAttention: Bool? = nil,
    exitStatus: Int? = nil
  ) {
    self.tabId = tabId
    self.cwd = cwd
    self.repoName = repoName
    self.repoRoot = repoRoot
    self.worktreeName = worktreeName
    self.branch = branch
    self.isDirty = isDirty
    self.foregroundProcess = foregroundProcess
    self.foregroundCommand = foregroundCommand
    self.pid = pid
    self.agentName = agentName
    self.sessionName = sessionName
    self.agentSessionId = agentSessionId
    self.taskLabel = taskLabel
    self.model = model
    self.contextPercent = contextPercent
    self.awaitingInput = awaitingInput
    self.activityState = activityState
    self.unseenOutput = unseenOutput
    self.bellAttention = bellAttention
    self.exitStatus = exitStatus
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "activityState": DebugPayloadSchema.string,
      "agentName": DebugPayloadSchema.string,
      "agentSessionId": DebugPayloadSchema.string,
      "awaitingInput": DebugPayloadSchema.boolean,
      "bellAttention": DebugPayloadSchema.boolean,
      "branch": DebugPayloadSchema.string,
      "contextPercent": DebugPayloadSchema.integer,
      "cwd": DebugPayloadSchema.string,
      "exitStatus": DebugPayloadSchema.integer,
      "foregroundCommand": DebugPayloadSchema.string,
      "foregroundProcess": DebugPayloadSchema.string,
      "isDirty": DebugPayloadSchema.boolean,
      "model": DebugPayloadSchema.string,
      "pid": DebugPayloadSchema.integer,
      "repoName": DebugPayloadSchema.string,
      "repoRoot": DebugPayloadSchema.string,
      "sessionName": DebugPayloadSchema.string,
      "tabId": DebugPayloadSchema.string,
      "taskLabel": DebugPayloadSchema.string,
      "unseenOutput": DebugPayloadSchema.boolean,
      "worktreeName": DebugPayloadSchema.string,
    ])
  }
}

public struct ResizeWindowActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var width: Int?
  public var height: Int?

  public init(width: Int? = nil, height: Int? = nil) {
    self.width = width
    self.height = height
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "height": DebugPayloadSchema.integer,
      "width": DebugPayloadSchema.integer,
    ])
  }
}

public struct SetFontSizeActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var pointSize: Double?

  public init(pointSize: Double? = nil) {
    self.pointSize = pointSize
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(["pointSize": DebugPayloadSchema.number])
  }
}

public struct TextActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var text: String?
  public var tabId: String?

  public init(text: String? = nil, tabId: String? = nil) {
    self.text = text
    self.tabId = tabId
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "tabId": DebugPayloadSchema.string,
      "text": DebugPayloadSchema.string,
    ])
  }
}

public struct SetRendererActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var renderer: String?

  public init(renderer: String? = nil) {
    self.renderer = renderer
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "renderer": SchemaNode.string(
          enumValues: ["software", "classic", "gpuDriven", "vectorGlyph", "slugGlyph"],
          const: nil,
          format: nil,
          pattern: nil)
      ], required: ["renderer"])
  }
}

public struct AdvanceFramesActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var count: Int?

  public init(count: Int? = nil) {
    self.count = count
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(["count": SchemaNode.integer(min: 1, max: nil)])
  }
}

public struct AdvanceTimeActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  /// Hard ceiling so a typo cannot jump the virtual clock by minutes/hours.
  /// Scenario fixtures use ≤300 ms steps; 60 s is still ample for long settles.
  public static let maxMilliseconds = 60_000

  public var ms: Int?

  public init(ms: Int? = nil) {
    self.ms = ms
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "ms": SchemaNode.integer(min: 1, max: maxMilliseconds)
    ])
  }
}

public struct SetGlyphEffectsEnabledActionRequest: Codable, Sendable, Equatable,
  JSONSchemaProviding
{
  public var enabled: Bool?

  public init(enabled: Bool? = nil) {
    self.enabled = enabled
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(["enabled": DebugPayloadSchema.boolean], required: ["enabled"])
  }
}

public struct VectorSubpixelLayoutActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var layout: String?
  public var offsets: [Double]?
  public var areas: [[Double]]?

  public init(layout: String? = nil, offsets: [Double]? = nil, areas: [[Double]]? = nil) {
    self.layout = layout
    self.offsets = offsets
    self.areas = areas
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "layout": DebugPayloadSchema.string,
      "offsets": .array(DebugPayloadSchema.number, minItems: 3),
      "areas": .array(.array(DebugPayloadSchema.number, minItems: 4), minItems: 3),
    ])
  }
}

public struct WindowFocusActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var focused: Bool?

  public init(focused: Bool? = nil) {
    self.focused = focused
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(["focused": DebugPayloadSchema.boolean])
  }
}

public struct DebugKeyActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var key: String?
  public var type: String?
  public var modifiers: [String]?
  public var consumedModifiers: [String]?
  public var unshifted: String?
  public var text: String?

  public init(
    key: String? = nil,
    type: String? = nil,
    modifiers: [String]? = nil,
    consumedModifiers: [String]? = nil,
    unshifted: String? = nil,
    text: String? = nil
  ) {
    self.key = key
    self.type = type
    self.modifiers = modifiers
    self.consumedModifiers = consumedModifiers
    self.unshifted = unshifted
    self.text = text
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "consumedModifiers": DebugPayloadSchema.stringArray(),
      "key": DebugPayloadSchema.string,
      "modifiers": DebugPayloadSchema.stringArray(),
      "text": DebugPayloadSchema.string,
      "type": DebugPayloadSchema.string,
      "unshifted": DebugPayloadSchema.string,
    ])
  }
}

public struct MouseWheelActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var x: Int?
  public var y: Int?
  public var deltaY: Double?

  public init(x: Int? = nil, y: Int? = nil, deltaY: Double? = nil) {
    self.x = x
    self.y = y
    self.deltaY = deltaY
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "deltaY": DebugPayloadSchema.number,
      "x": DebugPayloadSchema.integer,
      "y": DebugPayloadSchema.integer,
    ])
  }
}

public struct MouseDragActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var startX: Int?
  public var startY: Int?
  public var endX: Int?
  public var endY: Int?
  public var button: String?
  public var holdMs: Int?

  public init(
    startX: Int? = nil,
    startY: Int? = nil,
    endX: Int? = nil,
    endY: Int? = nil,
    button: String? = nil,
    holdMs: Int? = nil
  ) {
    self.startX = startX
    self.startY = startY
    self.endX = endX
    self.endY = endY
    self.button = button
    self.holdMs = holdMs
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "button": DebugPayloadSchema.string,
      "endX": DebugPayloadSchema.integer,
      "endY": DebugPayloadSchema.integer,
      "holdMs": SchemaNode.integer(min: 0, max: nil),
      "startX": DebugPayloadSchema.integer,
      "startY": DebugPayloadSchema.integer,
    ])
  }
}

public struct ClickActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var x: Int?
  public var y: Int?
  public var button: String?

  public init(x: Int? = nil, y: Int? = nil, button: String? = nil) {
    self.x = x
    self.y = y
    self.button = button
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "button": DebugPayloadSchema.string,
      "x": DebugPayloadSchema.integer,
      "y": DebugPayloadSchema.integer,
    ])
  }
}

public struct SelectionActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var sessionId: String?
  public var anchor: CellCoordinateReq?
  public var focus: CellCoordinateReq?

  public init(
    sessionId: String? = nil,
    anchor: CellCoordinateReq? = nil,
    focus: CellCoordinateReq? = nil
  ) {
    self.sessionId = sessionId
    self.anchor = anchor
    self.focus = focus
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "anchor": CellCoordinateReq.jsonSchema,
      "focus": CellCoordinateReq.jsonSchema,
      "sessionId": DebugPayloadSchema.string,
    ])
  }
}

public struct PreeditActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var sessionId: String?
  public var text: String?
  public var caretCells: Int?

  public init(sessionId: String? = nil, text: String? = nil, caretCells: Int? = nil) {
    self.sessionId = sessionId
    self.text = text
    self.caretCells = caretCells
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "caretCells": DebugPayloadSchema.integer,
      "sessionId": DebugPayloadSchema.string,
      "text": DebugPayloadSchema.string,
    ])
  }
}

public struct SessionTargetActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var sessionId: String?

  public init(sessionId: String? = nil) {
    self.sessionId = sessionId
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(["sessionId": DebugPayloadSchema.string])
  }
}

public struct DropFilesActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var paths: [String]?

  public init(paths: [String]? = nil) {
    self.paths = paths
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(["paths": DebugPayloadSchema.stringArray()])
  }
}

public struct ScrollViewportActionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var sessionId: String?
  public var deltaRows: Int?

  public init(sessionId: String? = nil, deltaRows: Int? = nil) {
    self.sessionId = sessionId
    self.deltaRows = deltaRows
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "deltaRows": DebugPayloadSchema.integer,
      "sessionId": DebugPayloadSchema.string,
    ])
  }
}

public struct FindStartRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var sessionID: String?
  public var sessionId: String?
  public var needle: String?

  public var targetSessionId: String? { sessionID ?? sessionId }

  public init(sessionID: String? = nil, sessionId: String? = nil, needle: String? = nil) {
    self.sessionID = sessionID
    self.sessionId = sessionId
    self.needle = needle
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "needle": DebugPayloadSchema.string,
      "sessionID": DebugPayloadSchema.string,
      "sessionId": DebugPayloadSchema.string,
    ])
  }
}

public struct FindStepRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var sessionID: String?
  public var sessionId: String?
  public var direction: String?

  public var targetSessionId: String? { sessionID ?? sessionId }

  public init(sessionID: String? = nil, sessionId: String? = nil, direction: String? = nil) {
    self.sessionID = sessionID
    self.sessionId = sessionId
    self.direction = direction
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "direction": DebugPayloadSchema.string,
      "sessionID": DebugPayloadSchema.string,
      "sessionId": DebugPayloadSchema.string,
    ])
  }
}

public struct FindSessionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var sessionID: String?
  public var sessionId: String?

  public var targetSessionId: String? { sessionID ?? sessionId }

  public init(sessionID: String? = nil, sessionId: String? = nil) {
    self.sessionID = sessionID
    self.sessionId = sessionId
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "sessionID": DebugPayloadSchema.string,
      "sessionId": DebugPayloadSchema.string,
    ])
  }
}

public struct CaptureStartRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var name: String?
  public var screenshots: String?

  public init(name: String? = nil, screenshots: String? = nil) {
    self.name = name
    self.screenshots = screenshots
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "name": DebugPayloadSchema.string,
      "screenshots": DebugPayloadSchema.string,
    ])
  }
}

public struct WaitRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var timeoutMs: Int
  public var condition: WaitCondition

  public init(timeoutMs: Int, condition: WaitCondition) {
    self.timeoutMs = timeoutMs
    self.condition = condition
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "condition": WaitCondition.jsonSchema,
        "timeoutMs": SchemaNode.integer(min: 0, max: nil),
      ], required: ["timeoutMs", "condition"])
  }
}

public struct WaitCondition: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var kind: String
  public var frame: Int?
  public var eventKind: String?
  public var count: Int?
  public var tabId: String?
  public var sessionId: String?
  public var status: String?
  public var title: String?
  public var text: String?
  public var commandKind: String?
  public var invariantKind: String?
  public var level: String?

  public init(
    kind: String,
    frame: Int? = nil,
    eventKind: String? = nil,
    count: Int? = nil,
    tabId: String? = nil,
    sessionId: String? = nil,
    status: String? = nil,
    title: String? = nil,
    text: String? = nil,
    commandKind: String? = nil,
    invariantKind: String? = nil,
    level: String? = nil
  ) {
    self.kind = kind
    self.frame = frame
    self.eventKind = eventKind
    self.count = count
    self.tabId = tabId
    self.sessionId = sessionId
    self.status = status
    self.title = title
    self.text = text
    self.commandKind = commandKind
    self.invariantKind = invariantKind
    self.level = level
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "commandKind": DebugPayloadSchema.string,
        "count": DebugPayloadSchema.integer,
        "eventKind": DebugPayloadSchema.string,
        "frame": DebugPayloadSchema.integer,
        "invariantKind": DebugPayloadSchema.string,
        "kind": DebugPayloadSchema.string,
        "level": DebugPayloadSchema.string,
        "sessionId": DebugPayloadSchema.string,
        "status": DebugPayloadSchema.string,
        "tabId": DebugPayloadSchema.string,
        "text": DebugPayloadSchema.string,
        "title": DebugPayloadSchema.string,
      ], required: ["kind"])
  }
}

public struct RenderTraceRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var frame: Int?
  public var target: String?
  public var include: [String]?
  public var commandIds: [String]?
  public var pixelProbes: [PixelProbeReq]?
  public var limit: Int?

  public init(
    frame: Int? = nil,
    target: String? = nil,
    include: [String]? = nil,
    commandIds: [String]? = nil,
    pixelProbes: [PixelProbeReq]? = nil,
    limit: Int? = nil
  ) {
    self.frame = frame
    self.target = target
    self.include = include
    self.commandIds = commandIds
    self.pixelProbes = pixelProbes
    self.limit = limit
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "commandIds": DebugPayloadSchema.stringArray(),
      "frame": DebugPayloadSchema.integer,
      "include": DebugPayloadSchema.stringArray(),
      "limit": SchemaNode.integer(min: 0, max: nil),
      "pixelProbes": .array(PixelProbeReq.jsonSchema, minItems: 0),
      "target": DebugPayloadSchema.string,
    ])
  }
}

public struct PixelProbeReq: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var name: String?
  public var x: Int
  public var y: Int

  public init(name: String? = nil, x: Int, y: Int) {
    self.name = name
    self.x = x
    self.y = y
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "name": DebugPayloadSchema.string,
        "x": DebugPayloadSchema.integer,
        "y": DebugPayloadSchema.integer,
      ], required: ["x", "y"])
  }
}

public struct PixelProbePointRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var x: Int
  public var y: Int

  public init(x: Int, y: Int) {
    self.x = x
    self.y = y
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "x": DebugPayloadSchema.integer,
        "y": DebugPayloadSchema.integer,
      ], required: ["x", "y"])
  }
}

public struct PixelProbeRegionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var name: String
  public var x: Int
  public var y: Int
  public var width: Int
  public var height: Int

  public init(name: String, x: Int, y: Int, width: Int, height: Int) {
    self.name = name
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "height": SchemaNode.integer(min: 1, max: nil),
        "name": DebugPayloadSchema.string,
        "width": SchemaNode.integer(min: 1, max: nil),
        "x": DebugPayloadSchema.integer,
        "y": DebugPayloadSchema.integer,
      ], required: ["name", "x", "y", "width", "height"])
  }
}

public struct PixelProbeRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var points: [PixelProbePointRequest]?
  public var regions: [PixelProbeRegionRequest]?

  public init(points: [PixelProbePointRequest]? = nil, regions: [PixelProbeRegionRequest]? = nil) {
    self.points = points
    self.regions = regions
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "points": .array(PixelProbePointRequest.jsonSchema, minItems: 0),
      "regions": .array(PixelProbeRegionRequest.jsonSchema, minItems: 0),
    ])
  }
}

public struct FixtureControlRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var action: String
  public var path: String?
  public var count: Int?

  public init(action: String, path: String? = nil, count: Int? = nil) {
    self.action = action
    self.path = path
    self.count = count
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "action": DebugPayloadSchema.string,
        "count": SchemaNode.integer(min: 1, max: nil),
        "path": DebugPayloadSchema.string,
      ], required: ["action"])
  }
}

public struct AgentRestoreSelectionRequest: Codable, Sendable, Equatable, JSONSchemaProviding {
  public var tabIds: [String]?
  public var selectedTabIds: [String]?
  public var environmentPatch: [String: String]?

  public init(
    tabIds: [String]? = nil,
    selectedTabIds: [String]? = nil,
    environmentPatch: [String: String]? = nil
  ) {
    self.tabIds = tabIds
    self.selectedTabIds = selectedTabIds
    self.environmentPatch = environmentPatch
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "environmentPatch": .object(
        properties: [:],
        required: [],
        additionalProperties: true),
      "selectedTabIds": DebugPayloadSchema.stringArray(),
      "tabIds": DebugPayloadSchema.stringArray(),
    ])
  }
}

public struct NativeNotificationTestRequest: Codable, Sendable, Equatable,
  JSONSchemaProviding
{
  public var title: String?
  public var body: String?
  public var soundEnabled: Bool?

  public init(title: String? = nil, body: String? = nil, soundEnabled: Bool? = nil) {
    self.title = title
    self.body = body
    self.soundEnabled = soundEnabled
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object([
      "body": DebugPayloadSchema.string,
      "soundEnabled": DebugPayloadSchema.boolean,
      "title": DebugPayloadSchema.string,
    ])
  }
}

public struct NativeNotificationTestAcceptedResponse: Codable, Sendable, Equatable,
  JSONSchemaProviding
{
  public var accepted: Bool
  public var eventId: String

  public init(accepted: Bool, eventId: String) {
    self.accepted = accepted
    self.eventId = eventId
  }

  public static var jsonSchema: SchemaNode {
    DebugPayloadSchema.object(
      [
        "accepted": DebugPayloadSchema.boolean,
        "eventId": DebugPayloadSchema.string,
      ], required: ["accepted", "eventId"])
  }
}
