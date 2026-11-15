//! Per-row layout: CoreText shaping -> glyph list -> cell models (docs/cell-model.md).
//!
//! Terms: a "cluster" is a base character plus its zero-width marks (tashkeel). A cluster
//! occupies one cell; a glyph may cover several clusters (lam-alef ligature = 2 cells).
const std = @import("std");
const ct = @import("ct.zig");
const Allocator = std.mem.Allocator;

/// a/b/c: the three models from docs/cell-model.md. d = "C fitted": each Arabic word is
/// justified (kashida) to exactly its cell span, letters get per-cluster extents for cursor/selection.
pub const Model = enum(u32) { a = 0, b = 1, c = 2, d = 3 };
pub const BaseDir = enum(u32) { auto = 0, ltr = 1, rtl = 2 };

/// Model B per-glyph horizontal scale limits. A tunable under evaluation, not a verdict.
const b_min_scale: f64 = 0.75;
const b_max_scale: f64 = 1.35;

pub const Placed = struct {
    font_id: u16,
    gid: u16,
    /// Pen origin x in px, relative to the row start.
    x: f32,
    /// Horizontal scale the glyph is rasterized with (1 = natural).
    sx: f32,
    /// Logical cell column of the glyph's cluster (what the grid / cursor / copy use).
    lcol: u32,
    /// Visual cell index of the glyph's cluster (where it is drawn).
    vcell: u32,
};

pub const RowInfo = extern struct {
    n_cells: u32,
    rtl_base: u32,
    /// Runs whose font is neither the primary nor the requested Arabic font (CoreText fallback).
    foreign_runs: u32,
    foreign_name: [48]u8,
};

/// Where one cluster (a cell's base letter + marks) is drawn, for cursor and selection.
/// x0..x1 are visual pixels relative to the row start. `lcol` is the logical cell column.
/// Only filled for model d.
pub const Extent = extern struct {
    lcol: u32,
    x0: f32,
    x1: f32,
    /// Left edge of the grid cell this cluster occupies, in visual order (`visual cell * cell_w`). Unlike x0 and
    /// x1, which follow the glyphs, it always lands on the cell grid: use it for backgrounds and selection.
    cell_x: f32,
    /// Byte range of the cluster's text in the request text (UTF-8).
    text_start: u32,
    text_len: u32,
};

pub const Request = struct {
    text: []const u8,
    primary: *const ct.CTFont,
    arabic: *const ct.CTFont,
    cell_w: f32,
    model: Model,
    base: BaseDir,
};

/// CoreText's caret offsets collapse inside a ligature: the first cluster gets the whole glyph and the
/// others get zero width. Split the glyph's span equally among them. Words are always RTL, so the
/// first logical cluster takes the rightmost slice. `ex` is one word's extents in logical order.
fn splitLigatures(ex: []Extent) void {
    const eps: f32 = 0.01;
    var i: usize = 0;
    while (i < ex.len) : (i += 1) {
        if (ex[i].x1 - ex[i].x0 <= eps) continue;
        var j = i + 1;
        while (j < ex.len and ex[j].x1 - ex[j].x0 <= eps) : (j += 1) {}
        const m = j - i;
        if (m > 1) {
            const lo = ex[i].x0;
            const hi = ex[i].x1;
            const slice = (hi - lo) / @as(f32, @floatFromInt(m));
            for (i..j) |k| {
                const r: f32 = @floatFromInt(k - i);
                ex[k].x1 = hi - r * slice;
                ex[k].x0 = hi - (r + 1) * slice;
            }
        }
        i = j - 1;
    }
}

pub fn isMark(cp: u21) bool {
    return (cp >= 0x0300 and cp <= 0x036F) or
        (cp >= 0x064B and cp <= 0x065F) or cp == 0x0670 or
        (cp >= 0x06D6 and cp <= 0x06DC) or (cp >= 0x06DF and cp <= 0x06E4) or
        cp == 0x06E7 or cp == 0x06E8 or (cp >= 0x06EA and cp <= 0x06ED) or
        cp == 0x200C or cp == 0x200D;
}

/// An Arabic-script letter (not a mark, digit or punctuation). A fitted "word" needs at least one.
fn isArabicLetter(cp: u21) bool {
    if (!isArabic(cp) or isMark(cp)) return false;
    if (cp >= 0x0600 and cp <= 0x061F) return false; // signs, comma, semicolon, question mark
    if (cp >= 0x0660 and cp <= 0x066D) return false; // Arabic-Indic digits, percent, decimal separators
    if (cp >= 0x06F0 and cp <= 0x06F9) return false; // extended Arabic-Indic digits
    return true;
}

