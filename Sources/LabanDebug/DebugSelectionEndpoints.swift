import CoreGraphics
import Foundation
import LabanCore
import LabanTerminalCore

extension HeadlessDebugRuntime {
  public func selection() -> DebugResponse {
    withRuntimeLock {
      let encoded = controlJSONEncode(
        ControlStateProjections.selectionResponse(controlProjectionContext()))
      return DebugResponse(status: encoded.status, body: encoded.body)
    }
  }

  public func clipboard() -> DebugResponse {
    withRuntimeLock {
      jsonEncode(
        ClipboardResponse(
          lastCopyText: lastCopyText,
          lastPasteText: lastPasteText,
          lastPasteUsedBracketedPaste: lastPasteUsedBracketedPaste,
          lastPasteIgnoredNonText: lastPasteIgnoredNonText
        ))
    }
  }
}
