//! Draws a terminal's visible grid with CoreText: one cell at a time at `col * cell_w`, so the grid
//! never drifts. No bidi and no joining here (Phase 4): an Arabic letter is drawn as its own cell.
const std = @import("std");
const ct = @import("shape/ct.zig");
const vt = @import("vt.zig");
const rowfacts = @import("rowfacts.zig");
const rowlayout = @import("rowlayout.zig");

pub const Metrics = struct { cell_w: f32, cell_h: f32, ascent: f32 };

pub const Glyph = struct { font: *const ct.CTFont, gid: u16 };

const Rgb3 = [3]f64;

/// Selected cells get this background (Decision 9); their foreground is kept.
const selection_bg: Rgb3 = .{ 0.22, 0.33, 0.55 };

fn rgb(c: vt.Rgb) Rgb3 {
    return .{ @as(f64, @floatFromInt(c.r)) / 255.0, @as(f64, @floatFromInt(c.g)) / 255.0, @as(f64, @floatFromInt(c.b)) / 255.0 };
}

/// The colors a cell is drawn with: inverse swaps foreground and background, faint blends the
/// foreground half way to the background. `has_bg` says the background differs from the default.
const CellColors = struct { fg: Rgb3, bg: Rgb3, has_bg: bool };

fn cellColors(style: vt.Style, selected: bool, d: vt.Colors) CellColors {
    var f = style.fg orelse d.fg;
    var b = style.bg orelse d.bg;
    if (style.flags & vt.Style.Flag.inverse != 0) std.mem.swap(vt.Rgb, &f, &b);
    var fc = rgb(f);
    const bc = rgb(b);
    if (style.flags & vt.Style.Flag.faint != 0) for (&fc, bc) |*x, y| {
        x.* = (x.* + y) / 2;
    };
    if (selected) return .{ .fg = fc, .bg = selection_bg, .has_bg = true };
    return .{ .fg = fc, .bg = bc, .has_bg = b.r != d.bg.r or b.g != d.bg.g or b.b != d.bg.b };
}

/// Face index: 0 regular, 1 bold, 2 italic, 3 bold italic.
fn faceOf(style: vt.Style) u2 {
    const F = vt.Style.Flag;
    return @as(u2, @intFromBool(style.flags & F.bold != 0)) | (@as(u2, @intFromBool(style.flags & F.italic != 0)) << 1);
}

/// A wide cell's spacer takes the wide cell's style (the library may leave it unstyled).
fn colorsAt(cells: []const vt.Cell, col: usize, d: vt.Colors) CellColors {
    const cell = if (cells[col].wide == .spacer_tail and col > 0) cells[col - 1] else cells[col];
    return cellColors(cell.style, cell.selected, d);
}

fn styleAt(cells: []const vt.Cell, col: usize) vt.Style {
    if (cells[col].wide == .spacer_tail and col > 0) return cells[col - 1].style;
    return cells[col].style;
}

/// The glyph cache stops growing here; lookups past it still work, just uncached.
const max_cached: usize = 4096;
const max_fallback_fonts: usize = 64;

