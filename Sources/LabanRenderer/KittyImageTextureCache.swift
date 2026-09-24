import CoreGraphics
import Metal

/// One `texturedQuad` resolved for a Metal draw: the texture plus a single
/// instance in the layout shared by the glyph/texture vertex functions
/// (`GlyphInstance` in Shaders.metal, `VectorGlyphInstance` in
/// VectorGlyphShaders.metal): origin and size in device pixels (bottom-left
/// origin), uv origin/size in normalized top-down texture space. `color`
/// carries the uv clamp rect (minU, minV, maxU, maxV) for the image fragment
/// functions, which sample no color tint.
struct KittyImageQuad {
  struct Instance {
    var origin: SIMD2<Float>  //  8
    var size: SIMD2<Float>  //  8
    var uvOrigin: SIMD2<Float>  //  8
    var uvSize: SIMD2<Float>  //  8
    var uvClamp: SIMD4<Float>  // 16
  }

  var layer: ImageLayer
  var texture: MTLTexture
  var instance: Instance

  /// Resolves a `texturedQuad` against `cache`; nil when the image is not in
  /// `FrameImageStore` (not yet published, or already retired) or degenerate.
  ///
  /// The clamp rect is the crop's whole-pixel bounds inset by half a texel,
  /// so linear filtering never blends in pixels outside the protocol's crop
  /// (the software renderer gets the same result by cropping first).
  static func make(
    rect: CGRect, sourceRect: CGRect, resourceId: UInt64, layer: ImageLayer,
    scale: CGFloat, cache: KittyImageTextureCache
  ) -> KittyImageQuad? {
    guard rect.width > 0, rect.height > 0,
      let texture = cache.texture(for: resourceId)
    else { return nil }
    let width = CGFloat(texture.width)
    let height = CGFloat(texture.height)
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    let source =
      sourceRect.isNull || sourceRect.isEmpty ? bounds : sourceRect.intersection(bounds)
    let crop = source.integral.intersection(bounds)
    guard !source.isEmpty, !crop.isEmpty else { return nil }
    let instance = Instance(
      origin: SIMD2(Float(rect.minX * scale), Float(rect.minY * scale)),
      size: SIMD2(Float(rect.width * scale), Float(rect.height * scale)),
      uvOrigin: SIMD2(Float(source.minX / width), Float(source.minY / height)),
      uvSize: SIMD2(Float(source.width / width), Float(source.height / height)),
      uvClamp: SIMD4(
        Float((crop.minX + 0.5) / width), Float((crop.minY + 0.5) / height),
        Float((crop.maxX - 0.5) / width), Float((crop.maxY - 0.5) / height)))
    return KittyImageQuad(layer: layer, texture: texture, instance: instance)
  }
}

/// Per-renderer GPU textures for `FrameImageStore` images, keyed by resource
/// id (a libghostty image generation, so new pixels always arrive under a new
/// id and a cached texture never goes stale). Uploads on first use; textures
/// no frame has used for `retentionFrames` frames are dropped. Command buffers
/// retain the textures they reference, so dropping one here never pulls it
/// out from under an in-flight frame. Not thread-safe; used from the render
/// thread only.
final class KittyImageTextureCache {
  static let retentionFrames = 120

  private let device: MTLDevice
  private var textures: [UInt64: (texture: MTLTexture, lastUsed: Int)] = [:]
  private var frame = 0
  private(set) var uploads = 0

  init(device: MTLDevice) {
    self.device = device
  }

  var count: Int { textures.count }

  func texture(for resourceId: UInt64) -> MTLTexture? {
    if let entry = textures[resourceId] {
      textures[resourceId] = (entry.texture, frame)
      return entry.texture
    }
    guard let image = FrameImageStore.shared.image(for: resourceId),
      image.width > 0, image.height > 0,
      image.rgba.count >= image.width * image.height * 4
    else { return nil }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm, width: image.width, height: image.height, mipmapped: false)
    descriptor.usage = .shaderRead
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
    texture.label = "laban.kitty-image.\(resourceId)"
    image.rgba.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      texture.replace(
        region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
        withBytes: base, bytesPerRow: image.width * 4)
    }
    uploads += 1
    textures[resourceId] = (texture, frame)
    return texture
  }

  /// Call once per rendered frame, after the frame's quads were resolved.
  func endFrame() {
    frame &+= 1
    guard !textures.isEmpty else { return }
    let stale = textures.compactMap { id, entry in
      frame &- entry.lastUsed > Self.retentionFrames ? id : nil
    }
    for id in stale { textures.removeValue(forKey: id) }
  }

  /// A linear-filtering, edge-clamped sampler for scaled images.
  static func makeSampler(device: MTLDevice) -> MTLSamplerState? {
    let descriptor = MTLSamplerDescriptor()
    descriptor.minFilter = .linear
    descriptor.magFilter = .linear
    descriptor.sAddressMode = .clampToEdge
    descriptor.tAddressMode = .clampToEdge
    return device.makeSamplerState(descriptor: descriptor)
  }
}
