//! Turns one grid row into shaped Arabic layout: cells to text, CoreText shaping through
//! `layout.Layouter` (model D, "C fit"), and a pixel box for every logical column that the
//! cursor uses. The grid stays logical; this only decides where things are drawn.
const std = @import("std");
const ct = @import("shape/ct.zig");
const layout = @import("shape/layout.zig");
const vt = @import("vt.zig");
const rowfacts = @import("rowfacts.zig");
const bidi = @import("bidi/bidi.zig");
const Allocator = std.mem.Allocator;

/// Pixel extent of one logical column, relative to the row start.
pub const Span = struct { x0: f32, x1: f32 };

/// One shaped row. `placed` is in draw order; `spans[col]` is where logical column `col` is drawn.
pub const RowLayout = struct {
    placed: []layout.Placed,
    spans: []Span,
    rtl_base: bool,
    n_cells: u16,

    /// The box of `col`. Columns at or past the text are plain cells.
    pub fn span(self: RowLayout, col: u16, cell_w: f32) Span {
        if (col < self.n_cells) return self.spans[col];
        const x0 = @as(f32, @floatFromInt(col)) * cell_w;
        return .{ .x0 = x0, .x1 = x0 + cell_w };
    }

    pub fn deinit(self: *RowLayout, gpa: Allocator) void {
        gpa.free(self.placed);
        gpa.free(self.spans);
    }
};

/// Appends the row as UTF-8 (a blank cell is a space, trailing blanks are trimmed) and returns the
/// number of cells, or null if the row cannot be mapped one cell per character: a wide cell, a
/// spacer, a cell whose later codepoints are not combining marks (a ZWJ emoji), or a cell that
/// starts with a mark. The layouter counts cells from characters, so those rows draw plain.
pub fn rowText(cells: []const vt.Cell, out: *std.ArrayList(u8), gpa: Allocator) Allocator.Error!?u16 {
    const start = out.items.len;
    var end = start;
    var n: u16 = 0;
    var n_end: u16 = 0;
    for (cells, 0..) |cell, i| {
        if (cell.wide != .narrow) return unmappable(out, start);
        if (cell.cps.len == 0) {
            try out.append(gpa, ' ');
        } else {
            if (i > 0 and layout.isMark(cell.cps[0])) return unmappable(out, start);
            for (cell.cps[1..]) |cp| if (!layout.isMark(cp)) return unmappable(out, start);
            for (cell.cps) |cp| {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &buf) catch return unmappable(out, start);
                try out.appendSlice(gpa, buf[0..len]);
            }
            end = out.items.len;
            n_end = n + 1;
        }
        n += 1;
    }
    out.shrinkRetainingCapacity(end);
    return n_end;
}

fn unmappable(out: *std.ArrayList(u8), start: usize) ?u16 {
    out.shrinkRetainingCapacity(start);
    return null;
}

pub const Shaper = struct {
    gpa: Allocator,
    layouter: layout.Layouter,
    primary: *const ct.CTFont,
    cell_w: f32,
    scratch: std.ArrayList(layout.Placed) = .empty,

    /// `primary` is also the Arabic font: CoreText's cascade picks the face (font policy, cell-model.md).
    pub fn init(gpa: Allocator, primary: *const ct.CTFont, cell_w: f32) Shaper {
        return .{ .gpa = gpa, .layouter = layout.Layouter.init(gpa), .primary = primary, .cell_w = cell_w };
    }

    pub fn deinit(self: *Shaper) void {
        self.layouter.deinit();
        self.scratch.deinit(self.gpa);
    }

    /// Shapes `text` (from `rowText`) as one row of `n_cells` cells. Null if the layout's cell count
    /// disagrees with `n_cells` (the caller draws the row plain). `error.LayoutHole` if a column got no box.
    pub fn shape(self: *Shaper, text: []const u8, n_cells: u16, rtl_base: bool) !?RowLayout {
        if (text.len == 0) {
            if (n_cells != 0) return null;
            return .{ .placed = try self.gpa.alloc(layout.Placed, 0), .spans = try self.gpa.alloc(Span, 0), .rtl_base = rtl_base, .n_cells = 0 };
        }
        const info = try self.layouter.layoutRow(.{
            .text = text,
            .primary = self.primary,
            .arabic = self.primary,
            .cell_w = self.cell_w,
            .model = .d,
            .base = if (rtl_base) .rtl else .ltr,
        }, &self.scratch);
        if (info.n_cells != n_cells) return null;
        const spans = try self.gpa.alloc(Span, n_cells);
        errdefer self.gpa.free(spans);
        @memset(spans, .{ .x0 = std.math.nan(f32), .x1 = std.math.nan(f32) });
        for (self.layouter.extents.items) |e| {
            if (e.lcol >= n_cells) return error.LayoutHole;
            spans[e.lcol] = .{ .x0 = e.x0, .x1 = e.x1 };
        }
        for (spans) |sp| if (std.math.isNan(sp.x0)) return error.LayoutHole;
        return .{ .placed = try self.gpa.dupe(layout.Placed, self.scratch.items), .spans = spans, .rtl_base = rtl_base, .n_cells = n_cells };
    }
};