pub const Painter = struct {
    /// Shaped rows kept between draws. Full means clear-all (a ponytail: per-row LRU if the numbers ask).
    pub const max_cached_rows: usize = 128;

    gpa: std.mem.Allocator,
    primary: *ct.CTFont,
    size_px: f32,
    metrics_: Metrics,
    /// Fonts CoreText picked for characters Menlo lacks (deduplicated, retained).
    fallbacks: std.ArrayList(*ct.CTFont) = .empty,
    /// Glyphs by codepoint and face (cp | face << 21).
    cache: std.AutoHashMapUnmanaged(u32, ?Glyph) = .empty,
    /// Regular, bold, italic, bold italic. `faces[0]` is `primary`; the others fall back to it if CoreText has no such face.
    faces: [4]*ct.CTFont,
    /// False draws the cursor as a hollow block (the window is not key).
    focused: bool = true,
    /// Thickness in pixels of underlines and cursor edges.
    line_px: f32,
    /// Base-direction policy for rows with Arabic (brief 4.4). No config UI before Phase 6.
    policy: rowfacts.Policy = .auto,
    /// Counters that make the fast path and the cache testable.
    stats: struct { shaped_rows: u32 = 0, plain_rows: u32 = 0, cache_hits: u32 = 0 } = .{},
    shaper: rowlayout.Shaper,
    /// Shaped rows by key: one byte of base direction, then the row text. The map compares whole keys,
    /// so a hash collision can never return another row's layout.
    rows: std.StringHashMapUnmanaged(rowlayout.RowLayout) = .empty,
    // Per-row scratch, reused so a draw does not allocate once warm.
    cell_store: std.ArrayList(u21) = .empty,
    cells: std.ArrayList(vt.Cell) = .empty,
    flat: std.ArrayList(u21) = .empty,
    text: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, size_px: f32) !*Painter {
        const name = ct.cfString("Menlo") orelse return error.FontUnavailable;
        defer ct.CFRelease(name);
        const font = ct.CTFontCreateWithName(name, size_px, null) orelse return error.FontUnavailable;
        errdefer ct.CFRelease(font);
        const self = try gpa.create(Painter);
        const ch = [_]ct.UniChar{'M'};
        var g = [_]ct.CGGlyph{0};
        _ = ct.CTFontGetGlyphsForCharacters(font, &ch, &g, 1);
        const asc = @ceil(ct.CTFontGetAscent(font));
        const desc = @ceil(ct.CTFontGetDescent(font));
        const lead = @ceil(ct.CTFontGetLeading(font));
        const cell_w: f32 = @floatCast(@round(ct.CTFontGetAdvancesForGlyphs(font, ct.orientation_horizontal, &g, null, 1)));
        const bold = ct.CTFontCreateCopyWithSymbolicTraits(font, size_px, null, ct.trait_bold, ct.trait_bold);
        const italic = ct.CTFontCreateCopyWithSymbolicTraits(font, size_px, null, ct.trait_italic, ct.trait_italic);
        const both = ct.CTFontCreateCopyWithSymbolicTraits(font, size_px, null, ct.trait_bold | ct.trait_italic, ct.trait_bold | ct.trait_italic);
        self.* = .{
            .gpa = gpa,
            .primary = font,
            .faces = .{ font, bold orelse font, italic orelse font, both orelse font },
            .line_px = @max(1, @round(size_px / 14)),
            .size_px = size_px,
            // The Arabic font is the primary font; CoreText's cascade picks the face (cell-model.md).
            .shaper = rowlayout.Shaper.init(gpa, font, cell_w),
            .metrics_ = .{
                .cell_w = cell_w,
                .cell_h = @floatCast(asc + desc + lead),
                .ascent = @floatCast(asc),
            },
        };
        return self;
    }

    pub fn deinit(self: *Painter) void {
        for (self.faces[1..]) |f| if (f != self.primary) ct.CFRelease(f);
        self.clearRows();
        self.rows.deinit(self.gpa);
        self.shaper.deinit();
        self.cell_store.deinit(self.gpa);
        self.cells.deinit(self.gpa);
        self.flat.deinit(self.gpa);
        self.text.deinit(self.gpa);
        for (self.fallbacks.items) |f| ct.CFRelease(f);
        self.fallbacks.deinit(self.gpa);
        self.cache.deinit(self.gpa);
        ct.CFRelease(self.primary);
        self.gpa.destroy(self);
    }

    pub fn metrics(self: *const Painter) Metrics {
        return self.metrics_;
    }

    /// The font and glyph that draw `cp`: Menlo if it has the character, else the font CoreText
    /// falls back to. Null if nothing has it.
    pub fn lookup(self: *Painter, cp: u21) ?Glyph {
        return self.lookupFace(cp, 0);
    }

    pub fn lookupFace(self: *Painter, cp: u21, face: u2) ?Glyph {
        const key: u32 = @as(u32, cp) | (@as(u32, face) << 21);
        if (self.cache.get(key)) |hit| return hit;
        const found = self.resolve(cp, face);
        if (self.cache.count() < max_cached) self.cache.put(self.gpa, key, found) catch {};
        return found;
    }

    fn resolve(self: *Painter, cp: u21, face: u2) ?Glyph {
        const base = self.faces[face];
        var units: [2]ct.UniChar = undefined;
        const n: usize = if (cp < 0x10000) blk: {
            units[0] = @intCast(cp);
            break :blk 1;
        } else blk: {
            const v = cp - 0x10000;
            units[0] = @intCast(0xD800 + (v >> 10));
            units[1] = @intCast(0xDC00 + (v & 0x3FF));
            break :blk 2;
        };
        var gids = [2]ct.CGGlyph{ 0, 0 };
        if (ct.CTFontGetGlyphsForCharacters(base, &units, &gids, @intCast(n)) and gids[0] != 0) {
            return .{ .font = base, .gid = gids[0] };
        }
        var utf8: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &utf8) catch return null;
        const str = ct.cfString(utf8[0..len]) orelse return null;
        defer ct.CFRelease(str);
        const fb = ct.CTFontCreateForString(base, str, .{ .location = 0, .length = @intCast(n) }) orelse return null;
        // CoreText returns a new reference every time; keep one per distinct font.
        var keep: *ct.CTFont = fb;
        for (self.fallbacks.items) |f| {
            if (ct.CFEqual(f, fb)) {
                keep = f;
                ct.CFRelease(fb);
                break;
            }
        } else if (self.fallbacks.items.len < max_fallback_fonts) {
            self.fallbacks.append(self.gpa, fb) catch {
                ct.CFRelease(fb);
                return null;
            };
        } else {
            ct.CFRelease(fb);
            return null;
        }
        gids = .{ 0, 0 };
        if (ct.CTFontGetGlyphsForCharacters(keep, &units, &gids, @intCast(n)) and gids[0] != 0) {
            return .{ .font = keep, .gid = gids[0] };
        }
        return null;
    }

    fn fill(ctx: *ct.CGContext, x: f64, y: f64, w: f64, h: f64, color: [3]f64) void {
        ct.CGContextSetRGBFillColor(ctx, color[0], color[1], color[2], 1);
        ct.CGContextFillRect(ctx, .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } });
    }

    fn drawCell(self: *Painter, ctx: *ct.CGContext, cps: []const u21, face: u2, x: f64, baseline: f64, color: [3]f64) void {
        ct.CGContextSetRGBFillColor(ctx, color[0], color[1], color[2], 1);
        for (cps) |cp| {
            if (cp == ' ') continue;
            const g = self.lookupFace(cp, face) orelse continue;
            ct.CGContextSaveGState(ctx);
            ct.CGContextTranslateCTM(ctx, 0, baseline);
            ct.CGContextScaleCTM(ctx, 1, -1); // the context is y-down: flip glyphs upright
            const gid = [1]ct.CGGlyph{g.gid};
            const pos = [1]ct.CGPoint{.{ .x = x, .y = 0 }};
            ct.CTFontDrawGlyphs(g.font, &gid, &pos, 1, ctx);
            ct.CGContextRestoreGState(ctx);
        }
    }

    pub const CellPos = struct { col: u16, row: u16 };

    /// The cell under the pixel (`x_px`, `y_px`) of the grid, clamped to the grid. On a shaped Arabic row the
    /// column comes from the layout, so it is the letter drawn under the pointer; elsewhere it is `x / cell_w`.
    /// Takes the render state, so the caller holds the session lock.
    pub fn cellAt(self: *Painter, term: *vt.Terminal, x_px: f64, y_px: f64) CellPos {
        const size = term.size();
        if (size.cols == 0 or size.rows == 0) return .{ .col = 0, .row = 0 };
        const m = self.metrics_;
        const rowf = std.math.clamp(@floor(y_px / m.cell_h), 0, @as(f64, @floatFromInt(size.rows - 1)));
        const row: u16 = @intFromFloat(rowf);
        const colf = std.math.clamp(@floor(x_px / m.cell_w), 0, @as(f64, @floatFromInt(size.cols - 1)));
        const plain: CellPos = .{ .col = @intFromFloat(colf), .row = row };
        if (!term.update() or !term.selectRow(row)) return plain;
        const cells = self.gather(term, size.cols) catch return plain;
        const rl = (self.shapedRow(cells) catch null) orelse return plain;
        if (x_px >= @as(f64, @floatFromInt(rl.n_cells)) * m.cell_w) return plain; // past the text: plain cells
        var best: u16 = 0;
        var best_d: f64 = std.math.inf(f64);
        for (rl.spans, 0..) |sp, i| {
            const d: f64 = if (x_px < sp.x0) sp.x0 - x_px else if (x_px > sp.x1) x_px - sp.x1 else 0;
            if (d < best_d) {
                best_d = d;
                best = @intCast(i);
            }
            if (d == 0) break;
        }
        return .{ .col = best, .row = row };
    }

    /// Reads the cells of the selected row (`term.selectRow` first). The slice is valid until the next call.
    fn gather(self: *Painter, term: *vt.Terminal, cols: u16) ![]const vt.Cell {
        try self.cell_store.resize(self.gpa, @as(usize, cols) * 16);
        try self.cells.resize(self.gpa, cols);
        for (0..cols) |col| {
            const buf: *[16]u21 = self.cell_store.items[col * 16 ..][0..16];
            self.cells.items[col] = term.cellInRow(@intCast(col), buf);
        }
        return self.cells.items;
    }

    fn clearRows(self: *Painter) void {
        var it = self.rows.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(self.gpa);
        }
        self.rows.clearRetainingCapacity();
    }

    /// The shaped layout for a gathered row, or null if the row draws plain (no RTL text, or it cannot
    /// be mapped one cell per character). The cache owns the result; it stays valid until the next call.
    fn shapedRow(self: *Painter, cells: []const vt.Cell) !?*const rowlayout.RowLayout {
        self.flat.clearRetainingCapacity();
        for (cells) |cell| {
            if (cell.wide == .spacer_tail or cell.wide == .spacer_head) continue;
            if (cell.cps.len == 0) try self.flat.append(self.gpa, ' ') else try self.flat.appendSlice(self.gpa, cell.cps);
        }
        const facts = rowfacts.analyze(self.flat.items, self.policy);
        if (!facts.needs_layout) return null;
        self.text.clearRetainingCapacity();
        try self.text.append(self.gpa, @intFromBool(facts.rtl_base)); // the key's first byte
        const n = (try rowlayout.rowText(cells, &self.text, self.gpa)) orelse return null;
        if (self.rows.getPtr(self.text.items)) |hit| {
            self.stats.cache_hits += 1;
            return hit;
        }
        var rl = (try self.shaper.shape(self.text.items[1..], n, facts.rtl_base)) orelse return null;
        errdefer rl.deinit(self.gpa);
        if (self.rows.count() >= max_cached_rows) self.clearRows();
        const key = try self.gpa.dupe(u8, self.text.items);
        errdefer self.gpa.free(key);
        try self.rows.put(self.gpa, key, rl);
        self.stats.shaped_rows += 1;
        return self.rows.getPtr(key);
    }

    /// Draws a shaped row's glyphs (each horizontally scaled by its `sx`) with the pen at `baseline`.
    /// With `flat` every glyph takes that color (the cursor's inverted pass); otherwise each glyph
    /// takes its cell's colors, and invisible cells draw nothing. Bold and italic are not applied:
    /// the layouter shapes a row with one font (Decision 3).
    fn drawShaped(self: *Painter, ctx: *ct.CGContext, rl: *const rowlayout.RowLayout, cells: []const vt.Cell, d: vt.Colors, baseline: f64, flat: ?Rgb3) void {
        for (rl.placed) |pl| {
            const color = if (flat) |f| f else blk: {
                if (pl.lcol >= cells.len) break :blk cellColors(.{}, false, d).fg;
                if (cells[pl.lcol].style.flags & vt.Style.Flag.invisible != 0) continue;
                break :blk colorsAt(cells, pl.lcol, d).fg;
            };
            ct.CGContextSetRGBFillColor(ctx, color[0], color[1], color[2], 1);
            ct.CGContextSaveGState(ctx);
            ct.CGContextTranslateCTM(ctx, pl.x, baseline);
            ct.CGContextScaleCTM(ctx, pl.sx, -1); // y-down context: flip glyphs upright
            const gid = [1]ct.CGGlyph{pl.gid};
            const pos = [1]ct.CGPoint{.{ .x = 0, .y = 0 }};
            ct.CTFontDrawGlyphs(self.shaper.layouter.font(pl.font_id), &gid, &pos, 1, ctx);
            ct.CGContextRestoreGState(ctx);
        }
    }

    /// Underline (any style) and strikethrough for one cell box `x .. x + w`.
    fn drawLines(self: *Painter, ctx: *ct.CGContext, style: vt.Style, cc: CellColors, x: f64, w: f64, top: f64) void {
        const m = self.metrics_;
        const th: f64 = self.line_px;
        const ch: f64 = m.cell_h;
        const base = top + m.ascent;
        const ul = style.underline();
        if (ul != .none) {
            const color = if (style.underline_color) |u| rgb(u) else cc.fg;
            // Below the baseline, inside the cell.
            const y1 = @min(base + @max(th, (ch - m.ascent) * 0.25), top + ch - th);
            switch (ul) {
                .none => {},
                .single => fill(ctx, x, y1, w, th, color),
                .double => {
                    const y2 = @min(y1 + 2 * th, top + ch - th);
                    fill(ctx, x, y2 - 2 * th, w, th, color);
                    fill(ctx, x, y2, w, th, color);
                },
                .curly => {
                    ct.CGContextSetRGBStrokeColor(ctx, color[0], color[1], color[2], 1);
                    ct.CGContextSetLineWidth(ctx, th);
                    const amp = th;
                    const yc = @min(y1 + th * 0.5, top + ch - th * 1.5 - amp * 0.5) - amp * 0.5;
                    ct.CGContextBeginPath(ctx);
                    ct.CGContextMoveToPoint(ctx, x, yc);
                    const step = @max(2, th * 2);
                    var dx: f64 = step;
                    var up = true;
                    while (dx < w + step) : (dx += step) {
                        ct.CGContextAddLineToPoint(ctx, @min(x + dx, x + w), if (up) yc + amp else yc);
                        up = !up;
                    }
                    ct.CGContextStrokePath(ctx);
                },
                .dotted => {
                    var dx: f64 = 0;
                    while (dx < w) : (dx += 2 * th) fill(ctx, x + dx, y1, @min(th, w - dx), th, color);
                },
                .dashed => {
                    var dx: f64 = 0;
                    while (dx < w) : (dx += 5 * th) fill(ctx, x + dx, y1, @min(3 * th, w - dx), th, color);
                },
            }
        }
        if (style.flags & vt.Style.Flag.strikethrough != 0) {
            fill(ctx, x, top + m.ascent * 0.6 - th * 0.5, w, th, cc.fg);
        }
    }

    /// Draws the cursor. `x0` and `bw` are the cell's pixel box; `inner` redraws the glyph under a solid block.
    fn drawCursor(self: *Painter, ctx: *ct.CGContext, cur: vt.Terminal.Cursor, d: vt.Colors, x0: f64, bw: f64, top: f64) bool {
        const m = self.metrics_;
        const ch: f64 = m.cell_h;
        const th: f64 = self.line_px;
        const color = if (cur.color) |c| rgb(c) else rgb(d.fg);
        const shape: vt.Terminal.CursorShape = if (!self.focused) .block_hollow else cur.shape;
        switch (shape) {
            .block => return true, // the caller fills the block and redraws the glyph
            .bar => fill(ctx, x0, top, th, ch, color),
            .underline => fill(ctx, x0, top + ch - th, bw, th, color),
            .block_hollow => {
                fill(ctx, x0, top, bw, th, color);
                fill(ctx, x0, top + ch - th, bw, th, color);
                fill(ctx, x0, top, th, ch, color);
                fill(ctx, x0 + bw - th, top, th, ch, color);
            },
        }
        return false;
    }

    /// Draws rows `first_row` to `last_row` (inclusive; clamped to the grid) and the cursor into a
    /// y-down context in device pixels whose origin is the grid's top-left. The caller holds the
    /// session lock. Refreshes the render state once. Rows with RTL text are shaped (Phase 4); all
    /// others are drawn one cell at a time. Colors and styles come from the terminal (slice 3).
    pub fn drawRows(self: *Painter, term: *vt.Terminal, ctx: *ct.CGContext, first_row: u16, last_row: u16) void {
        const size = term.size();
        if (size.rows == 0 or first_row >= size.rows or !term.update()) return;
        const last = @min(last_row, size.rows - 1);
        const m = self.metrics_;
        const cw: f64 = m.cell_w;
        const ch: f64 = m.cell_h;
        const grid_w = cw * @as(f64, @floatFromInt(size.cols));
        const d = term.colors();
        const default_bg = rgb(d.bg);
        ct.CGContextSaveGState(ctx);
        defer ct.CGContextRestoreGState(ctx);
        // Wide fallback glyphs must not spill past the grid.
        ct.CGContextClipToRect(ctx, .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = grid_w, .height = ch * @as(f64, @floatFromInt(size.rows)) } });
        const cur = term.cursor();
        var cursor_drawn = false;
        var row: u16 = first_row;
        while (row <= last) : (row += 1) {
            const top = ch * @as(f64, @floatFromInt(row));
            fill(ctx, 0, top, grid_w, ch, default_bg);
            if (!term.selectRow(row)) continue;
            const cells = self.gather(term, size.cols) catch continue;
            if ((self.shapedRow(cells) catch null)) |rl| {
                // Backgrounds by column box (columns past the text are plain cells), then glyphs, then lines.
                for (0..cells.len) |col| {
                    const sp = rl.span(@intCast(col), m.cell_w);
                    const cc = colorsAt(cells, col, d);
                    if (cc.has_bg) fill(ctx, sp.x0, top, sp.x1 - sp.x0, ch, cc.bg);
                }
                self.drawShaped(ctx, rl, cells, d, top + m.ascent, null);
                for (0..cells.len) |col| {
                    const st = styleAt(cells, col);
                    if (st.underline() == .none and st.flags & vt.Style.Flag.strikethrough == 0) continue;
                    const sp = rl.span(@intCast(col), m.cell_w);
                    self.drawLines(ctx, st, colorsAt(cells, col, d), sp.x0, sp.x1 - sp.x0, top);
                }
                if (cur) |c| if (c.visible and c.row == row and c.col < size.cols) {
                    const sp = rl.span(c.col, m.cell_w);
                    const bw: f64 = sp.x1 - sp.x0;
                    if (self.drawCursor(ctx, c, d, sp.x0, bw, top)) {
                        // A solid block covers the column's box and the row's glyphs are redrawn inverted inside it.
                        const color = if (c.color) |cc| rgb(cc) else rgb(d.fg);
                        fill(ctx, sp.x0, top, bw, ch, color);
                        ct.CGContextSaveGState(ctx);
                        ct.CGContextClipToRect(ctx, .{ .origin = .{ .x = sp.x0, .y = top }, .size = .{ .width = bw, .height = ch } });
                        self.drawShaped(ctx, rl, cells, d, top + m.ascent, default_bg);
                        ct.CGContextRestoreGState(ctx);
                    }
                    cursor_drawn = true;
                };
                continue;
            }
            self.stats.plain_rows += 1;
            // Backgrounds: runs of equal color.
            var col: usize = 0;
            while (col < cells.len) {
                const cc = colorsAt(cells, col, d);
                var end = col + 1;
                while (end < cells.len) : (end += 1) {
                    const next = colorsAt(cells, end, d);
                    if (!std.mem.eql(f64, &next.bg, &cc.bg)) break;
                }
                if (cc.has_bg) fill(ctx, cw * @as(f64, @floatFromInt(col)), top, cw * @as(f64, @floatFromInt(end - col)), ch, cc.bg);
                col = end;
            }
            // Glyphs, then lines.
            for (cells, 0..) |cell, ci| {
                if (cell.wide == .spacer_tail or cell.wide == .spacer_head or cell.cps.len == 0) continue;
                if (cell.style.flags & vt.Style.Flag.invisible != 0) continue;
                self.drawCell(ctx, cell.cps, faceOf(cell.style), cw * @as(f64, @floatFromInt(ci)), top + m.ascent, colorsAt(cells, ci, d).fg);
            }
            for (0..cells.len) |ci| {
                const st = styleAt(cells, ci);
                if (st.underline() == .none and st.flags & vt.Style.Flag.strikethrough == 0) continue;
                self.drawLines(ctx, st, colorsAt(cells, ci, d), cw * @as(f64, @floatFromInt(ci)), cw, top);
            }
        }
        const c = cur orelse return;
        if (cursor_drawn or !c.visible or c.row < first_row or c.row > last or c.col >= size.cols) return;
        const top = ch * @as(f64, @floatFromInt(c.row));
        const x = cw * @as(f64, @floatFromInt(c.col));
        var buf: [16]u21 = undefined;
        var cell: vt.Cell = .{ .cps = buf[0..0], .wide = .narrow };
        if (term.selectRow(c.row)) cell = term.cellInRow(c.col, &buf);
        const bw: f64 = if (cell.wide == .wide) cw * 2 else cw; // the block covers both halves of a wide glyph
        if (self.drawCursor(ctx, c, d, x, bw, top)) {
            fill(ctx, x, top, bw, ch, if (c.color) |cc| rgb(cc) else rgb(d.fg));
            if (cell.style.flags & vt.Style.Flag.invisible == 0) self.drawCell(ctx, cell.cps, faceOf(cell.style), x, top + m.ascent, default_bg); // the glyph under the block, inverted
        }
    }
};

