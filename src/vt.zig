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

pub const Rgb = struct { r: u8, g: u8, b: u8 };

/// Harf's default colors (the slice 2 theme): foreground 0.92, background (0.06, 0.06, 0.07).
pub const theme_fg: Rgb = .{ .r = 235, .g = 235, .b = 235 };
pub const theme_bg: Rgb = .{ .r = 15, .g = 15, .b = 18 };

/// Text attributes and colors of one cell. Colors are resolved (palette indices looked up); null
/// means "the terminal default".
pub const Style = struct {
    fg: ?Rgb = null,
    bg: ?Rgb = null,
    underline_color: ?Rgb = null,
    /// The library's flag bits: the `Flag` values, with the underline style in bits 8 to 10.
    flags: u16 = 0,

    pub const Flag = struct {
        pub const bold: u16 = c.GHOSTTY_STYLE_FLAG_BOLD;
        pub const italic: u16 = c.GHOSTTY_STYLE_FLAG_ITALIC;
        pub const faint: u16 = c.GHOSTTY_STYLE_FLAG_FAINT;
        pub const blink: u16 = c.GHOSTTY_STYLE_FLAG_BLINK;
        pub const inverse: u16 = c.GHOSTTY_STYLE_FLAG_INVERSE;
        pub const invisible: u16 = c.GHOSTTY_STYLE_FLAG_INVISIBLE;
        pub const strikethrough: u16 = c.GHOSTTY_STYLE_FLAG_STRIKETHROUGH;
        pub const overline: u16 = c.GHOSTTY_STYLE_FLAG_OVERLINE;
    };
    pub const Underline = enum { none, single, double, curly, dotted, dashed };

    pub fn underline(self: Style) Underline {
        return switch ((self.flags >> c.GHOSTTY_STYLE_UNDERLINE_SHIFT) & 7) {
            1 => .single,
            2 => .double,
            3 => .curly,
            4 => .dotted,
            5 => .dashed,
            else => .none,
        };
    }
};

/// The terminal's default colors as of the last `update`.
pub const Colors = struct { fg: Rgb, bg: Rgb, cursor: ?Rgb };

pub const Options = struct {
    default_fg: Rgb = theme_fg,
    default_bg: Rgb = theme_bg,
    cols: u16 = 80,
    rows: u16 = 24,
    /// libghostty keeps history in whole pages, so this is a limit to within about 400 KB.
    scrollback_bytes: usize = 1 << 20,
    callbacks: Callbacks = .{},
};

pub const Error = error{ OutOfMemory, Ghostty };

pub const KeyAction = enum(u8) { press = 0, release = 1, repeat = 2 };

pub const Wide = enum { narrow, wide, spacer_tail, spacer_head };

