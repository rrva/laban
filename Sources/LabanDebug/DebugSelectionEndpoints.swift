import CoreGraphics
import Foundation
import LabanTerminalCore

extension HeadlessDebugRuntime {
  public func selection() -> DebugResponse {
    withRuntimeLock {
      guard let tab = model.activeTab, let session = model.session(forTab: tab.id) else {
        return jsonEncode(
          SelectionResponse(
            active: false, sessionId: nil, anchor: nil, focus: nil, rects: [], text: ""))
      }

      guard let selection = selectionBySession[session.id] else {
        return jsonEncode(
          SelectionResponse(
            active: false,
            sessionId: tab.sessionId,
            anchor: nil,
            focus: nil,
            rects: [],
            text: ""))
      }

      var rects: [RectResponse] = []
      var text = ""

      if let snapshot = session.snapshot() {
        defer { laban_snapshot_destroy(snapshot) }
        let rows = Int(snapshot.pointee.rows)
        let cols = Int(snapshot.pointee.cols)
        for rect in selection.cgRects(
          rows: rows,
          cols: cols,
          cellWidth: CGFloat(cellWidth),
          cellHeight: CGFloat(cellHeight),
          originX: CGFloat(sidebarWidth),
          originY: 0
        ) {
          rects.append(DebugFrameCommandSerializer.rectResponse(rect))
        }
        if let viewportState = session.viewportState() {
          text = selection.selectedText(
            from: session,
            viewportSnapshot: snapshot.pointee,
            viewportState: viewportState
          )
        } else {
          text = selection.selectedText(from: snapshot.pointee)
        }
      }

      return jsonEncode(
        SelectionResponse(
          active: true,
          sessionId: tab.sessionId,
          anchor: CellCoordResponse(row: selection.anchor.row, col: selection.anchor.col),
          focus: CellCoordResponse(row: selection.focus.row, col: selection.focus.col),
          rects: rects,
          text: text
        ))
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
