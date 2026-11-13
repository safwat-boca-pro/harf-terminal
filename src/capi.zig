//! C ABI surface. Keep in sync with include/harf.h.
const std = @import("std");
const ct = @import("shape/ct.zig");
const term = @import("term.zig");
const vt = @import("vt.zig");
const draw = @import("draw.zig");

/// Phase 0 smoke test. Returns 0x48415246 ("HARF").
export fn harf_ping() u32 {
    return 0x48415246;
}

// ---- Terminal sessions (Phase 3): a child on a PTY, parsed into a logical-order grid ----

pub const HarfTermCallbacks = extern struct {
    ctx: ?*anyopaque,
    wake: ?*const fn (ctx: ?*anyopaque) callconv(.c) void,
    title: ?*const fn (ctx: ?*anyopaque) callconv(.c) void,
    bell: ?*const fn (ctx: ?*anyopaque) callconv(.c) void,
    exited: ?*const fn (ctx: ?*anyopaque, status: c_int) callconv(.c) void,
};

/// Opaque to C. Holds the session and the caller's callbacks; the session's own callbacks are
/// adapters that forward to `cb` (they run on the I/O thread).
const HarfTerm = struct {
    session: *term.Session,
    cb: HarfTermCallbacks,

    fn from(ctx: ?*anyopaque) *HarfTerm {
        return @ptrCast(@alignCast(ctx.?));
    }
    fn wake(ctx: ?*anyopaque) void {
        const self = from(ctx);
        if (self.cb.wake) |f| f(self.cb.ctx);
    }
    fn title(ctx: ?*anyopaque) void {
        const self = from(ctx);
        if (self.cb.title) |f| f(self.cb.ctx);
    }
    fn bell(ctx: ?*anyopaque) void {
        const self = from(ctx);
        if (self.cb.bell) |f| f(self.cb.ctx);
    }
    fn exited(ctx: ?*anyopaque, status: u8) void {
        const self = from(ctx);
        if (self.cb.exited) |f| f(self.cb.ctx, status);
    }
};

/// Starts a session. `argv` is a NULL-terminated program and arguments (`argv[0]` is the path),
/// or NULL for the user's login shell. Returns NULL for a zero size or if the child cannot start.
export fn harf_term_new(
    cols: u16,
    rows: u16,
    scrollback_bytes: usize,
    argv: ?[*:null]const ?[*:0]const u8,
    cb: ?*const HarfTermCallbacks,
) ?*HarfTerm {
    if (cols == 0 or rows == 0) return null;
    const gpa = std.heap.smp_allocator;
    const self = gpa.create(HarfTerm) catch return null;
    errdefer gpa.destroy(self);
    self.cb = if (cb) |p| p.* else .{ .ctx = null, .wake = null, .title = null, .bell = null, .exited = null };

    var list: std.ArrayList([:0]const u8) = .empty;
    defer list.deinit(gpa);
    if (argv) |a| {
        var i: usize = 0;
        while (a[i]) |arg| : (i += 1) list.append(gpa, std.mem.span(arg)) catch return null;
    }
    self.session = term.Session.start(gpa, .{
        .cols = cols,
        .rows = rows,
        .scrollback_bytes = scrollback_bytes,
        .argv = if (argv != null and list.items.len > 0) list.items else null,
        .callbacks = .{ .ctx = self, .wake = HarfTerm.wake, .title = HarfTerm.title, .bell = HarfTerm.bell, .exited = HarfTerm.exited },
    }) catch return null;
    return self;
}

/// Stops the session; the child is hung up on if it is still running. No callback runs after this returns.
export fn harf_term_free(t: *HarfTerm) void {
    t.session.deinit();
    std.heap.smp_allocator.destroy(t);
}

/// Sends bytes to the child as if typed. 0 on success.
export fn harf_term_input(t: *HarfTerm, bytes: [*]const u8, len: usize) c_int {
    t.session.input(bytes[0..len]) catch return -1;
    return 0;
}

/// Resizes the grid and the PTY; `cell_w_px` and `cell_h_px` are the pixel size of one cell. 0 on success.
export fn harf_term_resize(t: *HarfTerm, cols: u16, rows: u16, cell_w_px: u32, cell_h_px: u32) c_int {
    t.session.resize(cols, rows, cell_w_px, cell_h_px) catch return -1;
    return 0;
}

/// Copies the UTF-8 text of visible row `row` (trailing blanks trimmed, no NUL) into `out`.
/// Returns the number of bytes written, cut off at `cap`.
export fn harf_term_row_text(t: *HarfTerm, row: u16, out: [*]u8, cap: usize) usize {
    const g = t.session.lock();
    defer t.session.unlock();
    return g.rowText(row, out[0..cap]).len;
}

/// Sends a key event. `keycode` is the macOS virtual keycode, `mods` the HARF_MOD_* bits, `utf8` the
/// text AppKit produced (may be empty), `action` 0 press, 1 release, 2 repeat. Returns 1 if the key was
/// handled (and its bytes queued), 0 if it is a text key that the caller should send with
/// harf_term_input, -1 on error.
export fn harf_term_key(t: *HarfTerm, keycode: u16, mods: u32, utf8: ?[*]const u8, len: usize, action: c_int) c_int {
    const act: vt.KeyAction = switch (action) {
        1 => .release,
        2 => .repeat,
        else => .press,
    };
    const text: []const u8 = if (utf8) |p| p[0..len] else "";
    const handled = t.session.key(keycode, mods, text, act) catch return -1;
    return if (handled) 1 else 0;
}

