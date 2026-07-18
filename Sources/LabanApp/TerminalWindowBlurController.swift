import AppKit
import Darwin

/// Applies Terminal.app-style tint-free blur to a window's translucent pixels.
///
/// The configurable-radius CGS entrypoint is private, so it is resolved at
/// runtime instead of linked into the app. Tests inject a setter; production
/// keeps the loaded framework handle alive for the lifetime of the process.
@MainActor
final class TerminalWindowBlurController {
  typealias SetBlurRadius = (_ windowNumber: Int, _ radius: Int32) -> Int32

  private let setBlurRadius: SetBlurRadius?

  private(set) var appliedRadius: Int?

  var isAvailable: Bool {
    setBlurRadius != nil
  }

  init(
    setBlurRadius: SetBlurRadius? = TerminalWindowBlurController.resolveSetBlurRadius()
  ) {
    self.setBlurRadius = setBlurRadius
  }

  /// Applies a 0...100 radius. A zero radius is the explicit reset used when
  /// None, Image, full screen, or an accessibility override disables blur.
  @discardableResult
  func apply(radius: Int, to window: NSWindow) -> Bool {
    guard let setBlurRadius else {
      appliedRadius = nil
      return false
    }
    let clampedRadius = min(100, max(0, radius))
    let status = setBlurRadius(window.windowNumber, Int32(clampedRadius))
    guard status == 0 else {
      appliedRadius = nil
      return false
    }
    appliedRadius = clampedRadius
    return true
  }

  private nonisolated static func resolveSetBlurRadius() -> SetBlurRadius? {
    typealias DefaultConnectionFunction = @convention(c) () -> UnsafeMutableRawPointer?
    typealias SetBlurRadiusFunction =
      @convention(c) (
        UnsafeMutableRawPointer?, Int, Int32
      ) -> Int32

    let frameworkPaths = [
      "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
      "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
    ]
    for path in frameworkPaths {
      guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL),
        let connectionSymbol = dlsym(handle, "CGSDefaultConnectionForThread"),
        let setterSymbol = dlsym(handle, "CGSSetWindowBackgroundBlurRadius")
      else { continue }

      let connectionFunction = unsafeBitCast(
        connectionSymbol,
        to: DefaultConnectionFunction.self)
      guard let connection = connectionFunction() else { continue }
      let setter = unsafeBitCast(setterSymbol, to: SetBlurRadiusFunction.self)
      return { windowNumber, radius in
        setter(connection, windowNumber, radius)
      }
    }
    return nil
  }
}
