// Selenized Dark color scheme by Jan Warchol — all values are 0xRRGGBBAA.
// Source: https://github.com/jan-warchol/selenized
public enum Theme {
  public typealias CurrentTheme = SelenizedDark

  public enum SelenizedDark {
    public static let bg0: UInt32 = 0x103C_48FF
    public static let bg1: UInt32 = 0x1749_56FF
    public static let bg2: UInt32 = 0x2D5B_69FF
    public static let dim0: UInt32 = 0x7289_8FFF
    public static let fg0: UInt32 = 0xADBC_BCFF
    public static let fg1: UInt32 = 0xCAD8_D9FF

    public static let red: UInt32 = 0xFA57_50FF
    public static let green: UInt32 = 0x75B9_38FF
    public static let yellow: UInt32 = 0xDBB3_2DFF
    public static let blue: UInt32 = 0x4695_F7FF
    public static let magenta: UInt32 = 0xF275_BEFF
    public static let cyan: UInt32 = 0x41C7_B9FF
    public static let orange: UInt32 = 0xED86_49FF
    public static let violet: UInt32 = 0xAF88_EBFF

    public static let brRed: UInt32 = 0xFF66_5CFF
    public static let brGreen: UInt32 = 0x84C7_47FF
    public static let brYellow: UInt32 = 0xEBC1_3DFF
    public static let brBlue: UInt32 = 0x58A3_FFFF
    public static let brMagenta: UInt32 = 0xFF84_CDFF
    public static let brCyan: UInt32 = 0x53D6_C7FF
    public static let brOrange: UInt32 = 0xFD94_56FF
    public static let brViolet: UInt32 = 0xBD96_FAFF

    public static let cursor: UInt32 = 0xADBC_BCFF
    public static let selectionBg: UInt32 = 0x325B_6680

    // ANSI 16-color palette for OSC injection (indices 0–15).
    public static let ansi16: [UInt32] = [
      bg1,  // 0  black
      red,  // 1  red
      green,  // 2  green
      yellow,  // 3  yellow
      blue,  // 4  blue
      magenta,  // 5  magenta
      cyan,  // 6  cyan
      dim0,  // 7  white
      0x325B_66FF,  // 8  bright black
      brRed,  // 9  bright red
      brGreen,  // 10 bright green
      brYellow,  // 11 bright yellow
      brBlue,  // 12 bright blue
      brMagenta,  // 13 bright magenta
      brCyan,  // 14 bright cyan
      fg1,  // 15 bright white
    ]
  }
}
