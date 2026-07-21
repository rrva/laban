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

// Per-glyph animation channel (execplans/active/per-glyph-animation-channel.md):
// `effectKind`/`effectStart` ride the two former pad words, so the instance
// stride stays 64 B and kind 0 (none) is byte-identical to the pre-channel
// layout. The Metal mirror in VectorGlyphShaders.metal must stay
// byte-identical with this struct.
struct SlugGlyphGPUInstance {
  var originPx: SIMD2<Float>
  var sizePx: SIMD2<Float>
  var localMin: SIMD2<Float>
  var localMax: SIMD2<Float>
  var color: SIMD4<Float>
  var glyphIndex: UInt32
  var dilation: Float = 0
  var effectKind: UInt32 = 0
  var effectStart: Float = 0
}

// Motion variant: 96 bytes, matching the Metal mirror in
// VectorGlyphShaders.metal. It carries the normal Slug instance fields plus
// the start color and duration needed for foreground-color spinner motion.
struct SlugGlyphMotionGPUInstance {
  var originPx: SIMD2<Float>
  var sizePx: SIMD2<Float>
  var localMin: SIMD2<Float>
  var localMax: SIMD2<Float>
  var color: SIMD4<Float>
  var glyphIndex: UInt32
  var dilation: Float = 0
  var effectKind: UInt32 = 0
  var effectStart: Float = 0
  var duration: Float = 0
  var startColor: SIMD4<Float> = .zero
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
  var timeSeconds: Float = 0
  var bellAmplitudePx: Float = 0
  var bellDirection: Float = 0
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

private struct SlugTranslucentPipelines {
  let solid: MTLRenderPipelineState
  let replaceSolid: MTLRenderPipelineState
  let glyphAlpha: MTLRenderPipelineState
  let rasterGlyph: MTLRenderPipelineState
  let colorGlyph: MTLRenderPipelineState
}

/// Lazily builds only the rgba16Float pipelines Slug's forced-grayscale
/// translucent path can use. Keeping this separate from `init` means an
/// always-opaque renderer compiles exactly its shipped pipeline set.
private enum SlugTranslucentPipelineCache {
  private static let lock = NSLock()
  private static var cache: [ObjectIdentifier: SlugTranslucentPipelines] = [:]

  static func pipelines(
    device: MTLDevice,
    library: MTLLibrary
  ) -> SlugTranslucentPipelines? {
    let key = ObjectIdentifier(device)
    lock.lock()
    if let cached = cache[key] {
      lock.unlock()
      return cached
    }
    lock.unlock()

    guard let translucentLibrary = VectorGlyphShaderCache.translucentLibrary(device: device),
      let solidVertex = library.makeFunction(name: "vectorSolidVertex"),
      let solidFragment = library.makeFunction(name: "vectorSolidFragment"),
      let textureVertex = library.makeFunction(name: "vectorGlyphVertex"),
      let rasterGlyphFragment = library.makeFunction(name: "vectorRasterGlyphFragment"),
      let colorGlyphFragment = translucentLibrary.makeFunction(
        name: "translucentVectorColorGlyphFragment"),
      let glyphVertex = library.makeFunction(name: "slugGlyphVertex"),
      let glyphAlphaFragment = library.makeFunction(name: "slugGlyphAlphaFragment")
    else { return nil }

    func descriptor(
      label: String,
      vertex: MTLFunction,
      fragment: MTLFunction,
      blended: Bool
    ) -> MTLRenderPipelineDescriptor {
      let value = MTLRenderPipelineDescriptor()
      value.label = label
      value.vertexFunction = vertex
      value.fragmentFunction = fragment
      value.colorAttachments[0]?.pixelFormat = .rgba16Float
      if blended {
        configureSlugAlphaBlend(value.colorAttachments[0])
      } else {
        value.colorAttachments[0]?.isBlendingEnabled = false
      }
      return value
    }

    guard
      let solid = try? device.makeRenderPipelineState(
        descriptor: descriptor(
          label: "laban.slug.translucent-solid",
          vertex: solidVertex,
          fragment: solidFragment,
          blended: true)),
      let replaceSolid = try? device.makeRenderPipelineState(
        descriptor: descriptor(
          label: "laban.slug.translucent-solid-replace",
          vertex: solidVertex,
          fragment: solidFragment,
          blended: false)),
      let glyphAlpha = try? device.makeRenderPipelineState(
        descriptor: descriptor(
          label: "laban.slug.translucent-glyph-alpha",
          vertex: glyphVertex,
          fragment: glyphAlphaFragment,
          blended: true)),
      let rasterGlyph = try? device.makeRenderPipelineState(
        descriptor: descriptor(
          label: "laban.slug.translucent-raster-glyph",
          vertex: textureVertex,
          fragment: rasterGlyphFragment,
          blended: true)),
      let colorGlyph = try? device.makeRenderPipelineState(
        descriptor: descriptor(
          label: "laban.slug.translucent-color-glyph",
          vertex: textureVertex,
          fragment: colorGlyphFragment,
          blended: true))
    else { return nil }

    let pipelines = SlugTranslucentPipelines(
      solid: solid,
      replaceSolid: replaceSolid,
      glyphAlpha: glyphAlpha,
      rasterGlyph: rasterGlyph,
      colorGlyph: colorGlyph)
    lock.lock()
    if let existing = cache[key] {
      lock.unlock()
      return existing
    }
    cache[key] = pipelines
    lock.unlock()
    return pipelines
  }
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
  private let shaderLibrary: MTLLibrary
  private let solidPipeline: MTLRenderPipelineState
  private let replaceSolidPipeline: MTLRenderPipelineState
  private let glyphAlphaPipeline: MTLRenderPipelineState
  private let glyphCoveragePipeline: MTLRenderPipelineState
  private let glyphColorPipeline: MTLRenderPipelineState
  private let slugAccumulatePipeline: MTLRenderPipelineState
  private let subpixelCompositeDarkenPipeline: MTLRenderPipelineState
  private let subpixelCompositeAdditivePipeline: MTLRenderPipelineState
  private let rasterGlyphPipeline: MTLRenderPipelineState
  private let colorGlyphPipeline: MTLRenderPipelineState
  /// Nil for an always-opaque renderer so default activation compiles no extra
  /// translucent PSOs.
  private var translucentPipelines: SlugTranslucentPipelines?
  private var linearPremultipliedResolvePipeline: MTLRenderPipelineState?
  /// Lazy motion-pipeline variants; created on first frame that needs them.
  private var motionGlyphAlphaPipeline: MTLRenderPipelineState?
  private var motionSlugAccumulatePipeline: MTLRenderPipelineState?
  private var motionGlyphCoveragePipeline: MTLRenderPipelineState?
  private var motionGlyphColorPipeline: MTLRenderPipelineState?
  private var motionTranslucentGlyphAlphaPipeline: MTLRenderPipelineState?
  private let sampler: MTLSamplerState
  public let layer: CAMetalLayer

  public private(set) var fontAtlas: FontAtlas
  public private(set) var sidebarFontAtlas: FontAtlas
  private var referenceFontAtlas: FontAtlas
  private var sidebarReferenceFontAtlas: FontAtlas

  private let curveStore = GlyphCurveStore()
  private var entriesByKey: [SlugGlyphGeometryKey: SlugGlyphEntry] = [:]
  private var entriesByResolveKey: [SlugGlyphResolveKey: SlugGlyphEntry] = [:]
  /// Resolve keys whose cold-path resolution previously returned nil (no
  /// CTFont glyph, or an empty outline such as a space character). Checked
  /// right after the `entriesByResolveKey` hit check so a cluster that can
  /// never resolve stops re-running CTFont/outline work every frame it
  /// appears. Never cleared: like `entriesByResolveKey`, the key embeds the
  /// interned font identity, so a font change produces new keys naturally.
  private var failedResolveKeys: Set<SlugGlyphResolveKey> = []
  private var fontIdentityIntern: [SlugFontIdentityKey: Int] = [:]
  private var nextFontIdentityID = 0
  /// Font color-glyph trait, keyed like `VectorGlyphRenderer.fontCache`
  /// (attrs bits | atlas bit). The trait is invariant per font; this avoids
  /// re-probing `CTFontGetSymbolicTraits` every glyph run.
  private var colorTraitCache: [UInt32: Bool] = [:]
  /// Resolved (interned font ID, reference-atlas styled variant) per
  /// (source == .sidebar, bold, italic) run-shape (8 combinations), keyed
  /// like `colorTraitCache` (bit0 = sidebar, bit1 = bold, bit2 = italic).
  /// `appendGlyphRun` otherwise called `FontAtlas.postScriptName(of:)`
  /// (`CTFontCopyPostScriptName`) once per glyph run per frame just to feed
  /// `internedFontID`; both reference atlases are stable between font
  /// reconfigures, so the resolved pair only needs computing once per shape.
  /// Invalidated whenever a reference atlas can change identity: cleared in
  /// `reconfigureFonts` (replaces `referenceFontAtlas`/
  /// `sidebarReferenceFontAtlas` directly) and in `refreshCJKFontCascade`
  /// (only rebuilds `rasterAtlas`, not the reference atlases, but cleared
  /// too for safety since nothing here is hot enough to matter).
  private typealias RunFontIdentity = (
    fontID: Int, referenceVariant: (font: CTFont, boldFallback: Bool, italicFallback: Bool)
  )
  private var runFontIdentityCache: [UInt8: RunFontIdentity] = [:]
  private var lastFrameSolidsCount = 0
  public private(set) var lastFrameSlugGlyphsCount = 0
  public private(set) var lastFrameMotionGlyphsCount = 0
  public private(set) var lastFrameSpinnerFallbackSnapCount = 0
  private var frameSpinnerFallbackSnapCount = 0
  private var lastFrameRasterGlyphsCount = 0
  private var lastFrameColorGlyphsCount = 0

