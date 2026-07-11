import AppKit
import Foundation
import LabanRenderer

struct LabanWindowScreenshot: Equatable {
  var pngData: Data
  var width: Int
  var height: Int
}

enum LabanWindowScreenshotCapture {
  struct RelatedNode<ID: Hashable> {
    var id: ID
    var parentID: ID?
    var isVisible: Bool
    var order: Int
  }

  static let maxPNGBytes = 10 * 1024 * 1024

  static func capture(window: NSWindow) -> LabanWindowScreenshot? {
    let windowIDs = relatedWindowIDs(for: window)
    guard !windowIDs.isEmpty else { return nil }
    let numbers = windowIDs.map { NSNumber(value: $0) }
    guard
      let image = CGImage(
        windowListFromArrayScreenBounds: .null,
        windowArray: numbers as CFArray,
        imageOption: [.boundsIgnoreFraming, .bestResolution]),
      let pngData = PNGEncoder.encode(image),
      !pngData.isEmpty,
      pngData.count <= maxPNGBytes
    else {
      return nil
    }
    return LabanWindowScreenshot(
      pngData: pngData,
      width: image.width,
      height: image.height)
  }

  static func relatedWindowIDs(for root: NSWindow) -> [CGWindowID] {
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

    collect(root)

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

    return relatedIDs(rootID: ObjectIdentifier(root), nodes: nodes)
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
    let nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })

    func descendsFromRoot(_ node: RelatedNode<ID>) -> Bool {
      guard node.id != rootID, node.isVisible else { return node.id == rootID }
      var ancestorID = node.parentID
      var visited: Set<ID> = [node.id]
      while let currentID = ancestorID, visited.insert(currentID).inserted {
        if currentID == rootID { return true }
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
