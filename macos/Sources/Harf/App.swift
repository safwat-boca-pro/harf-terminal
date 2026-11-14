import AppKit
import CHarf

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
        controller.onNotify = { [weak controller] title, body in Notifier.post(title: title, body: body, focused: controller?.hasKeyboard() ?? false) }
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

/// The terminal's window, built the same way for the app and for the self-test.
@MainActor
func makeTerminalWindow(content: NSSize, view: NSView) -> NSWindow {
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: content), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
    window.title = "Harf"
    // The default (wide-gamut) window color space makes AppKit keep two backing surfaces once the view has been
    // redrawn (about 5 MB more at 700x420 pt); sRGB keeps one. Measured in docs/perf.md (slice 4 attribution).
    // Colors are also interpreted as sRGB, which is what the theme and ANSI palette are defined in.
    window.colorSpace = .sRGB
    window.contentView = view
    return window
}

/// What a menu item does: an action by name, as a key binding names it.
final class ActionBox: NSObject {
    let action: String
    let arg: [UInt8]
    init(_ action: String, _ arg: [UInt8] = []) {
        self.action = action
        self.arg = arg
    }
}

/// The menus: title, then (item, action). Each item shows the shortcut the key bindings give its action.
private let menuLayout: [(String, [(String, String)])] = [
    ("Harf", [("Settings…", "open_config"), ("Reload Config", "reload_config"), ("Quit Harf", "quit")]),
    ("Shell", [("New Window", "new_window"), ("New Tab", "new_tab"), ("Close", "close"), ("Split Right", "split_right"), ("Split Down", "split_down"), ("Clear", "clear")]),
    ("Edit", [("Copy", "copy"), ("Paste", "paste"), ("Find…", "find"), ("Find Next", "find_next"), ("Find Previous", "find_prev")]),
    ("View", [("Larger", "font_larger"), ("Smaller", "font_smaller"), ("Actual Size", "font_reset")]),
    ("Window", [("Next Tab", "next_tab"), ("Previous Tab", "prev_tab"), ("Next Pane", "focus_next"), ("Previous Pane", "focus_prev")]),
]

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [WindowController] = []

    /// The terminal that has the keyboard, if one does (the find field of a pane counts as its pane's).
    func focusedController() -> TerminalController? { focusedPane()?.controller }

    private func controller(of window: NSWindow?) -> WindowController? { windows.first { $0.window === window } }

    func focusedPane() -> TerminalPane? { controller(of: NSApp.keyWindow)?.focusedPane() }

    /// A new window (or a tab of the key window) with a login shell, starting where the focused terminal is.
    @discardableResult
    func openWindow(tab: Bool, argv: [String]? = nil, content: NSSize? = nil) -> WindowController? {
        let key = NSApp.keyWindow
        let size = content ?? key?.contentView?.bounds.size ?? NSSize(width: 700, height: 420)
        guard let wc = WindowController(argv: argv, content: size, cwd: focusedController()?.currentDirectory()) else { return nil }
        wc.onClose = { [weak self] closing in self?.windows.removeAll { $0 === closing } }
        windows.append(wc)
        if tab, let key { key.addTabbedWindow(wc.window, ordered: .above) }
        else if let key { wc.window.cascadeTopLeft(from: NSPoint(x: key.frame.minX + 28, y: key.frame.maxY - 28)) }
        else { wc.window.center() }
        wc.window.makeKeyAndOrderFront(nil)
        wc.window.makeFirstResponder(wc.allPanes.first?.controller.view)
        return wc
    }

    /// Runs an action named by a key binding or a menu item. Returns whether it was one.
    @discardableResult
    func perform(_ action: String, _ arg: [UInt8], from c: TerminalController?) -> Bool {
        let wc = controller(of: c?.view.window ?? NSApp.keyWindow)
        let pane = c.flatMap { enclosingPane(of: $0.view) } ?? wc?.focusedPane()
        switch action {
        case "quit": NSApp.terminate(nil)
        case "open_config": Settings.shared.openConfigFile()
        case "reload_config": Settings.shared.reload()
        case "font_larger": Settings.shared.fontLarger()
        case "font_smaller": Settings.shared.fontSmaller()
        case "font_reset": Settings.shared.fontReset()
        case "new_window": openWindow(tab: false)
        case "new_tab": openWindow(tab: true)
        case "close": if let pane, let wc { wc.close(pane: pane) } else { NSApp.keyWindow?.performClose(nil) }
        case "split_right": if let pane, let wc { wc.split(pane, vertical: true) }
        case "split_down": if let pane, let wc { wc.split(pane, vertical: false) }
        case "focus_next": wc?.focusPane(next: true)
        case "focus_prev": wc?.focusPane(next: false)
        case "next_tab": NSApp.keyWindow?.selectNextTab(nil)
        case "prev_tab": NSApp.keyWindow?.selectPreviousTab(nil)
        case "goto_tab":
            let n = Int(String(decoding: arg, as: UTF8.self)) ?? 0
            if let tabs = NSApp.keyWindow?.tabbedWindows, n >= 1, n <= tabs.count { tabs[n - 1].makeKeyAndOrderFront(nil) }
        case "find": pane?.showFind()
        case "find_next", "find_prev":
            if let pane, pane.isFindOpen { pane.findStep(older: action == "find_next") } else { pane?.showFind() }
        case "copy", "paste":
            // the find field has the keyboard: it is the one to copy from and paste into
            if let text = NSApp.keyWindow?.firstResponder as? NSTextView {
                if action == "copy" { text.copy(nil) } else { text.paste(nil) }
            } else if let c { return c.perform(action, arg: arg) } else { return pane?.controller.perform(action, arg: arg) ?? false }
        default: return c?.perform(action, arg: arg) ?? pane?.controller.perform(action, arg: arg) ?? false
        }
        return true
    }

    @objc func menuAction(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ActionBox else { return }
        perform(box.action, box.arg, from: focusedController())
    }

    /// Builds the menus from the key bindings, so a remapped shortcut shows in its menu.
    func rebuildMenu() {
        let main = NSMenu()
        for (title, items) in menuLayout {
            let top = NSMenuItem()
            main.addItem(top)
            let menu = NSMenu(title: title)
            for (text, action) in items {
                let mi = NSMenuItem(title: text, action: #selector(menuAction(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = ActionBox(action)
                let shortcuts = Settings.shared.bindings.filter { $0.value.action == action && $0.key.key.unicodeScalars.count == 1 }
                if let t = shortcuts.keys.min(by: { ($0.mods.nonzeroBitCount, $0.key) < ($1.mods.nonzeroBitCount, $1.key) }) {
                    mi.keyEquivalent = t.key
                    var mask: NSEvent.ModifierFlags = []
                    if t.mods & UInt8(HARF_MOD_SHIFT) != 0 { mask.insert(.shift) }
                    if t.mods & UInt8(HARF_MOD_CTRL) != 0 { mask.insert(.control) }
                    if t.mods & UInt8(HARF_MOD_ALT) != 0 { mask.insert(.option) }
                    if t.mods & UInt8(HARF_MOD_SUPER) != 0 { mask.insert(.command) }
                    mi.keyEquivalentModifierMask = mask
                }
                menu.addItem(mi)
            }
            top.submenu = menu
            if title == "Window" { NSApp.windowsMenu = menu }   // AppKit adds the tab and window items to it
        }
        NSApp.mainMenu = main
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        traceStep("applicationDidFinishLaunching")
        rebuildMenu()
        Settings.shared.load()   // before the first terminal exists, so its font, theme and scrollback are the configured ones
        traceStep("main menu installed, configuration loaded")
        // Measurement hook (docs/perf.md): HARF_CONTENT_SIZE=WxH pins the window, e.g. 700x420 for the 80x24 class.
        var content = NSSize(width: 700, height: 420)
        if let s = ProcessInfo.processInfo.environment["HARF_CONTENT_SIZE"] {
            let p = s.split(separator: "x").compactMap { Double($0) }
            if p.count == 2 { content = NSSize(width: p[0], height: p[1]) }
        }
        // Measurement hook (bench/footprint.sh): HARF_CHILD_CMD runs a command first, then the user's shell.
        var argv: [String]? = nil
        if let cmd = ProcessInfo.processInfo.environment["HARF_CHILD_CMD"], !cmd.isEmpty {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            argv = ["/bin/sh", "-c", "\(cmd); exec \(shell) -l"]
        }
        guard openWindow(tab: false, argv: argv, content: content) != nil else { fatalError("cannot start the terminal") }
        traceStep("window built and shown")
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
