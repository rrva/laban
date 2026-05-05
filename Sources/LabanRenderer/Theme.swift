import Foundation

/// A complete terminal color theme: an explicit 16-color ANSI palette plus
/// the chrome slots (background ramp, default fg, dim text, accent colors,
/// cursor, selection) that FrameProducer and SidebarProducer read.
///
/// Stored as 0xRRGGBBAA. Selection uses a translucent alpha; everything else
/// is fully opaque.
///
/// `ansi16` is independent of the chrome ramp on purpose — for light themes,
/// "ANSI 0 = black" must stay dark even when the sidebar background (`bg1`)
/// is light. Bundle author owns the palette.
public struct ThemeData: Equatable, Sendable {
  public let name: String
  public let isDark: Bool

  // Background ramp: bg0 is the terminal canvas, bg1 the sidebar, bg2 the
  // active-tab pill. Three steps so chrome can stack without colliding.
  public let bg0: UInt32
  public let bg1: UInt32
  public let bg2: UInt32

  /// Default foreground for sidebar text and the in-tab labels.
  public let fg0: UInt32
  /// Stronger foreground used on the active tab and any "primary text" slot.
  public let fg1: UInt32
  /// Dim foreground for secondary lines and inactive labels.
  public let dim0: UInt32

  /// Status-badge color in the sidebar (process exited, errors).
  public let red: UInt32
  /// Accent stripe on the active tab and the default link-underline color.
  public let blue: UInt32

  public let cursor: UInt32
  public let selectionBg: UInt32

  /// 16-color ANSI palette in libghostty's OSC 4 order.
  /// 0–7: black, red, green, yellow, blue, magenta, cyan, white.
  /// 8–15: bright equivalents.
  public let ansi16: [UInt32]
}

public enum Theme {

  // MARK: Bundled palettes

  /// Selenized Dark by Jan Warchol — https://github.com/jan-warchol/selenized
  public static let selenizedDark = ThemeData(
    name: "Selenized Dark",
    isDark: true,
    bg0: 0x103C_48FF, bg1: 0x1749_56FF, bg2: 0x2D5B_69FF,
    fg0: 0xADBC_BCFF, fg1: 0xCAD8_D9FF, dim0: 0x7289_8FFF,
    red: 0xFA57_50FF, blue: 0x4695_F7FF,
    cursor: 0xADBC_BCFF, selectionBg: 0x325B_6680,
    ansi16: [
      0x1749_56FF,  // 0  black (bg1, intentional — Selenized's "ANSI black" is its bg1)
      0xFA57_50FF,  // 1  red
      0x75B9_38FF,  // 2  green
      0xDBB3_2DFF,  // 3  yellow
      0x4695_F7FF,  // 4  blue
      0xF275_BEFF,  // 5  magenta
      0x41C7_B9FF,  // 6  cyan
      0x7289_8FFF,  // 7  white (dim0)
      0x325B_66FF,  // 8  bright black
      0xFF66_5CFF,  // 9  bright red
      0x84C7_47FF,  // 10 bright green
      0xEBC1_3DFF,  // 11 bright yellow
      0x58A3_FFFF,  // 12 bright blue
      0xFF84_CDFF,  // 13 bright magenta
      0x53D6_C7FF,  // 14 bright cyan
      0xCAD8_D9FF,  // 15 bright white (fg1)
    ]
  )

  /// Selenized Light — pair to Selenized Dark from the same upstream palette.
  public static let selenizedLight = ThemeData(
    name: "Selenized Light",
    isDark: false,
    bg0: 0xFBF3_DBFF, bg1: 0xECE3_CCFF, bg2: 0xD5CD_B6FF,
    fg0: 0x5367_6DFF, fg1: 0x3A4D_53FF, dim0: 0x9099_95FF,
    red: 0xD221_2DFF, blue: 0x0072_D4FF,
    cursor: 0x5367_6DFF, selectionBg: 0xC4B8_9A80,
    ansi16: [
      0x3A4D_53FF,  // 0  black (the actual dark color — fg1 doubles as ANSI black)
      0xD221_2DFF,  // 1  red
      0x4891_00FF,  // 2  green
      0xAD89_00FF,  // 3  yellow
      0x0072_D4FF,  // 4  blue
      0xCA48_98FF,  // 5  magenta
      0x009C_8FFF,  // 6  cyan
      0x9099_95FF,  // 7  white (dim0)
      0x5367_6DFF,  // 8  bright black (fg0)
      0xCC17_29FF,  // 9  bright red
      0x428B_00FF,  // 10 bright green
      0xA783_00FF,  // 11 bright yellow
      0x006D_CEFF,  // 12 bright blue
      0xC443_92FF,  // 13 bright magenta
      0x0097_8AFF,  // 14 bright cyan
      0x5367_6DFF,  // 15 bright white (matches bright black; Selenized Light is intentional here)
    ]
  )

