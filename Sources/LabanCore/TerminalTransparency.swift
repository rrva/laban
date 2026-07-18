import Foundation

public enum TerminalBackdropStyle: String, CaseIterable, Codable, Sendable {
  case none
  case systemBlur
  case image
}

/// Geometry requested for a managed terminal background image. The value is
/// pure policy state: AppKit owns the eventual drawing implementation.
public enum TerminalBackgroundImageScaling: String, CaseIterable, Codable, Sendable {
  case fill
  case fit
  case stretch

  public static let `default`: Self = .fill
}

/// URL-free availability input for resolving an Image backdrop. File lookup
/// and decoding belong to the later AppKit image-store boundary.
public enum TerminalBackgroundImageAvailability: String, CaseIterable, Codable, Sendable {
  case none
  case available
  case missing
  case corrupt
  case headlessUnsupported
}

/// The transparency values requested by the user. System and session policy
/// never mutates this value; temporary overrides are represented by
/// `EffectiveTerminalTransparency` instead.
public struct TerminalTransparencyConfiguration: Equatable, Sendable {
  private var storedBackgroundOpacity: Double
  private var storedBackgroundBlur: Double

  /// A stable unit-interval value. NaN falls back to the shipped opaque
  /// default rather than allowing invalid alpha into rendering.
  public var backgroundOpacity: Double {
    get { storedBackgroundOpacity }
    set { storedBackgroundOpacity = Self.clamp(newValue, invalidValue: 1) }
  }

  /// Requested window-background blur as a stable unit interval. It has no
  /// renderer effect; the AppKit window layer maps it to a native blur radius.
  public var backgroundBlur: Double {
    get { storedBackgroundBlur }
    set { storedBackgroundBlur = Self.clamp(newValue, invalidValue: 0) }
  }

  public var applyToExplicitCellBackgrounds: Bool
  public var backdropStyle: TerminalBackdropStyle
  public var backgroundImageScaling: TerminalBackgroundImageScaling

  public init(
    backgroundOpacity: Double,
    applyToExplicitCellBackgrounds: Bool,
    backdropStyle: TerminalBackdropStyle,
    backgroundImageScaling: TerminalBackgroundImageScaling = .default,
    backgroundBlur: Double = 0
  ) {
    self.storedBackgroundOpacity = Self.clamp(backgroundOpacity, invalidValue: 1)
    self.storedBackgroundBlur = Self.clamp(backgroundBlur, invalidValue: 0)
    self.applyToExplicitCellBackgrounds = applyToExplicitCellBackgrounds
    self.backdropStyle = backdropStyle
    self.backgroundImageScaling = backgroundImageScaling
  }

  private static func clamp(_ value: Double, invalidValue: Double) -> Double {
    guard !value.isNaN else { return invalidValue }
    if value <= 0 { return 0 }
    if value >= 1 { return 1 }
    return value
  }
}

public enum TerminalTransparencyForceOpaqueReason: String, Codable, Sendable {
  case reduceTransparency
  case nativeFullscreen
  case legacySnapshotWriter
  case backgroundImageUnavailable
}

public struct EffectiveTerminalTransparency: Equatable, Sendable {
  public var backgroundOpacity: Double
  public var backgroundBlur: Double
  public var applyToExplicitCellBackgrounds: Bool
  public var backdropStyle: TerminalBackdropStyle
  public var forceOpaqueReason: TerminalTransparencyForceOpaqueReason?
  public var isSurfaceOpaque: Bool

  public init(
    backgroundOpacity: Double,
    backgroundBlur: Double = 0,
    applyToExplicitCellBackgrounds: Bool,
    backdropStyle: TerminalBackdropStyle,
    forceOpaqueReason: TerminalTransparencyForceOpaqueReason?,
    isSurfaceOpaque: Bool
  ) {
    self.backgroundOpacity = backgroundOpacity
    self.backgroundBlur = backgroundBlur
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
    backgroundImageAvailability: TerminalBackgroundImageAvailability = .none,
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
    } else if requested.backgroundOpacity < 1,
      requested.backdropStyle == .image,
      !headless,
      backgroundImageAvailability != .available
    {
      forceOpaqueReason = .backgroundImageUnavailable
    } else {
      forceOpaqueReason = nil
    }

    if let forceOpaqueReason {
      return EffectiveTerminalTransparency(
        backgroundOpacity: 1,
        backgroundBlur: 0,
        applyToExplicitCellBackgrounds: requested.applyToExplicitCellBackgrounds,
        backdropStyle: .none,
        forceOpaqueReason: forceOpaqueReason,
        isSurfaceOpaque: true)
    }

    let backgroundOpacity = requested.backgroundOpacity
    let backdropStyle: TerminalBackdropStyle
    let backgroundBlur: Double
    if backgroundOpacity == 1 {
      backdropStyle = .none
      backgroundBlur = 0
    } else {
      switch requested.backdropStyle {
      case .none:
        backdropStyle = .none
        backgroundBlur = 0
      case .systemBlur:
        if supportsBehindWindowBlur && !headless {
          backdropStyle = .systemBlur
          backgroundBlur = requested.backgroundBlur
        } else {
          backdropStyle = .none
          backgroundBlur = 0
        }
      case .image:
        backdropStyle = !headless && backgroundImageAvailability == .available ? .image : .none
        backgroundBlur = 0
      }
    }

    return EffectiveTerminalTransparency(
      backgroundOpacity: backgroundOpacity,
      backgroundBlur: backgroundBlur,
      applyToExplicitCellBackgrounds: requested.applyToExplicitCellBackgrounds,
      backdropStyle: backdropStyle,
      forceOpaqueReason: nil,
      isSurfaceOpaque: backgroundOpacity == 1)
  }
}
