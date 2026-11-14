import AppKit

/// Connects a controller's events to its window: title, bell, and what happens when the shell exits.
@MainActor
final class WindowBinding: NSObject, NSWindowDelegate {
    let window: NSWindow
    let controller: TerminalController
    private(set) var closed = false

    init(window: NSWindow, controller: TerminalController) {
        self.window = window
        self.controller = controller
        super.init()
        window.delegate = self
        controller.onTitle = { [weak window] in window?.title = $0 }
        controller.onBell = { NSSound.beep() }
        controller.onExit = { [weak self] status in
            guard let self else { return }
            // A clean exit closes the window. A failure keeps it, so the last output stays readable.
            if status == 0 { self.window.close() } else { self.window.title = "Harf (exited (\(status)))" }
        }
    }

    func windowWillClose(_ notification: Notification) {
        closed = true
        controller.close()
    }
}

@MainActor
func installMainMenu() {
    let main = NSMenu()
    func add(_ title: String, _ items: [(String, Selector, String)]) {
        let item = NSMenuItem()
        main.addItem(item)
        let menu = NSMenu(title: title)
        for (t, sel, key) in items { menu.addItem(withTitle: t, action: sel, keyEquivalent: key) }
        item.submenu = menu
    }
    add("Harf", [("Quit Harf", #selector(NSApplication.terminate(_:)), "q")])
    add("Shell", [("Close Window", #selector(NSWindow.performClose(_:)), "w")])
    add("Edit", [("Copy", #selector(TerminalView.copy(_:)), "c"), ("Paste", #selector(TerminalView.paste(_:)), "v")])
    NSApp.mainMenu = main
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var binding: WindowBinding!

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        // Measurement hook (docs/perf.md): HARF_CONTENT_SIZE=WxH pins the window, e.g. 700x420 for the 80x24 class.
        var content = NSSize(width: 700, height: 420)
        if let s = ProcessInfo.processInfo.environment["HARF_CONTENT_SIZE"] {
            let p = s.split(separator: "x").compactMap { Double($0) }
            if p.count == 2 { content = NSSize(width: p[0], height: p[1]) }
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        // Measurement hook (bench/footprint.sh): HARF_CHILD_CMD runs a command first, then the user's shell.
        var argv: [String]? = nil
        if let cmd = ProcessInfo.processInfo.environment["HARF_CHILD_CMD"], !cmd.isEmpty {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            argv = ["/bin/sh", "-c", "\(cmd); exec \(shell) -l"]
        }
        guard let c = TerminalController(argv: argv, frame: content, scale: scale) else { fatalError("cannot start the terminal") }
        window = NSWindow(contentRect: NSRect(origin: .zero, size: content), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Harf"
        window.contentView = c.view
        binding = WindowBinding(window: window, controller: c)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(c.view)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