// ---- tests ----

/// A BGRA bitmap drawn y-down, like the window's context.
const Canvas = struct {
    w: usize,
    h: usize,
    data: []u8,
    ctx: *ct.CGContext,

    fn init(w: usize, h: usize) !Canvas {
        const data = try std.testing.allocator.alloc(u8, w * h * 4);
        @memset(data, 0);
        const space = ct.CGColorSpaceCreateDeviceRGB() orelse return error.NoColorSpace;
        defer ct.CGColorSpaceRelease(space);
        // premultiplied-first, 32-bit little endian: bytes are B, G, R, A
        const ctx = ct.CGBitmapContextCreate(data.ptr, w, h, 8, w * 4, space, 2 | (2 << 12)) orelse return error.NoContext;
        ct.CGContextTranslateCTM(ctx, 0, @floatFromInt(h));
        ct.CGContextScaleCTM(ctx, 1, -1);
        return .{ .w = w, .h = h, .data = data, .ctx = ctx };
    }
    fn deinit(self: Canvas) void {
        ct.CGContextRelease(self.ctx);
        std.testing.allocator.free(self.data);
    }
    fn px(self: Canvas, x: usize, y: usize) [3]u8 {
        const i = (y * self.w + x) * 4;
        return .{ self.data[i + 2], self.data[i + 1], self.data[i] }; // R, G, B
    }
    fn isBg(self: Canvas, x: usize, y: usize) bool {
        const p = self.px(x, y);
        const want = [3]u8{ 15, 15, 18 };
        for (p, want) |a, b| if (@abs(@as(i32, a) - @as(i32, b)) > 6) return false;
        return true;
    }
    /// Any non-background pixel in the box?
    fn inkIn(self: Canvas, x0: usize, y0: usize, x1: usize, y1: usize) bool {
        var y = y0;
        while (y < @min(y1, self.h)) : (y += 1) {
            var x = x0;
            while (x < @min(x1, self.w)) : (x += 1) if (!self.isBg(x, y)) return true;
        }
        return false;
    }
};

