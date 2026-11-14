import AppKit
import CHarf

/// A key and its modifiers, as the config file names them: `mods` uses the HARF_MOD_* bits, `key` is a lowercase character or
/// a name (`left`, `return`, `f5`).
struct Trigger: Hashable {
    var mods: UInt8
    var key: String

    private static let named: [UInt16: String] = [
        123: "left", 124: "right", 125: "down", 126: "up", 36: "return", 76: "return", 48: "tab", 53: "escape", 51: "backspace",
        117: "delete", 49: "space", 115: "home", 119: "end", 116: "pageup", 121: "pagedown",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
    ]

    /// The trigger a key-down event makes. The key is the layout's character with no modifiers (so Shift+[ is `[` with
    /// shift), which is what a binding names.
    init?(_ event: NSEvent) {
        var m: UInt8 = 0
        let f = event.modifierFlags
        if f.contains(.shift) { m |= UInt8(HARF_MOD_SHIFT) }
        if f.contains(.control) { m |= UInt8(HARF_MOD_CTRL) }
        if f.contains(.option) { m |= UInt8(HARF_MOD_ALT) }
        if f.contains(.command) { m |= UInt8(HARF_MOD_SUPER) }
        if let n = Self.named[event.keyCode] {
            key = n
        } else if let ch = event.characters(byApplyingModifiers: [])?.lowercased(), ch.unicodeScalars.count == 1, ch.unicodeScalars.first!.value > 0x20 {
            key = ch
        } else {
            return nil
        }
        mods = m
    }

    init(mods: UInt8, key: String) {
        self.mods = mods
        self.key = key
    }
}

struct Binding {
    var action: String
    var arg: [UInt8]
}

/// Everything the configuration file sets, as the shell uses it. With no file loaded (the self-test, or before launch finishes)
/// these are the built-in defaults, which are the dark theme the app always had.
@MainActor
final class Settings {
    static let shared = Settings()

    private(set) var config: OpaquePointer?
    private(set) var fontFamily = "Menlo"
    private var configPt: CGFloat = 14
    /// Added to the configured size by Larger and Smaller; a reload resets it.
    private var fontDelta: CGFloat = 0
    private(set) var scrollbackBytes = 1 << 20
    private(set) var clipboardWrite = true
    /// 0 unfocused, 1 always, 2 off.
    private(set) var notifications: Int32 = 0
    /// Confirm a paste that would run lines in a program without bracketed paste, or that is very large.
    private(set) var pasteGuard = true
    /// How Cmd-click on a file path opens it (see `editorLaunch`); empty means the default text editor.
    private(set) var editor = ""
    private(set) var bindings: [Trigger: Binding] = [:]
    private(set) var warnings: [String] = []

    var fontPt: CGFloat { min(72, max(6, configPt + fontDelta)) }
    var isDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    private let controllers = NSHashTable<TerminalController>.weakObjects()
    private var watcher = ConfigWatcher()
    private var appearanceObserver: NSKeyValueObservation?
    private var reloadPending = false
    /// The directory last asked for; nil is the default place. A reload reads the same one.
    private var directory: String?

    func register(_ c: TerminalController) { controllers.add(c) }

