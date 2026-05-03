import AppKit

private let smokeMode =
    ProcessInfo.processInfo.environment["LABAN_SMOKE"] == "1" ||
    CommandLine.arguments.contains("--smoke")

// Smoke path: prove AppKit initializes, then exit before entering the run loop.
if smokeMode {
    NSApplication.shared.setActivationPolicy(.prohibited)
    print("laban-app: smoke ok")
    exit(0)
}

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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
