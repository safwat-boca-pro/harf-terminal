import AppKit
import CHarf

/// The Phase 3 terminal theme's background (the Zig painter fills with the same color).
let terminalBackground = NSColor(red: 0.06, green: 0.06, blue: 0.07, alpha: 1)

/// What the I/O thread's callbacks point at. It outlives the session: the callbacks retain it
/// before hopping to the main queue, so a queued block never sees a freed object.
final class CallbackTarget: @unchecked Sendable {
    // Only read and written on the main thread.
    nonisolated(unsafe) weak var controller: TerminalController?
}

private func hop(_ ctx: UnsafeMutableRawPointer?, _ work: @escaping @MainActor (TerminalController) -> Void) {
    guard let ctx else { return }
    let addr = UInt(bitPattern: Unmanaged<CallbackTarget>.fromOpaque(ctx).retain().toOpaque())
    DispatchQueue.main.async {
        let target = Unmanaged<CallbackTarget>.fromOpaque(UnsafeRawPointer(bitPattern: addr)!).takeRetainedValue()
        MainActor.assumeIsolated {
            if let c = target.controller { work(c) }
        }
    }
}

// The session calls these on its I/O thread, so they must not be main-actor isolated: they are
// globals, not closures written inside the controller (which would inherit its isolation).
private let wakeCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ctx in hop(ctx) { $0.wakeOnMain() } }
private let titleCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ctx in hop(ctx) { $0.titleOnMain() } }
private let bellCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ctx in hop(ctx) { $0.onBell() } }
private let exitedCallback: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void = { ctx, status in hop(ctx) { $0.exitedOnMain(status) } }

/// Owns one session, its painter and its view. All methods run on the main thread.
@MainActor
final class TerminalController {
    let view: TerminalView
    private var term: OpaquePointer?
    private var painter: OpaquePointer?
    private let target = CallbackTarget()
    private var retainedTarget: Unmanaged<CallbackTarget>?
    private(set) var scale: CGFloat
    private var cellPx = (w: CGFloat(8), h: CGFloat(16))
    private let fontPt: CGFloat = 14
    private let inset: CGFloat = 6
    private(set) var gridSize = (cols: 0, rows: 0)
    private(set) var exitStatus: Int32?

    var onTitle: (String) -> Void = { _ in }
    var onBell: () -> Void = {}
    var onExit: (Int32) -> Void = { _ in }

    /// `argv` nil runs the login shell. `frame` is the view's initial size in points.
    init?(argv: [String]?, frame: NSSize, scale: CGFloat = 2) {
        self.scale = scale
        view = TerminalView(frame: NSRect(origin: .zero, size: frame))
        target.controller = self
        guard makePainter() else { return nil }
        let size = fitGrid(frame)
        let cstrs: [UnsafeMutablePointer<CChar>?] = (argv ?? []).map { strdup($0) } + [nil]
        defer { cstrs.forEach { free($0) } }
        var cb = HarfTermCallbacks(ctx: nil, wake: wakeCallback, title: titleCallback, bell: bellCallback, exited: exitedCallback)
        let retained = Unmanaged.passRetained(target)
        retainedTarget = retained
        cb.ctx = retained.toOpaque()
        term = cstrs.withUnsafeBufferPointer { buf -> OpaquePointer? in
            let argvPtr = UnsafeMutablePointer(mutating: buf.baseAddress!)
            return argvPtr.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) { p in
                harf_term_new(UInt16(size.cols), UInt16(size.rows), 1 << 20, argv == nil ? nil : p, &cb)
            }
        }
        guard term != nil else { return nil }
        gridSize = size
        view.controller = self
    }

    /// Stops the session. Safe to call twice. No callback runs after it returns.
    func close() {
        if let t = term {
            term = nil
            harf_term_free(t)
        }
        retainedTarget?.release()
        retainedTarget = nil
        if let p = painter {
            painter = nil
            harf_painter_free(p)
        }
        view.controller = nil
    }

    deinit { MainActor.assumeIsolated { close() } }

    // MARK: layout

    @discardableResult
    private func makePainter() -> Bool {
        if let p = painter { harf_painter_free(p) }
        painter = harf_painter_new(Float(fontPt * scale))
        guard let p = painter else { return false }
        var m = HarfCellMetrics()
        harf_painter_metrics(p, &m)
        cellPx = (CGFloat(m.cell_w), CGFloat(m.cell_h))
        return true
    }

    private func fitGrid(_ size: NSSize) -> (cols: Int, rows: Int) {
        let cw = cellPx.w / scale, ch = cellPx.h / scale
        return (max(1, Int(((size.width - 2 * inset) / cw).rounded(.down))),
                max(1, Int(((size.height - 2 * inset) / ch).rounded(.down))))
    }

    /// The view's size or backing scale changed: refit the grid and tell the session.
    func layoutChanged(scale newScale: CGFloat? = nil) {
        guard let t = term else { return }
        if let s = newScale, s != scale {
            scale = s
            makePainter()
        }
        let size = fitGrid(view.bounds.size)
        if size.cols != gridSize.cols || size.rows != gridSize.rows || newScale != nil {
            gridSize = size
            harf_term_resize(t, UInt16(size.cols), UInt16(size.rows), UInt32(cellPx.w), UInt32(cellPx.h))
        }
        view.needsDisplay = true
    }

    // MARK: events from the session (already on the main thread)

    fileprivate func wakeOnMain() {
        guard let t = term else { return }
        harf_term_wake_handled(t)   // re-arm before reading, so output arriving during the draw wakes us again
        view.needsDisplay = true
    }

    fileprivate func titleOnMain() {
        guard let t = term else { return }
        var buf = [UInt8](repeating: 0, count: 512)
        let n = harf_term_title(t, &buf, buf.count)
        onTitle(String(decoding: buf[0..<n], as: UTF8.self))
    }

    fileprivate func exitedOnMain(_ status: Int32) {
        exitStatus = status
        onExit(status)
    }

    // MARK: drawing

    fileprivate func draw(in ctx: CGContext, dirty: NSRect) {
        guard let t = term, let p = painter else { return }
        let chPt = cellPx.h / scale
        let first = max(0, Int(((dirty.minY - inset) / chPt).rounded(.down)))
        let last = max(first, Int(((dirty.maxY - inset) / chPt).rounded(.up)))
        ctx.saveGState()
        ctx.translateBy(x: inset, y: inset)
        ctx.scaleBy(x: 1 / scale, y: 1 / scale)   // the painter works in device pixels
        harf_term_draw(t, p, Unmanaged.passUnretained(ctx).toOpaque(), UInt16(min(first, 65535)), UInt16(min(last, 65535)))
        ctx.restoreGState()
    }

    /// UTF-8 text of visible row `row` (for the self-test).
    func rowText(_ row: Int) -> String {
        guard let t = term else { return "" }
        var buf = [CChar](repeating: 0, count: 1024)
        let n = harf_term_row_text(t, UInt16(row), &buf, buf.count)
        return String(decoding: buf[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// CPU-drawn terminal view: the Zig painter draws into the view's CGContext. No GPU, no timers.
@MainActor
final class TerminalView: NSView {
    weak var controller: TerminalController?

    override var isFlipped: Bool { true }   // y-down, matches the painter
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        terminalBackground.setFill()
        dirtyRect.fill()
        controller?.draw(in: ctx, dirty: dirtyRect)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        controller?.layoutChanged()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let s = window?.backingScaleFactor { controller?.layoutChanged(scale: s) }
    }
}