/// One grid cell: its codepoints (base plus combining marks) and its width role.
pub const Cell = struct { cps: []const u21, wide: Wide, style: Style = .{} };

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
    key_encoder: c.GhosttyKeyEncoder,
    key_event: c.GhosttyKeyEvent,
    /// Colors as of the last `update`.
    palette: [256]Rgb = @splat(.{ .r = 0, .g = 0, .b = 0 }),
    default_colors: Colors = .{ .fg = theme_fg, .bg = theme_bg, .cursor = null },

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
        var fg: c.GhosttyColorRgb = .{ .r = opts.default_fg.r, .g = opts.default_fg.g, .b = opts.default_fg.b };
        var bg: c.GhosttyColorRgb = .{ .r = opts.default_bg.r, .g = opts.default_bg.g, .b = opts.default_bg.b };
        try check(c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg));
        try check(c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg));
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
        errdefer c.ghostty_render_state_row_cells_free(self.row_cells);
        try check(c.ghostty_key_encoder_new(null, &self.key_encoder));
        errdefer c.ghostty_key_encoder_free(self.key_encoder);
        try check(c.ghostty_key_event_new(null, &self.key_event));
        return self;
    }

    pub fn deinit(self: *Terminal) void {
        c.ghostty_key_event_free(self.key_event);
        c.ghostty_key_encoder_free(self.key_encoder);
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

    /// Refreshes the render state from the terminal. Call once per frame, before `selectRow`,
    /// `cellInRow` and `cursor`. False on failure.
    pub fn update(self: *Terminal) bool {
        if (c.ghostty_render_state_update(self.render_state, self.handle) != c.GHOSTTY_SUCCESS) return false;
        var rc = std.mem.zeroes(c.GhosttyRenderStateColors);
        rc.size = @sizeOf(c.GhosttyRenderStateColors);
        if (c.ghostty_render_state_get(self.render_state, c.GHOSTTY_RENDER_STATE_DATA_COLORS, &rc) == c.GHOSTTY_SUCCESS) {
            self.default_colors = .{
                .fg = .{ .r = rc.foreground.r, .g = rc.foreground.g, .b = rc.foreground.b },
                .bg = .{ .r = rc.background.r, .g = rc.background.g, .b = rc.background.b },
                .cursor = if (rc.cursor_has_value) .{ .r = rc.cursor.r, .g = rc.cursor.g, .b = rc.cursor.b } else null,
            };
            for (rc.palette, 0..) |p, i| self.palette[i] = .{ .r = p.r, .g = p.g, .b = p.b };
        }
        return true;
    }

    /// The default colors as of the last `update`.
    pub fn colors(self: *const Terminal) Colors {
        return self.default_colors;
    }

    /// Palette entry `i` as of the last `update`.
    pub fn paletteColor(self: *const Terminal, i: u8) Rgb {
        return self.palette[i];
    }

    /// Points `row_cells` at the cells of visible row `row` of the last `update`. False if the row does not exist.
    pub fn selectRow(self: *Terminal, row: u16) bool {
        if (c.ghostty_render_state_get(self.render_state, c.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, @ptrCast(&self.row_iter)) != c.GHOSTTY_SUCCESS) return false;
        var i: u32 = 0;
        while (i <= row) : (i += 1) {
            if (!c.ghostty_render_state_row_iterator_next(self.row_iter)) return false;
        }
        return c.ghostty_render_state_row_get(self.row_iter, c.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, @ptrCast(&self.row_cells)) == c.GHOSTTY_SUCCESS;
    }

    /// The cell at `col` of the row chosen by `selectRow`; blank if `col` is out of range.
    pub fn cellInRow(self: *Terminal, col: u16, buf: *[16]u21) Cell {
        const blank: Cell = .{ .cps = buf[0..0], .wide = .narrow };
        if (c.ghostty_render_state_row_cells_select(self.row_cells, col) != c.GHOSTTY_SUCCESS) return blank;
        return self.readCell(buf);
    }

    pub const CursorShape = enum { bar, block, underline, block_hollow };
    pub const Cursor = struct { col: u16, row: u16, visible: bool, shape: CursorShape = .block, color: ?Rgb = null };

    /// The cursor of the last `update`; null when it is outside the viewport.
    pub fn cursor(self: *Terminal) ?Cursor {
        var has: bool = false;
        _ = c.ghostty_render_state_get(self.render_state, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &has);
        if (!has) return null;
        var x: u16 = 0;
        var y: u16 = 0;
        var vis: bool = true;
        _ = c.ghostty_render_state_get(self.render_state, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &x);
        _ = c.ghostty_render_state_get(self.render_state, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &y);
        _ = c.ghostty_render_state_get(self.render_state, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &vis);
        var style: c.GhosttyCursorStyle = c.GHOSTTY_CURSOR_STYLE_BLOCK;
        _ = c.ghostty_render_state_get(self.render_state, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &style);
        const shape: CursorShape = switch (style) {
            c.GHOSTTY_CURSOR_STYLE_BAR => .bar,
            c.GHOSTTY_CURSOR_STYLE_UNDERLINE => .underline,
            c.GHOSTTY_CURSOR_STYLE_BLOCK_HOLLOW => .block_hollow,
            else => .block,
        };
        return .{ .col = x, .row = y, .visible = vis, .shape = shape, .color = self.default_colors.cursor };
    }

    /// The bytes a key press sends to the child, for the terminal's current modes (application
    /// cursor keys, kitty flags). `mods` uses the bits of `keys.Mods`; `utf8` is the text the
    /// platform produced for the event (may be empty). Empty result: nothing to send.
    /// `unshifted` is the layout's character for the key with no modifiers (0 if unknown); the kitty
    /// protocol names a key by it. A private-use or control value (AppKit's for arrows) is ignored.
    pub fn encodeKey(self: *Terminal, key: c.GhosttyKey, mods: u32, utf8: []const u8, unshifted: u21, action: KeyAction, out: []u8) []const u8 {
        _ = c.ghostty_key_encoder_set_from_terminal(self.key_encoder, self.handle);
        _ = c.ghostty_key_event_set_key(self.key_event, key);
        _ = c.ghostty_key_event_set_mods(self.key_event, @intCast(mods & 0xF));
        _ = c.ghostty_key_event_set_action(self.key_event, switch (action) {
            .press => c.GHOSTTY_KEY_ACTION_PRESS,
            .release => c.GHOSTTY_KEY_ACTION_RELEASE,
            .repeat => c.GHOSTTY_KEY_ACTION_REPEAT,
        });
        // Control characters (AppKit reports "\x03" for Ctrl+C) are derived from the key and
        // modifiers; passing them as text makes the encoder emit a CSI u sequence instead.
        // AppKit also reports private-use characters (U+F700 for Up, ...) for function keys;
        // with the kitty keyboard protocol on, the encoder would send those as text.
        const text = if (isPrivateUse(utf8)) "" else if (std.mem.indexOfAny(u8, utf8, "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f\x7f") != null) "" else utf8;
        _ = c.ghostty_key_event_set_utf8(self.key_event, .{ .ptr = text.ptr, .len = text.len });
        // The kitty keyboard protocol names a key by its unshifted character; set it every call so
        // a previous key's value never leaks into a function key.
        const named = if (unshifted >= 0x20 and unshifted != 0x7f and !(unshifted >= 0xE000 and unshifted <= 0xF8FF)) unshifted else @import("keys.zig").unshiftedCodepoint(key);
        _ = c.ghostty_key_event_set_unshifted_codepoint(self.key_event, named);
        var written: usize = 0;
        if (c.ghostty_key_encoder_encode(self.key_encoder, self.key_event, out.ptr, out.len, &written) != c.GHOSTTY_SUCCESS) return out[0..0];
        return out[0..written];
    }

    fn isPrivateUse(utf8: []const u8) bool {
        if (utf8.len < 3) return false;
        const len = std.unicode.utf8ByteSequenceLength(utf8[0]) catch return false;
        if (len > utf8.len) return false;
        const cp = std.unicode.utf8Decode(utf8[0..len]) catch return false;
        return cp >= 0xE000 and cp <= 0xF8FF;
    }

    /// The kitty keyboard protocol flags the program has set (0 = legacy keys).
    pub fn kittyFlags(self: *Terminal) u8 {
        var flags: u8 = 0;
        _ = c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, &flags);
        return flags;
    }

    pub fn bracketedPaste(self: *Terminal) bool {
        var cfg: c.GhosttyTerminalModeConfig = .{ .mode = c.ghostty_mode_new(2004, false), .value = false };
        _ = c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_MODE, &cfg);
        return cfg.value;
    }

    /// Appends what pasting `text` sends to the child: newlines become CR, and in bracketed
    /// paste mode the text is wrapped in ESC[200~ ... ESC[201~. The library removes control
    /// characters that could end a bracketed paste early.
    pub fn encodePaste(self: *Terminal, text: []const u8, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
        if (text.len == 0) return;
        const bracketed = self.bracketedPaste();
        // The library turns every LF into CR, so a CRLF would become two Enters. Unbracketed, fold
        // CRLF into LF first. (Bracketed text goes to the program as it is.)
        var folded: std.ArrayList(u8) = .empty;
        defer folded.deinit(gpa);
        const src: []const u8 = if (bracketed) text else blk: {
            try folded.ensureTotalCapacity(gpa, text.len);
            for (text, 0..) |ch, i| {
                if (ch == '\r' and i + 1 < text.len and text[i + 1] == '\n') continue;
                folded.appendAssumeCapacity(ch);
            }
            break :blk folded.items;
        };
        const copy = try gpa.dupe(u8, src); // the encoder edits its input in place
        defer gpa.free(copy);
        var needed: usize = 0;
        const first = c.ghostty_paste_encode(copy.ptr, copy.len, bracketed, null, 0, &needed);
        if (first != c.GHOSTTY_OUT_OF_SPACE and first != c.GHOSTTY_SUCCESS) return error.Ghostty;
        const start = out.items.len;
        try out.resize(gpa, start + needed);
        const copy2 = try gpa.dupe(u8, src);
        defer gpa.free(copy2);
        var written: usize = 0;
        if (c.ghostty_paste_encode(copy2.ptr, copy2.len, bracketed, out.items[start..].ptr, needed, &written) != c.GHOSTTY_SUCCESS) return error.Ghostty;
        out.shrinkRetainingCapacity(start + written);
    }

    /// Scrolls the viewport through the scrollback by `delta` rows (negative = toward older output).
    /// The library clamps at both ends.
    pub fn scrollViewport(self: *Terminal, delta: i32) void {
        const behavior: c.GhosttyTerminalScrollViewport = .{ .tag = c.GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA, .value = .{ .delta = delta } };
        _ = c.ghostty_terminal_scroll_viewport(self.handle, behavior);
    }

    pub fn scrollToBottom(self: *Terminal) void {
        const behavior: c.GhosttyTerminalScrollViewport = .{ .tag = c.GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM, .value = .{ .delta = 0 } };
        _ = c.ghostty_terminal_scroll_viewport(self.handle, behavior);
    }

    /// Where the viewport is in the scrollable area: `offset` rows from the top, `rows` visible, `total` in all.
    pub const Viewport = struct { offset: usize, total: usize, rows: usize };

    pub fn viewport(self: *Terminal) Viewport {
        var sb: c.GhosttyTerminalScrollbar = std.mem.zeroes(c.GhosttyTerminalScrollbar);
        _ = c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_SCROLLBAR, &sb);
        return .{ .offset = @intCast(sb.offset), .total = @intCast(sb.total), .rows = @intCast(sb.len) };
    }

    pub fn atBottom(self: *Terminal) bool {
        const v = self.viewport();
        return v.offset + v.rows >= v.total;
    }

    pub fn onAlternateScreen(self: *Terminal) bool {
        var screen: c.GhosttyTerminalScreen = c.GHOSTTY_TERMINAL_SCREEN_PRIMARY;
        _ = c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen);
        return screen == c.GHOSTTY_TERMINAL_SCREEN_ALTERNATE;
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
        if (str.len == 0) return ""; // the pointer may be null when no title is set
        return str.ptr[0..str.len];
    }

    /// The style of the cell `row_cells` currently points at.
    fn readStyle(self: *Terminal) Style {
        var style: Style = .{};
        var col: c.GhosttyColorRgb = undefined;
        if (c.ghostty_render_state_row_cells_get(self.row_cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &col) == c.GHOSTTY_SUCCESS)
            style.fg = .{ .r = col.r, .g = col.g, .b = col.b };
        if (c.ghostty_render_state_row_cells_get(self.row_cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &col) == c.GHOSTTY_SUCCESS)
            style.bg = .{ .r = col.r, .g = col.g, .b = col.b };
        var has: bool = false;
        _ = c.ghostty_render_state_row_cells_get(self.row_cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, &has);
        if (has) {
            var st = std.mem.zeroes(c.GhosttyStyle);
            if (c.ghostty_render_state_row_cells_get(self.row_cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &st) == c.GHOSTTY_SUCCESS) {
                style.flags = st.flags;
                style.underline_color = switch (st.underline_color.tag) {
                    c.GHOSTTY_STYLE_COLOR_PALETTE => self.palette[st.underline_color.value.palette],
                    c.GHOSTTY_STYLE_COLOR_RGB => .{ .r = st.underline_color.value.rgb.r, .g = st.underline_color.value.rgb.g, .b = st.underline_color.value.rgb.b },
                    else => null,
                };
            }
        }
        return style;
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
        // OUT_OF_SPACE still wrote the first 16 codepoints and set `len` to the real count.
        const got = c.ghostty_render_state_row_cells_get(self.row_cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &gb);
        if (got == c.GHOSTTY_SUCCESS or got == c.GHOSTTY_OUT_OF_SPACE) {
            n = @min(gb.len, cps.len);
        }
        for (cps[0..n], 0..) |cp, i| buf[i] = @intCast(cp);
        return .{ .cps = buf[0..n], .wide = switch (wide) {
            c.GHOSTTY_CELL_WIDE_WIDE => .wide,
            c.GHOSTTY_CELL_WIDE_SPACER_TAIL => .spacer_tail,
            c.GHOSTTY_CELL_WIDE_SPACER_HEAD => .spacer_head,
            else => .narrow,
        }, .style = self.readStyle() };
    }

    /// The cell at (`col`, `row`) of the visible screen; blank (no codepoints) if out of range.
    /// `buf` backs the returned codepoints.
    pub fn cell(self: *Terminal, col: u16, row: u16, buf: *[16]u21) Cell {
        const blank: Cell = .{ .cps = buf[0..0], .wide = .narrow };
        if (!self.update() or !self.selectRow(row)) return blank;
        return self.cellInRow(col, buf);
    }

    /// UTF-8 text of visible row `row`: blank cells are spaces, the spacer after a wide cell is
    /// skipped, trailing blanks are trimmed. The result is a slice of `out`; text that does not fit is cut off.
    pub fn rowText(self: *Terminal, row: u16, out: []u8) []const u8 {
        if (!self.update() or !self.selectRow(row)) return out[0..0];
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

test "title is empty when never set" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    try std.testing.expectEqualStrings("", t.title());
}

