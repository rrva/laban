import AppKit

private let smokeMode =
    ProcessInfo.processInfo.environment["LABAN_SMOKE"] == "1" ||
    CommandLine.arguments.contains("--smoke")

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let rect = NSRect(x: 0, y: 0, width: 800, height: 500)
        let mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let win = NSWindow(contentRect: rect, styleMask: mask, backing: .buffered, defer: false)
        win.title = "Laban"
        win.center()
        win.makeKeyAndOrderFront(nil)
        window = win

        if smokeMode {
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(smokeMode ? .prohibited : .regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
