import Foundation
import LabanTerminalCore

public enum SessionError: Error {
  case createFailed
}

public final class Session {
  public typealias ID = String

  public let id: ID
  private var handle: OpaquePointer?
  public private(set) var isClosed = false

  public init(config: inout LabanLaunchConfig, size: LabanTerminalSize) throws {
    self.id = UUID().uuidString
    var h: OpaquePointer?
    guard laban_session_create(&config, size, &h) == 0, let h else {
      throw SessionError.createFailed
    }
    self.handle = h
  }

  public static func fixture(size: LabanTerminalSize) throws -> Session {
    var config = LabanLaunchConfig()
    config.fixture_mode = 1
    return try Session(config: &config, size: size)
  }

  public static func realShell(size: LabanTerminalSize) throws -> Session {
    var config = LabanLaunchConfig()
    config.fixture_mode = 0
    return try Session(config: &config, size: size)
  }

  public func close() {
    guard !isClosed else { return }
    isClosed = true
    if let h = handle {
      laban_session_destroy(h)
      handle = nil
    }
  }

  deinit { close() }

  @discardableResult
  public func poll() -> Int32 {
    guard !isClosed, let h = handle else { return -1 }
    return laban_session_poll(h)
  }

  @discardableResult
  public func resize(_ size: LabanTerminalSize) -> Int32 {
    guard !isClosed, let h = handle else { return -1 }
    return laban_session_resize(h, size)
  }

  @discardableResult
  public func write(_ bytes: [UInt8]) -> Int32 {
    guard !isClosed, let h = handle else { return -1 }
    if bytes.isEmpty { return 0 }
    return bytes.withUnsafeBytes { buf in
      laban_session_write(h, buf.baseAddress!.assumingMemoryBound(to: UInt8.self), bytes.count)
    }
  }

  /// Feed bytes directly into the VT parser, bypassing the PTY.
  /// Used to inject OSC palette sequences at session startup.
  @discardableResult
  public func feedOutput(_ bytes: [UInt8]) -> Int32 {
    guard !isClosed, let h = handle else { return -1 }
    if bytes.isEmpty { return 0 }
    return bytes.withUnsafeBytes { buf in
      laban_session_feed_output(
        h, buf.baseAddress!.assumingMemoryBound(to: UInt8.self), bytes.count)
    }
  }

  public func snapshot() -> UnsafeMutablePointer<LabanSnapshot>? {
    guard !isClosed, let h = handle else { return nil }
    var snap: UnsafeMutablePointer<LabanSnapshot>?
    guard laban_session_snapshot(h, &snap) == 0 else { return nil }
    return snap
  }

  /// Returns true if the session has unrendered terminal changes.
  /// Returns false on C failure or closed session; the frame loop
  /// should treat C failure as non-fatal and retry on the next tick.
  public func renderDirty() -> Bool {
    guard !isClosed, let h = handle else { return false }
    var dirty: Int32 = 0
    guard laban_session_render_dirty(h, &dirty) == 0 else { return false }
    return dirty != 0
  }

  /// Mark the session as fully rendered (clears global and row dirty flags).
  /// Returns -1 on C failure, 0 on success.
  @discardableResult
  public func markRendered() -> Int32 {
    guard !isClosed, let h = handle else { return -1 }
    return laban_session_mark_rendered(h)
  }

  // MARK: - PTY-byte capture

  /// Mirror every byte fed to the VT parser into `path` until `stopCapture()`
  /// is called. Existing file contents are overwritten. Returns true on
  /// success.
  @discardableResult
  public func startCapture(path: String) -> Bool {
    guard !isClosed, let h = handle else { return false }
    return path.withCString { laban_session_capture_start(h, $0) == 0 }
  }

  @discardableResult
  public func stopCapture() -> Bool {
    guard !isClosed, let h = handle else { return false }
    return laban_session_capture_stop(h) == 0
  }

  public var isCapturing: Bool {
    guard !isClosed, let h = handle else { return false }
    return laban_session_capture_active(h) != 0
  }

  // MARK: - Title

  /// Consume any pending title-changed notification from the C layer.
  /// Returns (dirty: true, raw: String?) when a title change was pending and
  /// its raw bytes were copied; returns (false, nil) when nothing changed.
  public func consumeTitle() -> (dirty: Bool, raw: String?) {
    guard !isClosed, let h = handle else { return (false, nil) }
    var buf = [CChar](repeating: 0, count: 1024)
    let r = buf.withUnsafeMutableBufferPointer { ptr in
      laban_session_consume_title(h, ptr.baseAddress, ptr.count)
    }
    guard r > 0 else { return (false, nil) }
    let raw = String(cString: buf)
    return (true, raw.isEmpty ? nil : raw)
  }

  // MARK: - Viewport scrolling

  /// Scroll the terminal viewport by deltaRows relative to the current offset.
  /// Negative values scroll toward older history; positive values scroll toward
  /// the active bottom. Returns 0 on success.
  @discardableResult
  public func scrollViewport(deltaRows: Int) -> Int32 {
    guard !isClosed, let h = handle else { return -1 }
    return laban_session_scroll_viewport(h, Int32(deltaRows))
  }

