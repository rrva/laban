import Foundation

public struct MetalDrawableAcquireDiagnostic: Codable, Equatable, Sendable {
  public enum Outcome: String, Codable, Equatable, Sendable {
    case carried
    case activeRequest
    case timedOut
    case returnedNil
    case returnedDrawable
    case lateStashed
    case lateNil
  }

  public var outcome: Outcome
  public var budgetMs: Double
  public var elapsedMs: Double
  public var drawableRequestActiveBefore: Bool
  public var drawableRequestActiveAfter: Bool
  public var pendingDrawablePresentBefore: Bool
  public var pendingDrawablePresentAfter: Bool
  public var layerMaximumDrawableCount: Int
  public var layerAllowsNextDrawableTimeout: Bool
  /// Wall-clock latency of the most recent background `nextDrawable()` call
  /// (post → return), regardless of which acquire consumed the result. The
  /// discriminating metric for present-pipeline stalls: a sharp ~16.7 ms
  /// means drawable recycling is locked to display swaps at half rate; ~9-12
  /// ms means the GPU frame itself is the bottleneck.
  public var lastRequestLatencyMs: Double?

  public init(
    outcome: Outcome,
    budgetMs: Double,
    elapsedMs: Double,
    drawableRequestActiveBefore: Bool,
    drawableRequestActiveAfter: Bool,
    pendingDrawablePresentBefore: Bool,
    pendingDrawablePresentAfter: Bool,
    layerMaximumDrawableCount: Int,
    layerAllowsNextDrawableTimeout: Bool,
    lastRequestLatencyMs: Double? = nil
  ) {
    self.outcome = outcome
    self.budgetMs = budgetMs
    self.elapsedMs = elapsedMs
    self.drawableRequestActiveBefore = drawableRequestActiveBefore
    self.drawableRequestActiveAfter = drawableRequestActiveAfter
    self.pendingDrawablePresentBefore = pendingDrawablePresentBefore
    self.pendingDrawablePresentAfter = pendingDrawablePresentAfter
    self.layerMaximumDrawableCount = layerMaximumDrawableCount
    self.layerAllowsNextDrawableTimeout = layerAllowsNextDrawableTimeout
    self.lastRequestLatencyMs = lastRequestLatencyMs
  }
}