test "cell with more than 16 codepoints keeps the first 16" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    t.write("a");
    for (0..20) |_| t.write("\u{64E}");
    var buf: [16]u21 = undefined;
    const cl = t.cell(0, 0, &buf);
    try std.testing.expectEqual(@as(usize, 16), cl.cps.len);
    try std.testing.expectEqual(@as(u21, 'a'), cl.cps[0]);
}

test "cursor follows output" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    t.write("ab\r\ncd");
    try std.testing.expect(t.update());
    try std.testing.expectEqual(Terminal.Cursor{ .col = 2, .row = 1, .visible = true }, t.cursor().?);
    t.write("\x1b[?25l");
    try std.testing.expect(t.update());
    try std.testing.expect(!t.cursor().?.visible);
}

test "selectRow does not refresh" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    try std.testing.expect(t.update());
    t.write("x");
    var buf: [16]u21 = undefined;
    try std.testing.expect(t.selectRow(0));
    try std.testing.expectEqual(@as(usize, 0), t.cellInRow(0, &buf).cps.len);
    try std.testing.expect(t.update());
    try std.testing.expect(t.selectRow(0));
    try std.testing.expectEqualSlices(u21, &.{'x'}, t.cellInRow(0, &buf).cps);
}

fn encFor(t: *Terminal, code: u16, mods: u32, utf8: []const u8, buf: []u8) []const u8 {
    return t.encodeKey(@import("keys.zig").fromMac(code).?, mods, utf8, 0, .press, buf);
}

