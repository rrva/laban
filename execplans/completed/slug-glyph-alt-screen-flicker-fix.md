# Fix Slug Glyph Renderer Flickering in Fullscreen/Alternate-Screen TUIs

This ExecPlan defines the changes to resolve visual flickering in `SlugGlyphRenderer` under heavy rendering cadence and alternate screen usage (such as when running `claude` or other fullscreen TUIs).

## Purpose / Big Picture

Users running fullscreen terminal UIs (TUIs) like Claude Code report that the `SlugGlyphRenderer` exhibits visual flickering/shimmering. This plan fixes two main architectural issues in `SlugGlyphRenderer`:
1. **Unsafe target publication on skipped frames (Race Condition)**: When `render()` determines there is no effective damage, it skips GPU encoding and returns early. However, it immediately calls `publishLatestTarget(currentTarget)` on the main thread. If the previous frame's GPU command buffer is still in flight (very common under rapid TUI updates), this immediately publishes the texture and causes the display link thread to blit from it while the GPU is still writing to it, resulting in rendering races and flickering.
2. **Untracked default background color changes**: When alternate screens or themes switch background colors, the change in the clear color is not tracked by the renderer's configuration change detector. If `damage == .full` is not explicitly passed (e.g. dynamic color shifts), the slots in the 3-slot target ring don't perform a full redraw, leaving mismatched background colors in different slots that flash as the ring rotates.

After this change, skipped frames will not publish the target prematurely (they will let the active GPU completed handler publish it safely), and background color changes will force all slots to redraw fully, eliminating flickering.

## Progress

- [x] **M1: Fix skipped frame publication race condition**
- [x] **M2: Track clear color changes to force full redraws**

## Plan of Work

### Milestone 1: Fix skipped frame publication race condition

We will remove the unsafe `publishLatestTarget(currentTarget)` call from the `.skip` path of `SlugGlyphRenderer.render(_:damage:)`.

**Files to modify**:
- [SlugGlyphRenderer.swift](file:///Users/user/wrk/laban/Sources/LabanRenderer/SlugGlyphRenderer.swift)

**Description of change**:
In `SlugGlyphRenderer.render(_:damage:)`, replace the guard else block:
```swift
    guard case .render(let effectiveDamage, let slot, let ringRebuild) = outcome else {
      previousCursorRects = currentCursorRects
      snapshotConfigForNextFrame()
      if presentsToLayer, let currentTarget = targetTexture {
        publishLatestTarget(currentTarget)
      }
      onFrameCompleted?()
      return true
    }
```
with:
```swift
    guard case .render(let effectiveDamage, let slot, let ringRebuild) = outcome else {
      previousCursorRects = currentCursorRects
      snapshotConfigForNextFrame()
      onFrameCompleted?()
      return true
    }
```

### Milestone 2: Track clear color changes to force full redraws

We will store `previousClearColor` and check if the clear color changes between frames.

**Files to modify**:
- [SlugGlyphRenderer.swift](file:///Users/user/wrk/laban/Sources/LabanRenderer/SlugGlyphRenderer.swift)

**Description of change**:
1. Add `previousClearColor: MTLClearColor?` to the private state of `SlugGlyphRenderer`.
2. Update `configChangedSincePreviousFrame()` to accept the current `clearColor: MTLClearColor`:
```swift
  private func configChangedSincePreviousFrame(clearColor: MTLClearColor) -> Bool {
    guard let previousClearColor else { return true }
    return previousGestureZoom != gestureZoom
      || previousGestureZoomAnchor != gestureZoomAnchor
      || previousEffectiveSubpixelLayout != effectiveSubpixelLayout
      || previousTextWeight != textWeight
      || previousEmojiRenderingMode != emojiRenderingMode
      || previousClearColor.red != clearColor.red
      || previousClearColor.green != clearColor.green
      || previousClearColor.blue != clearColor.blue
      || previousClearColor.alpha != clearColor.alpha
  }
```
3. Update `snapshotConfigForNextFrame()` to accept and store the current `clearColor: MTLClearColor`:
```swift
  private func snapshotConfigForNextFrame(clearColor: MTLClearColor) {
    previousGestureZoom = gestureZoom
    previousGestureZoomAnchor = gestureZoomAnchor
    previousEffectiveSubpixelLayout = effectiveSubpixelLayout
    previousTextWeight = textWeight
    previousEmojiRenderingMode = emojiRenderingMode
    previousClearColor = clearColor
  }
```
4. In `resolveEffectiveDamage()`, pass the `clearColor` parameter and forward it:
```swift
  private func resolveEffectiveDamage(
    damage: RenderDamage,
    currentCursorRects: [CGRect],
    clearColor: MTLClearColor
  ) -> EffectiveDamageOutcome {
    let (slot, ringRebuild) = peekNextRingSlot()
    ensureSlotDamageStateSized(rebuild: ringRebuild)

    let forcesEveryone = ringRebuild || configChangedSincePreviousFrame(clearColor: clearColor) || damage == .full
    if forcesEveryone {
      for i in slotNeedsForceFull.indices { slotNeedsForceFull[i] = true }
    }
    // ...
```
5. In `render()`, compute `clearColor = Self.linearizedClearColor(commands)` at the very beginning and pass it to `resolveEffectiveDamage` and the updated snapshot helpers.

## Validation and Acceptance

1. **Verify all tests pass**:
   ```bash
   swift test --filter SlugGlyphDamageTests
   ```
2. **Run local check suite**:
   ```bash
   ./scripts/check
   ```
3. **Verify correct behavior**:
   Skipped frames no longer call `publishLatestTarget`, preventing race conditions. Background changes successfully trigger a full slot invalidate and redraw.
