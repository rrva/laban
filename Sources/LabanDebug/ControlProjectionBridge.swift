import Foundation
import LabanCore
import LabanRenderer
import LabanTerminalCore

extension HeadlessDebugRuntime {
  func controlProjectionContext(scopedSessionID: String? = nil) -> ControlProjectionContext {
    let runtime = self
    return ControlProjectionContext(
      model: model,
      mode: mode,
      frame: currentFrame,
      windowWidth: windowWidth,
      windowHeight: windowHeight,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      sidebarWidth: sidebarWidth,
      accessibilityDisplayFlags: accessibilityDisplayFlags,
      selectionBySession: selectionBySession,
      sessionClientInfoById: terminalClientSessionInfoById,
      transportMode: terminalSessionClient?.transportMode ?? terminalBackend.rawValue,
      scopedSessionID: scopedSessionID,
      clientSnapshotProvider: { sessionId in
        guard runtime.terminalSessionClient != nil else { return nil }
        return runtime.terminalClientSnapshotUnlocked(sessionId: sessionId)
      },
      accessibilityValueProvider: nil,
      glyphEffectsProvider: {
        guard let slug = runtime.rendererBackend as? SlugGlyphRenderer else { return nil }
        return GlyphEffectsStateResponse(
          active: slug.glyphEffectLiveCount > 0,
          liveCount: slug.glyphEffectLiveCount,
          lastKind: Int(slug.lastGlyphEffectKind),
          wakeCount: Int(slug.glyphEffectFrameCount))
      },
      spinnerMotionProvider: {
        let slug = runtime.rendererBackend as? SlugGlyphRenderer
        let motionCount = slug?.lastFrameMotionGlyphsCount ?? 0
        let activeTransitionCount = runtime.surfaceController.spinnerMotionActiveTransitionCount()
        let effectKind = Int(slug?.lastGlyphEffectKind ?? 0)

        return SpinnerMotionStateResponse(
          configured: SpinnerMotionSmoothingSettings.enabled,
          effectiveRenderer: runtime.rendererBackend.rendererStatus.effectiveRenderer,
          rendererEligible: runtime.rendererBackend is SlugGlyphRenderer,
          reduceMotion: runtime.accessibilityDisplayFlags.reduceMotion,
          effectiveEnabled: SpinnerMotionSmoothingSettings.enabled
            && runtime.rendererBackend is SlugGlyphRenderer
            && !runtime.accessibilityDisplayFlags.reduceMotion,
          activeTransitions: activeTransitionCount,
          analyticMotionInstances: motionCount,
          fallbackSnaps: slug?.lastFrameSpinnerFallbackSnapCount ?? 0,
          effectKind: effectKind,
          remainingSeconds: slug?.glyphEffectAnimatingRemainingSeconds ?? 0,
          liveEffectFrames: Int(slug?.glyphEffectFrameCount ?? 0))
      })
  }
}