test "up arrow, normal and application mode" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[A", encFor(t, 126, 0, "", &buf));
    t.write("\x1b[?1h");
    try std.testing.expectEqualStrings("\x1bOA", encFor(t, 126, 0, "", &buf));
}

test "AppKit reports private-use text for function keys; arrows still encode" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[A", encFor(t, 126, 0, "\u{F700}", &buf)); // up
    try std.testing.expectEqualStrings("\x1b[B", encFor(t, 125, 0, "\u{F701}", &buf)); // down
    try std.testing.expectEqualStrings("\x1b[3~", encFor(t, 117, 0, "\u{F728}", &buf)); // forward delete
    try std.testing.expectEqualStrings("\x1bOP", encFor(t, 122, 0, "\u{F704}", &buf)); // F1
}

test "arrows and function keys with the kitty keyboard protocol on" {
    // Claude Code and other TUIs send ESC[>1u; AppKit's private-use text must not reach the encoder.
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    t.write("\x1b[>1u");
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[A", encFor(t, 126, 0, "\u{F700}", &buf));
    try std.testing.expectEqualStrings("\x1b[B", encFor(t, 125, 0, "\u{F701}", &buf));
    try std.testing.expectEqualStrings("\x1b[3~", encFor(t, 117, 0, "\u{F728}", &buf));
    try std.testing.expectEqualStrings("\x1b[C", encFor(t, 124, 0, "", &buf));
}

test "kitty keyboard flags follow the program's requests" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    try std.testing.expectEqual(@as(u8, 0), t.kittyFlags());
    t.write("\x1b[>1u");
    try std.testing.expectEqual(@as(u8, 1), t.kittyFlags());
    t.write("\x1b[<u");
    try std.testing.expectEqual(@as(u8, 0), t.kittyFlags());
}

