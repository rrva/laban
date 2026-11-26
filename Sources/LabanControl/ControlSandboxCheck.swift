import Darwin
import Foundation

/// Whether a process runs inside a macOS sandbox (Seatbelt, App Sandbox,
/// `sandbox-exec`). An in-session spawn skips the approval dialog only when no
/// process between the requester and its session shell is sandboxed: a new
/// terminal runs as a child of Laban, outside any sandbox, so a sandboxed agent
/// must not open one silently (ADR 0024, Amendment 2026-11-26).
public enum ControlSandboxCheck {
  private typealias SandboxCheck = @convention(c) (pid_t, UnsafePointer<CChar>?, Int32) -> Int32

  /// `sandbox_check(pid, NULL, SANDBOX_FILTER_NONE)`: 1 when sandboxed, 0 when
  /// not. An error or a missing symbol counts as sandboxed, so the caller falls
  /// back to the dialog instead of skipping it.
  public static func isSandboxed(_ pid: pid_t) -> Bool {
    guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "sandbox_check") else {
      return true
    }
    let check = unsafeBitCast(symbol, to: SandboxCheck.self)
    return check(pid, nil, 0) != 0
  }
}