  /// Catppuccin Mocha — https://github.com/catppuccin/catppuccin
  /// Chrome maps Base→bg0, Surface1→bg1 (also ANSI black), Surface2→bg2.
  public static let catppuccinMocha = ThemeData(
    name: "Catppuccin Mocha",
    isDark: true,
    bg0: 0x1E1E_2EFF, bg1: 0x4547_5AFF, bg2: 0x585B_70FF,
    fg0: 0xBAC2_DEFF, fg1: 0xCDD6_F4FF, dim0: 0x7F84_9CFF,
    red: 0xF38B_A8FF, blue: 0x89B4_FAFF,
    cursor: 0xF5E0_DCFF, selectionBg: 0x585B_7080,
    ansi16: [
      0x4547_5AFF,  // 0  black     (Surface1)
      0xF38B_A8FF,  // 1  red
      0xA6E3_A1FF,  // 2  green
      0xF9E2_AFFF,  // 3  yellow
      0x89B4_FAFF,  // 4  blue
      0xF5C2_E7FF,  // 5  magenta   (Pink)
      0x94E2_D5FF,  // 6  cyan      (Teal)
      0xBAC2_DEFF,  // 7  white     (Subtext1)
      0x585B_70FF,  // 8  br black  (Surface2)
      0xF38B_A8FF,  // 9  br red
      0xA6E3_A1FF,  // 10 br green
      0xF9E2_AFFF,  // 11 br yellow
      0x89B4_FAFF,  // 12 br blue
      0xF5C2_E7FF,  // 13 br magenta
      0x94E2_D5FF,  // 14 br cyan
      0xA6AD_C8FF,  // 15 br white  (Subtext0)
    ]
  )

  /// Catppuccin Latte — light pair to Catppuccin Mocha.
  /// Subtext1→bg1 keeps the chrome surface visually lifted from Base.
  public static let catppuccinLatte = ThemeData(
    name: "Catppuccin Latte",
    isDark: false,
    bg0: 0xEFF1_F5FF, bg1: 0xCCD0_DAFF, bg2: 0xBCC0_CCFF,
    fg0: 0x4C4F_69FF, fg1: 0x4C4F_69FF, dim0: 0x8C8F_A1FF,
    red: 0xD20F_39FF, blue: 0x1E66_F5FF,
    cursor: 0xDC8A_78FF, selectionBg: 0xACB0_BE80,
    ansi16: [
      0x5C5F_77FF,  // 0  black     (Subtext1)
      0xD20F_39FF,  // 1  red
      0x40A0_2BFF,  // 2  green
      0xDF8E_1DFF,  // 3  yellow
      0x1E66_F5FF,  // 4  blue
      0xEA76_CBFF,  // 5  magenta   (Pink)
      0x1792_99FF,  // 6  cyan      (Teal)
      0xACB0_BEFF,  // 7  white     (Surface2)
      0x6C6F_85FF,  // 8  br black  (Subtext0)
      0xD20F_39FF,  // 9  br red
      0x40A0_2BFF,  // 10 br green
      0xDF8E_1DFF,  // 11 br yellow
      0x1E66_F5FF,  // 12 br blue
      0xEA76_CBFF,  // 13 br magenta
      0x1792_99FF,  // 14 br cyan
      0xBCC0_CCFF,  // 15 br white  (Surface1)
    ]
  )

  public static let allDarkThemes: [ThemeData] = [selenizedDark, catppuccinMocha]
  public static let allLightThemes: [ThemeData] = [selenizedLight, catppuccinLatte]

  // MARK: Runtime state

  /// Active theme. Mutated only on the main thread (NSApp appearance KVO
  /// fires on main), read from the main-thread render loop. No locking.
  public static var current: ThemeData = selenizedDark

  /// User's chosen variants for system-appearance auto-switching. Hard-coded
  /// for now; a future config layer (Phase 2) will load these by name.
  public static var darkVariant: ThemeData = selenizedDark
  public static var lightVariant: ThemeData = selenizedLight

  /// When true, applyForAppearance(isDark:) follows the system. False locks
  /// `current` to whatever the user picked manually.
  public static var followsSystemAppearance: Bool = true

  /// Posted whenever `current` changes. AppModel re-injects the palette into
  /// every live session via OSC 4/10/11/12; views invalidate their next frame
  /// so chrome reads the new colors.
  public static let didChangeNotification = Notification.Name("LabanThemeDidChange")

  /// Backward-compatible accessor — existing code reads `Theme.CurrentTheme.bg0`.
  /// Returns the live `current` theme so any property access picks up swaps.
  public static var CurrentTheme: ThemeData { current }

  // MARK: Mutation

  /// Swap to `theme` and notify observers. No-op if already current.
  public static func apply(_ theme: ThemeData) {
    guard theme != current else { return }
    current = theme
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
  }

  /// Pick `darkVariant` or `lightVariant` based on the system appearance and
  /// apply it. Skipped when `followsSystemAppearance` is off so a manual
  /// override can stick across appearance changes.
  public static func applyForAppearance(isDark: Bool) {
    guard followsSystemAppearance else { return }
    apply(isDark ? darkVariant : lightVariant)
  }
}
