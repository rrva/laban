import Foundation

public enum TerminalBackdropStyle: String, CaseIterable, Codable, Sendable {
  case none
  case systemBlur
}

/// The transparency values requested by the user. System and session policy
/// never mutates this value; temporary overrides are represented by
/// `EffectiveTerminalTransparency` instead.
public struct TerminalTransparencyConfiguration: Equatable, Sendable {
  private var storedBackgroundOpacity: Double

  /// A stable unit-interval value. NaN falls back to the shipped opaque
  /// default rather than allowing invalid alpha into rendering.
  public var backgroundOpacity: Double {
    get { storedBackgroundOpacity }
    set { storedBackgroundOpacity = Self.clamp(newValue) }
  }

  public var applyToExplicitCellBackgrounds: Bool
  public var backdropStyle: TerminalBackdropStyle

  public init(
    backgroundOpacity: Double,
    applyToExplicitCellBackgrounds: Bool,
    backdropStyle: TerminalBackdropStyle
  ) {
    self.storedBackgroundOpacity = Self.clamp(backgroundOpacity)
    self.applyToExplicitCellBackgrounds = applyToExplicitCellBackgrounds
    self.backdropStyle = backdropStyle
  }

  private static func clamp(_ opacity: Double) -> Double {
    guard !opacity.isNaN else { return 1 }
    if opacity <= 0 { return 0 }
    if opacity >= 1 { return 1 }
    return opacity
  }
}

public enum TerminalTransparencyForceOpaqueReason: String, Codable, Sendable {
  case reduceTransparency
  case nativeFullscreen
  case legacySnapshotWriter
}

public struct EffectiveTerminalTransparency: Equatable, Sendable {
  public var backgroundOpacity: Double
  public var applyToExplicitCellBackgrounds: Bool
  public var backdropStyle: TerminalBackdropStyle
  public var forceOpaqueReason: TerminalTransparencyForceOpaqueReason?
  public var isSurfaceOpaque: Bool

  public init(
    backgroundOpacity: Double,
    applyToExplicitCellBackgrounds: Bool,
    backdropStyle: TerminalBackdropStyle,
    forceOpaqueReason: TerminalTransparencyForceOpaqueReason?,
    isSurfaceOpaque: Bool
  ) {
    self.backgroundOpacity = backgroundOpacity
    self.applyToExplicitCellBackgrounds = applyToExplicitCellBackgrounds
    self.backdropStyle = backdropStyle
    self.forceOpaqueReason = forceOpaqueReason
    self.isSurfaceOpaque = isSurfaceOpaque
  }
}

/// Resolves persisted user intent into the state that may safely be applied to
/// a terminal surface. This policy is deliberately pure so visible, headless,
/// local, and remote paths cannot disagree about temporary overrides.
public enum TerminalTransparencyPolicy {
  public static func resolve(
    requested: TerminalTransparencyConfiguration,
    reduceTransparency: Bool,
    nativeFullscreen: Bool,
    supportsBehindWindowBlur: Bool,
    snapshotBackgroundCapability: TerminalSnapshotBackgroundCapability,
    headless: Bool
  ) -> EffectiveTerminalTransparency {
    let forceOpaqueReason: TerminalTransparencyForceOpaqueReason?
    if reduceTransparency {
      forceOpaqueReason = .reduceTransparency
    } else if nativeFullscreen {
      forceOpaqueReason = .nativeFullscreen
    } else if snapshotBackgroundCapability == .legacy {
      forceOpaqueReason = .legacySnapshotWriter
    } else {
      forceOpaqueReason = nil
    }

    if let forceOpaqueReason {
      return EffectiveTerminalTransparency(
        backgroundOpacity: 1,
        applyToExplicitCellBackgrounds: requested.applyToExplicitCellBackgrounds,
        backdropStyle: .none,
        forceOpaqueReason: forceOpaqueReason,
        isSurfaceOpaque: true)
    }

    let backgroundOpacity = requested.backgroundOpacity
    let backdropStyle: TerminalBackdropStyle
    if backgroundOpacity == 1 {
      backdropStyle = .none
    } else {
      switch requested.backdropStyle {
      case .none:
        backdropStyle = .none
      case .systemBlur:
        backdropStyle = supportsBehindWindowBlur && !headless ? .systemBlur : .none
      }
    }

    return EffectiveTerminalTransparency(
      backgroundOpacity: backgroundOpacity,
      applyToExplicitCellBackgrounds: requested.applyToExplicitCellBackgrounds,
      backdropStyle: backdropStyle,
      forceOpaqueReason: nil,
      isSurfaceOpaque: backgroundOpacity == 1)
  }
}
