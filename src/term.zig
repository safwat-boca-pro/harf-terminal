//! A terminal session: a child on a PTY, a grid fed from its output, one I/O thread.
//! The I/O thread owns reading, parsing and reaping; everything else goes through `lock`/`unlock`.
const std = @import("std");
const vt = @import("vt.zig");
const pty = @import("pty.zig");
const keys = @import("keys.zig");

const c = std.c;

/// Events from the session. All run on the I/O thread, so they must be quick and must not call
/// back into the session except `wakeHandled`.
pub const Callbacks = struct {
    ctx: ?*anyopaque = null,
    /// New output was parsed. Called once, then not again until `wakeHandled`.
    wake: ?*const fn (ctx: ?*anyopaque) void = null,
    title: ?*const fn (ctx: ?*anyopaque) void = null,
    bell: ?*const fn (ctx: ?*anyopaque) void = null,
    /// The child ended and all its output has been parsed.
    exited: ?*const fn (ctx: ?*anyopaque, status: u8) void = null,
};

pub const Options = struct {
    cols: u16 = 80,
    rows: u16 = 24,
    scrollback_bytes: usize = 1 << 20,
    /// The program to run (`argv[0]` is its path). Null runs the user's login shell.
    argv: ?[]const [:0]const u8 = null,
    callbacks: Callbacks = .{},
};

/// Most bytes `Session.input` queues before refusing more.
pub const max_pending_input: usize = 64 << 20;