test "ctrl letters under the kitty keyboard protocol (what Claude Code sets)" {
    // Claude Code asks for flags 5 (disambiguate + report alternates). Without the key's
    // unshifted codepoint the encoder produced no bytes at all, so Ctrl+C did nothing.
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\x03", encFor(t, 8, 2, "\x03", &buf)); // legacy mode
    t.write("\x1b[>5u");
    try std.testing.expectEqualStrings("\x1b[99;5u", encFor(t, 8, 2, "\x03", &buf)); // ctrl c
    try std.testing.expectEqualStrings("\x1b[100;5u", encFor(t, 2, 2, "\x04", &buf)); // ctrl d
    try std.testing.expectEqualStrings("\x1b[108;5u", encFor(t, 37, 2, "\x0c", &buf)); // ctrl l
    try std.testing.expectEqualStrings("\x1b[A", encFor(t, 126, 0, "\u{F700}", &buf)); // arrows unchanged
}

test "the layout's unshifted letter names the key under the kitty protocol" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    t.write("\x1b[>5u");
    var buf: [32]u8 = undefined;
    const q = @import("keys.zig").fromMac(12).?; // physical Q, AZERTY "a"
    // unicode key code 97 (the layout's a), base-layout key 113 (the physical q), as the protocol says
    try std.testing.expectEqualStrings("\x1b[97::113;5u", t.encodeKey(q, 2, "", 'a', .press, &buf));
    // AppKit's private-use "unshifted" character for an arrow is not a codepoint to send
    try std.testing.expectEqualStrings("\x1b[A", t.encodeKey(@import("keys.zig").fromMac(126).?, 0, "", 0xF700, .press, &buf));
}

