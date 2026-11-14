import AppKit
import CHarf

/// One terminal, and the find bar that floats over its top right corner while Find is open.
@MainActor
final class TerminalPane: NSView {
    let controller: TerminalController
    /// The title the program set; the window shows the focused pane's.
    var title = "Harf"
    private var findBar: FindBar?

    init(controller: TerminalController) {
        self.controller = controller
        super.init(frame: controller.view.frame)
        controller.view.frame = bounds
        controller.view.autoresizingMask = [.width, .height]
        addSubview(controller.view)
    }

    required init?(coder: NSCoder) { fatalError("TerminalPane is made in code") }

    var isFindOpen: Bool { findBar != nil }

    /// Cmd+F: opens the find bar (or moves back into it) and puts the keyboard there.
    func showFind() {
        if findBar == nil {
            let bar = FindBar(pane: self)
            bar.frame.origin = NSPoint(x: bounds.width - bar.frame.width - 12, y: bounds.height - bar.frame.height - 8)
            bar.autoresizingMask = [.minXMargin, .minYMargin]
            addSubview(bar)
            findBar = bar
        }
        findBar?.focus()
    }

    func hideFind() {
        findBar?.removeFromSuperview()
        findBar = nil
        controller.findEnd()
        window?.makeFirstResponder(controller.view)
    }

    /// The find text changed: search again and jump to the newest match.
    func findChanged(_ text: String) {
        guard controller.findStart(text) > 0 else {
            findBar?.show(position: nil, empty: text.isEmpty)
            return
        }
        findBar?.show(position: controller.findStep(older: true), empty: false)
    }

    /// Enter, Cmd+G: the next match toward older output; Shift+Enter, Cmd+Shift+G: toward newer.
    func findStep(older: Bool) {
        findBar?.show(position: controller.findStep(older: older), empty: false)
    }
}

/// The find bar: a text field, "n of m", previous, next and close.
@MainActor
final class FindBar: NSView, NSTextFieldDelegate {
    private let field = NSTextField()
    private let status = NSTextField(labelWithString: "")
    private weak var pane: TerminalPane?

