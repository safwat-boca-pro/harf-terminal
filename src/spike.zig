//! Phase 1 spike context: fonts + layout + CPU drawing into a CGContext.
//! Temporary scaffolding for the cell-model work; the production per-row pipeline (grid in,
//! draw damaged rows out) replaces this in Phase 4. The renderer is CPU-drawn (owner decision
//! 2026-11-13, brief section 2): no atlas, no GPU.
const std = @import("std");
const ct = @import("shape/ct.zig");
const layout = @import("shape/layout.zig");

pub const Metrics = extern struct {
    cell_w: f32,
    cell_h: f32,
    /// Baseline offset from the top of a cell row, px.
    ascent: f32,
    arabic_ascent: f32,
    arabic_descent: f32,
    arabic_leading: f32,
};

pub const RowRequest = extern struct {
    utf8: [*]const u8,
    len: usize,
    /// Arabic font: a family name, or "system" for the system UI font's Arabic face.
    font_spec: [*:0]const u8,
    size_px: f32,
    /// layout.Model: 0 = A, 1 = B, 2 = C, 3 = D (C fitted).
    model: u32,
    base_dir: u32,
    origin_x: f32,
    /// Baseline y in the context's coordinates. The context must be y-down (flipped).
    baseline_y: f32,
    color: [4]f32,
};

fn makeFont(spec: []const u8, size: f64) ?*ct.CTFont {
    if (std.mem.eql(u8, spec, "system")) {
        const sys = ct.CTFontCreateUIFontForLanguage(ct.ui_font_system, size, null) orelse return null;
        defer ct.CFRelease(sys);
        // The Arabic face is reached through the system font's cascade (SF Arabic), not by name.
        const probe = ct.cfString("\u{0628}") orelse return null;
        defer ct.CFRelease(probe);
        return ct.CTFontCreateForString(sys, probe, .{ .location = 0, .length = 1 });
    }
    const name = ct.cfString(spec) orelse return null;
    defer ct.CFRelease(name);
    return ct.CTFontCreateWithName(name, size, null);
}

fn cellWidth(f: *const ct.CTFont) f32 {
    const ch = [_]ct.UniChar{'M'};
    var g = [_]ct.CGGlyph{0};
    _ = ct.CTFontGetGlyphsForCharacters(f, &ch, &g, 1);
    return @floatCast(@round(ct.CTFontGetAdvancesForGlyphs(f, ct.orientation_horizontal, &g, null, 1)));
}

pub const Spike = struct {
    alloc: std.mem.Allocator,
    layouter: layout.Layouter,
    placed: std.ArrayList(layout.Placed) = .empty,

    pub fn create(alloc: std.mem.Allocator) !*Spike {
        const self = try alloc.create(Spike);
        self.* = .{ .alloc = alloc, .layouter = layout.Layouter.init(alloc) };
        return self;
    }

    pub fn destroy(self: *Spike) void {
        self.placed.deinit(self.alloc);
        self.layouter.deinit();
        self.alloc.destroy(self);
    }

    pub fn metrics(self: *Spike, spec: []const u8, size_px: f32) Metrics {
        _ = self;
        const primary = makeFont("Menlo", size_px) orelse return std.mem.zeroes(Metrics);
        defer ct.CFRelease(primary);
        const arabic = makeFont(spec, size_px) orelse return std.mem.zeroes(Metrics);
        defer ct.CFRelease(arabic);
        const asc = @ceil(ct.CTFontGetAscent(primary));
        const desc = @ceil(ct.CTFontGetDescent(primary));
        const lead = @ceil(ct.CTFontGetLeading(primary));
        return .{
            .cell_w = cellWidth(primary),
            .cell_h = @floatCast(asc + desc + lead),
            .ascent = @floatCast(asc),
            .arabic_ascent = @floatCast(ct.CTFontGetAscent(arabic)),
            .arabic_descent = @floatCast(ct.CTFontGetDescent(arabic)),
            .arabic_leading = @floatCast(ct.CTFontGetLeading(arabic)),
        };
    }

    /// Cluster extents of the last `drawRow` (model D only), x relative to the row origin.
    pub fn extents(self: *const Spike) []const layout.Extent {
        return self.layouter.extents.items;
    }

    /// Lays out one row and draws it into `ctx` (y-down).
    pub fn drawRow(self: *Spike, ctx: *ct.CGContext, req: RowRequest, info: *layout.RowInfo) void {
        const size: f64 = req.size_px;
        const primary = makeFont("Menlo", size) orelse return;
        defer ct.CFRelease(primary);
        const arabic = makeFont(std.mem.span(req.font_spec), size) orelse return;
        defer ct.CFRelease(arabic);

        info.* = self.layouter.layoutRow(.{
            .text = req.utf8[0..req.len],
            .primary = primary,
            .arabic = arabic,
            .cell_w = cellWidth(primary),
            .model = @enumFromInt(req.model),
            .base = @enumFromInt(req.base_dir),
        }, &self.placed) catch return;

        ct.CGContextSetRGBFillColor(ctx, req.color[0], req.color[1], req.color[2], req.color[3]);
        const items = self.placed.items;
        var i: usize = 0;
        while (i < items.len) {
            // One draw call per run of glyphs sharing a font and horizontal scale. CoreText's
            // justification emits dozens of tiny kashida glyphs per word, so batching matters.
            const first = items[i];
            var j = i;
            while (j < items.len and items[j].font_id == first.font_id and items[j].sx == first.sx) j += 1;

            ct.CGContextSaveGState(ctx);
            ct.CGContextTranslateCTM(ctx, 0, req.baseline_y);
            ct.CGContextScaleCTM(ctx, first.sx, -1); // y-down context: flip glyphs upright
            const font = self.layouter.font(first.font_id);
            var k = i;
            while (k < j) {
                const end = @min(k + 64, j);
                var gids: [64]ct.CGGlyph = undefined;
                var pos: [64]ct.CGPoint = undefined;
                for (k..end, 0..) |idx, t| {
                    gids[t] = items[idx].gid;
                    pos[t] = .{ .x = (req.origin_x + items[idx].x) / first.sx, .y = 0 };
                }
                ct.CTFontDrawGlyphs(font, &gids, &pos, end - k, ctx);
                k = end;
            }
            ct.CGContextRestoreGState(ctx);
            i = j;
        }
    }
};