// ---- tests (need Menlo, shipped with macOS) ----

const test_cell_w: f32 = 10;

fn testFont() *const ct.CTFont {
    const s = ct.cfString("Menlo").?;
    defer ct.CFRelease(s);
    return ct.CTFontCreateWithName(s, 16, null).?;
}

/// A row built from a string: one cell per base character, marks stay in their base's cell.
const TestRow = struct {
    cps: [256]u21 = undefined,
    cells: [64]vt.Cell = undefined,
    n: usize = 0,

    fn init(self: *TestRow, str: []const u8) !void {
        var ncp: usize = 0;
        var it = (try std.unicode.Utf8View.init(str)).iterator();
        var starts: [64]usize = undefined;
        while (it.nextCodepoint()) |cp| : (ncp += 1) {
            self.cps[ncp] = cp;
            if (self.n == 0 or !layout.isMark(cp)) {
                starts[self.n] = ncp;
                self.n += 1;
            }
        }
        for (0..self.n) |i| {
            const end = if (i + 1 < self.n) starts[i + 1] else ncp;
            self.cells[i] = .{ .cps = self.cps[starts[i]..end], .wide = .narrow };
        }
    }
};

const Shaped = struct { rl: RowLayout, n: u16, text: []u8 };

fn shapeStr(str: []const u8, rtl: bool) !Shaped {
    var row: TestRow = .{};
    try row.init(str);
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(std.testing.allocator);
    const n = (try rowText(row.cells[0..row.n], &text, std.testing.allocator)).?;
    const font = testFont();
    defer ct.CFRelease(font);
    var sh = Shaper.init(std.testing.allocator, font, test_cell_w);
    defer sh.deinit();
    const rl = (try sh.shape(text.items, n, rtl)).?;
    return .{ .rl = rl, .n = n, .text = try text.toOwnedSlice(std.testing.allocator) };
}

fn freeShaped(s: *Shaped) void {
    s.rl.deinit(std.testing.allocator);
    std.testing.allocator.free(s.text);
}

test "unmappable cells fall back" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    const alloc = std.testing.allocator;
    const wide_cps = [_]u21{0x4E2D};
    const zwj_cps = [_]u21{ 0x1F468, 0x200D, 0x1F469 };
    const a = [_]u21{'a'};
    const lead_mark = [_]u21{0x64E};
    try std.testing.expect((try rowText(&.{.{ .cps = &wide_cps, .wide = .wide }}, &text, alloc)) == null);
    try std.testing.expect((try rowText(&.{ .{ .cps = &a, .wide = .narrow }, .{ .cps = &.{}, .wide = .spacer_tail } }, &text, alloc)) == null);
    try std.testing.expect((try rowText(&.{.{ .cps = &.{}, .wide = .spacer_head }}, &text, alloc)) == null);
    try std.testing.expect((try rowText(&.{.{ .cps = &zwj_cps, .wide = .narrow }}, &text, alloc)) == null);
    try std.testing.expect((try rowText(&.{ .{ .cps = &a, .wide = .narrow }, .{ .cps = &lead_mark, .wide = .narrow } }, &text, alloc)) == null);
    // base plus two marks is one cell; blanks become spaces; trailing blanks are trimmed
    const meem = [_]u21{ 0x645, 0x64E, 0x651 };
    text.clearRetainingCapacity();
    const blank: vt.Cell = .{ .cps = &.{}, .wide = .narrow };
    const n = try rowText(&.{ .{ .cps = &meem, .wide = .narrow }, blank, .{ .cps = &a, .wide = .narrow }, blank, blank }, &text, alloc);
    try std.testing.expectEqual(@as(?u16, 3), n);
    try std.testing.expectEqualStrings("\u{645}\u{64E}\u{651} a", text.items);
}

