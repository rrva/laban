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

  public init(
    name: String,
    isDark: Bool,
    bg0: UInt32,
    bg1: UInt32,
    bg2: UInt32,
    fg0: UInt32,
    fg1: UInt32,
    dim0: UInt32,
    red: UInt32,
    blue: UInt32,
    cursor: UInt32,
    selectionBg: UInt32,
    ansi16: [UInt32]
  ) {
    self.name = name
    self.isDark = isDark
    self.bg0 = bg0
    self.bg1 = bg1
    self.bg2 = bg2
    self.fg0 = fg0
    self.fg1 = fg1
    self.dim0 = dim0
    self.red = red
    self.blue = blue
    self.cursor = cursor
    self.selectionBg = selectionBg
    self.ansi16 = ansi16
  }

  /// Attention accent for needsAction chrome: the palette's bright yellow.
  /// Deliberately not `red` — red already means *failure* in the sidebar
  /// (exited process, failed command), and a tab waiting for input is an
  /// invitation, not an error. Every bundled palette tunes its yellow against
  /// the chrome backgrounds, so this stays legible per theme.
  public var attention: UInt32 {
    ansi16.count > 11 ? ansi16[11] : red
  }
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

  /// Gruvbox Dark — Pavel Pertsev's retro warm palette.
  /// https://github.com/morhetz/gruvbox
  public static let gruvboxDark = ThemeData(
    name: "Gruvbox Dark",
    isDark: true,
    bg0: 0x2828_28FF, bg1: 0x3C38_36FF, bg2: 0x5049_45FF,
    fg0: 0xEBDB_B2FF, fg1: 0xFBF1_C7FF, dim0: 0x9283_74FF,
    red: 0xCC24_1DFF, blue: 0x4585_88FF,
    cursor: 0xEBDB_B2FF, selectionBg: 0x5049_4580,
    ansi16: [
      0x2828_28FF,  // 0  black     (bg)
      0xCC24_1DFF,  // 1  red
      0x9897_1AFF,  // 2  green
      0xD799_21FF,  // 3  yellow
      0x4585_88FF,  // 4  blue
      0xB162_86FF,  // 5  magenta   (purple)
      0x689D_6AFF,  // 6  cyan      (aqua)
      0xA899_84FF,  // 7  white     (fg dim)
      0x9283_74FF,  // 8  br black  (gray)
      0xFB49_34FF,  // 9  br red
      0xB8BB_26FF,  // 10 br green
      0xFABD_2FFF,  // 11 br yellow
      0x83A5_98FF,  // 12 br blue
      0xD386_9BFF,  // 13 br magenta
      0x8EC0_7CFF,  // 14 br cyan
      0xEBDB_B2FF,  // 15 br white  (fg)
    ]
  )

  /// Dracula — https://draculatheme.com (the canonical purple-on-charcoal).
  public static let dracula = ThemeData(
    name: "Dracula",
    isDark: true,
    bg0: 0x282A_36FF, bg1: 0x2122_2CFF, bg2: 0x4447_5AFF,
    fg0: 0xF8F8_F2FF, fg1: 0xFFFF_FFFF, dim0: 0x6272_A4FF,
    red: 0xFF55_55FF, blue: 0xBD93_F9FF,
    cursor: 0xF8F8_F2FF, selectionBg: 0x4447_5A80,
    ansi16: [
      0x2122_2CFF,  // 0  black
      0xFF55_55FF,  // 1  red
      0x50FA_7BFF,  // 2  green
      0xF1FA_8CFF,  // 3  yellow
      0xBD93_F9FF,  // 4  blue      (Dracula maps "blue" to purple)
      0xFF79_C6FF,  // 5  magenta   (pink)
      0x8BE9_FDFF,  // 6  cyan
      0xF8F8_F2FF,  // 7  white     (fg)
      0x6272_A4FF,  // 8  br black  (comment)
      0xFF6E_6EFF,  // 9  br red
      0x69FF_94FF,  // 10 br green
      0xFFFF_A5FF,  // 11 br yellow
      0xD6AC_FFFF,  // 12 br blue
      0xFF92_DFFF,  // 13 br magenta
      0xA4FF_FFFF,  // 14 br cyan
      0xFFFF_FFFF,  // 15 br white
    ]
  )

  /// Nord — https://www.nordtheme.com (Arctic, north-bluish).
  public static let nord = ThemeData(
    name: "Nord",
    isDark: true,
    bg0: 0x2E34_40FF, bg1: 0x3B42_52FF, bg2: 0x434C_5EFF,
    fg0: 0xD8DE_E9FF, fg1: 0xECEF_F4FF, dim0: 0x4C56_6AFF,
    red: 0xBF61_6AFF, blue: 0x81A1_C1FF,
    cursor: 0xD8DE_E9FF, selectionBg: 0x434C_5E80,
    ansi16: [
      0x3B42_52FF,  // 0  black     (nord1)
      0xBF61_6AFF,  // 1  red       (nord11)
      0xA3BE_8CFF,  // 2  green     (nord14)
      0xEBCB_8BFF,  // 3  yellow    (nord13)
      0x81A1_C1FF,  // 4  blue      (nord9)
      0xB48E_ADFF,  // 5  magenta   (nord15)
      0x88C0_D0FF,  // 6  cyan      (nord8)
      0xE5E9_F0FF,  // 7  white     (nord5)
      0x4C56_6AFF,  // 8  br black  (nord3)
      0xBF61_6AFF,  // 9  br red
      0xA3BE_8CFF,  // 10 br green
      0xEBCB_8BFF,  // 11 br yellow
      0x81A1_C1FF,  // 12 br blue
      0xB48E_ADFF,  // 13 br magenta
      0x8FBC_BBFF,  // 14 br cyan   (nord7)
      0xECEF_F4FF,  // 15 br white  (nord6)
    ]
  )

  /// Tokyo Night Storm — https://github.com/folke/tokyonight.nvim
  /// Deep blue-violet canvas with high-luminance accents: at Frosted's 80%
  /// canvas opacity the composed blur stays dark and saturated instead of
  /// turning muddy, and the bright palette keeps its contrast over the
  /// lightly blurred background.
  public static let tokyoNightStorm = ThemeData(
    name: "Tokyo Night Storm",
    isDark: true,
    bg0: 0x2428_3BFF, bg1: 0x292E_42FF, bg2: 0x4148_68FF,
    fg0: 0xA9B1_D6FF, fg1: 0xC0CA_F5FF, dim0: 0x565F_89FF,
    red: 0xF776_8EFF, blue: 0x7AA2_F7FF,
    cursor: 0xC0CA_F5FF, selectionBg: 0x2E3C_6480,
    ansi16: [
      0x1D20_2FFF,  // 0  black
      0xF776_8EFF,  // 1  red
      0x9ECE_6AFF,  // 2  green
      0xE0AF_68FF,  // 3  yellow
      0x7AA2_F7FF,  // 4  blue
      0xBB9A_F7FF,  // 5  magenta
      0x7DCF_FFFF,  // 6  cyan
      0xA9B1_D6FF,  // 7  white     (fg0)
      0x4148_68FF,  // 8  bright black
      0xFF89_9DFF,  // 9  bright red
      0x9FE0_44FF,  // 10 bright green
      0xFABA_4AFF,  // 11 bright yellow
      0x8DB0_FFFF,  // 12 bright blue
      0xC7A9_FFFF,  // 13 bright magenta
      0xA4DA_FFFF,  // 14 bright cyan
      0xC0CA_F5FF,  // 15 bright white (fg1)
    ]
  )

  /// Rosé Pine — https://rosepinetheme.com (muted soho purple-grey).
  /// The low-contrast, deep purple base composites beautifully over the
  /// system blur: the 80% Frosted canvas keeps the theme present while the
  /// lightly blurred backdrop glows through and the soft foreground stays calm.
  public static let rosePine = ThemeData(
    name: "Rosé Pine",
    isDark: true,
    bg0: 0x1917_24FF, bg1: 0x2623_3AFF, bg2: 0x403D_52FF,
    fg0: 0x908C_AAFF, fg1: 0xE0DE_F4FF, dim0: 0x6E6A_86FF,
    red: 0xEB6F_92FF, blue: 0x9CCF_D8FF,
    cursor: 0xE0DE_F4FF, selectionBg: 0x403D_5280,
    ansi16: [
      0x2623_3AFF,  // 0  black     (overlay)
      0xEB6F_92FF,  // 1  red       (love)
      0x3174_8FFF,  // 2  green     (pine)
      0xF6C1_77FF,  // 3  yellow    (gold)
      0x9CCF_D8FF,  // 4  blue      (foam)
      0xC4A7_E7FF,  // 5  magenta   (iris)
      0xEBBC_BAFF,  // 6  cyan      (rose)
      0xE0DE_F4FF,  // 7  white     (text)
      0x6E6A_86FF,  // 8  bright black (muted)
      0xEB6F_92FF,  // 9  bright red
      0x3174_8FFF,  // 10 bright green
      0xF6C1_77FF,  // 11 bright yellow
      0x9CCF_D8FF,  // 12 bright blue
      0xC4A7_E7FF,  // 13 bright magenta
      0xEBBC_BAFF,  // 14 bright cyan
      0xE0DE_F4FF,  // 15 bright white
    ]
  )

  /// Rosé Pine Dawn — light pair to Rosé Pine. The warm cream base keeps its
  /// hue at Frosted's 80% opacity while the light, tint-free blur preserves
  /// background detail; ANSI black stays dark per the light-theme palette rule.
  public static let rosePineDawn = ThemeData(
    name: "Rosé Pine Dawn",
    isDark: false,
    bg0: 0xFAF4_EDFF, bg1: 0xF2E9_E1FF, bg2: 0xDFDA_D9FF,
    fg0: 0x7975_93FF, fg1: 0x5752_79FF, dim0: 0x9893_A5FF,
    red: 0xB463_7AFF, blue: 0x5694_9FFF,
    cursor: 0x5752_79FF, selectionBg: 0xDFDA_D980,
    ansi16: [
      0x5752_79FF,  // 0  black     (text — stays dark on the light canvas)
      0xB463_7AFF,  // 1  red       (love)
      0x2869_83FF,  // 2  green     (pine)
      0xEA9D_34FF,  // 3  yellow    (gold)
      0x5694_9FFF,  // 4  blue      (foam)
      0x907A_A9FF,  // 5  magenta   (iris)
      0xD782_7EFF,  // 6  cyan      (rose)
      0x9893_A5FF,  // 7  white     (muted)
      0x7975_93FF,  // 8  bright black (subtle)
      0xB463_7AFF,  // 9  bright red
      0x2869_83FF,  // 10 bright green
      0xEA9D_34FF,  // 11 bright yellow
      0x5694_9FFF,  // 12 bright blue
      0x907A_A9FF,  // 13 bright magenta
      0xD782_7EFF,  // 14 bright cyan
      0x7975_93FF,  // 15 bright white (matches bright black, as in Selenized Light)
    ]
  )

  /// Terminal Basic — the macOS Terminal.app default look: black text on a
  /// pure white canvas with Terminal.app's canonical ANSI palette (dark
  /// normals at 0.6 luminance, vivid brights). ANSI white/bright white are
  /// intentionally light, matching Terminal.app's own white-on-white behavior.
  /// Selection is Terminal.app's light blue.
  public static let terminalBasic = ThemeData(
    name: "Terminal Basic",
    isDark: false,
    bg0: 0xFFFF_FFFF, bg1: 0xF2F2_F2FF, bg2: 0xE5E5_E5FF,
    fg0: 0x0000_00FF, fg1: 0x0000_00FF, dim0: 0x6666_66FF,
    red: 0x9900_00FF, blue: 0x0000_B2FF,
    cursor: 0x4D4D_4DFF, selectionBg: 0xB5D5_FF80,
    ansi16: [
      0x0000_00FF,  // 0  black
      0x9900_00FF,  // 1  red
      0x00A6_00FF,  // 2  green
      0x9999_00FF,  // 3  yellow
      0x0000_B2FF,  // 4  blue
      0xB200_B2FF,  // 5  magenta
      0x00A6_B2FF,  // 6  cyan
      0xBFBF_BFFF,  // 7  white     (light by design, as in Terminal.app)
      0x6666_66FF,  // 8  bright black
      0xE500_00FF,  // 9  bright red
      0x00D9_00FF,  // 10 bright green
      0xE5E5_00FF,  // 11 bright yellow
      0x0000_FFFF,  // 12 bright blue
      0xE500_E5FF,  // 13 bright magenta
      0x00E5_E5FF,  // 14 bright cyan
      0xE5E5_E5FF,  // 15 bright white (light by design, as in Terminal.app)
    ]
  )

  public static let allDarkThemes: [ThemeData] = [
    selenizedDark, catppuccinMocha, gruvboxDark, dracula, nord,
    tokyoNightStorm, rosePine,
  ]
  public static let allLightThemes: [ThemeData] = [
    selenizedLight, catppuccinLatte, rosePineDawn, terminalBasic,
  ]

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

  /// Monotonic counter bumped on every successful `apply`. Lets renderers
  /// with persistent GPU caches detect a palette swap even when the next frame
  /// arrives with partial terminal damage.
  public private(set) static var revision: UInt64 = 0

  // MARK: Mutation

  /// Swap to `theme` and notify observers. No-op if already current.
  public static func apply(_ theme: ThemeData) {
    guard theme != current else { return }
    current = theme
    revision &+= 1
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
