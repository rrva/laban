import CoreGraphics

public enum FrameSource: String, Sendable {
    case sidebar
    case chrome
    case terminal
    case cursor
    case selection
    case image
}

public enum FrameCommand: Sendable {
    case rect(CGRect, color: UInt32, source: FrameSource)
    case glyphRun(origin: CGPoint, text: String, foreground: UInt32, background: UInt32, source: FrameSource)
    case cursor(CGRect, color: UInt32)
    case selection(CGRect, color: UInt32)
    case clip(CGRect)
    case texturedQuad(rect: CGRect, resourceId: UInt64, source: FrameSource)
}