test "keypad enter sends a carriage return, like Return" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\r", encFor(t, 76, 0, "\r", &buf));
}

test "paste: CRLF is one Enter, a lone CR stays one" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try t.encodePaste("a\r\nb\r\n\r\nc\rd\ne", &out, std.testing.allocator);
    try std.testing.expectEqualStrings("a\rb\r\rc\rd\re", out.items);
    out.clearRetainingCapacity();
    t.write("\x1b[?2004h"); // bracketed: the text goes through as it is
    try t.encodePaste("a\r\nb", &out, std.testing.allocator);
    try std.testing.expectEqualStrings("\x1b[200~a\r\nb\x1b[201~", out.items);
}

test "ctrl c, enter, backspace, shift tab" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\x03", encFor(t, 8, 2, "", &buf));
    try std.testing.expectEqualStrings("\x03", encFor(t, 8, 2, "\x03", &buf));
    try std.testing.expectEqualStrings("\r", encFor(t, 36, 0, "\r", &buf));
    try std.testing.expectEqualStrings("\x7f", encFor(t, 51, 0, "\x7f", &buf));
    try std.testing.expectEqualStrings("\x1b[Z", encFor(t, 48, 1, "\t", &buf));
}

test "paste: newlines, bracketed mode, and an embedded end marker" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try t.encodePaste("a\nb", &out, std.testing.allocator);
    try std.testing.expectEqualStrings("a\rb", out.items);
    out.clearRetainingCapacity();
    t.write("\x1b[?2004h");
    try t.encodePaste("a\nb", &out, std.testing.allocator);
    try std.testing.expectEqualStrings("\x1b[200~a\nb\x1b[201~", out.items); // bracketed text keeps its newlines
    out.clearRetainingCapacity();
    try t.encodePaste("x\x1b[201~y", &out, std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, out.items[6 .. out.items.len - 6], "\x1b") == null);
}

