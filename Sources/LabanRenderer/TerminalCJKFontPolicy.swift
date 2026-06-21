import CoreGraphics
import CoreText
import Foundation

public struct TerminalCJKFontDiagnostics {
  public let selectedFontPostScriptName: String
  public let selectedFamilyName: String
  public let selectedSource: String
  public let candidateFonts: [String]
  public let fallbackOrder: [String]
  public let glyphAvailable: Bool
  public let glyphAdvance: CGFloat
  public let targetCellWidth: CGFloat
  public let scaleX: CGFloat
}

public enum TerminalCJKFontPolicy {
  private struct Candidate {
    let name: String
    let displayName: String
    let source: String
    let matchTokens: [String]
  }

  private static let candidates: [Candidate] = [
    Candidate(
      name: "PingFangSC-Regular",
      displayName: "PingFang SC",
      source: "system",
      matchTokens: ["pingfang"]),
    Candidate(
      name: "PingFang SC",
      displayName: "PingFang SC",
      source: "system",
      matchTokens: ["pingfang"]),
    Candidate(
      name: "NotoSansMonoCJKsc-Regular",
      displayName: "Noto Sans Mono CJK SC",
      source: "user/system",
      matchTokens: ["notosansmonocjk", "noto sans mono cjk"]),
    Candidate(
      name: "Noto Sans Mono CJK SC",
      displayName: "Noto Sans Mono CJK SC",
      source: "user/system",
      matchTokens: ["notosansmonocjk", "noto sans mono cjk"]),
    Candidate(
      name: "SarasaTermSC-Regular",
      displayName: "Sarasa Term SC",
      source: "user/system",
      matchTokens: ["sarasa"]),
    Candidate(
      name: "Sarasa Term SC",
      displayName: "Sarasa Term SC",
      source: "user/system",
      matchTokens: ["sarasa"]),
    Candidate(
      name: "SarasaMonoSC-Regular",
      displayName: "Sarasa Mono SC",
      source: "user/system",
      matchTokens: ["sarasa"]),
    Candidate(
      name: "Sarasa Mono SC",
      displayName: "Sarasa Mono SC",
      source: "user/system",
      matchTokens: ["sarasa"]),
    Candidate(
      name: "SarasaGothicSC-Regular",
      displayName: "Sarasa Gothic SC",
      source: "user/system",
      matchTokens: ["sarasa"]),
    Candidate(
      name: "Sarasa Gothic SC",
      displayName: "Sarasa Gothic SC",
      source: "user/system",
      matchTokens: ["sarasa"]),
  ]

  private static let representativeScalar = Unicode.Scalar(0x4E2D)!

  public static var candidateFontDisplayNames: [String] {
    var result: [String] = []
    for candidate in candidates where !result.contains(candidate.displayName) {
      result.append(candidate.displayName)
    }
    return result
  }

  public static var fallbackOrderDescription: [String] {
    ["primary terminal font"] + candidateFontDisplayNames + ["CoreText cascade"]
  }

  public static func containsCJK(_ text: String) -> Bool {
    text.unicodeScalars.contains(where: isCJKScalar)
  }

  public static func terminalCellCount(for text: String) -> Int? {
    guard text.count == 1, containsCJK(text) else { return nil }
    return 2
  }

