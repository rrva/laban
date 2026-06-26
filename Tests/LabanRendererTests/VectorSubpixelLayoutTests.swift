import XCTest

@testable import LabanRenderer

final class VectorSubpixelLayoutTests: XCTestCase {
  func testSettingsCasesExposeGrayscaleCalibratedAndRGBOnly() {
    XCTAssertEqual(
      VectorSubpixelLayoutPreset.settingsCases,
      [.grayscale, .calibratedRGB, .rgbStripe])
    XCTAssertTrue(
      VectorSubpixelLayoutPreset.allCases.contains(.bgrStripe),
      "BGR remains available for debug/API calibration without being a normal Settings choice.")
  }

  func testPersistedPresetDefaultsToGrayscaleAndStoresCalibratedAndStripePresets() throws {
    let suiteName = "VectorSubpixelLayoutTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    XCTAssertEqual(VectorSubpixelLayout.persistedPreset(defaults: defaults), .grayscale)
    XCTAssertEqual(VectorSubpixelLayout.persisted(defaults: defaults), .grayscale)

    VectorSubpixelLayout.setPersistedPreset(.calibratedRGB, defaults: defaults)

    XCTAssertEqual(VectorSubpixelLayout.persistedPreset(defaults: defaults), .calibratedRGB)
    XCTAssertEqual(VectorSubpixelLayout.persisted(defaults: defaults), .calibratedRGB)
    XCTAssertEqual(
      VectorSubpixelLayout.persisted(defaults: defaults).offsets.x, -0.15, accuracy: 0.0001)
    XCTAssertEqual(
      VectorSubpixelLayout.persisted(defaults: defaults).offsets.z, 0.15, accuracy: 0.0001)
    XCTAssertLessThan(
      VectorSubpixelLayout.calibratedRGB.areas.r.min.x,
      0,
      "Calibrated RGB should model OSOR-style left bleed outside the pixel.")
    XCTAssertGreaterThan(
      VectorSubpixelLayout.calibratedRGB.areas.b.max.x,
      1,
      "Calibrated RGB should model OSOR-style right bleed outside the pixel.")
    XCTAssertGreaterThan(
      VectorSubpixelLayout.calibratedRGB.areas.r.max.x,
      VectorSubpixelLayout.calibratedRGB.areas.g.min.x,
      "Calibrated RGB channel sample areas must overlap.")
    XCTAssertGreaterThan(
      VectorSubpixelLayout.calibratedRGB.areas.g.max.x,
      VectorSubpixelLayout.calibratedRGB.areas.b.min.x,
      "Calibrated RGB channel sample areas must overlap.")

    VectorSubpixelLayout.setPersistedPreset(.rgbStripe, defaults: defaults)

    XCTAssertEqual(VectorSubpixelLayout.persistedPreset(defaults: defaults), .rgbStripe)
    XCTAssertEqual(VectorSubpixelLayout.persisted(defaults: defaults), .rgbStripe)
    XCTAssertEqual(
      VectorSubpixelLayout.rgbStripe.areas.r.max.x,
      VectorSubpixelLayout.rgbStripe.areas.g.min.x,
      accuracy: 0.0001)
    XCTAssertEqual(
      VectorSubpixelLayout.rgbStripe.areas.g.max.x,
      VectorSubpixelLayout.rgbStripe.areas.b.min.x,
      accuracy: 0.0001)

    VectorSubpixelLayout.setPersistedPreset(.bgrStripe, defaults: defaults)

    XCTAssertEqual(VectorSubpixelLayout.persistedPreset(defaults: defaults), .bgrStripe)
    XCTAssertEqual(VectorSubpixelLayout.persisted(defaults: defaults), .bgrStripe)
  }

  func testPersistedCustomJSONLayoutSupportsAdvancedOffsets() throws {
    let suiteName = "VectorSubpixelLayoutTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set(
      #"{"name":"oledDiamond","offsets":[-0.25,0.0,0.25]}"#,
      forKey: VectorSubpixelLayout.defaultsKey)

    let layout = VectorSubpixelLayout.persisted(defaults: defaults)
    XCTAssertEqual(layout.name, "oledDiamond")
    XCTAssertEqual(layout.offsets.x, -0.25, accuracy: 0.0001)
    XCTAssertEqual(layout.offsets.y, 0, accuracy: 0.0001)
    XCTAssertEqual(layout.offsets.z, 0.25, accuracy: 0.0001)
    XCTAssertEqual(
      VectorSubpixelLayout.persistedPreset(defaults: defaults),
      .grayscale,
      "Settings only exposes safe presets; custom JSON remains an advanced path.")
  }

  func testPersistedCustomJSONLayoutSupportsOSORAreas() throws {
    let suiteName = "VectorSubpixelLayoutTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set(
      #"{"name":"lcdOverlap","areas":[[-0.1,0.0,0.7,1.0],[0.1,0.0,0.9,1.0],[0.3,0.0,1.1,1.0]]}"#,
      forKey: VectorSubpixelLayout.defaultsKey)

    let layout = VectorSubpixelLayout.persisted(defaults: defaults)
    XCTAssertEqual(layout.name, "lcdOverlap")
    XCTAssertEqual(layout.offsets.x, -0.20, accuracy: 0.0001)
    XCTAssertEqual(layout.offsets.y, 0, accuracy: 0.0001)
    XCTAssertEqual(layout.offsets.z, 0.20, accuracy: 0.0001)
    XCTAssertEqual(layout.areas.r.min.x, -0.1, accuracy: 0.0001)
    XCTAssertEqual(layout.areas.b.max.x, 1.1, accuracy: 0.0001)
  }

  func testSetPersistedCustomLayoutWritesJSON() throws {
    let suiteName = "VectorSubpixelLayoutTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let custom = try XCTUnwrap(
      VectorSubpixelLayout.custom(
        name: "oledDiamond",
        offsets: SIMD3<Float>(-0.25, 0, 0.25)))
    VectorSubpixelLayout.setPersisted(custom, defaults: defaults)

    let layout = VectorSubpixelLayout.persisted(defaults: defaults)
    XCTAssertEqual(layout.name, "oledDiamond")
    XCTAssertEqual(layout.offsets.x, -0.25, accuracy: 0.0001)
    XCTAssertEqual(layout.offsets.y, 0, accuracy: 0.0001)
    XCTAssertEqual(layout.offsets.z, 0.25, accuracy: 0.0001)
    XCTAssertEqual(layout.areas.r.min.x, -0.25, accuracy: 0.0001)
    XCTAssertEqual(layout.areas.b.max.x, 1.25, accuracy: 0.0001)
  }

  func testInvalidCustomJSONFallsBackToGrayscale() throws {
    let suiteName = "VectorSubpixelLayoutTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set(#"{"name":"bad","offsets":[0,0]}"#, forKey: VectorSubpixelLayout.defaultsKey)

    XCTAssertEqual(VectorSubpixelLayout.persisted(defaults: defaults), .grayscale)
  }
}
