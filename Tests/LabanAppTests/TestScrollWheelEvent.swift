import AppKit

final class TestScrollWheelEvent: NSEvent {
  private let testLocationInWindow: NSPoint
  private let testDeltaY: CGFloat
  private let testScrollingDeltaY: CGFloat
  private let testHasPreciseScrollingDeltas: Bool
  private let testModifierFlags: NSEvent.ModifierFlags

  init(
    locationInWindow: NSPoint,
    deltaY: CGFloat,
    scrollingDeltaY: CGFloat = 0,
    hasPreciseScrollingDeltas: Bool = false,
    modifierFlags: NSEvent.ModifierFlags = []
  ) {
    testLocationInWindow = locationInWindow
    testDeltaY = deltaY
    testScrollingDeltaY = scrollingDeltaY
    testHasPreciseScrollingDeltas = hasPreciseScrollingDeltas
    testModifierFlags = modifierFlags
    super.init()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var type: NSEvent.EventType { .scrollWheel }
  override var locationInWindow: NSPoint { testLocationInWindow }
  override var deltaY: CGFloat { testDeltaY }
  override var scrollingDeltaY: CGFloat { testScrollingDeltaY }
  override var hasPreciseScrollingDeltas: Bool { testHasPreciseScrollingDeltas }
  override var modifierFlags: NSEvent.ModifierFlags { testModifierFlags }
}
