import Foundation
import LabanCore
import LabanRenderer
import LabanTerminalCore

extension HeadlessDebugRuntime {
  public func state() -> DebugResponse {
    withRuntimeLock {
      stateUnlocked()
    }
  }

  func stateUnlocked() -> DebugResponse {
    syncSessionMetadataUnlocked()
    let ctx = controlProjectionContext()
    return debugJSON(ControlStateProjections.stateResponse(ctx))
  }

  public func spinnerMotion() -> DebugResponse {
    withRuntimeLock {
      syncSessionMetadataUnlocked()
      let ctx = controlProjectionContext()
      if let response = ControlStateProjections.spinnerMotionResponse(ctx) {
        return debugJSON(response)
      }
      return jsonError("spinner motion state unavailable")
    }
  }

  public func hoverPreview() -> DebugResponse {
    withRuntimeLock {
      syncSessionMetadataUnlocked()
      let ctx = controlProjectionContext()
      if let response = ControlStateProjections.hoverPreviewResponse(ctx) {
        return debugJSON(response)
      }
      return jsonError("hover preview state unavailable")
    }
  }

  public func accessibility() -> DebugResponse {
    withRuntimeLock {
      syncSessionMetadataUnlocked()
      refreshTerminalClientSessionInfoUnlocked()
      return debugJSON(ControlStateProjections.accessibilityResponse(controlProjectionContext()))
    }
  }

  public func terminalModes() -> DebugResponse {
    withRuntimeLock {
      syncSessionMetadataUnlocked()
      return debugJSON(ControlStateProjections.terminalModesResponse(controlProjectionContext()))
    }
  }

  public func sessions() -> DebugResponse {
    withRuntimeLock {
      syncSessionMetadataUnlocked()
      refreshTerminalClientSessionInfoUnlocked()
      return debugJSON(ControlStateProjections.sessionsResponse(controlProjectionContext()))
    }
  }

  func findStateResponsesUnlocked() -> [String: FindStateResponse] {
    ControlStateProjections.findStateResponses(controlProjectionContext())
  }

  static func findStateResponse(_ state: TerminalFindState) -> FindStateResponse {
    ControlStateProjections.findStateResponse(state)
  }

  public func session(id: String, query: [String: String]) -> DebugResponse {
    withRuntimeLock {
      syncSessionMetadataUnlocked()
      refreshTerminalClientSessionInfoUnlocked()
      let response = ControlStateProjections.sessionResponse(
        id: id, query: query, ctx: controlProjectionContext())
      return DebugResponse(status: response.status, body: response.body)
    }
  }

  func syncSessionMetadataUnlocked() {
    _ = surfaceController.syncSessions(
      captureFrame: currentFrame + 1,
      polling: .pollAllSessions,
      markInactiveDirtyRendered: false,
      noteOutputOnDirty: false)
  }

  private func debugJSON<T: Encodable>(_ value: T, status: Int = 200) -> DebugResponse {
    let encoded = controlJSONEncode(value, status: status)
    return DebugResponse(status: encoded.status, body: encoded.body)
  }

  func emojiRenderingSettingsResponse() -> EmojiRenderingSettingsResponse {
    let mode = EmojiRenderingSettings.current().rawValue
    return EmojiRenderingSettingsResponse(mode: mode, effectiveMode: mode)
  }
}
