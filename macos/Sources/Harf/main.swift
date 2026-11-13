import AppKit
import CHarf
import ImageIO

let background = (red: CGFloat(0.06), green: CGFloat(0.06), blue: CGFloat(0.07))

/// `Harf --dump <dir>`: renders every font x size page to PNG files and exits.
@MainActor
func dump(to dir: URL) {
    guard let scene = Scene() else { fatalError("core unavailable") }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for font in fontChoices {
        for pt in [11.0, 14.0, 20.0] {
            for grid in [false, true] {
                let size = scene.geometry(font: font, sizePt: pt, scale: 2).size
                let w = Int(size.width), h = Int(size.height)
                let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { continue }
                ctx.translateBy(x: 0, y: CGFloat(h))   // y-down, like the live view
                ctx.scaleBy(x: 1, y: -1)
                ctx.setFillColor(red: background.red, green: background.green, blue: background.blue, alpha: 1)
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                scene.draw(ctx, font: font, sizePt: pt, scale: 2, grid: grid)
                let name = "\(font.slug)-\(Int(pt))pt\(grid ? "-grid" : "").png"
                var ok = false
                if let image = ctx.makeImage(),
                   let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, image, nil)
                    ok = CGImageDestinationFinalize(dest)
                }
                print(ok ? "wrote" : "FAILED", name, "\(w)x\(h)")
            }
        }
    }
    try? scene.report.joined(separator: "\n").appending("\n")
        .write(to: dir.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
}

/// CPU-drawn page view. Draws through the Zig core into the view's CGContext; no GPU, no timers.
@MainActor
final class SpikeView: NSView {
    var scene: Scene!
    var font = fontChoices[1]
    var sizePt = 14.0
    var grid = false
    var onKey: ((UInt16, String) -> Void)?

    override var isFlipped: Bool { true }   // y-down, matches the core's drawing
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { onKey?(event.keyCode, event.charactersIgnoringModifiers ?? "") }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let scale = window?.backingScaleFactor ?? 2
        // The Zig side works in device pixels; scale the points-based context to match.
        ctx.setFillColor(red: background.red, green: background.green, blue: background.blue, alpha: 1)
        ctx.fill(bounds)
        ctx.saveGState()
        ctx.scaleBy(x: 1 / scale, y: 1 / scale)
        scene.draw(ctx, font: font, sizePt: sizePt, scale: scale, grid: grid)
        ctx.restoreGState()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var view: SpikeView!
    var fontIdx = 1
    var sizeIdx = 1
    let sizes = [11.0, 14.0, 20.0]

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let scene = Scene() else { fatalError("core unavailable") }
        view = SpikeView(frame: NSRect(x: 0, y: 0, width: 1100, height: 330))
        view.scene = scene
        view.onKey = { [weak self] code, chars in self?.key(code, chars) }
        window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate()
        rebuild()
    }

    func key(_ code: UInt16, _ chars: String) {
        switch code {
        case 123: fontIdx = (fontIdx + fontChoices.count - 1) % fontChoices.count
        case 124: fontIdx = (fontIdx + 1) % fontChoices.count
        case 125: sizeIdx = (sizeIdx + sizes.count - 1) % sizes.count
        case 126: sizeIdx = (sizeIdx + 1) % sizes.count
        default: if chars == "g" { view.grid.toggle() } else { return }
        }
        rebuild()
    }

    func rebuild() {
        let scale = window.backingScaleFactor
        view.font = fontChoices[fontIdx]
        view.sizePt = sizes[sizeIdx]
        let page = view.scene.geometry(font: view.font, sizePt: view.sizePt, scale: scale).size
        window.setContentSize(NSSize(width: page.width / scale, height: page.height / scale))
        window.title = String(format: "Harf spike (ping 0x%08X) %@ %dpt%@   [<- -> font   up/down size   g grid]",
                              harf_ping(), view.font.label, Int(view.sizePt), view.grid ? " grid" : "")
        view.needsDisplay = true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--dump"), i + 1 < args.count {
    dump(to: URL(fileURLWithPath: args[i + 1]))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
