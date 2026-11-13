import CHarf
import CoreGraphics
import Foundation

struct FontChoice {
    let spec: String   // family name, or "system" for the system UI font's Arabic face
    let label: String
    var slug: String { spec.lowercased().replacingOccurrences(of: " ", with: "-") }
}

/// Four installed Arabic fonts. Courier New is what CoreText's cascade picks for a Menlo
/// primary; the others are macOS's own Arabic faces. (Phase 1 evaluation set, not a v1 decision.)
let fontChoices: [FontChoice] = [
    .init(spec: "Courier New", label: "Courier New (default cascade)"),
    .init(spec: "Geeza Pro", label: "Geeza Pro"),
    .init(spec: "system", label: "SF Arabic (system UI font)"),
    .init(spec: "Al Nile", label: "Al Nile"),
]

/// PROJECT_BRIEF section 4.7. Base direction 0 = auto (first strong); the box row is forced LTR
/// so it does not mirror.
let samples: [(text: String, base: UInt32)] = [
    ("مرحبا world 123", 0),
    ("السلام عليكم ورحمة الله", 0),
    ("مُحَمَّد", 0),
    ("لا إله إلا الله", 0),
    ("ls ملف.txt", 0),
    ("\"النتيجة: ١٢٣ (ناجح)\"", 0),
    ("echo \"اختبار\" | wc -c", 0),
    ("│ مرحبا    │", 1),
]

/// Demo overlays on the fitted panel: a caret at logical column `caret`, and a visual drag
/// between the centres of the clusters at logical columns `drag.0` and `drag.1`.
private let demos: [Int: (caret: UInt32, drag: (UInt32, UInt32))] = [
    0: (5, (8, 2)),    // from inside "world" into مرحبا
    1: (6, (9, 15)),   // from inside عليكم into ورحمة
    4: (3, (1, 4)),    // from "s" into ملف
]

private let typed = Array("السلام عليكم").map(String.init)

private let ink: [Float] = [0.92, 0.92, 0.92, 1]
private let accent: [Float] = [0.55, 0.78, 1.0, 1]
private let dim: [Float] = [0.55, 0.55, 0.6, 1]
private let caretColor: (CGFloat, CGFloat, CGFloat) = (1.0, 0.62, 0.2)
private let typingColor: (CGFloat, CGFloat, CGFloat) = (0.4, 0.9, 0.5)

struct Geometry {
    var cw: CGFloat, ch: CGFloat, asc: CGFloat
    var cols: CGFloat = 36
    var margin: CGFloat, gap: CGFloat
    var headerRows = 4   // title, font, size/cell, blank
    var rows: Int
    var panelW: CGFloat { cols * cw + 2 * margin }
    var panelH: CGFloat { CGFloat(headerRows + rows) * ch + 2 * margin }
    var size: CGSize { CGSize(width: (3 * panelW + 4 * gap).rounded(.up), height: (panelH + 2 * gap).rounded(.up)) }
}

/// Lays out and draws one page: plain C | C fitted (with caret and selection demo) | typing.
/// All coordinates are device pixels, y down. The CGContext must be flipped to y-down.
@MainActor
final class Scene {
    let spike: OpaquePointer
    private(set) var report: [String] = []

    init?() {
        guard let s = harf_spike_new() else { return nil }
        spike = s
    }

    func geometry(font: FontChoice, sizePt: Double, scale: Double) -> Geometry {
        var m = HarfMetrics()
        font.spec.withCString { harf_spike_metrics(spike, $0, Float(sizePt * scale), &m) }
        return Geometry(cw: CGFloat(m.cell_w), ch: CGFloat(m.cell_h), asc: CGFloat(m.ascent),
                        margin: CGFloat(m.cell_h), gap: CGFloat(m.cell_h), rows: max(samples.count, typed.count))
    }

