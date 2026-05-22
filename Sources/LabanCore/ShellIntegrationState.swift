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
public enum ShellIntegrationPhase: String, Sendable, Equatable {
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

  public init(phase: ShellIntegrationPhase = .idle, lastExitCode: Int? = nil) {
    self.phase = phase
    self.lastExitCode = lastExitCode
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
      if let exitCode {
        lastExitCode = exitCode
      }
    }
  }
}