pub const Session = struct {
    gpa: std.mem.Allocator,
    pty: pty.Pty,
    term: *vt.Terminal,
    callbacks: Callbacks,
    thread: ?std.Thread = null,
    /// Guards `term`. Held by the I/O thread while parsing and by drawing code while reading cells.
    term_lock: c.pthread_mutex_t = .{},
    /// Guards `out_queue`. Taken after `term_lock` when both are needed, never before.
    out_lock: c.pthread_mutex_t = .{},
    /// Bytes for the child (typed input, pasted text, parser replies), oldest first. Only the I/O
    /// thread writes them to the PTY, so no caller ever waits on a child that is not reading.
    out_queue: std.ArrayList(u8) = .empty,
    out_head: usize = 0,
    /// Written by `input` to wake the I/O thread; it then polls for POLLOUT.
    kick_pipe: [2]c_int = .{ -1, -1 },
    /// `deinit` writes to [1] to wake the I/O thread, which polls [0] together with the PTY.
    stop_pipe: [2]c_int = .{ -1, -1 },
    wake_pending: std.atomic.Value(bool) = .init(false),
    /// -1 while the child runs, then its exit code.
    exit_status: std.atomic.Value(i32) = .init(-1),

    pub fn start(gpa: std.mem.Allocator, opts: Options) !*Session {
        const self = try gpa.create(Session);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .pty = undefined, .term = undefined, .callbacks = opts.callbacks };
        if (c.pipe(&self.stop_pipe) != 0) return error.PipeFailed;
        pty.setCloexec(self.stop_pipe[0]);
        pty.setCloexec(self.stop_pipe[1]);
        errdefer {
            _ = c.close(self.stop_pipe[0]);
            _ = c.close(self.stop_pipe[1]);
        }
        if (c.pipe(&self.kick_pipe) != 0) return error.PipeFailed;
        for (self.kick_pipe) |fd| {
            pty.setCloexec(fd);
            pty.setNonblock(fd);
        }
        errdefer {
            _ = c.close(self.kick_pipe[0]);
            _ = c.close(self.kick_pipe[1]);
        }
        errdefer self.out_queue.deinit(gpa);
        self.term = try vt.Terminal.init(gpa, .{
            .cols = opts.cols,
            .rows = opts.rows,
            .scrollback_bytes = opts.scrollback_bytes,
            .callbacks = .{ .ctx = self, .write_pty = onWritePty, .bell = onBell, .title_changed = onTitle },
        });
        errdefer self.term.deinit();
        self.pty = if (opts.argv) |argv|
            try pty.Pty.spawn(gpa, .{ .argv = argv, .cols = opts.cols, .rows = opts.rows })
        else
            try pty.Pty.spawnShell(gpa, opts.cols, opts.rows);
        errdefer self.pty.deinit();
        self.thread = try std.Thread.spawn(.{}, ioLoop, .{self});
        return self;
    }

    /// Stops the I/O thread, hangs up on the child if it is still running, and frees everything.
    pub fn deinit(self: *Session) void {
        _ = c.write(self.stop_pipe[1], "x", 1);
        if (self.thread) |t| t.join();
        self.pty.deinit();
        self.term.deinit();
        _ = c.close(self.stop_pipe[0]);
        _ = c.close(self.stop_pipe[1]);
        _ = c.close(self.kick_pipe[0]);
        _ = c.close(self.kick_pipe[1]);
        self.out_queue.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Queues bytes for the child as if typed; returns at once. The I/O thread sends them when the
    /// child is ready to read. Fails with `error.InputQueueFull` past `max_pending_input` queued bytes.
    pub fn input(self: *Session, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        {
            _ = c.pthread_mutex_lock(&self.out_lock);
            defer _ = c.pthread_mutex_unlock(&self.out_lock);
            if (self.out_queue.items.len - self.out_head + bytes.len > max_pending_input) return error.InputQueueFull;
            try self.out_queue.appendSlice(self.gpa, bytes);
        }
        _ = c.write(self.kick_pipe[1], "k", 1); // a full pipe means a wake-up is already pending
    }

    /// Handles a key event the way a terminal must: function keys, and any key with Control held,
    /// are encoded for the terminal's current modes and queued. Returns false for text keys, which
    /// the caller sends as text through `input` (that keeps dead keys and Arabic layouts working).
    pub fn key(self: *Session, keycode: u16, mods: u32, utf8: []const u8, action: vt.KeyAction) !bool {
        if (keys.isModifierKeycode(keycode)) return true; // nothing to send
        const k = keys.fromMac(keycode) orelse return false;
        if (!keys.isFunctional(k) and mods & keys.Mods.ctrl == 0) return false;
        var buf: [128]u8 = undefined;
        const t = self.lock();
        const legacy = t.kittyFlags() == 0;
        // Editor-style keys (brief section 5) are for programs that have not enabled the kitty
        // protocol; once one has, it gets the full modifier encoding instead.
        if (legacy and action != .release) {
            if (keys.editorBytes(k, mods)) |seq| {
                self.unlock();
                try self.input(seq);
                return true;
            }
            if (mods & keys.Mods.super != 0) { // other Command combinations belong to the app, not the shell
                self.unlock();
                return true;
            }
        }
        const bytes = t.encodeKey(k, mods, utf8, action, &buf);
        self.unlock();
        try self.input(bytes);
        return true;
    }

    /// Queues pasted text, framed for the terminal's current paste mode.
    pub fn paste(self: *Session, text: []const u8) !void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        {
            const t = self.lock();
            defer self.unlock();
            try t.encodePaste(text, &out, self.gpa);
        }
        try self.input(out.items);
    }

    /// Copies the window title into `out` under the lock (a slice of `out`, cut off if too long).
    pub fn title(self: *Session, out: []u8) []const u8 {
        const t = self.lock();
        defer self.unlock();
        const src = t.title();
        const n = @min(src.len, out.len);
        @memcpy(out[0..n], src[0..n]);
        return out[0..n];
    }

    /// Bytes queued for the child and not yet sent.
    pub fn pendingInput(self: *Session) usize {
        _ = c.pthread_mutex_lock(&self.out_lock);
        defer _ = c.pthread_mutex_unlock(&self.out_lock);
        return self.out_queue.items.len - self.out_head;
    }

    /// Sends as much queued input as the child takes right now. I/O thread only.
    fn flushOutput(self: *Session) void {
        _ = c.pthread_mutex_lock(&self.out_lock);
        defer _ = c.pthread_mutex_unlock(&self.out_lock);
        while (self.out_head < self.out_queue.items.len) {
            const n = self.pty.writeSome(self.out_queue.items[self.out_head..]) catch {
                self.out_queue.clearRetainingCapacity(); // the child is gone: nobody will read these
                self.out_head = 0;
                return;
            };
            if (n == 0) return;
            self.out_head += n;
        }
        self.out_queue.clearRetainingCapacity();
        self.out_head = 0;
    }

    /// Resizes the grid and the PTY. `cell_w_px` and `cell_h_px` are the size of one cell.
    pub fn resize(self: *Session, cols: u16, rows: u16, cell_w_px: u32, cell_h_px: u32) !void {
        {
            const t = self.lock();
            defer self.unlock();
            t.resize(cols, rows, cell_w_px, cell_h_px);
        }
        const total_w: u16 = @intCast(@min(std.math.maxInt(u16), @as(u64, cols) * cell_w_px));
        const total_h: u16 = @intCast(@min(std.math.maxInt(u16), @as(u64, rows) * cell_h_px));
        try self.pty.resize(cols, rows, total_w, total_h);
    }

    /// Locks the grid and returns it. Pair with `unlock`; keep the lock short.
    pub fn lock(self: *Session) *vt.Terminal {
        _ = c.pthread_mutex_lock(&self.term_lock);
        return self.term;
    }

    pub fn unlock(self: *Session) void {
        _ = c.pthread_mutex_unlock(&self.term_lock);
    }

    /// Re-arms the `wake` callback; call it before reading the grid for a redraw.
    pub fn wakeHandled(self: *Session) void {
        self.wake_pending.store(false, .release);
    }

    /// The child's exit code once it has ended and its output is fully parsed, else null.
    pub fn exitStatus(self: *Session) ?u8 {
        const v = self.exit_status.load(.acquire);
        return if (v < 0) null else @intCast(v);
    }

    pub fn pid(self: *Session) c_int {
        return self.pty.pid;
    }

    fn requestWake(self: *Session) void {
        if (self.wake_pending.swap(true, .acq_rel)) return;
        if (self.callbacks.wake) |f| f(self.callbacks.ctx);
    }

    fn ioLoop(self: *Session) void {
        var buf: [64 * 1024]u8 = undefined;
        var fds = [3]c.pollfd{
            .{ .fd = self.pty.fd, .events = c.POLL.IN, .revents = 0 },
            .{ .fd = self.stop_pipe[0], .events = c.POLL.IN, .revents = 0 },
            .{ .fd = self.kick_pipe[0], .events = c.POLL.IN, .revents = 0 },
        };
        const readable = c.POLL.IN | c.POLL.HUP | c.POLL.ERR | c.POLL.NVAL;
        while (true) {
            // Watch for POLLOUT only while there is something to send: idle means no wake-ups.
            fds[0].events = if (self.pendingInput() > 0) c.POLL.IN | c.POLL.OUT else c.POLL.IN;
            const r = c.poll(&fds, fds.len, -1);
            if (r < 0) {
                if (std.posix.errno(@as(isize, r)) == .INTR) continue;
                break;
            }
            if (fds[1].revents != 0) return; // deinit: it hangs up on the child and reaps it
            if (fds[2].revents != 0) {
                var junk: [64]u8 = undefined;
                _ = c.read(self.kick_pipe[0], &junk, junk.len);
            }
            // Read first: output must drain even while input is stuck, or both sides wait on each other.
            if (fds[0].revents & readable != 0) {
                const n = self.pty.read(&buf) catch break;
                if (n == 0) break;
                _ = c.pthread_mutex_lock(&self.term_lock);
                self.term.write(buf[0..n]);
                _ = c.pthread_mutex_unlock(&self.term_lock);
                self.requestWake();
            }
            if (self.pendingInput() > 0) self.flushOutput();
        }
        // The child closed its side: reap it and report.
        const status = self.pty.wait();
        self.exit_status.store(status, .release);
        if (self.callbacks.exited) |f| f(self.callbacks.ctx, status);
    }

    // Parser callbacks run inside Terminal.write on the I/O thread, with term_lock held.
    fn onWritePty(ctx: ?*anyopaque, data: []const u8) void {
        const self: *Session = @ptrCast(@alignCast(ctx.?));
        self.input(data) catch {}; // a reply that does not fit the queue is dropped
    }

    fn onBell(ctx: ?*anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(ctx.?));
        if (self.callbacks.bell) |f| f(self.callbacks.ctx);
    }

    fn onTitle(ctx: ?*anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(ctx.?));
        if (self.callbacks.title) |f| f(self.callbacks.ctx);
    }
};

