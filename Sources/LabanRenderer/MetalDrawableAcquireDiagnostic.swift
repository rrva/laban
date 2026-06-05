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

  public init(
    outcome: Outcome,
    budgetMs: Double,
    elapsedMs: Double,
    drawableRequestActiveBefore: Bool,
    drawableRequestActiveAfter: Bool,
    pendingDrawablePresentBefore: Bool,
    pendingDrawablePresentAfter: Bool,
    layerMaximumDrawableCount: Int,
    layerAllowsNextDrawableTimeout: Bool
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
  }
}
