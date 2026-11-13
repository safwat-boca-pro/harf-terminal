//! C ABI surface. Keep in sync with include/harf.h.
const std = @import("std");
const ct = @import("shape/ct.zig");
const spike = @import("spike.zig");
const layout = @import("shape/layout.zig");
const term = @import("term.zig");

/// Phase 0 smoke test. Returns 0x48415246 ("HARF").
export fn harf_ping() u32 {
    return 0x48415246;
}

// ---- Phase 1 spike (temporary; replaced by the real draw-rows API in Phase 4) ----

export fn harf_spike_new() ?*spike.Spike {
    return spike.Spike.create(std.heap.smp_allocator) catch null;
}

export fn harf_spike_free(s: *spike.Spike) void {
    s.destroy();
}

export fn harf_spike_metrics(s: *spike.Spike, font_spec: [*:0]const u8, size_px: f32, out: *spike.Metrics) void {
    out.* = s.metrics(std.mem.span(font_spec), size_px);
}

/// Lays out and draws one row into a y-down CGContext.
export fn harf_spike_draw_row(s: *spike.Spike, ctx: *ct.CGContext, req: *const spike.RowRequest, info: *layout.RowInfo) void {
    s.drawRow(ctx, req.*, info);
}

/// Copies the cluster extents of the last drawn row (model 3). Returns how many exist; writes at most `cap`.
export fn harf_spike_extents(s: *spike.Spike, out: [*]layout.Extent, cap: usize) usize {
    const ex = s.extents();
    const n = @min(ex.len, cap);
    @memcpy(out[0..n], ex[0..n]);
    return ex.len;
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
}
