import CoreGraphics
import Foundation
import Metal

public enum RendererSelection: String, Codable, CaseIterable, Sendable {
  case software
  case classic
  case gpuDriven
  case vectorGlyph
  case slugGlyph

  public static let defaultsKey = RendererMode.defaultsKey

  public var isAvailableOnCurrentOS: Bool {
    switch self {
    case .software, .classic, .vectorGlyph, .slugGlyph:
      return true
    case .gpuDriven:
      return RendererMode.gpuDriven.isAvailableOnCurrentOS
    }
  }

  public var metalMode: RendererMode? {
    switch self {
    case .software, .vectorGlyph, .slugGlyph:
      return nil
    case .classic:
      return .classic
    case .gpuDriven:
      return .gpuDriven
    }
  }

  public static func persisted(defaults: UserDefaults = .standard) -> RendererSelection {
    guard let raw = defaults.string(forKey: defaultsKey),
      let selection = RendererSelection(rawValue: raw),
      selection.isAvailableOnCurrentOS
    else {
      return RendererSelection(metalMode: RendererMode.defaultMode)
    }
    return selection
  }

  public static func set(_ selection: RendererSelection, defaults: UserDefaults = .standard) {
    let resolved = selection.isAvailableOnCurrentOS ? selection : .classic
    defaults.set(resolved.rawValue, forKey: defaultsKey)
  }

  public init(metalMode: RendererMode) {
    switch metalMode {
    case .classic:
      self = .classic
    case .gpuDriven:
      self = .gpuDriven
    }
  }
}

public func makeRendererBackend(
  selection: RendererSelection,
  fontAtlas: FontAtlas,
  sidebarFontAtlas: FontAtlas? = nil,
  pixelWidth: Int = 1,
  pixelHeight: Int = 1,
  scale: CGFloat = 1,
  prebuiltRasterAtlas: MetalGlyphAtlas? = nil,
  prebuiltSidebarRasterAtlas: MetalGlyphAtlas? = nil
) -> RendererBackend {
  let resolved = selection.isAvailableOnCurrentOS ? selection : .classic
  let sidebar = sidebarFontAtlas ?? fontAtlas

  switch resolved {
  case .software:
    return SoftwareBackend(
      fontAtlas: fontAtlas,
      sidebarFontAtlas: sidebar,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      scale: scale)

  case .classic, .gpuDriven:
    guard MTLCreateSystemDefaultDevice() != nil else {
      return SoftwareBackend(
        fontAtlas: fontAtlas,
        sidebarFontAtlas: sidebar,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        scale: scale,
        rendererStatus: RendererStatus(
          configuredRenderer: resolved.rawValue,
          effectiveRenderer: RendererSelection.software.rawValue,
          fallbackReason: "noMetalDevice",
          textCompositeModel: .nativePlatformReference))
    }
    if let metalMode = resolved.metalMode,
      let metal = MetalRenderer(
        fontAtlas: fontAtlas,
        sidebarFontAtlas: sidebar,
        scale: scale,
        rendererMode: metalMode)
    {
      metal.resize(pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: scale)
      return metal
    }
    return SoftwareBackend(
      fontAtlas: fontAtlas,
      sidebarFontAtlas: sidebar,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      scale: scale,
      rendererStatus: RendererStatus(
        configuredRenderer: resolved.rawValue,
        effectiveRenderer: RendererSelection.software.rawValue,
        fallbackReason: "metalPipelineUnavailable",
        textCompositeModel: .nativePlatformReference))

  case .vectorGlyph:
    guard MTLCreateSystemDefaultDevice() != nil else {
      return SoftwareBackend(
        fontAtlas: fontAtlas,
        sidebarFontAtlas: sidebar,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        scale: scale,
        rendererStatus: RendererStatus(
          configuredRenderer: RendererSelection.vectorGlyph.rawValue,
          effectiveRenderer: RendererSelection.software.rawValue,
          fallbackReason: "noMetalDevice",
          textCompositeModel: .nativePlatformReference))
    }
    if let vector = VectorGlyphRenderer(
      fontAtlas: fontAtlas,
      sidebarFontAtlas: sidebar,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      scale: scale,
      prebuiltRasterAtlas: prebuiltRasterAtlas,
      prebuiltSidebarRasterAtlas: prebuiltSidebarRasterAtlas)
    {
      vector.setSubpixelLayout(VectorSubpixelLayout.persisted())
      return vector
    }
    if let classic = MetalRenderer(
      fontAtlas: fontAtlas,
      sidebarFontAtlas: sidebar,
      scale: scale,
      rendererMode: .classic)
    {
      classic.resize(pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: scale)
      classic.overrideRendererStatus(
        RendererStatus(
          configuredRenderer: RendererSelection.vectorGlyph.rawValue,
          effectiveRenderer: RendererSelection.classic.rawValue,
          fallbackReason: "vectorPipelineUnavailable",
          textCompositeModel: .encodedSRGBCompatibility))
      return classic
    }
    return SoftwareBackend(
      fontAtlas: fontAtlas,
      sidebarFontAtlas: sidebar,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      scale: scale,
      rendererStatus: RendererStatus(
        configuredRenderer: RendererSelection.vectorGlyph.rawValue,
        effectiveRenderer: RendererSelection.software.rawValue,
        fallbackReason: "vectorPipelineUnavailable",
        textCompositeModel: .nativePlatformReference))

  case .slugGlyph:
    guard MTLCreateSystemDefaultDevice() != nil else {
      return SoftwareBackend(
        fontAtlas: fontAtlas,
        sidebarFontAtlas: sidebar,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        scale: scale,
        rendererStatus: RendererStatus(
          configuredRenderer: RendererSelection.slugGlyph.rawValue,
          effectiveRenderer: RendererSelection.software.rawValue,
          fallbackReason: "noMetalDevice",
          textCompositeModel: .nativePlatformReference))
    }
    if let slug = SlugGlyphRenderer(
      fontAtlas: fontAtlas,
      sidebarFontAtlas: sidebar,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      scale: scale,
      prebuiltRasterAtlas: prebuiltRasterAtlas)
    {
      slug.setSubpixelLayout(VectorSubpixelLayout.persisted())
      return slug
    }
    if let classic = MetalRenderer(
      fontAtlas: fontAtlas,
      sidebarFontAtlas: sidebar,
      scale: scale,
      rendererMode: .classic)
    {
      classic.resize(pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: scale)
      classic.overrideRendererStatus(
        RendererStatus(
          configuredRenderer: RendererSelection.slugGlyph.rawValue,
          effectiveRenderer: RendererSelection.classic.rawValue,
          fallbackReason: "slugPipelineUnavailable",
          textCompositeModel: .encodedSRGBCompatibility))
      return classic
    }
    return SoftwareBackend(
      fontAtlas: fontAtlas,
      sidebarFontAtlas: sidebar,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      scale: scale,
      rendererStatus: RendererStatus(
        configuredRenderer: RendererSelection.slugGlyph.rawValue,
        effectiveRenderer: RendererSelection.software.rawValue,
        fallbackReason: "slugPipelineUnavailable",
        textCompositeModel: .nativePlatformReference))
  }
}