const test_px: f32 = 28;

fn cellBox(m: Metrics, col: usize, row: usize) [4]usize {
    const cw: usize = @intFromFloat(m.cell_w);
    const chh: usize = @intFromFloat(m.cell_h);
    return .{ col * cw, row * chh, (col + 1) * cw, (row + 1) * chh };
}

test "metrics are positive and cell width is whole pixels" {
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    const m = p.metrics();
    try std.testing.expect(m.cell_w > 0 and m.cell_h > m.ascent and m.ascent > 0);
    try std.testing.expectEqual(@round(m.cell_w), m.cell_w);
}

test "lookup: ascii is Menlo, arabic is a cached fallback" {
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    const a = p.lookup('a').?;
    try std.testing.expect(a.font == p.primary and a.gid != 0);
    const m1 = p.lookup(0x0645).?;
    try std.testing.expect(m1.font != p.primary and m1.gid != 0);
    const m2 = p.lookup(0x0645).?;
    try std.testing.expect(m1.font == m2.font and m1.gid == m2.gid);
}

test "draw: text inks its cells only" {
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    const t = try vt.Terminal.init(std.testing.allocator, .{ .cols = 20, .rows = 3 });
    defer t.deinit();
    t.write("abc");
    const m = p.metrics();
    const cv = try Canvas.init(@intFromFloat(m.cell_w * 20), @intFromFloat(m.cell_h * 3));
    defer cv.deinit();
    p.drawRows(t, cv.ctx, 0, 2);
    for (0..3) |col| {
        const b = cellBox(m, col, 0);
        try std.testing.expect(cv.inkIn(b[0], b[1], b[2], b[3]));
    }
    const rest = cellBox(m, 5, 0);
    try std.testing.expect(!cv.inkIn(rest[0], rest[1], cv.w, rest[3]));
    try std.testing.expect(!cv.inkIn(0, cellBox(m, 0, 1)[1], cv.w, cv.h));
}

test "draw: cursor is a foreground block, hidden when the program hides it" {
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    const t = try vt.Terminal.init(std.testing.allocator, .{ .cols = 20, .rows = 3 });
    defer t.deinit();
    t.write("abc");
    const m = p.metrics();
    const cv = try Canvas.init(@intFromFloat(m.cell_w * 20), @intFromFloat(m.cell_h * 3));
    defer cv.deinit();
    p.drawRows(t, cv.ctx, 0, 2);
    const b = cellBox(m, 3, 0);
    const corner = cv.px(b[0] + 1, b[1] + 1);
    try std.testing.expect(corner[0] > 200 and corner[1] > 200);
    t.write("\x1b[?25l");
    p.drawRows(t, cv.ctx, 0, 2);
    try std.testing.expect(cv.isBg(b[0] + 1, b[1] + 1));
}

test "draw: arabic letters and tashkeel ink their cells" {
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    const t = try vt.Terminal.init(std.testing.allocator, .{ .cols = 20, .rows = 3 });
    defer t.deinit();
    t.write("\u{645}\u{64E}\u{631}\u{62D}\u{628}\u{627}");
    t.write("\x1b[?25l");
    const m = p.metrics();
    const cv = try Canvas.init(@intFromFloat(m.cell_w * 20), @intFromFloat(m.cell_h * 3));
    defer cv.deinit();
    p.drawRows(t, cv.ctx, 0, 2);
    for (0..5) |col| {
        const b = cellBox(m, col, 0);
        try std.testing.expect(cv.inkIn(b[0], b[1], b[2], b[3]));
    }
}

test "draw clamps rows" {
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    const m = p.metrics();
    const cv = try Canvas.init(@intFromFloat(m.cell_w * 40), @intFromFloat(m.cell_h * 10));
    defer cv.deinit();
    const small = try vt.Terminal.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer small.deinit();
    p.drawRows(small, cv.ctx, 0, 500);
    p.drawRows(small, cv.ctx, 7, 9); // past the grid: nothing to draw
    const one = try vt.Terminal.init(std.testing.allocator, .{ .cols = 1, .rows = 1 });
    defer one.deinit();
    one.write("xyz");
    p.drawRows(one, cv.ctx, 0, 9);
    const big = try vt.Terminal.init(std.testing.allocator, .{ .cols = 40, .rows = 10 });
    defer big.deinit();
    big.write("hello\r\nworld");
    big.resize(3, 1, 0, 0);
    p.drawRows(big, cv.ctx, 0, 9);
}

// ---- Phase 4: shaped Arabic rows ----

/// Longest run of pixel columns without ink between the first and last inked column of the box.
fn maxBlankRun(cv: Canvas, x0: usize, x1: usize, y0: usize, y1: usize) usize {
    var first: ?usize = null;
    var last: usize = 0;
    var x = x0;
    while (x < @min(x1, cv.w)) : (x += 1) {
        if (cv.inkIn(x, y0, x + 1, y1)) {
            if (first == null) first = x;
            last = x;
        }
    }
    const f = first orelse return std.math.maxInt(usize);
    var best: usize = 0;
    var run: usize = 0;
    x = f;
    while (x <= last) : (x += 1) {
        if (cv.inkIn(x, y0, x + 1, y1)) run = 0 else {
            run += 1;
            best = @max(best, run);
        }
    }
    return best;
}

/// True if nothing was drawn in the box: outside the grid the canvas keeps its initial transparent black.
fn untouched(cv: Canvas, x0: usize, y0: usize, x1: usize, y1: usize) bool {
    var y = y0;
    while (y < @min(y1, cv.h)) : (y += 1) {
        var x = x0;
        while (x < @min(x1, cv.w)) : (x += 1) if (cv.data[(y * cv.w + x) * 4 + 3] != 0) return false;
    }
    return true;
}

fn anyDarkIn(cv: Canvas, x0: usize, y0: usize, x1: usize, y1: usize) bool {
    var y = y0;
    while (y < @min(y1, cv.h)) : (y += 1) {
        var x = x0;
        while (x < @min(x1, cv.w)) : (x += 1) if (cv.px(x, y)[0] < 60) return true;
    }
    return false;
}

fn testScreen(p: *Painter, cols: u16, rows: u16, canvas_cols: usize, text: []const u8) !struct { t: *vt.Terminal, cv: Canvas } {
    const t = try vt.Terminal.init(std.testing.allocator, .{ .cols = cols, .rows = rows });
    errdefer t.deinit();
    t.write(text);
    const m = p.metrics();
    const cv = try Canvas.init(@intFromFloat(m.cell_w * @as(f32, @floatFromInt(canvas_cols))), @intFromFloat(m.cell_h * @as(f32, @floatFromInt(rows))));
    p.drawRows(t, cv.ctx, 0, rows - 1);
    return .{ .t = t, .cv = cv };
}

