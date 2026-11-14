//! Phase 5 spike (docs/phase5-spike.md): an agent CLI (claude, codex) runs inside a real `Session`, behind
//! `tools/agent-proxy.py`, which logs every byte the program writes and every byte Harf answers. A scripted list of steps
//! drives it; `dump` prints the screen and the terminal's modes. Tests only; nothing ships. Gated on HARF_AGENT_CMD.
//!
//!   HARF_AGENT_CMD="claude" HARF_PROXY_LOG=<file> HARF_AGENT_SCRIPT="waitfor:?;dump;text:hi;dump" \
//!     zig build test -Dtest-filter="agent spike"
//!
//! Steps, separated by `;`: `wait:<ms>`, `waitfor:<text>` (20 s), `dump`, `shot:<file>` (raw picture), `text:<utf8>`, `paste:<utf8>`, `enter`,
//! `shift-enter`, `esc`, `tab`, `up`, `down`, `ctrl-c`, `ctrl-d`, `resize:<cols>x<rows>`.
const std = @import("std");
const term = @import("term.zig");
const keys = @import("keys.zig");
const draw = @import("draw.zig");
const ct = @import("shape/ct.zig");
const Session = term.Session;

extern "c" fn creat(path: [*:0]const u8, mode: u16) c_int;

fn sleepMs(ms: u32) void {
    const ts: std.c.timespec = .{ .sec = ms / 1000, .nsec = @as(isize, ms % 1000) * std.time.ns_per_ms };
    _ = std.c.nanosleep(&ts, null);
}

fn env(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    return std.mem.span(v);
}

fn screenHas(s: *Session, needle: []const u8) bool {
    const t = s.lock();
    defer s.unlock();
    var buf: [2048]u8 = undefined;
    var r: u16 = 0;
    const rows = t.size().rows;
    while (r < rows) : (r += 1) if (std.mem.indexOf(u8, t.rowText(r, &buf), needle) != null) return true;
    return false;
}

fn dump(s: *Session, n: usize) void {
    var tbuf: [256]u8 = undefined;
    const title = s.title(&tbuf);
    const t = s.lock();
    defer s.unlock();
    _ = t.update();
    const sz = t.size();
    std.debug.print("\n=== dump {d}: {d}x{d} alt={} kitty_flags={d} bracketed_paste={} focus_events={} mouse={} scrollback_rows={d} title='{s}'\n", .{
        n, sz.cols, sz.rows, t.onAlternateScreen(), t.kittyFlags(), t.bracketedPaste(), t.focusEvents(), t.mouseTracking(), t.scrollbackRows(), title,
    });
    if (t.cursor()) |cur| std.debug.print("cursor: col {d} row {d} visible={} shape={s}\n", .{ cur.col, cur.row, cur.visible, @tagName(cur.shape) }) else std.debug.print("cursor: hidden\n", .{});
    var buf: [2048]u8 = undefined;
    var r: u16 = 0;
    while (r < sz.rows) : (r += 1) {
        const line = std.mem.trimEnd(u8, t.rowText(r, &buf), " ");
        std.debug.print("{d:0>2}|{s}\n", .{ r, line });
    }
}

