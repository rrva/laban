import LabanRenderer

struct DebugPixelProbeSampler {
  var width: Int
  var height: Int
  var pixelAt: (Int, Int) -> UInt32?

  init(width: Int, height: Int, pixelAt: @escaping (Int, Int) -> UInt32?) {
    self.width = width
    self.height = height
    self.pixelAt = pixelAt
  }

  init(surface: BitmapSurface) {
    self.init(width: surface.width, height: surface.height) { x, y in
      surface.pixel(x: x, y: y)
    }
  }

  func response(frame: Int, request: PixelProbeRequest) -> PixelProbeResponse {
    PixelProbeResponse(
      frame: frame,
      points: (request.points ?? []).map(pointResult),
      regions: (request.regions ?? []).map(regionResult)
    )
  }

  func traceProbes(_ probes: [PixelProbeReq]?) -> [TracePixelProbe] {
    (probes ?? []).map { probe in
      TracePixelProbe(
        name: probe.name,
        x: probe.x,
        y: probe.y,
        rgba: pixelAt(probe.x, probe.y).map(DebugFrameCommandSerializer.rgbaArray)
          ?? [0, 0, 0, 255],
        contributors: [
          TraceContributor(passId: "pass-main", drawId: "draw-main", commandId: "cmd-0")
        ]
      )
    }
  }

  private func pointResult(_ point: PixelProbePointRequest) -> PixelProbePointResult {
    PixelProbePointResult(
      x: point.x,
      y: point.y,
      rgba: pixelAt(point.x, point.y).map(DebugFrameCommandSerializer.rgbaArray) ?? [0, 0, 0, 0]
    )
  }

  private func regionResult(_ region: PixelProbeRegionRequest) -> PixelProbeRegionResult {
    var sampled = 0
    var nonBackground = 0
    var sums = [0, 0, 0, 0]
    let background = pixelAt(region.x, region.y)

    let maxX = min(width, region.x + region.width)
    let maxY = min(height, region.y + region.height)
    if region.x < maxX && region.y < maxY {
      for y in region.y..<maxY {
        for x in region.x..<maxX {
          guard let pixel = pixelAt(x, y) else { continue }
          let rgba = DebugFrameCommandSerializer.rgbaArray(pixel)
          for channel in 0..<4 { sums[channel] += rgba[channel] }
          sampled += 1
          if pixel != background { nonBackground += 1 }
        }
      }
    }

    return PixelProbeRegionResult(
      name: region.name,
      averageRgba: sampled > 0 ? sums.map { $0 / sampled } : [0, 0, 0, 0],
      nonBackgroundPixels: nonBackground,
      sampledPixels: sampled
    )
  }
}