/// The layout the painter would use for visible row `row` (null if the row draws plain).
fn testLayout(p: *Painter, t: *vt.Terminal, row: u16) !?*const rowlayout.RowLayout {
    _ = t.update();
    _ = t.selectRow(row);
    const cells = try p.gather(t, t.size().cols);
    return p.shapedRow(cells);
}

test "latin rows take the plain path" {
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    const s = try testScreen(p, 20, 3, 20, "hello\r\nls -la");
    defer s.t.deinit();
    defer s.cv.deinit();
    try std.testing.expectEqual(@as(u32, 0), p.stats.shaped_rows);
    try std.testing.expectEqual(@as(u32, 3), p.stats.plain_rows);
}

test "arabic word is joined" {
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    p.policy = .ltr;
    const s = try testScreen(p, 20, 2, 20, "  \u{628}\u{64A}\u{62A}\u{64A}\x1b[?25l");
    defer s.t.deinit();
    defer s.cv.deinit();
    const m = p.metrics();
    try std.testing.expectEqual(@as(u32, 1), p.stats.shaped_rows);
    const b = cellBox(m, 2, 0);
    const word_end = cellBox(m, 5, 0)[2];
    try std.testing.expect(s.cv.inkIn(b[0], b[1], word_end, b[3]));
    try std.testing.expect(!s.cv.inkIn(0, b[1], b[0], b[3])); // nothing before the word
    try std.testing.expect(!s.cv.inkIn(word_end, b[1], s.cv.w, b[3])); // nothing after it
    try std.testing.expect(maxBlankRun(s.cv, b[0], word_end, b[1], b[3]) <= 1);
}

test "box row keeps its bars" {
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    const s = try testScreen(p, 20, 2, 20, "\u{2502} \u{645}\u{631}\u{62D}\u{628}\u{627}    \u{2502}\x1b[?25l");
    defer s.t.deinit();
    defer s.cv.deinit();
    const m = p.metrics();
    try std.testing.expectEqual(@as(u32, 1), p.stats.shaped_rows);
    for ([_]usize{ 0, 11 }) |col| {
        const b = cellBox(m, col, 0);
        const cx = (b[0] + b[2]) / 2;
        try std.testing.expect(s.cv.inkIn(cx, b[1], cx + 1, b[3]));
    }
    try std.testing.expect(!s.cv.inkIn(cellBox(m, 12, 0)[0], 0, s.cv.w, cellBox(m, 0, 0)[3]));
}

test "rtl row is right to left" {
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    const t = try vt.Terminal.init(std.testing.allocator, .{ .cols = 20, .rows = 2 });
    defer t.deinit();
    t.write("\u{645}\u{631}\u{62D}\u{628}\u{627}");
    const rl = (try testLayout(p, t, 0)).?;
    try std.testing.expect(rl.rtl_base);
    try std.testing.expect(rl.span(0, p.metrics().cell_w).x0 > rl.span(4, p.metrics().cell_w).x0);
}

test "cursor box on a shaped row" {
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    const s = try testScreen(p, 30, 2, 30, "\u{645}\u{631}\u{62D}\u{628}\u{627}\x1b[1;3H");
    defer s.t.deinit();
    defer s.cv.deinit();
    const rl = (try testLayout(p, s.t, 0)).?;
    const m = p.metrics();
    const sp = rl.span(2, m.cell_w);
    const x0: usize = @intFromFloat(@ceil(sp.x0));
    const x1: usize = @intFromFloat(@floor(sp.x1));
    try std.testing.expect(s.cv.px(x0 + 1, 1)[0] > 200); // the block is the foreground color
    try std.testing.expect(anyDarkIn(s.cv, x0, 0, x1, @intFromFloat(m.cell_h))); // the letter, inverted
    // past the end of the text: a plain cell
    s.t.write("\x1b[1;21H");
    p.drawRows(s.t, s.cv.ctx, 0, 1);
    const past = cellBox(m, 20, 0);
    try std.testing.expect(s.cv.px(past[0] + 1, 1)[0] > 200);
}

test "wide cell row takes the plain path" {
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    const s = try testScreen(p, 20, 2, 20, "\u{645}\u{631}\u{62D}\u{628}\u{627} \u{4E2D}");
    defer s.t.deinit();
    defer s.cv.deinit();
    try std.testing.expectEqual(@as(u32, 0), p.stats.shaped_rows);
    try std.testing.expectEqual(@as(u32, 2), p.stats.plain_rows);
}

test "full width row stays inside the grid" {
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    const unit = "\u{628}\u{64A}\u{62A}\u{64A}";
    var line: [unit.len * 10 + 6]u8 = undefined;
    for (0..10) |i| @memcpy(line[i * unit.len ..][0..unit.len], unit);
    @memcpy(line[unit.len * 10 ..], "\x1b[?25l");
    const s = try testScreen(p, 40, 2, 60, &line);
    defer s.t.deinit();
    defer s.cv.deinit();
    const m = p.metrics();
    try std.testing.expectEqual(@as(u32, 1), p.stats.shaped_rows);
    const gw: usize = @intFromFloat(m.cell_w * 40);
    try std.testing.expect(s.cv.inkIn(0, 0, gw, @intFromFloat(m.cell_h)));
    try std.testing.expect(untouched(s.cv, gw, 0, s.cv.w, s.cv.h));
}

test "tiny grids" {
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    inline for (.{ 1, 2 }) |cols| {
        const s = try testScreen(p, cols, 2, 10, "\u{645}\u{631}\u{62D}\u{628}\u{627}");
        defer s.t.deinit();
        defer s.cv.deinit();
        const m = p.metrics();
        const gw: usize = @intFromFloat(m.cell_w * cols);
        try std.testing.expect(untouched(s.cv, gw, 0, s.cv.w, s.cv.h));
    }
}

test "same row twice shapes once" {
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    const s = try testScreen(p, 20, 2, 20, "\u{645}\u{631}\u{62D}\u{628}\u{627}");
    defer s.t.deinit();
    defer s.cv.deinit();
    p.drawRows(s.t, s.cv.ctx, 0, 1);
    try std.testing.expectEqual(@as(u32, 1), p.stats.shaped_rows);
    try std.testing.expectEqual(@as(u32, 1), p.stats.cache_hits);
}

test "changed row is reshaped" {
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    const s = try testScreen(p, 20, 2, 20, "\u{645}\u{631}\u{62D}\u{628}\u{627}\x1b[?25l");
    defer s.t.deinit();
    defer s.cv.deinit();
    const before = try std.testing.allocator.dupe(u8, s.cv.data);
    defer std.testing.allocator.free(before);
    s.t.write("\x1b[1;1H\x1b[2K\u{645}\u{631}\u{62D}\u{628}\u{64A}");
    p.drawRows(s.t, s.cv.ctx, 0, 1);
    try std.testing.expect(!std.mem.eql(u8, before, s.cv.data));
    try std.testing.expectEqual(@as(u32, 2), p.stats.shaped_rows);
}

test "cached and fresh draws match" {
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    const s = try testScreen(p, 20, 2, 20, "\u{645}\u{64F}\u{62D}\u{645}\u{651}\u{62F} \u{644}\u{627} ab");
    defer s.t.deinit();
    defer s.cv.deinit();
    const cold = try std.testing.allocator.dupe(u8, s.cv.data);
    defer std.testing.allocator.free(cold);
    p.drawRows(s.t, s.cv.ctx, 0, 1);
    try std.testing.expectEqual(@as(u32, 1), p.stats.cache_hits);
    try std.testing.expectEqualSlices(u8, cold, s.cv.data);
}

test "cache is capped" {
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    const s = try testScreen(p, 40, 2, 40, "");
    defer s.t.deinit();
    defer s.cv.deinit();
    var buf: [64]u8 = undefined;
    for (0..1000) |i| {
        const line = try std.fmt.bufPrint(&buf, "\x1b[1;1H\x1b[2K\u{645}\u{631}\u{62D}\u{628}\u{627} {d}", .{i});
        s.t.write(line);
        p.drawRows(s.t, s.cv.ctx, 0, 1);
        try std.testing.expect(p.rows.count() <= Painter.max_cached_rows);
    }
    try std.testing.expectEqual(@as(u32, 1000), p.stats.shaped_rows);
}

// ---- slice 3: colors and styles ----

fn near(p: [3]u8, r: u8, g: u8, b: u8, tol: u8) bool {
    return @abs(@as(i32, p[0]) - r) <= tol and @abs(@as(i32, p[1]) - g) <= tol and @abs(@as(i32, p[2]) - b) <= tol;
}

