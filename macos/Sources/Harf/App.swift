import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var controller: TerminalController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Measurement hook (docs/perf.md): HARF_CONTENT_SIZE=WxH pins the window, e.g. 700x420 for the 80x24 class.
        var content = NSSize(width: 700, height: 420)
        if let s = ProcessInfo.processInfo.environment["HARF_CONTENT_SIZE"] {
            let p = s.split(separator: "x").compactMap { Double($0) }
            if p.count == 2 { content = NSSize(width: p[0], height: p[1]) }
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let c = TerminalController(argv: nil, frame: content, scale: scale) else { fatalError("cannot start the terminal") }
        controller = c
        window = NSWindow(contentRect: NSRect(origin: .zero, size: content), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Harf"
        window.contentView = c.view
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(c.view)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) { controller.close() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