// ---- tests ----

const Spy = struct {
    wakes: std.atomic.Value(u32) = .init(0),
    exits: std.atomic.Value(i32) = .init(-1),

    fn from(ctx: ?*anyopaque) *Spy {
        return @ptrCast(@alignCast(ctx.?));
    }
    fn wake(ctx: ?*anyopaque) void {
        _ = from(ctx).wakes.fetchAdd(1, .monotonic);
    }
    fn exited(ctx: ?*anyopaque, status: u8) void {
        from(ctx).exits.store(status, .release);
    }
    fn callbacks(self: *Spy) Callbacks {
        return .{ .ctx = self, .wake = wake, .exited = exited };
    }
};

fn sleepMs(ms: u32) void {
    const ts: std.c.timespec = .{ .sec = ms / 1000, .nsec = @as(isize, ms % 1000) * std.time.ns_per_ms };
    _ = std.c.nanosleep(&ts, null);
}

/// Test-only polling: product code never polls.
fn waitFor(timeout_ms: u32, ctx: anytype, comptime pred: fn (@TypeOf(ctx)) bool) bool {
    var waited: u32 = 0;
    while (waited < timeout_ms) : (waited += 5) {
        if (pred(ctx)) return true;
        sleepMs(5);
    }
    return pred(ctx);
}