fn anyNear(cv: Canvas, box: [4]usize, r: u8, g: u8, b: u8, tol: u8) bool {
    var y = box[1];
    while (y < @min(box[3], cv.h)) : (y += 1) {
        var x = box[0];
        while (x < @min(box[2], cv.w)) : (x += 1) if (near(cv.px(x, y), r, g, b, tol)) return true;
    }
    return false;
}

fn inkCount(cv: Canvas, box: [4]usize) usize {
    var n: usize = 0;
    var y = box[1];
    while (y < @min(box[3], cv.h)) : (y += 1) {
        var x = box[0];
        while (x < @min(box[2], cv.w)) : (x += 1) if (!cv.isBg(x, y)) {
            n += 1;
        };
    }
    return n;
}

fn rowBand(m: Metrics, row: usize, from: f32, to: f32, cols: usize) [4]usize {
    const top: f32 = m.cell_h * @as(f32, @floatFromInt(row));
    return .{ 0, @intFromFloat(top + from), @intFromFloat(m.cell_w * @as(f32, @floatFromInt(cols))), @intFromFloat(top + to) };
}

test "foreground and background colors" {
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    const s = try testScreen(p, 20, 2, 20, "\x1b[?25l\x1b[38;2;200;10;10;48;2;10;10;200mA\x1b[0mB");
    defer s.t.deinit();
    defer s.cv.deinit();
    const m = p.metrics();
    const a = cellBox(m, 0, 0);
    try std.testing.expect(near(s.cv.px(a[0] + 1, a[1] + 1), 10, 10, 200, 2)); // background
    try std.testing.expect(anyNear(s.cv, a, 200, 10, 10, 30)); // the letter
    try std.testing.expect(s.cv.isBg(cellBox(m, 5, 0)[0] + 1, 1)); // untouched cells keep the theme
    const pal = try testScreen(p, 20, 2, 20, "\x1b[?25l\x1b[31;44mA\x1b[38;5;196mB");
    defer pal.t.deinit();
    defer pal.cv.deinit();
    const c4 = pal.t.paletteColor(4);
    try std.testing.expect(near(pal.cv.px(a[0] + 1, a[1] + 1), c4.r, c4.g, c4.b, 2));
    try std.testing.expect(anyNear(pal.cv, cellBox(m, 1, 0), 255, 0, 0, 30));
}

test "erased cells keep their background" {
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    const s = try testScreen(p, 20, 2, 20, "\x1b[?25l\x1b[41m\x1b[2K");
    defer s.t.deinit();
    defer s.cv.deinit();
    const m = p.metrics();
    const red = s.t.paletteColor(1);
    const last = cellBox(m, 19, 0);
    try std.testing.expect(near(s.cv.px(last[0] + 1, last[1] + 1), red.r, red.g, red.b, 2));
    try std.testing.expect(s.cv.isBg(1, cellBox(m, 0, 1)[1] + 1)); // the next row is not
}

test "wide cell background" {
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    const s = try testScreen(p, 20, 2, 20, "\x1b[?25l\x1b[42m\u{65E5}\x1b[0m");
    defer s.t.deinit();
    defer s.cv.deinit();
    const m = p.metrics();
    const green = s.t.paletteColor(2);
    for ([_]usize{ 0, 1 }) |col| {
        const b = cellBox(m, col, 0);
        try std.testing.expect(near(s.cv.px(b[2] - 1, b[1] + 1), green.r, green.g, green.b, 2));
    }
    try std.testing.expect(s.cv.isBg(cellBox(m, 2, 0)[0] + 1, 1));
}

test "inverse swaps" {
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    const s = try testScreen(p, 20, 2, 20, "\x1b[?25l\x1b[7mH");
    defer s.t.deinit();
    defer s.cv.deinit();
    const b = cellBox(p.metrics(), 0, 0);
    try std.testing.expect(s.cv.px(b[0] + 1, b[1] + 1)[0] > 200); // a foreground-colored cell
    try std.testing.expect(anyDarkIn(s.cv, b[0], b[1], b[2], b[3])); // with background-colored ink
}

test "faint and invisible" {
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    const s = try testScreen(p, 20, 2, 20, "\x1b[?25lH\x1b[2mH\x1b[0m\x1b[8mH");
    defer s.t.deinit();
    defer s.cv.deinit();
    const m = p.metrics();
    var normal_max: u8 = 0;
    var faint_max: u8 = 0;
    const n = cellBox(m, 0, 0);
    const f = cellBox(m, 1, 0);
    var y = n[1];
    while (y < n[3]) : (y += 1) {
        var x: usize = 0;
        while (x < n[2] - n[0]) : (x += 1) {
            normal_max = @max(normal_max, s.cv.px(n[0] + x, y)[0]);
            faint_max = @max(faint_max, s.cv.px(f[0] + x, y)[0]);
        }
    }
    try std.testing.expect(faint_max < normal_max and faint_max > 40);
    const inv = cellBox(m, 2, 0);
    try std.testing.expect(!s.cv.inkIn(inv[0], inv[1], inv[2], inv[3]));
}

test "bold and italic draw differently" {
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    const s = try testScreen(p, 20, 2, 20, "\x1b[?25lH\x1b[1mH\x1b[0m\x1b[3mH\x1b[0m");
    defer s.t.deinit();
    defer s.cv.deinit();
    const m = p.metrics();
    const regular = inkCount(s.cv, cellBox(m, 0, 0));
    try std.testing.expect(inkCount(s.cv, cellBox(m, 1, 0)) > regular); // bold has more ink
    var differs = false;
    const a = cellBox(m, 0, 0);
    const c = cellBox(m, 2, 0);
    for (0..a[2] - a[0]) |dx| {
        for (a[1]..a[3]) |y| {
            if (!std.mem.eql(u8, &s.cv.px(a[0] + dx, y), &s.cv.px(c[0] + dx, y))) differs = true;
        }
    }
    try std.testing.expect(differs); // italic is not the regular face
}

test "underline and strike" {
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    // one underline style per row, three blank cells each; row 5 is strikethrough
    const s = try testScreen(p, 6, 6, 6, "\x1b[?25l\x1b[4m   \x1b[0m\r\n\x1b[21m   \x1b[0m\r\n\x1b[4:3m   \x1b[0m\r\n\x1b[4:4m   \x1b[0m\r\n\x1b[4:5m   \x1b[0m\r\n\x1b[9m   \x1b[0m");
    defer s.t.deinit();
    defer s.cv.deinit();
    const m = p.metrics();
    for (0..5) |row| {
        try std.testing.expect(inkCount(s.cv, rowBand(m, row, m.ascent, m.cell_h, 3)) > 0); // below the baseline
        try std.testing.expect(inkCount(s.cv, rowBand(m, row, 0, m.ascent - 1, 3)) == 0); // nothing above it
    }
    try std.testing.expect(inkCount(s.cv, rowBand(m, 5, m.ascent * 0.2, m.ascent * 0.9, 3)) > 0); // strike through the middle
    try std.testing.expect(inkCount(s.cv, rowBand(m, 5, m.ascent + 2, m.cell_h, 3)) == 0);
    // underline color
    const c = try testScreen(p, 6, 2, 6, "\x1b[?25l\x1b[4m\x1b[58;2;0;200;0m   ");
    defer c.t.deinit();
    defer c.cv.deinit();
    try std.testing.expect(anyNear(c.cv, rowBand(m, 0, m.ascent, m.cell_h, 3), 0, 200, 0, 20));
}

test "shaped row colors" {
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    const word = "\u{645}\u{631}\u{62D}\u{628}\u{627}";
    const s = try testScreen(p, 20, 2, 20, "\x1b[?25l\x1b[38;2;220;10;10;48;2;10;10;200m" ++ word ++ "\x1b[0m");
    defer s.t.deinit();
    defer s.cv.deinit();
    const m = p.metrics();
    try std.testing.expectEqual(@as(u32, 1), p.stats.shaped_rows);
    const b = cellBox(m, 0, 0);
    try std.testing.expect(near(s.cv.px(b[0] + 1, b[1] + 1), 10, 10, 200, 2));
    try std.testing.expect(anyNear(s.cv, rowBand(m, 0, 0, m.cell_h, 5), 220, 10, 10, 30));
    try std.testing.expect(s.cv.isBg(cellBox(m, 6, 0)[0] + 1, 1)); // the span ends with the word
    // bold is ignored on a shaped row (Decision 3): the same pixels as regular
    const plain = try testScreen(p, 20, 2, 20, "\x1b[?25l" ++ word);
    defer plain.t.deinit();
    defer plain.cv.deinit();
    const bold = try testScreen(p, 20, 2, 20, "\x1b[?25l\x1b[1m" ++ word);
    defer bold.t.deinit();
    defer bold.cv.deinit();
    try std.testing.expectEqualSlices(u8, plain.cv.data, bold.cv.data);
}