test "every column has a box" {
    var s = try shapeStr("مُحَمَّد لا إله إلا الله", false);
    defer freeShaped(&s);
    const limit = @as(f32, @floatFromInt(s.n)) * test_cell_w + 0.5;
    var order: [64]u16 = undefined;
    for (0..s.n) |i| {
        order[i] = @intCast(i);
        const b = s.rl.span(@intCast(i), test_cell_w);
        try std.testing.expect(std.math.isFinite(b.x0) and std.math.isFinite(b.x1));
        try std.testing.expect(b.x1 > b.x0 and b.x0 >= 0 and b.x1 <= limit);
    }
    const Ctx = struct {
        rl: *const RowLayout,
        fn less(c: @This(), a: u16, b: u16) bool {
            return c.rl.span(a, test_cell_w).x0 < c.rl.span(b, test_cell_w).x0;
        }
    };
    std.mem.sort(u16, order[0..s.n], Ctx{ .rl = &s.rl }, Ctx.less);
    for (1..s.n) |i| {
        const prev = s.rl.span(order[i - 1], test_cell_w);
        const cur = s.rl.span(order[i], test_cell_w);
        try std.testing.expect(cur.x0 >= prev.x1 - 0.5);
    }
    // past the text: the plain cell box
    const past = s.rl.span(s.n + 3, test_cell_w);
    try std.testing.expectEqual(@as(f32, @floatFromInt(s.n + 3)) * test_cell_w, past.x0);
    try std.testing.expectEqual(past.x0 + test_cell_w, past.x1);
}

test "plain LTR text keeps cell boxes" {
    var s = try shapeStr("ls ملف.txt", false);
    defer freeShaped(&s);
    for (0..3) |col| {
        const b = s.rl.span(@intCast(col), test_cell_w);
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(col)) * test_cell_w, b.x0, 0.01);
        try std.testing.expectApproxEqAbs(b.x0 + test_cell_w, b.x1, 0.01);
    }
}

test "rtl row order" {
    inline for (.{ true, false }) |rtl| {
        var s = try shapeStr("مرحبا", rtl);
        defer freeShaped(&s);
        try std.testing.expect(s.rl.span(0, test_cell_w).x0 > s.rl.span(4, test_cell_w).x0); // first letter rightmost
    }
}

test "shape guard" {
    var row: TestRow = .{};
    try row.init("abc");
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    const n = (try rowText(row.cells[0..row.n], &text, std.testing.allocator)).?;
    const font = testFont();
    defer ct.CFRelease(font);
    var sh = Shaper.init(std.testing.allocator, font, test_cell_w);
    defer sh.deinit();
    try std.testing.expect((try sh.shape(text.items, n + 1, false)) == null);
}

test "empty and blank rows" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    const blank: vt.Cell = .{ .cps = &.{}, .wide = .narrow };
    try std.testing.expectEqual(@as(?u16, 0), try rowText(&.{ blank, blank, blank }, &text, std.testing.allocator));
    try std.testing.expectEqual(@as(usize, 0), text.items.len);
    const font = testFont();
    defer ct.CFRelease(font);
    var sh = Shaper.init(std.testing.allocator, font, test_cell_w);
    defer sh.deinit();
    var rl = (try sh.shape("", 0, false)).?;
    defer rl.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 0), rl.n_cells);
    try std.testing.expectEqual(@as(f32, 20), rl.span(2, test_cell_w).x0);
}

test "visual order agrees with UAX #9" {
    const samples = [_][]const u8{
        "مرحبا world 123",
        "السلام عليكم ورحمة الله",
        "مُحَمَّد",
        "لا إله إلا الله",
        "ls ملف.txt",
        "\"النتيجة: ١٢٣ (ناجح)\"",
        "echo \"اختبار\" | wc -c",
        "│ مرحبا    │",
    };
    const alloc = std.testing.allocator;
    for (samples) |str| {
        var row: TestRow = .{};
        try row.init(str);
        var ncp: usize = 0;
        for (row.cells[0..row.n]) |c| ncp += c.cps.len;
        const facts = rowfacts.analyze(row.cps[0..ncp], .auto);
        var s = try shapeStr(str, facts.rtl_base);
        defer freeShaped(&s);

        var levels: [256]u8 = undefined;
        _ = try bidi.resolve(alloc, row.cps[0..ncp], if (facts.rtl_base) .rtl else .ltr, levels[0..ncp]);
        var cell_levels: [64]u8 = undefined;
        var off: usize = 0;
        for (row.cells[0..row.n], 0..) |c, i| {
            cell_levels[i] = levels[off];
            off += c.cps.len;
        }
        var want: [64]usize = undefined;
        bidi.reorder(cell_levels[0..row.n], want[0..row.n]);

        var got: [64]u16 = undefined;
        for (0..row.n) |i| got[i] = @intCast(i);
        const Ctx = struct {
            rl: *const RowLayout,
            fn less(c: @This(), a: u16, b: u16) bool {
                return c.rl.span(a, test_cell_w).x0 < c.rl.span(b, test_cell_w).x0;
            }
        };
        std.mem.sort(u16, got[0..row.n], Ctx{ .rl = &s.rl }, Ctx.less);
        for (0..row.n) |i| {
            if (want[i] != got[i]) {
                std.debug.print("order differs for '{s}' (rtl base {}) at {d}\n want {any}\n  got {any}\n", .{ str, facts.rtl_base, i, want[0..row.n], got[0..row.n] });
                return error.OrderDiffers;
            }
        }
    }
}
