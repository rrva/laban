import CoreGraphics
import CoreText
import Foundation
import Metal
import QuartzCore

private struct SlugSolidInstance {
  var origin: SIMD2<Float>
  var size: SIMD2<Float>
  var color: SIMD4<Float>
}

private struct SlugTextureInstance {
  var origin: SIMD2<Float>
  var size: SIMD2<Float>
  var uvOrigin: SIMD2<Float>
  var uvSize: SIMD2<Float>
  var color: SIMD4<Float>
}

private struct SlugVectorUniforms {
  var surfaceSizePixels: SIMD2<Float>
  var scale: Float
  var gestureZoom: Float = 1
  var gestureZoomAnchor: SIMD2<Float> = .zero
  var _pad: Float = 0
}

private struct SlugGlyphGPUCurve {
  var p0: SIMD2<Float>
  var p1: SIMD2<Float>
  var p2: SIMD2<Float>
}

private struct SlugGlyphGPUGlyph {
  var boundsMin: SIMD2<Float>
  var boundsMax: SIMD2<Float>
  var curveStart: UInt32
  var curveCount: UInt32
  var horizontalBandStart: UInt32
  var horizontalBandCount: UInt32
  var verticalBandStart: UInt32
  var verticalBandCount: UInt32
}

private struct SlugGlyphGPUBand {
  var indexStart: UInt32
  var indexCount: UInt32
}

private struct SlugGlyphGPUInstance {
  var originPx: SIMD2<Float>
  var sizePx: SIMD2<Float>
  var localMin: SIMD2<Float>
  var localMax: SIMD2<Float>
  var color: SIMD4<Float>
  var glyphIndex: UInt32
  var dilation: Float = 0
  var pad1: UInt32 = 0
  var pad2: UInt32 = 0
}

private struct SlugGlyphGPUUniforms {
  var surfaceSizePixels: SIMD2<Float>
  var scale: Float
  var gestureZoom: Float
  var gestureZoomAnchor: SIMD2<Float>
  var pad0: SIMD2<Float> = .zero
  var subpixelRBounds: SIMD4<Float>
  var subpixelGBounds: SIMD4<Float>
  var subpixelBBounds: SIMD4<Float>
  var subpixelMode: UInt32
  var pad1: UInt32 = 0
  var pad2: UInt32 = 0
  var pad3: UInt32 = 0
}

private struct SlugGlyphGeometryKey: Hashable {
  var postScriptName: String
  var glyph: CGGlyph
}

/// Identifies a (reference PostScript name, bold, italic) triple. Interned to
/// a small `Int` once per glyph run (`SlugGlyphRenderer.internedFontID`) so
/// the per-cell resolve-cache key below never re-hashes a `String`.
private struct SlugFontIdentityKey: Hashable {
  var postScriptName: String
  var bold: Bool
  var italic: Bool
}

private struct SlugGlyphResolveKey: Hashable {
  var fontID: Int
  var cluster: Character
}

private struct SlugGlyphEntry {
  var key: SlugGlyphGeometryKey
  var outline: GlyphCurveOutline
  var glyphIndex: Int
}

/// Analytic, atlas-free glyph renderer based on Lengyel's Slug fragment path.
///
/// Ordinary outline glyphs use reference-size curve geometry plus horizontal and
/// vertical band lists; color emoji and high-complexity CJK cells fall back to
/// the existing raster atlas paths.
public final class SlugGlyphRenderer: RendererBackend, DisplayLinkPresentingRenderer {
  public static let referencePointSize: CGFloat = 14

  private static let bandCount = 64
  private static let targetRingDepth = 3

  /// Geometric dilation (stem darkening) constants, calibrated so slug text
  /// weight 1.0 matches the software/CoreText renderer's ink. This approximates
  /// the FreeType/Adobe approach of thickening stems by an amount that depends
  /// on on-screen size; see Step 4 calibration in
  /// execplans/active/slug-text-weight-geometric-dilation.md.
  ///
  /// Per-side dilation in device pixels at text weight 1.0, keyed by on-screen
  /// em size (points-per-em times backing scale). Found by measurement: the
  /// calibration probe rendered the same probe string with the software
  /// (CoreText) renderer and the slug renderer at several dilation amounts
  /// for sizes 9/11/14/18/24pt at scale 2 (on-screen em size 18/22/28/36/48
  /// device pixels), for three foreground/background cases, and these are the
  /// per-size amounts that minimize the worst-case ratio error across all
  /// three cases. Growing dilation with size (the opposite of FreeType's
  /// large-text taper) is the measured best fit here, not a guess: CoreText's
  /// own extra stem-darkening ink, as a fraction of total ink, grows faster
  /// for dark-on-light text than a constant-pixel dilation would supply.
  /// Even at each size's optimum, dark-on-light wants more dilation while
  /// mid-gray/light-on-dark want less, especially at the smallest size (9pt);
  /// a single color-independent dilation cannot satisfy both exactly (see
  /// Artifacts and Notes for the measured ratios). Sizes between table entries
  /// use linear interpolation; below the smallest entry the smallest amount is
  /// used; above `dilationPpemFull` (outside the calibrated range) dilation
  /// tapers down toward `dilationMinTaper` of the largest table amount, since
  /// FreeType/Adobe do not bother thickening already-thick stems.
  private static let dilationTable: [(ppem: Float, amountPx: Float)] = [
    (18, 0.16),
    (22, 0.22),
    (28, 0.27),
    (36, 0.34),
    (48, 0.42),
  ]
  /// On-screen em size at and above which the table's largest amount stops
  /// growing and the large-text taper begins (outside the calibrated range).
  private static let dilationPpemFull: Float = 96
  /// On-screen em size at and above which the dilation taper bottoms out at
  /// `dilationMinTaper` of the largest table amount.
  private static let dilationPpemNone: Float = 240
  /// Floor for the large-text taper curve, as a fraction of the largest
  /// table amount.
  private static let dilationMinTaper: Float = 0.3

  /// Linearly interpolates `dilationTable` at `ppem`, clamping to the first
  /// and last entries outside the table's range.
  private static func dilationTableAmountPx(ppem: Float) -> Float {
    guard let first = dilationTable.first, let last = dilationTable.last else { return 0 }
    if ppem <= first.ppem { return first.amountPx }
    if ppem >= last.ppem { return last.amountPx }
    for index in 1..<dilationTable.count {
      let lo = dilationTable[index - 1]
      let hi = dilationTable[index]
      if ppem <= hi.ppem {
        let span = max(hi.ppem - lo.ppem, .ulpOfOne)
        let fraction = (ppem - lo.ppem) / span
        return lo.amountPx + fraction * (hi.amountPx - lo.amountPx)
      }
    }
    return last.amountPx
  }

  /// Maps text weight and on-screen em size to a per-side device-pixel
  /// dilation amount for the slug shader's `dilate` parameter. Color-independent:
  /// the same geometry applies regardless of foreground/background.
  private static func perSideDilatePx(weight: Double, ppemPx: Double) -> Float {
    guard weight > 0 else { return 0 }
    let ppem = Float(ppemPx)
    let amount = dilationTableAmountPx(ppem: min(ppem, dilationPpemFull))
    let taper: Float
    if ppem <= dilationPpemFull {
      taper = 1
    } else {
      let span = max(dilationPpemNone - dilationPpemFull, .ulpOfOne)
      taper = min(1, max(dilationMinTaper, 1 - (ppem - dilationPpemFull) / span))
    }
    return Float(weight) * amount * taper
  }

  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private let solidPipeline: MTLRenderPipelineState
  private let glyphAlphaPipeline: MTLRenderPipelineState
  private let glyphCoveragePipeline: MTLRenderPipelineState
  private let glyphColorPipeline: MTLRenderPipelineState
  private let slugAccumulatePipeline: MTLRenderPipelineState
  private let subpixelCompositeDarkenPipeline: MTLRenderPipelineState
  private let subpixelCompositeAdditivePipeline: MTLRenderPipelineState
  private let rasterGlyphPipeline: MTLRenderPipelineState
  private let colorGlyphPipeline: MTLRenderPipelineState
  private let sampler: MTLSamplerState
  public let layer: CAMetalLayer

  public private(set) var fontAtlas: FontAtlas
  public private(set) var sidebarFontAtlas: FontAtlas
  private var referenceFontAtlas: FontAtlas
  private var sidebarReferenceFontAtlas: FontAtlas

  private let curveStore = GlyphCurveStore()
  private var entriesByKey: [SlugGlyphGeometryKey: SlugGlyphEntry] = [:]
  private var entriesByResolveKey: [SlugGlyphResolveKey: SlugGlyphEntry] = [:]
  private var fontIdentityIntern: [SlugFontIdentityKey: Int] = [:]
  private var nextFontIdentityID = 0
  /// Font color-glyph trait, keyed like `VectorGlyphRenderer.fontCache`
  /// (attrs bits | atlas bit). The trait is invariant per font; this avoids
  /// re-probing `CTFontGetSymbolicTraits` every glyph run.
  private var colorTraitCache: [UInt32: Bool] = [:]
  private var lastFrameSolidsCount = 0
  private var lastFrameSlugGlyphsCount = 0
  private var lastFrameRasterGlyphsCount = 0
  private var lastFrameColorGlyphsCount = 0

  // MARK: - M2 damage-aware rendering state
  //
  // See execplans/active/slug-render-loop-perf-and-aa-quality.md M2. One
  // `DirtyYRangeSet` accumulator and one "needs a hard full redraw" flag per
  // target-ring slot (ring depth 1 outside the display-link present path,
  // see `ringDepth`): a ring slot's texture is `ringDepth - 1` frames stale
  // when it is next drawn into, so a partial redraw into slot `i` must cover
  // everything that changed since slot `i` was last drawn, not just what
  // changed since the previous frame.
  private var slotDamageAccumulators: [DirtyYRangeSet] = []
  /// Sticky per-slot flag: true means the next render into that slot must be
  /// a full redraw regardless of incoming damage, because that slot's cached
  /// content is invalid (fresh/uninitialized texture, or drawn under a zoom/
  /// subpixel-layout/text-weight/emoji-mode/upstream-full-damage state that
  /// no longer matches). Consumed (set false) the render after it is used.
  private var slotNeedsForceFull: [Bool] = []
  private var previousCursorRects: [CGRect] = []
  private var previousGestureZoom: CGFloat?
  private var previousGestureZoomAnchor: CGPoint?
  private var previousEffectiveSubpixelLayout: VectorSubpixelLayout?
  private var previousTextWeight: Double?
  private var previousEmojiRenderingMode: EmojiRenderingMode?
  private var curves: [SlugGlyphGPUCurve] = []
  private var glyphs: [SlugGlyphGPUGlyph] = []
  private var bands: [SlugGlyphGPUBand] = []
  private var bandIndices: [UInt32] = []
  private var curveBuffer: MTLBuffer?
  private var glyphBuffer: MTLBuffer?
  private var bandBuffer: MTLBuffer?
  private var bandIndexBuffer: MTLBuffer?
  // M4: how many of the corresponding CPU-side array's (append-only)
  // elements are already present in the matching `MTLBuffer`. A capacity
  // overflow reallocates (doubling) and re-copies from the CPU array (the
  // source of truth); otherwise growth is a tail-only memcpy of just the
  // newly appended elements. See `ensureIncrementalBuffer`.
  private var curveBufferUploadedCount = 0
  private var glyphBufferUploadedCount = 0
  private var bandBufferUploadedCount = 0
  private var bandIndexBufferUploadedCount = 0
  private var subpixelCoverageAccum: MTLTexture?
  private var subpixelColorAccum: MTLTexture?
  private var geometryBuffersDirty = false

