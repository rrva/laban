import Metal

/// Process-wide cache for the compiled `VectorGlyphShaders.metal` library and
/// its pipeline states, shared by `VectorGlyphRenderer` and
/// `VectorGlyphScratchRasterizer`.
///
/// Before this cache existed, both initializers independently re-read the
/// bundle resource and called `device.makeLibrary(source:options:)` on the
/// identical 799-line source, and every renderer activation rebuilt all 5
/// render + 2 compute pipeline states from zero — even the Nth time a session
/// toggled back to the vector renderer. None of that work depends on the
/// per-activation parameters (`fontAtlas`, `scale`, `pixelWidth/Height`): the
/// shader source is static and the pipeline descriptors vary only on
/// `pixelFormat` (which the vector layer always sets to
/// `.bgra8Unorm_srgb`). A Metal System Trace of repeated renderer switching
/// showed this double-compile-per-activation as the single largest CPU
/// category for the vector backend and as multi-hundred-ms main-thread gaps
/// (the `MTLCompiler`/AGX driver PSO-build wait, which blocks the calling
/// thread on IPC) — the visible "white window for a couple of seconds" on
/// activation. Caching the compiled objects removes the redundant rebuild
/// without changing what gets built: the cached `MTLLibrary` and pipeline
/// states are byte-for-byte what a fresh compile would produce, since the
/// inputs (source text, function names, descriptors) are unchanged.
enum VectorGlyphShaderCache {
  struct RenderPipelines {
    let solid: MTLRenderPipelineState
    let replaceSolid: MTLRenderPipelineState
    let glyphCoverage: MTLRenderPipelineState
    let glyphColor: MTLRenderPipelineState
    let rasterGlyph: MTLRenderPipelineState
    let colorGlyph: MTLRenderPipelineState
  }

  struct ComputePipelines {
    let scratch: MTLComputePipelineState
    let accum: MTLComputePipelineState
  }

  private struct CacheKey: Hashable {
    let device: ObjectIdentifier
    let pixelFormat: MTLPixelFormat
  }

  private static let lock = NSLock()
  private static var libraryCache: [ObjectIdentifier: MTLLibrary] = [:]
  private static var renderPipelineCache: [CacheKey: RenderPipelines] = [:]
  private static var computePipelineCache: [ObjectIdentifier: ComputePipelines] = [:]

  /// The compiled `VectorGlyphShaders.metal` library for `device`, building it
  /// at most once per device for the lifetime of the process.
  static func library(device: MTLDevice) -> MTLLibrary? {
    let key = ObjectIdentifier(device)
    lock.lock()
    if let cached = libraryCache[key] {
      lock.unlock()
      return cached
    }
    lock.unlock()

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
      let library = try? device.makeLibrary(source: source, options: options)
    else { return nil }

    lock.lock()
    if let existing = libraryCache[key] {
      // Lost a build race against another thread; keep the first winner so
      // every caller observes a single shared instance.
      lock.unlock()
      return existing
    }
    libraryCache[key] = library
    lock.unlock()
    return library
  }

