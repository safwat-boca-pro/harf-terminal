//! Draws a terminal's visible grid with CoreText: one cell at a time at `col * cell_w`, so the grid
//! never drifts. No bidi and no joining here (Phase 4): an Arabic letter is drawn as its own cell.
const std = @import("std");
const ct = @import("shape/ct.zig");
const vt = @import("vt.zig");

pub const Metrics = struct { cell_w: f32, cell_h: f32, ascent: f32 };

pub const Glyph = struct { font: *const ct.CTFont, gid: u16 };

/// Phase 3 theme (slice 3 replaces it with the terminal's own colors).
const bg = [3]f64{ 0.06, 0.06, 0.07 };
const fg = [3]f64{ 0.92, 0.92, 0.92 };

/// The glyph cache stops growing here; lookups past it still work, just uncached.
const max_cached: usize = 4096;
const max_fallback_fonts: usize = 64;

pub const Painter = struct {
    gpa: std.mem.Allocator,
    primary: *ct.CTFont,
    size_px: f32,
    metrics_: Metrics,
    /// Fonts CoreText picked for characters Menlo lacks (deduplicated, retained).
    fallbacks: std.ArrayList(*ct.CTFont) = .empty,
    cache: std.AutoHashMapUnmanaged(u21, ?Glyph) = .empty,

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
        self.* = .{
            .gpa = gpa,
            .primary = font,
            .size_px = size_px,
            .metrics_ = .{
                .cell_w = @floatCast(@round(ct.CTFontGetAdvancesForGlyphs(font, ct.orientation_horizontal, &g, null, 1))),
                .cell_h = @floatCast(asc + desc + lead),
                .ascent = @floatCast(asc),
            },
        };
        return self;
    }

    pub fn deinit(self: *Painter) void {
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
        if (self.cache.get(cp)) |hit| return hit;
        const found = self.resolve(cp);
        if (self.cache.count() < max_cached) self.cache.put(self.gpa, cp, found) catch {};
        return found;
    }

    fn resolve(self: *Painter, cp: u21) ?Glyph {
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
        if (ct.CTFontGetGlyphsForCharacters(self.primary, &units, &gids, @intCast(n)) and gids[0] != 0) {
            return .{ .font = self.primary, .gid = gids[0] };
        }
        var utf8: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &utf8) catch return null;
        const str = ct.cfString(utf8[0..len]) orelse return null;
        defer ct.CFRelease(str);
        const fb = ct.CTFontCreateForString(self.primary, str, .{ .location = 0, .length = @intCast(n) }) orelse return null;
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

    fn drawCell(self: *Painter, ctx: *ct.CGContext, cps: []const u21, x: f64, baseline: f64, color: [3]f64) void {
        ct.CGContextSetRGBFillColor(ctx, color[0], color[1], color[2], 1);
        for (cps) |cp| {
            if (cp == ' ') continue;
            const g = self.lookup(cp) orelse continue;
            ct.CGContextSaveGState(ctx);
            ct.CGContextTranslateCTM(ctx, 0, baseline);
            ct.CGContextScaleCTM(ctx, 1, -1); // the context is y-down: flip glyphs upright
            const gid = [1]ct.CGGlyph{g.gid};
            const pos = [1]ct.CGPoint{.{ .x = x, .y = 0 }};
            ct.CTFontDrawGlyphs(g.font, &gid, &pos, 1, ctx);
            ct.CGContextRestoreGState(ctx);
        }
    }

    /// Draws rows `first_row` to `last_row` (inclusive; clamped to the grid) and the cursor into a
    /// y-down context in device pixels whose origin is the grid's top-left. The caller holds the
    /// session lock. Refreshes the render state once.
    pub fn drawRows(self: *Painter, term: *vt.Terminal, ctx: *ct.CGContext, first_row: u16, last_row: u16) void {
        const size = term.size();
        if (size.rows == 0 or first_row >= size.rows or !term.update()) return;
        const last = @min(last_row, size.rows - 1);
        const m = self.metrics_;
        const cw: f64 = m.cell_w;
        const ch: f64 = m.cell_h;
        const grid_w = cw * @as(f64, @floatFromInt(size.cols));
        ct.CGContextSaveGState(ctx);
        defer ct.CGContextRestoreGState(ctx);
        // Wide fallback glyphs must not spill past the grid.
        ct.CGContextClipToRect(ctx, .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = grid_w, .height = ch * @as(f64, @floatFromInt(size.rows)) } });
        var buf: [16]u21 = undefined;
        var row: u16 = first_row;
        while (row <= last) : (row += 1) {
            const top = ch * @as(f64, @floatFromInt(row));
            fill(ctx, 0, top, grid_w, ch, bg);
            if (!term.selectRow(row)) continue;
            var col: u16 = 0;
            while (col < size.cols) : (col += 1) {
                const cell = term.cellInRow(col, &buf);
                if (cell.wide == .spacer_tail or cell.wide == .spacer_head or cell.cps.len == 0) continue;
                self.drawCell(ctx, cell.cps, cw * @as(f64, @floatFromInt(col)), top + m.ascent, fg);
            }
        }
        const cur = term.cursor() orelse return;
        if (!cur.visible or cur.row < first_row or cur.row > last or cur.col >= size.cols) return;
        const x = cw * @as(f64, @floatFromInt(cur.col));
        const top = ch * @as(f64, @floatFromInt(cur.row));
        fill(ctx, x, top, cw, ch, fg);
        if (term.selectRow(cur.row)) {
            const cell = term.cellInRow(cur.col, &buf);
            self.drawCell(ctx, cell.cps, x, top + m.ascent, bg); // the glyph under the block, inverted
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