  /// macOS 14+ fast path: when present, Slug mirrors VectorGlyphRenderer's
  /// CAMetalDisplayLink presenter. `render()` publishes completed offscreen
  /// targets and never calls `nextDrawable()` while this link exists.
  private var presentDisplayLinkStorage: AnyObject?
  @available(macOS 14.0, *)
  private var presentDisplayLink: VectorPresentDisplayLink? {
    presentDisplayLinkStorage as? VectorPresentDisplayLink
  }
  private var latestPresentedTarget: MTLTexture?
  private let presentTargetLock = NSLock()
  private var presentQueue: MTLCommandQueue?
  private var targetRing: [MTLTexture] = []
  private var targetRingCursor = 0

  private var targetTexture: MTLTexture?
  private var lastCommandBuffer: MTLCommandBuffer?
  private var rasterAtlas: MetalGlyphAtlas?
  private var colorGlyphAtlas: ColorGlyphAtlas?
  private var pixelWidth: Int
  private var pixelHeight: Int
  private var scale: CGFloat
  public private(set) var gestureZoom: CGFloat = 1
  public private(set) var gestureZoomAnchor: CGPoint = .zero
  public private(set) var subpixelLayout: VectorSubpixelLayout = .grayscale
  private var textWeight: Double = VectorTextWeightSettings.current()
  private var emojiRenderingMode: EmojiRenderingMode = EmojiRenderingSettings.current()
  private var displayDownsampled = false
  public var effectiveSubpixelLayout: VectorSubpixelLayout {
    VectorSubpixelLayout.effective(
      configured: subpixelLayout,
      scale: Double(scale),
      downsampled: displayDownsampled)
  }

  public var onFrameCompleted: (() -> Void)?
  public var waitForFrameCompletion: Bool = false
  public var presentsToLayer: Bool = true

  /// Number of size-independent glyph geometry entries built by this renderer.
  /// Used by tests to prove active point-size changes do not rebuild curves/bands.
  public private(set) var geometryEntryBuildCount = 0

  /// Number of times the accumulated curve/band arrays were uploaded to GPU
  /// buffers. This may advance when a new glyph appears, but not merely because
  /// the same glyph is rendered at a different active point size.
  public private(set) var geometryBufferUploadCount = 0
  public private(set) var lastFrameGlyphFontSizes: [Double] = []
  public private(set) var lastFrameQuadHeights: [Int] = []
  private var frameGlyphFontSizes = Set<Double>()
  private var frameQuadHeights = Set<Int>()
  private var lastRasterFallbackGlyphs = 0

  public var rendererStatus: RendererStatus {
    RendererStatus(
      configuredRenderer: RendererSelection.slugGlyph.rawValue,
      effectiveRenderer: RendererSelection.slugGlyph.rawValue,
      rasterFallbackGlyphs: lastRasterFallbackGlyphs,
      vectorSubpixelLayout: effectiveSubpixelLayout.name,
      textCompositeModel: .linearLight)
  }

  public init?(
    fontAtlas: FontAtlas,
    sidebarFontAtlas: FontAtlas? = nil,
    pixelWidth: Int = 1,
    pixelHeight: Int = 1,
    scale: CGFloat = 1
  ) {
    guard let device = MTLCreateSystemDefaultDevice(),
      let queue = device.makeCommandQueue()
    else { return nil }

    let options = MTLCompileOptions()
    if #available(macOS 15.0, *) {
      options.mathMode = .safe
    } else {
      options.fastMathEnabled = false
    }
    guard
      let url = LabanRendererResources.bundle?.url(
        forResource: "VectorGlyphShaders",
        withExtension: "metal"),
      let source = try? String(contentsOf: url, encoding: .utf8),
      let library = try? device.makeLibrary(source: source, options: options),
      let solidVertex = library.makeFunction(name: "vectorSolidVertex"),
      let solidFragment = library.makeFunction(name: "vectorSolidFragment"),
      let textureVertex = library.makeFunction(name: "vectorGlyphVertex"),
      let rasterGlyphFragment = library.makeFunction(name: "vectorRasterGlyphFragment"),
      let colorGlyphFragment = library.makeFunction(name: "vectorColorGlyphFragment"),
      let glyphVertex = library.makeFunction(name: "slugGlyphVertex"),
      let glyphAlphaFragment = library.makeFunction(name: "slugGlyphAlphaFragment"),
      let glyphCoverageFragment = library.makeFunction(name: "slugGlyphCoverageFragment"),
      let glyphColorFragment = library.makeFunction(name: "slugGlyphColorFragment"),
      let slugAccumulateFragment = library.makeFunction(name: "slugGlyphAccumulateFragment"),
      let fullscreenVertex = library.makeFunction(name: "vectorFullscreenVertex"),
      let compositeDarkenFragment = library.makeFunction(name: "subpixelCompositeDarkenFragment"),
      let compositeAdditiveFragment = library.makeFunction(name: "subpixelCompositeAdditiveFragment")
    else { return nil }

    let layer = CAMetalLayer()
    layer.device = device
    layer.pixelFormat = .bgra8Unorm_srgb
    layer.framebufferOnly = false
    layer.contentsScale = max(scale, 1)
    layer.drawableSize = CGSize(width: max(1, pixelWidth), height: max(1, pixelHeight))
    layer.isOpaque = true
    layer.maximumDrawableCount = 3
    layer.allowsNextDrawableTimeout = true
    layer.contentsGravity = .topLeft

    let solidDescriptor = MTLRenderPipelineDescriptor()
    solidDescriptor.label = "laban.slug.solid"
    solidDescriptor.vertexFunction = solidVertex
    solidDescriptor.fragmentFunction = solidFragment
    solidDescriptor.colorAttachments[0]?.pixelFormat = layer.pixelFormat
    configureSlugAlphaBlend(solidDescriptor.colorAttachments[0])

    let glyphAlphaDescriptor = MTLRenderPipelineDescriptor()
    glyphAlphaDescriptor.label = "laban.slug.glyph-alpha"
    glyphAlphaDescriptor.vertexFunction = glyphVertex
    glyphAlphaDescriptor.fragmentFunction = glyphAlphaFragment
    glyphAlphaDescriptor.colorAttachments[0]?.pixelFormat = layer.pixelFormat
    configureSlugAlphaBlend(glyphAlphaDescriptor.colorAttachments[0])

    let glyphCoverageDescriptor = MTLRenderPipelineDescriptor()
    glyphCoverageDescriptor.label = "laban.slug.glyph-coverage"
    glyphCoverageDescriptor.vertexFunction = glyphVertex
    glyphCoverageDescriptor.fragmentFunction = glyphCoverageFragment
    glyphCoverageDescriptor.colorAttachments[0]?.pixelFormat = layer.pixelFormat
    configureSubpixelCoverageBlend(glyphCoverageDescriptor.colorAttachments[0])

    let glyphColorDescriptor = MTLRenderPipelineDescriptor()
    glyphColorDescriptor.label = "laban.slug.glyph-color"
    glyphColorDescriptor.vertexFunction = glyphVertex
    glyphColorDescriptor.fragmentFunction = glyphColorFragment
    glyphColorDescriptor.colorAttachments[0]?.pixelFormat = layer.pixelFormat
    configureAdditiveRGBPreserveAlphaBlend(glyphColorDescriptor.colorAttachments[0])

    // Subpixel accumulate-then-composite path. The accumulate pipeline writes
    // per-channel coverage (attachment 0) and premultiplied foreground
    // (attachment 1) into two GPU-private rgba16Float textures with ADDITIVE
    // blend, so abutting glyph quads SUM their coverage at a seam
    // (c1 + c2 = c_full) instead of the per-glyph "over" operator's
    // c1 + c2 - c1*c2 bright notch. The composite pipelines then read those
    // textures back with a full-screen quad and darken + add the target once.
    // The analytic coverage band walk still runs once per glyph: MRT writes
    // both outputs in a single pass.
    let slugAccumulateDescriptor = MTLRenderPipelineDescriptor()
    slugAccumulateDescriptor.label = "laban.slug.glyph-accumulate"
    slugAccumulateDescriptor.vertexFunction = glyphVertex
    slugAccumulateDescriptor.fragmentFunction = slugAccumulateFragment
    slugAccumulateDescriptor.colorAttachments[0]?.pixelFormat = .rgba16Float
    configureAdditiveAccumBlend(slugAccumulateDescriptor.colorAttachments[0])
    slugAccumulateDescriptor.colorAttachments[1]?.pixelFormat = .rgba16Float
    configureAdditiveAccumBlend(slugAccumulateDescriptor.colorAttachments[1])

    let compositeDarkenDescriptor = MTLRenderPipelineDescriptor()
    compositeDarkenDescriptor.label = "laban.slug.subpixel-composite-darken"
    compositeDarkenDescriptor.vertexFunction = fullscreenVertex
    compositeDarkenDescriptor.fragmentFunction = compositeDarkenFragment
    compositeDarkenDescriptor.colorAttachments[0]?.pixelFormat = layer.pixelFormat
    configureSubpixelCoverageBlend(compositeDarkenDescriptor.colorAttachments[0])

    let compositeAdditiveDescriptor = MTLRenderPipelineDescriptor()
    compositeAdditiveDescriptor.label = "laban.slug.subpixel-composite-additive"
    compositeAdditiveDescriptor.vertexFunction = fullscreenVertex
    compositeAdditiveDescriptor.fragmentFunction = compositeAdditiveFragment
    compositeAdditiveDescriptor.colorAttachments[0]?.pixelFormat = layer.pixelFormat
    configureAdditiveRGBPreserveAlphaBlend(compositeAdditiveDescriptor.colorAttachments[0])

    let rasterGlyphDescriptor = MTLRenderPipelineDescriptor()
    rasterGlyphDescriptor.label = "laban.slug.raster-glyph"
    rasterGlyphDescriptor.vertexFunction = textureVertex
    rasterGlyphDescriptor.fragmentFunction = rasterGlyphFragment
    rasterGlyphDescriptor.colorAttachments[0]?.pixelFormat = layer.pixelFormat
    configureSlugAlphaBlend(rasterGlyphDescriptor.colorAttachments[0])

    let colorGlyphDescriptor = MTLRenderPipelineDescriptor()
    colorGlyphDescriptor.label = "laban.slug.color-glyph"
    colorGlyphDescriptor.vertexFunction = textureVertex
    colorGlyphDescriptor.fragmentFunction = colorGlyphFragment
    colorGlyphDescriptor.colorAttachments[0]?.pixelFormat = layer.pixelFormat
    configureSlugAlphaBlend(colorGlyphDescriptor.colorAttachments[0])

