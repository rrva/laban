import XCTest

@testable import LabanApp

final class LabanWindowScreenshotCaptureTests: XCTestCase {
  func testRelatedIDsContainVisibleDescendantsButNotHiddenOrUnrelatedWindows() {
    typealias Node = LabanWindowScreenshotCapture.RelatedNode<String>
    let nodes = [
      Node(id: "dialog", parentID: "root", isVisible: true, order: 0),
      Node(id: "root", parentID: nil, isVisible: true, order: 1),
      Node(id: "nested-dialog", parentID: "dialog", isVisible: true, order: 2),
      Node(id: "hidden-dialog", parentID: "root", isVisible: false, order: 3),
      Node(id: "unrelated", parentID: nil, isVisible: true, order: 4),
    ]

    let ids = LabanWindowScreenshotCapture.relatedIDs(rootID: "root", nodes: nodes)

    XCTAssertEqual(ids, ["dialog", "root", "nested-dialog"])
  }

  func testRelatedIDsIncludeAnExplicitVisibleAuxiliaryRootAndItsDialogOnly() {
    typealias Node = LabanWindowScreenshotCapture.RelatedNode<String>
    let nodes = [
      Node(id: "settings", parentID: nil, isVisible: true, order: 0),
      Node(id: "root", parentID: nil, isVisible: true, order: 1),
      Node(id: "settings-dialog", parentID: "settings", isVisible: true, order: 2),
      Node(id: "unrelated", parentID: nil, isVisible: true, order: 3),
    ]

    let ids = LabanWindowScreenshotCapture.relatedIDs(
      rootIDs: ["root", "settings"], nodes: nodes)

    XCTAssertEqual(ids, ["settings", "root", "settings-dialog"])
  }
}