  // MARK: - Glyph-effect animation channel (M0 substrate)

  /// Monotonic seconds clock driving the `timeSeconds` uniform. Defaults to
  /// the shared mach_absolute_time-based `MonotonicClock`; tests and headless
  /// runs substitute a virtual clock so effect evaluation is deterministic.
  public var glyphEffectClock: () -> Double = MonotonicClock.seconds
  /// Epoch subtracted from `glyphEffectClock` so the shader-side Float stays
  /// precise over long uptimes. Captured lazily on the first `render()`.
  private var glyphEffectEpochSeconds: Double?
  /// `timeSeconds` for the frame currently being built; read by
  /// `glyphUniforms` and by effectStart conversion.
  private var frameTimeSeconds: Float = 0
  /// DEBUG-only trigger (M0 acceptance hook): when non-zero, glyph runs
  /// stamped with a fresh output timestamp are emitted with this `effectKind`
  /// so the kind≠0 shader path can be exercised before M1 wires real kind
  /// assignment. Default 0 (no effect); settable in tests or via the
  /// `LABAN_GLYPH_EFFECT_DEBUG_TRIGGER` environment variable.
  public var debugGlyphEffectKind: UInt32 = {
    guard
      let raw = ProcessInfo.processInfo.environment["LABAN_GLYPH_EFFECT_DEBUG_TRIGGER"],
      let kind = UInt32(raw)
    else { return 0 }
    return kind
  }()

  // MARK: - Glyph-effect live state (M1)

  // Effect-kind and decay constants mirrored from `GlyphEffectTimeline`
  // (LabanCore), the documented source of truth; LabanRenderer cannot import
  // LabanCore (dependency direction), so keep these in sync manually — same
  // shared-source pattern as the Metal shader constants.
  public static let glyphEffectKindNone: UInt32 = 0
  public static let glyphEffectKindInkBloom: UInt32 = 1
  public static let glyphEffectKindBellShake: UInt32 = 2
  public static let glyphEffectKindSpinnerForegroundMotion: UInt32 = 3
  private static let glyphEffectInkBloomDecaySeconds: Double = 0.280
  private static let glyphEffectBellShakeDecaySeconds: Double = 0.300

  private static func glyphEffectDecaySeconds(kind: UInt32, duration: Float? = nil) -> Double {
    switch kind {
    case glyphEffectKindInkBloom: return glyphEffectInkBloomDecaySeconds
    case glyphEffectKindBellShake: return glyphEffectBellShakeDecaySeconds
    case glyphEffectKindSpinnerForegroundMotion:
      guard let duration, duration > 0 else { return 0 }
      return Double(duration)
    default: return 0
    }
  }

  /// Whether freshly output glyph runs are emitted with a real `effectKind`
  /// (ink-bloom today). Set by the view every frame from
  /// `GlyphEffectSettings.enabled && !reduceMotion`; default off.
  public var glyphEffectsEnabled = false

  /// A glyph run carrying a live effect, tracked at the run level so bands
  /// stay in the same CG-point y-up space as `RenderDamage`.
  private struct LiveGlyphEffect {
    var band: DirtyYRange
    var effectStart: Float
    var kind: UInt32
    /// Per-transition duration in seconds. Kind 1/2 use fixed decay; kind 3
    /// stores the command metadata duration.
    var duration: Float?
  }
  /// Live effects from the most recently built frame; their bands are
  /// re-damaged at the next `render()` entry (frame pumping + settle
  /// repaint).
  private var liveGlyphEffects: [LiveGlyphEffect] = []
  /// Accumulator rebuilt by `buildInstances` each frame.
  private var frameLiveGlyphEffects: [LiveGlyphEffect] = []
  /// Live effect runs in the last built frame (0 once every effect decayed
  /// and the settle repaint landed).
  public private(set) var glyphEffectLiveCount = 0
  /// Most recent non-zero effect kind seen (0 = none yet).
  public private(set) var lastGlyphEffectKind: UInt32 = 0
  /// Seconds until the last live effect decays (renderer clock domain); the
  /// view converts this into its `glyphEffectAnimatingUntil` deadline so the
  /// display link runs at the animation budget while effects move pixels.
  public private(set) var glyphEffectAnimatingRemainingSeconds: Double = 0
  /// Frames rendered with at least one live effect — the pumping evidence
  /// counter surfaced as `glyphEffects.wakeCount` in `/debug/state`.
  public private(set) var glyphEffectFrameCount: UInt64 = 0

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
  private var previousClearColor: MTLClearColor?
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
  /// Monotonic stamp for each `publishLatestTarget` call, carried by the
  /// `slug.publish` signpost event and the `slug.present` signpost span so a
  /// trace can tell fresh presents from redundant re-presents of the same
  /// published frame. Guarded by `presentTargetLock`.
  private var publishedFrameVersion: UInt64 = 0
  /// The `publishedFrameVersion` most recently actually presented by
  /// `presentLatestTarget(into:)`. Read and written solely from the
  /// present-link callback thread (`laban.vector.present-link`, the only
  /// caller of `presentLatestTarget`), so no lock guards this field itself;
  /// the version it is compared against is still snapshotted under
  /// `presentTargetLock` (see `presentLatestTarget`). Never reset, including
  /// at `resize` (which nils `latestPresentedTarget`): `publishedFrameVersion`
  /// only ever increases for this renderer's lifetime (`&+=1` in
  /// `publishLatestTarget`, never decremented or rewound), so equality with
  /// `lastPresentedFrameVersion` can only mean "this exact publish was
  /// already presented" — a post-resize republish always carries a version
  /// one greater than anything seen before, so it is never wrongly skipped.
  private var lastPresentedFrameVersion: UInt64 = 0
  private var presentQueue: MTLCommandQueue?
  /// Serializes render frames so only one is in flight on `queue` at a time.
  /// `MetalRenderer` and `VectorGlyphRenderer` get the same contract through
  /// `MetalDrawableScheduler`; Slug uses a dedicated semaphore because its
  /// present path is driven by `VectorPresentDisplayLink` rather than by
  /// main-thread drawable acquisition.
  ///
  /// `DispatchSemaphore` is not formally `Sendable`, but this instance is safe
  /// to capture across threads: it is a `let`-bound, thread-safe reference type
  /// signaled once per `wait()` from the command-buffer completion handler on a
  /// Metal worker thread. The two captures below (`addCompletedHandler`) carry
  /// this rationale.
  private let frameInFlight = DispatchSemaphore(value: 1)
  private var targetRing: [MTLTexture] = []
  private var translucentWorkingRing: [MTLTexture] = []
  private var targetRingCursor = 0

  private var targetTexture: MTLTexture?
  private var translucentWorkingTexture: MTLTexture?
  var hasTranslucentPipelinesForTesting: Bool {
    translucentPipelines != nil && linearPremultipliedResolvePipeline != nil
  }
  var hasTranslucentWorkingTargetForTesting: Bool { translucentWorkingTexture != nil }
  private var lastCommandBuffer: MTLCommandBuffer?
  private var rasterAtlas: MetalGlyphAtlas?
  /// A prewarmed raster atlas supplied by a background cold-launch prewarm
  /// pass, held aside until the first atlas (re)build whose scale matches it,
  /// then adopted one-shot instead of building cold. Nil outside a cold launch
  /// into this renderer. See `adoptPrewarmedRasterAtlas(forFontAtlas:scale:)`.
  private var prewarmedRasterAtlas: MetalGlyphAtlas? = nil

