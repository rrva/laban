import CoreGraphics
import Foundation
import LabanTerminalCore
import LabanRenderer

// Converts a LabanSnapshot into a flat FrameCommand list for the terminal viewport.
// Uses standard CoreGraphics coordinates: (0,0) at bottom-left.
// Row 0 (topmost terminal row) maps to y = (rows-1) * cellHeight.
public struct FrameProducer {
    public let cellWidth: Int
    public let cellHeight: Int
    public let originX: CGFloat
    public let originY: CGFloat

    public init(
        cellWidth: Int = 8,
        cellHeight: Int = 16,
        originX: CGFloat = 0,
        originY: CGFloat = 0
    ) {
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.originX = originX
        self.originY = originY
    }

    // Caller owns the snapshot lifetime; FrameProducer does not retain it.
    public func commands(from snap: UnsafePointer<LabanSnapshot>) -> [FrameCommand] {
        let snapshot = snap.pointee
        let rows = Int(snapshot.rows)
        let cols = Int(snapshot.cols)
        let cw = CGFloat(cellWidth)
        let ch = CGFloat(cellHeight)

        var cmds: [FrameCommand] = []
        cmds.reserveCapacity(rows * cols * 2 + 4)

        // Terminal area background
        cmds.append(.rect(
            CGRect(x: originX, y: originY, width: CGFloat(cols) * cw, height: CGFloat(rows) * ch),
            color: Theme.SelenizedLight.bg0,
            source: .terminal
        ))

        guard rows > 0, cols > 0, let cells = snapshot.cells else { return cmds }

        // Per-cell commands
        for row in 0..<rows {
            let cellY = originY + CGFloat(rows - 1 - row) * ch

            for col in 0..<cols {
                let idx = row * cols + col
                let cell = cells[idx]
                let cellX = originX + CGFloat(col) * cw
                let cellRect = CGRect(x: cellX, y: cellY, width: cw, height: ch)

                // Cell background — always emitted so renderers can clear individually
                cmds.append(.rect(cellRect, color: cell.background_rgba, source: .terminal))

                // Glyph — only when UTF-8 content exists; text is copied verbatim (not substituted)
                if cell.utf8_length > 0, let storage = snapshot.utf8_storage {
                    let offset = Int(cell.utf8_offset)
                    let length = Int(cell.utf8_length)
                    let ptr: UnsafeRawPointer = UnsafeRawPointer(storage).advanced(by: offset)
                    let buf = UnsafeBufferPointer<UInt8>(
                        start: ptr.assumingMemoryBound(to: UInt8.self),
                        count: length
                    )
                    if let text = String(bytes: buf, encoding: .utf8), !text.isEmpty {
                        cmds.append(.glyphRun(
                            origin: CGPoint(x: cellX, y: cellY),
                            text: text,
                            foreground: cell.foreground_rgba,
                            background: cell.background_rgba,
                            source: .terminal
                        ))
                    }
                }
            }
        }

        // Cursor
        if snapshot.cursor_visible != 0,
           Int(snapshot.cursor_row) < rows,
           Int(snapshot.cursor_col) < cols
        {
            let cx = originX + CGFloat(snapshot.cursor_col) * cw
            let cy = originY + CGFloat(rows - 1 - Int(snapshot.cursor_row)) * ch
            cmds.append(.cursor(
                CGRect(x: cx, y: cy, width: cw, height: ch),
                color: Theme.SelenizedLight.cursor
            ))
        }

        return cmds
    }
}
