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

  /// The renderer a new install gets when no preference is persisted. Slug is
  /// the analytic-outline backend (ADR 0027): its glyph geometry is size
  /// independent, so text stays sharp through fractional zoom instead of
  /// re-baking a size-keyed mask atlas. Existing installs are unaffected — a
  /// persisted choice always wins, this is only the empty-defaults fallback.
  ///
  /// Safe on any machine: `makeRendererBackend` still falls back to classic
  /// (`slugPipelineUnavailable`) or software (`noMetalDevice`) and reports that
  /// through `RendererStatus`, so a missing Metal device or shader pipeline
  /// degrades rather than failing to draw.
  public static var defaultSelection: RendererSelection {
    RendererSelection.slugGlyph.isAvailableOnCurrentOS
      ? .slugGlyph
      : RendererSelection(metalMode: RendererMode.defaultMode)
  }

  /// Renderers a user can still choose. `vectorGlyph` is retired (ADR 0033) and
  /// is absent here, so no picker or menu can offer it; the case itself remains
  /// so an existing persisted value still decodes and can be migrated forward,
  /// and so the fidelity/parity harnesses can keep instantiating the backend
  /// directly for comparison.
  public static var selectableCases: [RendererSelection] {
    allCases.filter { $0 != .vectorGlyph }
  }

  /// Map a retired selection onto its replacement.
  ///
  /// `vectorGlyph` bakes a glyph mask per glyph and, at rest, gives every
  /// first-seen glyph the full 512-sample accumulation with no per-frame budget
  /// — the scrolling path caps this, the at-rest path never did. First-painting
  /// an unfamiliar screen (switching to a tab) could therefore encode seconds of
  /// GPU compute into one command buffer; measured at 9.7 s on 2026-08-24. Until
  /// that buffer completes it holds the one-frame-in-flight slot and, because
  /// the publish happens in its completion handler, the window keeps showing the
  /// previous tab. Slug has no mask atlas and no accumulation, so the cost model
  /// does not exist there. See ADR 0033.
  public static func migratingRetired(_ selection: RendererSelection) -> RendererSelection {
    selection == .vectorGlyph ? .slugGlyph : selection
  }

  public static func persisted(defaults: UserDefaults = .standard) -> RendererSelection {
    guard let raw = defaults.string(forKey: defaultsKey),
      let selection = RendererSelection(rawValue: raw),
      selection.isAvailableOnCurrentOS
    else {
      return defaultSelection
    }
    return migratingRetired(selection)
  }

  public static func set(_ selection: RendererSelection, defaults: UserDefaults = .standard) {
    let migrated = migratingRetired(selection)
    let resolved = migrated.isAvailableOnCurrentOS ? migrated : .classic
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
  previewFontAtlas: FontAtlas? = nil,
  pixelWidth: Int = 1,
  pixelHeight: Int = 1,
  scale: CGFloat = 1,
  surfaceTransparency: RendererSurfaceTransparency = RendererSurfaceTransparency(
    isOpaque: true),
  prebuiltRasterAtlas: MetalGlyphAtlas? = nil,
  prebuiltSidebarRasterAtlas: MetalGlyphAtlas? = nil
) -> RendererBackend {
  let resolved = selection.isAvailableOnCurrentOS ? selection : .classic
  let sidebar = sidebarFontAtlas ?? fontAtlas
  let preview = previewFontAtlas ?? fontAtlas

  switch resolved {
  case .software:
    return SoftwareBackend(
      fontAtlas: fontAtlas,
      sidebarFontAtlas: sidebar,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      scale: scale,
      surfaceTransparency: surfaceTransparency)

  case .classic, .gpuDriven:
    guard MTLCreateSystemDefaultDevice() != nil else {
      return SoftwareBackend(
        fontAtlas: fontAtlas,
        sidebarFontAtlas: sidebar,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        scale: scale,
        surfaceTransparency: surfaceTransparency,
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
        rendererMode: metalMode,
        surfaceTransparency: surfaceTransparency)
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
      surfaceTransparency: surfaceTransparency,
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
        surfaceTransparency: surfaceTransparency,
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
      surfaceTransparency: surfaceTransparency,
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
      rendererMode: .classic,
      surfaceTransparency: surfaceTransparency)
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
      surfaceTransparency: surfaceTransparency,
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
        surfaceTransparency: surfaceTransparency,
        rendererStatus: RendererStatus(
          configuredRenderer: RendererSelection.slugGlyph.rawValue,
          effectiveRenderer: RendererSelection.software.rawValue,
          fallbackReason: "noMetalDevice",
          textCompositeModel: .nativePlatformReference))
    }
    if let slug = SlugGlyphRenderer(
      fontAtlas: fontAtlas,
      sidebarFontAtlas: sidebar,
      previewFontAtlas: preview,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      scale: scale,
      surfaceTransparency: surfaceTransparency,
      prebuiltRasterAtlas: prebuiltRasterAtlas)
    {
      slug.setSubpixelLayout(VectorSubpixelLayout.persisted())
      return slug
    }
    if let classic = MetalRenderer(
      fontAtlas: fontAtlas,
      sidebarFontAtlas: sidebar,
      scale: scale,
      rendererMode: .classic,
      surfaceTransparency: surfaceTransparency)
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
      surfaceTransparency: surfaceTransparency,
      rendererStatus: RendererStatus(
        configuredRenderer: RendererSelection.slugGlyph.rawValue,
        effectiveRenderer: RendererSelection.software.rawValue,
        fallbackReason: "slugPipelineUnavailable",
        textCompositeModel: .nativePlatformReference))
  }
}
