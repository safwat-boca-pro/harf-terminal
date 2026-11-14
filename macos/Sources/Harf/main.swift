import AppKit
import CHarf

/// `Harf --selftest`: drives a controller without a window and checks drawing and resizing. Exits 0 on success.
@MainActor
func selfTest() -> Never {
    func fail(_ what: String) -> Never {
        print("selftest FAILED: \(what)")
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

    print("selftest ok")
    exit(0)
}

let args = CommandLine.arguments
if args.contains("--selftest") {
    setvbuf(stdout, nil, _IONBF, 0)
    MainActor.assumeIsolated { _ = NSApplication.shared; selfTest() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
