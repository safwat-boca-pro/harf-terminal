//! Thin Zig wrapper over libghostty-vt's C API (parser, screen, scrollback, cells).
//! The grid is in logical order: one cell per character, combining marks inside their base cell.
//! Not thread-safe; callers serialize access (see term.zig).
const std = @import("std");
pub const c = @import("ghostty_c");

pub const Options = struct {
    cols: u16 = 80,
    rows: u16 = 24,
    /// libghostty keeps history in whole pages, so this is a limit to within about 400 KB.
    scrollback_bytes: usize = 1 << 20,
};

pub const Error = error{ OutOfMemory, Ghostty };

fn check(r: c.GhosttyResult) Error!void {
    if (r == c.GHOSTTY_SUCCESS) return;
    if (r == c.GHOSTTY_OUT_OF_MEMORY) return error.OutOfMemory;
    return error.Ghostty;
}

pub const Terminal = struct {
    gpa: std.mem.Allocator,
    handle: c.GhosttyTerminal,
    render_state: c.GhosttyRenderState,
    row_iter: c.GhosttyRenderStateRowIterator,
    row_cells: c.GhosttyRenderStateRowCells,

    pub fn init(gpa: std.mem.Allocator, opts: Options) Error!*Terminal {
        const self = try gpa.create(Terminal);
        errdefer gpa.destroy(self);
        self.gpa = gpa;
        try check(c.ghostty_terminal_new(null, &self.handle, opts.cols, opts.rows));
        errdefer c.ghostty_terminal_free(self.handle);
        var scrollback = opts.scrollback_bytes;
        try check(c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &scrollback));
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

    /// UTF-8 text of visible row `row`: blank cells are spaces, trailing blanks are trimmed.
    /// The result is a slice of `out`; text that does not fit is cut off.
    pub fn rowText(self: *Terminal, row: u16, out: []u8) []const u8 {
        if (!self.selectRow(row)) return out[0..0];
        var n: usize = 0;
        var end: usize = 0; // length after the last non-blank cell
        while (c.ghostty_render_state_row_cells_next(self.row_cells)) {
            var cps: [16]u32 = undefined;
            var buf = c.GhosttyCodepointBuffer{ .ptr = &cps, .cap = cps.len, .len = 0 };
            if (c.ghostty_render_state_row_cells_get(self.row_cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &buf) != c.GHOSTTY_SUCCESS or buf.len == 0) {
                if (n < out.len) {
                    out[n] = ' ';
                    n += 1;
                }
                continue;
            }
            for (cps[0..@min(buf.len, cps.len)]) |cp| {
                const len = std.unicode.utf8CodepointSequenceLength(@intCast(cp)) catch continue;
                if (n + len > out.len) return out[0..end];
                _ = std.unicode.utf8Encode(@intCast(cp), out[n..]) catch continue;
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
