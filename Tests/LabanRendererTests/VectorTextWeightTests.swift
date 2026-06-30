import Foundation
import XCTest

@testable import LabanRenderer

/// Gates the user-tunable text-weight (stem-darkening) setting: the exponent must
/// be neutral at weight 0, thicken at weight 1, and thicken dark-on-light more
/// than light-on-dark (matching where CoreText stem-darkens most). Also covers
/// the persistence round-trip.
final class VectorTextWeightTests: XCTestCase {
  private let white: UInt32 = 0xFF_FF_FF_FF
  private let black: UInt32 = 0x00_00_00_FF
  private let darkFg: UInt32 = 0x18_22_2A_FF
  private let lightBg: UInt32 = 0xF6_EE_DB_FF

  func testWeightZeroIsNeutral() {
    // weight 0 => pure geometric coverage, no darkening, in either direction.
    XCTAssertEqual(
      VectorGlyphRenderer.coverageExponent(foreground: white, background: black, weight: 0),
      1, accuracy: 1e-6)
    XCTAssertEqual(
      VectorGlyphRenderer.coverageExponent(foreground: darkFg, background: lightBg, weight: 0),
      1, accuracy: 1e-6)
  }

  func testWeightOneThickensBothDirections() {
    let lightOnDark = VectorGlyphRenderer.coverageExponent(
      foreground: white, background: black, weight: 1)
    let darkOnLight = VectorGlyphRenderer.coverageExponent(
      foreground: darkFg, background: lightBg, weight: 1)
    // exponent < 1 means coverage^e > coverage, i.e. thicker.
    XCTAssertLessThan(lightOnDark, 1)
    XCTAssertLessThan(darkOnLight, 1)
    // Dark-on-light gets the extra directional boost (thin strokes wash out on
    // bright backgrounds), so its exponent is smaller (thickens more).
    XCTAssertLessThan(darkOnLight, lightOnDark)
  }

  func testWeightScalesMonotonically() {
    let half = VectorGlyphRenderer.coverageExponent(
      foreground: darkFg, background: lightBg, weight: 0.5)
    let full = VectorGlyphRenderer.coverageExponent(
      foreground: darkFg, background: lightBg, weight: 1)
    XCTAssertLessThan(full, half)  // more weight => smaller exponent => thicker
    XCTAssertLessThan(half, 1)
  }

  func testWeightAboveOneThickensFurther() {
    // Weight can exceed CoreText (1.0) up to 2.0 for an extra-heavy look.
    let full = VectorGlyphRenderer.coverageExponent(
      foreground: darkFg, background: lightBg, weight: 1)
    let heavy = VectorGlyphRenderer.coverageExponent(
      foreground: darkFg, background: lightBg, weight: 2)
    XCTAssertLessThan(heavy, full)  // smaller exponent => thicker than CoreText
  }

  func testSettingPersistsAndClamps() {
    let defaults = UserDefaults(suiteName: "VectorTextWeightTests-\(UUID().uuidString)")!
    XCTAssertEqual(VectorTextWeightSettings.current(defaults: defaults), 1.0, accuracy: 1e-9)
    VectorTextWeightSettings.setCurrent(0.3, defaults: defaults)
    XCTAssertEqual(VectorTextWeightSettings.current(defaults: defaults), 0.3, accuracy: 1e-9)
    VectorTextWeightSettings.setCurrent(1.7, defaults: defaults)
    XCTAssertEqual(VectorTextWeightSettings.current(defaults: defaults), 1.7, accuracy: 1e-9)
    VectorTextWeightSettings.setCurrent(5, defaults: defaults)
    XCTAssertEqual(
      VectorTextWeightSettings.current(defaults: defaults),
      VectorTextWeightSettings.maxWeight, accuracy: 1e-9)
    VectorTextWeightSettings.setCurrent(-1, defaults: defaults)
    XCTAssertEqual(VectorTextWeightSettings.current(defaults: defaults), 0.0, accuracy: 1e-9)
  }
}
