import Metal

/// Process-wide cache for the compiled `VectorGlyphShaders.metal` library and
/// its pipeline states, shared by `VectorGlyphRenderer` and
/// `VectorGlyphScratchRasterizer`.
///
/// Before this cache existed, both initializers independently re-read the
/// bundle resource and called `device.makeLibrary(source:options:)` on the
/// identical 799-line source, and every renderer activation rebuilt all 6
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

  struct TranslucentRenderPipelines {
    let solid: MTLRenderPipelineState
    let replaceSolid: MTLRenderPipelineState
    let glyphAlpha: MTLRenderPipelineState
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
  private static var translucentLibraryCache: [ObjectIdentifier: MTLLibrary] = [:]
  private static var renderPipelineCache: [CacheKey: RenderPipelines] = [:]
  private static var translucentRenderPipelineCache:
    [ObjectIdentifier: TranslucentRenderPipelines] = [:]
  private static var resolvePipelineCache: [CacheKey: MTLRenderPipelineState] = [:]
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

  /// Small library containing only the fragments needed by nonopaque curve
  /// surfaces. It is intentionally loaded and compiled only from the lazy
  /// translucent pipeline accessors below, keeping opaque activation on the
  /// original VectorGlyphShaders source and PSO set.
  static func translucentLibrary(device: MTLDevice) -> MTLLibrary? {
    let key = ObjectIdentifier(device)
    lock.lock()
    if let cached = translucentLibraryCache[key] {
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
        forResource: "TranslucentSurfaceShaders",
        withExtension: "metal"),
      let source = try? String(contentsOf: url, encoding: .utf8),
      let library = try? device.makeLibrary(source: source, options: options)
    else { return nil }

    lock.lock()
    if let existing = translucentLibraryCache[key] {
      lock.unlock()
      return existing
    }
    translucentLibraryCache[key] = library
    lock.unlock()
    return library
  }

  /// The 6 render pipeline states `VectorGlyphRenderer` needs, built at most
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

  /// The exact five PSOs used only by Vector's nonopaque, forced-grayscale
  /// content pass. This separate lazy cache keeps the default opaque activation
  /// on its original pipeline set.
  static func translucentRenderPipelines(device: MTLDevice) -> TranslucentRenderPipelines? {
    let key = ObjectIdentifier(device)
    lock.lock()
    if let cached = translucentRenderPipelineCache[key] {
      lock.unlock()
      return cached
    }
    lock.unlock()

    guard let library = library(device: device),
      let translucentLibrary = translucentLibrary(device: device),
      let solidVertex = library.makeFunction(name: "vectorSolidVertex"),
      let solidFragment = library.makeFunction(name: "vectorSolidFragment"),
      let glyphVertex = library.makeFunction(name: "vectorGlyphVertex"),
      let glyphAlphaFragment = translucentLibrary.makeFunction(
        name: "translucentVectorGlyphAlphaFragment"),
      let rasterGlyphFragment = library.makeFunction(name: "vectorRasterGlyphFragment"),
      let colorGlyphFragment = translucentLibrary.makeFunction(
        name: "translucentVectorColorGlyphFragment")
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
        configureAlphaBlend(value.colorAttachments[0])
      } else {
        value.colorAttachments[0]?.isBlendingEnabled = false
      }
      return value
    }

    guard
      let solid = try? device.makeRenderPipelineState(
        descriptor: descriptor(
          label: "laban.vector.translucent-solid",
          vertex: solidVertex,
          fragment: solidFragment,
          blended: true)),
      let replaceSolid = try? device.makeRenderPipelineState(
        descriptor: descriptor(
          label: "laban.vector.translucent-solid-replace",
          vertex: solidVertex,
          fragment: solidFragment,
          blended: false)),
      let glyphAlpha = try? device.makeRenderPipelineState(
        descriptor: descriptor(
          label: "laban.vector.translucent-glyph-alpha",
          vertex: glyphVertex,
          fragment: glyphAlphaFragment,
          blended: true)),
      let rasterGlyph = try? device.makeRenderPipelineState(
        descriptor: descriptor(
          label: "laban.vector.translucent-raster-glyph",
          vertex: glyphVertex,
          fragment: rasterGlyphFragment,
          blended: true)),
      let colorGlyph = try? device.makeRenderPipelineState(
        descriptor: descriptor(
          label: "laban.vector.translucent-color-glyph",
          vertex: glyphVertex,
          fragment: colorGlyphFragment,
          blended: true))
    else { return nil }

    let pipelines = TranslucentRenderPipelines(
      solid: solid,
      replaceSolid: replaceSolid,
      glyphAlpha: glyphAlpha,
      rasterGlyph: rasterGlyph,
      colorGlyph: colorGlyph)
    lock.lock()
    if let existing = translucentRenderPipelineCache[key] {
      lock.unlock()
      return existing
    }
    translucentRenderPipelineCache[key] = pipelines
    lock.unlock()
    return pipelines
  }

  /// Pipeline for the single storage-boundary pass used by nonopaque Vector
  /// and Slug surfaces. The source is linear-premultiplied rgba16Float; the
  /// destination is the renderer's encoded-sRGB-premultiplied presentation
  /// target. It is cached separately because the content pipelines are also
  /// built for rgba16Float while this pipeline is keyed only by its final
  /// destination format.
  static func linearPremultipliedResolvePipeline(
    device: MTLDevice, destinationPixelFormat: MTLPixelFormat
  ) -> MTLRenderPipelineState? {
    let key = CacheKey(device: ObjectIdentifier(device), pixelFormat: destinationPixelFormat)
    lock.lock()
    if let cached = resolvePipelineCache[key] {
      lock.unlock()
      return cached
    }
    lock.unlock()

    guard let library = library(device: device),
      let translucentLibrary = translucentLibrary(device: device),
      let vertex = library.makeFunction(name: "vectorFullscreenVertex"),
      let fragment = translucentLibrary.makeFunction(name: "linearPremultipliedResolveFragment")
    else { return nil }

    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.label = "laban.linear-premultiplied-resolve"
    descriptor.vertexFunction = vertex
    descriptor.fragmentFunction = fragment
    descriptor.colorAttachments[0]?.pixelFormat = destinationPixelFormat
    descriptor.colorAttachments[0]?.isBlendingEnabled = false
    guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
      return nil
    }

    lock.lock()
    if let existing = resolvePipelineCache[key] {
      lock.unlock()
      return existing
    }
    resolvePipelineCache[key] = pipeline
    lock.unlock()
    return pipeline
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
