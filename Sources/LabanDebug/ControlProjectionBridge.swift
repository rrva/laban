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
      })
  }
}
