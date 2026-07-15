public struct TerminalBackgroundCompositingOptions: Equatable, Sendable {
  public var opacity: UInt8
  public var applyToExplicitCellBackgrounds: Bool

  public init(opacity: UInt8, applyToExplicitCellBackgrounds: Bool) {
    self.opacity = opacity
    self.applyToExplicitCellBackgrounds = applyToExplicitCellBackgrounds
  }

  public static let opaque = TerminalBackgroundCompositingOptions(
    opacity: 255,
    applyToExplicitCellBackgrounds: false)
}