  public static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x1100...0x11FF,  // Hangul Jamo
      0x2E80...0x2EFF,  // CJK radicals supplement
      0x2F00...0x2FDF,  // Kangxi radicals
      0x3000...0x303F,  // CJK symbols and punctuation
      0x3040...0x30FF,  // Hiragana and Katakana
      0x31C0...0x31EF,  // CJK strokes
      0x3200...0x32FF,  // enclosed CJK
      0x3300...0x33FF,  // CJK compatibility
      0x3400...0x4DBF,  // CJK extension A
      0x4E00...0x9FFF,  // CJK unified ideographs
      0xAC00...0xD7AF,  // Hangul syllables
      0xF900...0xFAFF,  // CJK compatibility ideographs
      0xFE30...0xFE4F,  // CJK compatibility forms
      0xFF00...0xFFEF,  // fullwidth forms
      0x20000...0x2FA1F:  // CJK extensions B through compatibility supplement
      return true
    default:
      return false
    }
  }

  static func fontByAddingExplicitCJKCascade(to baseFont: CTFont) -> CTFont {
    let cascadeFonts = explicitCascadeFonts(for: baseFont)
    guard !cascadeFonts.isEmpty else { return baseFont }

    let descriptors = cascadeFonts.map { CTFontCopyFontDescriptor($0) } as CFArray
    let attributes = [kCTFontCascadeListAttribute: descriptors] as CFDictionary
    let descriptor = CTFontCopyFontDescriptor(baseFont)
    let cascaded = CTFontDescriptorCreateCopyWithAttributes(descriptor, attributes)
    return CTFontCreateWithFontDescriptor(cascaded, CTFontGetSize(baseFont), nil)
  }

  static func explicitCascadeFonts(for baseFont: CTFont) -> [CTFont] {
    let pointSize = CTFontGetSize(baseFont)
    let traits = CTFontGetSymbolicTraits(baseFont).intersection([.traitBold, .traitItalic])
    var result: [CTFont] = []
    var seen: Set<String> = []

    for candidate in candidates {
      guard let font = resolvedCandidateFont(candidate, pointSize: pointSize, traits: traits)
      else { continue }
      let postScriptName = CTFontCopyPostScriptName(font) as String
      guard !seen.contains(postScriptName) else { continue }
      seen.insert(postScriptName)
      result.append(font)
    }
    return result
  }

  static func cjkMetricPlan(
    text: String,
    cellWidth: CGFloat,
    layoutWidth: CGFloat,
    inkBounds: CGRect
  ) -> (targetWidth: CGFloat, scaleX: CGFloat)? {
    guard let cellCount = terminalCellCount(for: text), cellWidth.isFinite, cellWidth > 0 else {
      return nil
    }
    let targetWidth = CGFloat(cellCount) * cellWidth
    let inkExtent = max(inkBounds.maxX, layoutWidth) - min(inkBounds.minX, 0)
    let naturalWidth = max(layoutWidth, inkBounds.width, inkExtent)
    guard naturalWidth.isFinite, naturalWidth > 0 else {
      return (targetWidth: targetWidth, scaleX: 1)
    }
    return (targetWidth: targetWidth, scaleX: min(1, targetWidth / naturalWidth))
  }

  public static func diagnostics(
    baseFont: CTFont,
    cellWidth: CGFloat
  ) -> TerminalCJKFontDiagnostics {
    let selected = explicitCascadeFonts(for: baseFont).first
    let selectedFont = selected ?? baseFont
    let postScriptName = CTFontCopyPostScriptName(selectedFont) as String
    let familyName = CTFontCopyFamilyName(selectedFont) as String
    let advance = glyphAdvance(for: representativeScalar, font: selectedFont)
    let targetCellWidth = max(cellWidth * 2, 0)
    let scaleX: CGFloat
    if let advance, advance > targetCellWidth, targetCellWidth > 0 {
      scaleX = targetCellWidth / advance
    } else {
      scaleX = 1
    }
    return TerminalCJKFontDiagnostics(
      selectedFontPostScriptName: selected == nil ? "" : postScriptName,
      selectedFamilyName: selected == nil ? "" : familyName,
      selectedSource: selected == nil ? "CoreText cascade" : source(for: selectedFont),
      candidateFonts: candidateFontDisplayNames,
      fallbackOrder: fallbackOrderDescription,
      glyphAvailable: advance != nil,
      glyphAdvance: advance ?? 0,
      targetCellWidth: targetCellWidth,
      scaleX: scaleX)
  }

  private static func resolvedCandidateFont(
    _ candidate: Candidate,
    pointSize: CGFloat,
    traits: CTFontSymbolicTraits
  ) -> CTFont? {
    let base = CTFontCreateWithName(candidate.name as CFString, pointSize, nil)
    guard matches(candidate: candidate, font: base),
      glyphAdvance(for: representativeScalar, font: base) != nil
    else {
      return nil
    }
    guard !traits.isEmpty else { return base }
    return CTFontCreateCopyWithSymbolicTraits(base, pointSize, nil, traits, traits) ?? base
  }

  private static func matches(candidate: Candidate, font: CTFont) -> Bool {
    let postScriptName = (CTFontCopyPostScriptName(font) as String).lowercased()
    let familyName = (CTFontCopyFamilyName(font) as String).lowercased()
    return candidate.matchTokens.contains { token in
      postScriptName.contains(token) || familyName.contains(token)
    }
  }

  private static func glyphAdvance(for scalar: Unicode.Scalar, font: CTFont) -> CGFloat? {
    guard scalar.value <= UInt32(UInt16.max) else { return nil }
    var unit = UniChar(scalar.value)
    var glyph = CGGlyph()
    guard CTFontGetGlyphsForCharacters(font, &unit, &glyph, 1), glyph != 0 else {
      return nil
    }
    var glyphCopy = glyph
    var advance = CGSize.zero
    let value = CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphCopy, &advance, 1)
    let width = advance.width.isFinite && advance.width > 0 ? advance.width : CGFloat(value)
    return width.isFinite && width > 0 ? width : nil
  }

  private static func source(for font: CTFont) -> String {
    let postScriptName = (CTFontCopyPostScriptName(font) as String).lowercased()
    let familyName = (CTFontCopyFamilyName(font) as String).lowercased()
    if postScriptName.contains("pingfang") || familyName.contains("pingfang") {
      return "system"
    }
    return "user/system"
  }
}