  /// Returns the current viewport state (scrollback rows, offset, mouse tracking, etc.),
  /// or nil if the session is closed or the C call fails.
  public func viewportState() -> ViewportState? {
    guard !isClosed, let h = handle else { return nil }
    var vs = LabanViewportState()
    guard laban_session_viewport_state(h, &vs) == 0 else { return nil }
    return ViewportState(from: vs)
  }

  // MARK: - Mouse encoding

  /// Encode a mouse event into terminal escape bytes using libghostty's mouse encoder.
  /// Returns nil if the session is closed, the C call fails, or if mouse tracking is
  /// disabled (the encoder returns zero bytes).
  public func encodeMouse(_ event: MouseEvent) -> [UInt8]? {
    guard !isClosed, let h = handle else { return nil }
    var raw = event.toLabanMouseEvent()
    var buf = [UInt8](repeating: 0, count: 64)
    var outLen: size_t = 0
    guard laban_session_encode_mouse(h, &raw, &buf, buf.count, &outLen) == 0 else { return nil }
    guard outLen > 0 else { return nil }
    return Array(buf.prefix(Int(outLen)))
  }

  /// Encode and send a mouse event through the PTY. Returns 0 on success.
  /// In fixture mode, this is a no-op that returns 0.
  @discardableResult
  public func sendMouse(_ event: MouseEvent) -> Int32 {
    guard !isClosed, let h = handle else { return -1 }
    var raw = event.toLabanMouseEvent()
    return laban_session_send_mouse(h, &raw)
  }

  // MARK: - Paste

  public func bracketedPasteEnabled() -> Bool {
    guard !isClosed, let h = handle else { return false }
    var enabled: Int32 = 0
    guard laban_session_bracketed_paste_enabled(h, &enabled) == 0 else { return false }
    return enabled != 0
  }

  public struct PasteWriteResult: Equatable, Sendable {
    public var bracketed: Bool
    public var bytesWritten: Int
  }

  @discardableResult
  public func writePaste(_ text: String) -> PasteWriteResult? {
    guard !isClosed, let h = handle else { return nil }
    let bytes = Array(text.utf8)
    if bytes.isEmpty {
      return PasteWriteResult(bracketed: bracketedPasteEnabled(), bytesWritten: 0)
    }
    var raw = LabanPasteResult()
    let r = bytes.withUnsafeBytes { buf in
      laban_session_write_paste(
        h,
        buf.baseAddress!.assumingMemoryBound(to: UInt8.self),
        bytes.count,
        &raw
      )
    }
    guard r == 0 else { return nil }
    return PasteWriteResult(bracketed: raw.bracketed != 0, bytesWritten: raw.bytes_written)
  }
}

// MARK: - Viewport state

public struct ViewportState {
  public let totalRows: Int
  public let scrollbackRows: Int
  public let viewportOffset: Int
  public let viewportRows: Int
  public let mouseTracking: Bool

  init(from raw: LabanViewportState) {
    totalRows = Int(raw.total_rows)
    scrollbackRows = Int(raw.scrollback_rows)
    viewportOffset = Int(raw.viewport_offset)
    viewportRows = Int(raw.viewport_rows)
    mouseTracking = raw.mouse_tracking != 0
  }
}

// MARK: - Mouse types

public enum MouseAction: Int {
  case press = 0
  case release = 1
  case motion = 2
}

public enum MouseButton: Int {
  case none = 0
  case left = 1
  case middle = 2
  case right = 3
  case wheelUp = 4
  case wheelDown = 5
}

public struct MouseEvent {
  public var action: MouseAction
  public var button: MouseButton
  public var x: Float
  public var y: Float
  public var screenWidth: Int
  public var screenHeight: Int
  public var cellWidth: Int
  public var cellHeight: Int
  public var modifiers: Int

  public init(
    action: MouseAction,
    button: MouseButton,
    x: Float,
    y: Float,
    screenWidth: Int,
    screenHeight: Int,
    cellWidth: Int,
    cellHeight: Int,
    modifiers: Int = 0
  ) {
    self.action = action
    self.button = button
    self.x = x
    self.y = y
    self.screenWidth = screenWidth
    self.screenHeight = screenHeight
    self.cellWidth = cellWidth
    self.cellHeight = cellHeight
    self.modifiers = modifiers
  }

  func toLabanMouseEvent() -> LabanMouseEvent {
    var raw = LabanMouseEvent()
    switch action {
    case .press: raw.action = LABAN_MOUSE_ACTION_PRESS
    case .release: raw.action = LABAN_MOUSE_ACTION_RELEASE
    case .motion: raw.action = LABAN_MOUSE_ACTION_MOTION
    }
    switch button {
    case .none: raw.button = LABAN_MOUSE_BUTTON_NONE
    case .left: raw.button = LABAN_MOUSE_BUTTON_LEFT
    case .middle: raw.button = LABAN_MOUSE_BUTTON_MIDDLE
    case .right: raw.button = LABAN_MOUSE_BUTTON_RIGHT
    case .wheelUp: raw.button = LABAN_MOUSE_BUTTON_WHEEL_UP
    case .wheelDown: raw.button = LABAN_MOUSE_BUTTON_WHEEL_DOWN
    }
    raw.x = x
    raw.y = y
    raw.screen_width = Int32(screenWidth)
    raw.screen_height = Int32(screenHeight)
    raw.cell_width = Int32(cellWidth)
    raw.cell_height = Int32(cellHeight)
    raw.modifiers = Int32(modifiers)
    return raw
  }
}
