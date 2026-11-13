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
