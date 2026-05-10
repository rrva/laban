import CoreGraphics
import Foundation

enum TerminalResizeAutomation {
  struct Configuration: Equatable {
    var startDelaySeconds: TimeInterval
    var settleDelaySeconds: TimeInterval
    var steps: [CGSize]
    var autoQuit: Bool
  }

  static let defaultStepsRaw = "1200x788,960x640,1328x860,1040x700,1260x820,900x620"
  static let fallbackStep = CGSize(width: 1000, height: 680)

  static func configuration(environment: [String: String]) -> Configuration? {
    guard environment["LABAN_RESIZE_AUTOMATION"] == "1" else { return nil }
    return Configuration(
      startDelaySeconds: envDouble(
        "LABAN_RESIZE_START_DELAY_MS",
        fallback: 500,
        environment: environment) / 1000,
      settleDelaySeconds: envDouble(
        "LABAN_RESIZE_CAPTURE_DELAY_MS",
        fallback: 35,
        environment: environment) / 1000,
      steps: steps(from: environment["LABAN_RESIZE_STEPS"]),
      autoQuit: environment["LABAN_RESIZE_AUTO_QUIT"] == "1"
    )
  }

  static func envDouble(
    _ name: String,
    fallback: Double,
    environment: [String: String]
  ) -> Double {
    guard let raw = environment[name],
      let value = Double(raw)
    else { return fallback }
    return value
  }

  static func steps(from raw: String?) -> [CGSize] {
    let stepList = raw ?? defaultStepsRaw
    let parsed = stepList.split(separator: ",").compactMap { part -> CGSize? in
      let pieces = part.lowercased().split(separator: "x")
      guard pieces.count == 2,
        let width = Double(pieces[0]),
        let height = Double(pieces[1]),
        width > 0,
        height > 0
      else { return nil }
      return CGSize(width: width, height: height)
    }
    return parsed.isEmpty ? [fallbackStep] : parsed
  }
}
