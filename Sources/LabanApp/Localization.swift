import Foundation

/// User-facing strings for LabanApp, backed by `Localizable.xcstrings`.
enum L10n {
  static func tr(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
  }

  /// Deterministic English lookup for tests and diagnostics.
  static func trEn(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module, locale: Locale(identifier: "en"))
  }
}
