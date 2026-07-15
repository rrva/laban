public struct RendererSurfaceTransparency: Equatable, Sendable {
  public var isOpaque: Bool

  public init(isOpaque: Bool) {
    self.isOpaque = isOpaque
  }
}