test "cursor shapes and focus" {
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    const m = p.metrics();
    const w: usize = @intFromFloat(m.cell_w);
    // steady bar: 2 px at the left of the cell, nothing at its right
    const bar = try testScreen(p, 10, 2, 10, "\x1b[6 q");
    defer bar.t.deinit();
    defer bar.cv.deinit();
    try std.testing.expect(bar.cv.px(0, 3)[0] > 200 and bar.cv.px(1, 3)[0] > 200);
    try std.testing.expect(bar.cv.isBg(w - 2, 3));
    // steady underline: the bottom rows only
    const ul = try testScreen(p, 10, 2, 10, "\x1b[4 q");
    defer ul.t.deinit();
    defer ul.cv.deinit();
    try std.testing.expect(ul.cv.px(w / 2, @as(usize, @intFromFloat(m.cell_h)) - 1)[0] > 200);
    try std.testing.expect(ul.cv.isBg(w / 2, 2));
    // unfocused: a hollow block (edge solid, interior background)
    p.focused = false;
    const hollow = try testScreen(p, 10, 2, 10, "\x1b[2 q");
    defer hollow.t.deinit();
    defer hollow.cv.deinit();
    try std.testing.expect(hollow.cv.px(0, 3)[0] > 200);
    try std.testing.expect(hollow.cv.isBg(w / 2, @as(usize, @intFromFloat(m.cell_h)) / 2));
    p.focused = true;
    const block = try testScreen(p, 10, 2, 10, "\x1b[2 q");
    defer block.t.deinit();
    defer block.cv.deinit();
    try std.testing.expect(block.cv.px(w / 2, @as(usize, @intFromFloat(m.cell_h)) / 2)[0] > 200);
}

test "cursor on an inverse cell stays legible" {
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    const s = try testScreen(p, 10, 2, 10, "\x1b[7mH\x1b[0m\x1b[1D");
    defer s.t.deinit();
    defer s.cv.deinit();
    const b = cellBox(p.metrics(), 0, 0);
    // the glyph must still be visible against the cursor block
    var lo: u8 = 255;
    var hi: u8 = 0;
    for (b[1]..b[3]) |y| for (b[0]..b[2]) |x| {
        const v = s.cv.px(x, y)[0];
        lo = @min(lo, v);
        hi = @max(hi, v);
    };
    try std.testing.expect(hi - lo > 100);
}

// ---- slice 3: hit-testing ----

test "cell lookup on plain and shaped rows" {
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    const m = p.metrics();
    const t = try vt.Terminal.init(std.testing.allocator, .{ .cols = 20, .rows = 3 });
    defer t.deinit();
    t.write("hello\r\n\u{645}\u{631}\u{62D}\u{628}\u{627}");
    const cw: f64 = m.cell_w;
    const chh: f64 = m.cell_h;
    // plain row: x / cell_w, y / cell_h
    const a = p.cellAt(t, cw * 3.5, chh * 0.5);
    try std.testing.expectEqual(@as(u16, 3), a.col);
    try std.testing.expectEqual(@as(u16, 0), a.row);
    // clamps: negative and far outside
    const neg = p.cellAt(t, -50, -50);
    try std.testing.expectEqual(@as(u16, 0), neg.col);
    try std.testing.expectEqual(@as(u16, 0), neg.row);
    const far = p.cellAt(t, 99999, 99999);
    try std.testing.expectEqual(@as(u16, 19), far.col);
    try std.testing.expectEqual(@as(u16, 2), far.row);
    // shaped row 1: the point inside the second letter's span is column 1; the first letter is rightmost
    var rl = (try testLayout(p, t, 1)).?;
    const second = rl.span(1, m.cell_w);
    const hit = p.cellAt(t, (second.x0 + second.x1) / 2, chh * 1.5);
    try std.testing.expectEqual(@as(u16, 1), hit.col);
    try std.testing.expectEqual(@as(u16, 1), hit.row);
    const first = rl.span(0, m.cell_w);
    try std.testing.expectEqual(@as(u16, 0), p.cellAt(t, (first.x0 + first.x1) / 2, chh * 1.5).col);
    // past the text: the plain column
    try std.testing.expectEqual(@as(u16, 12), p.cellAt(t, cw * 12.5, chh * 1.5).col);
}

test "selection draws on plain and shaped rows" {
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    const m = p.metrics();
    const t = try vt.Terminal.init(std.testing.allocator, .{ .cols = 20, .rows = 3 });
    defer t.deinit();
    t.write("\x1b[?25lhello world\r\n\u{645}\u{631}\u{62D}\u{628}\u{627}");
    t.selectionPress(2, 0, 1);
    t.selectionDrag(4, 0);
    t.selectionRelease();
    t.selectionPress(1, 1, 1);
    t.selectionDrag(2, 1);
    t.selectionRelease();
    const cv = try Canvas.init(@intFromFloat(m.cell_w * 20), @intFromFloat(m.cell_h * 3));
    defer cv.deinit();
    p.drawRows(t, cv.ctx, 0, 2);
    const sel = [3]u8{ 56, 84, 140 }; // selection_bg as pixels
    // the first selection was replaced by the second (one selection at a time): row 0 is not highlighted
    try std.testing.expect(!near(cv.px(cellBox(m, 3, 0)[0] + 1, 1), sel[0], sel[1], sel[2], 3));
    // shaped row 1: columns 1 and 2 highlighted inside their spans, column 4 not
    var rl = (try testLayout(p, t, 1)).?;
    for ([_]u16{ 1, 2 }) |col| {
        const sp = rl.span(col, m.cell_w);
        const x: usize = @intFromFloat(@ceil(sp.x0) + 1);
        try std.testing.expect(near(cv.px(x, @as(usize, @intFromFloat(m.cell_h)) + 1), sel[0], sel[1], sel[2], 3));
    }
    const out = rl.span(4, m.cell_w);
    try std.testing.expect(!near(cv.px(@as(usize, @intFromFloat(@ceil(out.x0) + 1)), @as(usize, @intFromFloat(m.cell_h)) + 1), sel[0], sel[1], sel[2], 3));
}

test "selection draws on a plain row" {
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    const m = p.metrics();
    const t = try vt.Terminal.init(std.testing.allocator, .{ .cols = 20, .rows = 3 });
    defer t.deinit();
    t.write("\x1b[?25lhello world");
    t.selectionPress(2, 0, 1);
    t.selectionDrag(4, 0);
    t.selectionRelease();
    const cv = try Canvas.init(@intFromFloat(m.cell_w * 20), @intFromFloat(m.cell_h * 3));
    defer cv.deinit();
    p.drawRows(t, cv.ctx, 0, 2);
    const sel = [3]u8{ 56, 84, 140 }; // selection_bg as pixels
    for ([_]usize{ 2, 3, 4 }) |col| try std.testing.expect(near(cv.px(cellBox(m, col, 0)[0] + 1, 1), sel[0], sel[1], sel[2], 3));
    for ([_]usize{ 1, 5 }) |col| try std.testing.expect(!near(cv.px(cellBox(m, col, 0)[0] + 1, 1), sel[0], sel[1], sel[2], 3));
}

test "cursor on a selected inverse cell stays legible" {
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    const t = try vt.Terminal.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer t.deinit();
    t.write("\x1b[7mH\x1b[0m\x1b[1D");
    t.selectionPress(0, 0, 1);
    t.selectionDrag(0, 0);
    t.selectionRelease();
    const m = p.metrics();
    const cv = try Canvas.init(@intFromFloat(m.cell_w * 10), @intFromFloat(m.cell_h * 2));
    defer cv.deinit();
    p.drawRows(t, cv.ctx, 0, 1);
    const b = cellBox(m, 0, 0);
    var lo: u8 = 255;
    var hi: u8 = 0;
    for (b[1]..b[3]) |y| for (b[0]..b[2]) |x| {
        const v = cv.px(x, y)[0];
        lo = @min(lo, v);
        hi = @max(hi, v);
    };
    try std.testing.expect(hi - lo > 100);
}

// ---- benchmark (HARF_BENCH=1) ----

fn benchNowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const bench_frames = 300;
const bench_warmup = 10;