const Row = struct {
    s: *Session,
    want: []const u8,
    exact: bool = true,
    fn ok(self: Row) bool {
        const t = self.s.lock();
        defer self.s.unlock();
        var buf: [512]u8 = undefined;
        var r: u16 = 0;
        while (r < t.size().rows) : (r += 1) {
            const text = t.rowText(r, &buf);
            if (if (self.exact) std.mem.eql(u8, text, self.want) else std.mem.indexOf(u8, text, self.want) != null) return true;
        }
        return false;
    }
};

const Exited = struct {
    s: *Session,
    fn ok(self: Exited) bool {
        return self.s.exitStatus() != null;
    }
};

test "echo round trip" {
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{"/bin/sh"} });
    defer s.deinit();
    try s.input("echo hi\n");
    try std.testing.expect(waitFor(10_000, Row{ .s = s, .want = "hi" }, Row.ok));
}

test "flood and fast exit" {
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "seq 1 200000" } });
    defer s.deinit();
    try std.testing.expect(waitFor(20_000, Exited{ .s = s }, Exited.ok));
    try std.testing.expectEqual(@as(?u8, 0), s.exitStatus());
    const t = s.lock();
    defer s.unlock();
    var buf: [512]u8 = undefined;
    var r: u16 = t.size().rows;
    var last: []const u8 = "";
    while (r > 0) {
        r -= 1;
        last = t.rowText(r, &buf);
        if (last.len > 0) break;
    }
    try std.testing.expectEqualStrings("200000", last);
    try std.testing.expect(t.scrollbackRows() <= 1200);
}

test "wake is coalesced until handled" {
    var spy: Spy = .{};
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{"/bin/sh"}, .callbacks = spy.callbacks() });
    defer s.deinit();
    try s.input("echo a\n");
    try std.testing.expect(waitFor(10_000, Row{ .s = s, .want = "a" }, Row.ok));
    try std.testing.expectEqual(@as(u32, 1), spy.wakes.load(.monotonic));
    try s.input("echo b\n");
    try std.testing.expect(waitFor(10_000, Row{ .s = s, .want = "b" }, Row.ok));
    try std.testing.expectEqual(@as(u32, 1), spy.wakes.load(.monotonic)); // never handled, so still one
    s.wakeHandled();
    try s.input("echo c\n");
    try std.testing.expect(waitFor(10_000, Row{ .s = s, .want = "c" }, Row.ok));
    try std.testing.expectEqual(@as(u32, 2), spy.wakes.load(.monotonic));
}

test "deinit kills a live child" {
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sleep", "60" } });
    const p = s.pid();
    s.deinit();
    const rc = std.c.kill(p, @enumFromInt(0)); // signal 0: only checks that the process exists
    const e = std.posix.errno(@as(isize, rc));
    try std.testing.expectEqual(@as(c_int, -1), rc);
    try std.testing.expectEqual(std.posix.E.SRCH, e);
}