    /// Reads the configuration from the default place, applies it to every terminal, and starts watching the files.
    func load(directory newDirectory: String? = nil) {
        if let newDirectory { directory = newDirectory }
        if let old = config { harf_config_free(old) }
        config = harf_config_load(directory)
        defer { (NSApp.delegate as? AppDelegate)?.rebuildMenu() }   // also when there is no config: the menu must exist
        guard let cfg = config else { return }
        fontFamily = String(cString: harf_config_font_family(cfg))
        configPt = CGFloat(harf_config_font_size(cfg))
        fontDelta = 0
        scrollbackBytes = harf_config_scrollback_bytes(cfg)
        clipboardWrite = harf_config_clipboard_write(cfg) != 0
        notifications = harf_config_notifications(cfg)
        pasteGuard = harf_config_paste_guard(cfg) != 0
        editor = String(cString: harf_config_editor(cfg))
        // The zsh shim (OSC 133 marks) ships in the app bundle; shells started after this get it unless the config says off.
        let shim = Bundle.main.resourceURL?.appendingPathComponent("shell-integration").path
        if harf_config_shell_integration(cfg) == 0, let shim, FileManager.default.fileExists(atPath: shim + "/zsh/.zshenv") {
            harf_set_shell_integration_dir(shim)
        } else {
            harf_set_shell_integration_dir(nil)
        }
        bindings = [:]
        for i in 0..<harf_config_keybind_count(cfg) {
            var k = HarfKeybind()
            guard harf_config_keybind(cfg, i, &k) == 0 else { continue }
            let key = withUnsafeBytes(of: &k.key) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let action = withUnsafeBytes(of: &k.action) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let arg = withUnsafeBytes(of: &k.arg) { Array($0.prefix(Int(k.arg_len))) }
            bindings[Trigger(mods: k.mods, key: key)] = Binding(action: action, arg: arg)
        }
        warnings = (0..<harf_config_warning_count(cfg)).compactMap { harf_config_warning(cfg, $0).map { String(cString: $0) } }
        for w in warnings { FileHandle.standardError.write(Data("harf: config: \(w)\n".utf8)) }
        for c in controllers.allObjects { c.applySettings() }
        watcher.watch(directory: String(cString: harf_config_dir(cfg))) { [weak self] in self?.reloadSoon() }
        if appearanceObserver == nil {
            appearanceObserver = NSApp.observe(\.effectiveAppearance, options: []) { _, _ in
                MainActor.assumeIsolated { Settings.shared.appearanceChanged() }
            }
        }
    }

    /// The files changed. Several events arrive for one save, so wait a moment and read once.
    private func reloadSoon() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            MainActor.assumeIsolated {
                Settings.shared.reloadPending = false
                Settings.shared.load()
            }
        }
    }

    func reload() { load() }

    func fontLarger() { fontDelta += 1; for c in controllers.allObjects { c.applySettings() } }
    func fontSmaller() { fontDelta -= 1; for c in controllers.allObjects { c.applySettings() } }
    func fontReset() { fontDelta = 0; for c in controllers.allObjects { c.applySettings() } }

    private func appearanceChanged() {
        for c in controllers.allObjects { c.applyTheme() }
    }

    /// The theme for the current system appearance, or nil when no configuration is loaded (the terminal's own default).
    func theme() -> HarfTheme? {
        guard let cfg = config else { return nil }
        var t = HarfTheme()
        harf_config_theme(cfg, isDark ? 1 : 0, &t)
        return t
    }

    /// The config file, created (with every setting commented out) if there is none, and watched: the directory may not have
    /// existed when `load` looked, in which case nothing was being watched.
    func ensureConfigFile() -> String {
        let dir = config.map { String(cString: harf_config_dir($0)) } ?? (NSHomeDirectory() + "/.config/harf")
        let path = dir + "/config"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: path) { try? String(cString: harf_config_template()).write(toFile: path, atomically: true, encoding: .utf8) }
        watcher.watch(directory: dir) { [weak self] in self?.reloadSoon() }
        return path
    }

    /// Shows the config file in the user's text editor.
    func openConfigFile() {
        let url = URL(fileURLWithPath: ensureConfigFile())
        if let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) {
            NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Watches the config directory, the config file, the themes directory and the theme files in it. A directory reports files
/// being created, removed or replaced; a file reports being edited in place. Events, not timers: idle costs nothing.
@MainActor
final class ConfigWatcher {
    private var sources: [DispatchSourceFileSystemObject] = []

    func watch(directory: String, changed: @escaping @MainActor () -> Void) {
        sources.forEach { $0.cancel() }
        sources = []
        var paths = [directory, directory + "/config", directory + "/themes"]
        if let themes = try? FileManager.default.contentsOfDirectory(atPath: directory + "/themes") {
            paths += themes.map { directory + "/themes/" + $0 }
        }
        for path in paths {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend], queue: .main)
            s.setEventHandler { MainActor.assumeIsolated { changed() } }
            s.setCancelHandler { close(fd) }
            s.resume()
            sources.append(s)
        }
    }
}
