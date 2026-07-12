import AppKit
import Foundation
import LabanRenderer
import ScreenCaptureKit

struct LabanWindowScreenshot: Equatable {
  var pngData: Data
  var width: Int
  var height: Int
}

/// Why `LabanWindowScreenshotCapture.capture` produced no image. Kept distinct
/// from a generic failure so the control-plane response (and the agent reading
/// it) can tell "go grant Screen Recording" apart from "transient capture
/// glitch, retry".
enum LabanWindowScreenshotFailure: Error, Equatable {
  case permissionDenied
  case captureFailed
}

enum LabanWindowScreenshotCapture {
  struct RelatedNode<ID: Hashable> {
    var id: ID
    var parentID: ID?
    var isVisible: Bool
    var order: Int
  }

  static let maxPNGBytes = 10 * 1024 * 1024

  // Completion-handler round trips to WindowServer/ScreenCaptureKit can, in
  // principle, be redelivered on the calling (main) thread; a bounded wait
  // turns a would-be deadlock into a clean captureFailed instead of freezing
  // the GUI.
  private static let asyncBridgeTimeout: TimeInterval = 5

  /// `CGWindowListCreateImage`/`CGImage(windowListFromArrayScreenBounds:...)`
  /// is obsolete starting macOS 15 and reliably returns nil there even with
  /// Screen Recording granted, so macOS 14+ must go through ScreenCaptureKit.
  /// macOS 14.4+ additionally exposes `SCShareableContent.currentProcess`,
  /// which enumerates only this process's own windows without requiring Screen
  /// Recording consent at all (Laban only ever screenshots its own window),
  /// removing the TCC/ad-hoc-signing fragility entirely for the common case.
  static func capture(
    window: NSWindow,
    including auxiliaryWindows: [NSWindow] = []
  ) -> Result<LabanWindowScreenshot, LabanWindowScreenshotFailure> {
    let windowIDs = relatedWindowIDs(for: window, including: auxiliaryWindows)
    guard !windowIDs.isEmpty else {
      EventLog.shared.log("screenshot.capture.failed", ["reason": "noRelatedWindowIDs"])
      return .failure(.captureFailed)
    }
    if #available(macOS 14.4, *) {
      return captureUsingScreenCaptureKit(
        window: window, windowIDs: windowIDs, useCurrentProcessScope: true)
    }
    if #available(macOS 14.0, *) {
      guard ensureScreenCaptureAccess() else { return .failure(.permissionDenied) }
      return captureUsingScreenCaptureKit(
        window: window, windowIDs: windowIDs, useCurrentProcessScope: false)
    }
    guard ensureScreenCaptureAccess() else { return .failure(.permissionDenied) }
    return captureUsingLegacyCGWindowList(windowIDs: windowIDs)
  }

  private static func ensureScreenCaptureAccess() -> Bool {
    if CGPreflightScreenCaptureAccess() { return true }
    guard CGRequestScreenCaptureAccess() else {
      EventLog.shared.log("screenshot.capture.failed", ["reason": "permissionDenied"])
      return false
    }
    return true
  }

  @available(macOS 14.0, *)
  private static func captureUsingScreenCaptureKit(
    window: NSWindow,
    windowIDs: [CGWindowID],
    useCurrentProcessScope: Bool
  ) -> Result<LabanWindowScreenshot, LabanWindowScreenshotFailure> {
    guard let content = synchronousShareableContent(currentProcessOnly: useCurrentProcessScope)
    else {
      EventLog.shared.log("screenshot.capture.failed", ["reason": "noShareableContent"])
      return .failure(.captureFailed)
    }
    let windowIDSet = Set(windowIDs)
    let matchedWindows = content.windows.filter { windowIDSet.contains($0.windowID) }
    guard let firstWindow = matchedWindows.first else {
      EventLog.shared.log(
        "screenshot.capture.failed",
        [
          "reason": "noShareableWindows",
          "windowIDs": windowIDs.map(String.init).joined(separator: ","),
        ])
      return .failure(.captureFailed)
    }
    guard let display = content.displays.first else {
      EventLog.shared.log("screenshot.capture.failed", ["reason": "noShareableDisplay"])
      return .failure(.captureFailed)
    }
    let unionFrame = matchedWindows.dropFirst().reduce(firstWindow.frame) { $0.union($1.frame) }
    guard unionFrame.width > 0, unionFrame.height > 0 else {
      EventLog.shared.log("screenshot.capture.failed", ["reason": "emptyUnionFrame"])
      return .failure(.captureFailed)
    }
    let filter = SCContentFilter(display: display, including: matchedWindows)
    let configuration = SCStreamConfiguration()
    let scale = window.backingScaleFactor
    configuration.sourceRect = unionFrame
    configuration.width = max(1, Int((unionFrame.width * scale).rounded()))
    configuration.height = max(1, Int((unionFrame.height * scale).rounded()))
    configuration.showsCursor = false

    guard let image = synchronousCaptureImage(filter: filter, configuration: configuration) else {
      EventLog.shared.log(
        "screenshot.capture.failed",
        ["reason": "cgImageNil", "windowIDs": windowIDs.map(String.init).joined(separator: ",")])
      return .failure(.captureFailed)
    }
    return encodePNG(image: image)
  }

  @available(macOS 14.0, *)
  private static func synchronousShareableContent(currentProcessOnly: Bool) -> SCShareableContent? {
    let box = ShareableContentBox()
    let semaphore = DispatchSemaphore(value: 0)
    if currentProcessOnly, #available(macOS 14.4, *) {
      SCShareableContent.getCurrentProcessShareableContent { content, _ in
        box.set(content)
        semaphore.signal()
      }
    } else {
      SCShareableContent.getExcludingDesktopWindows(
        false, onScreenWindowsOnly: true
      ) { content, _ in
        box.set(content)
        semaphore.signal()
      }
    }
    _ = semaphore.wait(timeout: .now() + asyncBridgeTimeout)
    return box.get()
  }

  @available(macOS 14.0, *)
  private static func synchronousCaptureImage(
    filter: SCContentFilter, configuration: SCStreamConfiguration
  ) -> CGImage? {
    let box = CapturedImageBox()
    let semaphore = DispatchSemaphore(value: 0)
    SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) {
      image, _ in
      box.set(image)
      semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + asyncBridgeTimeout)
    return box.get()
  }

  private static func captureUsingLegacyCGWindowList(
    windowIDs: [CGWindowID]
  ) -> Result<LabanWindowScreenshot, LabanWindowScreenshotFailure> {
    let numbers = windowIDs.map { NSNumber(value: $0) }
    guard
      let image = CGImage(
        windowListFromArrayScreenBounds: .null,
        windowArray: numbers as CFArray,
        imageOption: [.boundsIgnoreFraming, .bestResolution])
    else {
      EventLog.shared.log(
        "screenshot.capture.failed",
        ["reason": "cgImageNil", "windowIDs": windowIDs.map(String.init).joined(separator: ",")])
      return .failure(.captureFailed)
    }
    return encodePNG(image: image)
  }

  private static func encodePNG(
    image: CGImage
  ) -> Result<LabanWindowScreenshot, LabanWindowScreenshotFailure> {
    guard
      let pngData = PNGEncoder.encode(image),
      !pngData.isEmpty,
      pngData.count <= maxPNGBytes
    else {
      EventLog.shared.log(
        "screenshot.capture.failed",
        ["reason": "pngEncodeFailed", "width": image.width, "height": image.height])
      return .failure(.captureFailed)
    }
    return .success(
      LabanWindowScreenshot(
        pngData: pngData,
        width: image.width,
        height: image.height))
  }

  static func relatedWindowIDs(
    for root: NSWindow,
    including auxiliaryWindows: [NSWindow] = []
  ) -> [CGWindowID] {
    var candidates: [NSWindow] = []
    var seen: Set<ObjectIdentifier> = []

    func collect(_ window: NSWindow) {
      let identity = ObjectIdentifier(window)
      guard seen.insert(identity).inserted else { return }
      candidates.append(window)
      for sheet in window.sheets {
        collect(sheet)
      }
      for child in window.childWindows ?? [] {
        collect(child)
      }
    }

    let roots = [root] + auxiliaryWindows.filter(\.isVisible)
    for window in roots {
      collect(window)
    }

    // Some AppKit panels are associated by sheetParent/parent but are not in
    // the immediate child list during transition frames. Include only visible
    // descendants of this root, never unrelated app windows.
    let orderedWindows = NSApp.orderedWindows
    for candidate in orderedWindows {
      collect(candidate)
    }

    let order = Dictionary(
      uniqueKeysWithValues: orderedWindows.enumerated().map {
        (ObjectIdentifier($0.element), $0.offset)
      })
    let nodes = candidates.map { window in
      RelatedNode(
        id: ObjectIdentifier(window),
        parentID: (window.sheetParent ?? window.parent).map(ObjectIdentifier.init),
        isVisible: window.isVisible,
        order: order[ObjectIdentifier(window)] ?? Int.max)
    }
    let windowsByID = Dictionary(
      uniqueKeysWithValues: candidates.map { (ObjectIdentifier($0), $0) })

    return relatedIDs(rootIDs: Set(roots.map(ObjectIdentifier.init)), nodes: nodes)
      .compactMap { identity in
        guard let window = windowsByID[identity] else { return nil }
        guard window.windowNumber > 0 else { return nil }
        return CGWindowID(window.windowNumber)
      }
  }

  static func relatedIDs<ID: Hashable>(
    rootID: ID,
    nodes: [RelatedNode<ID>]
  ) -> [ID] {
    relatedIDs(rootIDs: [rootID], nodes: nodes)
  }

  static func relatedIDs<ID: Hashable>(
    rootIDs: Set<ID>,
    nodes: [RelatedNode<ID>]
  ) -> [ID] {
    let nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })

    func descendsFromRoot(_ node: RelatedNode<ID>) -> Bool {
      if rootIDs.contains(node.id) { return true }
      guard node.isVisible else { return false }
      var ancestorID = node.parentID
      var visited: Set<ID> = [node.id]
      while let currentID = ancestorID, visited.insert(currentID).inserted {
        if rootIDs.contains(currentID) { return true }
        ancestorID = nodesByID[currentID]?.parentID
      }
      return false
    }

    return
      nodes
      .filter(descendsFromRoot)
      .sorted { lhs, rhs in lhs.order < rhs.order }
      .map(\.id)
  }
}

@available(macOS 14.0, *)
private final class ShareableContentBox: @unchecked Sendable {
  private let lock = NSLock()
  private var content: SCShareableContent?

  func set(_ content: SCShareableContent?) {
    lock.lock()
    self.content = content
    lock.unlock()
  }

  func get() -> SCShareableContent? {
    lock.lock()
    defer { lock.unlock() }
    return content
  }
}

@available(macOS 14.0, *)
private final class CapturedImageBox: @unchecked Sendable {
  private let lock = NSLock()
  private var image: CGImage?

  func set(_ image: CGImage?) {
    lock.lock()
    self.image = image
    lock.unlock()
  }

  func get() -> CGImage? {
    lock.lock()
    defer { lock.unlock() }
    return image
  }
}