fn isArabic(cp: u21) bool {
    return (cp >= 0x0600 and cp <= 0x06FF) or (cp >= 0x0750 and cp <= 0x077F) or
        (cp >= 0x08A0 and cp <= 0x08FF) or (cp >= 0xFB50 and cp <= 0xFDFF) or
        (cp >= 0xFE70 and cp <= 0xFEFF);
}

/// First-strong heuristic for "auto" base direction.
fn strongRtl(cp: u21) ?bool {
    const digit = (cp >= 0x0660 and cp <= 0x0669) or (cp >= 0x06F0 and cp <= 0x06F9);
    if (isArabic(cp) and !isMark(cp) and !digit) return true;
    if ((cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z')) return false;
    return null;
}

pub const Layouter = struct {
    alloc: Allocator,
    /// Interned fonts, retained. Atlas keys use the index, never a raw pointer.
    fonts: std.ArrayList(*const ct.CTFont) = .empty,
    /// Cluster extents of the last `layoutRow` (model d only).
    extents: std.ArrayList(Extent) = .empty,

    pub fn init(alloc: Allocator) Layouter {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Layouter) void {
        for (self.fonts.items) |f| ct.CFRelease(f);
        self.fonts.deinit(self.alloc);
        self.extents.deinit(self.alloc);
    }

    pub fn font(self: *const Layouter, id: u16) *const ct.CTFont {
        return self.fonts.items[id];
    }

    pub fn intern(self: *Layouter, f: *const ct.CTFont) !u16 {
        for (self.fonts.items, 0..) |g, i| {
            if (ct.CFEqual(g, f)) return @intCast(i);
        }
        _ = ct.CFRetain(f);
        try self.fonts.append(self.alloc, f);
        return @intCast(self.fonts.items.len - 1);
    }

    const Glyph = struct {
        font_id: u16,
        gid: u16,
        x: f64, // natural position from CoreText (visual, left to right)
        adv: f64,
        si: usize, // UTF-16 index of the first character this glyph covers
        end: usize, // UTF-16 index one past the last character it covers
        run: u32,
        cells: u32, // logical cells covered (0 = mark)
        base_g: i32, // for marks: index of the glyph carrying the base character
        vcell: u32,
    };

    /// Shapes one row. Fills `out` (visual order) and returns row info.
    pub fn layoutRow(self: *Layouter, req: Request, out: *std.ArrayList(Placed)) !RowInfo {
        var arena_state = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var info = std.mem.zeroes(RowInfo);
        out.clearRetainingCapacity();
        if (req.text.len == 0) return info;

        // 1. UTF-16 units with cluster info. Marks (and low surrogates) are not cell bases.
        var is_base: std.ArrayList(bool) = .empty;
        var is_arab: std.ArrayList(bool) = .empty;
        var is_letter: std.ArrayList(bool) = .empty;
        var base_idx: std.ArrayList(u32) = .empty;
        var u8_of: std.ArrayList(u32) = .empty; // UTF-16 unit -> UTF-8 byte offset (+ sentinel)
        var first_strong: ?bool = null;
        var last_base: u32 = 0;
        var it = (try std.unicode.Utf8View.init(req.text)).iterator();
        while (true) {
            const start: u32 = @intCast(it.i);
            const cp = it.nextCodepoint() orelse break;
            if (first_strong == null) first_strong = strongRtl(cp);
            const units: usize = if (cp >= 0x10000) 2 else 1;
            for (0..units) |u| {
                const idx: u32 = @intCast(is_base.items.len);
                const base = (u == 0) and (!isMark(cp) or idx == 0);
                if (base) last_base = idx;
                try is_base.append(arena, base);
                try is_arab.append(arena, isArabic(cp));
                try is_letter.append(arena, isArabicLetter(cp));
                try base_idx.append(arena, last_base);
                try u8_of.append(arena, start);
            }
        }
        try u8_of.append(arena, @intCast(req.text.len));
        const n = is_base.items.len;
        // bb[i] = number of cell bases before unit i, so bb[base_idx[i]] is unit i's logical column.
        const bb = try arena.alloc(u32, n + 1);
        bb[0] = 0;
        for (0..n) |i| bb[i + 1] = bb[i] + @intFromBool(is_base.items[i]);
        info.n_cells = bb[n];
        // next_base[b] = the next cell base after unit b (or n): the end of b's cluster.
        const next_base = try arena.alloc(u32, n);
        var nb: u32 = @intCast(n);
        var kk: usize = n;
        while (kk > 0) {
            kk -= 1;
            next_base[kk] = nb;
            if (is_base.items[kk]) nb = @intCast(kk);
        }

        // 2. Attributed string: primary font everywhere, Arabic font on Arabic ranges.
        const cfstr = ct.cfString(req.text) orelse return error.CoreText;
        defer ct.CFRelease(cfstr);
        const astr = ct.CFAttributedStringCreateMutable(null, 0) orelse return error.CoreText;
        defer ct.CFRelease(astr);
        ct.CFAttributedStringReplaceString(astr, .{ .location = 0, .length = 0 }, cfstr);
        const full = ct.CFRange{ .location = 0, .length = @intCast(n) };
        ct.CFAttributedStringSetAttribute(astr, full, ct.kCTFontAttributeName, req.primary);
        var i: usize = 0;
        while (i < n) {
            if (!is_arab.items[i]) {
                i += 1;
                continue;
            }
            var j = i;
            while (j < n and is_arab.items[j]) j += 1;
            const range = ct.CFRange{ .location = @intCast(i), .length = @intCast(j - i) };
            ct.CFAttributedStringSetAttribute(astr, range, ct.kCTFontAttributeName, req.arabic);
            i = j;
        }
        const rtl = switch (req.base) {
            .rtl => true,
            .ltr => false,
            .auto => first_strong orelse false,
        };
        info.rtl_base = @intFromBool(rtl);
        var dir: i8 = if (rtl) ct.dir_rtl else ct.dir_ltr;
        const setting = ct.ParagraphSetting{
            .spec = ct.spec_base_writing_direction,
            .value_size = 1,
            .value = &dir,
        };
        const pstyle = ct.CTParagraphStyleCreate(@ptrCast(&setting), 1) orelse return error.CoreText;
        defer ct.CFRelease(pstyle);
        ct.CFAttributedStringSetAttribute(astr, full, ct.kCTParagraphStyleAttributeName, pstyle);

        // 3. Shape. CTLine runs come back in visual order.
        const line = ct.CTLineCreateWithAttributedString(astr) orelse return error.CoreText;
        defer ct.CFRelease(line);
        const runs = ct.CTLineGetGlyphRuns(line);
        const nruns: usize = @intCast(ct.CFArrayGetCount(runs));
        const run_rtl = try arena.alloc(bool, nruns);
        @memset(run_rtl, false);

        var gl: std.ArrayList(Glyph) = .empty;
        for (0..nruns) |r| {
            const run: *const ct.CTRun = @ptrCast(ct.CFArrayGetValueAtIndex(runs, @intCast(r)));
            const cnt: usize = @intCast(ct.CTRunGetGlyphCount(run));
            if (cnt == 0) continue;
            const all = ct.CFRange{ .location = 0, .length = 0 }; // length 0 = whole run
            const gids = try arena.alloc(ct.CGGlyph, cnt);
            const pos = try arena.alloc(ct.CGPoint, cnt);
            const advs = try arena.alloc(ct.CGSize, cnt);
            const idxs = try arena.alloc(ct.CFIndex, cnt);
            ct.CTRunGetGlyphs(run, all, gids.ptr);
            ct.CTRunGetPositions(run, all, pos.ptr);
            ct.CTRunGetAdvances(run, all, advs.ptr);
            ct.CTRunGetStringIndices(run, all, idxs.ptr);

            const attrs = ct.CTRunGetAttributes(run);
            const rf: *const ct.CTFont = @ptrCast(ct.CFDictionaryGetValue(attrs, ct.kCTFontAttributeName) orelse return error.CoreText);
            if (!ct.CFEqual(rf, req.primary) and !ct.CFEqual(rf, req.arabic)) {
                info.foreign_runs += 1;
                if (info.foreign_name[0] == 0) {
                    if (ct.CTFontCopyFullName(rf)) |nm| {
                        defer ct.CFRelease(nm);
                        _ = ct.CFStringGetCString(nm, &info.foreign_name, info.foreign_name.len, ct.encoding_utf8);
                    }
                }
            }
            const fid = try self.intern(rf);
            const srange = ct.CTRunGetStringRange(run);
            const run_end: usize = @intCast(srange.location + srange.length);
            run_rtl[r] = ct.CTRunGetStatus(run) & ct.run_status_rtl != 0;

            for (0..cnt) |k| {
                const si: usize = @intCast(idxs[k]);
                // ponytail: O(n^2) per run; fine for row lengths, use a sorted pass if rows get huge.
                var end = run_end;
                for (idxs) |o| {
                    const ou: usize = @intCast(o);
                    if (ou > si and ou < end) end = ou;
                }
                try gl.append(arena, .{
                    .font_id = fid,
                    .gid = gids[k],
                    .x = pos[k].x,
                    .adv = advs[k].width,
                    .si = si,
                    .end = end,
                    .run = @intCast(r),
                    .cells = bb[end] - bb[si],
                    .base_g = -1,
                    .vcell = 0,
                });
            }
        }

        // 4. Cluster -> cell map. Visual cells are assigned in visual glyph order.
        var running: u32 = 0;
        for (gl.items) |*g| {
            g.vcell = running;
            running += g.cells;
        }
        for (gl.items) |*g| {
            if (g.cells != 0) continue;
            const b = base_idx.items[g.si];
            for (gl.items, 0..) |h, hi| {
                if (h.cells > 0 and h.si <= b and b < h.end) {
                    g.base_g = @intCast(hi);
                    g.vcell = h.vcell;
                    break;
                }
            }
        }

        // 5. Placement per cell model.
        const cw: f64 = req.cell_w;
        const xs = try arena.alloc(f64, gl.items.len);
        const ss = try arena.alloc(f64, gl.items.len);
        @memset(xs, 0);
        @memset(ss, 1);
        switch (req.model) {
            .a, .b, .d => { // d places everything outside fitted words like A
                for (gl.items, 0..) |g, gi| {
                    if (g.cells == 0) continue;
                    const span = @as(f64, @floatFromInt(g.cells)) * cw;
                    var s: f64 = 1;
                    var x = @as(f64, @floatFromInt(g.vcell)) * cw;
                    if (req.model == .b and g.adv > 0) {
                        s = std.math.clamp(span / g.adv, b_min_scale, b_max_scale);
                        x += (span - g.adv * s) / 2;
                    }
                    xs[gi] = x;
                    ss[gi] = s;
                }
                // Marks follow their base glyph: same offset from the base as CoreText chose.
                for (gl.items, 0..) |g, gi| {
                    if (g.cells != 0) continue;
                    if (g.base_g >= 0) {
                        const b: usize = @intCast(g.base_g);
                        ss[gi] = ss[b];
                        xs[gi] = xs[b] + (g.x - gl.items[b].x) * ss[b];
                    } else {
                        xs[gi] = @as(f64, @floatFromInt(g.vcell)) * cw;
                    }
                }
            },
            .c => {
                for (0..nruns) |r| {
                    var first_v: ?u32 = null;
                    var cells_run: u32 = 0;
                    var xmin: f64 = std.math.inf(f64);
                    var xmax: f64 = -std.math.inf(f64);
                    for (gl.items) |g| {
                        if (g.run != r or g.cells == 0) continue;
                        first_v = @min(first_v orelse g.vcell, g.vcell);
                        cells_run += g.cells;
                        xmin = @min(xmin, g.x);
                        xmax = @max(xmax, g.x + g.adv);
                    }
                    const fv = first_v orelse continue;
                    const span = @as(f64, @floatFromInt(cells_run)) * cw;
                    const wn = xmax - xmin;
                    const s: f64 = if (wn > span) span / wn else 1;
                    // Natural advances; the run's start edge is snapped to its cell boundary.
                    const off: f64 = if (run_rtl[r]) span - wn * s else 0;
                    for (gl.items, 0..) |g, gi| {
                        if (g.run != r) continue;
                        xs[gi] = @as(f64, @floatFromInt(fv)) * cw + off + (g.x - xmin) * s;
                        ss[gi] = s;
                    }
                }
            },
        }

        // 6. Model d: fit each Arabic word to its cell span; collect cluster extents.
        const skip = try arena.alloc(bool, gl.items.len);
        @memset(skip, false);
        self.extents.clearRetainingCapacity();
        if (req.model == .d) {
            var rdir: i8 = ct.dir_rtl;
            const rsetting = ct.ParagraphSetting{ .spec = ct.spec_base_writing_direction, .value_size = 1, .value = &rdir };
            const rstyle = ct.CTParagraphStyleCreate(@ptrCast(&rsetting), 1) orelse return error.CoreText;
            defer ct.CFRelease(rstyle);

            var w: usize = 0;
            while (w < n) {
                if (!is_arab.items[w]) {
                    w += 1;
                    continue;
                }
                const ws = w;
                var we = w;
                var has_letter = false;
                while (we < n and is_arab.items[we]) : (we += 1) has_letter = has_letter or is_letter.items[we];
                w = we;
                if (!has_letter) continue; // digits/punctuation only: stays cell-aligned
                const wcells = bb[we] - bb[ws];
                if (wcells == 0) continue;

                // Visual start cell of the word, from the whole-line shaping.
                var vstart: ?u32 = null;
                for (gl.items) |g| {
                    if (g.cells > 0 and g.si >= ws and g.si < we) vstart = @min(vstart orelse g.vcell, g.vcell);
                }
                const vs = vstart orelse continue;
                for (gl.items, 0..) |g, gi| {
                    if (g.si >= ws and g.si < we) skip[gi] = true;
                }

                // The word on its own, in its own CTLine, so justification never touches spaces.
                const wstr = ct.cfString(req.text[u8_of.items[ws]..u8_of.items[we]]) orelse return error.CoreText;
                defer ct.CFRelease(wstr);
                const wa = ct.CFAttributedStringCreateMutable(null, 0) orelse return error.CoreText;
                defer ct.CFRelease(wa);
                ct.CFAttributedStringReplaceString(wa, .{ .location = 0, .length = 0 }, wstr);
                const wfull = ct.CFRange{ .location = 0, .length = @intCast(we - ws) };
                ct.CFAttributedStringSetAttribute(wa, wfull, ct.kCTFontAttributeName, req.arabic);
                ct.CFAttributedStringSetAttribute(wa, wfull, ct.kCTParagraphStyleAttributeName, rstyle);
                const nat_line = ct.CTLineCreateWithAttributedString(wa) orelse return error.CoreText;
                defer ct.CFRelease(nat_line);

                const target = @as(f64, @floatFromInt(wcells)) * cw;
                const natural = ct.CTLineGetTypographicBounds(nat_line, null, null, null);
                var line_use: *const ct.CTLine = nat_line;
                var justified: ?*ct.CTLine = null;
                defer if (justified) |j| ct.CFRelease(j);
                if (natural < target - 0.5) {
                    justified = ct.CTLineCreateJustifiedLine(nat_line, 1.0, target);
                    if (justified) |j| line_use = j;
                }
                // Wider than its cells: uniform scale-down. Could not stretch (lone glyph): centre it.
                const width = ct.CTLineGetTypographicBounds(line_use, null, null, null);
                const s: f64 = if (width > target) target / width else 1;
                const off: f64 = if (width * s < target - 0.5) (target - width * s) / 2 else 0;
                const x0 = @as(f64, @floatFromInt(vs)) * cw + off;

                const wruns = ct.CTLineGetGlyphRuns(line_use);
                const wnruns: usize = @intCast(ct.CFArrayGetCount(wruns));
                for (0..wnruns) |r| {
                    const run: *const ct.CTRun = @ptrCast(ct.CFArrayGetValueAtIndex(wruns, @intCast(r)));
                    const cnt: usize = @intCast(ct.CTRunGetGlyphCount(run));
                    if (cnt == 0) continue;
                    const all = ct.CFRange{ .location = 0, .length = 0 };
                    const gids = try arena.alloc(ct.CGGlyph, cnt);
                    const pos = try arena.alloc(ct.CGPoint, cnt);
                    const idxs = try arena.alloc(ct.CFIndex, cnt);
                    ct.CTRunGetGlyphs(run, all, gids.ptr);
                    ct.CTRunGetPositions(run, all, pos.ptr);
                    ct.CTRunGetStringIndices(run, all, idxs.ptr);
                    const attrs = ct.CTRunGetAttributes(run);
                    const rf: *const ct.CTFont = @ptrCast(ct.CFDictionaryGetValue(attrs, ct.kCTFontAttributeName) orelse return error.CoreText);
                    const fid = try self.intern(rf);
                    for (0..cnt) |k| {
                        // Kashida glyphs may share a letter's string index: they only draw, never count as cells.
                        const si = @min(ws + @as(usize, @intCast(idxs[k])), n - 1);
                        try out.append(self.alloc, .{
                            .font_id = fid,
                            .gid = gids[k],
                            .x = @floatCast(x0 + pos[k].x * s),
                            .sx = @floatCast(s),
                            .lcol = bb[base_idx.items[si]],
                            .vcell = vs,
                        });
                    }
                }

                // Cluster extents come from CoreText's caret offsets in the fitted line.
                const first_ext = self.extents.items.len;
                var b = ws;
                var in_word: u32 = 0; // logical cluster number inside the word; the word is shaped right to left
                while (b < we) {
                    if (!is_base.items[b]) {
                        b += 1;
                        continue;
                    }
                    const e: usize = @min(next_base[b], we);
                    const oa = ct.CTLineGetOffsetForStringIndex(line_use, @intCast(b - ws), null);
                    const ob = ct.CTLineGetOffsetForStringIndex(line_use, @intCast(e - ws), null);
                    try self.extents.append(self.alloc, .{
                        .lcol = bb[b],
                        .x0 = @floatCast(x0 + @min(oa, ob) * s),
                        .x1 = @floatCast(x0 + @max(oa, ob) * s),
                        .cell_x = @floatCast(@as(f64, @floatFromInt(vs + (wcells - 1 - in_word))) * cw),
                        .text_start = u8_of.items[b],
                        .text_len = u8_of.items[e] - u8_of.items[b],
                    });
                    in_word += 1;
                    b = e;
                }
                splitLigatures(self.extents.items[first_ext..]);
            }

            // Everything outside a fitted word keeps whole cells.
            for (gl.items, 0..) |g, gi| {
                if (skip[gi] or g.cells == 0) continue;
                var seen: u32 = 0;
                var u: usize = g.si;
                while (u < g.end) : (u += 1) {
                    if (!is_base.items[u]) continue;
                    const e: usize = next_base[u];
                    try self.extents.append(self.alloc, .{
                        .lcol = bb[u],
                        .x0 = @floatCast((@as(f64, @floatFromInt(g.vcell + seen))) * cw),
                        .x1 = @floatCast((@as(f64, @floatFromInt(g.vcell + seen + 1))) * cw),
                        .cell_x = @floatCast((@as(f64, @floatFromInt(g.vcell + seen))) * cw),
                        .text_start = u8_of.items[u],
                        .text_len = u8_of.items[e] - u8_of.items[u],
                    });
                    seen += 1;
                }
            }
        }

        for (gl.items, 0..) |g, gi| {
            if (skip[gi]) continue;
            try out.append(self.alloc, .{
                .font_id = g.font_id,
                .gid = g.gid,
                .x = @floatCast(xs[gi]),
                .sx = @floatCast(ss[gi]),
                .lcol = bb[base_idx.items[g.si]],
                .vcell = g.vcell,
            });
        }
        return info;
    }
};

// ---- tests (need Menlo and Geeza Pro, both shipped with macOS) ----

fn testFont(name: []const u8) *const ct.CTFont {
    const s = ct.cfString(name).?;
    defer ct.CFRelease(s);
    return ct.CTFontCreateWithName(s, 16, null).?;
}

fn testRow(l: *Layouter, text: []const u8, model: Model, base: BaseDir, out: *std.ArrayList(Placed)) !RowInfo {
    const primary = testFont("Menlo");
    defer ct.CFRelease(primary);
    const arabic = testFont("Geeza Pro");
    defer ct.CFRelease(arabic);
    return l.layoutRow(.{ .text = text, .primary = primary, .arabic = arabic, .cell_w = 10, .model = model, .base = base }, out);
}

test "LTR row: one glyph per cell at cell origins" {
    var l = Layouter.init(std.testing.allocator);
    defer l.deinit();
    var out: std.ArrayList(Placed) = .empty;
    defer out.deinit(std.testing.allocator);
    const info = try testRow(&l, "ls", .a, .auto, &out);
    try std.testing.expectEqual(@as(u32, 2), info.n_cells);
    try std.testing.expectEqual(@as(u32, 0), info.rtl_base);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqual(@as(f32, 0), out.items[0].x);
    try std.testing.expectEqual(@as(f32, 10), out.items[1].x);
}

test "RTL word: visual order is the reverse of logical columns" {
    var l = Layouter.init(std.testing.allocator);
    defer l.deinit();
    var out: std.ArrayList(Placed) = .empty;
    defer out.deinit(std.testing.allocator);
    const info = try testRow(&l, "مرحبا", .a, .auto, &out);
    try std.testing.expectEqual(@as(u32, 5), info.n_cells);
    try std.testing.expectEqual(@as(u32, 1), info.rtl_base);
    try std.testing.expectEqual(@as(usize, 5), out.items.len);
    for (out.items, 0..) |p, vi| {
        try std.testing.expectEqual(@as(u32, @intCast(vi)), p.vcell);
        try std.testing.expectEqual(@as(u32, @intCast(4 - vi)), p.lcol);
    }
}

test "lam-alef is one glyph covering two cells" {
    var l = Layouter.init(std.testing.allocator);
    defer l.deinit();
    var out: std.ArrayList(Placed) = .empty;
    defer out.deinit(std.testing.allocator);
    const info = try testRow(&l, "لا", .a, .auto, &out);
    try std.testing.expectEqual(@as(u32, 2), info.n_cells);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
}

test "tashkeel stays attached to its base cell" {
    var l = Layouter.init(std.testing.allocator);
    defer l.deinit();
    var out: std.ArrayList(Placed) = .empty;
    defer out.deinit(std.testing.allocator);
    const info = try testRow(&l, "مُحَمَّد", .a, .auto, &out);
    try std.testing.expectEqual(@as(u32, 4), info.n_cells);
    try std.testing.expect(out.items.len > 4); // base glyphs plus mark glyphs
    var seen: [4]bool = .{ false, false, false, false };
    for (out.items) |p| {
        try std.testing.expect(p.vcell < 4 and p.lcol < 4);
        seen[p.vcell] = true;
    }
    for (seen) |s| try std.testing.expect(s);
}

fn extentLess(_: void, a: Extent, b: Extent) bool {
    return a.x0 < b.x0;
}

test "fit: a word fills exactly its cells and its extents tile the span" {
    var l = Layouter.init(std.testing.allocator);
    defer l.deinit();
    var out: std.ArrayList(Placed) = .empty;
    defer out.deinit(std.testing.allocator);
    const info = try testRow(&l, "السلام", .d, .auto, &out);
    try std.testing.expectEqual(@as(u32, 6), info.n_cells);
    try std.testing.expectEqual(@as(usize, 6), l.extents.items.len);

    const sorted = try std.testing.allocator.dupe(Extent, l.extents.items);
    defer std.testing.allocator.free(sorted);
    std.mem.sort(Extent, sorted, {}, extentLess);
    // cell_w is 10 in testRow, so the word spans 60 px.
    try std.testing.expectApproxEqAbs(@as(f32, 0), sorted[0].x0, 0.75);
    try std.testing.expectApproxEqAbs(@as(f32, 60), sorted[5].x1, 0.75);
    for (sorted[1..], 0..) |e, i| {
        try std.testing.expectApproxEqAbs(sorted[i].x1, e.x0, 0.75); // no gap, no overlap
        try std.testing.expect(e.x1 >= e.x0);
    }
    // every logical column appears exactly once
    var seen: [6]bool = .{ false, false, false, false, false, false };
    for (l.extents.items) |e| {
        try std.testing.expect(e.lcol < 6 and !seen[e.lcol]);
        seen[e.lcol] = true;
    }
    // drawn glyphs stay inside the span (kashida glyphs may share indices but never leave it)
    for (out.items) |p| try std.testing.expect(p.x > -1 and p.x < 61 and p.vcell < 6);
}

test "fit: Latin outside a word keeps whole cells" {
    var l = Layouter.init(std.testing.allocator);
    defer l.deinit();
    var out: std.ArrayList(Placed) = .empty;
    defer out.deinit(std.testing.allocator);
    _ = try testRow(&l, "ls", .d, .auto, &out);
    try std.testing.expectEqual(@as(usize, 2), l.extents.items.len);
    try std.testing.expectEqual(@as(f32, 0), l.extents.items[0].x0);
    try std.testing.expectEqual(@as(f32, 10), l.extents.items[0].x1);
    try std.testing.expectEqual(@as(f32, 10), l.extents.items[1].x0);
}
