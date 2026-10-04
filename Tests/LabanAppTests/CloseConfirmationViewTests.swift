import AppKit
import LabanCore
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanApp

/// The pane, tab, and sidebar close paths ask before ending a running program
/// (spec §28). The process probe and the sheet are replaced by test seams, so
/// these run against fixture sessions without a window.
final class CloseConfirmationViewTests: XCTestCase {
  private var savedRenderer: String?
  private var defaults: UserDefaults!
  private var suiteName: String!

  override func setUp() {
    super.setUp()
    savedRenderer = getenv("LABAN_RENDERER").map { String(cString: $0) }
    setenv("LABAN_RENDERER", "software", 1)
    suiteName = "CloseConfirmationViewTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDown() {
    if let savedRenderer {
      setenv("LABAN_RENDERER", savedRenderer, 1)
    } else {
      unsetenv("LABAN_RENDERER")
    }
    defaults.removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  private func makeView() throws -> (AppModel, TerminalBitmapView) {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 40
    let model = try AppModel(
      initialSize: size,
      sessionFactory: { size, context in
        try Session.fixture(size: size, sessionID: context.sessionID)
      })
    let fontAtlas = FontAtlas(pointSize: 14)
    let cellSize = fontAtlas.cellSize
    let view = TerminalBitmapView(
      model: model,
      fontAtlas: fontAtlas,
      sidebarFontAtlas: FontAtlas(pointSize: 11),
      cellWidth: Int(cellSize.width),
      cellHeight: Int(cellSize.height))
    view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    return (model, view)
  }

  /// Every session whose id is in `busy` runs vim; the rest sit at zsh.
  private func useProbe(_ view: TerminalBitmapView, busy: @escaping () -> Set<Session.ID>) {
    var pidBySession: [Session.ID: Int32] = [:]
    view.closeConfirmationEnvironmentForTesting = CloseConfirmationEnvironment(
      shellPid: { id in
        if let pid = pidBySession[id] { return pid }
        let pid = Int32(1000 + pidBySession.count)
        pidBySession[id] = pid
        return pid
      },
      sessionsSurviveQuit: false,
      defaults: defaults,
      probe: { pid in
        let id = pidBySession.first { $0.value == pid }?.key
        let name = id.map { busy().contains($0) } == true ? "vim" : "-zsh"
        return ForegroundProcess(pid: pid, arguments: [name])
      })
  }

  private func addTab(_ model: AppModel) throws -> Tab {
    try model.createTab()
  }

  func testIdleTabClosesWithoutAsking() throws {
    let (model, view) = try makeView()
    let tab = try addTab(model)
    useProbe(view) { [] }
    var asked = 0
    view.closeConfirmationResponderForTesting = { _ in
      asked += 1
      return false
    }
    view.closeTab(nil)
    XCTAssertEqual(asked, 0)
    XCTAssertNil(model.tabs.first { $0.id == tab.id })
  }

  func testBusyTabAsksAndCancelKeepsIt() throws {
    let (model, view) = try makeView()
    let tab = try addTab(model)
    useProbe(view) { [tab.focusedSessionId] }
    var dialogs: [CloseConfirmationDialog] = []
    view.closeConfirmationResponderForTesting = { dialog in
      dialogs.append(dialog)
      return false
    }
    view.closeTab(nil)
    XCTAssertEqual(dialogs.count, 1)
    XCTAssertEqual(dialogs.first?.busyPanes.map(\.program), ["vim"])
    XCTAssertEqual(dialogs.first?.confirmButtonTitle, L10n.tr("Close Tab"))
    XCTAssertNotNil(model.tabs.first { $0.id == tab.id }, "cancel keeps the tab")

    view.closeConfirmationResponderForTesting = { _ in true }
    view.closeTab(nil)
    XCTAssertNil(model.tabs.first { $0.id == tab.id }, "confirm closes the tab")
  }

  func testPaneCloseAsksOnlyAboutThatPane() throws {
    let (model, view) = try makeView()
    let tab = try addTab(model)
    let other = try model.splitPane(inTab: tab.id) { id, size, _ in
      try Session.fixture(size: size, sessionID: id)
    }
    let focused = try XCTUnwrap(model.tabs.first { $0.id == tab.id }?.focusedSessionId)
    XCTAssertEqual(focused, other)
    // The other, unfocused pane runs vim; closing the focused idle pane must not ask.
    useProbe(view) { [tab.focusedSessionId] }
    var asked = 0
    view.closeConfirmationResponderForTesting = { _ in
      asked += 1
      return true
    }
    view.closePane(nil)
    XCTAssertEqual(asked, 0)
    XCTAssertEqual(model.tabs.first { $0.id == tab.id }?.allSessionIds, [tab.focusedSessionId])
  }

  func testTabCloseListsEveryBusyPane() throws {
    let (model, view) = try makeView()
    let tab = try addTab(model)
    let other = try model.splitPane(inTab: tab.id) { id, size, _ in
      try Session.fixture(size: size, sessionID: id)
    }
    useProbe(view) { [tab.focusedSessionId, other] }
    var dialog: CloseConfirmationDialog?
    view.closeConfirmationResponderForTesting = {
      dialog = $0
      return false
    }
    view.closeTab(nil)
    XCTAssertEqual(dialog?.busyPanes.count, 2)
    XCTAssertEqual(model.tabs.first { $0.id == tab.id }?.allSessionIds.count, 2)
  }

  func testNeverModeClosesBusyTab() throws {
    let (model, view) = try makeView()
    let tab = try addTab(model)
    useProbe(view) { [tab.focusedSessionId] }
    CloseConfirmationSettings.setMode(.never, defaults: defaults)
    view.closeConfirmationResponderForTesting = { _ in
      XCTFail("never mode must not ask")
      return false
    }
    view.closeTab(nil)
    XCTAssertNil(model.tabs.first { $0.id == tab.id })
  }

  /// Closing the last tab quits; that quit must not ask about the same tab.
  func testClosingLastTabMarksTheFollowingQuitConfirmed() throws {
    let (model, view) = try makeView()
    let quit = QuitConfirmation()
    view.quitConfirmation = quit
    useProbe(view) { Set(model.tabs.flatMap(\.allSessionIds)) }
    var asked = 0
    view.closeConfirmationResponderForTesting = { _ in
      asked += 1
      return true
    }
    XCTAssertEqual(model.tabs.count, 1)
    view.closeTab(nil)
    XCTAssertEqual(asked, 1)
    XCTAssertEqual(
      quit.shouldTerminate(
        asks: {
          XCTFail("the quit after closing the last tab must not ask again")
          return true
        }, present: { _ in }, reply: { _ in }),
      .terminateNow)
  }

  func testQuitDecisionHonorsSurvivingSessions() throws {
    let (model, view) = try makeView()
    let tab = try addTab(model)
    useProbe(view) { [tab.focusedSessionId] }
    XCTAssertTrue(view.closeConfirmationDecision(.quit).asks)
    var environment = try XCTUnwrap(view.closeConfirmationEnvironmentForTesting)
    environment.sessionsSurviveQuit = true
    view.closeConfirmationEnvironmentForTesting = environment
    XCTAssertFalse(view.closeConfirmationDecision(.quit).asks)
    XCTAssertFalse(view.closeConfirmationDecision(.window).asks)
    XCTAssertTrue(view.closeConfirmationDecision(.tab).asks, "closing a tab still ends it")
  }

  func testAlertUsesDialogText() {
    let alert = TerminalBitmapView.closeConfirmationAlert(
      CloseConfirmationDialog(
        messageText: "Close this tab?", informativeText: "vim is running and will be ended.",
        confirmButtonTitle: "Close Tab", busyPanes: []))
    XCTAssertEqual(alert.messageText, "Close this tab?")
    XCTAssertEqual(alert.buttons.map { $0.title }, ["Close Tab", L10n.tr("Cancel")])
    XCTAssertTrue(alert.showsSuppressionButton)
  }
}