test "resize while output streams" {
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "seq 1 200000" } });
    defer s.deinit();
    const sizes = [_][2]u16{ .{ 10, 5 }, .{ 200, 60 }, .{ 1, 1 } };
    for (0..50) |i| {
        const sz = sizes[i % sizes.len];
        try s.resize(sz[0], sz[1], 8, 16);
    }
    try s.resize(80, 24, 8, 16);
    try std.testing.expect(waitFor(30_000, Exited{ .s = s }, Exited.ok));
    try std.testing.expectEqual(@as(?u8, 0), s.exitStatus());
}

test "exit status is reported" {
    var spy: Spy = .{};
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "exit 7" }, .callbacks = spy.callbacks() });
    defer s.deinit();
    try std.testing.expect(waitFor(10_000, Exited{ .s = s }, Exited.ok));
    try std.testing.expectEqual(@as(?u8, 7), s.exitStatus());
    try std.testing.expectEqual(@as(i32, 7), spy.exits.load(.acquire));
}

test "terminal replies reach the child" {
    // macOS od pads each byte with extra spaces; tr squeezes them so the needle below matches.
    const script = "stty raw -echo; printf '\\033[6n'; dd bs=1 count=6 2>/dev/null | od -An -tx1 | tr -s ' '";
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", script } });
    defer s.deinit();
    try std.testing.expect(waitFor(10_000, Row{ .s = s, .want = "1b 5b 31 3b 31 52", .exact = false }, Row.ok));
}

test "a child does not inherit another session's descriptors" {
    const a = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sleep", "60" } });
    defer a.deinit();
    var script_buf: [256]u8 = undefined;
    const script = try std.fmt.bufPrintSentinel(
        &script_buf,
        "for fd in {d} {d} {d}; do if (: <&$fd) 2>/dev/null; then echo leaked$fd; fi; done; echo done",
        .{ a.pty.fd, a.stop_pipe[0], a.stop_pipe[1] },
        0,
    );
    const b = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", script } });
    defer b.deinit();
    try std.testing.expect(waitFor(10_000, Row{ .s = b, .want = "done" }, Row.ok));
    try std.testing.expect(!(Row{ .s = b, .want = "leaked", .exact = false }).ok());
}

fn nowMs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

test "input never blocks" {
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "sleep 3" } });
    defer s.deinit();
    const big = try std.testing.allocator.alloc(u8, 8 << 20);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    const t0 = nowMs();
    try s.input(big);
    try std.testing.expect(nowMs() - t0 < 200);
}

test "queued input reaches the child in order" {
    const script = "stty raw -echo; echo ready; sleep 1; head -c 1000000 | wc -c";
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", script } });
    defer s.deinit();
    try std.testing.expect(waitFor(10_000, Row{ .s = s, .want = "ready", .exact = false }, Row.ok));
    const data = try std.testing.allocator.alloc(u8, 1_000_000);
    defer std.testing.allocator.free(data);
    @memset(data, 'y');
    try s.input(data);
    try std.testing.expect(waitFor(20_000, Row{ .s = s, .want = "1000000", .exact = false }, Row.ok));
}

test "resize with size reports does not block" {
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "printf '\\033[?2048h'; sleep 3" } });
    defer s.deinit();
    sleepMs(300); // let the mode switch be parsed
    const big = try std.testing.allocator.alloc(u8, 4 << 20);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    try s.input(big);
    const t0 = nowMs();
    try s.resize(100, 30, 8, 16);
    try std.testing.expect(nowMs() - t0 < 500);
}

test "input over the cap is refused" {
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "sleep 3" } });
    defer s.deinit();
    const big = try std.testing.allocator.alloc(u8, max_pending_input + 1);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    try std.testing.expectError(error.InputQueueFull, s.input(big));
    try std.testing.expectEqual(@as(usize, 0), s.pendingInput());
}

