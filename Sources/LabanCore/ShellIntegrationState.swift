import Foundation

/// The shell lifecycle phase derived from OSC 133 ("semantic prompt")
/// markers emitted by the shell. See `docs/product/spec.md` §7 and the C
/// scanner in `Sources/LabanTerminalCore/osc133.c`.
///
/// - `idle`: no marker seen yet this session.
/// - `atPrompt`: the shell drew a prompt and is waiting for input
///   (OSC 133 A or B).
/// - `running`: a command is executing (OSC 133 C).
/// - `finished`: the last command finished (OSC 133 D); `lastExitCode`
///   holds its status when the shell reported one.
public enum ShellIntegrationPhase: String, Sendable, Equatable, Codable {
  case idle
  case atPrompt
  case running
  case finished
}

/// A single OSC 133 action delivered from the C scanner. Mirrors
/// `LabanOSC133Action` in `LabanTerminalCore.h`, restricted to the
/// A/B/C/D subset Laban consumes. `commandEnd` carries the exit code only
/// when the shell included one (`ESC ] 133 ; D ; <n> ST`).
public enum ShellIntegrationAction: Sendable, Equatable {
  case promptStart
  case promptEnd
  case commandStart
  case commandEnd(exitCode: Int?)
}

/// Reduces a stream of OSC 133 actions into a phase + last exit code.
///
/// The reducer is intentionally liberal: repeated `A`/`B` markers simply
/// keep the phase at `atPrompt`, and a `D` without a numeric argument
/// leaves `lastExitCode` unchanged from whatever the shell last reported
/// (a missing exit code means "finished, status unknown" — it must not
/// silently overwrite a real prior code). This makes the reducer robust to
/// shells (or duplicate integrations) that emit markers in slightly
/// different orders.
public struct ShellIntegrationState: Sendable, Equatable {
  public private(set) var phase: ShellIntegrationPhase
  public private(set) var lastExitCode: Int?
  /// Monotonic count of commands that have *finished* (OSC 133 D) this
  /// session. `lastExitCode` is a level that the reducer carries forward
  /// across later markers, so it cannot tell a fresh failure from a prompt
  /// re-emission of an old one; this counter gives each completion a distinct
  /// identity, which the failed-command dot uses to decide whether a non-zero
  /// exit is a *new*, still-unacknowledged failure (see `TabMetadataSynchronizer`).
  public private(set) var completedCommandCount: Int

  public init(
    phase: ShellIntegrationPhase = .idle,
    lastExitCode: Int? = nil,
    completedCommandCount: Int = 0
  ) {
    self.phase = phase
    self.lastExitCode = lastExitCode
    self.completedCommandCount = completedCommandCount
  }

  /// Apply one OSC 133 action, advancing the phase.
  public mutating func apply(_ action: ShellIntegrationAction) {
    switch action {
    case .promptStart, .promptEnd:
      phase = .atPrompt
    case .commandStart:
      phase = .running
    case .commandEnd(let exitCode):
      phase = .finished
      completedCommandCount += 1
      if let exitCode {
        lastExitCode = exitCode
      }
    }
  }
}