    init(pane: TerminalPane) {
        self.pane = pane
        super.init(frame: NSRect(x: 0, y: 0, width: 372, height: 30))
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        layer?.cornerRadius = 6
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        field.placeholderString = "Find"
        field.delegate = self
        field.frame = NSRect(x: 8, y: 4, width: 214, height: 22)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.alignment = .right
        status.frame = NSRect(x: 226, y: 6, width: 76, height: 16)
        func button(_ title: String, _ x: CGFloat, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .inline
            b.frame = NSRect(x: x, y: 3, width: 24, height: 24)
            return b
        }
        // up goes toward older output (where Enter goes), down toward newer
        for v in [field, status, button("▲", 306, #selector(older)), button("▼", 326, #selector(newer)), button("✕", 346, #selector(close))] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError("FindBar is made in code") }

    func focus() {
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    /// `position` nil: no match (or nothing typed yet, when `empty`).
    func show(position: (number: Int, total: Int)?, empty: Bool) {
        if let p = position { status.stringValue = "\(p.number) of \(p.total)" } else { status.stringValue = empty ? "" : "No matches" }
    }

    func controlTextDidChange(_ obj: Notification) { pane?.findChanged(field.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            pane?.findStep(older: !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            pane?.hideFind()
            return true
        default:
            return false
        }
    }

    @objc private func older() { pane?.findStep(older: true) }
    @objc private func newer() { pane?.findStep(older: false) }
    @objc private func close() { pane?.hideFind() }
}

/// The panes under a view, in reading order.
@MainActor
func panes(under view: NSView?) -> [TerminalPane] {
    guard let view else { return [] }
    if let p = view as? TerminalPane { return [p] }
    if let sv = view as? NSSplitView { return sv.arrangedSubviews.flatMap { panes(under: $0) } }
    return []
}

/// The pane a responder (the terminal view, or the find field's editor) belongs to.
@MainActor
func enclosingPane(of responder: NSResponder?) -> TerminalPane? {
    var v = responder as? NSView
    while let cur = v {
        if let p = cur as? TerminalPane { return p }
        v = cur.superview
    }
    return nil
}

/// One window (a tab, when tabbed) and the tree of panes in it: a single pane, or splits of splits.
@MainActor
final class WindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private(set) var closed = false
    var onClose: (WindowController) -> Void = { _ in }

    /// `argv` nil runs the login shell, in `cwd` (nil: the home directory).
    init?(argv: [String]?, content: NSSize, cwd: String?) {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: content), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.title = "Harf"
        // sRGB keeps one backing surface (docs/perf.md, slice 4 attribution), and the theme is defined in sRGB.
        window.colorSpace = .sRGB
        window.tabbingIdentifier = "app.harf.terminal"
        window.tabbingMode = .automatic
        guard let pane = makePane(argv: argv, cwd: cwd, content: content) else { return nil }
        window.contentView = pane
        window.delegate = self
    }

    private func makePane(argv: [String]?, cwd: String?, content: NSSize) -> TerminalPane? {
        let scale = window.backingScaleFactor
        guard let c = TerminalController(argv: argv, frame: content, scale: scale, cwd: cwd) else { return nil }
        let pane = TerminalPane(controller: c)
        c.onTitle = { [weak self, weak pane] title in
            guard let self, let pane else { return }
            pane.title = title
            if self.focusedPane() === pane { self.window.title = title }
        }
        c.onFocus = { [weak self, weak pane] in
            if let self, let pane { self.window.title = pane.title }
        }
        c.onBell = { NSSound.beep() }
        c.onNotify = { [weak self] title, body in Notifier.post(title: title, body: body, from: self?.window) }
        c.onExit = { [weak self, weak pane] status in
            guard let self, let pane else { return }
            // A clean exit closes the pane (the last one closes the window). A failure keeps it, so the last output stays readable.
            if status == 0 { self.close(pane: pane) } else { pane.title = "Harf (exited (\(status)))"; if self.focusedPane() === pane { self.window.title = pane.title } }
        }
        return pane
    }

    var allPanes: [TerminalPane] { panes(under: window.contentView) }

    func focusedPane() -> TerminalPane? { enclosingPane(of: window.firstResponder) ?? allPanes.first }

    /// Puts a new terminal beside (`vertical`) or below the pane, starting where its shell is.
    func split(_ pane: TerminalPane, vertical: Bool) {
        guard let parent = pane.superview,
              let fresh = makePane(argv: nil, cwd: pane.controller.currentDirectory(), content: pane.bounds.size) else { return }
        let inner = NSSplitView(frame: pane.frame)
        inner.isVertical = vertical
        inner.dividerStyle = .thin
        inner.autoresizingMask = [.width, .height]
        if let outer = parent as? NSSplitView {
            let index = outer.arrangedSubviews.firstIndex(of: pane) ?? 0
            outer.removeArrangedSubview(pane)
            pane.removeFromSuperview()
            outer.insertArrangedSubview(inner, at: index)
        } else {
            window.contentView = inner   // the pane was the content view; this takes it out of the window
        }
        inner.addArrangedSubview(pane)
        inner.addArrangedSubview(fresh)
        inner.adjustSubviews()
        inner.setPosition(vertical ? inner.bounds.width / 2 : inner.bounds.height / 2, ofDividerAt: 0)
        window.makeFirstResponder(fresh.controller.view)
    }

    /// Closes a pane; its neighbour takes its place. The last pane closes the window.
    func close(pane: TerminalPane) {
        pane.controller.close()
        guard let split = pane.superview as? NSSplitView, let sibling = split.arrangedSubviews.first(where: { $0 !== pane }) else {
            window.close()
            return
        }
        split.removeArrangedSubview(pane)
        pane.removeFromSuperview()
        split.removeArrangedSubview(sibling)
        sibling.removeFromSuperview()
        if let outer = split.superview as? NSSplitView {
            let index = outer.arrangedSubviews.firstIndex(of: split) ?? 0
            outer.removeArrangedSubview(split)
            split.removeFromSuperview()
            outer.insertArrangedSubview(sibling, at: index)
        } else {
            window.contentView = sibling
        }
        if let next = panes(under: sibling).first { window.makeFirstResponder(next.controller.view) }
    }

    /// Moves the keyboard to the next (or previous) pane in reading order.
    func focusPane(next: Bool) {
        let list = allPanes
        guard list.count > 1, let current = focusedPane(), let i = list.firstIndex(where: { $0 === current }) else { return }
        window.makeFirstResponder(list[(i + (next ? 1 : list.count - 1)) % list.count].controller.view)
    }

    func windowWillClose(_ notification: Notification) {
        closed = true
        for p in allPanes { p.controller.close() }
        onClose(self)
    }
}
