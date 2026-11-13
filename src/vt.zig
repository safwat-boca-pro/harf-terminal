//! Thin Zig wrapper over libghostty-vt's C API (parser, screen, scrollback, cells).
//! The grid is in logical order: one cell per character, combining marks inside their base cell.
//! Not thread-safe; callers serialize access (see term.zig).
const std = @import("std");
pub const c = @import("ghostty_c");

/// Events the terminal raises while parsing. They run inside `Terminal.write` on the caller's
/// thread and must not call `write` on the same terminal.
pub const Callbacks = struct {
    ctx: ?*anyopaque = null,
    /// Bytes the terminal wants sent to the child (answers to queries such as cursor position).
    write_pty: ?*const fn (ctx: ?*anyopaque, data: []const u8) void = null,
    bell: ?*const fn (ctx: ?*anyopaque) void = null,
    /// The new title is already readable with `Terminal.title`.
    title_changed: ?*const fn (ctx: ?*anyopaque) void = null,
};

pub const Options = struct {
    cols: u16 = 80,
    rows: u16 = 24,
    /// libghostty keeps history in whole pages, so this is a limit to within about 400 KB.
    scrollback_bytes: usize = 1 << 20,
    callbacks: Callbacks = .{},
};

pub const Error = error{ OutOfMemory, Ghostty };

pub const Wide = enum { narrow, wide, spacer_tail, spacer_head };

/// One grid cell: its codepoints (base plus combining marks) and its width role.
pub const Cell = struct { cps: []const u21, wide: Wide };

fn check(r: c.GhosttyResult) Error!void {
    if (r == c.GHOSTTY_SUCCESS) return;
    if (r == c.GHOSTTY_OUT_OF_MEMORY) return error.OutOfMemory;
    return error.Ghostty;
}

fn writePtyTrampoline(_: c.GhosttyTerminal, ud: ?*anyopaque, data: [*c]const u8, len: usize) callconv(.c) void {
    const self: *Terminal = @ptrCast(@alignCast(ud.?));
    if (self.callbacks.write_pty) |f| f(self.callbacks.ctx, data[0..len]);
}

fn bellTrampoline(_: c.GhosttyTerminal, ud: ?*anyopaque) callconv(.c) void {
    const self: *Terminal = @ptrCast(@alignCast(ud.?));
    if (self.callbacks.bell) |f| f(self.callbacks.ctx);
}

fn titleTrampoline(_: c.GhosttyTerminal, ud: ?*anyopaque) callconv(.c) void {
    const self: *Terminal = @ptrCast(@alignCast(ud.?));
    if (self.callbacks.title_changed) |f| f(self.callbacks.ctx);
}

