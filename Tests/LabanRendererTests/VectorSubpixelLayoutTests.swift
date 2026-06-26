import XCTest

@testable import LabanRenderer

final class VectorSubpixelLayoutTests: XCTestCase {
  func testPersistedPresetDefaultsToGrayscaleAndStoresStripePresets() throws {
    let suiteName = "VectorSubpixelLayoutTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    XCTAssertEqual(VectorSubpixelLayout.persistedPreset(defaults: defaults), .grayscale)
    XCTAssertEqual(VectorSubpixelLayout.persisted(defaults: defaults), .grayscale)

    VectorSubpixelLayout.setPersistedPreset(.rgbStripe, defaults: defaults)

    XCTAssertEqual(VectorSubpixelLayout.persistedPreset(defaults: defaults), .rgbStripe)
    XCTAssertEqual(VectorSubpixelLayout.persisted(defaults: defaults), .rgbStripe)

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
  }

  func testInvalidCustomJSONFallsBackToGrayscale() throws {
    let suiteName = "VectorSubpixelLayoutTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set(#"{"name":"bad","offsets":[0,0]}"#, forKey: VectorSubpixelLayout.defaultsKey)

    XCTAssertEqual(VectorSubpixelLayout.persisted(defaults: defaults), .grayscale)
  }
}