test "key: text keys are left to the text path, Arabic text arrives intact" {
    const script = "stty raw -echo; echo ready; dd bs=1 count=2 2>/dev/null | od -An -tx1 | tr -s ' '";
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", script } });
    defer s.deinit();
    try std.testing.expect(!try s.key(0, 0, "ش", .press)); // physical A on an Arabic layout
    try std.testing.expect(!try s.key(200, 0, "م", .press)); // unknown keycode
    try std.testing.expect(waitFor(10_000, Row{ .s = s, .want = "ready", .exact = false }, Row.ok));
    try s.input("م");
    try std.testing.expect(waitFor(10_000, Row{ .s = s, .want = "d9 85", .exact = false }, Row.ok));
}

test "key: arrows and ctrl c are encoded, modifier keys send nothing" {
    const script = "stty raw -echo; echo ready; dd bs=1 count=4 2>/dev/null | od -An -tx1 | tr -s ' '";
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", script } });
    defer s.deinit();
    try std.testing.expect(waitFor(10_000, Row{ .s = s, .want = "ready", .exact = false }, Row.ok));
    try std.testing.expect(try s.key(56, 1, "", .press)); // shift alone
    try std.testing.expect(try s.key(126, 0, "", .press)); // up arrow: ESC [ A (3 bytes)
    try std.testing.expect(try s.key(8, keys.Mods.ctrl, "\x03", .press)); // ctrl c: 1 byte
    try std.testing.expect(waitFor(10_000, Row{ .s = s, .want = "1b 5b 41 03", .exact = false }, Row.ok));
}

test "paste reaches the child with newlines as CR" {
    const script = "stty raw -echo; echo ready; dd bs=1 count=3 2>/dev/null | od -An -tx1 | tr -s ' '";
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", script } });
    defer s.deinit();
    try std.testing.expect(waitFor(10_000, Row{ .s = s, .want = "ready", .exact = false }, Row.ok));
    try s.paste("a\nb");
    try std.testing.expect(waitFor(10_000, Row{ .s = s, .want = "61 0d 62", .exact = false }, Row.ok));
}

test "title copy" {
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "printf '\\033]0;hi\\007'; sleep 2" } });
    defer s.deinit();
    var buf: [16]u8 = undefined;
    var got = false;
    var waited: u32 = 0;
    while (waited < 10_000 and !got) : (waited += 5) {
        got = std.mem.eql(u8, s.title(&buf), "hi");
        if (!got) sleepMs(5);
    }
    try std.testing.expect(got);
    var one: [1]u8 = undefined;
    try std.testing.expectEqualStrings("h", s.title(&one));
}

fn hexOf(s: *Session, want: []const u8) bool {
    return waitFor(10_000, Row{ .s = s, .want = want, .exact = false }, Row.ok);
}

test "key: Option and Command editing keys in legacy mode" {
    const script = "stty raw -echo; echo ready; dd bs=1 count=7 2>/dev/null | od -An -tx1 | tr -s ' '";
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", script } });
    defer s.deinit();
    try std.testing.expect(hexOf(s, "ready"));
    try std.testing.expect(try s.key(123, keys.Mods.alt, "", .press)); // Option+Left: ESC b
    try std.testing.expect(try s.key(124, keys.Mods.alt, "", .press)); // Option+Right: ESC f
    try std.testing.expect(try s.key(123, keys.Mods.super, "", .press)); // Cmd+Left: ^A
    try std.testing.expect(try s.key(126, keys.Mods.super, "", .press)); // Cmd+Up: nothing for the shell
    try std.testing.expect(try s.key(124, keys.Mods.super, "", .press)); // Cmd+Right: ^E
    try std.testing.expect(try s.key(51, keys.Mods.super, "", .press)); // Cmd+Backspace: ^U
    try std.testing.expect(hexOf(s, "1b 62 1b 66 01 05 15"));
}

test "key: Option+arrows send the full modifier encoding once the program asked for the kitty protocol" {
    const script = "stty raw -echo; printf '\\033[>1u'; echo ready; dd bs=1 count=6 2>/dev/null | od -An -tx1 | tr -s ' '";
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", script } });
    defer s.deinit();
    try std.testing.expect(hexOf(s, "ready"));
    try std.testing.expect(try s.key(123, keys.Mods.alt, "", .press)); // ESC [ 1 ; 3 D
    try std.testing.expect(hexOf(s, "1b 5b 31 3b 33 44"));
}