pub const Terminal = struct {
    gpa: std.mem.Allocator,
    callbacks: Callbacks,
    handle: c.GhosttyTerminal,
    render_state: c.GhosttyRenderState,
    row_iter: c.GhosttyRenderStateRowIterator,
    row_cells: c.GhosttyRenderStateRowCells,

    pub fn init(gpa: std.mem.Allocator, opts: Options) Error!*Terminal {
        const self = try gpa.create(Terminal);
        errdefer gpa.destroy(self);
        self.gpa = gpa;
        self.callbacks = opts.callbacks;
        try check(c.ghostty_terminal_new(null, &self.handle, opts.cols, opts.rows));
        errdefer c.ghostty_terminal_free(self.handle);
        // Callback options take the function pointer (or the userdata pointer) itself as the value.
        try check(c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_USERDATA, @as(?*const anyopaque, self)));
        try check(c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_WRITE_PTY, @as(?*const anyopaque, @ptrCast(&writePtyTrampoline))));
        try check(c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_BELL, @as(?*const anyopaque, @ptrCast(&bellTrampoline))));
        try check(c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, @as(?*const anyopaque, @ptrCast(&titleTrampoline))));
        var scrollback = opts.scrollback_bytes;
        try check(c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &scrollback));
        // Kitty graphics are compiled in but not wanted in v1: a zero limit stores no images.
        var image_limit: u64 = 0;
        try check(c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &image_limit));
        try check(c.ghostty_render_state_new(null, &self.render_state));
        errdefer c.ghostty_render_state_free(self.render_state);
        try check(c.ghostty_render_state_row_iterator_new(null, &self.row_iter));
        errdefer c.ghostty_render_state_row_iterator_free(self.row_iter);
        try check(c.ghostty_render_state_row_cells_new(null, &self.row_cells));
        return self;
    }

    pub fn deinit(self: *Terminal) void {
        c.ghostty_render_state_row_cells_free(self.row_cells);
        c.ghostty_render_state_row_iterator_free(self.row_iter);
        c.ghostty_render_state_free(self.render_state);
        c.ghostty_terminal_free(self.handle);
        self.gpa.destroy(self);
    }

    /// Feeds bytes from the child (escape sequences and text) to the parser.
    pub fn write(self: *Terminal, bytes: []const u8) void {
        c.ghostty_terminal_vt_write(self.handle, bytes.ptr, bytes.len);
    }

    /// Points `row_cells` at the cells of visible row `row`. False if the row does not exist.
    fn selectRow(self: *Terminal, row: u16) bool {
        if (c.ghostty_render_state_update(self.render_state, self.handle) != c.GHOSTTY_SUCCESS) return false;
        if (c.ghostty_render_state_get(self.render_state, c.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, @ptrCast(&self.row_iter)) != c.GHOSTTY_SUCCESS) return false;
        var i: u32 = 0;
        while (i <= row) : (i += 1) {
            if (!c.ghostty_render_state_row_iterator_next(self.row_iter)) return false;
        }
        return c.ghostty_render_state_row_get(self.row_iter, c.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, @ptrCast(&self.row_cells)) == c.GHOSTTY_SUCCESS;
    }

    /// Number of history rows above the visible screen.
    pub fn scrollbackRows(self: *Terminal) usize {
        var rows: usize = 0;
        _ = c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &rows);
        return rows;
    }

    pub fn size(self: *Terminal) struct { cols: u16, rows: u16 } {
        var cols: u16 = 0;
        var rows: u16 = 0;
        _ = c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_COLS, &cols);
        _ = c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_ROWS, &rows);
        return .{ .cols = cols, .rows = rows };
    }

    /// Changes the grid size (the library reflows). The pixel size of a cell is informational
    /// (size reports sent to the child); pass 0 if unknown.
    pub fn resize(self: *Terminal, cols: u16, rows: u16, cell_w_px: u32, cell_h_px: u32) void {
        _ = c.ghostty_terminal_resize(self.handle, cols, rows, cell_w_px, cell_h_px);
    }

    /// The window title set by the child (OSC 0 or 2); empty if none. Valid until the next `write`.
    pub fn title(self: *Terminal) []const u8 {
        var str: c.GhosttyString = undefined;
        if (c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_TITLE, &str) != c.GHOSTTY_SUCCESS) return "";
        return str.ptr[0..str.len];
    }

    /// Reads the cell `row_cells` currently points at; `buf` holds its codepoints (at most 16).
    fn readCell(self: *Terminal, buf: *[16]u21) Cell {
        var wide: c.GhosttyCellWide = c.GHOSTTY_CELL_WIDE_NARROW;
        var raw: c.GhosttyCell = undefined;
        if (c.ghostty_render_state_row_cells_get(self.row_cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw) == c.GHOSTTY_SUCCESS) {
            _ = c.ghostty_cell_get(raw, c.GHOSTTY_CELL_DATA_WIDE, &wide);
        }
        var cps: [16]u32 = undefined;
        var gb = c.GhosttyCodepointBuffer{ .ptr = &cps, .cap = cps.len, .len = 0 };
        var n: usize = 0;
        if (c.ghostty_render_state_row_cells_get(self.row_cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &gb) == c.GHOSTTY_SUCCESS) {
            n = @min(gb.len, cps.len);
        }
        for (cps[0..n], 0..) |cp, i| buf[i] = @intCast(cp);
        return .{ .cps = buf[0..n], .wide = switch (wide) {
            c.GHOSTTY_CELL_WIDE_WIDE => .wide,
            c.GHOSTTY_CELL_WIDE_SPACER_TAIL => .spacer_tail,
            c.GHOSTTY_CELL_WIDE_SPACER_HEAD => .spacer_head,
            else => .narrow,
        } };
    }

    /// The cell at (`col`, `row`) of the visible screen; blank (no codepoints) if out of range.
    /// `buf` backs the returned codepoints.
    pub fn cell(self: *Terminal, col: u16, row: u16, buf: *[16]u21) Cell {
        const blank: Cell = .{ .cps = buf[0..0], .wide = .narrow };
        if (!self.selectRow(row)) return blank;
        if (c.ghostty_render_state_row_cells_select(self.row_cells, col) != c.GHOSTTY_SUCCESS) return blank;
        return self.readCell(buf);
    }

    /// UTF-8 text of visible row `row`: blank cells are spaces, the spacer after a wide cell is
    /// skipped, trailing blanks are trimmed. The result is a slice of `out`; text that does not fit is cut off.
    pub fn rowText(self: *Terminal, row: u16, out: []u8) []const u8 {
        if (!self.selectRow(row)) return out[0..0];
        var n: usize = 0;
        var end: usize = 0; // length after the last non-blank cell
        var cps: [16]u21 = undefined;
        while (c.ghostty_render_state_row_cells_next(self.row_cells)) {
            const cl = self.readCell(&cps);
            if (cl.wide == .spacer_tail or cl.wide == .spacer_head) continue;
            if (cl.cps.len == 0) {
                if (n < out.len) {
                    out[n] = ' ';
                    n += 1;
                }
                continue;
            }
            for (cl.cps) |cp| {
                const len = std.unicode.utf8CodepointSequenceLength(cp) catch continue;
                if (n + len > out.len) return out[0..end];
                _ = std.unicode.utf8Encode(cp, out[n..]) catch continue;
                n += len;
            }
            end = n;
        }
        return out[0..end];
    }
};

