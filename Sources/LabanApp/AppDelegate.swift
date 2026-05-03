import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var windowController: MainWindowController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    MenuCommands.setupMenuBar()
    do {
      windowController = try MainWindowController.makeAndShow()
    } catch {
      let alert = NSAlert()
      alert.messageText = "Laban failed to start"
      alert.informativeText = "\(error)"
      alert.addButton(withTitle: "Quit")
      alert.runModal()
      NSApp.terminate(nil)
    }
    NSApp.activate(ignoringOtherApps: true)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