    let samplerDescriptor = MTLSamplerDescriptor()
    samplerDescriptor.minFilter = .nearest
    samplerDescriptor.magFilter = .nearest
    samplerDescriptor.sAddressMode = .clampToEdge
    samplerDescriptor.tAddressMode = .clampToEdge

    guard
      let solidPipeline = try? device.makeRenderPipelineState(descriptor: solidDescriptor),
      let glyphAlphaPipeline = try? device.makeRenderPipelineState(
        descriptor: glyphAlphaDescriptor),
      let glyphCoveragePipeline = try? device.makeRenderPipelineState(
        descriptor: glyphCoverageDescriptor),
      let glyphColorPipeline = try? device.makeRenderPipelineState(
        descriptor: glyphColorDescriptor),
      let slugAccumulatePipeline = try? device.makeRenderPipelineState(
        descriptor: slugAccumulateDescriptor),
      let subpixelCompositeDarkenPipeline = try? device.makeRenderPipelineState(
        descriptor: compositeDarkenDescriptor),
      let subpixelCompositeAdditivePipeline = try? device.makeRenderPipelineState(
        descriptor: compositeAdditiveDescriptor),
      let rasterGlyphPipeline = try? device.makeRenderPipelineState(
        descriptor: rasterGlyphDescriptor),
      let colorGlyphPipeline = try? device.makeRenderPipelineState(
        descriptor: colorGlyphDescriptor),
      let sampler = device.makeSamplerState(descriptor: samplerDescriptor)
    else { return nil }

    self.device = device
    self.queue = queue
    self.solidPipeline = solidPipeline
    self.glyphAlphaPipeline = glyphAlphaPipeline
    self.glyphCoveragePipeline = glyphCoveragePipeline
    self.glyphColorPipeline = glyphColorPipeline
    self.slugAccumulatePipeline = slugAccumulatePipeline
    self.subpixelCompositeDarkenPipeline = subpixelCompositeDarkenPipeline
    self.subpixelCompositeAdditivePipeline = subpixelCompositeAdditivePipeline
    self.rasterGlyphPipeline = rasterGlyphPipeline
    self.colorGlyphPipeline = colorGlyphPipeline
    self.sampler = sampler
    self.layer = layer
    self.fontAtlas = fontAtlas
    self.sidebarFontAtlas = sidebarFontAtlas ?? fontAtlas
    self.referenceFontAtlas = fontAtlas.withPointSize(Self.referencePointSize)
    self.sidebarReferenceFontAtlas = (sidebarFontAtlas ?? fontAtlas).withPointSize(
      Self.referencePointSize)
    self.pixelWidth = max(1, pixelWidth)
    self.pixelHeight = max(1, pixelHeight)
    self.scale = max(scale, 1)
    self.colorGlyphAtlas = Self.makeColorGlyphAtlas(
      device: device,
      fontAtlas: fontAtlas,
      scale: self.scale)
    self.rasterAtlas = Self.makeRasterGlyphAtlas(
      device: device,
      fontAtlas: fontAtlas,
      scale: self.scale)

