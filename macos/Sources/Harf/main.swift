import AppKit
import CHarf

/// `Harf --selftest`: drives a controller without a window and checks drawing and resizing. Exits 0 on success.
@MainActor
func selfTest() -> Never {
    var tempScripts: [String] = []   // scripts the checks write; removed before the self-test ends, including on failure
    func fail(_ what: String) -> Never {
        print("selftest FAILED: \(what)")
        for p in tempScripts { try? FileManager.default.removeItem(atPath: p) }
        exit(1)
    }
    func pump(_ seconds: Double, until done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return done()
    }

    print("selftest: start")
    // 1. Output is parsed, drawn, and the grid refits on resize.
    guard let c = TerminalController(argv: ["/bin/sh", "-c", "printf 'hello مرحبا'; sleep 2"], frame: NSSize(width: 700, height: 420)) else { fail("cannot start") }
    if !pump(5, until: { c.rowText(0).contains("hello مرحبا") }) { fail("row 0 is '\(c.rowText(0))'") }
    guard let rep = c.view.bitmapImageRepForCachingDisplay(in: c.view.bounds) else { fail("no bitmap") }
    c.view.cacheDisplay(in: c.view.bounds, to: rep)
    // HARF_SELFTEST_PNG=<path> keeps a picture of the first view for a human to look at.
    if let path = ProcessInfo.processInfo.environment["HARF_SELFTEST_PNG"], let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
    }
    let px = Double(rep.pixelsWide) / Double(c.view.bounds.width)
    func ink(_ y0: Double, _ y1: Double) -> Bool {
        let bg = terminalBackground.usingColorSpace(.sRGB)!
        for y in stride(from: Int(y0 * px), to: Int(y1 * px), by: 2) {
            for x in stride(from: Int(6 * px), to: rep.pixelsWide - Int(6 * px), by: 2) {
                guard let col = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(col.redComponent - bg.redComponent) > 0.1 || abs(col.greenComponent - bg.greenComponent) > 0.1 { return true }
            }
        }
        return false
    }
    if !ink(6, 22) { fail("first row has no ink") }
    if ink(380, 414) { fail("last row has ink") }
    c.view.setFrameSize(NSSize(width: 1, height: 1))
    if c.gridSize.cols != 1 || c.gridSize.rows != 1 { fail("grid at 1x1 pt is \(c.gridSize)") }
    c.view.setFrameSize(NSSize(width: 600, height: 400))
    if c.gridSize.cols < 40 || c.gridSize.rows < 10 { fail("grid at 600x400 pt is \(c.gridSize)") }
    c.close()

    // 1b. Cost of a screen of shaped Arabic rows (Phase 4): first draw shapes every row, the second hits the cache.
    let flood = "i=0; while [ $i -lt 40 ]; do printf 'بيتي مرحبا السلام عليكم ورحمة الله وبركاته %d بيتي مرحبا السلام عليكم ورحمة الله\\n' $i; i=$((i+1)); done; sleep 4"
    guard let shaped = TerminalController(argv: ["/bin/sh", "-c", flood], frame: NSSize(width: 700, height: 420)) else { fail("cannot start shaped session") }
    if !pump(5, until: { shaped.rowText(shaped.gridSize.rows - 2).contains("بيتي") }) { fail("shaped rows: row is '\(shaped.rowText(shaped.gridSize.rows - 2))'") }
    guard let srep = shaped.view.bitmapImageRepForCachingDisplay(in: shaped.view.bounds) else { fail("no bitmap") }
    func timed() -> Double {
        let t0 = Date()
        shaped.view.cacheDisplay(in: shaped.view.bounds, to: srep)
        return Date().timeIntervalSince(t0) * 1000
    }
    let cold = timed()
    let warm = timed()
    print(String(format: "selftest: %dx%d screen of shaped Arabic rows: cold draw %.1f ms, cached draw %.1f ms", shaped.gridSize.cols, shaped.gridSize.rows, cold, warm))
    shaped.close()

    // 1c. Arabic samples (brief 4.7): the grid keeps the logical text and every sample row is drawn.
    let samples = ["مرحبا world 123", "السلام عليكم ورحمة الله", "مُحَمَّد", "لا إله إلا الله", "ls ملف.txt",
                   "\"النتيجة: ١٢٣ (ناجح)\"", "echo \"اختبار\" | wc -c", "│ مرحبا    │"]
    guard let arabic = TerminalController(argv: ["/bin/sh", "-c", "printf '%s\\n' \"$@\"; sleep 3", "sh"] + samples, frame: NSSize(width: 700, height: 420)) else { fail("cannot start samples session") }
    if !pump(5, until: { arabic.rowText(samples.count - 1) == samples[samples.count - 1] }) { fail("samples: row \(samples.count - 1) is '\(arabic.rowText(samples.count - 1))'") }
    for (i, want) in samples.enumerated() where arabic.rowText(i) != want { fail("samples: row \(i) is '\(arabic.rowText(i))', want '\(want)'") }
    guard let arep = arabic.view.bitmapImageRepForCachingDisplay(in: arabic.view.bounds) else { fail("no bitmap") }
    arabic.view.cacheDisplay(in: arabic.view.bounds, to: arep)
    func rowHasInk(_ rep: NSBitmapImageRep, _ c: TerminalController, _ row: Int) -> Bool {
        let scalePx = Double(rep.pixelsWide) / Double(c.view.bounds.width)
        let bg = terminalBackground.usingColorSpace(.sRGB)!
        let y0 = Double(c.insetPt) + Double(row) * Double(c.cellSizePt.height)
        for y in stride(from: Int((y0 + 2) * scalePx), to: Int((y0 + Double(c.cellSizePt.height) - 2) * scalePx), by: 2) {
            for x in stride(from: Int(Double(c.insetPt) * scalePx), to: rep.pixelsWide - Int(Double(c.insetPt) * scalePx), by: 2) {
                guard let col = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(col.redComponent - bg.redComponent) > 0.1 || abs(col.greenComponent - bg.greenComponent) > 0.1 { return true }
            }
        }
        return false
    }
    for i in 0..<samples.count where !rowHasInk(arep, arabic, i) { fail("samples: row \(i) has no ink") }
    // The pictures a human looks at (brief 4.7): HARF_SELFTEST_PNG_DIR=<dir> keeps them.
    let pictureDir = ProcessInfo.processInfo.environment["HARF_SELFTEST_PNG_DIR"]
    func savePNG(_ rep: NSBitmapImageRep, _ name: String) {
        guard let dir = pictureDir, let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }
    savePNG(arep, "samples.png")
    arabic.close()
    // Typing: the same text one letter at a time, frame by frame (row 0 only), at an LTR prompt and on a bare row.
    func typingStrip(prompt: String, text: String, name: String) {
        guard let t = TerminalController(argv: ["/bin/sh", "-c", "printf '\(prompt)'; cat"], frame: NSSize(width: 700, height: 420)) else { fail("cannot start typing strip") }
        if !prompt.isEmpty, !pump(5, until: { t.rowText(0).contains(prompt.trimmingCharacters(in: .whitespaces)) }) { fail("typing strip: no prompt") }
        _ = pump(0.3) { false }
        var frames: [NSBitmapImageRep] = []
        var typed = ""
        for ch in text {
            typed.append(ch)
            t.sendText(String(ch))
            let want = (prompt + typed).trimmingCharacters(in: .whitespaces)
            if !pump(5, until: { t.rowText(0).trimmingCharacters(in: .whitespaces) == want }) { fail("typing strip: row 0 is '\(t.rowText(0))', want '\(want)'") }
            guard let r = t.view.bitmapImageRepForCachingDisplay(in: t.view.bounds) else { fail("no bitmap") }
            t.view.cacheDisplay(in: t.view.bounds, to: r)
            frames.append(r)
        }
        if pictureDir != nil, let first = frames.first {
            let hPx = Int((t.insetPt + t.cellSizePt.height + 4) * CGFloat(first.pixelsWide) / t.view.bounds.width)
            guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: first.pixelsWide, pixelsHigh: hPx * frames.count, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let gctx = NSGraphicsContext(bitmapImageRep: out) else { fail("no strip bitmap") }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = gctx
            for (i, r) in frames.enumerated() {
                let img = NSImage(size: NSSize(width: r.pixelsWide, height: r.pixelsHigh))
                img.addRepresentation(r)
                img.draw(in: NSRect(x: 0, y: (frames.count - 1 - i) * hPx, width: r.pixelsWide, height: hPx),
                         from: NSRect(x: 0, y: r.pixelsHigh - hPx, width: r.pixelsWide, height: hPx), operation: .copy, fraction: 1)
            }
            NSGraphicsContext.restoreGraphicsState()
            savePNG(out, name)
        }
        t.close()
    }
    typingStrip(prompt: "❯ ", text: "السلام عليكم", name: "typing-prompt.png")
    typingStrip(prompt: "", text: "السلام عليكم", name: "typing-bare.png")

    // 1d. Slice 3 pictures (HARF_SELFTEST_PNG_DIR) and the cost of colored screens.
    func scriptController(_ text: String) -> TerminalController {
        let path = NSTemporaryDirectory() + "harf-selftest-\(getpid())-\(UUID().uuidString).sh"
        tempScripts.append(path)
        do { try (text + "\nsleep 8\n").write(toFile: path, atomically: true, encoding: .utf8) } catch { fail("cannot write a script") }
        guard let c = TerminalController(argv: ["/bin/sh", path], frame: NSSize(width: 700, height: 420)) else { fail("cannot start a script session") }
        return c
    }
    let colorScript = #"""
    for b in 0 1; do for c in 30 31 32 33 34 35 36 37 90 91 92 93 94 95 96 97; do printf '\033[%d;%dm %3d \033[0m' $b $c $c; done; printf '\n'; done
    i=16; while [ $i -lt 52 ]; do printf '\033[48;5;%dm  \033[0m' $i; i=$((i+1)); done; printf '\n'
    i=0; while [ $i -lt 40 ]; do printf '\033[48;2;%d;%d;128m  \033[0m' $((i*6)) $((255-i*6)); i=$((i+1)); done; printf '\n'
    printf '\033[1mbold\033[0m \033[3mitalic\033[0m \033[4munderline\033[0m \033[21mdouble\033[0m \033[4:3mcurly\033[0m \033[4:4mdotted\033[0m \033[4:5mdashed\033[0m \033[9mstrike\033[0m \033[2mfaint\033[0m \033[7minverse\033[0m \033[1;3;4mall\033[0m\n'
    printf '\033[38;2;255;160;0mtruecolor text\033[0m \033[48;2;40;40;90m\033[38;5;229m 256 on truecolor \033[0m\n'
    printf '\033[42m\033[2K erased line, green background\033[0m\n'
    """#
    let colors = scriptController(colorScript)
    if !pump(5, until: { (0..<colors.gridSize.rows).contains { colors.rowText($0).contains("inverse all") } }) { fail("colors: rows are '\(colors.rowText(0))'") }
    if let rep = colors.view.bitmapImageRepForCachingDisplay(in: colors.view.bounds) { colors.view.cacheDisplay(in: colors.view.bounds, to: rep); savePNG(rep, "colors.png") }
    colors.close()

    let arabicColorScript = #"""
    printf '\033[1;34mمجلد\033[0m  \033[0;32mسكريبت.sh\033[0m  \033[0;31mأرشيف.tar.gz\033[0m  \033[0;36mرابط -> هدف\033[0m  \033[1;33mملف.txt\033[0m\n'
    printf '\033[44m\033[1;37m  نتيجة: ١٢٣ (ناجح)  \033[0m  \033[41m خطأ \033[0m  \033[4;31mتحذير\033[0m  \033[9mمشطوب\033[0m\n'
    printf 'plain latin \033[32mgreen\033[0m and \033[1;35mbold magenta\033[0m\n'
    printf '\033[7m  مقلوب  \033[0m \033[2mباهت\033[0m\n'
    """#
    let acolors = scriptController(arabicColorScript)
    if !pump(5, until: { (0..<acolors.gridSize.rows).contains { acolors.rowText($0).contains("باهت") } }) { fail("arabic colors: rows are '\(acolors.rowText(0))'") }
    if let rep = acolors.view.bitmapImageRepForCachingDisplay(in: acolors.view.bounds) { acolors.view.cacheDisplay(in: acolors.view.bounds, to: rep); savePNG(rep, "arabic-colors.png") }
    acolors.close()

    // Selection over a Latin row and an Arabic row, with real mouse events.
    let selpic = scriptController(#"printf 'select this latin text\nمرحبا بالعالم ورحمة الله\n'"#)
    let selwin = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
    selwin.contentView = selpic.view
    if !pump(5, until: { selpic.rowText(1).contains("ورحمة") }) { fail("selection picture: rows are '\(selpic.rowText(0))'") }
    do {
        let cell = selpic.cellSizePt
        func at(_ col: Double, _ row: Double) -> NSPoint { NSPoint(x: selpic.insetPt + cell.width * (col + 0.5), y: 420 - (selpic.insetPt + cell.height * (row + 0.5))) }
        func ev(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: selwin.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1) else { fail("cannot make a mouse event") }
            return e
        }
        selpic.view.mouseDown(with: ev(.leftMouseDown, at(7, 0)))
        selpic.view.mouseDragged(with: ev(.leftMouseDragged, at(11, 0)))
        selpic.view.mouseUp(with: ev(.leftMouseUp, at(11, 0)))
        if let rep = selpic.view.bitmapImageRepForCachingDisplay(in: selpic.view.bounds) { selpic.view.cacheDisplay(in: selpic.view.bounds, to: rep); savePNG(rep, "selection-latin.png") }
        selpic.view.mouseDown(with: ev(.leftMouseDown, at(22, 1)))
        selpic.view.mouseDragged(with: ev(.leftMouseDragged, at(14, 1)))
        selpic.view.mouseUp(with: ev(.leftMouseUp, at(14, 1)))
        if let rep = selpic.view.bitmapImageRepForCachingDisplay(in: selpic.view.bounds) { selpic.view.cacheDisplay(in: selpic.view.bounds, to: rep); savePNG(rep, "selection-arabic.png") }
    }
    selpic.close()

    // Cost of a colored 80x24 screen: plain (per-cell path) and Arabic (shaped path). Cold draws every row, cached reuses layouts.
    func timedScreen(_ label: String, _ line: String) {
        let flood = "i=0; while [ $i -lt 40 ]; do printf '\\033[3%d;4%dm\(line)\\033[0m\\n' $((i % 7 + 1)) $(((i + 3) % 7 + 1)) $i; i=$((i+1)); done; sleep 4"
        guard let c = TerminalController(argv: ["/bin/sh", "-c", flood], frame: NSSize(width: 700, height: 420)) else { fail("cannot start \(label)") }
        if !pump(5, until: { c.rowText(c.gridSize.rows - 2).contains("x") || c.rowText(c.gridSize.rows - 2).contains("بيتي") }) { fail("\(label): rows not ready") }
        guard let r = c.view.bitmapImageRepForCachingDisplay(in: c.view.bounds) else { fail("no bitmap") }
        func t() -> Double { let t0 = Date(); c.view.cacheDisplay(in: c.view.bounds, to: r); return Date().timeIntervalSince(t0) * 1000 }
        let cold = t(), warm = t()
        print(String(format: "selftest: colored %@ 80x24 screen: cold draw %.1f ms, second draw %.1f ms", label, cold, warm))
        c.close()
    }
    timedScreen("plain", "colored latin text line %d xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
    timedScreen("arabic", "بيتي مرحبا السلام عليكم ورحمة الله وبركاته %d بيتي مرحبا السلام عليكم ورحمة الله")

    // 1e. A program's OSC 11 (default background) also changes the margins around the grid, not just the cells.
    do {
        guard let b = TerminalController(argv: ["/bin/sh", "-c", #"printf '\033]11;rgb:ff/ff/ff\007'; echo done; sleep 4"#], frame: NSSize(width: 700, height: 420)) else { fail("cannot start background session") }
        if !pump(5, until: { (0..<3).contains { b.rowText($0).contains("done") } }) { fail("background: child not done") }
        guard let r = b.view.bitmapImageRepForCachingDisplay(in: b.view.bounds) else { fail("no bitmap") }
        b.view.cacheDisplay(in: b.view.bounds, to: r)
        let px = Double(r.pixelsWide) / Double(b.view.bounds.width)
        // 2 points from the left and top edges: inside the 6-point inset, outside every cell
        guard let margin = r.colorAt(x: Int(2 * px), y: Int(2 * px))?.usingColorSpace(.sRGB) else { fail("no margin pixel") }
        if margin.redComponent < 0.95 || margin.greenComponent < 0.95 || margin.blueComponent < 0.95 {
            fail("background: after OSC 11 white the margin is (\(margin.redComponent), \(margin.greenComponent), \(margin.blueComponent))")
        }
        b.close()
    }

    // 1f. HARF_MEASURE=1: a 100 MB flood must not leave memory growing (phys_footprint, the budget's own measure).
    if ProcessInfo.processInfo.environment["HARF_MEASURE"] == "1" {
        func physFootprintMB() -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
            }
            return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
        }
        guard let warm = TerminalController(argv: ["/bin/sh", "-c", "sleep 30"], frame: NSSize(width: 700, height: 420)) else { fail("cannot start the baseline session") }
        _ = pump(1.5) { false }
        let before = physFootprintMB()
        guard let flood = TerminalController(argv: ["/bin/sh", "-c", "yes 'flood flood flood flood flood flood flood flood flood flood flood flood flood' | head -c 100000000"], frame: NSSize(width: 700, height: 420)) else { fail("cannot start the flood session") }
        if !pump(120, until: { flood.exitStatus != nil }) { fail("flood did not finish in 120 s") }
        _ = pump(2) { false }
        let during = physFootprintMB()
        flood.close()
        _ = pump(2) { false }
        let after = physFootprintMB()
        warm.close()
        print(String(format: "selftest: footprint before flood %.1f MB, with the flooded session open %.1f MB, after it is closed %.1f MB", before, during, after))
        if during - before > 2 { fail(String(format: "footprint after a flood is %.1f MB above before (limit 2 MB)", during - before)) }
        if after - before > 2 { fail(String(format: "footprint after closing the flood session is %.1f MB above before (limit 2 MB)", after - before)) }
    }

    // 1g. Pictures of real programs running in the view (HARF_SELFTEST_PNG_DIR); each is skipped if the program is missing.
    if pictureDir != nil {
        func installed(_ tool: String) -> Bool {
            ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"].contains { FileManager.default.isExecutableFile(atPath: $0 + tool) }
        }
        func programPicture(_ tool: String, _ png: String, script: String, ready: String, keys: [String]) {
            guard installed(tool) else { print("selftest: \(tool) is not installed, no picture"); return }
            let c = scriptController(script)
            if !pump(10, until: { (0..<c.gridSize.rows).contains { c.rowText($0).contains(ready) } }) { fail("\(tool): '\(ready)' never appeared") }
            for k in keys { c.sendText(k); _ = pump(0.5) { false } }
            _ = pump(0.8) { false }
            if let rep = c.view.bitmapImageRepForCachingDisplay(in: c.view.bounds) { c.view.cacheDisplay(in: c.view.bounds, to: rep); savePNG(rep, png) }
            c.close()
        }
        let sample = #"printf '#!/bin/sh\n# a small script\nname="harf"\nif [ -n "$name" ]; then\n  echo "hello $name" | tr a-z A-Z\nfi\nfor i in 1 2 3; do\n  echo "$i"\ndone\n' > "$F""#
        tempScripts.append("\(NSTemporaryDirectory())harf-selftest-vim-\(getpid()).sh")   // the picture closes vim before its own rm runs
        programPicture("vim", "vim.png", script: "F=\(NSTemporaryDirectory())harf-selftest-vim-\(getpid()).sh; \(sample); vim -u NONE -N -n \"$F\"; rm -f \"$F\"",
                       ready: "a small script", keys: [":syntax on\r", ":set ft=sh\r", ":set number\r"])
        let tmuxName = "harfpic\(getpid())"
        programPicture("tmux", "tmux.png", script: "tmux -L \(tmuxName) -f /dev/null new-session", ready: "[0]", keys: ["\u{2}%", "echo left pane\r", "\u{2}o", "echo right pane\r"])
        for dir in ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"] where FileManager.default.isExecutableFile(atPath: dir + "tmux") {
            let kill = Process(); kill.executableURL = URL(fileURLWithPath: dir + "tmux"); kill.arguments = ["-L", tmuxName, "kill-server"]
            try? kill.run(); kill.waitUntilExit(); break
        }
        programPicture("htop", "htop.png", script: "htop", ready: "Tasks", keys: [])
        programPicture("fzf", "fzf.png", script: "printf 'alpha\\nbeta\\ngamma\\ndelta\\nepsilon\\nzeta\\n' | fzf --height=100%", ready: "gamma", keys: ["a"])
    }

    // 1h. HARF_MEASURE=1: keypress-to-draw latency at an idle prompt. In process: from just before the key is handed to the view
    // until the frame that shows the echo has finished. It leaves out waiting for the display's next refresh and the compositor.
    if ProcessInfo.processInfo.environment["HARF_MEASURE"] == "1" {
        guard let c = TerminalController(argv: ["/bin/sh", "-c", "exec cat"], frame: NSSize(width: 700, height: 420)) else { fail("cannot start the latency session") }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = c.view
        guard let rep = c.view.bitmapImageRepForCachingDisplay(in: c.view.bounds) else { fail("no bitmap") }
        _ = pump(1.0) { false }
        c.view.cacheDisplay(in: c.view.bounds, to: rep)   // warm the draw path once
        func typed() -> Int { (0..<c.gridSize.rows).reduce(0) { $0 + c.rowText($1).filter { $0.isLetter }.count } }
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        var samples: [Double] = []
        for i in 0..<200 {
            let ch = String(letters[i % 26])
            let before = typed()
            let marks = measureDirtyMarks
            measureDirtyRect = .null
            let t0 = ProcessInfo.processInfo.systemUptime
            c.view.handleKey(code: 0, mods: 0, characters: ch, isRepeat: false) { c.sendText(ch) }
            // The product path: key -> core -> PTY echo -> parse -> wake -> hop to the main thread -> wakeOnMain marks the
            // view dirty (`markDirty`). We wait for that mark; we do not read the grid to decide the echo has arrived.
            let deadline = t0 + 2
            while measureDirtyMarks == marks && ProcessInfo.processInfo.systemUptime < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.0002)) }
            if measureDirtyMarks == marks { fail("keystroke \(i): the product's wake path never marked the view dirty within 2 s") }
            // An off-screen window gets no display-link tick, so this stands in for it: draw once, now, what the wake
            // invalidated (the changed row and the one above it, not the whole view).
            let dirty = measureDirtyRect.intersection(c.view.bounds)
            if dirty.isNull || dirty.height > 3 * c.cellSizePt.height { fail("keystroke \(i): the wake invalidated \(measureDirtyRect) of a \(c.view.bounds.size) view; one echoed letter should touch at most two rows") }
            guard let part = c.view.bitmapImageRepForCachingDisplay(in: dirty) else { fail("no bitmap") }
            c.view.cacheDisplay(in: dirty, to: part)
            if typed() != before + 1 { fail("keystroke \(i): the frame drawn after the wake does not show the echo") }
            samples.append((measureFrameEnd - t0) * 1000)
            _ = pump(0.01) { false }
        }
        c.close()
        samples.sort()
        let median = samples[samples.count / 2], p95 = samples[Int(Double(samples.count) * 0.95)], worst = samples[samples.count - 1]
        print(String(format: "selftest: keypress-to-draw at an idle prompt over %d keystrokes: median %.2f ms, p95 %.2f ms, max %.2f ms", samples.count, median, p95, worst))
        if median >= 10 { fail(String(format: "median keypress-to-draw latency is %.2f ms (budget 10 ms)", median)) }
    }

    // 1i. The app's window is an sRGB window: with the default color space AppKit keeps a second backing surface (about 5 MB)
    // once the view has been redrawn. Nothing else in the self-test would notice that setting disappearing.
    do {
        guard let c = TerminalController(argv: ["/bin/sh", "-c", "sleep 2"], frame: NSSize(width: 700, height: 420)) else { fail("cannot start the window session") }
        let w = makeTerminalWindow(content: NSSize(width: 700, height: 420), view: c.view)
        if w.colorSpace != NSColorSpace.sRGB { fail("the terminal window's color space is \(String(describing: w.colorSpace?.localizedName)), not sRGB (costs about 5 MB of footprint)") }
        c.close()
    }

    // 1j. A program that switches the terminal to 132 columns (DECCOLM) gets a window that fits them, and the window follows
    // it back to 80. Before this the grid changed and the window did not, so the right-hand columns were clipped.
    do {
        // The first second is for the window to finish its own refit, which would otherwise reset the grid under the program.
        let script = "sleep 1; printf '\\033[?40h\\033[?3h'; printf wide; sleep 3; printf '\\033[?3l'; printf narrow; sleep 3"
        guard let c = TerminalController(argv: ["/bin/sh", "-c", script], frame: NSSize(width: 700, height: 420)) else { fail("cannot start the DECCOLM session") }
        let w = makeTerminalWindow(content: NSSize(width: 700, height: 420), view: c.view)
        func fits(_ cols: Int) -> Bool {
            let want = CGFloat(cols) * c.cellSizePt.width + 2 * c.insetPt
            return abs(c.view.bounds.width - want) < 1 && c.gridSize.cols == cols && c.coreGrid().cols == cols
        }
        if !pump(5, until: { c.coreGrid().cols == 132 }) { fail("DECCOLM: the core never went to 132 columns (grid \(c.coreGrid()), row0 '\(c.rowText(0))')") }
        if !pump(3, until: { fits(132) }) { fail("DECCOLM: the program switched to 132 columns but the window is \(c.view.bounds.width) pt wide, grid \(c.gridSize), core \(c.coreGrid())") }
        _ = pump(0.3) { false }
        if !fits(132) { fail("DECCOLM: the 132-column fit did not hold (view \(c.view.bounds.width) pt, grid \(c.gridSize), core \(c.coreGrid()))") }
        if !pump(5, until: { fits(80) && c.rowText(0).contains("narrow") }) { fail("DECCOLM: back to 80 columns, the window is \(c.view.bounds.width) pt wide, grid \(c.gridSize), core \(c.coreGrid())") }
        c.close()
        _ = w
    }

    // 1k. Dirty rows, through the view: a bitmap that is updated only with the rectangles the wake path invalidates, each drawn by the
    // view's own `draw`, must equal a full redraw after every step (typing Latin and Arabic, Return, so the screen scrolls).
    do {
        trackDirty = true
        defer { trackDirty = false }
        guard let c = TerminalController(argv: ["/bin/sh", "-c", "exec cat"], frame: NSSize(width: 700, height: 420)) else { fail("cannot start the dirty-rows session") }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = c.view
        _ = pump(1.0) { false }
        guard let kept = c.view.bitmapImageRepForCachingDisplay(in: c.view.bounds), let full = c.view.bitmapImageRepForCachingDisplay(in: c.view.bounds) else { fail("no bitmap") }
        c.view.cacheDisplay(in: c.view.bounds, to: kept)
        let px = Double(kept.pixelsWide) / Double(c.view.bounds.width)
        let alphabet = ["a", "b", "g", "م", "ر", "ح", "ب", "ا", " ", " ", "\r", "é", "日", "ل"]
        var seed: UInt32 = 12345
        var partial = 0
        for i in 0..<120 {
            seed = seed &* 1664525 &+ 1013904223
            let ch = alphabet[Int(seed >> 16) % alphabet.count]
            let marks = measureDirtyMarks
            measureDirtyRect = .null
            c.sendText(ch)
            let deadline = Date().addingTimeInterval(2)
            while measureDirtyMarks == marks && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
            _ = pump(0.03) { false }   // let any second wake (cat's own output) arrive
            let dirty = measureDirtyRect.intersection(c.view.bounds)
            if !dirty.isNull {
                if dirty.height < c.view.bounds.height { partial += 1 }
                guard let part = c.view.bitmapImageRepForCachingDisplay(in: dirty) else { fail("no bitmap") }
                c.view.cacheDisplay(in: dirty, to: part)
                guard let src = part.bitmapData, let dst = kept.bitmapData else { fail("no bitmap data") }
                let x0 = Int((dirty.minX * px).rounded()), y0 = Int((dirty.minY * px).rounded())
                let bytes = min(part.bytesPerRow, kept.bytesPerRow - x0 * 4)
                for y in 0..<part.pixelsHigh where y0 + y < kept.pixelsHigh { memcpy(dst + (y0 + y) * kept.bytesPerRow + x0 * 4, src + y * part.bytesPerRow, bytes) }
            }
            c.view.cacheDisplay(in: c.view.bounds, to: full)
            guard let a = kept.bitmapData, let b = full.bitmapData else { fail("no bitmap data") }
            for y in 0..<kept.pixelsHigh where memcmp(a + y * kept.bytesPerRow, b + y * full.bytesPerRow, kept.pixelsWide * 4) != 0 {
                fail("dirty rows: after step \(i) ('\(ch)') the partially redrawn view differs from a full redraw at pixel row \(y) (row \(Int(Double(y) / px / c.cellSizePt.height)), invalidated \(dirty))")
            }
        }
        if partial < 60 { fail("dirty rows: only \(partial) of 120 steps invalidated less than the whole view") }
        print("selftest: dirty rows: 120 typed steps, \(partial) redrawn as rows, every one identical to a full redraw")
        c.close()
        _ = win
    }

    // 2. Typing (a letter, an Arabic letter, Return) goes through the view's own key path.
    let echo = ["/bin/sh", "-c", "read x; echo got:$x"]
    func rows(_ c: TerminalController) -> String { (0..<6).map { c.rowText($0) }.joined(separator: "|") }
    guard let typing = TerminalController(argv: echo, frame: NSSize(width: 700, height: 420)) else { fail("cannot start typing session") }
    func key(_ code: UInt16, _ chars: String) {
        typing.view.handleKey(code: code, mods: 0, characters: chars, isRepeat: false) { typing.sendText(chars) }
    }
    key(0, "a")
    key(46, "م")
    key(36, "\r")
    if !pump(5, until: { rows(typing).contains("got:aم") }) { fail("typing: rows are '\(rows(typing))'") }
    typing.close()

    // 2b. A real arrow-key NSEvent reaches the child as an escape sequence, kitty protocol on or off.
    for kitty in ["", "\\033[>1u"] {
        let script = "stty raw -echo; printf '\(kitty)'; printf R; head -c 3 | od -An -c"
        guard let arrows = TerminalController(argv: ["/bin/sh", "-c", script], frame: NSSize(width: 700, height: 420)) else { fail("cannot start arrow session") }
        if !pump(5, until: { rows(arrows).contains("R") }) { fail("arrow child not ready: '\(rows(arrows))'") }
        guard let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0,
                                        windowNumber: 0, context: nil, characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}",
                                        isARepeat: false, keyCode: 126) else { fail("cannot make key event") }
        arrows.view.keyDown(with: ev)
        if !pump(5, until: { rows(arrows).contains("033") }) { fail("arrow (kitty '\(kitty)'): rows are '\(rows(arrows))'") }
        if !rows(arrows).contains("[   A") { fail("arrow (kitty '\(kitty)'): wrong bytes '\(rows(arrows))'") }
        arrows.close()
    }

    // 2c. Option and Command editing keys, and Ctrl+C under the keyboard flags Claude Code sets (5), as real key events.
    func keyEvent(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        guard let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                        characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { fail("cannot make key event") }
        return ev
    }
    func expectBytes(_ name: String, prelude: String, count: Int, events: [NSEvent], contains: String) {
        let script = "stty raw -echo; printf '\(prelude)'; printf R; head -c \(count) | od -An -tx1 | tr -s ' '"
        guard let t = TerminalController(argv: ["/bin/sh", "-c", script], frame: NSSize(width: 700, height: 420)) else { fail("cannot start \(name)") }
        if !pump(5, until: { t.rowText(0).contains("R") }) { fail("\(name): child not ready: '\(t.rowText(0))'") }
        for ev in events { t.view.keyDown(with: ev) }
        if !pump(5, until: { (0..<4).contains { t.rowText($0).contains(contains) } }) { fail("\(name): rows are '\((0..<4).map { t.rowText($0) }.joined(separator: "|"))', want '\(contains)'") }
        t.close()
    }
    expectBytes("option+left, cmd+left", prelude: "", count: 3,
                events: [keyEvent(123, "\u{F702}", [.option, .numericPad, .function]), keyEvent(123, "\u{F702}", [.command, .numericPad, .function])],
                contains: "1b 62 01")
    expectBytes("ctrl+c with kitty flags 5", prelude: "\\033[>5u", count: 7, events: [keyEvent(8, "\u{03}", [.control])], contains: "1b 5b 39 39 3b 35 75")

    // 2d. The wheel scrolls through the scrollback (a real scroll event), and typing brings the view back.
    guard let hist = TerminalController(argv: ["/bin/sh", "-c", "seq 1 80; exec cat"], frame: NSSize(width: 700, height: 420)) else { fail("cannot start scrollback session") }
    let lastRow = hist.gridSize.rows - 2
    if !pump(5, until: { hist.rowText(lastRow).trimmingCharacters(in: .whitespaces) == "80" }) { fail("scrollback: rows are '\(hist.rowText(lastRow))'") }
    let topBefore = Int(hist.rowText(0).trimmingCharacters(in: .whitespaces)) ?? -1
    guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0), let wheel = NSEvent(cgEvent: cg) else { fail("cannot make a scroll event") }
    hist.view.scrollWheel(with: wheel)
    if !pump(5, until: { (Int(hist.rowText(0).trimmingCharacters(in: .whitespaces)) ?? 999) < topBefore }) { fail("scrollback: wheel did not scroll, row 0 is '\(hist.rowText(0))'") }
    hist.sendText("hi\n")
    if !pump(5, until: { (0..<hist.gridSize.rows).contains { hist.rowText($0).contains("hi") } }) { fail("scrollback: typing did not bring the view back") }
    hist.close()

    // 2e. A real mouse click reaches a program that asked for mouse reports, at the cell under the pointer.
    do {
        let script = "stty raw -echo; printf '\\033[?1000h\\033[?1006h'; printf R; head -c 18 | od -An -tx1 | tr -s ' '"
        guard let m = TerminalController(argv: ["/bin/sh", "-c", script], frame: NSSize(width: 700, height: 420)) else { fail("cannot start mouse session") }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = m.view
        if !pump(5, until: { m.rowText(0).contains("R") }) { fail("mouse: child not ready: '\(m.rowText(0))'") }
        _ = pump(0.3) { false }   // the child switched tracking on before it printed R; let the parser see it
        let cell = m.cellSizePt
        let pt = NSPoint(x: m.insetPt + cell.width * 4.5, y: 420 - (m.insetPt + cell.height * 2.5))   // window coordinates: y up
        func click(_ type: NSEvent.EventType) -> NSEvent {
            guard let ev = NSEvent.mouseEvent(with: type, location: pt, modifierFlags: [], timestamp: 0, windowNumber: win.windowNumber, context: nil,
                                              eventNumber: 0, clickCount: 1, pressure: 1) else { fail("cannot make a mouse event") }
            return ev
        }
        m.view.mouseDown(with: click(.leftMouseDown))
        m.view.mouseUp(with: click(.leftMouseUp))
        func joined() -> String { (0..<4).map { m.rowText($0) }.joined().filter { $0 != " " } }   // the hex dump wraps
        if !pump(5, until: { joined().contains("1b5b3c303b353b334d1b5b3c303b353b336d") }) {
            fail("mouse: rows are '\((0..<4).map { m.rowText($0) }.joined(separator: "|"))'")
        }
        m.close()
    }

    // 2g. A key release reaches a program that asked for event types (kitty flags 1 + 2), for a key whose press reached it.
    do {
        let script = "stty raw -echo; printf '\\033[>3u'; printf R; head -c 16 | od -An -tx1 | tr -s ' '"
        guard let t = TerminalController(argv: ["/bin/sh", "-c", script], frame: NSSize(width: 700, height: 420)) else { fail("cannot start the release session") }
        if !pump(5, until: { t.rowText(0).contains("R") }) { fail("release: child not ready: '\(t.rowText(0))'") }
        _ = pump(0.3) { false }
        func up(_ type: NSEvent.EventType) -> NSEvent {
            guard let ev = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0, windowNumber: 0, context: nil,
                                            characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}", isARepeat: false, keyCode: 126) else { fail("cannot make a key event") }
            return ev
        }
        t.view.keyUp(with: up(.keyUp))   // a release with no press behind it is not reported
        t.view.keyDown(with: up(.keyDown))
        t.view.keyUp(with: up(.keyUp))
        if !pump(5, until: { (0..<4).contains { t.rowText($0).contains("1b 5b 31 3b 31 3a 31 41 1b 5b 31 3b 31 3a 33 41") } }) {
            fail("release: rows are '\((0..<4).map { t.rowText($0) }.joined(separator: "|"))'")
        }
        t.close()
    }

    // 2h. A program's OSC 52 write reaches the clipboard, OSC 9 raises a notification, and a Command-click opens an OSC 8 link:
    // http(s) and mailto only. A file: link, and a cell with no link, give nothing to open.
    do {
        let script = "printf '\\033]52;c;aGVsbG8=\\007'; printf '\\033]9;Build done\\007'; "
            + "printf '\\033]8;;https://example.com/x\\033\\\\link\\033]8;;\\033\\\\ '; "
            + "printf '\\033]8;;file:///etc/passwd\\033\\\\evil\\033]8;;\\033\\\\'; sleep 5"
        guard let c = TerminalController(argv: ["/bin/sh", "-c", script], frame: NSSize(width: 700, height: 420)) else { fail("cannot start the OSC session") }
        let pb = NSPasteboard(name: NSPasteboard.Name("app.harf.selftest"))
        pb.clearContents()
        c.clipboard = pb
        c.clipboardWriteAllowed = { false }   // not focused: the program's write must be ignored
        var notes: [(String, String)] = []
        c.onNotify = { notes.append(($0, $1)) }
        if !pump(5, until: { c.rowText(0).contains("evil") }) { fail("OSC: row 0 is '\(c.rowText(0))'") }
        if pb.string(forType: .string) != nil { fail("OSC 52: a write while the terminal is not focused changed the clipboard") }
        guard let c2 = TerminalController(argv: ["/bin/sh", "-c", "printf '\\033]52;c;aGVsbG8=\\007'; sleep 2"], frame: NSSize(width: 700, height: 420)) else { fail("cannot start the second OSC 52 session") }
        c2.clipboard = pb
        c2.clipboardWriteAllowed = { true }   // focused
        if !pump(5, until: { pb.string(forType: .string) == "hello" }) { fail("OSC 52: the clipboard holds \(String(describing: pb.string(forType: .string)))") }
        c2.close()
        if notes.count != 1 || notes[0].1 != "Build done" { fail("OSC 9: notifications are \(notes)") }
        let cell = c.cellSizePt
        func at(_ col: Double) -> NSPoint { NSPoint(x: c.insetPt + cell.width * col, y: c.insetPt + cell.height * 0.5) }   // the view is y-down
        if c.hyperlink(at: at(1.5))?.absoluteString != "https://example.com/x" { fail("OSC 8: link at column 1 is \(String(describing: c.hyperlink(at: at(1.5))))") }
        if c.hyperlink(at: at(6.5)) != nil { fail("OSC 8: a file: link would be opened") }
        if c.hyperlink(at: at(30.5)) != nil { fail("OSC 8: a link where there is none") }
        pb.clearContents()
        c.close()
    }

    // 2f. Window focus reaches a program that asked for focus events (mode 1004).
    do {
        let script = "stty raw -echo; printf '\\033[?1004h'; printf R; head -c 6 | od -An -tx1 | tr -s ' '"
        guard let f = TerminalController(argv: ["/bin/sh", "-c", script], frame: NSSize(width: 700, height: 420)) else { fail("cannot start focus session") }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = f.view
        if !pump(5, until: { f.rowText(0).contains("R") }) { fail("focus: child not ready: '\(f.rowText(0))'") }
        _ = pump(0.3) { false }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: win)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: win)
        if !pump(5, until: { (0..<3).contains { f.rowText($0).contains("1b 5b 49 1b 5b 4f") } }) {
            fail("focus: rows are '\((0..<3).map { f.rowText($0) }.joined(separator: "|"))'")
        }
        f.close()
    }

    // 2g. Drag-select with real mouse events and copy: logical text reaches the pasteboard, nothing selected copies nothing.
    do {
        guard let sel = TerminalController(argv: ["/bin/sh", "-c", "printf 'hello world\\nمرحبا بالعالم\\n'; sleep 5"], frame: NSSize(width: 700, height: 420)) else { fail("cannot start selection session") }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = sel.view
        if !pump(5, until: { sel.rowText(1).contains("بالعالم") }) { fail("selection: rows are '\(sel.rowText(0))|\(sel.rowText(1))'") }
        let cell = sel.cellSizePt
        func at(_ col: Double, _ row: Double) -> NSPoint { NSPoint(x: sel.insetPt + cell.width * (col + 0.5), y: 420 - (sel.insetPt + cell.height * (row + 0.5))) }
        func ev(_ type: NSEvent.EventType, _ p: NSPoint, clicks: Int = 1) -> NSEvent {
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: win.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: clicks, pressure: 1) else { fail("cannot make a mouse event") }
            return e
        }
        let pb = NSPasteboard(name: NSPasteboard.Name("harf.selftest.\(getpid())"))
        sel.copySelection(to: pb)
        if pb.string(forType: .string) != nil { fail("selection: copy with nothing selected wrote to the pasteboard") }
        sel.view.mouseDown(with: ev(.leftMouseDown, at(0, 0)))
        sel.view.mouseDragged(with: ev(.leftMouseDragged, at(4, 0)))
        sel.view.mouseUp(with: ev(.leftMouseUp, at(4, 0)))
        sel.copySelection(to: pb)
        if pb.string(forType: .string) != "hello" { fail("selection: copied '\(pb.string(forType: .string) ?? "nil")', want 'hello'") }
        // The Arabic row reads right to left, so its logical start is at the right: drag in reading order, right to
        // left across the 13 cells it occupies. The copy is the logical text. (A left-to-right drag selects the
        // logical range between its endpoints, which is the minimal copy of slice 3; visual selection is Phase 7.)
        sel.view.mouseDown(with: ev(.leftMouseDown, at(12, 1)))
        sel.view.mouseDragged(with: ev(.leftMouseDragged, at(0, 1)))
        sel.view.mouseUp(with: ev(.leftMouseUp, at(0, 1)))
        sel.copySelection(to: pb)
        if pb.string(forType: .string) != "مرحبا بالعالم" { fail("selection: copied '\(pb.string(forType: .string) ?? "nil")', want the Arabic row") }
        pb.releaseGlobally()
        sel.close()
    }

    // 3. Paste, bracketed or not, arrives as typed text.
    guard let pasting = TerminalController(argv: echo, frame: NSSize(width: 700, height: 420)) else { fail("cannot start paste session") }
    pasting.paste("x y")
    pasting.view.handleKey(code: 36, mods: 0, characters: "\r", isRepeat: false) {}
    if !pump(5, until: { rows(pasting).contains("got:x y") }) { fail("paste: rows are '\(rows(pasting))'") }
    pasting.close()

    // 4. Title and bell reach the window; a clean exit closes it.
    guard let sig = TerminalController(argv: ["/bin/sh", "-c", "printf '\\033]0;T1\\007\\007'"], frame: NSSize(width: 700, height: 420)) else { fail("cannot start title session") }
    let win1 = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
    win1.contentView = sig.view
    var bells = 0
    let bind1 = WindowBinding(window: win1, controller: sig)
    sig.onBell = { bells += 1 }
    if !pump(5, until: { bind1.closed }) { fail("a clean exit did not close the window") }
    if win1.title != "T1" { fail("title is '\(win1.title)'") }
    if bells != 1 { fail("bell count is \(bells)") }

    // 2i. Configuration, through the app's own path: a config file sets the font and the theme (the core is told, so a program's
    // colour query gets the new colours), a key binding intercepts a key, a theme file is read, a bad line is a warning, and
    // saving the file changes the settings with no restart (file watching).
    do {
        let tmp = NSTemporaryDirectory() + "harf-selftest-config-\(getpid())"
        let fm = FileManager.default
        try? fm.removeItem(atPath: tmp)
        try? fm.createDirectory(atPath: tmp + "/themes", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tmp) }
        func write(_ name: String, _ text: String, atomically: Bool = false) { try? text.write(toFile: tmp + "/" + name, atomically: atomically, encoding: .utf8) }
        write("themes/mine", "background = #102030\nforeground = #a0b0c0\npalette = 1=#ff0000\n")
        write("config", "font_size = 20\ntheme = mine\nclipboard_write = deny\nnotifications = off\nkeybind = option+left = send:X\nbogus line\n")
        let plainCell = TerminalController(argv: ["/bin/sh", "-c", "sleep 1"], frame: NSSize(width: 700, height: 420))?.cellSizePt
        Settings.shared.load(directory: tmp)
        if Settings.shared.fontPt != 20 { fail("config: font size is \(Settings.shared.fontPt)") }
        if Settings.shared.warnings.count != 1 || !Settings.shared.warnings[0].contains("line 6") { fail("config: warnings are \(Settings.shared.warnings)") }
        if Settings.shared.notifications != 2 || Settings.shared.clipboardWrite { fail("config: notifications \(Settings.shared.notifications), clipboard \(Settings.shared.clipboardWrite)") }
        let script = "stty raw -echo; printf R; head -c 1 | od -An -c"
        guard let c = TerminalController(argv: ["/bin/sh", "-c", script], frame: NSSize(width: 700, height: 420)) else { fail("cannot start the config session") }
        if let plain = plainCell, !(c.cellSizePt.width > plain.width * 1.3) { fail("config: font_size = 20 did not enlarge the cell (\(c.cellSizePt) against \(plain))") }
        guard let bg = c.defaultBackground() else { fail("config: no background") }
        if abs(bg.redComponent - 0x10 / 255.0) > 0.01 || abs(bg.greenComponent - 0x20 / 255.0) > 0.01 || abs(bg.blueComponent - 0x30 / 255.0) > 0.01 { fail("config: the theme file's background is \(bg)") }
        if !pump(5, until: { c.rowText(0).contains("R") }) { fail("config: child not ready '\(c.rowText(0))'") }
        c.view.keyDown(with: keyEvent(123, "\u{F702}", [.option, .numericPad, .function]))   // bound: sends X, not the editing key's ESC b
        if !pump(5, until: { (0..<3).contains { c.rowText($0).dropFirst().contains("X") } }) { fail("config: the binding sent '\((0..<3).map { c.rowText($0) })'") }
        c.close()
        // saving the file (in place, then replaced) is seen without a restart
        write("config", "font_size = 11\ntheme = mine\n")
        if !pump(5, until: { Settings.shared.fontPt == 11 }) { fail("config: an edit in place was not noticed (font size \(Settings.shared.fontPt))") }
        write("config", "font_size = 13\ntheme = mine\n", atomically: true)
        if !pump(5, until: { Settings.shared.fontPt == 13 }) { fail("config: a replaced file was not noticed (font size \(Settings.shared.fontPt))") }
        write("themes/mine", "background = #405060\n")
        let live = TerminalController(argv: ["/bin/sh", "-c", "sleep 3"], frame: NSSize(width: 700, height: 420))
        if !pump(5, until: { (live?.defaultBackground()?.redComponent ?? 0) > 0.2 }) { fail("config: a changed theme file did not reach a running terminal") }
        live?.close()
        // back to the built-in defaults for the rest of the run
        let empty = tmp + "/empty"
        try? fm.createDirectory(atPath: empty, withIntermediateDirectories: true)
        Settings.shared.load(directory: empty)
        if Settings.shared.fontPt != 14 || !Settings.shared.clipboardWrite { fail("config: an empty directory did not give the defaults") }
    }

    // 2j. Panes, through the window controller the app uses: a split shares the window and starts where its neighbour's shell is,
    // splits nest, a closed pane gives its place to its neighbour, the keyboard moves between panes, and the last pane closes the
    // window. Find counts matches in the scrollback and scrolls to each.
    do {
        setenv("SHELL", "/bin/sh", 1)   // a split starts the login shell: keep the user's own startup files out of the test
        let script = "echo needle-top; seq 1 100; echo needle-bottom; sleep 30"
        guard let wc = WindowController(argv: ["/bin/sh", "-c", script], content: NSSize(width: 700, height: 420), cwd: "/usr") else { fail("cannot make a window controller") }
        var windowClosed = false
        wc.onClose = { _ in windowClosed = true }
        guard let first = wc.allPanes.first, wc.allPanes.count == 1 else { fail("a new window should have one pane") }
        let cols = first.controller.gridSize.cols
        if !pump(5, until: { (0..<first.controller.gridSize.rows).contains { first.controller.rowText($0).contains("needle-bottom") } }) { fail("panes: the first pane's output never arrived") }
        // find: two matches, the newest first; the older one is in the scrollback and the view is taken to it
        if first.controller.findStart("NEEDLE") != 2 { fail("find: expected two matches for NEEDLE") }
        guard let a = first.controller.findStep(older: true), a.number == 1, a.total == 2 else { fail("find: the first step should be match 1 of 2") }
        guard let b = first.controller.findStep(older: true), b.number == 2 else { fail("find: the second step should be match 2 of 2") }
        if !(0..<first.controller.gridSize.rows).contains(where: { first.controller.rowText($0).contains("needle-top") }) { fail("find: the view did not scroll to the older match") }
        first.showFind()
        if !first.isFindOpen { fail("find: the bar did not open") }
        first.hideFind()
        if first.isFindOpen || first.controller.findStart("") != 0 { fail("find: the bar did not close") }
        // split: a second shell in the directory the first one is in, side by side
        wc.split(first, vertical: true)
        guard wc.allPanes.count == 2, wc.allPanes[0] === first else { fail("split: expected two panes") }
        let second = wc.allPanes[1]
        if !(second.controller.gridSize.cols < cols && first.controller.gridSize.cols < cols) { fail("split: the panes should each be narrower than the whole window (\(first.controller.gridSize.cols), \(second.controller.gridSize.cols) of \(cols))") }
        if abs(first.frame.width - second.frame.width) > 24 { fail("split: unequal panes \(first.frame.width) and \(second.frame.width)") }
        if wc.focusedPane() !== second { fail("split: the new pane should have the keyboard") }
        // a window that is not key (every window here) gives no pane the keyboard, so no pane may write the clipboard or silence a notification
        if wc.allPanes.contains(where: { $0.controller.hasKeyboard() || $0.controller.clipboardWriteAllowed() }) { fail("panes: a pane of a window that is not key has the keyboard") }
        second.controller.sendText("pwd -P\n")
        if !pump(8, until: { (0..<second.controller.gridSize.rows).contains { second.controller.rowText($0).trimmingCharacters(in: .whitespaces) == "/usr" } }) {
            fail("split: the new shell did not start in /usr: '\((0..<4).map { second.controller.rowText($0) })'")
        }
        // nest a split below the second pane, move the keyboard around, close the middle one
        wc.split(second, vertical: false)
        if wc.allPanes.count != 3 { fail("split: expected three panes") }
        let third = wc.allPanes[2]
        if let dir = ProcessInfo.processInfo.environment["HARF_SELFTEST_PNG_DIR"] {   // pictures for a human, drawn offscreen
            first.showFind()
            first.findChanged("needle")
            _ = pump(0.5) { false }
            func shot(_ v: NSView, _ name: String) {
                v.layoutSubtreeIfNeeded()
                guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/" + name))
            }
            shot(wc.window.contentView!, "shell-panes-whole.png")
            shot(first, "shell-pane-first.png")
            shot(second, "shell-pane-second.png")
            shot(third.controller.view, "shell-view-third.png")
            first.hideFind()
            wc.window.makeFirstResponder(third.controller.view)
        }
        wc.focusPane(next: true)
        if wc.focusedPane() !== first { fail("focus: next from the last pane should wrap to the first") }
        wc.focusPane(next: false)
        if wc.focusedPane() !== third { fail("focus: previous from the first pane should wrap to the last") }
        wc.close(pane: second)
        if wc.allPanes.count != 2 || wc.allPanes[0] !== first || wc.allPanes[1] !== third { fail("close: the neighbour should take the closed pane's place") }
        if abs(third.frame.width - first.frame.width) > 24 { fail("close: the remaining panes should share the window (\(first.frame.width), \(third.frame.width))") }
        wc.close(pane: third)
        if wc.allPanes.count != 1 || windowClosed { fail("close: one pane should remain and the window stay open") }
        wc.close(pane: first)
        if !windowClosed || !wc.closed { fail("close: closing the last pane should close the window") }
    }

    // 5. A failing shell keeps its window and says so.
    guard let bad = TerminalController(argv: ["/bin/sh", "-c", "echo boom; exit 3"], frame: NSSize(width: 700, height: 420)) else { fail("cannot start failing session") }
    let win2 = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
    win2.contentView = bad.view
    let bind2 = WindowBinding(window: win2, controller: bad)
    if !pump(5, until: { bad.exitStatus == 3 }) { fail("exit status is \(String(describing: bad.exitStatus))") }
    _ = pump(0.2) { false }
    if bind2.closed { fail("exit status 3 closed the window") }
    if !win2.title.contains("exited (3)") { fail("title is '\(win2.title)'") }
    if !bad.rowText(0).contains("boom") { fail("row 0 is '\(bad.rowText(0))'") }
    bad.close()

    for p in tempScripts { try? FileManager.default.removeItem(atPath: p) }
    print("selftest ok")
    exit(0)
}

let args = CommandLine.arguments
traceStep("main() entered")
if args.contains("--selftest") {
    setvbuf(stdout, nil, _IONBF, 0)
    MainActor.assumeIsolated { _ = NSApplication.shared; selfTest() }
}

if let i = args.firstIndex(of: "--conformance"), i + 1 < args.count {
    setvbuf(stdout, nil, _IONBF, 0)
    let dir = args[i + 1]
    MainActor.assumeIsolated { _ = NSApplication.shared; conformance(dir: dir) }
}

let app = NSApplication.shared
traceStep("NSApplication.shared")
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