  /// The 5 render pipeline states `VectorGlyphRenderer` needs, built at most
  /// once per (device, pixelFormat) pair for the lifetime of the process.
  static func renderPipelines(
    device: MTLDevice, pixelFormat: MTLPixelFormat
  ) -> RenderPipelines? {
    let key = CacheKey(device: ObjectIdentifier(device), pixelFormat: pixelFormat)
    lock.lock()
    if let cached = renderPipelineCache[key] {
      lock.unlock()
      return cached
    }
    lock.unlock()

    guard let library = library(device: device),
      let solidVertex = library.makeFunction(name: "vectorSolidVertex"),
      let solidFragment = library.makeFunction(name: "vectorSolidFragment"),
      let glyphVertex = library.makeFunction(name: "vectorGlyphVertex"),
      let glyphCoverageFragment = library.makeFunction(name: "vectorGlyphCoverageFragment"),
      let glyphColorFragment = library.makeFunction(name: "vectorGlyphColorFragment"),
      let rasterGlyphFragment = library.makeFunction(name: "vectorRasterGlyphFragment"),
      let colorGlyphFragment = library.makeFunction(name: "vectorColorGlyphFragment")
    else { return nil }

    let solidDescriptor = MTLRenderPipelineDescriptor()
    solidDescriptor.label = "laban.vector.solid"
    solidDescriptor.vertexFunction = solidVertex
    solidDescriptor.fragmentFunction = solidFragment
    solidDescriptor.colorAttachments[0]?.pixelFormat = pixelFormat
    configureAlphaBlend(solidDescriptor.colorAttachments[0])

    let replaceSolidDescriptor = MTLRenderPipelineDescriptor()
    replaceSolidDescriptor.label = "laban.vector.solid-replace"
    replaceSolidDescriptor.vertexFunction = solidVertex
    replaceSolidDescriptor.fragmentFunction = solidFragment
    replaceSolidDescriptor.colorAttachments[0]?.pixelFormat = pixelFormat
    replaceSolidDescriptor.colorAttachments[0]?.isBlendingEnabled = false

    let glyphCoverageDescriptor = MTLRenderPipelineDescriptor()
    glyphCoverageDescriptor.label = "laban.vector.glyph-coverage"
    glyphCoverageDescriptor.vertexFunction = glyphVertex
    glyphCoverageDescriptor.fragmentFunction = glyphCoverageFragment
    glyphCoverageDescriptor.colorAttachments[0]?.pixelFormat = pixelFormat
    configureSubpixelCoverageBlend(glyphCoverageDescriptor.colorAttachments[0])

    let glyphColorDescriptor = MTLRenderPipelineDescriptor()
    glyphColorDescriptor.label = "laban.vector.glyph-color"
    glyphColorDescriptor.vertexFunction = glyphVertex
    glyphColorDescriptor.fragmentFunction = glyphColorFragment
    glyphColorDescriptor.colorAttachments[0]?.pixelFormat = pixelFormat
    configureAdditiveRGBPreserveAlphaBlend(glyphColorDescriptor.colorAttachments[0])

    let rasterGlyphDescriptor = MTLRenderPipelineDescriptor()
    rasterGlyphDescriptor.label = "laban.vector.raster-glyph"
    rasterGlyphDescriptor.vertexFunction = glyphVertex
    rasterGlyphDescriptor.fragmentFunction = rasterGlyphFragment
    rasterGlyphDescriptor.colorAttachments[0]?.pixelFormat = pixelFormat
    configureAlphaBlend(rasterGlyphDescriptor.colorAttachments[0])

    let colorGlyphDescriptor = MTLRenderPipelineDescriptor()
    colorGlyphDescriptor.label = "laban.vector.color-glyph"
    colorGlyphDescriptor.vertexFunction = glyphVertex
    colorGlyphDescriptor.fragmentFunction = colorGlyphFragment
    colorGlyphDescriptor.colorAttachments[0]?.pixelFormat = pixelFormat
    configureAlphaBlend(colorGlyphDescriptor.colorAttachments[0])

    guard
      let solidPipeline = try? device.makeRenderPipelineState(descriptor: solidDescriptor),
      let replaceSolidPipeline = try? device.makeRenderPipelineState(
        descriptor: replaceSolidDescriptor),
      let glyphCoveragePipeline = try? device.makeRenderPipelineState(
        descriptor: glyphCoverageDescriptor),
      let glyphColorPipeline = try? device.makeRenderPipelineState(
        descriptor: glyphColorDescriptor),
      let rasterGlyphPipeline = try? device.makeRenderPipelineState(
        descriptor: rasterGlyphDescriptor),
      let colorGlyphPipeline = try? device.makeRenderPipelineState(
        descriptor: colorGlyphDescriptor)
    else { return nil }

    let pipelines = RenderPipelines(
      solid: solidPipeline,
      replaceSolid: replaceSolidPipeline,
      glyphCoverage: glyphCoveragePipeline,
      glyphColor: glyphColorPipeline,
      rasterGlyph: rasterGlyphPipeline,
      colorGlyph: colorGlyphPipeline)

    lock.lock()
    if let existing = renderPipelineCache[key] {
      lock.unlock()
      return existing
    }
    renderPipelineCache[key] = pipelines
    lock.unlock()
    return pipelines
  }

  /// The 2 compute pipeline states `VectorGlyphScratchRasterizer` needs, built
  /// at most once per device for the lifetime of the process.
  static func computePipelines(device: MTLDevice) -> ComputePipelines? {
    let key = ObjectIdentifier(device)
    lock.lock()
    if let cached = computePipelineCache[key] {
      lock.unlock()
      return cached
    }
    lock.unlock()

    guard let library = library(device: device),
      let scratchFunction = library.makeFunction(name: "vectorGlyphRasterizeScratch"),
      let accumFunction = library.makeFunction(name: "vectorGlyphAccumulateAtlas"),
      let scratchPipeline = try? device.makeComputePipelineState(function: scratchFunction),
      let accumPipeline = try? device.makeComputePipelineState(function: accumFunction)
    else { return nil }

    let pipelines = ComputePipelines(scratch: scratchPipeline, accum: accumPipeline)

    lock.lock()
    if let existing = computePipelineCache[key] {
      lock.unlock()
      return existing
    }
    computePipelineCache[key] = pipelines
    lock.unlock()
    return pipelines
  }
}
