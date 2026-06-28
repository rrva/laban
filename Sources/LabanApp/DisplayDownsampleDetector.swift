import AppKit
import CoreGraphics
import LabanRenderer

/// Detects whether the display a window lives on is in a macOS "scaled"
/// (downsampled) mode, where the framebuffer is rendered larger than the panel
/// and resampled down. Subpixel AA cannot survive that resample, so the result
/// feeds `VectorGlyphRenderer.setDisplayDownsampled` and the subpixel
/// auto-policy falls back to grayscale (see `VectorSubpixelLayout.effective`).
///
/// The signal is the panel's *native* display mode: macOS tags the 1:1 mode(s)
/// with `kDisplayModeNativeFlag`. Comparing the current mode's pixel size to the
/// native mode's pixel size tells us whether the framebuffer maps 1:1. (The
/// largest available mode is NOT native — "More Space" renders above native and
/// downscales — so the native flag, not the max, is the correct reference.)
enum DisplayDownsampleDetector {
  // CoreGraphics does not surface this publicly; it is stable across macOS.
  private static let nativeModeFlag: UInt32 = 0x0200_0000  // kDisplayModeNativeFlag

  /// Whether the given display is rendering downsampled. Returns false when the
  /// mode information is unavailable, leaving an opted-in subpixel layout intact
  /// rather than disabling it on a detection gap.
  static func isDownsampled(displayID: CGDirectDisplayID) -> Bool {
    guard let current = CGDisplayCopyDisplayMode(displayID) else { return false }
    guard let native = nativePixelSize(for: displayID) else { return false }
    return VectorSubpixelLayout.displayIsDownsampled(
      currentPixelWidth: current.pixelWidth,
      currentPixelHeight: current.pixelHeight,
      nativePixelWidth: native.width,
      nativePixelHeight: native.height)
  }

  /// Whether the display backing the window (or the main display, if the window
  /// is not yet on screen) is downsampled.
  static func isDownsampled(for window: NSWindow?) -> Bool {
    isDownsampled(displayID: displayID(for: window))
  }

  /// The native (1:1) pixel size of a display, from its native-flagged mode.
  /// Nil when no native-flagged mode is reported.
  static func nativePixelSize(for displayID: CGDirectDisplayID) -> (width: Int, height: Int)? {
    let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
    guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode]
    else { return nil }
    guard let native = modes.first(where: { ($0.ioFlags & nativeModeFlag) != 0 }) else {
      return nil
    }
    return (native.pixelWidth, native.pixelHeight)
  }

  private static func displayID(for window: NSWindow?) -> CGDirectDisplayID {
    let screen = window?.screen ?? NSScreen.main
    let key = NSDeviceDescriptionKey("NSScreenNumber")
    if let number = screen?.deviceDescription[key] as? NSNumber {
      return CGDirectDisplayID(number.uint32Value)
    }
    return CGMainDisplayID()
  }
}
