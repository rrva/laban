import XCTest

@testable import LabanApp
@testable import LabanRenderer

/// `vectorGlyph` is retired (ADR 0033): at rest it gave every first-seen glyph
/// the full 512-sample accumulation with no per-frame budget, so first-painting
/// an unfamiliar screen — a tab switch — could encode seconds of GPU compute
/// into one command buffer (measured at 9.67 s). That frame holds the
/// one-frame-in-flight slot and, because the publish happens in its completion
/// handler, the window keeps showing the previous tab.
///
/// Every install predating ADR 0032 persisted `vectorGlyph`, because a stored
/// choice always beats the default. Migration is what actually moves those users.
final class RetiredRendererMigrationTests: XCTestCase {
  private let key = RendererSelection.defaultsKey

  private func defaults(_ name: String) -> UserDefaults {
    let suite = "laban-retired-renderer-\(name)-\(getpid())"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    return d
  }

  func testPersistedVectorGlyphMigratesToSlug() {
    let d = defaults("persisted")
    d.set(RendererSelection.vectorGlyph.rawValue, forKey: key)
    XCTAssertEqual(RendererSelection.persisted(defaults: d), .slugGlyph)
  }

  /// Migration must not rewrite anyone else's choice — someone on classic or
  /// software stays there.
  func testOtherPersistedSelectionsAreUntouched() {
    for selection: RendererSelection in [.software, .classic, .slugGlyph] {
      let d = defaults("keep-\(selection.rawValue)")
      d.set(selection.rawValue, forKey: key)
      XCTAssertEqual(RendererSelection.persisted(defaults: d), selection, selection.rawValue)
    }
  }

  /// Writing it back must migrate too, so nothing can re-persist a retired
  /// renderer through the menu/settings path.
  func testSettingVectorGlyphStoresSlugInstead() {
    let d = defaults("set")
    RendererSelection.set(.vectorGlyph, defaults: d)
    XCTAssertEqual(d.string(forKey: key), RendererSelection.slugGlyph.rawValue)
    XCTAssertEqual(RendererSelection.persisted(defaults: d), .slugGlyph)
  }

  /// No picker or menu may offer it. The case itself stays so an old persisted
  /// value still decodes and the fidelity harnesses can instantiate the backend.
  func testRetiredRendererIsNotSelectableButStillDecodes() {
    XCTAssertFalse(RendererSelection.selectableCases.contains(.vectorGlyph))
    XCTAssertTrue(RendererSelection.allCases.contains(.vectorGlyph))
    XCTAssertEqual(RendererSelection(rawValue: "vectorGlyph"), .vectorGlyph)
    for selection in RendererSelection.selectableCases {
      XCTAssertEqual(
        RendererSelection.migratingRetired(selection), selection,
        "\(selection.rawValue) is selectable so it must not migrate")
    }
  }

  /// Migration is idempotent — a migrated value re-read stays put.
  func testMigrationIsIdempotent() {
    let d = defaults("idempotent")
    d.set(RendererSelection.vectorGlyph.rawValue, forKey: key)
    let once = RendererSelection.persisted(defaults: d)
    RendererSelection.set(once, defaults: d)
    XCTAssertEqual(RendererSelection.persisted(defaults: d), .slugGlyph)
  }
}
