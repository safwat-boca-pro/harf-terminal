import AppKit
import CHarf

/// `Harf --conformance <dir>`: drives `vttest` through its core menus in an 80x24 view and saves, for every screen it
/// shows, a picture and the grid text, plus an index. A review aid for a human, not a pass or fail: the screens say what
/// a correct display looks like, and a screen that needs something typed that a script cannot supply is recorded as
/// "needs a human". Exits 0 when it produced screens.
@MainActor
func conformance(dir: String) -> Never {
    func pump(_ seconds: Double, until done: () -> Bool = { false }) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return done()
    }
    func fail(_ what: String) -> Never { print("conformance FAILED: \(what)"); exit(1) }

    let candidates = ["/opt/homebrew/bin/vttest", "/usr/local/bin/vttest", "/usr/bin/vttest"]
    guard let vttest = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
        print("conformance: vttest is not installed (brew install vttest)")
        exit(2)
    }
    do { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) } catch { fail("cannot create \(dir)") }

    func screenText(_ c: TerminalController) -> String { (0..<max(c.gridSize.rows, 24)).map { c.rowText($0) }.joined(separator: "\n") }
    /// Waits until the grid has not changed for 400 ms (at most 6 s).
    func settle(_ c: TerminalController) {
        var last = screenText(c)
        var stable = 0
        let end = Date().addingTimeInterval(6)
        while Date() < end && stable < 8 {
            _ = pump(0.05)
            let now = screenText(c)
            if now == last { stable += 1 } else { stable = 0; last = now }
        }
    }

    struct Entry { let file: String; let label: String; let cols: Int; let rows: Int; let note: String; let title: String }
    var entries: [Entry] = []
    var counter = 0
    var expanded: Set<String> = []   // menus already walked: several vttest menus contain each other
    let started = Date()

    /// The numbered choices (other than 0) of a vttest menu screen.
    func menuItems(_ text: String) -> [String] {
        var items: [String] = []
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let dot = t.firstIndex(of: "."), let n = Int(t[t.startIndex..<dot]), n > 0, t[t.index(after: dot)...].hasPrefix(" ") else { continue }
            items.append(String(n))
        }
        return items
    }

    /// Opens the menu path in a fresh vttest. A submenu is expanded item by item; a test is stepped through screen by screen.
    func visit(_ path: [String], parentTitle: String = "") {
        if Date().timeIntervalSince(started) > 14 * 60 { return }   // never run away
        if path.count > 3 {   // vttest's higher menus reopen the lower ones, so the walk is bounded; the skipped paths are listed
            entries.append(Entry(file: "", label: "menu" + path.joined(separator: "."), cols: 0, rows: 0, note: "not walked (depth limit 3): run vttest by hand and choose this path", title: ""))
            return
        }
        let label = path.isEmpty ? "main" : "menu" + path.joined(separator: ".")
        guard let c = TerminalController(argv: [vttest], frame: NSSize(width: 700, height: 420)) else { fail("cannot start vttest") }
        defer { c.close() }
        if !pump(10, until: { screenText(c).contains("Enter choice number") }) { fail("vttest did not show its menu") }
        for step in path {
            _ = pump(0.2)
            c.sendText(step + "\r")
            settle(c)
        }
        var text = screenText(c)
        if !path.isEmpty && text.contains("Choose test type") && !text.contains("Push") {
            let menuTitle = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
            if menuTitle == parentTitle {   // the same menu came back: this choice was a setting, not a submenu
                entries.append(Entry(file: "", label: label, cols: 0, rows: 0, note: "a setting: the menu came back, no screen", title: ""))
                return
            }
            if expanded.contains(menuTitle) {
                entries.append(Entry(file: "", label: label, cols: 0, rows: 0, note: "the menu '\(menuTitle)' was already walked", title: menuTitle))
                return
            }
            expanded.insert(menuTitle)
            let items = menuItems(text)
            c.close()
            for item in items { visit(path + [item], parentTitle: menuTitle) }
            return
        }
        if path.isEmpty { return }
        var shots = 0
        while shots < 80 {
            if shots > 0 { settle(c); text = screenText(c) }
            if shots > 0 && (text.contains("Choose test type") || text.contains("Enter choice number")) { break }   // back at a menu
            counter += 1
            let base = String(format: "%03d-%@-s%02d", counter, label, shots + 1)
            let grid = c.coreGrid()
            let human = !text.contains("RETURN")
            let title = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
            var header = "# \(base)  grid \(grid.cols)x\(grid.rows)"
            if grid.cols != 80 || grid.rows != 24 { header += "  (the view is 80x24: columns past the window's edge are not visible in the picture)" }
            try? (header + "\n" + text + "\n").write(toFile: dir + "/" + base + ".txt", atomically: true, encoding: .utf8)
            if let rep = c.view.bitmapImageRepForCachingDisplay(in: c.view.bounds) {
                c.view.cacheDisplay(in: c.view.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: dir + "/" + base + ".png")) }
            }
            entries.append(Entry(file: base, label: label, cols: grid.cols, rows: grid.rows, note: human ? "needs a human" : "", title: title))
            if human { break }   // nothing a script can answer: stop this test here and say so
            c.sendText("\r")
            shots += 1
            _ = pump(0.1)
        }
    }

    for menu in ["1", "2", "3", "6", "8", "11"] { visit([menu]) }

    var index = "# vttest screens\n\nOne picture and one text dump per screen (the dump starts with the real grid size).\n\n| File | Menu | Grid | First line | Note |\n|---|---|---|---|---|\n"
    for e in entries {
        index += "| \(e.file.isEmpty ? "-" : e.file) | \(e.label) | \(e.cols)x\(e.rows) | \(e.title.replacingOccurrences(of: "|", with: "/")) | \(e.note) |\n"
    }
    try? index.write(toFile: dir + "/README.md", atomically: true, encoding: .utf8)
    let shotsTaken = entries.filter { !$0.file.isEmpty }.count
    print("conformance: \(shotsTaken) screens saved to \(dir) (\(entries.filter { $0.note == "needs a human" }.count) need a human)")
    exit(shotsTaken > 0 ? 0 : 1)
}
