import AppKit
import UniformTypeIdentifiers

/// A file a Command-click on `path:line:col` found: it exists and is a regular file. `line` and `col` are 0 when the text had none.
struct PathTarget {
    var url: URL
    var line: Int
    var col: Int
}

/// How a file is opened, from the `editor` setting.
enum EditorLaunch: Equatable {
    case textEditor            // no setting: the default plain-text editor
    case app(URL)              // `app:/Applications/X.app`: that app, no line number
    case url(URL)              // a URL template: opened through the system
    case command([String])     // a command template: run without a shell
}

/// Turns the `editor` template into what to do. `{path}`, `{line}` and `{col}` are filled in one pass (a file name that contains
/// `{line}` stays as it is); line and col are 1 when 0. A URL template gets the path percent-encoded; a command template is split on
/// spaces BEFORE filling, so a file name with spaces, quotes or `;` stays one argument and no shell ever sees it. A command whose
/// program word holds a placeholder is refused (it would run the clicked file).
func editorLaunch(template: String, path: String, line: Int, col: Int) -> EditorLaunch {
    let t = template.trimmingCharacters(in: .whitespaces)
    if t.isEmpty { return .textEditor }
    if t.hasPrefix("app:") {
        let app = t.dropFirst(4).trimmingCharacters(in: .whitespaces)
        return app.isEmpty ? .textEditor : .app(URL(fileURLWithPath: app))
    }
    let lineText = String(max(line, 1)), colText = String(max(col, 1))
    func fill(_ s: String, path: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i...].hasPrefix("{path}") { out += path; i = s.index(i, offsetBy: 6) }
            else if s[i...].hasPrefix("{line}") { out += lineText; i = s.index(i, offsetBy: 6) }
            else if s[i...].hasPrefix("{col}") { out += colText; i = s.index(i, offsetBy: 5) }
            else { out.append(s[i]); i = s.index(after: i) }
        }
        return out
    }
    if t.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) != nil {
        // Only letters, digits, `-._~` and `/` stay as they are: `&`, `=`, `;`, `+`, `,`, `@`, `$` in a file name must not be able to add
        // parameters when the template puts {path} in a query (`idea://open?file={path}&line={line}`).
        let encoded = path.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")) ?? path
        return URL(string: fill(t, path: encoded)).map(EditorLaunch.url) ?? .textEditor
    }
    let words = t.split(whereSeparator: \.isWhitespace).map(String.init)
    guard let program = words.first, !program.contains("{") else { return .textEditor }
    return .command(words.map { fill($0, path: path) })
}

/// The `editor` template for an app picked from the system. The editors whose URL scheme takes a line and column get it; any other
/// app is opened by `app:` (the file opens in it, with no line number).
func editorTemplate(forBundleID id: String?, appPath: String) -> String {
    switch id {
    case "com.microsoft.VSCode": return "vscode://file{path}:{line}:{col}"
    case "com.microsoft.VSCodeInsiders": return "vscode-insiders://file{path}:{line}:{col}"
    case "com.vscodium": return "vscodium://file{path}:{line}:{col}"
    case "com.todesktop.230313mzl4w4u92": return "cursor://file{path}:{line}:{col}"
    default: return "app:" + appPath
    }
}

/// Harf > Choose Editor…: the system's app picker (apps only, starting in /Applications); the choice is written to the config file.
@MainActor
func chooseEditor() {
    let panel = NSOpenPanel()
    panel.title = "Choose Editor"
    panel.message = "Cmd-click on a file name in the terminal opens the file in this app."
    panel.allowedContentTypes = [.application]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    guard panel.runModal() == .OK, let app = panel.url else { return }
    if !Settings.shared.setEditor(editorTemplate(forBundleID: Bundle(url: app)?.bundleIdentifier, appPath: app.path)) { warn("could not write the config file") }
}

private func warn(_ what: String) { Log.warn("editor: \(what)") }

/// The shell command mode runs through: `$SHELL` if it is a POSIX shell (the command goes in as `exec "$@"`, which fish, tcsh and
/// nushell do not understand), else /bin/zsh.
func editorShell(env: String?) -> String {
    guard let env, ["zsh", "bash", "sh", "dash", "ksh"].contains((env as NSString).lastPathComponent) else { return "/bin/zsh" }
    return env
}

/// Opens `target` as `Settings.shared.editor` says. Failures to start an editor are written to stderr.
@MainActor
func launchEditor(_ target: PathTarget) {
    func open(_ file: URL, with app: URL) {
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { @Sendable _, error in   // called off the main thread: not main-actor isolated
            if let error { warn("\(app.lastPathComponent): \(error.localizedDescription)") }
        }
    }
    switch editorLaunch(template: Settings.shared.editor, path: target.url.path, line: target.line, col: target.col) {
    case .url(let url):
        NSWorkspace.shared.open(url)
    case .app(let app):
        open(target.url, with: app)
    case .textEditor:
        // Always as text, through the plain-text app: opening the file with its own handler could run a script or launch an app.
        if let app = NSWorkspace.shared.urlForApplication(toOpen: UTType.plainText) { open(target.url, with: app) } else { NSWorkspace.shared.activateFileViewerSelecting([target.url]) }
    case .command(let argv):
        // through the login shell so the user's PATH finds `code` and friends; the words are arguments to `exec`, never a command line
        let process = Process()
        process.executableURL = URL(fileURLWithPath: editorShell(env: ProcessInfo.processInfo.environment["SHELL"]))
        process.terminationHandler = { @Sendable p in   // called off the main thread
            if p.terminationStatus != 0 { warn("\(argv[0]) exited with status \(p.terminationStatus) (is it in your PATH?)") }
        }
        process.arguments = ["-l", "-c", "exec \"$@\"", "harf"] + argv
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { warn("\(argv[0]): \(error.localizedDescription)") }
    }
}