fn cellOf(t: *Terminal, row: u16, col: u16, buf: *[16]u21) Cell {
    _ = t.update();
    _ = t.selectRow(row);
    return t.cellInRow(col, buf);
}

test "sgr colors resolve" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    t.write("\x1b[31mA\x1b[38;5;196mB\x1b[38;2;1;2;3mC\x1b[48;2;9;8;7mD\x1b[0mE");
    var buf: [16]u21 = undefined;
    const a = cellOf(t, 0, 0, &buf);
    try std.testing.expect(a.style.fg != null and a.style.fg.?.r > 150 and a.style.fg.?.g < 120); // palette red
    try std.testing.expectEqual(t.paletteColor(1), a.style.fg.?);
    const b = cellOf(t, 0, 1, &buf);
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 0, .b = 0 }, b.style.fg.?); // 256-color cube
    const cc = cellOf(t, 0, 2, &buf);
    try std.testing.expectEqual(Rgb{ .r = 1, .g = 2, .b = 3 }, cc.style.fg.?); // truecolor
    const d = cellOf(t, 0, 3, &buf);
    try std.testing.expectEqual(Rgb{ .r = 9, .g = 8, .b = 7 }, d.style.bg.?);
    const e = cellOf(t, 0, 4, &buf);
    try std.testing.expect(e.style.fg == null and e.style.bg == null and e.style.flags == 0);
}

test "style flags and underline styles" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    t.write("\x1b[1;3;2;7;8;9mX\x1b[0m\x1b[4mS\x1b[21mD\x1b[4:3mC\x1b[4:4mT\x1b[4:5mH\x1b[24m\x1b[53mO\x1b[0mN");
    var buf: [16]u21 = undefined;
    const F = Style.Flag;
    const x = cellOf(t, 0, 0, &buf).style;
    try std.testing.expectEqual(F.bold | F.italic | F.faint | F.inverse | F.invisible | F.strikethrough, x.flags & 0xFF);
    try std.testing.expectEqual(Style.Underline.none, x.underline());
    try std.testing.expectEqual(Style.Underline.single, cellOf(t, 0, 1, &buf).style.underline());
    try std.testing.expectEqual(Style.Underline.double, cellOf(t, 0, 2, &buf).style.underline());
    try std.testing.expectEqual(Style.Underline.curly, cellOf(t, 0, 3, &buf).style.underline());
    try std.testing.expectEqual(Style.Underline.dotted, cellOf(t, 0, 4, &buf).style.underline());
    try std.testing.expectEqual(Style.Underline.dashed, cellOf(t, 0, 5, &buf).style.underline());
    const o = cellOf(t, 0, 6, &buf).style;
    try std.testing.expect(o.flags & F.overline != 0 and o.underline() == .none);
    try std.testing.expectEqual(@as(u16, 0), cellOf(t, 0, 7, &buf).style.flags);
}

test "underline color resolves" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    t.write("\x1b[4m\x1b[58;2;10;20;30mU\x1b[58;5;1mP");
    var buf: [16]u21 = undefined;
    try std.testing.expectEqual(Rgb{ .r = 10, .g = 20, .b = 30 }, cellOf(t, 0, 0, &buf).style.underline_color.?);
    try std.testing.expectEqual(t.paletteColor(1), cellOf(t, 0, 1, &buf).style.underline_color.?);
}