/// Draws the grid with the real painter (Menlo 14 pt at 2x, as the window does) and writes `u32 w, u32 h, then BGRA rows`
/// to `path`; tools/raw2png.py makes the picture.
fn shot(s: *Session, path: []const u8) !void {
    const gpa = std.testing.allocator;
    const p = try draw.Painter.init(gpa, 28);
    defer p.deinit();
    p.focused = true;
    const m = p.metrics();
    const t = s.lock();
    defer s.unlock();
    const sz = t.size();
    const w: usize = @intFromFloat(m.cell_w * @as(f32, @floatFromInt(sz.cols)));
    const h: usize = @intFromFloat(m.cell_h * @as(f32, @floatFromInt(sz.rows)));
    const data = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(data);
    @memset(data, 0);
    const space = ct.CGColorSpaceCreateDeviceRGB() orelse return error.NoColorSpace;
    defer ct.CGColorSpaceRelease(space);
    const ctx = ct.CGBitmapContextCreate(data.ptr, w, h, 8, w * 4, space, 2 | (2 << 12)) orelse return error.NoContext;
    defer ct.CGContextRelease(ctx);
    ct.CGContextTranslateCTM(ctx, 0, @floatFromInt(h));
    ct.CGContextScaleCTM(ctx, 1, -1);
    p.drawRegion(t, ctx, 0, sz.rows - 1);
    var pathz: [512:0]u8 = undefined;
    @memcpy(pathz[0..path.len], path);
    pathz[path.len] = 0;
    const fd = creat(&pathz, 0o644);
    if (fd < 0) return error.CannotCreateFile;
    defer _ = std.c.close(fd);
    const head = [2]u32{ @intCast(w), @intCast(h) };
    _ = std.c.write(fd, std.mem.asBytes(&head), 8);
    var off: usize = 0;
    while (off < data.len) {
        const n = std.c.write(fd, data.ptr + off, data.len - off);
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

fn press(s: *Session, code: u16, mods: u32, text: []const u8, unshifted: u21) !void {
    _ = try s.key(code, mods, text, unshifted, .press);
}

test "agent spike: run the program in HARF_AGENT_CMD through the proxy and follow HARF_AGENT_SCRIPT" {
    const cmd = env("HARF_AGENT_CMD") orelse return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var argv: std.ArrayList([:0]const u8) = .empty;
    defer {
        for (argv.items) |a| gpa.free(a);
        argv.deinit(gpa);
    }
    try argv.append(gpa, try std.mem.Allocator.dupeSentinel(gpa, u8, "/usr/bin/python3", 0));
    try argv.append(gpa, try std.mem.Allocator.dupeSentinel(gpa, u8, "-I", 0));
    try argv.append(gpa, try std.mem.Allocator.dupeSentinel(gpa, u8, env("HARF_AGENT_PROXY") orelse "tools/agent-proxy.py", 0));
    var words = std.mem.tokenizeScalar(u8, cmd, ' ');
    while (words.next()) |w| try argv.append(gpa, try std.mem.Allocator.dupeSentinel(gpa, u8, w, 0));

    var cols: u16 = 100;
    var rows: u16 = 32;
    const s = try Session.start(gpa, .{ .cols = cols, .rows = rows, .argv = argv.items });
    defer s.deinit();

    var steps = std.mem.splitScalar(u8, env("HARF_AGENT_SCRIPT") orelse "wait:8000;dump", ';');
    var dumps: usize = 0;
    while (steps.next()) |step| {
        const colon = std.mem.indexOfScalar(u8, step, ':');
        const name = if (colon) |i| step[0..i] else step;
        const arg = if (colon) |i| step[i + 1 ..] else "";
        std.debug.print("step: {s}\n", .{step});
        if (std.mem.eql(u8, name, "wait")) {
            sleepMs(try std.fmt.parseInt(u32, arg, 10));
        } else if (std.mem.eql(u8, name, "waitfor")) {
            var waited: u32 = 0;
            while (waited < 20_000 and !screenHas(s, arg)) : (waited += 50) sleepMs(50);
            if (!screenHas(s, arg)) std.debug.print("waitfor '{s}': TIMED OUT\n", .{arg});
        } else if (std.mem.eql(u8, name, "dump")) {
            sleepMs(300); // let the last output settle
            dumps += 1;
            dump(s, dumps);
        } else if (std.mem.eql(u8, name, "shot")) {
            sleepMs(300);
            try shot(s, arg);
        } else if (std.mem.eql(u8, name, "text")) {
            try s.typeText(arg);
        } else if (std.mem.eql(u8, name, "paste")) {
            try s.paste(arg);
        } else if (std.mem.eql(u8, name, "enter")) {
            try press(s, 36, 0, "\r", '\r');
        } else if (std.mem.eql(u8, name, "shift-enter")) {
            try press(s, 36, keys.Mods.shift, "\r", '\r');
        } else if (std.mem.eql(u8, name, "esc")) {
            try press(s, 53, 0, "\x1b", 0x1b);
        } else if (std.mem.eql(u8, name, "tab")) {
            try press(s, 48, 0, "\t", '\t');
        } else if (std.mem.eql(u8, name, "up")) {
            try press(s, 126, 0, "", 0);
        } else if (std.mem.eql(u8, name, "down")) {
            try press(s, 125, 0, "", 0);
        } else if (std.mem.eql(u8, name, "ctrl-c")) {
            try press(s, 8, keys.Mods.ctrl, "c", 'c');
        } else if (std.mem.eql(u8, name, "ctrl-d")) {
            try press(s, 2, keys.Mods.ctrl, "d", 'd');
        } else if (std.mem.eql(u8, name, "resize")) {
            var it = std.mem.splitScalar(u8, arg, 'x');
            cols = try std.fmt.parseInt(u16, it.next() orelse "100", 10);
            rows = try std.fmt.parseInt(u16, it.next() orelse "32", 10);
            try s.resize(cols, rows, 8, 16);
        } else {
            std.debug.print("unknown step '{s}'\n", .{step});
        }
    }
    if (s.exitStatus()) |st| std.debug.print("program exited with {d}\n", .{st}) else std.debug.print("program still running\n", .{});
}