test "written text lands in row 0" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    t.write("hello");
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("hello", t.rowText(0, &buf));
    try std.testing.expectEqualStrings("", t.rowText(1, &buf));
}

fn expectCps(t: *Terminal, col: u16, row: u16, want: []const u21) !void {
    var buf: [16]u21 = undefined;
    try std.testing.expectEqualSlices(u21, want, t.cell(col, row, &buf).cps);
}

test "arabic: one cell per letter, logical order" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 40, .rows = 10 });
    defer t.deinit();
    t.write("مرحبا world");
    try expectCps(t, 0, 0, &.{0x645});
    try expectCps(t, 4, 0, &.{0x627});
    try expectCps(t, 5, 0, &.{0x20});
    try expectCps(t, 6, 0, &.{'w'});
}

test "tashkeel lives in its base cell" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 40, .rows = 10 });
    defer t.deinit();
    t.write("\u{645}\u{64F}\u{62D}\u{64E}\u{645}\u{64E}\u{651}\u{62F}");
    try expectCps(t, 0, 0, &.{ 0x645, 0x64F });
    try expectCps(t, 1, 0, &.{ 0x62D, 0x64E });
    try expectCps(t, 2, 0, &.{ 0x645, 0x64E, 0x651 });
    try expectCps(t, 3, 0, &.{0x62F});
    try expectCps(t, 4, 0, &.{}); // blank
}

test "lam-alef is two cells" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 40, .rows = 10 });
    defer t.deinit();
    t.write("\u{644}\u{627}");
    try expectCps(t, 0, 0, &.{0x644});
    try expectCps(t, 1, 0, &.{0x627});
}

test "zwnj joins the previous cell" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 40, .rows = 10 });
    defer t.deinit();
    t.write("\u{645}\u{6CC}\u{200C}\u{62E}\u{648}\u{627}\u{647}\u{645}");
    try expectCps(t, 1, 0, &.{ 0x6CC, 0x200C });
}

test "emoji is a wide cell plus a spacer" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 40, .rows = 10 });
    defer t.deinit();
    t.write("ok \u{1F600} ok");
    var buf: [16]u21 = undefined;
    try std.testing.expectEqual(Wide.wide, t.cell(3, 0, &buf).wide);
    try std.testing.expectEqualSlices(u21, &.{0x1F600}, t.cell(3, 0, &buf).cps);
    try std.testing.expectEqual(Wide.spacer_tail, t.cell(4, 0, &buf).wide);
}

test "rowText skips the spacer after a wide cell" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 40, .rows = 10 });
    defer t.deinit();
    t.write("ok \u{1F600} ok");
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("ok \u{1F600} ok", t.rowText(0, &buf));
}

test "utf-8 split across two writes equals one write" {
    const text = "مرحبا world";
    const a = try Terminal.init(std.testing.allocator, .{ .cols = 40, .rows = 10 });
    defer a.deinit();
    const b = try Terminal.init(std.testing.allocator, .{ .cols = 40, .rows = 10 });
    defer b.deinit();
    a.write(text);
    // byte 5 falls inside the third Arabic letter (two bytes each)
    b.write(text[0..5]);
    b.write(text[5..]);
    var ba: [128]u8 = undefined;
    var bb: [128]u8 = undefined;
    const ra = a.rowText(0, &ba);
    try std.testing.expect(ra.len > 0);
    try std.testing.expectEqualStrings(ra, b.rowText(0, &bb));
}