test "default colors are Harf's and programs can change them" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    _ = t.update();
    try std.testing.expectEqual(theme_fg, t.colors().fg);
    try std.testing.expectEqual(theme_bg, t.colors().bg);
    t.write("\x1b]11;rgb:10/20/30\x07");
    _ = t.update();
    try std.testing.expectEqual(Rgb{ .r = 0x10, .g = 0x20, .b = 0x30 }, t.colors().bg);
    const custom = try Terminal.init(std.testing.allocator, .{ .default_fg = .{ .r = 1, .g = 2, .b = 3 }, .default_bg = .{ .r = 4, .g = 5, .b = 6 } });
    defer custom.deinit();
    _ = custom.update();
    try std.testing.expectEqual(Rgb{ .r = 1, .g = 2, .b = 3 }, custom.colors().fg);
    try std.testing.expectEqual(Rgb{ .r = 4, .g = 5, .b = 6 }, custom.colors().bg);
}

test "palette change shows" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    t.write("\x1b]4;1;rgb:ff/00/00\x07\x1b[31mx");
    var buf: [16]u21 = undefined;
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 0, .b = 0 }, cellOf(t, 0, 0, &buf).style.fg.?);
}

test "erased cell keeps its background" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    t.write("\x1b[44m\x1b[2K");
    var buf: [16]u21 = undefined;
    const c0 = cellOf(t, 0, 0, &buf);
    try std.testing.expectEqual(@as(usize, 0), c0.cps.len);
    try std.testing.expectEqual(t.paletteColor(4), c0.style.bg.?);
    try std.testing.expectEqual(t.paletteColor(4), cellOf(t, 0, 79, &buf).style.bg.?);
}

fn lineNo(t: *Terminal, row: u16) !i64 {
    var buf: [64]u8 = undefined;
    const text = t.rowText(row, &buf);
    if (!std.mem.startsWith(u8, text, "line ")) return error.NotALine;
    return std.fmt.parseInt(i64, text[5..], 10);
}

fn fillHistory(t: *Terminal, n: usize) void {
    var buf: [32]u8 = undefined;
    for (0..n) |i| t.write(std.fmt.bufPrint(&buf, "line {d}\r\n", .{i}) catch unreachable);
}

test "viewport scrolls into history" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 20, .rows = 10 });
    defer t.deinit();
    fillHistory(t, 60);
    _ = t.update();
    const before = try lineNo(t, 0);
    try std.testing.expect(t.viewport().offset + t.viewport().rows == t.viewport().total); // at the bottom
    t.scrollViewport(-5);
    _ = t.update();
    try std.testing.expectEqual(before - 5, try lineNo(t, 0));
    t.scrollToBottom();
    _ = t.update();
    try std.testing.expectEqual(before, try lineNo(t, 0));
}

test "viewport clamps" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 20, .rows = 10 });
    defer t.deinit();
    fillHistory(t, 60);
    t.scrollViewport(-100000);
    _ = t.update();
    try std.testing.expectEqual(@as(usize, 0), t.viewport().offset);
    try std.testing.expectEqual(@as(i64, 0), try lineNo(t, 0)); // the oldest line
    t.scrollViewport(100000);
    try std.testing.expectEqual(t.viewport().total, t.viewport().offset + t.viewport().rows);
    for (0..1000) |i| t.scrollViewport(if (i % 2 == 0) -7 else 3);
    const v = t.viewport();
    try std.testing.expect(v.offset + v.rows <= v.total);
    t.scrollToBottom();
    try std.testing.expectEqual(t.viewport().total, t.viewport().offset + t.viewport().rows);
}

test "cursor hidden while scrolled" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 20, .rows = 10 });
    defer t.deinit();
    fillHistory(t, 60);
    _ = t.update();
    try std.testing.expect(t.cursor() != null);
    t.scrollViewport(-5);
    _ = t.update();
    try std.testing.expect(t.cursor() == null);
}

test "alternate screen is reported" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    try std.testing.expect(!t.onAlternateScreen());
    t.write("\x1b[?1049h");
    try std.testing.expect(t.onAlternateScreen());
    t.write("\x1b[?1049l");
    try std.testing.expect(!t.onAlternateScreen());
}