  /// Test accessor for the active raster atlas, so prebuilt-atlas adoption
  /// tests can assert identity (`===`) against a prebuilt atlas passed into
  /// `init` or adopted later at `resize`.
  public var debugRasterAtlasForTesting: MetalGlyphAtlas? { rasterAtlas }
  private var colorGlyphAtlas: ColorGlyphAtlas?
  private var pixelWidth: Int
  private var pixelHeight: Int
  private var scale: CGFloat
  public private(set) var surfaceTransparency: RendererSurfaceTransparency
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
      downsampled: displayDownsampled,
      surfaceIsOpaque: surfaceTransparency.isOpaque)
  }
  public var effectiveSubpixelFallbackReason: String? {
    VectorSubpixelLayout.effectiveFallbackReason(
      configured: subpixelLayout,
      scale: Double(scale),
      downsampled: displayDownsampled,
      surfaceIsOpaque: surfaceTransparency.isOpaque)
  }

  public var onFrameCompleted: (() -> Void)?
  public var waitForFrameCompletion: Bool = false
  public var presentsToLayer: Bool = true

  /// Set by the host view for the next frame only: when true, a frame whose
  /// render pipeline is already busy is *dropped* rather than blocked on.
  /// Mirrors `MetalRenderer.dropNextFrameWhenBusy` and
  /// `VectorGlyphRenderer.dropNextFrameWhenBusy`.
  public var dropNextFrameWhenBusy = false

  /// Why the most recent `render(_:damage:)` returned `false`. Cleared to `nil`
  /// at the start of every `render` and left `nil` on a successful frame.
  public private(set) var lastRenderFailureReason: RenderFailureReason?

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
      vectorSubpixelFallbackReason: effectiveSubpixelFallbackReason,
      textCompositeModel: .linearLight)
  }

  public init?(
    fontAtlas: FontAtlas,
    sidebarFontAtlas: FontAtlas? = nil,
    pixelWidth: Int = 1,
    pixelHeight: Int = 1,
    scale: CGFloat = 1,
    surfaceTransparency: RendererSurfaceTransparency = RendererSurfaceTransparency(
      isOpaque: true),
    prebuiltRasterAtlas: MetalGlyphAtlas? = nil
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
      let compositeAdditiveFragment = library.makeFunction(
        name: "subpixelCompositeAdditiveFragment")
    else { return nil }

    let layer = CAMetalLayer()
    layer.device = device
    layer.pixelFormat = .bgra8Unorm_srgb
    layer.framebufferOnly = false
    layer.contentsScale = max(scale, 1)
    layer.drawableSize = CGSize(width: max(1, pixelWidth), height: max(1, pixelHeight))
    layer.isOpaque = surfaceTransparency.isOpaque
    layer.maximumDrawableCount = 3
    layer.allowsNextDrawableTimeout = true
    layer.contentsGravity = .topLeft

    let solidDescriptor = MTLRenderPipelineDescriptor()
    solidDescriptor.label = "laban.slug.solid"
    solidDescriptor.vertexFunction = solidVertex
    solidDescriptor.fragmentFunction = solidFragment
    solidDescriptor.colorAttachments[0]?.pixelFormat = layer.pixelFormat
    configureSlugAlphaBlend(solidDescriptor.colorAttachments[0])

    let replaceSolidDescriptor = MTLRenderPipelineDescriptor()
    replaceSolidDescriptor.label = "laban.slug.solid-replace"
    replaceSolidDescriptor.vertexFunction = solidVertex
    replaceSolidDescriptor.fragmentFunction = solidFragment
    replaceSolidDescriptor.colorAttachments[0]?.pixelFormat = layer.pixelFormat
    replaceSolidDescriptor.colorAttachments[0]?.isBlendingEnabled = false

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
      let replaceSolidPipeline = try? device.makeRenderPipelineState(
        descriptor: replaceSolidDescriptor),
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

    let initialTranslucentPipelines: SlugTranslucentPipelines?
    let initialResolvePipeline: MTLRenderPipelineState?
    if surfaceTransparency.isOpaque {
      initialTranslucentPipelines = nil
      initialResolvePipeline = nil
    } else {
      guard
        let content = SlugTranslucentPipelineCache.pipelines(
          device: device, library: library),
        let resolve = VectorGlyphShaderCache.linearPremultipliedResolvePipeline(
          device: device, destinationPixelFormat: layer.pixelFormat)
      else { return nil }
      initialTranslucentPipelines = content
      initialResolvePipeline = resolve
    }

    self.device = device
    self.queue = queue
    self.shaderLibrary = library
    self.solidPipeline = solidPipeline
    self.replaceSolidPipeline = replaceSolidPipeline
    self.glyphAlphaPipeline = glyphAlphaPipeline
    self.glyphCoveragePipeline = glyphCoveragePipeline
    self.glyphColorPipeline = glyphColorPipeline
    self.slugAccumulatePipeline = slugAccumulatePipeline
    self.subpixelCompositeDarkenPipeline = subpixelCompositeDarkenPipeline
    self.subpixelCompositeAdditivePipeline = subpixelCompositeAdditivePipeline
    self.rasterGlyphPipeline = rasterGlyphPipeline
    self.colorGlyphPipeline = colorGlyphPipeline
    self.translucentPipelines = initialTranslucentPipelines
    self.linearPremultipliedResolvePipeline = initialResolvePipeline
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
    self.surfaceTransparency = surfaceTransparency
    self.colorGlyphAtlas = Self.makeColorGlyphAtlas(
      device: device,
      fontAtlas: fontAtlas,
      scale: self.scale)
    self.prewarmedRasterAtlas = prebuiltRasterAtlas
    if let prebuilt = prebuiltRasterAtlas,
      prebuilt.isCompatible(
        device: device,
        cellWidth: fontAtlas.cellSize.width,
        cellHeight: fontAtlas.cellSize.height,
        scale: self.scale)
    {
      self.rasterAtlas = prebuilt
      self.prewarmedRasterAtlas = nil
    } else {
      self.rasterAtlas = Self.makeRasterGlyphAtlas(
        device: device,
        fontAtlas: fontAtlas,
        scale: self.scale)
    }

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

  /// Lazy builds the motion-pipeline variants once. Returns false if any
  /// variant fails to compile; callers should fall back to static rendering.
  @discardableResult
  private func ensureMotionPipelines() -> Bool {
    guard motionGlyphAlphaPipeline == nil else { return true }
    guard let motionVertex = shaderLibrary.makeFunction(name: "slugGlyphMotionVertex"),
      let glyphAlphaFragment = shaderLibrary.makeFunction(name: "slugGlyphAlphaFragment"),
      let slugAccumulateFragment = shaderLibrary.makeFunction(name: "slugGlyphAccumulateFragment"),
      let glyphCoverageFragment = shaderLibrary.makeFunction(name: "slugGlyphCoverageFragment"),
      let glyphColorFragment = shaderLibrary.makeFunction(name: "slugGlyphColorFragment")
    else { return false }

    let glyphAlphaDescriptor = MTLRenderPipelineDescriptor()
    glyphAlphaDescriptor.label = "laban.slug.motion-glyph-alpha"
    glyphAlphaDescriptor.vertexFunction = motionVertex
    glyphAlphaDescriptor.fragmentFunction = glyphAlphaFragment
    glyphAlphaDescriptor.colorAttachments[0]?.pixelFormat = layer.pixelFormat
    configureSlugAlphaBlend(glyphAlphaDescriptor.colorAttachments[0])

    let slugAccumulateDescriptor = MTLRenderPipelineDescriptor()
    slugAccumulateDescriptor.label = "laban.slug.motion-glyph-accumulate"
    slugAccumulateDescriptor.vertexFunction = motionVertex
    slugAccumulateDescriptor.fragmentFunction = slugAccumulateFragment
    slugAccumulateDescriptor.colorAttachments[0]?.pixelFormat = .rgba16Float
    configureAdditiveAccumBlend(slugAccumulateDescriptor.colorAttachments[0])
    slugAccumulateDescriptor.colorAttachments[1]?.pixelFormat = .rgba16Float
    configureAdditiveAccumBlend(slugAccumulateDescriptor.colorAttachments[1])

    let glyphCoverageDescriptor = MTLRenderPipelineDescriptor()
    glyphCoverageDescriptor.label = "laban.slug.motion-glyph-coverage"
    glyphCoverageDescriptor.vertexFunction = motionVertex
    glyphCoverageDescriptor.fragmentFunction = glyphCoverageFragment
    glyphCoverageDescriptor.colorAttachments[0]?.pixelFormat = layer.pixelFormat
    configureSubpixelCoverageBlend(glyphCoverageDescriptor.colorAttachments[0])

    let glyphColorDescriptor = MTLRenderPipelineDescriptor()
    glyphColorDescriptor.label = "laban.slug.motion-glyph-color"
    glyphColorDescriptor.vertexFunction = motionVertex
    glyphColorDescriptor.fragmentFunction = glyphColorFragment
    glyphColorDescriptor.colorAttachments[0]?.pixelFormat = layer.pixelFormat
    configureAdditiveRGBPreserveAlphaBlend(glyphColorDescriptor.colorAttachments[0])

    guard
      let glyphAlpha = try? device.makeRenderPipelineState(descriptor: glyphAlphaDescriptor),
      let slugAccumulate = try? device.makeRenderPipelineState(
        descriptor: slugAccumulateDescriptor),
      let glyphCoverage = try? device.makeRenderPipelineState(
        descriptor: glyphCoverageDescriptor),
      let glyphColor = try? device.makeRenderPipelineState(descriptor: glyphColorDescriptor)
    else { return false }

    motionGlyphAlphaPipeline = glyphAlpha
    motionSlugAccumulatePipeline = slugAccumulate
    motionGlyphCoveragePipeline = glyphCoverage
    motionGlyphColorPipeline = glyphColor

    if !surfaceTransparency.isOpaque {
      let translucentDescriptor = MTLRenderPipelineDescriptor()
      translucentDescriptor.label = "laban.slug.translucent-motion-glyph-alpha"
      translucentDescriptor.vertexFunction = motionVertex
      translucentDescriptor.fragmentFunction = glyphAlphaFragment
      translucentDescriptor.colorAttachments[0]?.pixelFormat = .rgba16Float
      configureSlugAlphaBlend(translucentDescriptor.colorAttachments[0])
      motionTranslucentGlyphAlphaPipeline = try? device.makeRenderPipelineState(
        descriptor: translucentDescriptor)
    }

    return true
  }

  /// Public hook to compile motion pipelines before the first spinner frame
  /// lands, so effective enablement flipping false-to-true does not hitch.
  @discardableResult
  public func prewarmMotionPipelines() -> Bool {
    ensureMotionPipelines()
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

  /// Rebuild the present link after a display reconfiguration; see
  /// `VectorPresentDisplayLink.rebuild()`. No-op on the legacy path.
  public func rebuildPresentLink() {
    if #available(macOS 14.0, *) {
      presentDisplayLink?.rebuild()
    }
  }

  public func setSurfaceTransparency(_ transparency: RendererSurfaceTransparency) {
    guard transparency != surfaceTransparency else { return }
    // Retire the publish handler before removing the current target; otherwise
    // an old-policy frame could be republished after this method returns.
    lastCommandBuffer?.waitUntilCompleted()
    if !transparency.isOpaque {
      _ = ensureTranslucentPipelines()
    }
    let priorEffectiveSubpixelLayout = effectiveSubpixelLayout
    surfaceTransparency = transparency
    if effectiveSubpixelLayout != priorEffectiveSubpixelLayout {
      // Subpixel accumulation is destination-dependent. Drop it immediately so
      // returning opaque restores the configured layout from fresh coverage.
      subpixelCoverageAccum = nil
      subpixelColorAccum = nil
    }
    layer.isOpaque = transparency.isOpaque
    targetTexture = nil
    translucentWorkingTexture = nil
    targetRing.removeAll(keepingCapacity: true)
    translucentWorkingRing.removeAll(keepingCapacity: true)
    targetRingCursor = 0
    subpixelCoverageAccum = nil
    subpixelColorAccum = nil
    presentTargetLock.lock()
    latestPresentedTarget = nil
    presentTargetLock.unlock()
    // A rebuilt target ring is initialized through the existing per-slot
    // force-full path on the next render.
    slotDamageAccumulators.removeAll(keepingCapacity: true)
    slotNeedsForceFull.removeAll(keepingCapacity: true)
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

  /// Debug readback for headless pixel probes: raw premultiplied BGRA bytes
  /// of the current target texture (row 0 = top scanline), or nil before the
  /// first render. Same pixels `pngData` encodes, without the PNG round-trip.
  public func readbackBGRA() -> (width: Int, height: Int, bytes: [UInt8])? {
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
    return (targetTexture.width, targetTexture.height, bytes)
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
    runFontIdentityCache.removeAll()
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

  public func refreshCJKFontCascade() {
    // Only rebuilds `rasterAtlas`, not `referenceFontAtlas`/
    // `sidebarReferenceFontAtlas` (those change in `reconfigureFonts`), so
    // strictly this cache would still be valid here. Invalidated anyway:
    // nothing in this path is hot enough for the extra dictionary rebuild to
    // matter, and it keeps the cache's invariant ("cleared whenever atlas
    // state changes") simple to reason about from either call site alone.
    rasterAtlas = Self.makeRasterGlyphAtlas(
      device: device,
      fontAtlas: fontAtlas,
      scale: scale)
    runFontIdentityCache.removeAll()
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
    translucentWorkingTexture = nil
    targetRing.removeAll(keepingCapacity: true)
    translucentWorkingRing.removeAll(keepingCapacity: true)
    targetRingCursor = 0
    subpixelCoverageAccum = nil
    subpixelColorAccum = nil
    presentTargetLock.lock()
    latestPresentedTarget = nil
    presentTargetLock.unlock()
    // Deliberately NOT resetting `lastPresentedFrameVersion` here: it is a
    // monotonic-only field (see its declaration) and a post-resize republish
    // always carries a fresh, never-before-seen version, so it can never be
    // wrongly skipped even though `latestPresentedTarget` just went nil.
    if scaleChanged {
      colorGlyphAtlas = Self.makeColorGlyphAtlas(
        device: device,
        fontAtlas: fontAtlas,
        scale: newScale)
      rasterAtlas =
        adoptPrewarmedRasterAtlas(forFontAtlas: fontAtlas, scale: newScale)
        ?? Self.makeRasterGlyphAtlas(
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
    currentCursorRects: [CGRect],
    clearColor: MTLClearColor
  ) -> EffectiveDamageOutcome {
    let (slot, ringRebuild) = peekNextRingSlot()
    ensureSlotDamageStateSized(rebuild: ringRebuild)

    let forcesEveryone =
      ringRebuild || configChangedSincePreviousFrame(clearColor: clearColor) || damage == .full
    if forcesEveryone {
      for i in slotNeedsForceFull.indices { slotNeedsForceFull[i] = true }
    }

    // Accumulate this frame's damage into EVERY slot before the force-full
    // early return below. A partial frame that lands on a still-flagged slot
    // renders full and looks correct on screen, but the other slots still
    // need this frame's bands when their turn comes: returning early without
    // accumulating made rows silently revert to a slot's stale content one
    // ring revolution later (the git-pull / fullscreen-TUI flicker, where
    // .full frames from scrolling constantly re-flag all slots and the
    // partial progress-line updates in between were dropped).
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

    if slotNeedsForceFull[slot] {
      slotDamageAccumulators[slot] = DirtyYRangeSet([])
      slotNeedsForceFull[slot] = false
      return .render(damage: .full, slot: slot, ringRebuild: ringRebuild)
    }

    let combined = slotDamageAccumulators[slot]
    slotDamageAccumulators[slot] = DirtyYRangeSet([])
    guard !combined.isEmpty else { return .skip }
    return .render(damage: .partial(yRanges: combined.ranges), slot: slot, ringRebuild: ringRebuild)
  }

  @discardableResult
  public func render(_ commands: [FrameCommand], damage: RenderDamage) -> Bool {
    let signposter = RenderEncodeSignpost.signposter
    // Sample the glyph-effect clock once per frame so every instance and the
    // `timeSeconds` uniform share one time base. The epoch keeps the Float
    // handed to the shader small (precision) across long uptimes.
    let effectNowSeconds = glyphEffectClock()
    if glyphEffectEpochSeconds == nil { glyphEffectEpochSeconds = effectNowSeconds }
    frameTimeSeconds = Float(effectNowSeconds - (glyphEffectEpochSeconds ?? effectNowSeconds))
    let incomingShape: String
    if case .partial(let yRanges) = damage {
      incomingShape = "bands:\(yRanges.count)"
    } else {
      incomingShape = "full"
    }
    let renderSpan = signposter.beginInterval(
      "slug.render", "in=\(incomingShape, privacy: .public)")
    // Effective damage shape and instance counts, filled in as the frame
    // progresses so the interval's end message describes what was actually
    // encoded ("skip" when the empty-effective-damage fast path fired).
    var spanShape = "skip"
    var spanSolids = 0
    var spanGlyphs = 0
    var spanRaster = 0
    var spanColor = 0
    defer {
      signposter.endInterval(
        "slug.render",
        renderSpan,
        "eff=\(spanShape, privacy: .public) solids=\(spanSolids, privacy: .public) glyphs=\(spanGlyphs, privacy: .public) raster=\(spanRaster, privacy: .public) color=\(spanColor, privacy: .public)"
      )
    }
    let clearColor = Self.linearizedClearColor(commands)
    let currentCursorRects = cursorRects(in: commands)
    // M1 frame pumping: while glyph effects animate, their bands must be
    // redrawn every frame (and once more after decay for the settle repaint),
    // defeating the empty-effective-damage skip below. The live set is
    // recomputed after buildInstances; this unions the previous frame's set.
    let damage = unionLiveGlyphEffectBands(into: damage)
    let outcome = resolveEffectiveDamage(
      damage: damage,
      currentCursorRects: currentCursorRects,
      clearColor: clearColor)

    guard case .render(let effectiveDamage, let slot, let ringRebuild) = outcome else {
      // Empty effective damage: nothing changed since this slot was last
      // fully current (including cursor position). Skip encoding entirely
      // and do not rotate the ring; the last completed handler publication
      // remains visible. Honor the completion contract only.
      signposter.emitEvent("slug.skipFrame")
      previousCursorRects = currentCursorRects
      snapshotConfigForNextFrame(clearColor: clearColor)
      onFrameCompleted?()
      return true
    }
    if case .partial(let effectiveRanges) = effectiveDamage {
      spanShape = "bands:\(effectiveRanges.count)"
    } else {
      spanShape = "full"
    }
    previousCursorRects = currentCursorRects
    snapshotConfigForNextFrame(clearColor: clearColor)

    // resolveEffectiveDamage already consumed this slot's accumulator and
    // force-full flag. If the frame fails below (backpressure, allocation),
    // put that damage back so the retry cannot under-redraw the slot: most
    // callers retry with .full anyway, but the backpressure park path does
    // not guarantee it.
    var frameCommitted = false
    defer {
      if !frameCommitted {
        restoreConsumedDamage(effectiveDamage, slot: slot)
      }
    }

    lastRenderFailureReason = nil
    let dropIfBusy = dropNextFrameWhenBusy
    dropNextFrameWhenBusy = false
    let needsFullFrame = !dropIfBusy || damage == .full
    let timeout: DispatchTime =
      (needsFullFrame || !dropIfBusy) ? .now() + .milliseconds(16) : .now()
    guard frameInFlight.wait(timeout: timeout) == .success else {
      lastRenderFailureReason = .previousFrameInFlight
      return false
    }
    var releaseFrameOnExit = true
    defer {
      if releaseFrameOnExit {
        frameInFlight.signal()
      }
    }

    guard let frameTargets = commitRingSlot(slot, rebuild: ringRebuild),
      let commandBuffer = queue.makeCommandBuffer()
    else { return false }
    let target = frameTargets.final
    let contentTarget = frameTargets.content

    let scissorPlan = self.scissorPlan(for: effectiveDamage)

    // nil (i.e. `.full` effective damage) disables buildInstances' filtering
    // entirely, keeping that path byte-identical to pre-M5 behavior.
    let damageBands: DirtyYRangeSet?
    if case .partial(let effectiveRanges) = effectiveDamage {
      damageBands = DirtyYRangeSet(effectiveRanges)
    } else {
      damageBands = nil
    }

    var solids: [SlugSolidInstance] = []
    var replaceSolids: [SlugSolidInstance] = []
    var slugGlyphs: [SlugGlyphGPUInstance] = []
    var motionGlyphs: [SlugGlyphMotionGPUInstance] = []
    var rasterGlyphs: [SlugTextureInstance] = []
    var colorGlyphs: [SlugTextureInstance] = []
    solids.reserveCapacity(lastFrameSolidsCount)
    slugGlyphs.reserveCapacity(lastFrameSlugGlyphsCount)
    motionGlyphs.reserveCapacity(lastFrameMotionGlyphsCount)
    rasterGlyphs.reserveCapacity(lastFrameRasterGlyphsCount)
    colorGlyphs.reserveCapacity(lastFrameColorGlyphsCount)
    frameGlyphFontSizes.removeAll(keepingCapacity: true)
    frameQuadHeights.removeAll(keepingCapacity: true)
    frameSpinnerFallbackSnapCount = 0
    buildInstances(
      commands: commands,
      solids: &solids,
      replaceSolids: &replaceSolids,
      glyphs: &slugGlyphs,
      motionGlyphs: &motionGlyphs,
      rasterGlyphs: &rasterGlyphs,
      colorGlyphs: &colorGlyphs,
      damageBands: damageBands)
    updateLiveGlyphEffectState()
    lastFrameSolidsCount = solids.count + replaceSolids.count
    lastFrameSlugGlyphsCount = slugGlyphs.count
    lastFrameMotionGlyphsCount = motionGlyphs.count
    lastFrameSpinnerFallbackSnapCount = frameSpinnerFallbackSnapCount
    lastFrameRasterGlyphsCount = rasterGlyphs.count
    lastFrameColorGlyphsCount = colorGlyphs.count
    spanSolids = solids.count + replaceSolids.count
    spanGlyphs = slugGlyphs.count + motionGlyphs.count
    spanRaster = rasterGlyphs.count
    spanColor = colorGlyphs.count
    lastFrameGlyphFontSizes = frameGlyphFontSizes.sorted()
    lastFrameQuadHeights = frameQuadHeights.sorted()
    lastRasterFallbackGlyphs = rasterGlyphs.count + colorGlyphs.count
    guard
      ensureGeometryBuffersIfNeeded(
        glyphsNeeded: !slugGlyphs.isEmpty || !motionGlyphs.isEmpty)
    else { return false }
    if !motionGlyphs.isEmpty, !ensureMotionPipelines() {
      lastRenderFailureReason = .motionPipelineCompilation
      return false
    }

    var retainedBuffers: [MTLBuffer] = []

    let isOpaque = surfaceTransparency.isOpaque
    let activeSolidPipeline: MTLRenderPipelineState
    let activeReplaceSolidPipeline: MTLRenderPipelineState
    let activeGlyphAlphaPipeline: MTLRenderPipelineState
    let activeMotionGlyphAlphaPipeline: MTLRenderPipelineState?
    let activeMotionGlyphCoveragePipeline: MTLRenderPipelineState?
    let activeMotionGlyphColorPipeline: MTLRenderPipelineState?
    let activeRasterGlyphPipeline: MTLRenderPipelineState
    let activeColorGlyphPipeline: MTLRenderPipelineState
    if isOpaque {
      activeSolidPipeline = solidPipeline
      activeReplaceSolidPipeline = replaceSolidPipeline
      activeGlyphAlphaPipeline = glyphAlphaPipeline
      activeMotionGlyphAlphaPipeline = motionGlyphAlphaPipeline
      activeMotionGlyphCoveragePipeline = motionGlyphCoveragePipeline
      activeMotionGlyphColorPipeline = motionGlyphColorPipeline
      activeRasterGlyphPipeline = rasterGlyphPipeline
      activeColorGlyphPipeline = colorGlyphPipeline
    } else {
      guard let pipelines = translucentPipelines else { return false }
      activeSolidPipeline = pipelines.solid
      activeReplaceSolidPipeline = pipelines.replaceSolid
      activeGlyphAlphaPipeline = pipelines.glyphAlpha
      activeMotionGlyphAlphaPipeline = motionTranslucentGlyphAlphaPipeline
      activeMotionGlyphCoveragePipeline = nil
      activeMotionGlyphColorPipeline = nil
      activeRasterGlyphPipeline = pipelines.rasterGlyph
      activeColorGlyphPipeline = pipelines.colorGlyph
    }
    let useSubpixel = isOpaque && effectiveSubpixelLayout != .grayscale
    let slugInstanceBuffer = makeBuffer(slugGlyphs)
    if let slugInstanceBuffer { retainedBuffers.append(slugInstanceBuffer) }
    let motionInstanceBuffer = makeBuffer(motionGlyphs)
    if let motionInstanceBuffer { retainedBuffers.append(motionInstanceBuffer) }
    let slugCurveBuffer = curveBuffer
    let slugGlyphBuffer = glyphBuffer
    let slugBandBuffer = bandBuffer
    let slugBandIndexBuffer = bandIndexBuffer
    let slugBuffersReady =
      (slugInstanceBuffer != nil || motionInstanceBuffer != nil)
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
        if let motionInstanceBuffer, let motionSlugAccumulatePipeline {
          accumEncoder.setRenderPipelineState(motionSlugAccumulatePipeline)
          accumEncoder.setVertexBuffer(motionInstanceBuffer, offset: 0, index: 0)
          repeatingBands(scissorPlan, on: accumEncoder) {
            accumEncoder.drawPrimitives(
              type: .triangle,
              vertexStart: 0,
              vertexCount: 6,
              instanceCount: motionGlyphs.count)
          }
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
    descriptor.colorAttachments[0].texture = contentTarget
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

    // A partial update starts by overwriting every damaged band with
    // transparent black. Use an unzoomed full-target quad plus the existing
    // exact-band scissors so clean gaps between bands remain byte-identical.
    if case .bands = scissorPlan {
      let erase = SlugSolidInstance(
        origin: .zero,
        size: SIMD2<Float>(Float(pixelWidth), Float(pixelHeight)),
        color: .zero)
      if let eraseBuffer = makeBuffer([erase]) {
        retainedBuffers.append(eraseBuffer)
        var eraseUniforms = SlugVectorUniforms(
          surfaceSizePixels: SIMD2<Float>(Float(pixelWidth), Float(pixelHeight)),
          scale: Float(scale))
        encoder.setRenderPipelineState(activeReplaceSolidPipeline)
        encoder.setVertexBuffer(eraseBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(
          &eraseUniforms,
          length: MemoryLayout<SlugVectorUniforms>.stride,
          index: 1)
        repeatingBands(scissorPlan, on: encoder) {
          encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6,
            instanceCount: 1)
        }
      }
    }

    if !replaceSolids.isEmpty, let replaceSolidBuffer = makeBuffer(replaceSolids) {
      retainedBuffers.append(replaceSolidBuffer)
      encoder.setRenderPipelineState(activeReplaceSolidPipeline)
      encoder.setVertexBuffer(replaceSolidBuffer, offset: 0, index: 0)
      encoder.setVertexBytes(
        &vectorUniforms,
        length: MemoryLayout<SlugVectorUniforms>.stride,
        index: 1)
      repeatingBands(scissorPlan, on: encoder) {
        encoder.drawPrimitives(
          type: .triangle,
          vertexStart: 0,
          vertexCount: 6,
          instanceCount: replaceSolids.count)
      }
    }

    if !solids.isEmpty, let solidBuffer = makeBuffer(solids) {
      retainedBuffers.append(solidBuffer)
      encoder.setRenderPipelineState(activeSolidPipeline)
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
        encoder.setRenderPipelineState(activeGlyphAlphaPipeline)
        repeatingBands(scissorPlan, on: encoder) {
          encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6,
            instanceCount: slugGlyphs.count)
        }
        if let motionInstanceBuffer, let activeMotionGlyphAlphaPipeline {
          encoder.setRenderPipelineState(activeMotionGlyphAlphaPipeline)
          encoder.setVertexBuffer(motionInstanceBuffer, offset: 0, index: 0)
          repeatingBands(scissorPlan, on: encoder) {
            encoder.drawPrimitives(
              type: .triangle,
              vertexStart: 0,
              vertexCount: 6,
              instanceCount: motionGlyphs.count)
          }
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
        if let motionInstanceBuffer,
          let activeMotionGlyphCoveragePipeline,
          let activeMotionGlyphColorPipeline
        {
          encoder.setVertexBuffer(motionInstanceBuffer, offset: 0, index: 0)
          encoder.setRenderPipelineState(activeMotionGlyphCoveragePipeline)
          repeatingBands(scissorPlan, on: encoder) {
            encoder.drawPrimitives(
              type: .triangle,
              vertexStart: 0,
              vertexCount: 6,
              instanceCount: motionGlyphs.count)
          }
          encoder.setRenderPipelineState(activeMotionGlyphColorPipeline)
          repeatingBands(scissorPlan, on: encoder) {
            encoder.drawPrimitives(
              type: .triangle,
              vertexStart: 0,
              vertexCount: 6,
              instanceCount: motionGlyphs.count)
          }
        }
      }
    }

    if !rasterGlyphs.isEmpty,
      let rasterAtlas,
      let rasterBuffer = makeBuffer(rasterGlyphs)
    {
      retainedBuffers.append(rasterBuffer)
      encoder.setRenderPipelineState(activeRasterGlyphPipeline)
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
      encoder.setRenderPipelineState(activeColorGlyphPipeline)
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

    if !surfaceTransparency.isOpaque {
      guard
        encodeLinearPremultipliedResolve(
          from: contentTarget, to: target, commandBuffer: commandBuffer)
      else { return false }
    }

    let completion = onFrameCompleted
    if #available(macOS 14.0, *), presentDisplayLink != nil {
      // `frameInFlight` is non-Sendable but thread-safe; see its declaration.
      commandBuffer.addCompletedHandler { [weak self, frameInFlight] _ in
        _ = retainedBuffers
        if self?.presentsToLayer == true {
          self?.publishLatestTarget(target)
        }
        completion?()
        frameInFlight.signal()
      }
      commandBuffer.commit()
      lastCommandBuffer = commandBuffer
      if waitForFrameCompletion {
        commandBuffer.waitUntilCompleted()
      }
      frameCommitted = true
      releaseFrameOnExit = false
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

    // `frameInFlight` is non-Sendable but thread-safe; see its declaration.
    commandBuffer.addCompletedHandler { [frameInFlight] _ in
      _ = retainedBuffers
      completion?()
      frameInFlight.signal()
    }
    commandBuffer.commit()
    lastCommandBuffer = commandBuffer
    if waitForFrameCompletion {
      commandBuffer.waitUntilCompleted()
    }
    frameCommitted = true
    releaseFrameOnExit = false
    return true
  }

  /// Undo `resolveEffectiveDamage`'s consumption of `slot`'s pending damage
  /// after a failed (never-committed) render. A consumed `.full` becomes the
  /// slot's force-full flag again; consumed partial bands rejoin the slot's
  /// accumulator. Without this, a failure whose retry is not guaranteed to be
  /// `.full` (the GPU-backpressure park path) would under-redraw the slot.
  private func restoreConsumedDamage(_ damage: RenderDamage, slot: Int) {
    guard slotNeedsForceFull.indices.contains(slot) else { return }
    switch damage {
    case .full:
      slotNeedsForceFull[slot] = true
    case .partial(let yRanges):
      slotDamageAccumulators[slot] =
        slotDamageAccumulators[slot].union(DirtyYRangeSet(yRanges))
    }
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
      glyphIndex: UInt32(entry.glyphIndex),
      effectKind: 0,
      effectStart: 0)
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

  /// Whether a command's y-extent (`minY..<maxY`, the same y-up CG-point
  /// space `DirtyYRange` itself uses, not the flipped device-pixel space
  /// `slugScissorRect` converts to) intersects any damage band for this
  /// frame. `nil` bands means `.full` damage: every command is included,
  /// unfiltered, so `.full` frames stay byte-identical to pre-M5 behavior.
  /// Scissors already clip anything over-included to its band, so this only
  /// needs to avoid under-including (dropping pixels); ties go to inclusion.
  private func intersectsDamage(minY: CGFloat, maxY: CGFloat, bands: DirtyYRangeSet?) -> Bool {
    guard let bands else { return true }
    return bands.overlaps(y: minY, height: maxY - minY)
  }

  /// Builds the GPU instance lists for this frame, optionally skipping
  /// commands that fall entirely outside `damageBands` (M5: damage-aware
  /// instance building, see execplans/active/
  /// slug-hot-path-negative-cache-and-present-skip.md). `damageBands == nil`
  /// (i.e. `.full` effective damage) disables filtering entirely so the
  /// common full-redraw path is untouched.
  ///
  /// Solids (`rect`/`cursor`/`selection`/`findMatch`/`findSelected`) filter
  /// on their exact rect y-extent: no expansion needed since these draw
  /// exactly the pixels their rect covers.
  ///
  /// Glyph runs filter at the command level, before `appendGlyphRun` is
  /// called, because underline/strikethrough decorations are emitted by
  /// `appendGlyphRun` as part of the run and must be dropped together with
  /// it, not kept alive by a per-instance filter. The run's nominal extent
  /// is `origin.y ..< origin.y + cellSize.height`, but glyph quads can
  /// overhang that cell box (ascent/descent, dilation padding for bold
  /// stroke synthesis), so the extent is expanded by one full cell height on
  /// both sides as a safety margin. Scissors make any resulting
  /// over-inclusion harmless; only under-inclusion could drop pixels.
  private func buildInstances(
    commands: [FrameCommand],
    solids: inout [SlugSolidInstance],
    replaceSolids: inout [SlugSolidInstance],
    glyphs: inout [SlugGlyphGPUInstance],
    motionGlyphs: inout [SlugGlyphMotionGPUInstance],
    rasterGlyphs: inout [SlugTextureInstance],
    colorGlyphs: inout [SlugTextureInstance],
    damageBands: DirtyYRangeSet?
  ) {
    let preeditMaskRects = commands.compactMap { command -> CGRect? in
      if case .rect(let rect, _, .preedit, _) = command { return rect }
      return nil
    }
    frameLiveGlyphEffects.removeAll(keepingCapacity: true)
    for command in commands {
      switch command {
      case .rect(let rect, let color, _, let compositing):
        guard intersectsDamage(minY: rect.minY, maxY: rect.maxY, bands: damageBands) else {
          continue
        }
        if !surfaceTransparency.isOpaque
          && replacesDestination(compositing, color: color)
        {
          replaceSolids.append(replaceSolid(rect: rect, color: color))
        } else {
          solids.append(solid(rect: rect, color: color))
        }

      case .cursor(let rect, let color),
        .selection(let rect, let color),
        .findMatch(let rect, let color),
        .findSelected(let rect, let color):
        guard intersectsDamage(minY: rect.minY, maxY: rect.maxY, bands: damageBands) else {
          continue
        }
        solids.append(solid(rect: rect, color: color))

      case .glyphRun(
        let origin, let text, let foreground, let background, let attributes, let source,
        let underlineStyle, let underlineColor, _, _, let outputTimestampSeconds,
        let foregroundTransition
      ):
        let activeAtlas = source == .sidebar ? sidebarFontAtlas : fontAtlas
        let cellHeight = activeAtlas.cellSize.height
        guard
          intersectsDamage(
            minY: origin.y - cellHeight, maxY: origin.y + 2 * cellHeight, bands: damageBands)
        else { continue }
        let effectKind = resolvedGlyphEffectKind(
          outputTimestampSeconds: outputTimestampSeconds,
          foregroundTransition: foregroundTransition)
        let (effectStart, effectDuration) = effectStartAndDuration(
          outputTimestampSeconds: outputTimestampSeconds,
          foregroundTransition: foregroundTransition)
        if effectKind != Self.glyphEffectKindNone {
          // Track at the run level, in the same CG-point y-up space
          // RenderDamage uses, so render() can re-damage these bands while
          // the effect animates.
          frameLiveGlyphEffects.append(
            LiveGlyphEffect(
              band: DirtyYRange(y: origin.y - cellHeight, height: 3 * cellHeight),
              effectStart: effectStart,
              kind: effectKind,
              duration: effectDuration))
        }
        appendGlyphRun(
          text,
          origin: origin,
          foreground: foreground,
          background: background,
          attributes: attributes,
          underlineStyle: underlineStyle,
          underlineColor: underlineColor,
          source: source,
          effectKind: effectKind,
          effectStart: effectStart,
          effectDuration: effectDuration,
          foregroundTransition: foregroundTransition,
          preeditMaskRects: preeditMaskRects,
          solids: &solids,
          glyphs: &glyphs,
          motionGlyphs: &motionGlyphs,
          rasterGlyphs: &rasterGlyphs,
          colorGlyphs: &colorGlyphs)

      case .clip, .texturedQuad:
        break
      }
    }
  }

  /// Effect kind for a glyph run: kind 0 unless the run carries spinner
  /// motion metadata (which wins over ink bloom) or a fresh output timestamp.
  /// Kind assignment for stamped runs: the debug trigger wins when set,
  /// otherwise ink-bloom while `glyphEffectsEnabled` is on (the view already
  /// applied the reduceMotion gate).
  private func resolvedGlyphEffectKind(
    outputTimestampSeconds: Double?,
    foregroundTransition: GlyphForegroundTransition?
  ) -> UInt32 {
    if foregroundTransition != nil {
      return Self.glyphEffectKindSpinnerForegroundMotion
    }
    guard outputTimestampSeconds != nil else { return Self.glyphEffectKindNone }
    if debugGlyphEffectKind != 0 { return debugGlyphEffectKind }
    return glyphEffectsEnabled ? Self.glyphEffectKindInkBloom : Self.glyphEffectKindNone
  }

  /// Converts a stamp or transition start (controller clock domain) into the
  /// renderer-relative Float the shader compares against `timeSeconds`. Returns
  /// the start time and, for spinner motion, the metadata duration.
  private func effectStartAndDuration(
    outputTimestampSeconds: Double?,
    foregroundTransition: GlyphForegroundTransition?
  ) -> (Float, Float?) {
    guard let epoch = glyphEffectEpochSeconds else { return (0, nil) }
    if let transition = foregroundTransition {
      let start = Float(transition.startTimestampSeconds - epoch)
      let duration = Float(transition.durationSeconds)
      return (start, duration)
    }
    guard let outputTimestampSeconds else { return (0, nil) }
    return (Float(outputTimestampSeconds - epoch), nil)
  }

  /// Unions the previous frame's live-effect bands into incoming damage so
  /// animating (and just-decayed, for the settle repaint) bands are always
  /// redrawn. With no live effects this is identity.
  private func unionLiveGlyphEffectBands(into damage: RenderDamage) -> RenderDamage {
    guard !liveGlyphEffects.isEmpty else { return damage }
    switch damage {
    case .full:
      return .full
    case .partial(let ranges):
      return .partial(yRanges: ranges + liveGlyphEffects.map(\.band))
    }
  }

  /// Recomputes the public live-effect state after a frame's instances were
  /// built. Called once per `render()` that reached `buildInstances`. Runs
  /// whose age already exceeds their kind's decay are dropped: the shader
  /// clamps them to the settled state, so only the previous frame's band
  /// union (the settle repaint) still needs them.
  private func updateLiveGlyphEffectState() {
    liveGlyphEffects = frameLiveGlyphEffects.filter { effect in
      Double(effect.effectStart)
        + Self.glyphEffectDecaySeconds(kind: effect.kind, duration: effect.duration)
        > Double(frameTimeSeconds)
    }
    glyphEffectLiveCount = liveGlyphEffects.count
    var remaining = 0.0
    for effect in liveGlyphEffects {
      lastGlyphEffectKind = effect.kind
      let decay = Self.glyphEffectDecaySeconds(kind: effect.kind, duration: effect.duration)
      remaining = max(
        remaining, Double(effect.effectStart) + decay - Double(frameTimeSeconds))
    }
    glyphEffectAnimatingRemainingSeconds = max(0, remaining)
    if !liveGlyphEffects.isEmpty {
      glyphEffectFrameCount += 1
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
    effectKind: UInt32,
    effectStart: Float,
    effectDuration: Float? = nil,
    foregroundTransition: GlyphForegroundTransition? = nil,
    preeditMaskRects: [CGRect],
    solids: inout [SlugSolidInstance],
    glyphs: inout [SlugGlyphGPUInstance],
    motionGlyphs: inout [SlugGlyphMotionGPUInstance],
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
    let (fontID, referenceVariant) = runFontIdentity(
      sidebar: source == .sidebar, bold: bold, italic: italic, referenceAtlas: referenceAtlas)
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
      let cellRect = CGRect(
        x: cellOriginX, y: origin.y,
        width: cellAdvance, height: activeAtlas.cellSize.height)
      if source != .sidebar, source != .preedit,
        preeditMaskRects.contains(where: { $0.intersects(cellRect) })
      {
        continue
      }
      if runWantsColor,
        ColorGlyphSupport.clusterMayBeColor(cluster),
        let colorFallback = colorGlyphInstance(
          cluster: cluster,
          font: activeVariant.font,
          boldFallback: activeVariant.boldFallback,
          italicFallback: activeVariant.italicFallback,
          position: CGPoint(x: cellOriginX, y: origin.y))
      {
        if foregroundTransition != nil {
          frameSpinnerFallbackSnapCount += 1
        }
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
        if foregroundTransition != nil {
          frameSpinnerFallbackSnapCount += 1
        }
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
          if foregroundTransition != nil {
            frameSpinnerFallbackSnapCount += 1
          }
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
      if let transition = foregroundTransition {
        motionGlyphs.append(
          SlugGlyphMotionGPUInstance(
            originPx: instanceOrigin,
            sizePx: instanceSize,
            localMin: localMin,
            localMax: localMax,
            color: foregroundColor,
            glyphIndex: UInt32(entry.glyphIndex),
            dilation: perSideDilatePx,
            effectKind: effectKind,
            effectStart: effectStart,
            duration: effectDuration ?? 0,
            startColor: transition.startLinearRGBA))
      } else {
        glyphs.append(
          SlugGlyphGPUInstance(
            originPx: instanceOrigin,
            sizePx: instanceSize,
            localMin: localMin,
            localMax: localMax,
            color: foregroundColor,
            glyphIndex: UInt32(entry.glyphIndex),
            dilation: perSideDilatePx,
            effectKind: effectKind,
            effectStart: effectStart))
      }
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
    // Mirrors TextDecorationLayout.make's own guard (below): bail before
    // touching TerminalDisplayWidth.cells(of:) or cellSize for the common
    // undecorated run, instead of paying that work only for `make` to
    // return nil right after.
    guard
      attributes.contains(.underline) || attributes.contains(.strikethrough)
        || attributes.contains(.overline) || underlineStyle != .none
    else { return }
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

  /// Resolved (interned font ID, reference-atlas styled variant) for a run
  /// shape, cached in `runFontIdentityCache` so `appendGlyphRun` no longer
  /// calls `FontAtlas.postScriptName(of:)` (`CTFontCopyPostScriptName`) on
  /// every glyph run every frame. There are only 8 possible run shapes
  /// (sidebar x bold x italic); each is resolved once and reused until the
  /// cache is invalidated.
  private func runFontIdentity(
    sidebar: Bool, bold: Bool, italic: Bool, referenceAtlas: FontAtlas
  ) -> (fontID: Int, referenceVariant: (font: CTFont, boldFallback: Bool, italicFallback: Bool)) {
    var key: UInt8 = 0
    if sidebar { key |= 0x1 }
    if bold { key |= 0x2 }
    if italic { key |= 0x4 }
    if let cached = runFontIdentityCache[key] { return cached }
    let referenceVariant = referenceAtlas.styledFontVariant(bold: bold, italic: italic)
    let referencePostScriptName = FontAtlas.postScriptName(of: referenceVariant.font)
    let fontID = internedFontID(postScriptName: referencePostScriptName, bold: bold, italic: italic)
    let resolved = (fontID: fontID, referenceVariant: referenceVariant)
    runFontIdentityCache[key] = resolved
    return resolved
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
    if failedResolveKeys.contains(resolveKey) { return nil }
    // Cold path: CTFont glyph resolution and, for a first-ever glyph, curve
    // outline extraction plus band building. The message deliberately carries
    // no cluster text (terminal content); duration and count are the signal.
    let signposter = RenderEncodeSignpost.signposter
    let buildSpan = signposter.beginInterval("slug.glyphBuild")
    defer { signposter.endInterval("slug.glyphBuild", buildSpan) }
    guard
      let resolved = resolveGlyph(
        for: cluster,
        referenceAtlas: referenceAtlas,
        referenceVariant: referenceVariant,
        attributes: attributes)
    else {
      failedResolveKeys.insert(resolveKey)
      return nil
    }
    let key = SlugGlyphGeometryKey(
      postScriptName: FontAtlas.postScriptName(of: resolved.font),
      glyph: resolved.glyph)
    if let cached = entriesByKey[key] {
      entriesByResolveKey[resolveKey] = cached
      return cached
    }
    guard let outline = curveStore.outline(for: resolved.glyph, font: resolved.font) else {
      failedResolveKeys.insert(resolveKey)
      return nil
    }
    guard !outline.curves.isEmpty else {
      failedResolveKeys.insert(resolveKey)
      return nil
    }

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
    let signposter = RenderEncodeSignpost.signposter
    let curveCount = curves.count
    let glyphCount = glyphs.count
    let uploadSpan = signposter.beginInterval(
      "slug.geometryUpload",
      "curves=\(curveCount, privacy: .public) glyphs=\(glyphCount, privacy: .public)")
    defer { signposter.endInterval("slug.geometryUpload", uploadSpan) }
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

  private func replaceSolid(rect: CGRect, color: UInt32) -> SlugSolidInstance {
    SlugSolidInstance(
      origin: SIMD2<Float>(Float(rect.minX * scale), Float(rect.minY * scale)),
      size: SIMD2<Float>(Float(rect.width * scale), Float(rect.height * scale)),
      color: slugColor(color))
  }

  @inline(__always)
  private func replacesDestination(
    _ compositing: FrameCompositingMode,
    color: UInt32
  ) -> Bool {
    // Source-over with alpha 1 is byte-equivalent to replace. Avoid adding a
    // second solid batch to the default opaque path.
    compositing == .replace && UInt8(color & 0xFF) != 255
  }

  private func slugColor(_ rgba: UInt32) -> SIMD4<Float> {
    SRGBRenderTargetColor.linearizedStraightRGBA(rgba)
  }

  private static func linearizedClearColor(_ commands: [FrameCommand]) -> MTLClearColor {
    SRGBRenderTargetColor.linearPremultipliedClearColor(commands)
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

  /// If a prewarm pass left a compatible raster atlas held aside for `scale`,
  /// adopt it (one-shot) and clear the held reference; otherwise return nil so
  /// the caller builds a fresh atlas. Used at `resize`'s scale-changed rebuild
  /// so a cold-launch-prewarmed atlas is adopted at the first build whose scale
  /// matches it instead of being rasterized cold. `init` does its own inline
  /// adoption for the case where the prewarm scale already matches `init`'s
  /// scale.
  private func adoptPrewarmedRasterAtlas(
    forFontAtlas fontAtlas: FontAtlas,
    scale: CGFloat
  ) -> MetalGlyphAtlas? {
    guard let atlas = prewarmedRasterAtlas,
      atlas.isCompatible(
        device: device,
        cellWidth: fontAtlas.cellSize.width,
        cellHeight: fontAtlas.cellSize.height,
        scale: scale)
    else { return nil }
    prewarmedRasterAtlas = nil
    return atlas
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
      subpixelMode: resolved == .grayscale ? 0 : 1,
      timeSeconds: frameTimeSeconds)
  }

  private func encodeBlit(
    from source: MTLTexture,
    to destination: MTLTexture,
    commandBuffer: MTLCommandBuffer
  ) {
    let signposter = RenderEncodeSignpost.signposter
    let spanState = signposter.beginInterval(
      "slug.encodeBlit",
      "\(source.width, privacy: .public)x\(source.height, privacy: .public)")
    defer { signposter.endInterval("slug.encodeBlit", spanState) }
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

  private func ensureTranslucentPipelines() -> Bool {
    if translucentPipelines != nil, linearPremultipliedResolvePipeline != nil {
      return true
    }
    guard
      let content = SlugTranslucentPipelineCache.pipelines(
        device: device, library: shaderLibrary),
      let resolve = VectorGlyphShaderCache.linearPremultipliedResolvePipeline(
        device: device, destinationPixelFormat: layer.pixelFormat)
    else { return false }
    translucentPipelines = content
    linearPremultipliedResolvePipeline = resolve
    return true
  }

  private func encodeLinearPremultipliedResolve(
    from source: MTLTexture,
    to destination: MTLTexture,
    commandBuffer: MTLCommandBuffer
  ) -> Bool {
    guard let pipeline = linearPremultipliedResolvePipeline else { return false }
    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = destination
    descriptor.colorAttachments[0].loadAction = .dontCare
    descriptor.colorAttachments[0].storeAction = .store
    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
      return false
    }
    encoder.label = "laban.slug.linear-premultiplied-resolve"
    encoder.setRenderPipelineState(pipeline)
    encoder.setFragmentTexture(source, index: 0)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()
    return true
  }

  /// Present-thread-only decision: should `presentLatestTarget` actually
  /// encode and blit `version`, or was it already presented? Marks `version`
  /// as presented (mutates `lastPresentedFrameVersion`) exactly when it
  /// returns `true`, so a repeat call with the same version afterward
  /// returns `false`. Factored out of `presentLatestTarget` as a small pure
  /// function (state in, mutation, state out, no Metal types) so it is
  /// unit-testable without a Metal device, a `CAMetalLayer`, or a
  /// `CAMetalDrawable` (see `SlugGlyphDamageTests`).
  ///
  /// Correctness argument for the M4 redundant-present skip: `publishedFrameVersion`
  /// only ever increases for this renderer's lifetime (`&+=1` in
  /// `publishLatestTarget`, never reset or rewound, including across
  /// `resize` — see `lastPresentedFrameVersion`'s declaration). So a
  /// freshly published frame always carries a version that has never been
  /// presented, and this always returns `true` for it: no fresh content can
  /// ever be skipped. A `false` result can only mean this exact published
  /// target was already blitted to a previous drawable, so the drawable
  /// Core Animation now hands back already shows (or will show) that same
  /// content once presented, and skipping the redundant blit changes nothing
  /// visible. `VectorPresentDisplayLink.metalDisplayLink(_:needsUpdate:)`
  /// treats a `false` return from `onPresent` as "not presented" and
  /// decrements `PresentParkDecision`'s deferred-park budget accordingly, but
  /// that budget was already cleared to 0 by the present that DID present
  /// this version (`PresentParkDecision.didCallback(presented: true)`), so a
  /// later same-version callback decrementing an already-zero budget cannot
  /// cause a pending, unpresented frame to be dropped.
  func shouldEncodePresent(version: UInt64) -> Bool {
    guard version != lastPresentedFrameVersion else { return false }
    lastPresentedFrameVersion = version
    return true
  }

  private func presentLatestTarget(into drawable: any CAMetalDrawable) -> Bool {
    presentTargetLock.lock()
    let target = latestPresentedTarget
    let version = publishedFrameVersion
    presentTargetLock.unlock()
    guard let target,
      target.width == drawable.texture.width,
      target.height == drawable.texture.height
    else { return false }
    let signposter = RenderEncodeSignpost.signposter
    guard version != lastPresentedFrameVersion else {
      // Already on screen: no fresh content to blit. Emit a countable event
      // (rather than a span, since nothing is encoded) so traces can tally
      // skips directly instead of inferring them from repeated `v=` values.
      signposter.emitEvent("slug.presentSkip", "v=\(version, privacy: .public)")
      return false
    }
    guard let presentQueue,
      let commandBuffer = presentQueue.makeCommandBuffer()
    else { return false }
    // Mark presented only once we are committed to actually encoding the
    // blit below (a valid command buffer in hand): if `makeCommandBuffer()`
    // above had failed, `shouldEncodePresent` must not have consumed this
    // version, or this exact frame would never get another chance to reach
    // the screen.
    _ = shouldEncodePresent(version: version)
    let spanState = signposter.beginInterval(
      "slug.present", "v=\(version, privacy: .public)")
    defer { signposter.endInterval("slug.present", spanState) }
    encodeBlit(from: target, to: drawable.texture, commandBuffer: commandBuffer)
    commandBuffer.present(drawable)
    commandBuffer.commit()
    return true
  }

  private func publishLatestTarget(_ target: MTLTexture) {
    presentTargetLock.lock()
    latestPresentedTarget = target
    publishedFrameVersion &+= 1
    let version = publishedFrameVersion
    presentTargetLock.unlock()
    RenderEncodeSignpost.signposter.emitEvent(
      "slug.publish", "v=\(version, privacy: .public)")
    if #available(macOS 14.0, *) {
      presentDisplayLink?.notifyContentPublished()
    }
  }

  /// Test-only (not `public`): lets `SlugGlyphDamageTests` prove an
  /// empty-effective-damage frame does not rotate the ring, without
  /// extending the renderer's public contract.
  var targetRingCursorForTesting: Int { targetRingCursor }

  /// Test-only (not `public`): number of slug glyph instances `buildInstances`
  /// built for the most recently rendered frame. Lets `SlugGlyphDamageTests`
  /// prove M5's damage-aware filtering actually skips off-band glyph runs
  /// (execplans/active/slug-hot-path-negative-cache-and-present-skip.md M5)
  /// instead of only checking pixel output.
  var lastFrameSlugGlyphsCountForTesting: Int { lastFrameSlugGlyphsCount }

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
        && (surfaceTransparency.isOpaque
          || (translucentWorkingRing.count == Self.targetRingDepth
            && translucentWorkingRing[0].width == pixelWidth
            && translucentWorkingRing[0].height == pixelHeight))
      guard ringValid else { return (0, true) }
      return ((targetRingCursor + 1) % Self.targetRingDepth, false)
    }
    let legacyValid =
      targetTexture != nil
      && targetTexture!.width == pixelWidth
      && targetTexture!.height == pixelHeight
      && (surfaceTransparency.isOpaque
        || (translucentWorkingTexture != nil
          && translucentWorkingTexture!.width == pixelWidth
          && translucentWorkingTexture!.height == pixelHeight))
    return (0, !legacyValid)
  }

  /// Mutating counterpart to `peekNextRingSlot()`: actually rotates the ring
  /// cursor (or (re)allocates textures) to `slot`. Must be called with the
  /// exact result `peekNextRingSlot()` returned for this frame.
  private func commitRingSlot(
    _ slot: Int, rebuild: Bool
  ) -> (content: MTLTexture, final: MTLTexture)? {
    let needsWorking = !surfaceTransparency.isOpaque
    if needsWorking, !ensureTranslucentPipelines() { return nil }
    if presentQueue != nil {
      if rebuild {
        var finalRing: [MTLTexture] = []
        var workingRing: [MTLTexture] = []
        finalRing.reserveCapacity(Self.targetRingDepth)
        if needsWorking { workingRing.reserveCapacity(Self.targetRingDepth) }
        for i in 0..<Self.targetRingDepth {
          guard let final = makeFinalTargetTexture() else { return nil }
          final.label = "laban.slug.target.\(i)"
          finalRing.append(final)
          if needsWorking {
            guard let working = makeTranslucentWorkingTexture() else { return nil }
            working.label = "laban.slug.linear-working.\(i)"
            workingRing.append(working)
          }
        }
        targetRing = finalRing
        translucentWorkingRing = workingRing
        targetRingCursor = 0
        let final = finalRing[0]
        targetTexture = final
        if needsWorking {
          let content = workingRing[0]
          translucentWorkingTexture = content
          return (content, final)
        }
        translucentWorkingTexture = nil
        return (final, final)
      }
      targetRingCursor = slot
      let final = targetRing[slot]
      targetTexture = final
      if needsWorking {
        let content = translucentWorkingRing[slot]
        translucentWorkingTexture = content
        return (content, final)
      }
      translucentWorkingTexture = nil
      return (final, final)
    }

    if rebuild {
      guard let final = makeFinalTargetTexture() else { return nil }
      final.label = "laban.slug.target"
      targetTexture = final
      if needsWorking {
        guard let content = makeTranslucentWorkingTexture() else { return nil }
        content.label = "laban.slug.linear-working"
        translucentWorkingTexture = content
        return (content, final)
      }
      translucentWorkingTexture = nil
      return (final, final)
    }
    guard let final = targetTexture else { return nil }
    if needsWorking {
      guard let content = translucentWorkingTexture else { return nil }
      return (content, final)
    }
    return (final, final)
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
  private func configChangedSincePreviousFrame(clearColor: MTLClearColor) -> Bool {
    guard let previousClearColor else { return true }
    return previousGestureZoom != gestureZoom
      || previousGestureZoomAnchor != gestureZoomAnchor
      || previousEffectiveSubpixelLayout != effectiveSubpixelLayout
      || previousTextWeight != textWeight
      || previousEmojiRenderingMode != emojiRenderingMode
      || previousClearColor.red != clearColor.red
      || previousClearColor.green != clearColor.green
      || previousClearColor.blue != clearColor.blue
      || previousClearColor.alpha != clearColor.alpha
  }

  private func snapshotConfigForNextFrame(clearColor: MTLClearColor) {
    previousGestureZoom = gestureZoom
    previousGestureZoomAnchor = gestureZoomAnchor
    previousEffectiveSubpixelLayout = effectiveSubpixelLayout
    previousTextWeight = textWeight
    previousEmojiRenderingMode = emojiRenderingMode
    previousClearColor = clearColor
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

  private func makeFinalTargetTexture() -> MTLTexture? {
    makeTexture(pixelWidth: pixelWidth, pixelHeight: pixelHeight, storageMode: .shared)
  }

  private func makeTranslucentWorkingTexture() -> MTLTexture? {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba16Float,
      width: pixelWidth,
      height: pixelHeight,
      mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .private
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