    if #available(macOS 14.0, *), Self.presentDisplayLinkEnabled,
      let presentQueue = device.makeCommandQueue()
    {
      presentQueue.label = "laban.slug.present"
      self.presentQueue = presentQueue
      let presentLink = VectorPresentDisplayLink(layer: layer)
      presentLink.onPresent = { [weak self] drawable in
        self?.presentLatestTarget(into: drawable) ?? false
      }
      presentLink.start()
      self.presentDisplayLinkStorage = presentLink
    }
  }

  /// Default true. `LabanSlugPresentDisplayLink` can opt Slug out alone; if it is
  /// unset, the existing vector opt-out key disables the shared ADR 0026 fast path
  /// for both curve renderers.
  private static var presentDisplayLinkEnabled: Bool {
    let defaults = UserDefaults.standard
    if defaults.object(forKey: "LabanSlugPresentDisplayLink") != nil {
      return defaults.bool(forKey: "LabanSlugPresentDisplayLink")
    }
    if defaults.object(forKey: "LabanVectorPresentDisplayLink") != nil {
      return defaults.bool(forKey: "LabanVectorPresentDisplayLink")
    }
    return true
  }

  deinit {
    if #available(macOS 14.0, *) {
      presentDisplayLink?.stop()
    }
  }

  public func setPresentLinkRunning(_ running: Bool) {
    if #available(macOS 14.0, *) {
      presentDisplayLink?.setRunning(running)
    }
  }

  public func presentDisplayLinkStats(reset: Bool) -> [String: Double]? {
    if #available(macOS 14.0, *) {
      return presentDisplayLink?.presentIntervalStats(reset: reset)
    }
    return nil
  }

  public var surfaceWidth: Int { pixelWidth }
  public var surfaceHeight: Int { pixelHeight }
  public var surfaceScale: CGFloat { scale }
  public var presentationLayer: CALayer? { layer }
  public var presentationImage: CGImage? { nil }

  public var pngData: Data? {
    lastCommandBuffer?.waitUntilCompleted()
    guard let targetTexture else { return nil }
    let bytesPerRow = targetTexture.width * 4
    var bytes = [UInt8](repeating: 0, count: bytesPerRow * targetTexture.height)
    bytes.withUnsafeMutableBytes { raw in
      guard let base = raw.baseAddress else { return }
      targetTexture.getBytes(
        base,
        bytesPerRow: bytesPerRow,
        from: MTLRegionMake2D(0, 0, targetTexture.width, targetTexture.height),
        mipmapLevel: 0)
    }

    let bitmapInfo =
      CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
    // Tag sRGB: the target texture is an sRGB-encoded surface (bgra8Unorm_srgb
    // layer), so the readback bytes are sRGB. A deviceRGB tag mis-tags them as
    // display-native and oversaturates the PNG/screenshot on wide-gamut panels.
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
      let image = CGImage(
        width: targetTexture.width,
        height: targetTexture.height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent)
    else { return nil }
    return PNGEncoder.encode(image)
  }

  public func reconfigureFonts(fontAtlas: FontAtlas, sidebarFontAtlas: FontAtlas? = nil) {
    self.fontAtlas = fontAtlas
    self.sidebarFontAtlas = sidebarFontAtlas ?? fontAtlas
    self.referenceFontAtlas = fontAtlas.withPointSize(Self.referencePointSize)
    self.sidebarReferenceFontAtlas = (sidebarFontAtlas ?? fontAtlas).withPointSize(
      Self.referencePointSize)
    colorGlyphAtlas = Self.makeColorGlyphAtlas(
      device: device,
      fontAtlas: fontAtlas,
      scale: scale)
    rasterAtlas = Self.makeRasterGlyphAtlas(
      device: device,
      fontAtlas: fontAtlas,
      scale: scale)
  }

  public func setSubpixelLayout(_ layout: VectorSubpixelLayout) {
    subpixelLayout = layout
  }

  public func refreshTextWeight() {
    textWeight = VectorTextWeightSettings.current()
  }

  public func refreshEmojiRenderingMode() {
    emojiRenderingMode = EmojiRenderingSettings.current()
  }

  @discardableResult
  public func setDisplayDownsampled(_ downsampled: Bool) -> Bool {
    guard downsampled != displayDownsampled else { return false }
    let previousEffective = effectiveSubpixelLayout
    displayDownsampled = downsampled
    return effectiveSubpixelLayout != previousEffective
  }

  public func setGestureZoom(_ factor: CGFloat, anchor: CGPoint) {
    gestureZoom = factor.isFinite && factor > 0 ? factor : 1
    gestureZoomAnchor = anchor
  }

  @discardableResult
  public func resize(pixelWidth: Int, pixelHeight: Int, scale: CGFloat) -> Bool {
    let pw = max(1, pixelWidth)
    let ph = max(1, pixelHeight)
    let newScale = max(scale, 1)
    let changed = pw != self.pixelWidth || ph != self.pixelHeight || newScale != self.scale
    let scaleChanged = newScale != self.scale
    guard changed else { return false }
    self.pixelWidth = pw
    self.pixelHeight = ph
    self.scale = newScale
    layer.contentsScale = newScale
    layer.drawableSize = CGSize(width: pw, height: ph)
    targetTexture = nil
    targetRing.removeAll(keepingCapacity: true)
    targetRingCursor = 0
    subpixelCoverageAccum = nil
    subpixelColorAccum = nil
    presentTargetLock.lock()
    latestPresentedTarget = nil
    presentTargetLock.unlock()
    if scaleChanged {
      colorGlyphAtlas = Self.makeColorGlyphAtlas(
        device: device,
        fontAtlas: fontAtlas,
        scale: newScale)
      rasterAtlas = Self.makeRasterGlyphAtlas(
        device: device,
        fontAtlas: fontAtlas,
        scale: newScale)
    }
    return true
  }

  /// Stage A (GPU) scissoring for M2: `.full` draws unscissored exactly like
  /// pre-M2 code (Metal defaults an encoder's scissor rect to the whole
  /// attachment). `.bands` carries one device-pixel `MTLScissorRect` per
  /// exact damage band — never collapsed to one min/max scissor, since with
  /// per-slot accumulation disjoint bands (prompt row plus a status line) are
  /// the common case. See `repeatingBands(_:on:draw:)` for how these are
  /// applied: draws repeat once per band with the fragment stage exactly
  /// culled outside it.
  private enum SlugScissorPlan {
    case full
    case bands([MTLScissorRect])
  }

  private func scissorPlan(for damage: RenderDamage) -> SlugScissorPlan {
    guard case .partial(let yRanges) = damage else { return .full }
    let rects = yRanges.compactMap { slugScissorRect(for: $0) }
    return rects.isEmpty ? .full : .bands(rects)
  }

  /// y-up CG-point damage band to y-down device-pixel Metal scissor rect.
  /// Same conversion as `MetalRenderer.scissorRectFromYRanges`
  /// (`MetalRenderer.swift:2192`), applied per exact band here instead of to
  /// a collapsed min/max union.
  private func slugScissorRect(for range: DirtyYRange) -> MTLScissorRect? {
    guard range.height > 0 else { return nil }
    let surfaceHeightPoints = CGFloat(pixelHeight) / scale
    let topPx = max(
      0, Int(((surfaceHeightPoints - (range.y + range.height)) * scale).rounded(.down)))
    let bottomPx = min(
      pixelHeight, Int(((surfaceHeightPoints - range.y) * scale).rounded(.up)))
    let height = max(0, bottomPx - topPx)
    guard height > 0 else { return nil }
    return MTLScissorRect(x: 0, y: topPx, width: pixelWidth, height: height)
  }

  /// Repeats `draw` once per band, setting that band's scissor first. `.full`
  /// calls `draw` exactly once, unscissored. Encoder state set before this
  /// call (pipeline, buffers) is preserved across `setScissorRect` calls, so
  /// only the draw call itself needs to repeat.
  private func repeatingBands(
    _ plan: SlugScissorPlan,
    on encoder: MTLRenderCommandEncoder,
    draw: () -> Void
  ) {
    switch plan {
    case .full:
      draw()
    case .bands(let rects):
      for rect in rects {
        encoder.setScissorRect(rect)
        draw()
      }
    }
  }

  /// Resolves the damage this frame must actually redraw, applying M2's
  /// per-ring-slot accumulation, cursor-blink correctness, and force-full
  /// rules (see execplans/active/slug-render-loop-perf-and-aa-quality.md).
  /// Returns `nil` when the effective damage is empty (skip encoding, do not
  /// rotate the ring); the caller has already been told to re-present and
  /// call the completion handler in that case via `EffectiveDamageOutcome`.
  private enum EffectiveDamageOutcome {
    case render(damage: RenderDamage, slot: Int, ringRebuild: Bool)
    case skip
  }

  private func resolveEffectiveDamage(
    damage: RenderDamage,
    currentCursorRects: [CGRect]
  ) -> EffectiveDamageOutcome {
    let (slot, ringRebuild) = peekNextRingSlot()
    ensureSlotDamageStateSized(rebuild: ringRebuild)

    let forcesEveryone = ringRebuild || configChangedSincePreviousFrame() || damage == .full
    if forcesEveryone {
      for i in slotNeedsForceFull.indices { slotNeedsForceFull[i] = true }
    }

    if slotNeedsForceFull[slot] {
      slotDamageAccumulators[slot] = DirtyYRangeSet([])
      slotNeedsForceFull[slot] = false
      return .render(damage: .full, slot: slot, ringRebuild: ringRebuild)
    }

    let incoming: DirtyYRangeSet
    if case .partial(let yRanges) = damage {
      incoming = DirtyYRangeSet(yRanges).union(
        cursorDamage(previous: previousCursorRects, current: currentCursorRects))
    } else {
      incoming = cursorDamage(previous: previousCursorRects, current: currentCursorRects)
    }
    if !incoming.isEmpty {
      for i in slotDamageAccumulators.indices {
        slotDamageAccumulators[i] = slotDamageAccumulators[i].union(incoming)
      }
    }
    let combined = slotDamageAccumulators[slot]
    slotDamageAccumulators[slot] = DirtyYRangeSet([])
    guard !combined.isEmpty else { return .skip }
    return .render(damage: .partial(yRanges: combined.ranges), slot: slot, ringRebuild: ringRebuild)
  }

  @discardableResult
  public func render(_ commands: [FrameCommand], damage: RenderDamage) -> Bool {
    let currentCursorRects = cursorRects(in: commands)
    let outcome = resolveEffectiveDamage(damage: damage, currentCursorRects: currentCursorRects)

    guard case .render(let effectiveDamage, let slot, let ringRebuild) = outcome else {
      // Empty effective damage: nothing changed since this slot was last
      // fully current (including cursor position). Skip encoding entirely
      // and do not rotate the ring, but keep the present link fed and honor
      // the completion contract.
      previousCursorRects = currentCursorRects
      snapshotConfigForNextFrame()
      if presentsToLayer, let currentTarget = targetTexture {
        publishLatestTarget(currentTarget)
      }
      onFrameCompleted?()
      return true
    }
    previousCursorRects = currentCursorRects
    snapshotConfigForNextFrame()

    guard let target = commitRingSlot(slot, rebuild: ringRebuild),
      let commandBuffer = queue.makeCommandBuffer()
    else { return false }

    let scissorPlan = self.scissorPlan(for: effectiveDamage)

    var solids: [SlugSolidInstance] = []
    var slugGlyphs: [SlugGlyphGPUInstance] = []
    var rasterGlyphs: [SlugTextureInstance] = []
    var colorGlyphs: [SlugTextureInstance] = []
    solids.reserveCapacity(lastFrameSolidsCount)
    slugGlyphs.reserveCapacity(lastFrameSlugGlyphsCount)
    rasterGlyphs.reserveCapacity(lastFrameRasterGlyphsCount)
    colorGlyphs.reserveCapacity(lastFrameColorGlyphsCount)
    frameGlyphFontSizes.removeAll(keepingCapacity: true)
    frameQuadHeights.removeAll(keepingCapacity: true)
    buildInstances(
      commands: commands,
      solids: &solids,
      glyphs: &slugGlyphs,
      rasterGlyphs: &rasterGlyphs,
      colorGlyphs: &colorGlyphs)
    lastFrameSolidsCount = solids.count
    lastFrameSlugGlyphsCount = slugGlyphs.count
    lastFrameRasterGlyphsCount = rasterGlyphs.count
    lastFrameColorGlyphsCount = colorGlyphs.count
    lastFrameGlyphFontSizes = frameGlyphFontSizes.sorted()
    lastFrameQuadHeights = frameQuadHeights.sorted()
    lastRasterFallbackGlyphs = rasterGlyphs.count + colorGlyphs.count
    guard ensureGeometryBuffersIfNeeded(glyphsNeeded: !slugGlyphs.isEmpty) else { return false }

    var retainedBuffers: [MTLBuffer] = []

    let useSubpixel = effectiveSubpixelLayout != .grayscale
    let slugInstanceBuffer = makeBuffer(slugGlyphs)
    if let slugInstanceBuffer { retainedBuffers.append(slugInstanceBuffer) }
    let slugCurveBuffer = curveBuffer
    let slugGlyphBuffer = glyphBuffer
    let slugBandBuffer = bandBuffer
    let slugBandIndexBuffer = bandIndexBuffer
    let slugBuffersReady = slugInstanceBuffer != nil
      && slugCurveBuffer != nil
      && slugGlyphBuffer != nil
      && slugBandBuffer != nil
      && slugBandIndexBuffer != nil
    var glyphUniform = glyphUniforms(width: pixelWidth, height: pixelHeight)
    let (coverageAccum, colorAccum) = ensureSubpixelAccumTextures()
    let subpixelAccumReady = coverageAccum != nil && colorAccum != nil

    // Subpixel accumulate pass. Draw every glyph quad once into two GPU-private
    // rgba16Float textures with ADDITIVE blend: attachment 0 accumulates
    // per-channel coverage, attachment 1 accumulates premultiplied foreground.
    // Abutting glyph quads therefore SUM coverage at a seam (c1 + c2 = c_full)
    // instead of the per-glyph "over" operator's c1 + c2 - c1*c2 bright notch.
    // The analytic coverage band walk runs once per glyph (MRT writes both
    // outputs in a single pass). The grayscale path skips this encoder entirely.
    if useSubpixel, slugBuffersReady, subpixelAccumReady,
      let coverageAccum, let colorAccum
    {
      let accumDescriptor = MTLRenderPassDescriptor()
      accumDescriptor.colorAttachments[0].texture = coverageAccum
      accumDescriptor.colorAttachments[0].loadAction = .clear
      accumDescriptor.colorAttachments[0].clearColor = MTLClearColor(
        red: 0, green: 0, blue: 0, alpha: 0)
      accumDescriptor.colorAttachments[0].storeAction = .store
      accumDescriptor.colorAttachments[1].texture = colorAccum
      accumDescriptor.colorAttachments[1].loadAction = .clear
      accumDescriptor.colorAttachments[1].clearColor = MTLClearColor(
        red: 0, green: 0, blue: 0, alpha: 0)
      accumDescriptor.colorAttachments[1].storeAction = .store
      if let accumEncoder = commandBuffer.makeRenderCommandEncoder(
        descriptor: accumDescriptor)
      {
        accumEncoder.label = "laban.slug.glyph-accumulate"
        accumEncoder.setRenderPipelineState(slugAccumulatePipeline)
        accumEncoder.setVertexBuffer(slugInstanceBuffer, offset: 0, index: 0)
        accumEncoder.setVertexBytes(
          &glyphUniform,
          length: MemoryLayout<SlugGlyphGPUUniforms>.stride,
          index: 1)
        accumEncoder.setFragmentBytes(
          &glyphUniform,
          length: MemoryLayout<SlugGlyphGPUUniforms>.stride,
          index: 4)
        accumEncoder.setFragmentBuffer(slugCurveBuffer, offset: 0, index: 0)
        accumEncoder.setFragmentBuffer(slugGlyphBuffer, offset: 0, index: 1)
        accumEncoder.setFragmentBuffer(slugBandBuffer, offset: 0, index: 2)
        accumEncoder.setFragmentBuffer(slugBandIndexBuffer, offset: 0, index: 3)
        repeatingBands(scissorPlan, on: accumEncoder) {
          accumEncoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6,
            instanceCount: slugGlyphs.count)
        }
        accumEncoder.endEncoding()
      }
    }

    // M2: a partial frame loads (rather than clears) the content target and
    // relies on the frame's own background-rect commands to repaint inside
    // the scissored bands (`MTLLoadAction.clear` always clears the whole
    // attachment regardless of scissor, which is why the accumulate
    // textures above stay unconditionally `.clear` — a tile-clear is
    // effectively free and correctness only depends on the content pass's
    // load action here).
    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = target
    descriptor.colorAttachments[0].storeAction = .store
    switch scissorPlan {
    case .full:
      descriptor.colorAttachments[0].loadAction = .clear
      descriptor.colorAttachments[0].clearColor = Self.linearizedClearColor(commands)
    case .bands:
      descriptor.colorAttachments[0].loadAction = .load
    }
    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
      return false
    }
    encoder.label = "laban.slug.content"

    var vectorUniforms = SlugVectorUniforms(
      surfaceSizePixels: SIMD2<Float>(Float(pixelWidth), Float(pixelHeight)),
      scale: Float(scale),
      gestureZoom: Float(gestureZoom),
      gestureZoomAnchor: SIMD2<Float>(
        Float(gestureZoomAnchor.x),
        Float(gestureZoomAnchor.y)))

    if !solids.isEmpty, let solidBuffer = makeBuffer(solids) {
      retainedBuffers.append(solidBuffer)
      encoder.setRenderPipelineState(solidPipeline)
      encoder.setVertexBuffer(solidBuffer, offset: 0, index: 0)
      encoder.setVertexBytes(
        &vectorUniforms,
        length: MemoryLayout<SlugVectorUniforms>.stride,
        index: 1)
      repeatingBands(scissorPlan, on: encoder) {
        encoder.drawPrimitives(
          type: .triangle,
          vertexStart: 0,
          vertexCount: 6,
          instanceCount: solids.count)
      }
    }

    if slugBuffersReady {
      if !useSubpixel {
        encoder.setVertexBuffer(slugInstanceBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(
          &glyphUniform,
          length: MemoryLayout<SlugGlyphGPUUniforms>.stride,
          index: 1)
        encoder.setFragmentBytes(
          &glyphUniform,
          length: MemoryLayout<SlugGlyphGPUUniforms>.stride,
          index: 4)
        encoder.setFragmentBuffer(slugCurveBuffer, offset: 0, index: 0)
        encoder.setFragmentBuffer(slugGlyphBuffer, offset: 0, index: 1)
        encoder.setFragmentBuffer(slugBandBuffer, offset: 0, index: 2)
        encoder.setFragmentBuffer(slugBandIndexBuffer, offset: 0, index: 3)
        encoder.setRenderPipelineState(glyphAlphaPipeline)
        repeatingBands(scissorPlan, on: encoder) {
          encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6,
            instanceCount: slugGlyphs.count)
        }
      } else if subpixelAccumReady, let coverageAccum, let colorAccum {
        // Composite the accumulated coverage + premultiplied color over the
        // background once with a full-screen quad: darken (dst *= 1 - cov) then
        // add (dst += color). Both use the same blends as the per-glyph path,
        // but applied a single time per pixel so abutting glyphs sum correctly
        // at seams. Outside glyph quads cov = 0 so the darken is identity and
        // the add is zero — the pass is a no-op there.
        encoder.setViewport(
          MTLViewport(
            originX: 0, originY: 0,
            width: Double(pixelWidth), height: Double(pixelHeight),
            znear: 0, zfar: 1))
        encoder.setRenderPipelineState(subpixelCompositeDarkenPipeline)
        encoder.setFragmentTexture(coverageAccum, index: 0)
        repeatingBands(scissorPlan, on: encoder) {
          encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 3,
            instanceCount: 1)
        }
        encoder.setRenderPipelineState(subpixelCompositeAdditivePipeline)
        encoder.setFragmentTexture(colorAccum, index: 0)
        encoder.setFragmentTexture(coverageAccum, index: 1)
        repeatingBands(scissorPlan, on: encoder) {
          encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 3,
            instanceCount: 1)
        }
      } else {
        // Fallback if the accumulation textures could not be allocated:
        // recompute coverage and composite per glyph (the original two-pass
        // cost, with the seam notch). Still correct for non-abutting text.
        encoder.setVertexBuffer(slugInstanceBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(
          &glyphUniform,
          length: MemoryLayout<SlugGlyphGPUUniforms>.stride,
          index: 1)
        encoder.setFragmentBytes(
          &glyphUniform,
          length: MemoryLayout<SlugGlyphGPUUniforms>.stride,
          index: 4)
        encoder.setFragmentBuffer(slugCurveBuffer, offset: 0, index: 0)
        encoder.setFragmentBuffer(slugGlyphBuffer, offset: 0, index: 1)
        encoder.setFragmentBuffer(slugBandBuffer, offset: 0, index: 2)
        encoder.setFragmentBuffer(slugBandIndexBuffer, offset: 0, index: 3)
        encoder.setRenderPipelineState(glyphCoveragePipeline)
        repeatingBands(scissorPlan, on: encoder) {
          encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6,
            instanceCount: slugGlyphs.count)
        }
        encoder.setRenderPipelineState(glyphColorPipeline)
        repeatingBands(scissorPlan, on: encoder) {
          encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6,
            instanceCount: slugGlyphs.count)
        }
      }
    }

    if !rasterGlyphs.isEmpty,
      let rasterAtlas,
      let rasterBuffer = makeBuffer(rasterGlyphs)
    {
      retainedBuffers.append(rasterBuffer)
      encoder.setRenderPipelineState(rasterGlyphPipeline)
      encoder.setVertexBuffer(rasterBuffer, offset: 0, index: 0)
      encoder.setVertexBytes(
        &vectorUniforms,
        length: MemoryLayout<SlugVectorUniforms>.stride,
        index: 1)
      encoder.setFragmentTexture(rasterAtlas.texture, index: 0)
      encoder.setFragmentSamplerState(sampler, index: 0)
      repeatingBands(scissorPlan, on: encoder) {
        encoder.drawPrimitives(
          type: .triangle,
          vertexStart: 0,
          vertexCount: 6,
          instanceCount: rasterGlyphs.count)
      }
    }

    if !colorGlyphs.isEmpty,
      let colorGlyphAtlas,
      let colorBuffer = makeBuffer(colorGlyphs)
    {
      retainedBuffers.append(colorBuffer)
      encoder.setRenderPipelineState(colorGlyphPipeline)
      encoder.setVertexBuffer(colorBuffer, offset: 0, index: 0)
      encoder.setVertexBytes(
        &vectorUniforms,
        length: MemoryLayout<SlugVectorUniforms>.stride,
        index: 1)
      encoder.setFragmentTexture(colorGlyphAtlas.texture, index: 0)
      encoder.setFragmentSamplerState(sampler, index: 0)
      repeatingBands(scissorPlan, on: encoder) {
        encoder.drawPrimitives(
          type: .triangle,
          vertexStart: 0,
          vertexCount: 6,
          instanceCount: colorGlyphs.count)
      }
    }

    encoder.endEncoding()

    let completion = onFrameCompleted
    if #available(macOS 14.0, *), presentDisplayLink != nil {
      commandBuffer.addCompletedHandler { [weak self] _ in
        _ = retainedBuffers
        if self?.presentsToLayer == true {
          self?.publishLatestTarget(target)
        }
        completion?()
      }
      commandBuffer.commit()
      lastCommandBuffer = commandBuffer
      if waitForFrameCompletion {
        commandBuffer.waitUntilCompleted()
      }
      return true
    }

    if presentsToLayer,
      let drawable = layer.nextDrawable(),
      drawable.texture.width == target.width,
      drawable.texture.height == target.height
    {
      encodeBlit(from: target, to: drawable.texture, commandBuffer: commandBuffer)
      commandBuffer.present(drawable)
    }

    commandBuffer.addCompletedHandler { _ in
      _ = retainedBuffers
      completion?()
    }
    commandBuffer.commit()
    lastCommandBuffer = commandBuffer
    if waitForFrameCompletion {
      commandBuffer.waitUntilCompleted()
    }
    return true
  }

  public func referenceOutline(for scalar: Unicode.Scalar) -> GlyphCurveOutline? {
    ensureGlyph(for: Character(String(scalar)), referenceAtlas: referenceFontAtlas)?.outline
  }

  public func coverageMask(
    for scalar: Unicode.Scalar,
    origin: CGPoint,
    width: Int,
    height: Int
  ) -> [UInt8]? {
    guard width > 0, height > 0 else { return nil }
    guard
      let entry = ensureGlyph(
        for: Character(String(scalar)),
        referenceAtlas: referenceFontAtlas)
    else { return nil }
    guard ensureGeometryBuffersIfNeeded(glyphsNeeded: true) else { return nil }
    guard let texture = makeTexture(pixelWidth: width, pixelHeight: height, storageMode: .shared)
    else { return nil }
    guard let commandBuffer = queue.makeCommandBuffer() else { return nil }

    let instance = SlugGlyphGPUInstance(
      originPx: .zero,
      sizePx: SIMD2<Float>(Float(width), Float(height)),
      localMin: SIMD2<Float>(Float(origin.x), Float(origin.y)),
      localMax: SIMD2<Float>(Float(origin.x + CGFloat(width)), Float(origin.y + CGFloat(height))),
      color: SIMD4<Float>(1, 1, 1, 1),
      glyphIndex: UInt32(entry.glyphIndex))
    guard let instanceBuffer = makeBuffer([instance]) else { return nil }

    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass),
      let curveBuffer,
      let glyphBuffer,
      let bandBuffer,
      let bandIndexBuffer
    else { return nil }
    encoder.setRenderPipelineState(glyphAlphaPipeline)
    encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
    var uniforms = glyphUniforms(
      width: width,
      height: height,
      layout: .grayscale,
      gestureZoomFactor: 1,
      gestureZoomAnchorPoint: .zero)
    encoder.setVertexBytes(&uniforms, length: MemoryLayout<SlugGlyphGPUUniforms>.stride, index: 1)
    encoder.setFragmentBytes(
      &uniforms,
      length: MemoryLayout<SlugGlyphGPUUniforms>.stride,
      index: 4)
    encoder.setFragmentBuffer(curveBuffer, offset: 0, index: 0)
    encoder.setFragmentBuffer(glyphBuffer, offset: 0, index: 1)
    encoder.setFragmentBuffer(bandBuffer, offset: 0, index: 2)
    encoder.setFragmentBuffer(bandIndexBuffer, offset: 0, index: 3)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
    encoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    guard commandBuffer.error == nil else { return nil }

    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    bytes.withUnsafeMutableBytes { raw in
      if let base = raw.baseAddress {
        texture.getBytes(
          base,
          bytesPerRow: width * 4,
          from: MTLRegionMake2D(0, 0, width, height),
          mipmapLevel: 0)
      }
    }
    var alpha = [UInt8](repeating: 0, count: width * height)
    for index in alpha.indices {
      alpha[index] = bytes[index * 4 + 3]
    }
    return alpha
  }

  private func buildInstances(
    commands: [FrameCommand],
    solids: inout [SlugSolidInstance],
    glyphs: inout [SlugGlyphGPUInstance],
    rasterGlyphs: inout [SlugTextureInstance],
    colorGlyphs: inout [SlugTextureInstance]
  ) {
    for command in commands {
      switch command {
      case .rect(let rect, let color, _),
        .cursor(let rect, let color),
        .selection(let rect, let color),
        .findMatch(let rect, let color),
        .findSelected(let rect, let color):
        solids.append(solid(rect: rect, color: color))

      case .glyphRun(
        let origin, let text, let foreground, let background, let attributes, let source,
        let underlineStyle, let underlineColor, _, _
      ):
        appendGlyphRun(
          text,
          origin: origin,
          foreground: foreground,
          background: background,
          attributes: attributes,
          underlineStyle: underlineStyle,
          underlineColor: underlineColor,
          source: source,
          solids: &solids,
          glyphs: &glyphs,
          rasterGlyphs: &rasterGlyphs,
          colorGlyphs: &colorGlyphs)

      case .clip, .texturedQuad:
        break
      }
    }
  }

  private func appendGlyphRun(
    _ text: String,
    origin: CGPoint,
    foreground: UInt32,
    background _: UInt32,
    attributes: TextAttributes,
    underlineStyle: UnderlineStyle,
    underlineColor: UInt32?,
    source: FrameSource,
    solids: inout [SlugSolidInstance],
    glyphs: inout [SlugGlyphGPUInstance],
    rasterGlyphs: inout [SlugTextureInstance],
    colorGlyphs: inout [SlugTextureInstance]
  ) {
    guard !attributes.contains(.invisible) else { return }
    let activeAtlas = source == .sidebar ? sidebarFontAtlas : fontAtlas
    let referenceAtlas = source == .sidebar ? sidebarReferenceFontAtlas : referenceFontAtlas
    let cellAdvance = activeAtlas.cellSize.width
    let baseline = origin.y + activeAtlas.descent

    let pointScale = activeAtlas.pointSize / Self.referencePointSize
    let foregroundColor = slugColor(foreground)
    let ppemPx = Double(activeAtlas.pointSize) * Double(scale)
    let perSideDilatePx = Self.perSideDilatePx(weight: textWeight, ppemPx: ppemPx)
    let bold = attributes.contains(.bold)
    let italic = attributes.contains(.italic)
    let activeVariant = activeAtlas.styledFontVariant(bold: bold, italic: italic)
    let referenceVariant = referenceAtlas.styledFontVariant(bold: bold, italic: italic)
    let referencePostScriptName = FontAtlas.postScriptName(of: referenceVariant.font)
    let fontID = internedFontID(postScriptName: referencePostScriptName, bold: bold, italic: italic)
    frameGlyphFontSizes.insert(Double(activeAtlas.pointSize))

    // Run-level gates (mirrors VectorGlyphRenderer, see execplans/active/
    // slug-render-loop-perf-and-aa-quality.md M1): hoist the color/CJK probes
    // out of the per-cell loop so plain ASCII/Latin rows, the common case,
    // pay neither a per-cell color-glyph probe nor a per-cell CJK check.
    let runWantsColor: Bool
    if source != .sidebar, emojiRenderingMode == .color {
      let hasColorTrait = fontHasColorTrait(bold: bold, italic: italic, font: activeVariant.font)
      runWantsColor = ColorGlyphSupport.textMayContainColor(
        text: text, fontHasColorTrait: hasColorTrait)
    } else {
      runWantsColor = false
    }
    let runMayContainCJK = TerminalCJKFontPolicy.containsCJK(text)

    for (cellIndex, cluster) in text.enumerated() {
      let cellOriginX = origin.x + CGFloat(cellIndex) * cellAdvance
      if runWantsColor,
        ColorGlyphSupport.clusterMayBeColor(cluster),
        let colorFallback = colorGlyphInstance(
          cluster: cluster,
          font: activeVariant.font,
          boldFallback: activeVariant.boldFallback,
          italicFallback: activeVariant.italicFallback,
          position: CGPoint(x: cellOriginX, y: origin.y))
      {
        colorGlyphs.append(colorFallback)
        continue
      }
      if runMayContainCJK,
        TerminalCJKFontPolicy.containsCJK(cluster),
        let fallback = rasterGlyphInstance(
          cluster: cluster,
          font: activeVariant.font,
          boldFallback: activeVariant.boldFallback,
          italicFallback: activeVariant.italicFallback,
          position: CGPoint(x: cellOriginX, y: origin.y),
          color: foreground)
      {
        rasterGlyphs.append(fallback)
        continue
      }
      guard
        let entry = ensureGlyph(
          for: cluster,
          referenceAtlas: referenceAtlas,
          referenceVariant: referenceVariant,
          fontID: fontID,
          attributes: attributes)
      else {
        if let fallback = rasterGlyphInstance(
          cluster: cluster,
          font: activeVariant.font,
          boldFallback: activeVariant.boldFallback,
          italicFallback: activeVariant.italicFallback,
          position: CGPoint(x: cellOriginX, y: origin.y),
          color: foreground)
        {
          rasterGlyphs.append(fallback)
        }
        continue
      }
      let bounds = entry.outline.bounds
      let localPixelPad =
        CGFloat(1 + perSideDilatePx) / max(pointScale * scale, .ulpOfOne)
      let localMin = SIMD2<Float>(
        Float(bounds.minX - localPixelPad),
        Float(bounds.minY - localPixelPad))
      let localMax = SIMD2<Float>(
        Float(bounds.maxX + localPixelPad),
        Float(bounds.maxY + localPixelPad))
      let instanceOrigin = SIMD2<Float>(
        Float((cellOriginX + (bounds.minX - localPixelPad) * pointScale) * scale),
        Float((baseline + (bounds.minY - localPixelPad) * pointScale) * scale))
      let instanceSize = SIMD2<Float>(
        max(0, Float((bounds.width + localPixelPad * 2) * pointScale * scale)),
        max(0, Float((bounds.height + localPixelPad * 2) * pointScale * scale)))
      guard instanceSize.x > 0, instanceSize.y > 0 else { continue }
      frameQuadHeights.insert(Int((CGFloat(instanceSize.y) * gestureZoom).rounded()))
      glyphs.append(
        SlugGlyphGPUInstance(
          originPx: instanceOrigin,
          sizePx: instanceSize,
          localMin: localMin,
          localMax: localMax,
          color: foregroundColor,
          glyphIndex: UInt32(entry.glyphIndex),
          dilation: perSideDilatePx))
    }

    appendDecorations(
      text: text,
      origin: origin,
      attributes: attributes,
      underlineStyle: underlineStyle,
      underlineColor: underlineColor,
      atlas: activeAtlas,
      foreground: foreground,
      solids: &solids)
  }

  private func appendDecorations(
    text: String,
    origin: CGPoint,
    attributes: TextAttributes,
    underlineStyle: UnderlineStyle,
    underlineColor: UInt32?,
    atlas: FontAtlas,
    foreground: UInt32,
    solids: inout [SlugSolidInstance]
  ) {
    guard
      let layout = TextDecorationLayout.make(
        origin: origin,
        cellCount: TerminalDisplayWidth.cells(of: text),
        attributes: attributes,
        underlineStyle: underlineStyle,
        cellAdvance: atlas.cellSize.width,
        cellHeight: atlas.cellSize.height,
        descent: atlas.descent,
        scale: scale)
    else { return }

    let underlineRGBA = underlineColor ?? foreground
    for rect in layout.underlineRects {
      solids.append(solid(rect: rect, color: underlineRGBA))
    }
    if !layout.curlyUnderlinePoints.isEmpty {
      for (start, end) in zip(
        layout.curlyUnderlinePoints,
        layout.curlyUnderlinePoints.dropFirst())
      {
        solids.append(
          solid(
            rect: CGRect(
              x: start.x,
              y: min(start.y, end.y),
              width: max(end.x - start.x, layout.thickness),
              height: max(layout.thickness, abs(end.y - start.y))),
            color: underlineRGBA))
      }
    }
    if let rect = layout.strikethroughRect {
      solids.append(solid(rect: rect, color: foreground))
    }
    if let rect = layout.overlineRect {
      solids.append(solid(rect: rect, color: foreground))
    }
  }

  /// Interns (reference PostScript name, bold, italic) to a small `Int` once
  /// per glyph run, so the per-cell resolve-cache key never re-hashes a
  /// `String`. Semantics stay visual-font-identity (ADR 0027): this interns
  /// identity, not size, and geometry stays keyed separately in `entriesByKey`.
  private func internedFontID(postScriptName: String, bold: Bool, italic: Bool) -> Int {
    let key = SlugFontIdentityKey(postScriptName: postScriptName, bold: bold, italic: italic)
    if let existing = fontIdentityIntern[key] { return existing }
    let id = nextFontIdentityID
    nextFontIdentityID += 1
    fontIdentityIntern[key] = id
    return id
  }

  /// Font color-glyph trait, cached per (bold, italic) so the per-run cost is
  /// a cheap `UInt32` dictionary lookup instead of `CTFontGetSymbolicTraits`.
  /// Only called for `source != .sidebar` fonts (see `appendGlyphRun`), so no
  /// atlas bit is needed in the key.
  private func fontHasColorTrait(bold: Bool, italic: Bool, font: CTFont) -> Bool {
    var key: UInt32 = 0
    if bold { key |= 0x1 }
    if italic { key |= 0x2 }
    if let cached = colorTraitCache[key] { return cached }
    let value = ColorGlyphSupport.fontHasColorGlyphTrait(font)
    colorTraitCache[key] = value
    return value
  }

  private func ensureGlyph(
    for cluster: Character,
    referenceAtlas: FontAtlas,
    attributes: TextAttributes = []
  ) -> SlugGlyphEntry? {
    let bold = attributes.contains(.bold)
    let italic = attributes.contains(.italic)
    let referenceVariant = referenceAtlas.styledFontVariant(bold: bold, italic: italic)
    let fontID = internedFontID(
      postScriptName: FontAtlas.postScriptName(of: referenceVariant.font),
      bold: bold,
      italic: italic)
    return ensureGlyph(
      for: cluster,
      referenceAtlas: referenceAtlas,
      referenceVariant: referenceVariant,
      fontID: fontID,
      attributes: attributes)
  }

  private func ensureGlyph(
    for cluster: Character,
    referenceAtlas: FontAtlas,
    referenceVariant: (font: CTFont, boldFallback: Bool, italicFallback: Bool),
    fontID: Int,
    attributes: TextAttributes
  ) -> SlugGlyphEntry? {
    let resolveKey = SlugGlyphResolveKey(fontID: fontID, cluster: cluster)
    if let cached = entriesByResolveKey[resolveKey] { return cached }
    guard
      let resolved = resolveGlyph(
        for: cluster,
        referenceAtlas: referenceAtlas,
        referenceVariant: referenceVariant,
        attributes: attributes)
    else { return nil }
    let key = SlugGlyphGeometryKey(
      postScriptName: FontAtlas.postScriptName(of: resolved.font),
      glyph: resolved.glyph)
    if let cached = entriesByKey[key] {
      entriesByResolveKey[resolveKey] = cached
      return cached
    }
    guard let outline = curveStore.outline(for: resolved.glyph, font: resolved.font) else {
      return nil
    }
    guard !outline.curves.isEmpty else { return nil }

    let glyphIndex = glyphs.count
    let curveStart = curves.count
    for curve in outline.curves {
      curves.append(
        SlugGlyphGPUCurve(
          p0: SIMD2<Float>(Float(curve.p0.x), Float(curve.p0.y)),
          p1: SIMD2<Float>(Float(curve.p1.x), Float(curve.p1.y)),
          p2: SIMD2<Float>(Float(curve.p2.x), Float(curve.p2.y))))
    }

    let horizontalBandStart = bands.count
    appendBands(outline: outline, curveStart: curveStart, axis: .horizontal)
    let verticalBandStart = bands.count
    appendBands(outline: outline, curveStart: curveStart, axis: .vertical)
    glyphs.append(
      SlugGlyphGPUGlyph(
        boundsMin: SIMD2<Float>(Float(outline.bounds.minX), Float(outline.bounds.minY)),
        boundsMax: SIMD2<Float>(Float(outline.bounds.maxX), Float(outline.bounds.maxY)),
        curveStart: UInt32(curveStart),
        curveCount: UInt32(outline.curves.count),
        horizontalBandStart: UInt32(horizontalBandStart),
        horizontalBandCount: UInt32(Self.bandCount),
        verticalBandStart: UInt32(verticalBandStart),
        verticalBandCount: UInt32(Self.bandCount)))

    let entry = SlugGlyphEntry(key: key, outline: outline, glyphIndex: glyphIndex)
    entriesByKey[key] = entry
    entriesByResolveKey[resolveKey] = entry
    geometryEntryBuildCount += 1
    geometryBuffersDirty = true
    return entry
  }

  private func resolveGlyph(
    for cluster: Character,
    referenceAtlas: FontAtlas,
    referenceVariant: (font: CTFont, boldFallback: Bool, italicFallback: Bool),
    attributes: TextAttributes
  ) -> (font: CTFont, glyph: CGGlyph)? {
    let text = String(cluster)
    if text.unicodeScalars.count == 1,
      let scalar = text.unicodeScalars.first,
      scalar.value <= UInt32(UInt16.max),
      !TerminalCJKFontPolicy.containsCJK(text)
    {
      var unit = UniChar(scalar.value)
      var glyph = CGGlyph()
      if CTFontGetGlyphsForCharacters(referenceVariant.font, &unit, &glyph, 1), glyph != 0 {
        return (referenceVariant.font, glyph)
      }
    }
    return fallbackResolvedGlyph(
      text: text,
      baseFont: referenceVariant.font,
      cellAdvance: referenceAtlas.cellSize.width)
  }

  private func fallbackResolvedGlyph(
    text: String,
    baseFont: CTFont,
    cellAdvance: CGFloat
  ) -> (font: CTFont, glyph: CGGlyph)? {
    let line = TerminalGlyphFallback.fallbackLine(
      text: text,
      font: baseFont,
      cellAdvance: cellAdvance)
    let runs = CTLineGetGlyphRuns(line) as NSArray
    for case let run as CTRun in runs {
      guard CTRunGetGlyphCount(run) > 0 else { continue }
      var glyph = CGGlyph()
      CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &glyph)
      guard glyph != 0 else { continue }
      let attributes = CTRunGetAttributes(run) as NSDictionary
      let font =
        attributes[kCTFontAttributeName].map { $0 as! CTFont }
        ?? baseFont
      return (font, glyph)
    }
    return nil
  }

  private func colorGlyphInstance(
    cluster: Character,
    font: CTFont,
    boldFallback: Bool,
    italicFallback: Bool,
    position: CGPoint
  ) -> SlugTextureInstance? {
    guard let colorGlyphAtlas,
      let entry = colorGlyphAtlas.entry(
        character: cluster,
        font: font,
        boldFallback: boldFallback,
        italicFallback: italicFallback)
    else { return nil }
    let atlasSize = Float(colorGlyphAtlas.textureSize)
    return SlugTextureInstance(
      origin: SIMD2<Float>(
        Float((position.x + entry.logicalOriginX) * scale),
        Float(position.y * scale)),
      size: SIMD2<Float>(Float(entry.pixelWidth), Float(entry.pixelHeight)),
      uvOrigin: SIMD2<Float>(
        Float(entry.originX) / atlasSize,
        Float(entry.originY) / atlasSize),
      uvSize: SIMD2<Float>(
        Float(entry.pixelWidth) / atlasSize,
        Float(entry.pixelHeight) / atlasSize),
      color: SIMD4<Float>(1, 1, 1, 1))
  }

  private func rasterGlyphInstance(
    cluster: Character,
    font: CTFont,
    boldFallback: Bool,
    italicFallback: Bool,
    position: CGPoint,
    color: UInt32
  ) -> SlugTextureInstance? {
    guard let rasterAtlas,
      let entry = rasterAtlas.entry(
        character: cluster,
        font: font,
        boldFallback: boldFallback,
        italicFallback: italicFallback)
    else { return nil }
    let atlasSize = Float(rasterAtlas.textureSize)
    return SlugTextureInstance(
      origin: SIMD2<Float>(
        Float((position.x + entry.logicalOriginX) * scale),
        Float(position.y * scale)),
      size: SIMD2<Float>(Float(entry.pixelWidth), Float(entry.pixelHeight)),
      uvOrigin: SIMD2<Float>(
        Float(entry.originX) / atlasSize,
        Float(entry.originY) / atlasSize),
      uvSize: SIMD2<Float>(
        Float(entry.pixelWidth) / atlasSize,
        Float(entry.pixelHeight) / atlasSize),
      color: slugColor(color))
  }

  private enum SlugBandAxis {
    case horizontal
    case vertical
  }

  private func appendBands(outline: GlyphCurveOutline, curveStart: Int, axis: SlugBandAxis) {
    let minValue = axis == .horizontal ? outline.bounds.minY : outline.bounds.minX
    let extent = max(axis == .horizontal ? outline.bounds.height : outline.bounds.width, .ulpOfOne)
    for band in 0..<Self.bandCount {
      let bandMin = minValue + extent * CGFloat(band) / CGFloat(Self.bandCount)
      let bandMax = minValue + extent * CGFloat(band + 1) / CGFloat(Self.bandCount)
      let indexStart = bandIndices.count
      let intersecting = outline.curves.enumerated()
        .filter { _, curve in curveIntersectsBand(curve, min: bandMin, max: bandMax, axis: axis) }
        .sorted { lhs, rhs in
          curveBreakCoordinate(lhs.element, axis: axis)
            > curveBreakCoordinate(rhs.element, axis: axis)
        }
      for (localIndex, _) in intersecting {
        bandIndices.append(UInt32(curveStart + localIndex))
      }
      bands.append(
        SlugGlyphGPUBand(
          indexStart: UInt32(indexStart),
          indexCount: UInt32(bandIndices.count - indexStart)))
    }
  }

  private func curveIntersectsBand(
    _ curve: GlyphQuadraticCurve,
    min: CGFloat,
    max: CGFloat,
    axis: SlugBandAxis
  )
    -> Bool
  {
    let epsilon = CGFloat(1.0 / 1024.0)
    switch axis {
    case .horizontal:
      if abs(curve.p0.y - curve.p1.y) < epsilon && abs(curve.p1.y - curve.p2.y) < epsilon {
        return false
      }
      let curveMinY = Swift.min(curve.p0.y, curve.p1.y, curve.p2.y)
      let curveMaxY = Swift.max(curve.p0.y, curve.p1.y, curve.p2.y)
      return curveMinY <= max + epsilon && curveMaxY >= min - epsilon
    case .vertical:
      if abs(curve.p0.x - curve.p1.x) < epsilon && abs(curve.p1.x - curve.p2.x) < epsilon {
        return false
      }
      let curveMinX = Swift.min(curve.p0.x, curve.p1.x, curve.p2.x)
      let curveMaxX = Swift.max(curve.p0.x, curve.p1.x, curve.p2.x)
      return curveMinX <= max + epsilon && curveMaxX >= min - epsilon
    }
  }

  private func curveBreakCoordinate(_ curve: GlyphQuadraticCurve, axis: SlugBandAxis) -> CGFloat {
    switch axis {
    case .horizontal:
      return Swift.max(curve.p0.x, curve.p1.x, curve.p2.x)
    case .vertical:
      return Swift.max(curve.p0.y, curve.p1.y, curve.p2.y)
    }
  }

  private func ensureGeometryBuffersIfNeeded(glyphsNeeded: Bool) -> Bool {
    guard glyphsNeeded else { return true }
    guard geometryBuffersDirty || curveBuffer == nil else { return true }
    guard !curves.isEmpty, !glyphs.isEmpty else { return false }
    guard
      ensureIncrementalBuffer(
        curves, buffer: &curveBuffer, uploadedCount: &curveBufferUploadedCount),
      ensureIncrementalBuffer(
        glyphs, buffer: &glyphBuffer, uploadedCount: &glyphBufferUploadedCount),
      ensureIncrementalBuffer(
        bands, buffer: &bandBuffer, uploadedCount: &bandBufferUploadedCount)
    else { return false }
    // `bandIndices` can only be empty before the first glyph's bands are
    // appended, which the `curves`/`glyphs` emptiness guard above already
    // excludes in practice; kept as a defensive fallback (matching the
    // pre-M4 behavior) rather than folded into the incremental path so an
    // unreachable edge case cannot corrupt the tracked upload count.
    if bandIndices.isEmpty {
      if bandIndexBuffer == nil {
        guard let placeholder = makeBuffer([UInt32(0)]) else { return false }
        bandIndexBuffer = placeholder
      }
    } else {
      guard
        ensureIncrementalBuffer(
          bandIndices, buffer: &bandIndexBuffer, uploadedCount: &bandIndexBufferUploadedCount)
      else { return false }
    }
    geometryBuffersDirty = false
    geometryBufferUploadCount += 1
    return true
  }

  /// Uploads `values[uploadedCount...]` into `buffer`, the M4 incremental
  /// geometry upload path (see
  /// `execplans/active/slug-render-loop-perf-and-aa-quality.md` M4): the
  /// geometry arrays (`curves`/`glyphs`/`bands`/`bandIndices`) only ever grow
  /// by appending whole new glyphs, so once a buffer has spare capacity, a
  /// later call only needs to copy the newly appended tail, not the whole
  /// array. Capacity doubles (starting from `minimumCapacity`) only when the
  /// existing buffer cannot hold `values.count` elements; a reallocation
  /// re-copies from `values` (the CPU-side source of truth) rather than
  /// migrating bytes from the old, smaller buffer.
  private func ensureIncrementalBuffer<T>(
    _ values: [T],
    buffer: inout MTLBuffer?,
    uploadedCount: inout Int,
    minimumCapacity: Int = 1024
  ) -> Bool {
    guard !values.isEmpty else { return true }
    guard values.count != uploadedCount || buffer == nil else { return true }
    let stride = MemoryLayout<T>.stride
    let existingCapacity = buffer.map { $0.length / stride } ?? 0
    if buffer == nil || existingCapacity < values.count {
      let newCapacity = max(minimumCapacity, values.count, existingCapacity * 2)
      guard
        let newBuffer = device.makeBuffer(
          length: newCapacity * stride, options: .storageModeShared)
      else { return false }
      let copied: Bool = values.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return false }
        newBuffer.contents().copyMemory(from: base, byteCount: values.count * stride)
        return true
      }
      guard copied else { return false }
      buffer = newBuffer
      uploadedCount = values.count
      return true
    }
    guard let existingBuffer = buffer, values.count > uploadedCount else { return true }
    let tailCount = values.count - uploadedCount
    let copied: Bool = values.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return false }
      let destination = existingBuffer.contents().advanced(by: uploadedCount * stride)
      let source = base.advanced(by: uploadedCount * stride)
      destination.copyMemory(from: source, byteCount: tailCount * stride)
      return true
    }
    guard copied else { return false }
    uploadedCount = values.count
    return true
  }

  private func solid(rect: CGRect, color: UInt32) -> SlugSolidInstance {
    SlugSolidInstance(
      origin: SIMD2<Float>(Float(rect.minX * scale), Float(rect.minY * scale)),
      size: SIMD2<Float>(Float(rect.width * scale), Float(rect.height * scale)),
      color: slugColor(color))
  }

  private func slugColor(_ rgba: UInt32) -> SIMD4<Float> {
    SIMD4<Float>(
      Self.srgbToLinear(Float((rgba >> 24) & 0xFF) / 255),
      Self.srgbToLinear(Float((rgba >> 16) & 0xFF) / 255),
      Self.srgbToLinear(Float((rgba >> 8) & 0xFF) / 255),
      Float(rgba & 0xFF) / 255)
  }

  private static func linearizedClearColor(_ commands: [FrameCommand]) -> MTLClearColor {
    let c = MetalRenderer.fullRedrawClearColor(commands)
    return MTLClearColor(
      red: Double(srgbToLinear(Float(c.red))),
      green: Double(srgbToLinear(Float(c.green))),
      blue: Double(srgbToLinear(Float(c.blue))),
      alpha: c.alpha)
  }

  private static func makeColorGlyphAtlas(
    device: MTLDevice,
    fontAtlas: FontAtlas,
    scale: CGFloat
  ) -> ColorGlyphAtlas? {
    ColorGlyphAtlas(
      device: device,
      cellWidth: fontAtlas.cellSize.width,
      cellHeight: fontAtlas.cellSize.height,
      descent: fontAtlas.descent,
      scale: scale)
  }

  private static func makeRasterGlyphAtlas(
    device: MTLDevice,
    fontAtlas: FontAtlas,
    scale: CGFloat
  ) -> MetalGlyphAtlas? {
    MetalGlyphAtlas(
      device: device,
      cellWidth: fontAtlas.cellSize.width,
      cellHeight: fontAtlas.cellSize.height,
      descent: fontAtlas.descent,
      scale: scale)
  }

  private static func srgbToLinear(_ c: Float) -> Float {
    c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
  }

  private func glyphUniforms(
    width: Int,
    height: Int,
    layout: VectorSubpixelLayout? = nil,
    gestureZoomFactor: CGFloat? = nil,
    gestureZoomAnchorPoint: CGPoint? = nil
  ) -> SlugGlyphGPUUniforms {
    let resolved = layout ?? effectiveSubpixelLayout
    let zoom = gestureZoomFactor ?? gestureZoom
    let anchor = gestureZoomAnchorPoint ?? gestureZoomAnchor
    return SlugGlyphGPUUniforms(
      surfaceSizePixels: SIMD2<Float>(Float(width), Float(height)),
      scale: Float(scale),
      gestureZoom: Float(zoom),
      gestureZoomAnchor: SIMD2<Float>(Float(anchor.x), Float(anchor.y)),
      subpixelRBounds: resolved.rBounds,
      subpixelGBounds: resolved.gBounds,
      subpixelBBounds: resolved.bBounds,
      subpixelMode: resolved == .grayscale ? 0 : 1)
  }

  private func encodeBlit(
    from source: MTLTexture,
    to destination: MTLTexture,
    commandBuffer: MTLCommandBuffer
  ) {
    guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
    blit.label = "laban.slug.present-blit"
    blit.copy(
      from: source,
      sourceSlice: 0,
      sourceLevel: 0,
      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
      sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
      to: destination,
      destinationSlice: 0,
      destinationLevel: 0,
      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
    blit.endEncoding()
  }

  private func presentLatestTarget(into drawable: any CAMetalDrawable) -> Bool {
    presentTargetLock.lock()
    let target = latestPresentedTarget
    presentTargetLock.unlock()
    guard let target,
      target.width == drawable.texture.width,
      target.height == drawable.texture.height
    else { return false }
    guard let presentQueue,
      let commandBuffer = presentQueue.makeCommandBuffer()
    else { return false }
    encodeBlit(from: target, to: drawable.texture, commandBuffer: commandBuffer)
    commandBuffer.present(drawable)
    commandBuffer.commit()
    return true
  }

  private func publishLatestTarget(_ target: MTLTexture) {
    presentTargetLock.lock()
    latestPresentedTarget = target
    presentTargetLock.unlock()
    if #available(macOS 14.0, *) {
      presentDisplayLink?.notifyContentPublished()
    }
  }

  /// Test-only (not `public`): lets `SlugGlyphDamageTests` prove an
  /// empty-effective-damage frame does not rotate the ring, without
  /// extending the renderer's public contract.
  var targetRingCursorForTesting: Int { targetRingCursor }

  /// Number of ring slots `render()` rotates through. 3 under the
  /// display-link present path (a slot is `ringDepth - 1` frames stale when
  /// next drawn into); 1 outside it (headless/legacy single persistent
  /// target, the degenerate case where a slot is never stale).
  private var ringDepth: Int { presentQueue != nil ? Self.targetRingDepth : 1 }

  /// Pure query: which slot `render()` would draw into next, and whether that
  /// requires (re)allocating textures, without mutating any ring state. Used
  /// by M2's empty-effective-damage fast path to decide whether to render at
  /// all before committing to rotating the ring (see `render(_:damage:)`).
  private func peekNextRingSlot() -> (slot: Int, needsRebuild: Bool) {
    if presentQueue != nil {
      let ringValid =
        targetRing.count == Self.targetRingDepth
        && targetRing[0].width == pixelWidth
        && targetRing[0].height == pixelHeight
      guard ringValid else { return (0, true) }
      return ((targetRingCursor + 1) % Self.targetRingDepth, false)
    }
    let legacyValid =
      targetTexture != nil
      && targetTexture!.width == pixelWidth
      && targetTexture!.height == pixelHeight
    return (0, !legacyValid)
  }

  /// Mutating counterpart to `peekNextRingSlot()`: actually rotates the ring
  /// cursor (or (re)allocates textures) to `slot`. Must be called with the
  /// exact result `peekNextRingSlot()` returned for this frame.
  private func commitRingSlot(_ slot: Int, rebuild: Bool) -> MTLTexture? {
    if presentQueue != nil {
      if rebuild {
        targetRing.removeAll(keepingCapacity: true)
        for i in 0..<Self.targetRingDepth {
          guard
            let texture = makeTexture(
              pixelWidth: pixelWidth, pixelHeight: pixelHeight, storageMode: .shared)
          else { return nil }
          texture.label = "laban.slug.target.\(i)"
          targetRing.append(texture)
        }
        targetRingCursor = 0
        targetTexture = targetRing[0]
        return targetRing[0]
      }
      targetRingCursor = slot
      let texture = targetRing[slot]
      targetTexture = texture
      return texture
    }

    if rebuild {
      let texture = makeTexture(
        pixelWidth: pixelWidth, pixelHeight: pixelHeight, storageMode: .shared)
      texture?.label = "laban.slug.target"
      targetTexture = texture
      return texture
    }
    return targetTexture
  }

  private func ensureTargetTexture() -> MTLTexture? {
    let (slot, rebuild) = peekNextRingSlot()
    return commitRingSlot(slot, rebuild: rebuild)
  }

  /// Resizes `slotDamageAccumulators`/`slotNeedsForceFull` to `ringDepth`
  /// whenever the ring is (re)allocated, marking every slot as needing a hard
  /// full redraw (fresh textures have undefined content).
  private func ensureSlotDamageStateSized(rebuild: Bool) {
    let depth = ringDepth
    guard rebuild || slotDamageAccumulators.count != depth else { return }
    slotDamageAccumulators = Array(repeating: DirtyYRangeSet([]), count: depth)
    slotNeedsForceFull = Array(repeating: true, count: depth)
  }

  private func cursorRects(in commands: [FrameCommand]) -> [CGRect] {
    var rects: [CGRect] = []
    for command in commands {
      if case .cursor(let rect, _) = command {
        rects.append(rect)
      }
    }
    return rects
  }

  /// Cursor rects arrive as ordinary solids, so a cursor blink frame (same
  /// text, toggled cursor) looks like "nothing changed" to the terminal's own
  /// damage tracking. Unioning the previous and current cursor rects into the
  /// incoming damage before it reaches the per-slot accumulators guarantees
  /// an empty-partial blink frame still redraws exactly the cursor cells.
  private func cursorDamage(previous: [CGRect], current: [CGRect]) -> DirtyYRangeSet {
    guard !previous.isEmpty || !current.isEmpty else { return DirtyYRangeSet([]) }
    var ranges: [DirtyYRange] = []
    ranges.reserveCapacity(previous.count + current.count)
    for rect in previous {
      ranges.append(DirtyYRange(y: rect.origin.y, height: rect.size.height))
    }
    for rect in current {
      ranges.append(DirtyYRange(y: rect.origin.y, height: rect.size.height))
    }
    return DirtyYRangeSet(ranges)
  }

  /// True when any state that changes what every pixel on screen looks like
  /// (independent of the terminal's own row-dirty tracking) moved since the
  /// last `render()` call. `gestureZoom` is Slug/Vector-side gesture state the
  /// caller's damage computation does not know about; the rest can change via
  /// live-setting observers between frames.
  private func configChangedSincePreviousFrame() -> Bool {
    previousGestureZoom != gestureZoom
      || previousGestureZoomAnchor != gestureZoomAnchor
      || previousEffectiveSubpixelLayout != effectiveSubpixelLayout
      || previousTextWeight != textWeight
      || previousEmojiRenderingMode != emojiRenderingMode
  }

  private func snapshotConfigForNextFrame() {
    previousGestureZoom = gestureZoom
    previousGestureZoomAnchor = gestureZoomAnchor
    previousEffectiveSubpixelLayout = effectiveSubpixelLayout
    previousTextWeight = textWeight
    previousEmojiRenderingMode = emojiRenderingMode
  }

  /// GPU-private, 1:1 with the render target. The accumulate pass writes
  /// per-channel coverage into `subpixelCoverageAccum` and premultiplied
  /// foreground into `subpixelColorAccum` (additive blend), and the composite
  /// pass reads them back to darken + add the target once. Both recreated on
  /// resize. Returns nil for either if allocation fails; the caller falls back
  /// to the per-glyph "over" path.
  private func ensureSubpixelAccumTextures() -> (coverage: MTLTexture?, color: MTLTexture?) {
    if let coverage = subpixelCoverageAccum,
      let color = subpixelColorAccum,
      coverage.width == pixelWidth, coverage.height == pixelHeight,
      color.width == pixelWidth, color.height == pixelHeight
    {
      return (coverage, color)
    }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba16Float,
      width: pixelWidth,
      height: pixelHeight,
      mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .private
    let coverage = device.makeTexture(descriptor: descriptor)
    coverage?.label = "laban.slug.subpixel-coverage-accum"
    let color = device.makeTexture(descriptor: descriptor)
    color?.label = "laban.slug.subpixel-color-accum"
    subpixelCoverageAccum = coverage
    subpixelColorAccum = color
    return (coverage, color)
  }

  private func makeTexture(
    pixelWidth: Int,
    pixelHeight: Int,
    storageMode: MTLStorageMode
  ) -> MTLTexture? {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: layer.pixelFormat,
      width: pixelWidth,
      height: pixelHeight,
      mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
    descriptor.storageMode = storageMode
    return device.makeTexture(descriptor: descriptor)
  }

  private func makeBuffer<T>(_ values: [T]) -> MTLBuffer? {
    guard !values.isEmpty else { return nil }
    var copy = values
    let length = copy.count * MemoryLayout<T>.stride
    return copy.withUnsafeMutableBytes { raw in
      guard let base = raw.baseAddress else { return nil }
      return device.makeBuffer(bytes: base, length: length, options: .storageModeShared)
    }
  }
}

private func configureSlugAlphaBlend(_ attachment: MTLRenderPipelineColorAttachmentDescriptor?) {
  guard let attachment else { return }
  attachment.isBlendingEnabled = true
  attachment.rgbBlendOperation = .add
  attachment.alphaBlendOperation = .add
  attachment.sourceRGBBlendFactor = .one
  attachment.sourceAlphaBlendFactor = .one
  attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
  attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
}

extension SlugGlyphRenderer: GestureZoomRenderable {
  public var zoomDiagnostics: RendererZoomDiagnostics {
    RendererZoomDiagnostics(
      glyphFontSizes: lastFrameGlyphFontSizes,
      rasterAtlasCellHeight: 0,
      quadHeights: lastFrameQuadHeights,
      curveBufferBuildCount: geometryEntryBuildCount,
      geometryBufferUploadCount: geometryBufferUploadCount)
  }
}