    private func fill(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: (CGFloat, CGFloat, CGFloat), _ a: CGFloat) {
        ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: a)
        ctx.fill(CGRect(x: x, y: y, width: w, height: h))
    }

    /// Draws one row and returns its info and cluster extents (extents only for model 3).
    private func row(_ ctx: CGContext, _ text: String, spec: String, sizePx: Float, model: UInt32, base: UInt32,
                     x: CGFloat, baseline: CGFloat, color: [Float]) -> (info: HarfRowInfo, ext: [HarfExtent], bytes: [UInt8]) {
        var info = HarfRowInfo()
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { bp in
            spec.withCString { sp in
                var req = HarfRowRequest(utf8: bp.baseAddress, len: bytes.count, font_spec: sp, size_px: sizePx,
                                         model: model, base_dir: base, origin_x: Float(x), baseline_y: Float(baseline),
                                         color: (color[0], color[1], color[2], color[3]))
                harf_spike_draw_row(spike, Unmanaged.passUnretained(ctx).toOpaque(), &req, &info)
            }
        }
        var ext = [HarfExtent](repeating: HarfExtent(), count: 256)
        let n = min(harf_spike_extents(spike, &ext, ext.count), ext.count)
        return (info, Array(ext[0..<n]), bytes)
    }

    private func isRTLCluster(_ e: HarfExtent, _ bytes: [UInt8]) -> Bool {
        let s = String(decoding: bytes[Int(e.text_start)..<Int(e.text_start + e.text_len)], as: UTF8.self)
        guard let v = s.unicodeScalars.first?.value else { return false }
        return (0x0600...0x06FF).contains(v)
    }

    /// Leading-edge x of the caret at logical column `col` (the end of the line when col == n).
    private func caretX(_ ex: [HarfExtent], _ bytes: [UInt8], col: UInt32) -> Float? {
        if let e = ex.first(where: { $0.lcol == col }) { return isRTLCluster(e, bytes) ? e.x1 : e.x0 }
        guard let last = ex.max(by: { $0.lcol < $1.lcol }) else { return nil }
        return isRTLCluster(last, bytes) ? last.x0 : last.x1
    }

    /// Visual selection like a text editor: snap both ends to the nearest cluster boundary, highlight the
    /// contiguous span, copy the selected clusters in logical order.
    private func visualSelection(_ ex: [HarfExtent], _ bytes: [UInt8], from: UInt32, to: UInt32) -> (lo: Float, hi: Float, copy: String)? {
        guard let a = ex.first(where: { $0.lcol == from }), let b = ex.first(where: { $0.lcol == to }) else { return nil }
        let edges = ex.flatMap { [$0.x0, $0.x1] }
        func snap(_ x: Float) -> Float { edges.min(by: { abs($0 - x) < abs($1 - x) }) ?? x }
        let xa = snap((a.x0 + a.x1) / 2), xb = snap((b.x0 + b.x1) / 2)
        let lo = min(xa, xb), hi = max(xa, xb)
        let picked = ex.filter { $0.x0 >= lo - 0.5 && $0.x1 <= hi + 0.5 && $0.x1 > $0.x0 }.sorted { $0.lcol < $1.lcol }
        let text = picked.map { String(decoding: bytes[Int($0.text_start)..<Int($0.text_start + $0.text_len)], as: UTF8.self) }.joined()
        return (lo, hi, text)
    }

    /// Draws the whole page into `ctx`.
    func draw(_ ctx: CGContext, font: FontChoice, sizePt: Double, scale: Double, grid: Bool) {
        let g = geometry(font: font, sizePt: sizePt, scale: scale)
        let sizePx = Float(sizePt * scale)
        let titles = ["C  plain natural advances", "C fit  word fitted to its cells", "C fit  typing, one letter at a time"]
        var foreign: [String] = []
        var copies: [String] = []

        for p in 0..<3 {
            let px0 = g.gap + CGFloat(p) * (g.panelW + g.gap)
            let py0 = g.gap
            fill(ctx, px0, py0, g.panelW, g.panelH, (0.11, 0.11, 0.13), 1)
            let x0 = px0 + g.margin
            func baseline(_ r: Int) -> CGFloat { py0 + g.margin + g.asc + CGFloat(r) * g.ch }
            func top(_ r: Int) -> CGFloat { py0 + g.margin + CGFloat(r) * g.ch }

            _ = row(ctx, titles[p], spec: font.spec, sizePx: sizePx, model: 0, base: 1, x: x0, baseline: baseline(0), color: accent)
            _ = row(ctx, font.label, spec: font.spec, sizePx: sizePx, model: 0, base: 1, x: x0, baseline: baseline(1), color: dim)
            _ = row(ctx, "\(Int(sizePt))pt @\(Int(scale))x, cell \(Int(g.cw))x\(Int(g.ch))px", spec: font.spec, sizePx: sizePx,
                    model: 0, base: 1, x: x0, baseline: baseline(2), color: dim)

            if p < 2 {
                for (i, s) in samples.enumerated() {
                    let r = g.headerRows + i
                    let model: UInt32 = p == 0 ? 2 : 3
                    let res = row(ctx, s.text, spec: font.spec, sizePx: sizePx, model: model, base: s.base,
                                  x: x0, baseline: baseline(r), color: ink)
                    if p == 0, grid {   // uniform cells: where the grid says each letter is
                        fill(ctx, x0, top(r), CGFloat(res.info.n_cells) * g.cw, g.ch, (1, 1, 1), 0.05)
                        for c in 0...Int(res.info.n_cells) { fill(ctx, x0 + CGFloat(c) * g.cw, top(r), 1, g.ch, (1, 1, 1), 0.16) }
                    }
                    if p == 0, res.info.foreign_runs > 0 {
                        var name = res.info.foreign_name
                        let n = withUnsafeBytes(of: &name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                        foreign.append("\"\(n.isEmpty ? "?" : n)\" x\(res.info.foreign_runs) in row \(i + 1)")
                    }
                    if p == 1 {
                        if grid {       // cluster extents: where each letter really is
                            for e in res.ext { fill(ctx, x0 + CGFloat(e.x0), top(r), 1, g.ch, (1, 1, 1), 0.2) }
                            if let l = res.ext.map({ $0.x1 }).max() { fill(ctx, x0 + CGFloat(l), top(r), 1, g.ch, (1, 1, 1), 0.2) }
                        }
                        if let d = demos[i] {
                            if let sel = visualSelection(res.ext, res.bytes, from: d.drag.0, to: d.drag.1) {
                                fill(ctx, x0 + CGFloat(sel.lo), top(r), CGFloat(sel.hi - sel.lo), g.ch, (0.25, 0.5, 1.0), 0.35)
                                copies.append("row \(i + 1) drag cols \(d.drag.0)->\(d.drag.1): copy \u{201C}\(sel.copy)\u{201D}")
                            }
                            if let cx = caretX(res.ext, res.bytes, col: d.caret) {
                                fill(ctx, x0 + CGFloat(cx) - 1, top(r), 2, g.ch, caretColor, 1)
                            }
                            if let ex = caretX(res.ext, res.bytes, col: res.info.n_cells) {
                                fill(ctx, x0 + CGFloat(ex) - 1, top(r), 2, g.ch, typingColor, 1)
                            }
                        }
                    }
                }
            } else {
                var prefix = ""
                for (i, ch) in typed.enumerated() {
                    prefix += ch
                    let r = g.headerRows + i
                    let res = row(ctx, prefix, spec: font.spec, sizePx: sizePx, model: 3, base: 0,
                                  x: x0, baseline: baseline(r), color: ink)
                    if grid {
                        for e in res.ext { fill(ctx, x0 + CGFloat(e.x0), top(r), 1, g.ch, (1, 1, 1), 0.2) }
                    }
                    if let ex = caretX(res.ext, res.bytes, col: res.info.n_cells) {
                        fill(ctx, x0 + CGFloat(ex) - 1, top(r), 2, g.ch, typingColor, 1)
                    }
                }
            }
        }
        report.append("\(font.spec) | \(Int(sizePt))pt @\(Int(scale))x | cell \(Int(g.cw))x\(Int(g.ch)) px | fallback runs: \(foreign.isEmpty ? "none" : foreign.joined(separator: "; "))")
        report += copies.map { "    " + $0 }
    }
}