/// Pastes text, framed for the terminal's paste mode. 0 on success.
export fn harf_term_paste(t: *HarfTerm, utf8: [*]const u8, len: usize) c_int {
    t.session.paste(utf8[0..len]) catch return -1;
    return 0;
}

/// Copies the window title the child set into `out` (no NUL). Returns bytes written, cut off at `cap`.
export fn harf_term_title(t: *HarfTerm, out: [*]u8, cap: usize) usize {
    var buf: [512]u8 = undefined;
    const title = t.session.title(&buf);
    const n = @min(title.len, cap);
    @memcpy(out[0..n], title[0..n]);
    return n;
}

pub const HarfCellMetrics = extern struct { cell_w: f32, cell_h: f32, ascent: f32 };

/// A font at `size_px` device pixels plus its glyph cache. NULL if Menlo is unavailable.
export fn harf_painter_new(size_px: f32) ?*draw.Painter {
    return draw.Painter.init(std.heap.smp_allocator, size_px) catch null;
}

export fn harf_painter_free(p: *draw.Painter) void {
    p.deinit();
}

export fn harf_painter_metrics(p: *draw.Painter, out: *HarfCellMetrics) void {
    const m = p.metrics();
    out.* = .{ .cell_w = m.cell_w, .cell_h = m.cell_h, .ascent = m.ascent };
}

/// Draws rows `first_row`..`last_row` (inclusive, clamped) and the cursor into a y-down CGContext in
/// device pixels; the grid's top-left is the context's origin. Takes the session lock itself.
export fn harf_term_draw(t: *HarfTerm, p: *draw.Painter, ctx: *ct.CGContext, first_row: u16, last_row: u16) void {
    const g = t.session.lock();
    defer t.session.unlock();
    p.drawRows(g, ctx, first_row, last_row);
}

/// Re-arms the `wake` callback; call before reading the grid for a redraw.
export fn harf_term_wake_handled(t: *HarfTerm) void {
    t.session.wakeHandled();
}

/// The child's exit code once it has ended and its output is parsed, -1 while it runs.
export fn harf_term_exit_status(t: *HarfTerm) c_int {
    return if (t.session.exitStatus()) |s| s else -1;
}

const TestExit = struct {
    status: std.atomic.Value(c_int) = .init(-1),
    fn onExited(ctx: ?*anyopaque, status: c_int) callconv(.c) void {
        const self: *TestExit = @ptrCast(@alignCast(ctx.?));
        self.status.store(status, .release);
    }
};

test "harf_term round trip through the C ABI" {
    var state: TestExit = .{};
    const cb: HarfTermCallbacks = .{ .ctx = &state, .wake = null, .title = null, .bell = null, .exited = TestExit.onExited };
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "printf hi" };
    const t = harf_term_new(80, 24, 1 << 20, &argv, &cb) orelse return error.TermNotCreated;
    defer harf_term_free(t);
    var waited: u32 = 0;
    while (harf_term_exit_status(t) != 0 and waited < 10_000) : (waited += 5) {
        const ts: std.c.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    try std.testing.expectEqual(@as(c_int, 0), harf_term_exit_status(t));
    try std.testing.expectEqual(@as(c_int, 0), state.status.load(.acquire));
    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), harf_term_row_text(t, 0, &buf, buf.len));
    try std.testing.expectEqualStrings("hi", buf[0..2]);
}

test "harf_term_key and harf_term_paste" {
    const argv = [_:null]?[*:0]const u8{ "/bin/cat", null };
    const t = harf_term_new(80, 24, 1 << 20, &argv, null) orelse return error.TermNotCreated;
    defer harf_term_free(t);
    try std.testing.expectEqual(@as(c_int, 1), harf_term_key(t, 126, 0, null, 0, 0)); // up arrow
    try std.testing.expectEqual(@as(c_int, 1), harf_term_key(t, 56, 1, null, 0, 0)); // shift alone
    try std.testing.expectEqual(@as(c_int, 0), harf_term_key(t, 200, 0, "x", 1, 0)); // unknown key: text path
    try std.testing.expectEqual(@as(c_int, 0), harf_term_paste(t, "hi", 2));
}

test "harf_term_new rejects zero size" {
    const cb: HarfTermCallbacks = .{ .ctx = null, .wake = null, .title = null, .bell = null, .exited = null };
    try std.testing.expect(harf_term_new(0, 24, 1 << 20, null, &cb) == null);
    try std.testing.expect(harf_term_new(80, 0, 1 << 20, null, &cb) == null);
}

test "harf_ping returns magic" {
    try std.testing.expectEqual(@as(u32, 0x48415246), harf_ping());
}

test {
    _ = @import("shape/layout.zig");
    _ = @import("bidi/bidi.zig");
    _ = @import("vt.zig");
    _ = @import("pty.zig");
    _ = @import("term.zig");
    _ = @import("keys.zig");
    _ = @import("draw.zig");
}