const Spy = struct {
    replies: [64]u8 = undefined,
    reply_len: usize = 0,
    bells: u32 = 0,
    titles: u32 = 0,

    fn from(ctx: ?*anyopaque) *Spy {
        return @ptrCast(@alignCast(ctx.?));
    }
    fn writePty(ctx: ?*anyopaque, data: []const u8) void {
        const self = from(ctx);
        @memcpy(self.replies[self.reply_len..][0..data.len], data);
        self.reply_len += data.len;
    }
    fn bell(ctx: ?*anyopaque) void {
        from(ctx).bells += 1;
    }
    fn titleChanged(ctx: ?*anyopaque) void {
        from(ctx).titles += 1;
    }
    fn callbacks(self: *Spy) Callbacks {
        return .{ .ctx = self, .write_pty = writePty, .bell = bell, .title_changed = titleChanged };
    }
    fn replyText(self: *const Spy) []const u8 {
        return self.replies[0..self.reply_len];
    }
};

test "bell callback fires" {
    var spy: Spy = .{};
    const t = try Terminal.init(std.testing.allocator, .{ .callbacks = spy.callbacks() });
    defer t.deinit();
    t.write("\x07");
    try std.testing.expectEqual(@as(u32, 1), spy.bells);
}

test "title change callback and getter" {
    var spy: Spy = .{};
    const t = try Terminal.init(std.testing.allocator, .{ .callbacks = spy.callbacks() });
    defer t.deinit();
    t.write("\x1b]0;hello\x07");
    try std.testing.expectEqual(@as(u32, 1), spy.titles);
    try std.testing.expectEqualStrings("hello", t.title());
}

test "cursor position report goes to write_pty" {
    var spy: Spy = .{};
    const t = try Terminal.init(std.testing.allocator, .{ .callbacks = spy.callbacks() });
    defer t.deinit();
    t.write("\x1b[6n");
    try std.testing.expectEqualStrings("\x1b[1;1R", spy.replyText());

    var spy2: Spy = .{};
    const t2 = try Terminal.init(std.testing.allocator, .{ .callbacks = spy2.callbacks() });
    defer t2.deinit();
    t2.write("ab\x1b[6n");
    try std.testing.expectEqualStrings("\x1b[1;3R", spy2.replyText());
}

fn writeLines(t: *Terminal, n: usize) void {
    var buf: [32]u8 = undefined;
    for (0..n) |i| t.write(std.fmt.bufPrint(&buf, "line {d}\r\n", .{i}) catch unreachable);
}

test "default scrollback keeps between 500 and 1200 rows at 80 columns" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    writeLines(t, 3000);
    // History is pruned a whole page at a time, so the count swings with the page boundary;
    // measured 569 to 1160 over 20,000 lines at 80 columns (215 to 452 at 200 columns).
    const n = t.scrollbackRows();
    try std.testing.expect(n >= 500 and n <= 1200);
}

test "scrollback_bytes = 0 keeps nothing" {
    const t = try Terminal.init(std.testing.allocator, .{ .scrollback_bytes = 0 });
    defer t.deinit();
    writeLines(t, 100);
    try std.testing.expectEqual(@as(usize, 0), t.scrollbackRows());
}

test "kitty image storage limit is zero" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    var limit: u64 = 1;
    try std.testing.expectEqual(c.GHOSTTY_SUCCESS, c.ghostty_terminal_get(t.handle, c.GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_STORAGE_LIMIT, &limit));
    try std.testing.expectEqual(@as(u64, 0), limit);
}

test "resize to 500x200 and to 1x1 keeps working" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    t.resize(500, 200, 0, 0);
    try std.testing.expectEqual(@as(u16, 500), t.size().cols);
    try std.testing.expectEqual(@as(u16, 200), t.size().rows);
    t.write("x");
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("x", t.rowText(0, &buf));
    t.resize(1, 1, 0, 0);
    try std.testing.expectEqual(@as(u16, 1), t.size().cols);
    try std.testing.expectEqual(@as(u16, 1), t.size().rows);
    t.write("hello\r\n");
}