/// Mean microseconds of `body` over `bench_frames` runs after `bench_warmup` untimed ones.
fn benchMean(ctx: anytype, comptime body: fn (@TypeOf(ctx)) void) f64 {
    for (0..bench_warmup) |_| body(ctx);
    const t0 = benchNowNs();
    for (0..bench_frames) |_| body(ctx);
    return @as(f64, @floatFromInt(benchNowNs() - t0)) / 1000.0 / bench_frames;
}

const BenchCtx = struct {
    p: *Painter,
    t: *vt.Terminal,
    cv: Canvas,
    first: u16 = 0,
    last: u16 = 23,
    clear_cache: bool = false,
};

fn benchBody(b: *BenchCtx) void {
    if (b.clear_cache) b.p.clearRows();
    b.p.drawRows(b.t, b.cv.ctx, b.first, b.last);
}

fn benchScreen(comptime colored: bool, comptime arabic: bool) !struct { t: *vt.Terminal } {
    const t = try vt.Terminal.init(std.testing.allocator, .{ .cols = 80, .rows = 24 });
    errdefer t.deinit();
    t.write("\x1b[?25l");
    var buf: [256]u8 = undefined;
    for (0..24) |i| {
        const color = if (colored) std.fmt.bufPrint(buf[200..], "\x1b[3{d};4{d}m", .{ i % 7 + 1, (i + 3) % 7 + 1 }) catch unreachable else "";
        const line = if (arabic)
            std.fmt.bufPrint(&buf, "{s}\u{628}\u{64A}\u{62A}\u{64A} \u{645}\u{631}\u{62D}\u{628}\u{627} \u{627}\u{644}\u{633}\u{644}\u{627}\u{645} \u{639}\u{644}\u{64A}\u{643}\u{645} \u{648}\u{631}\u{62D}\u{645}\u{629} \u{627}\u{644}\u{644}\u{647} {d} \u{628}\u{64A}\u{62A}\u{64A} \u{645}\u{631}\u{62D}\u{628}\u{627}\x1b[0m", .{ color, i }) catch unreachable
        else blk: {
            // 80 inked cells per row (1920 glyphs per screen), letters of both cases, no blanks.
            var n = (std.fmt.bufPrint(&buf, "{s}", .{color}) catch unreachable).len;
            for (0..80) |col| {
                const k = (i * 7 + col * 3) % 52;
                buf[n] = if (k < 26) 'a' + @as(u8, @intCast(k)) else 'A' + @as(u8, @intCast(k - 26));
                n += 1;
            }
            const reset = "\x1b[0m";
            @memcpy(buf[n..][0..reset.len], reset);
            break :blk buf[0 .. n + reset.len];
        };
        t.write(line);
        t.write("\r\n");
    }
    return .{ .t = t };
}

test "bench: painter-only frame costs (HARF_BENCH=1)" {
    if (std.c.getenv("HARF_BENCH") == null) return error.SkipZigTest;
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    const m = p.metrics();
    const cv = try Canvas.init(@intFromFloat(m.cell_w * 80), @intFromFloat(m.cell_h * 24));
    defer cv.deinit();

    const plain = try benchScreen(false, false);
    defer plain.t.deinit();
    var ctx: BenchCtx = .{ .p = p, .t = plain.t, .cv = cv };
    std.debug.print("\nBENCH plain 80x24 full frame:        {d:>8.1} us\n", .{benchMean(&ctx, benchBody)});
    ctx.first = 5;
    ctx.last = 5;
    std.debug.print("BENCH plain one row (row 5):         {d:>8.1} us\n", .{benchMean(&ctx, benchBody)});

    const colored = try benchScreen(true, false);
    defer colored.t.deinit();
    ctx = .{ .p = p, .t = colored.t, .cv = cv };
    std.debug.print("BENCH colored plain full frame:      {d:>8.1} us\n", .{benchMean(&ctx, benchBody)});

    const arabic = try benchScreen(false, true);
    defer arabic.t.deinit();
    ctx = .{ .p = p, .t = arabic.t, .cv = cv };
    std.debug.print("BENCH arabic cached full frame:      {d:>8.1} us\n", .{benchMean(&ctx, benchBody)});
    ctx.clear_cache = true;
    std.debug.print("BENCH arabic cold full frame:        {d:>8.1} us\n", .{benchMean(&ctx, benchBody)});
}

// ---- R2: hit-testing on lam-alef, tashkeel and blank cells ----

/// Presses at the pixel center of logical column `from`'s span and drags to the center of `to`'s, through
/// `cellAt` (what a real click does), and returns the copied text.
fn dragCopy(p: *Painter, t: *vt.Terminal, row: u16, from: u16, to: u16) ![]u8 {
    const m = p.metrics();
    const rl = (try testLayout(p, t, row)).?;
    const a = rl.span(from, m.cell_w);
    const b = rl.span(to, m.cell_w);
    const y = m.cell_h * (@as(f64, @floatFromInt(row)) + 0.5);
    const ca = p.cellAt(t, (a.x0 + a.x1) / 2, y);
    const cb = p.cellAt(t, (b.x0 + b.x1) / 2, y);
    t.selectionPress(ca.col, ca.row, 1);
    t.selectionDrag(cb.col, cb.row);
    t.selectionRelease();
    return t.selectionText(std.testing.allocator);
}

test "hit test: each cell of lam-alef is its own target" {
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    const m = p.metrics();
    const t = try vt.Terminal.init(std.testing.allocator, .{ .cols = 20, .rows = 2 });
    defer t.deinit();
    t.write("\u{644}\u{627} \u{644}\u{627}"); // lam-alef, a blank, lam-alef: four letter cells and a space
    const rl = (try testLayout(p, t, 0)).?;
    const y = m.cell_h * 0.5;
    for (0..5) |col| {
        const sp = rl.span(@intCast(col), m.cell_w);
        try std.testing.expect(sp.x1 > sp.x0);
        const hit = p.cellAt(t, (sp.x0 + sp.x1) / 2, y);
        try std.testing.expectEqual(@as(u16, @intCast(col)), hit.col);
    }
    // a press-drag from the second cell of the first lam-alef to the blank after it copies that letter (the
    // blank is trimmed); a drag that stays in one cell selects nothing, so the neighbor is the other end
    const one = try dragCopy(p, t, 0, 1, 2);
    defer std.testing.allocator.free(one);
    try std.testing.expectEqualStrings("\u{627}", one);
    // and over both cells copies the ligature's two letters in logical order
    const both = try dragCopy(p, t, 0, 0, 1);
    defer std.testing.allocator.free(both);
    try std.testing.expectEqualStrings("\u{644}\u{627}", both);
}

test "hit test: a tashkeel base letter is its own target and copies with its marks" {
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    const m = p.metrics();
    const t = try vt.Terminal.init(std.testing.allocator, .{ .cols = 20, .rows = 2 });
    defer t.deinit();
    t.write("\u{645}\u{64F}\u{62D}\u{64E}\u{645}\u{64E}\u{651}\u{62F}"); // four cells: meem+damma, hah+fatha, meem+fatha+shadda, dal
    const rl = (try testLayout(p, t, 0)).?;
    try std.testing.expectEqual(@as(u16, 4), rl.n_cells);
    const y = m.cell_h * 0.5;
    for (0..4) |col| {
        const sp = rl.span(@intCast(col), m.cell_w);
        try std.testing.expectEqual(@as(u16, @intCast(col)), p.cellAt(t, (sp.x0 + sp.x1) / 2, y).col);
    }
    const third = try dragCopy(p, t, 0, 2, 3);
    defer std.testing.allocator.free(third);
    try std.testing.expectEqualStrings("\u{645}\u{64E}\u{651}\u{62F}", third); // the third base with both marks, then the dal
    const all = try dragCopy(p, t, 0, 0, 3);
    defer std.testing.allocator.free(all);
    try std.testing.expectEqualStrings("\u{645}\u{64F}\u{62D}\u{64E}\u{645}\u{64E}\u{651}\u{62F}", all);
}

test "hit test: blank cells after the text are plain columns" {
    const p = try Painter.init(std.testing.allocator, test_px);
    defer p.deinit();
    const m = p.metrics();
    const t = try vt.Terminal.init(std.testing.allocator, .{ .cols = 20, .rows = 2 });
    defer t.deinit();
    t.write("\u{644}\u{627} \u{645}\u{64E}\u{631}");
    const rl = (try testLayout(p, t, 0)).?;
    const n: usize = rl.n_cells;
    for ([_]usize{ n, n + 1, n + 5, 19 }) |col| {
        const x = (@as(f64, @floatFromInt(col)) + 0.5) * m.cell_w;
        try std.testing.expectEqual(@as(u16, @intCast(col)), p.cellAt(t, x, m.cell_h * 0.5).col);
    }
}
