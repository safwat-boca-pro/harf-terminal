import AppKit
import CHarf
import MetalKit

/// Phase 0: clears once, then idles. No display link runs while idle.
@MainActor
final class Renderer: NSObject, MTKViewDelegate {
    let queue: MTLCommandQueue

    init?(device: MTLDevice) {
        guard let q = device.makeCommandQueue() else { return nil }
        queue = q
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass)
        else { return }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var renderer: Renderer!

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let r = Renderer(device: device)
        else { fatalError("Metal is unavailable") }
        renderer = r

        let frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        let view = MTKView(frame: frame, device: device)
        view.clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1)
        view.isPaused = true                 // no display-link timer (idle cost zero)
        view.enableSetNeedsDisplay = true    // redraw only when asked
        view.delegate = r

        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.contentView = view
        window.title = String(format: "Harf (ping 0x%08X)", harf_ping())
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        view.setNeedsDisplay(view.bounds)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
