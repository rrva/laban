import Foundation

/// User-facing strings for LabanApp, backed by `Localizable.xcstrings`.
enum L10n {
  static func tr(_ key: String.LocalizationValue) -> String {
    if let preferred = Bundle.main.preferredLocalizations.first {
      return String(
        localized: key, bundle: LabanAppResources.bundle,
        locale: Locale(identifier: preferred))
    }
    return String(localized: key, bundle: LabanAppResources.bundle)
  }

  /// Deterministic English lookup for tests and diagnostics.
  static func trEn(_ key: String.LocalizationValue) -> String {
    String(
      localized: key, bundle: LabanAppResources.bundle, locale: Locale(identifier: "en"))
  }
}
